BeforeAll {
    . "$PSScriptRoot/../../lib/watchdog/counters.ps1"
}

Describe "Get-WslVhdPaths" {
    It "does not throw" {
        { Get-WslVhdPaths } | Should -Not -Throw
    }
}

Describe "Get-VhdIoRate" {
    It "returns a hashtable with required keys" {
        $result = Get-VhdIoRate
        $result | Should -BeOfType [hashtable]
        $result.Keys | Should -Contain "ReadBytesPerSec"
        $result.Keys | Should -Contain "WriteBytesPerSec"
        $result.Keys | Should -Contain "TotalMBps"
    }
}

Describe "Get-PhysicalDiskPercent" {
    It "returns a non-negative number" {
        $result = Get-PhysicalDiskPercent
        $result | Should -BeGreaterOrEqual 0
    }
}

Describe "Get-VmmemMemoryMB" {
    It "returns a non-negative number" {
        $result = Get-VmmemMemoryMB
        $result | Should -BeGreaterOrEqual 0
    }
}

Describe "Test-WslIsIoCause" {
    It "returns true when VHD IO is high and disk is high" {
        $result = Test-WslIsIoCause -VhdTotalMBps 80 -PhysicalDiskPct 90 -BaselineMBps 100
        $result | Should -Be $true
    }

    It "returns false when VHD IO is low but disk is high" {
        $result = Test-WslIsIoCause -VhdTotalMBps 10 -PhysicalDiskPct 90 -BaselineMBps 100
        $result | Should -Be $false
    }
}
