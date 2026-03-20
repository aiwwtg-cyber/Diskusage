#!/usr/bin/env bash
set -euo pipefail

echo "=== Diskusage Integration Test ==="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DISKUSAGE_HOME="$(mktemp -d)/.diskusage"
mkdir -p "$DISKUSAGE_HOME/logs" "$DISKUSAGE_HOME/config"
cp "$SCRIPT_DIR/config.conf.default" "$DISKUSAGE_HOME/config/config.conf"
# Use shorter interval for faster test execution
sed -i 's/^MONITOR_INTERVAL=.*/MONITOR_INTERVAL=2/' "$DISKUSAGE_HOME/config/config.conf"
sed -i 's/^MONITOR_INTERVAL_HIGH=.*/MONITOR_INTERVAL_HIGH=2/' "$DISKUSAGE_HOME/config/config.conf"

PASS=0
FAIL=0

assert() {
    local desc="$1"
    shift
    if "$@"; then
        echo "  PASS: $desc"
        ((PASS++)) || true
    else
        echo "  FAIL: $desc"
        ((FAIL++)) || true
    fi
}

# Test 1: monitor.sh start/stop cycle
echo ""
echo "[Test 1] monitor.sh start/stop cycle"
bash "$SCRIPT_DIR/monitor.sh" start
sleep 6
assert "pid file exists" test -f "$DISKUSAGE_HOME/monitor.pid"
assert "status file exists" test -f "$DISKUSAGE_HOME/status"
assert "log file created" test -f "$DISKUSAGE_HOME/logs/$(date +%Y-%m-%d).log"

bash "$SCRIPT_DIR/monitor.sh" stop
sleep 1
assert "pid file removed after stop" test ! -f "$DISKUSAGE_HOME/monitor.pid"

# Test 2: log content check
echo ""
echo "[Test 2] Log content"
LOGFILE="$DISKUSAGE_HOME/logs/$(date +%Y-%m-%d).log"
assert "log has VHD_IO entries" grep -q "VHD_IO:" "$LOGFILE"
assert "log has timestamps" grep -qE '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]' "$LOGFILE"

# Test 3: report command
echo ""
echo "[Test 3] Report command"
OUTPUT=$(bash "$SCRIPT_DIR/monitor.sh" report)
assert "report shows header" bash -c 'echo "$1" | grep -q "Diskusage Report"' -- "$OUTPUT"

# Test 4: double start prevention
echo ""
echo "[Test 4] Double start prevention"
bash "$SCRIPT_DIR/monitor.sh" start
sleep 1
OUTPUT=$(bash "$SCRIPT_DIR/monitor.sh" start 2>&1 || true)
assert "second start is rejected" bash -c 'echo "$1" | grep -q "already running"' -- "$OUTPUT"
bash "$SCRIPT_DIR/monitor.sh" stop
sleep 1

# Cleanup
rm -rf "$(dirname "$DISKUSAGE_HOME")"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
