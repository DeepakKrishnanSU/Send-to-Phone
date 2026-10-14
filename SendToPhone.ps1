Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------- Configuration ----------
$deviceId   = ""   # KDE Connect device (fallback)
$deviceName = ""   # Phone Name to display
$adb        = "C:\platform-tools\adb.exe"
$phoneIp    = ""        # leave empty = auto-detect (the hotspot gateway). Or set e.g. "192.168.43.1"
$adbPort    = 5555

# ---------- ADB helpers ----------
function Get-AdbDevices {
    $found = @()
    foreach ($line in (& $adb devices 2>&1)) {
        if ("$line" -match '^(\S+)\s+device$') { $found += $Matches[1] }
    }
    return $found
}

function Get-PhoneIp {
    if ($phoneIp) { return $phoneIp }
    try {
        $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop |
            Where-Object { $_.NextHop -ne "0.0.0.0" } |
            Sort-Object RouteMetric |
            Select-Object -First 1
        return $route.NextHop
    } catch { return $null }
}

# Returns the adb serial to use (USB serial or ip:port), or $null
function Get-AdbTarget {
    if (-not (Test-Path $adb)) { return $null }
    $found = @(Get-AdbDevices)
    if ($found.Count -gt 0) { return [string]$found[0] }
    $ip = Get-PhoneIp
    if ($ip) {
        $null = & $adb connect "${ip}:$adbPort" 2>&1
        $found = @(Get-AdbDevices)
        if ($found.Count -gt 0) { return [string]$found[0] }
    }
    return $null
}

# Opens the URL straight on the phone via ADB; falls back to a KDE Connect notification
function Send-ToPhone($url) {
    $adbNote = "no ADB device found"
    $target = Get-AdbTarget
    if ($target) {
        # single-quote the URL for the phone's shell so characters like & survive
        $safe = ($url -replace '"', '%22') -replace "'", "'\''"
        $cmd  = "am start -a android.intent.action.VIEW -d '$safe'"
        $out  = & $adb -s $target shell $cmd 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -and $out -cnotmatch 'Error') {
            return @{ Ok = $true; Tag = "Opened"; Message = "Opened directly on $deviceName." }
        }
        $adbNote = ($out -replace '\s+', ' ').Trim()
        if ($adbNote.Length -gt 70) { $adbNote = $adbNote.Substring(0, 70) }
        if (-not $adbNote) { $adbNote = "exit code $LASTEXITCODE" }
    }
    try {
        $null = & kdeconnect-cli --share $url --device $deviceId 2>&1
        if ($LASTEXITCODE -eq 0) {
            return @{ Ok = $true; Tag = "Fallback"; Message = "ADB failed ($adbNote). Sent via KDE Connect." }
        }
    } catch { }
    return @{ Ok = $false; Tag = "Failed"; Message = "ADB failed ($adbNote). KDE Connect failed too." }
}

function C($hex) {
    return [System.Drawing.ColorTranslator]::FromHtml($hex)
}

# ---------- Custom controls (compiled once per session) ----------
$source = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class Native {
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, int w, int l);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);

    // Windows 11: native rounded corners + subtle border colour. Silently ignored on Windows 10.
    public static void RoundWindow(Form f) {
        try {
            int pref = 2;
            DwmSetWindowAttribute(f.Handle, 33, ref pref, 4);
            int border = 60 | (80 << 8) | (130 << 16);
            DwmSetWindowAttribute(f.Handle, 34, ref border, 4);
        } catch { }
    }
}

