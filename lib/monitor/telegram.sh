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

# WSL 배관 init(루트 ns, Ubuntu에선 안 보임)이 커지면 OOM killer가 이를 죽이고
# 소켓 계층이 붕괴한다. 2026-07-22 사고에서는 80초 만에 3.8GB가 불어났다.
# 관측은 숨은 익명 메모리(전역 AnonPages − Ubuntu 가시분)로 한다. 평시 ~26MB.
notify_init_bloat() {
    local hidden_mb="$1" threshold_mb="$2"
    _send_telegram "⚠️ <b>WSL 배관 프로세스 메모리 폭주 감지</b>
$(date '+%Y-%m-%d %H:%M:%S')
루트 ns 추정 사용량 <b>${hidden_mb}MB</b> (임계 ${threshold_mb}MB, 평시 ~26MB)

과거 사고에서 이 수치가 5,600MB까지 오른 뒤
WSL 전체가 붕괴했습니다. OOM 면제가 걸려 있으면
WSL은 살아남지만 다른 프로세스가 대신 종료될 수 있습니다.
호스트(Windows) 디스크·OneDrive 부하를 확인하세요."
}

# 커널의 __vm_enough_memory 경고 = OOM 붕괴의 선행 신호.
# 과거 2건에서 OOM보다 각각 2분 31초, 43분 앞서 나타났다.
notify_init_vm_pressure() {
    local count="$1"
    _send_telegram "🚨 <b>커널 메모리 할당 실패 감지</b>
$(date '+%Y-%m-%d %H:%M:%S')
__vm_enough_memory 경고 누적 ${count}회

과거 사고에서 OOM 붕괴의 2분~43분 전에
나타난 선행 신호입니다. 지금 조치하면 막을 수 있습니다:
호스트 디스크 부하 중단(OneDrive 일시중지 등) 또는
불필요한 프로세스 종료를 권합니다."
}
