#!/usr/bin/env bash
# telegram.sh — 텔레그램 알림

_TELEGRAM_BOT_TOKEN=""
_TELEGRAM_CHAT_ID=""

load_telegram_config() {
    # Diskusage 전용 봇 설정 (~/.diskusage/config/telegram.conf 우선)
    local tg_conf="$DISKUSAGE_HOME/config/telegram.conf"
    if [[ -f "$tg_conf" ]]; then
        _TELEGRAM_BOT_TOKEN=$(grep '^BOT_TOKEN=' "$tg_conf" | cut -d= -f2- | tr -d '[:space:]' | tr -d '"' | tr -d "'")
        _TELEGRAM_CHAT_ID=$(grep '^CHAT_ID=' "$tg_conf" | cut -d= -f2 | tr -d '[:space:]')
    fi

    # 폴백: Chatbot 프로젝트 .env (하위 호환)
    if [[ -z "$_TELEGRAM_BOT_TOKEN" ]]; then
        local chatbot_env="$HOME/project/Chatbot/.env"
        if [[ -f "$chatbot_env" ]]; then
            _TELEGRAM_BOT_TOKEN=$(grep TELEGRAM_BOT_TOKEN "$chatbot_env" | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)
        fi
    fi
}

_send_telegram() {
    local msg="$1"
    [[ -z "$_TELEGRAM_BOT_TOKEN" || -z "$_TELEGRAM_CHAT_ID" ]] && return 0
    curl -s -X POST "https://api.telegram.org/bot${_TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="$_TELEGRAM_CHAT_ID" \
        -d text="$msg" \
        -d parse_mode="HTML" \
        --max-time 5 >/dev/null 2>&1
}

notify_monitor_started() {
    _send_telegram "✅ <b>Diskusage Monitor Started</b>
$(date '+%Y-%m-%d %H:%M:%S')
PID: $$"
}

notify_monitor_stopped() {
    _send_telegram "🛑 <b>Diskusage Monitor Stopped</b>
$(date '+%Y-%m-%d %H:%M:%S')"
}

# /init이 계속 커지면 OOM killer가 이를 죽이고 WSL 소켓 계층이 붕괴한다.
# 2026-07-22 사고에서는 80초 만에 3.8GB가 불어나 두 번 다 손쓸 틈이 없었다.
notify_init_bloat() {
    local rss_mb="$1" threshold_mb="$2"
    _send_telegram "⚠️ <b>WSL /init 메모리 폭주 감지</b>
$(date '+%Y-%m-%d %H:%M:%S')
현재 <b>${rss_mb}MB</b> (임계치 ${threshold_mb}MB)

OOM 면제가 걸려 있어 WSL이 죽지는 않지만,
다른 프로세스가 대신 종료될 수 있습니다.
호스트(Windows) 디스크 부하를 확인하세요."
}
