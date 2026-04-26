' listener-hidden.vbs — 창 없이 command-listener.ps1 실행 + 자동 재시작
Set shell = CreateObject("WScript.Shell")
scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File """ & scriptDir & "\command-listener.ps1"""

Do
  shell.Run cmd, 0, True
  WScript.Sleep 5000
Loop