public static class Gfx {
    public static GraphicsPath Round(Rectangle r, int radius) {
        int d = radius * 2;
        if (d > r.Height) d = r.Height;
        if (d > r.Width) d = r.Width;
        GraphicsPath p = new GraphicsPath();
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    public static Color Mix(Color a, Color b, float t) {
        if (t < 0f) t = 0f; if (t > 1f) t = 1f;
        return Color.FromArgb(
            (int)(a.R + (b.R - a.R) * t),
            (int)(a.G + (b.G - a.G) * t),
            (int)(a.B + (b.B - a.B) * t));
    }
}

// Borderless window with gradient backdrop, dot grid, accent line and drawn title bar
public class HudForm : Form {
    public HudForm() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        FormBorderStyle = FormBorderStyle.None;
    }
    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        Native.RoundWindow(this);
    }
    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e);
        if (e.Button == MouseButtons.Left && e.Y < 58) {
            Native.ReleaseCapture();
            Native.SendMessage(Handle, 0xA1, 2, 0);
        }
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        Rectangle r = ClientRectangle;

        using (LinearGradientBrush bg = new LinearGradientBrush(r, Color.FromArgb(8, 12, 24), Color.FromArgb(13, 19, 42), 65f))
            g.FillRectangle(bg, r);

        // cyan glow, top right
        using (GraphicsPath gp = new GraphicsPath()) {
            gp.AddEllipse(r.Width - 360, -260, 600, 480);
            using (PathGradientBrush pg = new PathGradientBrush(gp)) {
                pg.CenterColor = Color.FromArgb(70, 34, 211, 238);
                pg.SurroundColors = new Color[] { Color.FromArgb(0, 34, 211, 238) };
                g.FillPath(pg, gp);
            }
        }
        // violet glow, bottom left
        using (GraphicsPath gp2 = new GraphicsPath()) {
            gp2.AddEllipse(-240, r.Height - 200, 520, 420);
            using (PathGradientBrush pg2 = new PathGradientBrush(gp2)) {
                pg2.CenterColor = Color.FromArgb(55, 139, 92, 246);
                pg2.SurroundColors = new Color[] { Color.FromArgb(0, 139, 92, 246) };
                g.FillPath(pg2, gp2);
            }
        }

        // dot grid
        Rectangle c = e.ClipRectangle;
        int x0 = (c.Left / 24) * 24, y0 = (c.Top / 24) * 24;
        using (SolidBrush dot = new SolidBrush(Color.FromArgb(26, 160, 190, 255))) {
            for (int x = x0; x < c.Right; x += 24)
                for (int y = y0; y < c.Bottom; y += 24)
                    g.FillRectangle(dot, x, y, 1, 1);
        }

        // top accent line
        using (LinearGradientBrush lb = new LinearGradientBrush(new Rectangle(0, 0, Width, 3), Color.Cyan, Color.Cyan, 0f)) {
            ColorBlend cb = new ColorBlend(3);
            cb.Colors = new Color[] { Color.FromArgb(34, 211, 238), Color.FromArgb(99, 102, 241), Color.FromArgb(168, 85, 247) };
            cb.Positions = new float[] { 0f, 0.5f, 1f };
            lb.InterpolationColors = cb;
            g.FillRectangle(lb, 0, 0, Width, 3);
        }

        // logo tile
        Rectangle ir = new Rectangle(26, 15, 28, 28);
        using (GraphicsPath ip = Gfx.Round(ir, 8))
        using (LinearGradientBrush ib = new LinearGradientBrush(ir, Color.FromArgb(34, 211, 238), Color.FromArgb(99, 102, 241), 45f))
            g.FillPath(ib, ip);
        using (Pen ap = new Pen(Color.White, 2.2f)) {
            ap.StartCap = LineCap.Round; ap.EndCap = LineCap.Round; ap.LineJoin = LineJoin.Round;
            g.DrawLine(ap, 33, 29, 47, 29);
            g.DrawLine(ap, 42, 24, 47, 29);
            g.DrawLine(ap, 42, 34, 47, 29);
        }

        // title + tag
        using (Font tf = new Font("Segoe UI Semibold", 11f))
        using (SolidBrush tb = new SolidBrush(Color.FromArgb(240, 245, 255))) {
            g.DrawString("Send to phone", tf, tb, 66, 19);
            float tw = g.MeasureString("Send to phone", tf).Width;
            int tagX = (int)(66 + tw) + 6;
            using (Font gf = new Font("Segoe UI", 8f)) {
                float gw = g.MeasureString("ADB link", gf).Width;
                Rectangle tr = new Rectangle(tagX, 21, (int)gw + 8, 18);
                using (GraphicsPath tp = Gfx.Round(tr, 9))
                using (Pen tpn = new Pen(Color.FromArgb(90, 79, 140, 255), 1f))
                    g.DrawPath(tpn, tp);
                using (SolidBrush gb = new SolidBrush(Color.FromArgb(140, 175, 255)))
                    g.DrawString("ADB link", gf, gb, tagX + 4, 23);
            }
        }

        // title separator and outer border
        using (Pen sp = new Pen(Color.FromArgb(22, 255, 255, 255), 1f))
            g.DrawLine(sp, 24, 57, Width - 24, 57);
        using (Pen bp = new Pen(Color.FromArgb(50, 90, 140, 255), 1f))
            g.DrawRectangle(bp, 0, 0, Width - 1, Height - 1);
    }
}

