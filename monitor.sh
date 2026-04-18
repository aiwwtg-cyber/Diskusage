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
    kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
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
    trap '_on_exit' EXIT TERM INT
    _MONITOR_START_EPOCH=$(date +%s)
    set_status "idle"
    rotate_logs
    local last_rotation
    last_rotation=$_MONITOR_START_EPOCH
    local prev_rd=0 prev_wr=0
    local first_read=true
    local prev_level="normal"

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

        # 메모리 Top 프로세스 추적 (warn 이상 또는 메모리 85%+)
        local mem_used mem_total mem_pct top_procs=""
        read -r mem_used mem_total <<< "$(free -m | awk '/Mem:/{print $3, $2}')"
        mem_pct=$(( mem_used * 100 / mem_total ))
        if [[ "$level" != "normal" ]] || (( mem_pct >= 85 )); then
            top_procs=$(ps aux --sort=-%mem | awk 'NR>1 && NR<=6{printf " %s(%dMB)", $11, $6/1024}')
            log_entry "VHD_IO:${total_kbps}KB/s MEM:${mem_info} LEVEL:${level} TOP:${top_procs}"
        else
            log_entry "VHD_IO:${total_kbps}KB/s MEM:${mem_info} LEVEL:${level}"
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
