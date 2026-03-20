BeforeAll {
    . "$PSScriptRoot/../../lib/watchdog/notification.ps1"
}

Describe "Test-BurntToastAvailable" {
    It "returns a boolean" {
        $result = Test-BurntToastAvailable
        $result | Should -BeOfType [bool]
    }
}

Describe "Get-NotificationMethod" {
    It "returns 'BurntToast' or 'MessageBox'" {
        $result = Get-NotificationMethod
        $result | Should -BeIn @("BurntToast", "MessageBox")
    }
}

Describe "Format-AlertMessage" {
    It "includes level and I/O info" {
        $msg = Format-AlertMessage -Level "danger" -TotalMBps 95.5 -MemoryMB 4096
        $msg | Should -Match "danger"
        $msg | Should -Match "95"
    }
}