// Minimise / close glyph button
public class WinBtn : Control {
    public int Kind = 0;   // 0 = minimise, 1 = close
    bool over = false;
    public WinBtn() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;
        Cursor = Cursors.Hand;
    }
    protected override void OnMouseEnter(EventArgs e) { over = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { over = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        if (over) {
            Color f = (Kind == 1) ? Color.FromArgb(217, 65, 85) : Color.FromArgb(40, 255, 255, 255);
            using (GraphicsPath p = Gfx.Round(new Rectangle(0, 0, Width - 1, Height - 1), 8))
            using (SolidBrush b = new SolidBrush(f))
                g.FillPath(b, p);
        }
        Color gc = over ? Color.White : Color.FromArgb(160, 175, 205);
        using (Pen pen = new Pen(gc, 1.5f)) {
            pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
            float cx = Width / 2f, cy = Height / 2f;
            if (Kind == 1) {
                g.DrawLine(pen, cx - 5, cy - 5, cx + 5, cy + 5);
                g.DrawLine(pen, cx - 5, cy + 5, cx + 5, cy - 5);
            } else {
                g.DrawLine(pen, cx - 6, cy + 2, cx + 6, cy + 2);
            }
        }
    }
}

// Rounded, gradient, glowing button with animated hover
public class NeonButton : Control {
    public Color C1 = Color.FromArgb(34, 211, 238);
    public Color C2 = Color.FromArgb(99, 102, 241);
    public bool Ghost = false;
    float hover = 0f;
    bool over = false, down = false;
    System.Windows.Forms.Timer anim = new System.Windows.Forms.Timer();

