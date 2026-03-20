#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    CONFIG_DIR="$TEST_DIR/.diskusage/config"
    mkdir -p "$CONFIG_DIR"
    export DISKUSAGE_HOME="$TEST_DIR/.diskusage"

    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$PROJECT_ROOT/lib/monitor/config.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "load_config uses defaults when no config file exists" {
    load_config
    [ "$MONITOR_INTERVAL" -eq 5 ]
    [ "$MONITOR_INTERVAL_HIGH" -eq 15 ]
    [ "$LOG_RETENTION_DAYS" -eq 7 ]
}

@test "load_config sets all 17 defaults when no config file exists" {
    load_config
    [ "$MONITOR_INTERVAL"      -eq 5     ]
    [ "$MONITOR_INTERVAL_HIGH" -eq 15    ]
    [ "$MONITOR_IO_WARN_KB"    -eq 61440 ]
    [ "$MONITOR_IO_ALERT_KB"   -eq 76800 ]
    [ "$MONITOR_IO_DANGER_KB"  -eq 92160 ]
    [ "$LOG_RETENTION_DAYS"    -eq 7     ]
    [ "$MAX_LOG_SIZE_MB"       -eq 50    ]
    [ "$WARN_THRESHOLD"        -eq 60    ]
    [ "$ALERT_THRESHOLD"       -eq 75    ]
    [ "$DANGER_THRESHOLD"      -eq 90    ]
    [ "$CRITICAL_THRESHOLD"    -eq 95    ]
    [ "$IO_BASELINE_MBPS"      -eq 100   ]
    [ "$WARN_DURATION"         -eq 30    ]
    [ "$ALERT_DURATION"        -eq 30    ]
    [ "$DANGER_DURATION"       -eq 60    ]
    [ "$CRITICAL_DURATION"     -eq 120   ]
    [ "$WSL_EXEC_TIMEOUT"      -eq 10    ]
}

@test "load_config reads user config file" {
    echo "MONITOR_INTERVAL=10" > "$CONFIG_DIR/config.conf"
    load_config
    [ "$MONITOR_INTERVAL" -eq 10 ]
    [ "$LOG_RETENTION_DAYS" -eq 7 ]
}

@test "load_config validates numeric values" {
    echo "MONITOR_INTERVAL=notanumber" > "$CONFIG_DIR/config.conf"
    load_config
    [ "$MONITOR_INTERVAL" -eq 5 ]
}

@test "load_config rejects keys not in allowlist" {
    echo "EVIL_KEY=999" > "$CONFIG_DIR/config.conf"
    load_config
    [ -z "${EVIL_KEY+x}" ] || [ "$EVIL_KEY" != "999" ]
}
