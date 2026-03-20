#!/usr/bin/env bash
# logger.sh — 로깅 + 로그 로테이션

_log_dir="$DISKUSAGE_HOME/logs"

_get_logfile() {
    echo "$_log_dir/$(date +%Y-%m-%d).log"
}

log_entry() {
    local msg="$1"
    local ts
    ts="[$(date +%H:%M:%S)]"
    echo "$ts $msg" >> "$(_get_logfile)"
}

log_action() {
    log_entry "ACTION: $1"
}

log_external() {
    log_entry "EXTERNAL: $1"
}

rotate_logs() {
    local cutoff_date
    cutoff_date=$(date -d "$LOG_RETENTION_DAYS days ago" +%Y-%m-%d)

    for f in "$_log_dir"/*.log; do
        [[ -f "$f" ]] || continue
        local basename
        basename="$(basename "$f" .log)"
        if [[ "$basename" < "$cutoff_date" ]]; then
            rm -f "$f"
        fi
    done

    local logfile
    logfile="$(_get_logfile)"
    if [[ -f "$logfile" ]]; then
        local max_bytes=$(( MAX_LOG_SIZE_MB * 1024 * 1024 ))
        local size
        size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
        if (( size > max_bytes )); then
            tail -c "$max_bytes" "$logfile" > "${logfile}.tmp"
            mv "${logfile}.tmp" "$logfile"
        fi
    fi
}
