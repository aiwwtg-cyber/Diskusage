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
        [string]$Message,
        [string]$ReplyMarkupJson = $null,
        [int]$MaxAttempts = 3
    )

    if (-not $script:TelegramBotToken -or -not $script:TelegramChatId) {
        _TelegramLog "[SKIP] Token or ChatID missing"
        return
    }

    $url = "https://api.telegram.org/bot$($script:TelegramBotToken)/sendMessage"
    $body = @{
        chat_id = $script:TelegramChatId
        text = $Message
        parse_mode = "HTML"
    }
    if ($ReplyMarkupJson) {
        $body.reply_markup = $ReplyMarkupJson
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Invoke-RestMethod -Uri $url -Method Post -Body $body -TimeoutSec 15 | Out-Null
            if ($attempt -gt 1) { _TelegramLog "[OK] sent on retry #$attempt" }
            return
        }
        catch {
            _TelegramLog "[ERROR attempt $attempt/$MaxAttempts] $($_.Exception.Message)"
            if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds (2 * $attempt) }
        }
    }
    _TelegramLog "[FAIL] gave up after $MaxAttempts attempts"
}

function _TelegramLog {
    param([string]$Message)
    $logDir = "$env:USERPROFILE\.diskusage\logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir "telegram-$(Get-Date -Format 'yyyy-MM-dd').log"
    $ts = Get-Date -Format "HH:mm:ss"
    "[$ts] $Message" | Out-File -Append -FilePath $logFile -Encoding utf8
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

어떻게 할까요? (5분 내 선택)
"@
    $keyboard = @{
        inline_keyboard = @(
            ,@( @{ text = "🔄 Shutdown + Restart"; callback_data = "wsl_restart" } ),
            ,@( @{ text = "🛑 Just Shutdown";      callback_data = "wsl_shutdown" } ),
            ,@( @{ text = "❌ Ignore";             callback_data = "ignore" } )
        )
    } | ConvertTo-Json -Depth 5 -Compress
    Send-TelegramMessage -Message $msg -ReplyMarkupJson $keyboard
}

function Start-TelegramCallbackListener {
    # WSL 먹통 시 버튼 클릭 대기 (백그라운드 job)
    # 버튼 클릭되면 해당 액션을 자동 실행
    param([int]$TimeoutSec = 300)

    $token = $script:TelegramBotToken
    $chatId = $script:TelegramChatId

    if (-not $token -or -not $chatId) {
        return $null
    }

    Start-Job -Name "DiskusageCallback" -ScriptBlock {
        param($token, $chatId, $timeoutSec)

        function Send-Msg($text) {
            try {
                Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" `
                    -Method Post `
                    -Body @{ chat_id = $chatId; text = $text; parse_mode = "HTML" } `
                    -TimeoutSec 10 | Out-Null
            } catch {}
        }

        # 기존 업데이트 건너뛰기 위한 초기 offset 설정
        $offset = 0
        try {
            $init = Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/getUpdates" -Method Get -TimeoutSec 10
            if ($init.result -and $init.result.Count -gt 0) {
                $offset = ($init.result | ForEach-Object { $_.update_id } | Measure-Object -Maximum).Maximum + 1
            }
        } catch {}

        $deadline = (Get-Date).AddSeconds($timeoutSec)

        while ((Get-Date) -lt $deadline) {
            try {
                $allowed = [uri]::EscapeDataString('["callback_query"]')
                $url = "https://api.telegram.org/bot$token/getUpdates?offset=$offset&timeout=25&allowed_updates=$allowed"
                $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 30
                foreach ($update in $response.result) {
                    $offset = $update.update_id + 1
                    if (-not $update.callback_query) { continue }

                    $cq = $update.callback_query
                    if ("$($cq.message.chat.id)" -ne "$chatId") { continue }

                    # 버튼 클릭 응답 (로딩 표시 제거)
                    try {
                        Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/answerCallbackQuery" `
                            -Method Post `
                            -Body @{ callback_query_id = $cq.id } `
                            -TimeoutSec 10 | Out-Null
                    } catch {}

                    $action = $cq.data

                    switch ($action) {
                        "wsl_restart" {
                            Send-Msg "🔄 <b>WSL Shutdown + Restart 실행 중...</b>"
                            & wsl --shutdown 2>&1 | Out-Null
                            Start-Sleep -Seconds 3
                            # 백그라운드로 WSL 재시작 + 모니터 자동 시작
                            Start-Process -FilePath "wsl.exe" `
                                -ArgumentList '-e','bash','-c','cd ~/project/Diskusage && ./monitor.sh start' `
                                -WindowStyle Hidden -Wait
                            Send-Msg "✅ <b>WSL 재시작 완료</b>`nMonitor 자동 시작됨"
                            return "wsl_restart"
                        }
                        "wsl_shutdown" {
                            Send-Msg "🛑 <b>WSL Shutdown 실행 중...</b>"
                            & wsl --shutdown 2>&1 | Out-Null
                            Send-Msg "⚫ <b>WSL 종료 완료</b>"
                            return "wsl_shutdown"
                        }
                        "ignore" {
                            Send-Msg "❌ 무시 선택됨"
                            return "ignore"
                        }
                    }
                }
            } catch {
                Start-Sleep -Seconds 3
            }
        }

        Send-Msg "⏰ <b>선택 타임아웃 (5분)</b>`n자동 작업 없이 대기합니다."
        return "timeout"
    } -ArgumentList $token, $chatId, $TimeoutSec
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
