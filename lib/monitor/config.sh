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

    # ── 메모리 압박 알림 (2026-08-06) ──────────────────────────────────────
    # 6일치 91,000 샘플 실측: 평시 최대 MEM 83.1%, 실제 압박 사건은 98.8%.
    # 90%는 그 사이 어디에도 걸리지 않는 유일한 구간이라 오탐 0건이 나온다.
    MEM_PRESSURE_PCT=90
    # 급등 판정 — 이 값 이상이면 2주기를 기다리지 않고 즉시 알린다.
    # 08-06 15:23 사건은 첫 주기에 이미 98.7%였다(9초 먼저 잡힌다).
    MEM_PRESSURE_CRIT_PCT=95
    HIDDEN_ANON_CRIT_MB=3000
    # 압박 동반 조건. 100MB/s는 danger 임계(90MB/s)보다 위 — 실제 폭주만 잡는다.
    IO_PRESSURE_KB=102400
    PRESSURE_ALERT_COOLDOWN=1800

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
            [MEM_PRESSURE_PCT]=1 [MEM_PRESSURE_CRIT_PCT]=1
            [HIDDEN_ANON_CRIT_MB]=1 [IO_PRESSURE_KB]=1 [PRESSURE_ALERT_COOLDOWN]=1
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