    public NeonButton() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor |
                 ControlStyles.ResizeRedraw, true);
        BackColor = Color.Transparent;
        Cursor = Cursors.Hand;
        anim.Interval = 16;
        anim.Tick += delegate {
            float target = over ? 1f : 0f;
            hover += (target - hover) * 0.25f;
            if (Math.Abs(target - hover) < 0.02f) { hover = target; anim.Stop(); }
            Invalidate();
        };
    }
    public void PerformClick() { if (Enabled) OnClick(EventArgs.Empty); }
    protected override void OnTextChanged(EventArgs e) { base.OnTextChanged(e); Invalidate(); }
    protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
    protected override void OnMouseEnter(EventArgs e) { over = true; anim.Start(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { over = false; down = false; anim.Start(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        Rectangle body = new Rectangle(4, 4, Width - 9, Height - 9);
        if (body.Width < 8 || body.Height < 8) return;
        int rad = 12;
        float h = Enabled ? hover : 0f;

        if (Enabled && !Ghost) {
            for (int i = 4; i >= 1; i--) {
                int a = (int)((16 + 34 * h) / i);
                using (GraphicsPath gp = Gfx.Round(Rectangle.Inflate(body, i, i), rad + i))
                using (Pen p = new Pen(Color.FromArgb(Math.Min(255, a), C1), 1.5f))
                    g.DrawPath(p, gp);
            }
        }

        Color textColor;
        using (GraphicsPath path = Gfx.Round(body, rad)) {
            if (Ghost) {
                using (SolidBrush b = new SolidBrush(Color.FromArgb((int)(16 + 30 * h), 255, 255, 255)))
                    g.FillPath(b, path);
                using (Pen p = new Pen(Color.FromArgb((int)(60 + 130 * h), C1), 1f))
                    g.DrawPath(p, path);
                textColor = Gfx.Mix(Color.FromArgb(170, 185, 212), Color.White, h);
                if (!Enabled) textColor = Color.FromArgb(90, 100, 125);
            } else {
                Color a1, a2;
                if (!Enabled) {
                    a1 = Color.FromArgb(38, 48, 72); a2 = Color.FromArgb(34, 42, 64);
                    textColor = Color.FromArgb(120, 134, 160);
                } else {
                    a1 = Gfx.Mix(C1, Color.White, 0.18f * h);
                    a2 = Gfx.Mix(C2, Color.White, 0.14f * h);
                    if (down) { a1 = Gfx.Mix(a1, Color.Black, 0.18f); a2 = Gfx.Mix(a2, Color.Black, 0.18f); }
                    textColor = Color.White;
                }
                using (LinearGradientBrush lb = new LinearGradientBrush(body, a1, a2, 0f))
                    g.FillPath(lb, path);
                using (Pen p = new Pen(Color.FromArgb(Enabled ? 50 : 20, 255, 255, 255), 1f))
                    g.DrawPath(p, path);
            }
        }

        RectangleF tr = new RectangleF(body.X, body.Y + (down ? 1 : 0), body.Width, body.Height);
        using (StringFormat sf = new StringFormat())
        using (SolidBrush tb = new SolidBrush(textColor)) {
            sf.Alignment = StringAlignment.Center;
            sf.LineAlignment = StringAlignment.Center;
            g.DrawString(Text, Font, tb, tr, sf);
        }
    }
}

// Rounded input surface with glow on focus / error
public class InputCard : Panel {
    public TextBox Box = new TextBox();
    Label hint = new Label();
    bool focused = false;
    bool hasError = false;
    static Color Fill = Color.FromArgb(12, 18, 34);

    public bool HasError { get { return hasError; } set { hasError = value; Invalidate(); } }
    public string Placeholder { get { return hint.Text; } set { hint.Text = value; } }

    public InputCard() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw |
                 ControlStyles.SupportsTransparentBackColor, true);
        BackColor = Color.Transparent;

        Box.Multiline = true;
        Box.AcceptsReturn = true;
        Box.WordWrap = true;
        Box.BorderStyle = BorderStyle.None;
        Box.BackColor = Fill;
        Box.ForeColor = Color.FromArgb(234, 241, 255);
        Box.Font = new Font("Consolas", 12f);

        hint.AutoSize = false;
        hint.BackColor = Fill;
        hint.ForeColor = Color.FromArgb(88, 104, 134);
        hint.Font = Box.Font;
        hint.Cursor = Cursors.IBeam;
        hint.Click += delegate { Box.Focus(); };

        Box.GotFocus += delegate { focused = true; Invalidate(); };
        Box.LostFocus += delegate { focused = false; Invalidate(); };
        Box.TextChanged += delegate {
            hint.Visible = Box.Text.Length == 0;
            hasError = false;
            Invalidate();
        };

        Controls.Add(Box);
        Controls.Add(hint);
        hint.BringToFront();
        LayoutInner();
    }
    void LayoutInner() {
        Box.SetBounds(18, 16, Math.Max(10, Width - 36), Math.Max(10, Height - 32));
        hint.SetBounds(20, 16, Math.Max(10, Width - 40), 26);
    }
    protected override void OnResize(EventArgs e) { base.OnResize(e); LayoutInner(); }
    protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); Box.Focus(); }

    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle r = new Rectangle(4, 4, Width - 9, Height - 9);
        Color glow = hasError ? Color.FromArgb(255, 101, 122) : Color.FromArgb(34, 211, 238);

        if (focused || hasError) {
            for (int i = 4; i >= 1; i--) {
                using (GraphicsPath gp = Gfx.Round(Rectangle.Inflate(r, i, i), 12 + i))
                using (Pen p = new Pen(Color.FromArgb(10 + (5 - i) * 6, glow), 1.5f))
                    g.DrawPath(p, gp);
            }
        }
        using (GraphicsPath path = Gfx.Round(r, 12)) {
            using (SolidBrush b = new SolidBrush(Fill))
                g.FillPath(b, path);
            if (hasError) {
                using (Pen p = new Pen(glow, 1.5f)) g.DrawPath(p, path);
            } else if (focused) {
                using (LinearGradientBrush lb = new LinearGradientBrush(r, Color.FromArgb(34, 211, 238), Color.FromArgb(139, 92, 246), 0f))
                using (Pen p = new Pen(lb, 1.5f))
                    g.DrawPath(p, path);
            } else {
                using (Pen p = new Pen(Color.FromArgb(40, 52, 80), 1f)) g.DrawPath(p, path);
            }
        }
    }
}

// Pill-shaped status readout with pulsing dot
public class StatusPill : Control {
    Color dot = Color.FromArgb(57, 217, 138);
    string tag = "", msg = "";
    bool pulse = false;
    float phase = 0f;
    System.Windows.Forms.Timer t = new System.Windows.Forms.Timer();

