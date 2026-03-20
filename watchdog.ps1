#Requires -Version 5.1
<#
.SYNOPSIS
    Diskusage Windows Watchdog — WSL2 VHD I/O 감시 + 단계적 대응
.DESCRIPTION
    Hyper-V Virtual Storage Device 카운터로 WSL2 디스크 I/O를 감시하고,
    임계치 초과 시 단계적으로 대응합니다.
#>

param(
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Source libraries
. "$ScriptDir\lib\watchdog\counters.ps1"
. "$ScriptDir\lib\watchdog\escalation.ps1"
. "$ScriptDir\lib\watchdog\notification.ps1"

# Load config with defaults
$Config = @{
    MonitorInterval    = 5
    WarnThreshold      = 60
    AlertThreshold     = 75
    DangerThreshold    = 90
    CriticalThreshold  = 95
    IoBaselineMBps     = 100
    WslExecTimeout     = 10
    LogRetentionDays   = 7
}

# Try to load config from file
if ($ConfigPath -and (Test-Path $ConfigPath)) {
    Get-Content $ConfigPath | ForEach-Object {
        if ($_ -match "^(\w+)=(\d+)$") {
            $key = $matches[1]
            $val = [int]$matches[2]
            switch ($key) {
                "MONITOR_INTERVAL"   { $Config.MonitorInterval = $val }
                "WARN_THRESHOLD"     { $Config.WarnThreshold = $val }
                "ALERT_THRESHOLD"    { $Config.AlertThreshold = $val }
                "DANGER_THRESHOLD"   { $Config.DangerThreshold = $val }
                "CRITICAL_THRESHOLD" { $Config.CriticalThreshold = $val }
                "IO_BASELINE_MBPS"   { $Config.IoBaselineMBps = $val }
                "WSL_EXEC_TIMEOUT"   { $Config.WslExecTimeout = $val }
            }
        }
    }
}

# Log file setup
$LogDir = "$env:USERPROFILE\.diskusage\logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-WatchdogLog {
    param([string]$Message)
    $logFile = Join-Path $LogDir "watchdog-$(Get-Date -Format 'yyyy-MM-dd').log"
    $ts = Get-Date -Format "HH:mm:ss"
    "[$ts] $Message" | Out-File -Append -FilePath $logFile -Encoding utf8
}

function Invoke-WslCommand {
    param([string]$Command)
    $job = Start-Job -ScriptBlock {
        param($cmd)
        wsl -e bash -c $cmd
    } -ArgumentList $Command

    $completed = $job | Wait-Job -Timeout $Config.WslExecTimeout
    if ($null -eq $completed) {
        $job | Stop-Job
        $job | Remove-Job -Force
        return @{ Success = $false; Output = "timeout"; TimedOut = $true }
    }
    $output = $job | Receive-Job
    $job | Remove-Job -Force
    return @{ Success = $true; Output = $output; TimedOut = $false }
}

function Get-WslMonitorStatus {
    $result = Invoke-WslCommand "cat ~/.diskusage/status 2>/dev/null || echo 'unknown'"
    if ($result.Success) {
        return $result.Output.Trim()
    }
    return "unreachable"
}

# Check Hyper-V counter availability
$hasHyperV = (Get-WslVhdPaths).Count -gt 0
if (-not $hasHyperV) {
    Write-Host "[WARNING] Hyper-V counters not available. Using PhysicalDisk as fallback." -ForegroundColor Yellow
    Write-Host "          WSL I/O attribution will not be possible." -ForegroundColor Yellow
}

$notifyMethod = Get-NotificationMethod
Write-Host "=== Diskusage Watchdog ===" -ForegroundColor Cyan
Write-Host "Notification: $notifyMethod"
Write-Host "Hyper-V Counters: $(if ($hasHyperV) {'Available'} else {'Fallback mode'})"
Write-Host "Interval: $($Config.MonitorInterval)s"
Write-Host "Press Ctrl+C to stop."
Write-Host ""

# Main loop
$state = New-EscalationState

