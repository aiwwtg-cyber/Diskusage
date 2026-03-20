#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    export DISKUSAGE_HOME="$TEST_DIR/.diskusage"
    mkdir -p "$DISKUSAGE_HOME/logs" "$DISKUSAGE_HOME/config"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export MONITOR_SCRIPT="$PROJECT_ROOT/monitor.sh"
}

teardown() {
    if [[ -f "$DISKUSAGE_HOME/monitor.pid" ]]; then
        local pid
        pid=$(cat "$DISKUSAGE_HOME/monitor.pid")
        kill "$pid" 2>/dev/null || true
        rm -f "$DISKUSAGE_HOME/monitor.pid"
    fi
    rm -rf "$TEST_DIR"
}

@test "monitor.sh start creates pid file" {
    bash "$MONITOR_SCRIPT" start
    sleep 2
    [ -f "$DISKUSAGE_HOME/monitor.pid" ]
    local pid
    pid=$(cat "$DISKUSAGE_HOME/monitor.pid")
    kill -0 "$pid" 2>/dev/null
}

@test "monitor.sh status shows running when started" {
    bash "$MONITOR_SCRIPT" start
    sleep 2
    local output
    output=$(bash "$MONITOR_SCRIPT" status)
    [[ "$output" == *"running"* ]]
}

@test "monitor.sh stop kills the process and removes pid file" {
    bash "$MONITOR_SCRIPT" start
    sleep 2
    bash "$MONITOR_SCRIPT" stop
    sleep 1
    [ ! -f "$DISKUSAGE_HOME/monitor.pid" ]
}

@test "monitor.sh status shows stopped when not running" {
    local output
    output=$(bash "$MONITOR_SCRIPT" status)
    [[ "$output" == *"stopped"* ]]
}

@test "monitor.sh start writes status file" {
    bash "$MONITOR_SCRIPT" start
    sleep 3
    [ -f "$DISKUSAGE_HOME/status" ]
    local status
    status=$(cat "$DISKUSAGE_HOME/status")
    [[ "$status" == "monitoring" || "$status" == "idle" ]]
}

@test "monitor.sh detects stale pid file" {
    echo "99999" > "$DISKUSAGE_HOME/monitor.pid"
    local output
    output=$(bash "$MONITOR_SCRIPT" status)
    [[ "$output" == *"stopped"* ]]
}
