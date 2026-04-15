# register-task.ps1 — Windows 작업 스케줄러에 Watchdog 등록
# 로그온 시 자동 시작, 창 숨김, 사용자 세션에서 실행

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$TaskName = "DiskusageWatchdog"
$ScriptPath = Join-Path $PSScriptRoot "watchdog.ps1"

if (-not (Test-Path $ScriptPath)) {
    Write-Host "[ERROR] watchdog.ps1 not found at: $ScriptPath" -ForegroundColor Red
    exit 1
}

# 기존 작업 제거 (재등록 시)
& schtasks.exe /Query /TN $TaskName 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Removing existing task: $TaskName" -ForegroundColor Yellow
    & schtasks.exe /Delete /TN $TaskName /F | Out-Null
}

# XML 정의로 작업 등록 (가장 확실한 방법)
$userId = "$env:USERDOMAIN\$env:USERNAME"
$cmd = "powershell.exe"
$args = "-WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -File `"$ScriptPath`""

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Diskusage WSL Watchdog - WSL frozen detection with Telegram alerts</Description>
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
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$cmd</Command>
      <Arguments>$args</Arguments>
      <WorkingDirectory>$PSScriptRoot</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

# XML 파일로 저장 후 등록 (UTF-16)
$xmlPath = Join-Path $env:TEMP "diskusage-task.xml"
[System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.Encoding]::Unicode)

& schtasks.exe /Create /TN $TaskName /XML $xmlPath /F
$exitCode = $LASTEXITCODE
Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue

if ($exitCode -ne 0) {
    Write-Host "`n[ERROR] schtasks failed with exit code $exitCode" -ForegroundColor Red
    exit $exitCode
}

Write-Host "`n[OK] Task registered: $TaskName" -ForegroundColor Green
Write-Host ""
Write-Host "Start now:" -ForegroundColor Cyan
Write-Host "  schtasks /Run /TN $TaskName"
Write-Host ""
Write-Host "Stop:" -ForegroundColor Cyan
Write-Host "  schtasks /End /TN $TaskName"
Write-Host ""
Write-Host "Remove:" -ForegroundColor Cyan
Write-Host "  schtasks /Delete /TN $TaskName /F"
Write-Host ""
Write-Host "Status:" -ForegroundColor Cyan
Write-Host "  schtasks /Query /TN $TaskName /V /FO LIST"
