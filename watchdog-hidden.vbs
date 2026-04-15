' watchdog-hidden.vbs — 창 없이 watchdog.ps1 실행
Set shell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File """ & scriptDir & "\watchdog.ps1"""
shell.Run cmd, 0, False  ' 0 = hidden window, False = no wait