    public StatusPill() {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor |
                 ControlStyles.ResizeRedraw, true);
        BackColor = Color.Transparent;
        t.Interval = 30;
        t.Tick += delegate {
            phase += 0.035f;
            if (phase > 1f) phase = 0f;
            Invalidate();
        };
    }
    public void Set(Color c, string tagText, string message, bool pulsing) {
        dot = c; tag = tagText; msg = message; pulse = pulsing;
        if (pulse) t.Start(); else { t.Stop(); phase = 0f; }
        Invalidate();
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
        using (GraphicsPath p = Gfx.Round(r, Height / 2)) {
            using (SolidBrush b = new SolidBrush(Color.FromArgb(14, 255, 255, 255)))
                g.FillPath(b, p);
            using (Pen pen = new Pen(Color.FromArgb(70, dot), 1f))
                g.DrawPath(pen, p);
        }
        float cx = 24f, cy = Height / 2f;
        if (pulse) {
            float rr = 5f + 8f * phase;
            using (Pen rp = new Pen(Color.FromArgb((int)(130 * (1f - phase)), dot), 1.5f))
                g.DrawEllipse(rp, cx - rr, cy - rr, rr * 2, rr * 2);
        }
        using (SolidBrush db = new SolidBrush(dot))
            g.FillEllipse(db, cx - 5, cy - 5, 10, 10);

        using (StringFormat sf = new StringFormat(StringFormat.GenericTypographic)) {
            sf.LineAlignment = StringAlignment.Center;
            sf.Trimming = StringTrimming.EllipsisCharacter;
            using (Font tf = new Font("Segoe UI Semibold", 9.5f))
            using (Font mf = new Font("Segoe UI", 9.5f))
            using (SolidBrush tb = new SolidBrush(dot))
            using (SolidBrush mb = new SolidBrush(Color.FromArgb(145, 162, 188))) {
                float tw = g.MeasureString(tag, tf, 1000, sf).Width;
                g.DrawString(tag, tf, tb, new RectangleF(42, 0, tw + 4, Height), sf);
                float mx = 42 + tw + 14;
                g.DrawString(msg, mf, mb, new RectangleF(mx, 0, Math.Max(10, Width - mx - 16), Height), sf);
            }
        }
    }
}
'@

if (-not ("HudForm" -as [type])) {
    Add-Type -TypeDefinition $source -ReferencedAssemblies System.Windows.Forms, System.Drawing
}

# ---------- Helpers ----------
function New-Label($text, $x, $y, $w, $h, $color, $font, $align) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.ForeColor = C $color
    $l.Font = $font
    $l.BackColor = [System.Drawing.Color]::Transparent
    if ($align) { $l.TextAlign = $align }
    $form.Controls.Add($l)
    return $l
}

# ---------- Main window ----------
$form = New-Object HudForm
$form.Text = "Send to Phone"
$form.Size = New-Object System.Drawing.Size(680, 500)
$form.StartPosition = "CenterScreen"
$form.ShowInTaskbar = $true
$form.KeyPreview = $true
$form.ForeColor = C "#E5EAF5"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

# Window buttons
$closeButton = New-Object WinBtn
$closeButton.Kind = 1
$closeButton.Location = New-Object System.Drawing.Point(626, 13)
$closeButton.Size = New-Object System.Drawing.Size(40, 32)
$closeButton.Add_Click({ $form.Close() })
$form.Controls.Add($closeButton)

$minButton = New-Object WinBtn
$minButton.Kind = 0
$minButton.Location = New-Object System.Drawing.Point(582, 13)
$minButton.Size = New-Object System.Drawing.Size(40, 32)
$minButton.Add_Click({ $form.WindowState = "Minimized" })
$form.Controls.Add($minButton)

# ---------- Header ----------
$null = New-Label "Send something across." 30 78 620 42 "#F1F5FF" (New-Object System.Drawing.Font("Segoe UI Semibold", 22))
$null = New-Label "Paste a link and it opens on your $deviceName." 32 124 620 24 "#8DA0BE" (New-Object System.Drawing.Font("Segoe UI", 10.5))

# ---------- URL input ----------
$null = New-Label "Destination URL" 32 172 300 20 "#9DB4DA" (New-Object System.Drawing.Font("Segoe UI Semibold", 9))