while ($true) {
    $vhdIo = Get-VhdIoRate
    $diskPct = Get-PhysicalDiskPercent
    $memMB = Get-VmmemMemoryMB

    $wslIsCause = $true
    if ($hasHyperV) {
        $wslIsCause = Test-WslIsIoCause -VhdTotalMBps $vhdIo.TotalMBps -PhysicalDiskPct $diskPct -BaselineMBps $Config.IoBaselineMBps
    }

    $level = "normal"
    if ($wslIsCause) {
        $level = Get-IoLevel -TotalMBps $vhdIo.TotalMBps -BaselineMBps $Config.IoBaselineMBps -Config $Config
    }

    $logMsg = "VHD_IO:$($vhdIo.TotalMBps)MB/s DISK:$($diskPct)% MEM:$([math]::Round($memMB/1024,1))GB LEVEL:$level"
    if (-not $wslIsCause -and $diskPct -ge 50) {
        $logMsg += " [EXTERNAL]"
        Write-WatchdogLog "EXTERNAL: PhysicalDisk $($diskPct)% but VHD_IO $($vhdIo.TotalMBps)MB/s -- external pressure, WSL actions suppressed"
    }
    Write-WatchdogLog $logMsg

    $color = switch ($level) {
        "normal"   { "Green" }
        "warn"     { "Yellow" }
        "alert"    { "DarkYellow" }
        "danger"   { "Red" }
        "critical" { "DarkRed" }
        default    { "White" }
    }
    Write-Host "$(Get-Date -Format 'HH:mm:ss') | IO:$($vhdIo.TotalMBps)MB/s | Disk:$($diskPct)% | Mem:$([math]::Round($memMB/1024,1))GB | [$level]" -ForegroundColor $color

    $escResult = Update-EscalationState -State $state -Level $level -IntervalSec $Config.MonitorInterval

    if ($escResult.ShouldAct) {
        Write-WatchdogLog "ESCALATION: Action=$($escResult.Action) Level=$level Duration=$($state.Duration)s"

        switch ($escResult.Action) {
            "cleanup" {
                $monStatus = Get-WslMonitorStatus
                if ($monStatus -ne "cleaning") {
                    $wslResult = Invoke-WslCommand "~/.diskusage/cleanup_trigger.sh warn 2>/dev/null"
                    if ($wslResult.TimedOut) {
                        Write-WatchdogLog "WSL_TIMEOUT: wsl -e timed out, escalating"
                        $escResult = Update-EscalationState -State $state -Level $level -IntervalSec 0 -WslTimeout $true
                    }
                } else {
                    Write-WatchdogLog "SKIP: WSL monitor already cleaning"
                }
            }
            "cleanup_and_notify" {
                $alertMsg = Format-AlertMessage -Level $level -TotalMBps $vhdIo.TotalMBps -MemoryMB $memMB
                Send-Notification -Title "Diskusage Warning" -Message $alertMsg -Level $level
                $monStatus = Get-WslMonitorStatus
                if ($monStatus -ne "cleaning") {
                    $wslResult = Invoke-WslCommand "~/.diskusage/cleanup_trigger.sh alert 2>/dev/null"
                    if ($wslResult.TimedOut) {
                        Write-WatchdogLog "WSL_TIMEOUT: wsl -e timed out at alert, escalating"
                        $escResult = Update-EscalationState -State $state -Level $level -IntervalSec 0 -WslTimeout $true
                    }
                }
            }
            "user_confirm" {
                $alertMsg = Format-AlertMessage -Level $level -TotalMBps $vhdIo.TotalMBps -MemoryMB $memMB
                Send-Notification -Title "Diskusage DANGER" -Message "$alertMsg`nWSL may become unresponsive." -Level $level
            }
            "shutdown_confirm" {
                $confirmed = Request-UserConfirmation `
                    -Title "Diskusage Critical" `
                    -Message "WSL2 disk I/O has been at $($vhdIo.TotalMBps)MB/s for $($state.Duration)s.`nShutdown WSL? (All WSL sessions will be terminated)"
                if ($confirmed) {
                    Write-WatchdogLog "ACTION: User confirmed wsl --shutdown"
                    wsl --shutdown
                    Write-Host "WSL has been shut down." -ForegroundColor Red
                    $state = New-EscalationState
                } else {
                    Write-WatchdogLog "ACTION: User declined shutdown"
                    $state.Duration = 0
                }
            }
        }
    }

    Start-Sleep -Seconds $Config.MonitorInterval
}
