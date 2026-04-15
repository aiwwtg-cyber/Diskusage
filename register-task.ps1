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
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Removing existing task: $TaskName" -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# Action: PowerShell 창 숨김 실행
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -NoProfile -File `"$ScriptPath`""

# Trigger: 로그온 시
$trigger = New-ScheduledTaskTrigger -AtLogOn

# Settings: 배터리에서도 실행, 재시작 허용, 무제한 실행
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 0)

# Principal: 현재 사용자, 최고 권한 X (MessageBox 필요하니 일반 사용자)
$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Diskusage WSL Watchdog — WSL 먹통 감지 및 텔레그램 알림" | Out-Null

Write-Host "`n✅ 작업 스케줄러 등록 완료: $TaskName" -ForegroundColor Green
Write-Host ""
Write-Host "지금 바로 시작하려면:" -ForegroundColor Cyan
Write-Host "  Start-ScheduledTask -TaskName $TaskName"
Write-Host ""
Write-Host "중지하려면:" -ForegroundColor Cyan
Write-Host "  Stop-ScheduledTask -TaskName $TaskName"
Write-Host ""
Write-Host "제거하려면:" -ForegroundColor Cyan
Write-Host "  Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false"
Write-Host ""
Write-Host "상태 확인:" -ForegroundColor Cyan
Write-Host "  Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo"
