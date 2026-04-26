# command-listener.ps1 — 텔레그램 명령 수신 후 워치독 시작
# 가벼운 영구 리스너: 워치독이 죽었을 때 사용자가 텔레그램으로 재시작할 수 있게 함
#
# 지원 명령:
#   /start_watchdog  — 워치독 시작 (이미 실행 중이면 안내만)
#   /watchdog_status — 워치독 실행 여부 확인

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\lib\watchdog\telegram.ps1"

if (-not (Initialize-Telegram)) {
    exit 1
}

$VbsPath = Join-Path $ScriptDir "watchdog-hidden.vbs"

function Test-WatchdogRunning {
    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.CommandLine -match 'watchdog\.ps1' -and $_.Name -eq 'powershell.exe') -or
        ($_.CommandLine -match 'watchdog-hidden\.vbs' -and $_.Name -eq 'wscript.exe')
    }
    return ($procs | Measure-Object).Count -gt 0
}

function Start-Watchdog {
    Start-Process -FilePath "wscript.exe" -ArgumentList "`"$VbsPath`"" -WindowStyle Hidden | Out-Null
}

function _ListenerLog {
    param([string]$Message)
    $logDir = "$env:USERPROFILE\.diskusage\logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir "listener-$(Get-Date -Format 'yyyy-MM-dd').log"
    $ts = Get-Date -Format "HH:mm:ss"
    "[$ts] $Message" | Out-File -Append -FilePath $logFile -Encoding utf8
}

_ListenerLog "Command listener started"

# 시작 시 한 번 시작 알림 (선택 사항)
# Send-TelegramMessage -Message "🎧 <b>Command Listener Started</b>`n명령: /start_watchdog, /watchdog_status"

# 기존 업데이트 건너뛰기
$offset = 0
try {
    $init = Invoke-RestMethod -Uri "https://api.telegram.org/bot$($script:TelegramBotToken)/getUpdates" -TimeoutSec 10
    if ($init.result -and $init.result.Count -gt 0) {
        $offset = ($init.result | ForEach-Object { $_.update_id } | Measure-Object -Maximum).Maximum + 1
    }
} catch {
    _ListenerLog "Initial offset fetch failed: $($_.Exception.Message)"
}

# 워치독 죽음 감지 상태
$watchdogDeadAlertSent = $false
$lastWatchdogCheck = Get-Date

while ($true) {
    # 워치독 헬스체크 (1분마다)
    if (((Get-Date) - $lastWatchdogCheck).TotalSeconds -ge 60) {
        $lastWatchdogCheck = Get-Date
        if (-not (Test-WatchdogRunning)) {
            if (-not $watchdogDeadAlertSent) {
                $watchdogDeadAlertSent = $true
                _ListenerLog "Watchdog DOWN detected"
                $kbd = '{"inline_keyboard":[[{"text":"🔄 지금 시작","callback_data":"listener_start_watchdog"}],[{"text":"❌ 무시","callback_data":"listener_ignore"}]]}'
                $payload = @{
                    chat_id = $script:TelegramChatId
                    text = "⚠️ <b>Windows Watchdog 정지됨</b>`nTime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n워치독 프로세스가 감지되지 않습니다.`n버튼을 누르거나 <code>/start_watchdog</code> 명령을 보내세요."
                    parse_mode = "HTML"
                    reply_markup = ($kbd | ConvertFrom-Json)
                } | ConvertTo-Json -Depth 8 -Compress
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                try {
                    Invoke-RestMethod -Uri "https://api.telegram.org/bot$($script:TelegramBotToken)/sendMessage" `
                        -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 15 | Out-Null
                } catch {
                    _ListenerLog "Failed to send watchdog-down alert: $($_.Exception.Message)"
                }
            }
        } else {
            if ($watchdogDeadAlertSent) {
                _ListenerLog "Watchdog restored"
                Send-TelegramMessage -Message "🟢 <b>워치독 다시 실행 중</b>`nTime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                $watchdogDeadAlertSent = $false
            }
        }
    }

    try {
        $allowed = [uri]::EscapeDataString('["message","callback_query"]')
        $url = "https://api.telegram.org/bot$($script:TelegramBotToken)/getUpdates?offset=$offset&timeout=30&allowed_updates=$allowed"
        $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 35

        foreach ($update in $resp.result) {
            $offset = $update.update_id + 1

            # 콜백 버튼 처리 (워치독 다운 알림의 버튼)
            if ($update.callback_query) {
                $cq = $update.callback_query
                if ("$($cq.message.chat.id)" -ne "$script:TelegramChatId") { continue }
                try {
                    Invoke-RestMethod -Uri "https://api.telegram.org/bot$($script:TelegramBotToken)/answerCallbackQuery" `
                        -Method Post -Body @{ callback_query_id = $cq.id } -TimeoutSec 10 | Out-Null
                } catch {}
                if ($cq.data -eq "listener_start_watchdog") {
                    if (Test-WatchdogRunning) {
                        Send-TelegramMessage -Message "ℹ️ 이미 실행 중입니다."
                    } else {
                        Start-Watchdog
                        Start-Sleep -Seconds 4
                        if (Test-WatchdogRunning) {
                            Send-TelegramMessage -Message "✅ <b>워치독 시작됨</b>"
                        } else {
                            Send-TelegramMessage -Message "❌ 워치독 시작 실패"
                        }
                    }
                }
                continue
            }

            if (-not $update.message) { continue }

            $msg = $update.message
            # 권한: 등록된 chat_id만
            if ("$($msg.chat.id)" -ne "$script:TelegramChatId") { continue }

            $text = $msg.text
            if (-not $text) { continue }

            switch -Regex ($text) {
                '^/start_watchdog\b' {
                    if (Test-WatchdogRunning) {
                        _ListenerLog "/start_watchdog: already running"
                        Send-TelegramMessage -Message "ℹ️ 워치독이 이미 실행 중입니다."
                    } else {
                        Start-Watchdog
                        Start-Sleep -Seconds 4
                        if (Test-WatchdogRunning) {
                            _ListenerLog "/start_watchdog: started successfully"
                            Send-TelegramMessage -Message "✅ <b>워치독 시작됨</b>`nTime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                        } else {
                            _ListenerLog "/start_watchdog: start failed (process not detected after 4s)"
                            Send-TelegramMessage -Message "❌ <b>워치독 시작 실패</b>`n프로세스가 감지되지 않습니다. 로그 확인 필요."
                        }
                    }
                }
                '^/watchdog_status\b' {
                    if (Test-WatchdogRunning) {
                        Send-TelegramMessage -Message "🟢 워치독 실행 중"
                    } else {
                        Send-TelegramMessage -Message "🔴 워치독 정지됨`n/start_watchdog 명령으로 시작할 수 있습니다."
                    }
                }
            }
        }
    } catch {
        _ListenerLog "Polling error: $($_.Exception.Message)"
        Start-Sleep -Seconds 5
    }
}
