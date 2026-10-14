# activate-adb.ps1
# One-time (per phone restart) step: switches ADB to network mode so the phone
# can be reached over Wi-Fi / hotspot without a USB cable.
#
# Before running: plug the phone in with a USB data cable, unlock it, and accept
# the "Allow USB debugging?" prompt (tick "Always allow").

$adb  = "C:\platform-tools\adb.exe"   # change if adb.exe is somewhere else
$port = 5555

if (-not (Test-Path $adb)) {
    Write-Host "adb.exe not found at $adb" -ForegroundColor Red
    Write-Host "Install Android platform-tools or edit the `$adb path in this script."
    Read-Host "Press Enter to exit"
    exit 1
}

$null = & $adb start-server 2>&1

# Find a phone connected over USB (serials without a colon; network entries look like ip:port)
$usb = @(
    & $adb devices | ForEach-Object {
        if ("$_" -match '^(\S+)\s+device$') { $Matches[1] }
    } | Where-Object { $_ -notmatch ':' }
)

if ($usb.Count -eq 0) {
    Write-Host "No phone found over USB." -ForegroundColor Red
    Write-Host "Check the cable, unlock the phone, enable USB debugging and accept the prompt."
    Read-Host "Press Enter to exit"
    exit 1
}

$serial = [string]$usb[0]
Write-Host "Found phone: $serial"

& $adb -s $serial tcpip $port

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Done. You can unplug the cable now." -ForegroundColor Green
    Write-Host "Connect the PC to the phone's hotspot, then open Send to Phone."
}
else {
    Write-Host "Could not switch ADB to network mode." -ForegroundColor Red
}

Read-Host "Press Enter to exit"
