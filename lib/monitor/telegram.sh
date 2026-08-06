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

# 메모리 압박 알림 (2026-08-06 재설계).
#
# 이전에는 두 개의 알림이 따로 있었다:
#   - notify_init_bloat        : HID 단독 임계 (3주기 요건에 걸려 실제 사건을 놓침)
#   - notify_init_vm_pressure  : __vm_enough_memory 누적 증가 (8일 121건 발사, 실사건 0건)
# 둘 다 폐기하고 실제 압박 지표로 통합했다. 근거는
# docs/plans/2026-08-06-alert-precision-fix.md 참조.
#
# 커널 경고 개수는 판정에서 뺐지만 본문에는 남긴다 — 사후 분석에 유용하고,
# 사용자가 "지금 무슨 일이 벌어지는가"를 한 화면에서 읽을 수 있다.
notify_memory_pressure() {
    local mem_pct="$1" mem_used="$2" mem_total="$3" io_kb="$4" hidden_mb="$5" vmw_burst="$6"
    local io_mb=$(( io_kb / 1024 ))
    # "평시 26MB"는 기준선으로 쓰지 않는다 — 그 값 자체가 RssAnon 이중계상 총량에
    # 의존하는 우연한 수치임이 2026-08-06에 밝혀졌다. 임계 대비로만 표현한다.
    local hid_line
    if (( hidden_mb < 0 )); then
        hid_line="숨은 메모리: 측정 불가 (이중계상)"
    else
        hid_line="숨은 메모리: <b>${hidden_mb}MB</b> (임계 ${HIDDEN_ANON_WARN_MB}MB)"
    fi
    # 직전에 '완료된' 60초 창의 값이다(최대 60초 지연). 판정에 안 쓰는 참고 정보라
    # 슬라이딩 창까지는 구현하지 않았으므로 문구로 그 사실을 드러낸다.
    local vmw_line=""
    (( vmw_burst > 0 )) && vmw_line="
커널 할당 실패: 직전 60초 창에서 ${vmw_burst}회"

    _send_telegram "🚨 <b>WSL 메모리 압박</b>
$(date '+%Y-%m-%d %H:%M:%S')
메모리: <b>${mem_pct}%</b> (${mem_used}M / ${mem_total}M)
디스크 I/O: <b>${io_mb}MB/s</b>
${hid_line}${vmw_line}

과거 이 상태에서 WSL 배관 프로세스가 OOM으로 죽어
소켓 계층 전체가 붕괴했습니다(2026-07-22, 2회).
호스트(Windows) 디스크 부하를 줄이면 완화됩니다."
}
