#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    CONFIG_DIR="$TEST_DIR/.diskusage/config"
    mkdir -p "$CONFIG_DIR"
    export DISKUSAGE_HOME="$TEST_DIR/.diskusage"

    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$PROJECT_ROOT/lib/monitor/diskstats.sh"
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
