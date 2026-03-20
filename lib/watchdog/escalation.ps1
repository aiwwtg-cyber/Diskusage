# escalation.ps1 — 임계값 평가 + 상태 머신

$script:LevelOrder = @("normal", "warn", "alert", "danger", "critical")
$script:LevelActions = @{
    "normal"   = "none"
    "warn"     = "cleanup"
    "alert"    = "cleanup_and_notify"
    "danger"   = "user_confirm"
    "critical" = "shutdown_confirm"
}
$script:LevelDurations = @{
    "warn"     = 30
    "alert"    = 30
    "danger"   = 60
    "critical" = 120
}

function New-EscalationState {
    return @{
        CurrentLevel = "normal"
        Duration     = 0
        LastAction   = $null
    }
}

function Get-IoLevel {
    param(
        [double]$TotalMBps,
        [double]$BaselineMBps,
        [hashtable]$Config
    )
    $pct = ($TotalMBps / $BaselineMBps) * 100

    if ($pct -ge $Config.CriticalThreshold) { return "critical" }
    if ($pct -ge $Config.DangerThreshold)   { return "danger" }
    if ($pct -ge $Config.AlertThreshold)    { return "alert" }
    if ($pct -ge $Config.WarnThreshold)     { return "warn" }
    return "normal"
}

function Update-EscalationState {
    param(
        [hashtable]$State,
        [string]$Level,
        [int]$IntervalSec,
        [bool]$WslTimeout = $false
    )

    $result = @{
        ShouldAct     = $false
        Action        = "none"
        EscalatedLevel = $Level
    }

    if ($WslTimeout) {
        $idx = $script:LevelOrder.IndexOf($Level)
        if ($idx -lt $script:LevelOrder.Count - 1) {
            $result.EscalatedLevel = $script:LevelOrder[$idx + 1]
        }
        $Level = $result.EscalatedLevel
    }

    if ($Level -eq "normal") {
        $State.CurrentLevel = "normal"
        $State.Duration = 0
        return $result
    }

    if ($State.CurrentLevel -eq $Level) {
        $State.Duration += $IntervalSec
    } else {
        $State.CurrentLevel = $Level
        $State.Duration = $IntervalSec
    }

    $requiredDuration = $script:LevelDurations[$Level]
    if ($null -eq $requiredDuration) { $requiredDuration = 30 }

    if ($State.Duration -ge $requiredDuration) {
        $result.ShouldAct = $true
        $result.Action = $script:LevelActions[$Level]
    }

    return $result
}
