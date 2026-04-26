# register-listener-task.ps1 — Command Listener를 Task Scheduler에 등록
# 로그온 시 자동 시작. 워치독과 별개로 항상 켜져 있어야 함.

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$TaskName = "DiskusageListener"
$ScriptPath = Join-Path $PSScriptRoot "command-listener.ps1"
$VbsPath = Join-Path $PSScriptRoot "listener-hidden.vbs"

if (-not (Test-Path $ScriptPath) -or -not (Test-Path $VbsPath)) {
    Write-Host "[ERROR] required files not found" -ForegroundColor Red
    exit 1
}

& schtasks.exe /Query /TN $TaskName 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Removing existing task: $TaskName" -ForegroundColor Yellow
    & schtasks.exe /Delete /TN $TaskName /F | Out-Null
}

$userId = "$env:COMPUTERNAME\$env:USERNAME"

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Diskusage Command Listener - receives Telegram /start_watchdog</Description>
    <Author>$userId</Author>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$userId</UserId>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$userId</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>10</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>wscript.exe</Command>
      <Arguments>"$VbsPath"</Arguments>
      <WorkingDirectory>$PSScriptRoot</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = Join-Path $env:TEMP "diskusage-listener-task.xml"
[System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.Encoding]::Unicode)

& schtasks.exe /Create /TN $TaskName /XML $xmlPath /F
$exitCode = $LASTEXITCODE
Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue

if ($exitCode -ne 0) {
    Write-Host "[ERROR] schtasks failed: $exitCode" -ForegroundColor Red
    exit $exitCode
}

Write-Host "[OK] Task registered: $TaskName" -ForegroundColor Green
Write-Host ""
Write-Host "Start now: schtasks /Run /TN $TaskName"
Write-Host "텔레그램 명령:"
Write-Host "  /start_watchdog   — 워치독 시작"
Write-Host "  /watchdog_status  — 워치독 상태 확인"
