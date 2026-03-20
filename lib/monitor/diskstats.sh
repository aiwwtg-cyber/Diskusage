#!/usr/bin/env bash
# diskstats.sh — /proc/diskstats 파싱 + 설정 로딩

DISKUSAGE_HOME="${DISKUSAGE_HOME:-$HOME/.diskusage}"

load_config() {
    # defaults
    MONITOR_INTERVAL=5
    MONITOR_INTERVAL_HIGH=15
    MONITOR_IO_WARN_KB=61440
    MONITOR_IO_ALERT_KB=76800
    MONITOR_IO_DANGER_KB=92160
    LOG_RETENTION_DAYS=7
    MAX_LOG_SIZE_MB=50
    WARN_THRESHOLD=60
    ALERT_THRESHOLD=75
    DANGER_THRESHOLD=90
    CRITICAL_THRESHOLD=95
    IO_BASELINE_MBPS=100
    WARN_DURATION=30
    ALERT_DURATION=30
    DANGER_DURATION=60
    CRITICAL_DURATION=120
    WSL_EXEC_TIMEOUT=10

    local config_file="$DISKUSAGE_HOME/config/config.conf"
    if [[ -f "$config_file" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
            key="$(echo "$key" | tr -d '[:space:]')"
            value="$(echo "$value" | tr -d '[:space:]')"
            if [[ "$value" =~ ^[0-9]+$ ]]; then
                declare -g "$key=$value"
            fi
        done < "$config_file"
    fi
}
