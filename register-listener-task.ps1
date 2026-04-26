# register-listener-task.ps1 — Command Listener Task Scheduler 등록
# VBS 없이 powershell.exe 직접 실행 + 1분마다 체크 (죽어있으면 재시작)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$TaskName = "DiskusageListener"
$ScriptPath = Join-Path $PSScriptRoot "command-listener.ps1"
$VbsPath = Join-Path $PSScriptRoot "listener-hidden.vbs"

if (-not (Test-Path $ScriptPath)) {
    Write-Host "[ERROR] command-listener.ps1 not found" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $VbsPath)) {
    Write-Host "[ERROR] listener-hidden.vbs not found" -ForegroundColor Red
    exit 1
}

& schtasks.exe /Query /TN $TaskName 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Removing existing task: $TaskName" -ForegroundColor Yellow
    & schtasks.exe /Delete /TN $TaskName /F | Out-Null
}

$userId = "$env:COMPUTERNAME\$env:USERNAME"

# 핵심: TimeTrigger Repetition (1분마다 시도) + IgnoreNew (이미 실행 중이면 무시)
# = 죽으면 1분 안에 자동 부활, 살아있으면 중복 방지
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Diskusage Command Listener - persistent telegram bot listener</Description>
    <Author>$userId</Author>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$userId</UserId>
    </LogonTrigger>
    <TimeTrigger>
      <Repetition>
        <Interval>PT1M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>2025-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
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
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
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
Write-Host "  - 로그온 시 자동 시작"
Write-Host "  - 1분마다 살아있는지 체크 (이미 실행 중이면 무시)"
Write-Host "  - 죽으면 1분 내 자동 부활"
