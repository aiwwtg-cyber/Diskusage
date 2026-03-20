#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    export DISKUSAGE_HOME="$TEST_DIR/.diskusage"
    mkdir -p "$DISKUSAGE_HOME/config"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$PROJECT_ROOT/lib/monitor/diskstats.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "parse_diskstats_line extracts read and write sectors from mock data" {
    local mock_line="   8       0 sda 1000 500 200000 5000 2000 300 100000 3000 0 4000 8000 0 0 0 0"
    local result
    result=$(parse_diskstats_line "$mock_line")
    [ "$result" = "200000 100000" ]
}

@test "calc_io_kbps calculates delta correctly" {
    # prev: 100000 read, 50000 write sectors
    # curr: 110000 read, 55000 write sectors
    # delta: 10000 read, 5000 write
    # at 512 bytes/sector, over 5 seconds:
    # read: 10000*512/1024/5 = 1000 KB/s
    # write: 5000*512/1024/5 = 500 KB/s
    local result
    result=$(calc_io_kbps 100000 50000 110000 55000 5)
    [ "$result" = "1000 500 1500" ]
}

@test "get_io_level returns correct level based on thresholds" {
    load_config
    [ "$(get_io_level 50000)" = "normal" ]
    [ "$(get_io_level 65000)" = "warn" ]
    [ "$(get_io_level 80000)" = "alert" ]
    [ "$(get_io_level 95000)" = "danger" ]
}

@test "read_diskstats reads real /proc/diskstats without error" {
    local result
    result=$(read_diskstats)
    [[ "$result" =~ ^[0-9]+\ [0-9]+$ ]]
}
