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
