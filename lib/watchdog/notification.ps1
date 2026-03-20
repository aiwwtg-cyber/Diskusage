# notification.ps1 — 토스트 알림 + 폴백

function Test-BurntToastAvailable {
    try {
        $null = Get-Module -ListAvailable -Name BurntToast -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-NotificationMethod {
    if (Test-BurntToastAvailable) {
        return "BurntToast"
    }
    return "MessageBox"
}

function Format-AlertMessage {
    param(
        [string]$Level,
        [double]$TotalMBps,
        [double]$MemoryMB
    )
    $memGB = [math]::Round($MemoryMB / 1024, 1)
    return "WSL2 Disk I/O [$Level] - I/O: ${TotalMBps}MB/s, Memory: ${memGB}GB"
}

function Send-Notification {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Level = "warn"
    )

    $method = Get-NotificationMethod

    switch ($method) {
        "BurntToast" {
            Import-Module BurntToast -ErrorAction SilentlyContinue
            New-BurntToastNotification -Text $Title, $Message -UniqueIdentifier "Diskusage"
        }
        "MessageBox" {
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show($Message, $Title, "OK", "Warning") | Out-Null
        }
    }
}

function Request-UserConfirmation {
    param(
        [string]$Title,
        [string]$Message
    )

    Add-Type -AssemblyName System.Windows.Forms
    $result = [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}
