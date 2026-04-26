' watchdog-hidden.vbs — 창 없이 watchdog.ps1 실행 (단순 래퍼)
' 죽으면 wscript도 함께 종료. Task Scheduler가 1분마다 체크해서 재시작.
Set shell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File """ & scriptDir & "\watchdog.ps1"""
shell.Run cmd, 0, True
