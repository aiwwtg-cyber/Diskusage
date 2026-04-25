# test-buttons.ps1 — 텔레그램 버튼 전체 흐름 검증 스크립트
# 실행: powershell -ExecutionPolicy Bypass -File test-buttons.ps1
# 검증 항목:
#   1. 버튼 메시지 발송 (sendMessage + inline_keyboard)
#   2. Telegram이 메시지 ID 반환 (정상 수신)
#   3. callback_query 수신 (사용자가 버튼 클릭)
#   4. 권한 체크 (chat_id 일치)
#   5. answerCallbackQuery (로딩 표시 제거)
#   6. 결과 메시지 발송

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\lib\watchdog\telegram.ps1"

if (-not (Initialize-Telegram)) {
    Write-Host "[FAIL] Telegram config 로드 실패" -ForegroundColor Red
    exit 1
}

Write-Host "=== Diskusage 버튼 흐름 검증 ===" -ForegroundColor Cyan
Write-Host "Bot: token loaded ($($script:TelegramBotToken.Length) chars)"
Write-Host "Chat: $script:TelegramChatId"
Write-Host ""

# Step 1: getMe로 봇 인증
Write-Host "[1/6] 봇 인증..." -ForegroundColor Yellow
try {
    $me = Invoke-RestMethod -Uri "https://api.telegram.org/bot$($script:TelegramBotToken)/getMe" -TimeoutSec 10
    if ($me.ok) {
        Write-Host "  ✅ OK: @$($me.result.username)" -ForegroundColor Green
    } else { throw "not ok" }
} catch {
    Write-Host "  ❌ FAIL: $_" -ForegroundColor Red
    exit 1
}

# Step 2: 버튼 메시지 발송 (test_ prefix로 실제 액션과 구분)
Write-Host "[2/6] 테스트 버튼 메시지 발송..." -ForegroundColor Yellow
$keyboard = '{"inline_keyboard":[[{"text":"🧪 Test Restart","callback_data":"test_restart"}],[{"text":"🧪 Test Shutdown","callback_data":"test_shutdown"}],[{"text":"🧪 Test Ignore","callback_data":"test_ignore"}]]}'
$payload = @{
    chat_id = $script:TelegramChatId
    text = "🧪 <b>Diskusage 버튼 흐름 테스트</b>`nTime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n아무 버튼이나 눌러서 응답 흐름을 검증해주세요.`n(60초 안에 클릭하지 않으면 타임아웃)"
    parse_mode = "HTML"
    reply_markup = ($keyboard | ConvertFrom-Json)
} | ConvertTo-Json -Depth 8 -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)

try {
    $sent = Invoke-RestMethod -Uri "https://api.telegram.org/bot$($script:TelegramBotToken)/sendMessage" `
        -Method Post -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 15
    if ($sent.ok) {
        Write-Host "  ✅ 발송 성공 (message_id: $($sent.result.message_id))" -ForegroundColor Green
        $sentMessageId = $sent.result.message_id
    } else { throw "not ok" }
} catch {
    Write-Host "  ❌ FAIL: $_" -ForegroundColor Red
    if ($_.ErrorDetails) { Write-Host "  $($_.ErrorDetails.Message)" -ForegroundColor Red }
    exit 1
}

# Step 3: 버튼 클릭 대기 (최대 60초)
Write-Host "[3/6] 버튼 클릭 대기 중 (60초)..." -ForegroundColor Yellow
Write-Host "  → 텔레그램에서 위 메시지의 버튼 중 하나를 눌러주세요"

# 기존 업데이트 건너뛰기
$offset = 0
try {
    $init = Invoke-RestMethod -Uri "https://api.telegram.org/bot$($script:TelegramBotToken)/getUpdates" -TimeoutSec 10
    if ($init.result -and $init.result.Count -gt 0) {
        $offset = ($init.result | ForEach-Object { $_.update_id } | Measure-Object -Maximum).Maximum + 1
    }
} catch {}

$deadline = (Get-Date).AddSeconds(60)
$callback = $null
while ((Get-Date) -lt $deadline -and -not $callback) {
    try {
        $allowed = [uri]::EscapeDataString('["callback_query"]')
        $url = "https://api.telegram.org/bot$($script:TelegramBotToken)/getUpdates?offset=$offset&timeout=10&allowed_updates=$allowed"
        $resp = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 15
        foreach ($update in $resp.result) {
            $offset = $update.update_id + 1
            if ($update.callback_query -and $update.callback_query.data -like "test_*") {
                $callback = $update.callback_query
                break
            }
        }
    } catch {
        Start-Sleep -Seconds 2
    }
}

if (-not $callback) {
    Write-Host "  ⏰ 타임아웃 (60초 동안 버튼 안 누름)" -ForegroundColor DarkYellow
    Write-Host "[FAIL] 버튼 흐름을 끝까지 검증하지 못함" -ForegroundColor Red
    exit 2
}

Write-Host "  ✅ 클릭 수신: $($callback.data)" -ForegroundColor Green

# Step 4: 권한 체크
Write-Host "[4/6] 권한 체크 (chat_id 일치)..." -ForegroundColor Yellow
if ("$($callback.message.chat.id)" -eq "$script:TelegramChatId") {
    Write-Host "  ✅ 일치: $($callback.message.chat.id)" -ForegroundColor Green
} else {
    Write-Host "  ❌ 불일치: 메시지 chat_id=$($callback.message.chat.id), 설정=$script:TelegramChatId" -ForegroundColor Red
    exit 1
}

# Step 5: answerCallbackQuery
Write-Host "[5/6] 콜백 응답 (로딩 표시 제거)..." -ForegroundColor Yellow
try {
    $ans = Invoke-RestMethod -Uri "https://api.telegram.org/bot$($script:TelegramBotToken)/answerCallbackQuery" `
        -Method Post -Body @{ callback_query_id = $callback.id; text = "테스트 OK" } -TimeoutSec 10
    if ($ans.ok) {
        Write-Host "  ✅ OK" -ForegroundColor Green
    } else { throw "not ok" }
} catch {
    Write-Host "  ❌ FAIL: $_" -ForegroundColor Red
    exit 1
}

# Step 6: 결과 메시지
Write-Host "[6/6] 결과 메시지 발송..." -ForegroundColor Yellow
$resultMsg = "✅ <b>버튼 흐름 검증 완료</b>`n클릭한 버튼: <code>$($callback.data)</code>`nTime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n`n실제 먹통 시 동일한 흐름으로 작동합니다."
Send-TelegramMessage -Message $resultMsg

Write-Host ""
Write-Host "=== 모든 검증 통과 ✅ ===" -ForegroundColor Green
Write-Host "버튼이 정상 작동합니다. 실제 먹통 시 동일한 흐름이 작동할 것입니다."