$card = New-Object InputCard
$card.Location = New-Object System.Drawing.Point(32, 196)
$card.Size = New-Object System.Drawing.Size(616, 124)
$card.Placeholder = "https://example.com/article"
$form.Controls.Add($card)
$urlBox = $card.Box

# ---------- Buttons ----------
$pasteButton = New-Object NeonButton
$pasteButton.Text = "Paste"
$pasteButton.Ghost = $true
$pasteButton.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$pasteButton.Location = New-Object System.Drawing.Point(28, 334)
$pasteButton.Size = New-Object System.Drawing.Size(116, 58)
$form.Controls.Add($pasteButton)

$clearButton = New-Object NeonButton
$clearButton.Text = "Clear"
$clearButton.Ghost = $true
$clearButton.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$clearButton.Location = New-Object System.Drawing.Point(148, 334)
$clearButton.Size = New-Object System.Drawing.Size(100, 58)
$form.Controls.Add($clearButton)

$sendButton = New-Object NeonButton
$sendButton.Text = "Send to phone"
$sendButton.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 11.5)
$sendButton.Location = New-Object System.Drawing.Point(252, 334)
$sendButton.Size = New-Object System.Drawing.Size(400, 58)
$form.Controls.Add($sendButton)

# ---------- Status ----------
$pill = New-Object StatusPill
$pill.Location = New-Object System.Drawing.Point(32, 410)
$pill.Size = New-Object System.Drawing.Size(616, 40)
$pill.Set((C "#39D98A"), "Ready", $deviceName, $false)
$form.Controls.Add($pill)

$null = New-Label "Ctrl+Enter to send     Esc to close" 32 462 616 20 "#5B6D8C" (New-Object System.Drawing.Font("Segoe UI", 8.5))

# ---------- Paste / Clear ----------
$pasteButton.Add_Click({
    $text = ""
    try { $text = [System.Windows.Forms.Clipboard]::GetText() } catch { }
    if ($text) {
        $urlBox.Text = $text.Trim()
        $urlBox.SelectionStart = $urlBox.Text.Length
    }
    $urlBox.Focus()
})

$clearButton.Add_Click({
    $urlBox.Clear()
    $pill.Set((C "#39D98A"), "Ready", $deviceName, $false)
    $urlBox.Focus()
})

# ---------- Send URL ----------
$sendButton.Add_Click({
    $url = $urlBox.Text.Trim()

    if ($url -notmatch '^https?://\S+$') {
        $card.HasError = $true
        $pill.Set((C "#FFB454"), "Invalid link", "Enter a URL beginning with http:// or https://", $false)
        return
    }

    $sendButton.Enabled = $false
    $sendButton.Text = "Sending..."
    $pill.Set((C "#4F8CFF"), "Sending", "Contacting $deviceName...", $true)
    $form.Refresh()

    try {
        $result = Send-ToPhone $url
        if ($result.Ok) {
            $pill.Set((C "#39D98A"), $result.Tag, $result.Message, $false)
            $urlBox.Clear()
            $urlBox.Focus()
        }
        else {
            $pill.Set((C "#FF657A"), $result.Tag, $result.Message, $false)
        }
    }
    catch {
        $pill.Set((C "#FF657A"), "Error", $_.Exception.Message, $false)
    }
    finally {
        $sendButton.Text = "Send to phone"
        $sendButton.Enabled = $true
    }
})

# ---------- Keyboard shortcuts ----------
$form.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $sendButton.PerformClick()
        $_.SuppressKeyPress = $true
    }
    elseif ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
        $form.Close()
    }
})

# ---------- On open: focus input and check the phone is reachable ----------
$form.Add_Shown({
    $urlBox.Focus()
    $pill.Set((C "#FBBF24"), "Checking", "Looking for $deviceName...", $true)
    $form.Refresh()
    try {
        $target = Get-AdbTarget
        if ($target) {
            $pill.Set((C "#39D98A"), "Online", "$deviceName - direct open via ADB", $false)
        }
        else {
            $pill.Set((C "#FFB454"), "No ADB link", "Will fall back to a KDE Connect notification.", $false)
        }
    }
    catch {
        $pill.Set((C "#FFB454"), "Unknown", "Could not check the phone.", $false)
    }
})

# Keep open until closed
[void]$form.ShowDialog()
$form.Dispose()