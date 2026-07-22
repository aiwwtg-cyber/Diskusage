#!/usr/bin/env bash
# config.sh — configuration loading for diskusage monitor

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
    # 루트 ns 익명 메모리(숨은 배관 init 포함) 경고 임계치.
    # 실측 평시 26MB, 2026-07-22 OOM 시점 5,600MB — 여유 있게 1500.
    HIDDEN_ANON_WARN_MB=1500
    # 루트 ns init 보호 재적용 주기(초). wsl.exe 호출 비용 때문에 매 주기는 금지.
    ROOTNS_GUARD_INTERVAL=60

    local config_file="$DISKUSAGE_HOME/config/config.conf"
    if [[ -f "$config_file" ]]; then
        local -A _ALLOWED_KEYS=(
            [MONITOR_INTERVAL]=1 [MONITOR_INTERVAL_HIGH]=1
            [MONITOR_IO_WARN_KB]=1 [MONITOR_IO_ALERT_KB]=1 [MONITOR_IO_DANGER_KB]=1
            [WARN_THRESHOLD]=1 [ALERT_THRESHOLD]=1 [DANGER_THRESHOLD]=1 [CRITICAL_THRESHOLD]=1
            [IO_BASELINE_MBPS]=1 [WARN_DURATION]=1 [ALERT_DURATION]=1
            [DANGER_DURATION]=1 [CRITICAL_DURATION]=1 [WSL_EXEC_TIMEOUT]=1
            [LOG_RETENTION_DAYS]=1 [MAX_LOG_SIZE_MB]=1
            [HIDDEN_ANON_WARN_MB]=1 [ROOTNS_GUARD_INTERVAL]=1
        )
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
            key="$(echo "$key" | tr -d '[:space:]')"
            value="$(echo "$value" | tr -d '[:space:]')"
            # Only apply if key is in the allowlist AND value is numeric
            if [[ -v "_ALLOWED_KEYS[$key]" ]] && [[ "$value" =~ ^[0-9]+$ ]]; then
                declare -g "$key=$value"
            fi
        done < "$config_file"
    fi
}
