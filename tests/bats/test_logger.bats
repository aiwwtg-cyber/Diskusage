#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    export DISKUSAGE_HOME="$TEST_DIR/.diskusage"
    mkdir -p "$DISKUSAGE_HOME/logs" "$DISKUSAGE_HOME/config"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$PROJECT_ROOT/lib/monitor/config.sh"
    load_config
    source "$PROJECT_ROOT/lib/monitor/logger.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "log_entry writes formatted line to today's log" {
    log_entry "VHD_IO:45MB/s MEM:3.2G/8G"
    local logfile="$DISKUSAGE_HOME/logs/$(date +%Y-%m-%d).log"
    [ -f "$logfile" ]
    grep -q "VHD_IO:45MB/s" "$logfile"
}

@test "log_entry includes timestamp" {
    log_entry "test message"
    local logfile="$DISKUSAGE_HOME/logs/$(date +%Y-%m-%d).log"
    grep -qE '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]' "$logfile"
}

@test "log_action writes ACTION: prefix" {
    log_action "journalctl vacuum applied"
    local logfile="$DISKUSAGE_HOME/logs/$(date +%Y-%m-%d).log"
    grep -q "ACTION: journalctl vacuum applied" "$logfile"
}

@test "rotate_logs removes files older than retention" {
    local old_date
    old_date=$(date -d "10 days ago" +%Y-%m-%d)
    touch "$DISKUSAGE_HOME/logs/${old_date}.log"
    touch "$DISKUSAGE_HOME/logs/$(date +%Y-%m-%d).log"

    LOG_RETENTION_DAYS=7
    rotate_logs

    [ ! -f "$DISKUSAGE_HOME/logs/${old_date}.log" ]
    [ -f "$DISKUSAGE_HOME/logs/$(date +%Y-%m-%d).log" ]
}

@test "rotate_logs truncates oversized log file" {
    local logfile="$DISKUSAGE_HOME/logs/$(date +%Y-%m-%d).log"
    MAX_LOG_SIZE_MB=1
    dd if=/dev/zero of="$logfile" bs=1024 count=1100 2>/dev/null
    local size_before
    size_before=$(stat -c%s "$logfile")

    rotate_logs

    local size_after
    size_after=$(stat -c%s "$logfile")
    [ "$size_after" -lt "$size_before" ]
}
