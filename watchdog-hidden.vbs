' watchdog-hidden.vbs — 창 없이 watchdog.ps1 실행
Set shell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File """ & scriptDir & "\watchdog.ps1"""
' True = wait until powershell exits; prevents scheduler from re-spawning duplicates
shell.Run cmd, 0, True
