' watchdog-hidden.vbs — 창 없이 watchdog.ps1 실행 + 자동 재시작 keeper
' watchdog.ps1이 죽으면 5초 후 자동 재시작합니다.

Set shell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File """ & scriptDir & "\watchdog.ps1"""

Do
  ' 0 = hidden window, True = wait until exits
  shell.Run cmd, 0, True
  ' 워치독이 종료되면 5초 후 재시작
  WScript.Sleep 5000
Loop
