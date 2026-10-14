' launch.vbs
' Starts SendToPhone.ps1 (in the same folder as this file) with no console window.
' Point your desktop shortcut at:  wscript.exe "C:\full\path\to\launch.vbs"

Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)
script = folder & "\SendToPhone.ps1"

CreateObject("WScript.Shell").Run "powershell.exe -ExecutionPolicy Bypass -File """ & script & """", 0, False
