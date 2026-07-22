#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISKUSAGE_HOME="${DISKUSAGE_HOME:-$HOME/.diskusage}"
PID_FILE="$DISKUSAGE_HOME/monitor.pid"
STATUS_FILE="$DISKUSAGE_HOME/status"

# source libraries
source "$SCRIPT_DIR/lib/monitor/config.sh"
source "$SCRIPT_DIR/lib/monitor/diskstats.sh"
source "$SCRIPT_DIR/lib/monitor/logger.sh"
source "$SCRIPT_DIR/lib/monitor/cleanup.sh"
source "$SCRIPT_DIR/lib/monitor/telegram.sh"
source "$SCRIPT_DIR/lib/monitor/init-guard.sh"

load_config
load_telegram_config

set_status() {
    echo "$1" > "$STATUS_FILE"
}

is_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            local cmd
            cmd=$(ps -p "$pid" -o comm= 2>/dev/null || true)
            if [[ "$cmd" == "bash" || "$cmd" == "monitor.sh" ]]; then
                return 0
            fi
        fi
        rm -f "$PID_FILE"
    fi
    return 1
}

do_start() {
    if is_running; then
        echo "monitor is already running (pid: $(cat "$PID_FILE"))"
        exit 1
    fi
    mkdir -p "$DISKUSAGE_HOME/logs" "$DISKUSAGE_HOME/config"
    echo "starting monitor..."
    _monitor_loop >/dev/null 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    echo "monitor started (pid: $pid)"
    # 디바운스: 60초 이상 실행되어야만 Started 알림 (짧게 죽는 사이클 스팸 방지)
    _notify_after_debounce "$pid" &
}

_notify_after_debounce() {
    local pid="$1"
    local delay=60
    sleep "$delay"
    # 여전히 실행 중이면 알림 발송
    if kill -0 "$pid" 2>/dev/null; then
        # 그리고 여전히 등록된 pid인지 확인
        if [[ -f "$PID_FILE" ]] && [[ "$(cat "$PID_FILE")" == "$pid" ]]; then
            notify_monitor_started
        fi
    fi
}

do_stop() {
    if ! is_running; then
        echo "monitor is not running"
        return 0
    fi
    local pid
    pid=$(cat "$PID_FILE")
    echo "stopping monitor (pid: $pid)..."
    # 그룹 kill이 성공해도 대상 PID가 다른 그룹에 있으면 살아남는다.
    # 단축평가(||)로 두면 그룹 kill 성공 시 개별 kill을 건너뛰어 고아가 남는다.
    # 2026-07-22: 이 경로로 4.4시간짜리 고아 monitor가 중복 실행 중이었음.
    kill -- "-$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE" "$STATUS_FILE"
    echo "monitor stopped"
}

do_status() {
    if is_running; then
        echo "monitor is running (pid: $(cat "$PID_FILE"))"
        return 0
    else
        echo "monitor is stopped"
        return 1
    fi
}

do_report() {
    local logfile="$DISKUSAGE_HOME/logs/$(date +%Y-%m-%d).log"
    if [[ ! -f "$logfile" ]]; then
        echo "no log for today"
        return 0
    fi
    echo "=== Diskusage Report $(date +%Y-%m-%d) ==="
    echo ""
    echo "--- Actions taken ---"
    grep "ACTION:" "$logfile" 2>/dev/null || echo "(none)"
    echo ""
    echo "--- External pressure events ---"
    grep "EXTERNAL:" "$logfile" 2>/dev/null || echo "(none)"
    echo ""
    echo "--- Peak I/O (top 5 entries) ---"
    grep "VHD_IO:" "$logfile" 2>/dev/null | sort -t: -k2 -rn | head -5 || echo "(none)"
    echo ""
    echo "--- Log size ---"
    du -h "$logfile"
}

