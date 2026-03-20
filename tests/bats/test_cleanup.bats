#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    export DISKUSAGE_HOME="$TEST_DIR/.diskusage"
    mkdir -p "$DISKUSAGE_HOME/logs" "$DISKUSAGE_HOME/config"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$PROJECT_ROOT/lib/monitor/config.sh"
    load_config
    source "$PROJECT_ROOT/lib/monitor/logger.sh"
    source "$PROJECT_ROOT/lib/monitor/cleanup.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "cleanup_tmp removes old temp files" {
    local tmpfile
    tmpfile=$(mktemp "$TEST_DIR/tmp.XXXXXX")
    touch -d "3 days ago" "$tmpfile"

    TMP_DIRS="$TEST_DIR"
    cleanup_tmp
    [ ! -f "$tmpfile" ]
}

@test "cleanup_tmp preserves recent files" {
    local tmpfile
    tmpfile=$(mktemp "$TEST_DIR/tmp.XXXXXX")

    TMP_DIRS="$TEST_DIR"
    cleanup_tmp
    [ -f "$tmpfile" ]
}

@test "get_cleanup_actions returns correct actions for warn level" {
    local actions
    actions=$(get_cleanup_actions "warn")
    [[ "$actions" == *"journal"* ]]
    [[ "$actions" != *"fstrim"* ]]
}

@test "get_cleanup_actions returns all actions for alert level" {
    local actions
    actions=$(get_cleanup_actions "alert")
    [[ "$actions" == *"journal"* ]]
    [[ "$actions" == *"tmp"* ]]
    [[ "$actions" == *"fstrim"* ]]
}
