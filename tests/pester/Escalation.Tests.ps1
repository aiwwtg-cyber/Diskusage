BeforeAll {
    . "$PSScriptRoot/../../lib/watchdog/escalation.ps1"
}

Describe "Get-IoLevel" {
    It "returns 'normal' for I/O below warn threshold" {
        $result = Get-IoLevel -TotalMBps 50 -BaselineMBps 100 -Config @{
            WarnThreshold=60; AlertThreshold=75; DangerThreshold=90; CriticalThreshold=95
        }
        $result | Should -Be "normal"
    }

    It "returns 'warn' for I/O at warn threshold" {
        $result = Get-IoLevel -TotalMBps 65 -BaselineMBps 100 -Config @{
            WarnThreshold=60; AlertThreshold=75; DangerThreshold=90; CriticalThreshold=95
        }
        $result | Should -Be "warn"
    }

    It "returns 'critical' for I/O at critical threshold" {
        $result = Get-IoLevel -TotalMBps 96 -BaselineMBps 100 -Config @{
            WarnThreshold=60; AlertThreshold=75; DangerThreshold=90; CriticalThreshold=95
        }
        $result | Should -Be "critical"
    }
}

Describe "Update-EscalationState" {
    It "does not escalate on first occurrence" {
        $state = New-EscalationState
        $result = Update-EscalationState -State $state -Level "warn" -IntervalSec 5
        $result.ShouldAct | Should -Be $false
    }

    It "escalates after sufficient duration" {
        $state = New-EscalationState
        for ($i = 0; $i -lt 7; $i++) {
            $result = Update-EscalationState -State $state -Level "warn" -IntervalSec 5
        }
        $result.ShouldAct | Should -Be $true
        $result.Action | Should -Be "cleanup"
    }

    It "resets when level drops to normal" {
        $state = New-EscalationState
        for ($i = 0; $i -lt 7; $i++) {
            Update-EscalationState -State $state -Level "warn" -IntervalSec 5
        }
        $result = Update-EscalationState -State $state -Level "normal" -IntervalSec 5
        $result.ShouldAct | Should -Be $false
        $state.Duration | Should -Be 0
    }

    It "escalates to next level on wsl -e timeout" {
        $state = New-EscalationState
        $result = Update-EscalationState -State $state -Level "warn" -IntervalSec 5 -WslTimeout $true
        $result.EscalatedLevel | Should -Be "alert"
    }
}
