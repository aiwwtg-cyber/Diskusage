# telegram.ps1 — Windows 측 텔레그램 알림

$script:TelegramBotToken = ""
$script:TelegramChatId = ""

function Initialize-Telegram {
    param(
        [string]$ConfigPath = "$env:USERPROFILE\.diskusage\config\telegram.conf"
    )

    if (-not (Test-Path $ConfigPath)) {
        Write-Host "[WARNING] Telegram config not found: $ConfigPath" -ForegroundColor Yellow
        return $false
    }

    Get-Content $ConfigPath | ForEach-Object {
        if ($_ -match "^BOT_TOKEN=(.+)$") {
            $script:TelegramBotToken = $matches[1].Trim().Trim('"').Trim("'")
        }
        elseif ($_ -match "^CHAT_ID=(.+)$") {
            $script:TelegramChatId = $matches[1].Trim()
        }
    }

    if (-not $script:TelegramBotToken -or -not $script:TelegramChatId) {
        Write-Host "[WARNING] Telegram config incomplete (missing BOT_TOKEN or CHAT_ID)" -ForegroundColor Yellow
        return $false
    }

    return $true
}

function Send-TelegramMessage {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message
    )

    if (-not $script:TelegramBotToken -or -not $script:TelegramChatId) {
        return
    }

    try {
        $url = "https://api.telegram.org/bot$($script:TelegramBotToken)/sendMessage"
        $body = @{
            chat_id = $script:TelegramChatId
            text = $Message
            parse_mode = "HTML"
        }
        Invoke-RestMethod -Uri $url -Method Post -Body $body -TimeoutSec 10 | Out-Null
    }
    catch {
        Write-Host "[ERROR] Telegram send failed: $_" -ForegroundColor Red
    }
}

function Send-WslFrozenAlert {
    param(
        [double]$TotalMBps,
        [double]$DiskPct,
        [double]$MemoryMB
    )
    $memGB = [math]::Round($MemoryMB / 1024, 1)
    $msg = @"
🔴 <b>WSL 먹통 감지</b>
Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
VHD I/O: $TotalMBps MB/s
Disk: $DiskPct%
Memory: ${memGB}GB
<code>wsl -e</code> 응답 없음
"@
    Send-TelegramMessage -Message $msg
}

function Send-WslRecoveredAlert {
    $msg = @"
✅ <b>WSL 복구됨</b>
Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@
    Send-TelegramMessage -Message $msg
}

function Send-WatchdogStarted {
    $msg = @"
🟢 <b>Windows Watchdog Started</b>
Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@
    Send-TelegramMessage -Message $msg
}

function Send-WatchdogStopped {
    $msg = @"
⚫ <b>Windows Watchdog Stopped</b>
Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@
    Send-TelegramMessage -Message $msg
}