_monitor_loop() {
    # trap을 걸면 시그널의 기본 동작(종료)이 사라진다. 핸들러에서 명시적으로
    # exit하지 않으면 SIGTERM을 받고도 루프가 계속 돌아 고아가 남는다.
    # 2026-07-22: 이 누락으로 do_stop이 "stopped"를 출력해도 실제로는 죽지 않았음.
    trap '_on_exit; exit' EXIT TERM INT
    _MONITOR_START_EPOCH=$(date +%s)
    set_status "idle"
    rotate_logs
    local last_rotation
    last_rotation=$_MONITOR_START_EPOCH
    local prev_rd=0 prev_wr=0
    local first_read=true
    local prev_level="normal"
    local hidden_warned=false hidden_high_streak=0 hidden_last_alert=0
    local last_rootns=0 rootns_big_seen=false
    # 부팅 이전부터 쌓인 커널 경고에는 알리지 않도록 현재 카운트로 초기화
    local vmw_prev vmw_last_alert=0
    vmw_prev=$(dmesg 2>/dev/null | grep -c '__vm_enough_memory')

    while true; do
        local stats
        stats=$(read_diskstats)
        local curr_rd curr_wr
        read -r curr_rd curr_wr <<< "$stats"

        if $first_read; then
            prev_rd=$curr_rd
            prev_wr=$curr_wr
            first_read=false
            sleep "$MONITOR_INTERVAL"
            continue
        fi

        local io_result
        io_result=$(calc_io_kbps "$prev_rd" "$prev_wr" "$curr_rd" "$curr_wr" "$MONITOR_INTERVAL")
        local rd_kbps wr_kbps total_kbps
        read -r rd_kbps wr_kbps total_kbps <<< "$io_result"

        local level
        level=$(get_io_level "$total_kbps")

        local mem_info
        mem_info=$(free -m | awk '/Mem:/{printf "%dM/%dM", $3, $2} /Swap:/{printf " SWAP:%dM/%dM", $3, $2}')

        # 루트 ns 숨은 익명 메모리 = OOM 희생자였던 배관 init의 비대 게이지.
        # 사고 시 프로세스가 소멸해 부검이 불가능하므로 상시 기록이 유일한 증거다.
        local hidden_mb
        hidden_mb=$(get_hidden_anon_mb)

        # 메모리 Top 프로세스 추적 (warn 이상 또는 메모리 85%+)
        local mem_used mem_total mem_pct top_procs=""
        read -r mem_used mem_total <<< "$(free -m | awk '/Mem:/{print $3, $2}')"
        mem_pct=$(( mem_used * 100 / mem_total ))
        if [[ "$level" != "normal" ]] || (( mem_pct >= 85 )); then
            top_procs=$(ps aux --sort=-%mem | awk 'NR>1 && NR<=6{printf " %s(%dMB)", $11, $6/1024}')
            log_entry "VHD_IO:${total_kbps}KB/s MEM:${mem_info} HID:${hidden_mb}MB LEVEL:${level} TOP:${top_procs}"
        else
            log_entry "VHD_IO:${total_kbps}KB/s MEM:${mem_info} HID:${hidden_mb}MB LEVEL:${level}"
        fi

        local now_epoch
        now_epoch=$(date +%s)

        # 실제 폭주는 수십 초 이상 지속되므로 3주기 연속일 때만 판정한다
        # (1주기짜리 스파이크 = 측정 경합 잔재, 2026-07-22 가짜 경보 3건).
        # 알림은 30분 쿨다운, 임계치의 80% 아래로 내려가야 재무장.
        if (( hidden_mb >= HIDDEN_ANON_WARN_MB )); then
            hidden_high_streak=$(( hidden_high_streak + 1 ))
            if (( hidden_high_streak >= 3 )) && [[ "$hidden_warned" == false ]]; then
                log_entry "HIDDEN_BLOAT: root-ns anon ${hidden_mb}MB >= ${HIDDEN_ANON_WARN_MB}MB (${hidden_high_streak} cycles)"
                if (( now_epoch - hidden_last_alert >= 1800 )); then
                    notify_init_bloat "$hidden_mb" "$HIDDEN_ANON_WARN_MB"
                    hidden_last_alert=$now_epoch
                fi
                hidden_warned=true
            fi
        else
            hidden_high_streak=0
            if (( hidden_mb < HIDDEN_ANON_WARN_MB * 80 / 100 )); then
                hidden_warned=false
            fi
        fi

        # 커널 __vm_enough_memory = OOM 붕괴의 선행 신호(과거 2건에서 2분~43분 전).
        # 카운트 감소는 링버퍼 순환이므로 기준점만 갱신한다.
        local vmw
        vmw=$(dmesg 2>/dev/null | grep -c '__vm_enough_memory')
        if (( vmw > vmw_prev )); then
            log_entry "KERNEL_VM_PRESSURE: __vm_enough_memory ${vmw_prev} -> ${vmw}"
            if (( now_epoch - vmw_last_alert >= 600 )); then
                notify_init_vm_pressure "$vmw"
                vmw_last_alert=$now_epoch
            fi
        fi
        (( vmw != vmw_prev )) && vmw_prev=$vmw

        # 루트 ns 배관 init 보호 재적용. 배관 init은 세션 형태에 따라 늦게
        # 생성될 수 있어(이번 부팅엔 아직 없음) 1회성 보호로는 놓친다.
        # 호스트 정체 중엔 wsl.exe가 못 돌아오므로 평시에 걸어두는 게 요점.
        if (( now_epoch - last_rootns >= ROOTNS_GUARD_INTERVAL )); then
            last_rootns=$now_epoch
            local rootns_out big_info
            rootns_out=$(rootns_init_guard protect || true)
            big_info=$(awk '{split($2,v,"="); split($3,r,"="); split($4,a,"=");
                            if (v[2]+0 >= 4000000) printf "pid=%s rss=%dMB adj=%s", $1, r[2]/1024, a[2]}' \
                       <<< "$rootns_out" | head -1)
            if [[ -n "$big_info" ]]; then
                if [[ "$rootns_big_seen" == false ]]; then
                    log_entry "ROOTNS_GUARD: plumbing init detected, protected ($big_info)"
                    rootns_big_seen=true
                elif [[ "$big_info" != *"adj=-1000"* ]]; then
                    log_entry "ROOTNS_GUARD: protect FAILED ($big_info)"
                fi
            else
                rootns_big_seen=false
            fi
        fi

        if [[ "$level" != "normal" ]]; then
            set_status "cleaning"
            run_cleanup "$level"
            set_status "monitoring"
            prev_level="$level"
        else
            prev_level="normal"
            set_status "idle"
        fi

        prev_rd=$curr_rd
        prev_wr=$curr_wr

        local now
        now=$(date +%s)
        if (( now - last_rotation > 3600 )); then
            rotate_logs
            last_rotation=$now
        fi

        local interval=$MONITOR_INTERVAL
        if [[ "$level" == "alert" || "$level" == "danger" ]]; then
            interval=$MONITOR_INTERVAL_HIGH
        fi
        sleep "$interval"
    done
}

_on_exit() {
    # TERM 핸들러의 exit가 EXIT trap을 다시 부르므로 재진입을 막는다.
    [[ -n "${_MONITOR_EXITING:-}" ]] && return
    _MONITOR_EXITING=1
    # 디바운스: 60초 이상 살아있었을 때만 Stopped 알림 (짧은 사이클 스팸 방지)
    local now
    now=$(date +%s)
    local uptime=$(( now - ${_MONITOR_START_EPOCH:-$now} ))
    if (( uptime >= 60 )); then
        notify_monitor_stopped
    fi
    local own_pid=$$
    if [[ -f "$PID_FILE" ]] && [[ "$(cat "$PID_FILE" 2>/dev/null)" == "$own_pid" ]]; then
        rm -f "$PID_FILE" "$STATUS_FILE"
    fi
}

case "${1:-}" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
    report) do_report ;;
    *)      echo "Usage: $0 {start|stop|status|report}" ; exit 1 ;;
esac
