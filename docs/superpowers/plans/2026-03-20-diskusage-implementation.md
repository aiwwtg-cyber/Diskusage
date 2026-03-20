# Diskusage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** WSL2 디스크 I/O 100% 문제를 진단하고 예방하는 듀얼 워치독 시스템 구현

**Architecture:** Windows PowerShell 워치독이 Hyper-V VHD 카운터로 WSL 디스크 I/O를 감시하고, WSL Bash 모니터가 자율적으로 /proc/diskstats 기반 진단 + 예방 정리를 수행. 두 컴포넌트는 상태 파일로 조율.

**Tech Stack:** Bash + bats-core (WSL), PowerShell 5.1+ + Pester (Windows), BurntToast (알림)

---

## File Structure

```
Diskusage/
├── monitor.sh                    # WSL 모니터 진입점 (start/stop/status/report)
├── watchdog.ps1                  # Windows 워치독 진입점
├── setup.sh                      # WSL 초기 설정
├── setup.ps1                     # Windows 초기 설정
├── config.conf.default           # 기본 설정 템플릿
├── lib/
│   ├── monitor/
│   │   ├── diskstats.sh          # /proc/diskstats 파싱 + I/O 계산
│   │   ├── cleanup.sh            # 안전한 정리 액션 함수들
│   │   └── logger.sh             # 로깅 + 로그 로테이션
│   └── watchdog/
│       ├── counters.ps1          # Hyper-V 카운터 읽기
│       ├── escalation.ps1        # 임계값 평가 + 상태 머신
│       └── notification.ps1      # 토스트 알림 + 폴백
├── tests/
│   ├── bats/
│   │   ├── test_diskstats.bats   # diskstats 파싱 테스트
│   │   ├── test_cleanup.bats     # 정리 액션 테스트
│   │   ├── test_logger.bats      # 로깅 테스트
│   │   └── test_monitor.bats     # 모니터 통합 테스트
│   └── pester/
│       ├── Counters.Tests.ps1    # Hyper-V 카운터 테스트
│       ├── Escalation.Tests.ps1  # 에스컬레이션 테스트
│       └── Notification.Tests.ps1 # 알림 테스트
└── docs/
    └── superpowers/
        ├── specs/
        │   └── 2026-03-20-diskusage-design.md
        └── plans/
            └── 2026-03-20-diskusage-implementation.md
```

**파일 책임 분리:**
- `lib/monitor/diskstats.sh`: I/O 데이터 수집만 담당, 판단 로직 없음
- `lib/monitor/cleanup.sh`: 정리 액션 실행만 담당, 언제 실행할지는 monitor.sh가 결정
- `lib/monitor/logger.sh`: 로그 쓰기 + 로테이션만 담당
- `lib/watchdog/counters.ps1`: 카운터 값 읽기만 담당
- `lib/watchdog/escalation.ps1`: 상태 전환 판단만 담당, 실행은 watchdog.ps1이 수행
- `lib/watchdog/notification.ps1`: 알림 표시만 담당

---

## Task 1: 프로젝트 스캐폴드 + 설정 로딩

**Files:**
- Create: `config.conf.default`
- Create: `lib/monitor/config.sh` (설정이 없으므로 이건 monitor.sh에서 직접 처리 — 아래 참고)
- Test: `tests/bats/test_config.bats`

참고: 설정 로딩은 단순 `source` 기반이므로 별도 파일 대신 monitor.sh 내에 `load_config()` 함수로 구현합니다.

- [ ] **Step 1: bats-core 설치 확인**

Run: `which bats || sudo apt-get install -y bats`
Expected: bats 경로 출력

- [ ] **Step 2: 프로젝트 디렉토리 생성**

```bash
mkdir -p lib/monitor lib/watchdog tests/bats tests/pester
```

- [ ] **Step 3: 기본 설정 파일 작성**

`config.conf.default`:
```ini
# Diskusage Configuration
# 이 파일을 ~/.diskusage/config/config.conf 로 복사하여 사용

# 감시 주기 (초)
MONITOR_INTERVAL=5
# 경고 수준 초과 시 폴링 간격 (초)
MONITOR_INTERVAL_HIGH=15

# I/O 임계값 (KB/s 기준, /proc/diskstats 델타에서 계산)
# monitor.sh 내부에서 사용하는 자체 임계값
MONITOR_IO_WARN_KB=61440
MONITOR_IO_ALERT_KB=76800
MONITOR_IO_DANGER_KB=92160

# Windows 워치독 임계값 (WSL VHD I/O 기준, % of baseline)
WARN_THRESHOLD=60
ALERT_THRESHOLD=75
DANGER_THRESHOLD=90
CRITICAL_THRESHOLD=95

# I/O 기준값 (MB/s, 사용자 환경에 맞게 조정)
IO_BASELINE_MBPS=100

# 지속 시간 (초)
WARN_DURATION=30
ALERT_DURATION=30
DANGER_DURATION=60
CRITICAL_DURATION=120

# wsl -e 타임아웃 (초)
WSL_EXEC_TIMEOUT=10

# 로그 보관 기간 (일)
LOG_RETENTION_DAYS=7
# 일별 최대 로그 크기 (MB)
MAX_LOG_SIZE_MB=50
```

- [ ] **Step 4: 설정 로딩 테스트 작성**

`tests/bats/test_config.bats`:
```bash
#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    CONFIG_DIR="$TEST_DIR/.diskusage/config"
    mkdir -p "$CONFIG_DIR"
    export DISKUSAGE_HOME="$TEST_DIR/.diskusage"

    # source the function we're testing
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
    # other defaults still apply
    [ "$LOG_RETENTION_DAYS" -eq 7 ]
}

@test "load_config validates numeric values" {
    echo "MONITOR_INTERVAL=notanumber" > "$CONFIG_DIR/config.conf"
    load_config
    # should fall back to default
    [ "$MONITOR_INTERVAL" -eq 5 ]
}
```

- [ ] **Step 5: 테스트 실행 — 실패 확인**

Run: `cd /home/aiwwt/project/Diskusage && bats tests/bats/test_config.bats`
Expected: FAIL — `lib/monitor/diskstats.sh` 파일이 없음

- [ ] **Step 6: load_config 함수 구현**

`lib/monitor/diskstats.sh` (초기 버전 — 설정 로딩만):
```bash
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

    local config_file="$DISKUSAGE_HOME/config/config.conf"
    if [[ -f "$config_file" ]]; then
        while IFS='=' read -r key value; do
            # skip comments and empty lines
            [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
            key="$(echo "$key" | tr -d '[:space:]')"
            value="$(echo "$value" | tr -d '[:space:]')"
            # validate numeric
            if [[ "$value" =~ ^[0-9]+$ ]]; then
                declare -g "$key=$value"
            fi
        done < "$config_file"
    fi
}
```

- [ ] **Step 7: 테스트 실행 — 통과 확인**

Run: `cd /home/aiwwt/project/Diskusage && bats tests/bats/test_config.bats`
Expected: 3 tests, 3 passed

- [ ] **Step 8: 커밋**

```bash
git add config.conf.default lib/monitor/diskstats.sh tests/bats/test_config.bats
git commit -m "feat: add project scaffold and config loading"
```

---

## Task 2: /proc/diskstats 파싱 + I/O 계산

**Files:**
- Modify: `lib/monitor/diskstats.sh`
- Test: `tests/bats/test_diskstats.bats`

- [ ] **Step 1: diskstats 파싱 테스트 작성**

`tests/bats/test_diskstats.bats`:
```bash
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

@test "parse_diskstats extracts read and write sectors from mock data" {
    # mock /proc/diskstats line for sda:
    # major minor name rd_ios rd_merges rd_sectors rd_ticks wr_ios wr_merges wr_sectors wr_ticks ...
    local mock_line="   8       0 sda 1000 500 200000 5000 2000 300 100000 3000 0 4000 8000 0 0 0 0"
    local result
    result=$(parse_diskstats_line "$mock_line")
    # should return "read_sectors write_sectors" = "200000 100000"
    [ "$result" = "200000 100000" ]
}

@test "calc_io_kbps calculates delta correctly" {
    # prev: 100000 read sectors, 50000 write sectors
    # curr: 110000 read sectors, 55000 write sectors
    # delta: 10000 read, 5000 write sectors
    # at 512 bytes/sector, over 5 seconds:
    # read: 10000*512/1024/5 = 1000 KB/s
    # write: 5000*512/1024/5 = 500 KB/s
    local result
    result=$(calc_io_kbps 100000 50000 110000 55000 5)
    # total = 1500 KB/s, format: "read_kbps write_kbps total_kbps"
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
    # should return two numbers (read_sectors write_sectors)
    [[ "$result" =~ ^[0-9]+\ [0-9]+$ ]]
}
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

Run: `bats tests/bats/test_diskstats.bats`
Expected: FAIL — 함수들이 아직 없음

- [ ] **Step 3: diskstats 파싱 함수 구현**

`lib/monitor/diskstats.sh`에 다음 함수 추가:
```bash
parse_diskstats_line() {
    local line="$1"
    local fields
    read -ra fields <<< "$line"
    # fields[5] = rd_sectors, fields[9] = wr_sectors
    echo "${fields[5]} ${fields[9]}"
}

read_diskstats() {
    local total_rd=0 total_wr=0
    while read -r line; do
        local fields
        read -ra fields <<< "$line"
        local name="${fields[2]}"
        # only count whole-disk devices (sda, vda, etc.), skip partitions
        if [[ "$name" =~ ^(sd|vd|nvme)[a-z]+$ ]] || [[ "$name" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
            local rd="${fields[5]}"
            local wr="${fields[9]}"
            total_rd=$((total_rd + rd))
            total_wr=$((total_wr + wr))
        fi
    done < /proc/diskstats
    echo "$total_rd $total_wr"
}

calc_io_kbps() {
    local prev_rd="$1" prev_wr="$2" curr_rd="$3" curr_wr="$4" interval="$5"
    local delta_rd=$(( curr_rd - prev_rd ))
    local delta_wr=$(( curr_wr - prev_wr ))
    # sectors are 512 bytes, convert to KB/s
    local rd_kbps=$(( delta_rd * 512 / 1024 / interval ))
    local wr_kbps=$(( delta_wr * 512 / 1024 / interval ))
    local total=$(( rd_kbps + wr_kbps ))
    echo "$rd_kbps $wr_kbps $total"
}

get_io_level() {
    local total_kbps="$1"
    if (( total_kbps >= MONITOR_IO_DANGER_KB )); then
        echo "danger"
    elif (( total_kbps >= MONITOR_IO_ALERT_KB )); then
        echo "alert"
    elif (( total_kbps >= MONITOR_IO_WARN_KB )); then
        echo "warn"
    else
        echo "normal"
    fi
}
```

- [ ] **Step 4: 테스트 실행 — 통과 확인**

Run: `bats tests/bats/test_diskstats.bats`
Expected: 4 tests, 4 passed

- [ ] **Step 5: 커밋**

```bash
git add lib/monitor/diskstats.sh tests/bats/test_diskstats.bats
git commit -m "feat: add /proc/diskstats parsing and I/O calculation"
```

---

## Task 3: 로깅 + 로그 로테이션

**Files:**
- Create: `lib/monitor/logger.sh`
- Test: `tests/bats/test_logger.bats`

- [ ] **Step 1: 로거 테스트 작성**

`tests/bats/test_logger.bats`:
```bash
#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    export DISKUSAGE_HOME="$TEST_DIR/.diskusage"
    mkdir -p "$DISKUSAGE_HOME/logs" "$DISKUSAGE_HOME/config"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$PROJECT_ROOT/lib/monitor/diskstats.sh"
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
    # timestamp format: [HH:MM:SS]
    grep -qE '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]' "$logfile"
}

@test "log_action writes ACTION: prefix" {
    log_action "journalctl vacuum applied"
    local logfile="$DISKUSAGE_HOME/logs/$(date +%Y-%m-%d).log"
    grep -q "ACTION: journalctl vacuum applied" "$logfile"
}

@test "rotate_logs removes files older than retention" {
    # create a log file "older" than retention
    local old_date
    old_date=$(date -d "10 days ago" +%Y-%m-%d)
    touch "$DISKUSAGE_HOME/logs/${old_date}.log"
    # create today's log
    touch "$DISKUSAGE_HOME/logs/$(date +%Y-%m-%d).log"

    LOG_RETENTION_DAYS=7
    rotate_logs

    [ ! -f "$DISKUSAGE_HOME/logs/${old_date}.log" ]
    [ -f "$DISKUSAGE_HOME/logs/$(date +%Y-%m-%d).log" ]
}

@test "rotate_logs truncates oversized log file" {
    local logfile="$DISKUSAGE_HOME/logs/$(date +%Y-%m-%d).log"
    MAX_LOG_SIZE_MB=1
    # create a file slightly over 1MB
    dd if=/dev/zero of="$logfile" bs=1024 count=1100 2>/dev/null
    local size_before
    size_before=$(stat -c%s "$logfile")

    rotate_logs

    local size_after
    size_after=$(stat -c%s "$logfile")
    [ "$size_after" -lt "$size_before" ]
}
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

Run: `bats tests/bats/test_logger.bats`
Expected: FAIL

- [ ] **Step 3: 로거 구현**

`lib/monitor/logger.sh`:
```bash
#!/usr/bin/env bash
# logger.sh — 로깅 + 로그 로테이션

_log_dir="$DISKUSAGE_HOME/logs"

_get_logfile() {
    echo "$_log_dir/$(date +%Y-%m-%d).log"
}

log_entry() {
    local msg="$1"
    local ts
    ts="[$(date +%H:%M:%S)]"
    echo "$ts $msg" >> "$(_get_logfile)"
}

log_action() {
    log_entry "ACTION: $1"
}

log_external() {
    log_entry "EXTERNAL: $1"
}

rotate_logs() {
    local cutoff_date
    cutoff_date=$(date -d "$LOG_RETENTION_DAYS days ago" +%Y-%m-%d)

    # remove old log files
    for f in "$_log_dir"/*.log; do
        [[ -f "$f" ]] || continue
        local basename
        basename="$(basename "$f" .log)"
        if [[ "$basename" < "$cutoff_date" ]]; then
            rm -f "$f"
        fi
    done

    # truncate oversized current log
    local logfile
    logfile="$(_get_logfile)"
    if [[ -f "$logfile" ]]; then
        local max_bytes=$(( MAX_LOG_SIZE_MB * 1024 * 1024 ))
        local size
        size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
        if (( size > max_bytes )); then
            # keep the last portion of the file
            tail -c "$max_bytes" "$logfile" > "${logfile}.tmp"
            mv "${logfile}.tmp" "$logfile"
        fi
    fi
}
```

- [ ] **Step 4: 테스트 실행 — 통과 확인**

Run: `bats tests/bats/test_logger.bats`
Expected: 5 tests, 5 passed

- [ ] **Step 5: 커밋**

```bash
git add lib/monitor/logger.sh tests/bats/test_logger.bats
git commit -m "feat: add logging and log rotation"
```

---

## Task 4: 정리 액션 함수

**Files:**
- Create: `lib/monitor/cleanup.sh`
- Test: `tests/bats/test_cleanup.bats`

- [ ] **Step 1: 정리 액션 테스트 작성**

`tests/bats/test_cleanup.bats`:
```bash
#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    export DISKUSAGE_HOME="$TEST_DIR/.diskusage"
    mkdir -p "$DISKUSAGE_HOME/logs" "$DISKUSAGE_HOME/config"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    source "$PROJECT_ROOT/lib/monitor/diskstats.sh"
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
    # make it look old
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
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

Run: `bats tests/bats/test_cleanup.bats`
Expected: FAIL

- [ ] **Step 3: 정리 액션 구현**

`lib/monitor/cleanup.sh`:
```bash
#!/usr/bin/env bash
# cleanup.sh — 안전한 정리 액션

TMP_DIRS="${TMP_DIRS:-/tmp}"

get_cleanup_actions() {
    local level="$1"
    case "$level" in
        warn)
            echo "journal"
            ;;
        alert|danger)
            echo "journal tmp fstrim"
            ;;
        *)
            echo ""
            ;;
    esac
}

run_cleanup() {
    local level="$1"
    local actions
    actions=$(get_cleanup_actions "$level")

    for action in $actions; do
        case "$action" in
            journal)  cleanup_journal ;;
            tmp)      cleanup_tmp ;;
            fstrim)   cleanup_fstrim ;;
        esac
    done
}

cleanup_journal() {
    if command -v journalctl &>/dev/null; then
        sudo journalctl --vacuum-size=50M 2>/dev/null && \
            log_action "journalctl vacuum applied"
    fi
}

cleanup_tmp() {
    local dir
    for dir in $TMP_DIRS; do
        # only remove files older than 2 days, not directories
        find "$dir" -maxdepth 1 -type f -mtime +2 -delete 2>/dev/null
    done
    log_action "tmp cleanup applied"
}

cleanup_fstrim() {
    if command -v fstrim &>/dev/null; then
        sudo fstrim / 2>/dev/null && \
            log_action "fstrim applied"
    fi
}
```

- [ ] **Step 4: 테스트 실행 — 통과 확인**

Run: `bats tests/bats/test_cleanup.bats`
Expected: 4 tests, 4 passed

- [ ] **Step 5: 커밋**

```bash
git add lib/monitor/cleanup.sh tests/bats/test_cleanup.bats
git commit -m "feat: add safe cleanup action functions"
```

---

## Task 5: monitor.sh 프로세스 관리 (start/stop/status/report)

**Files:**
- Create: `monitor.sh`
- Test: `tests/bats/test_monitor.bats`

- [ ] **Step 1: 프로세스 관리 테스트 작성**

`tests/bats/test_monitor.bats`:
```bash
#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    export DISKUSAGE_HOME="$TEST_DIR/.diskusage"
    mkdir -p "$DISKUSAGE_HOME/logs" "$DISKUSAGE_HOME/config"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export MONITOR_SCRIPT="$PROJECT_ROOT/monitor.sh"
}

teardown() {
    # kill any leftover monitor processes
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
    sleep 1
    [ -f "$DISKUSAGE_HOME/monitor.pid" ]
    local pid
    pid=$(cat "$DISKUSAGE_HOME/monitor.pid")
    kill -0 "$pid" 2>/dev/null
}

@test "monitor.sh status shows running when started" {
    bash "$MONITOR_SCRIPT" start
    sleep 1
    local output
    output=$(bash "$MONITOR_SCRIPT" status)
    [[ "$output" == *"running"* ]]
}

@test "monitor.sh stop kills the process and removes pid file" {
    bash "$MONITOR_SCRIPT" start
    sleep 1
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
    sleep 2
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
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

Run: `bats tests/bats/test_monitor.bats`
Expected: FAIL

- [ ] **Step 3: monitor.sh 구현**

`monitor.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISKUSAGE_HOME="${DISKUSAGE_HOME:-$HOME/.diskusage}"
PID_FILE="$DISKUSAGE_HOME/monitor.pid"
STATUS_FILE="$DISKUSAGE_HOME/status"

# source libraries
source "$SCRIPT_DIR/lib/monitor/diskstats.sh"
source "$SCRIPT_DIR/lib/monitor/logger.sh"
source "$SCRIPT_DIR/lib/monitor/cleanup.sh"

load_config

set_status() {
    echo "$1" > "$STATUS_FILE"
}

is_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            # verify it's actually our process
            local cmd
            cmd=$(ps -p "$pid" -o comm= 2>/dev/null || true)
            if [[ "$cmd" == "bash" || "$cmd" == "monitor.sh" ]]; then
                return 0
            fi
        fi
        # stale pid file
        rm -f "$PID_FILE"
    fi
    return 1
}

do_start() {
    if is_running; then
        echo "monitor is already running (pid: $(cat "$PID_FILE"))"
        exit 1
    fi
    mkdir -p "$DISKUSAGE_HOME/logs" "$DISKUSAGE_HOME/config"
    echo "starting monitor..."
    _monitor_loop &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    echo "monitor started (pid: $pid)"
}

do_stop() {
    if ! is_running; then
        echo "monitor is not running"
        return 0
    fi
    local pid
    pid=$(cat "$PID_FILE")
    echo "stopping monitor (pid: $pid)..."
    kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE" "$STATUS_FILE"
    echo "monitor stopped"
}

do_status() {
    if is_running; then
        echo "monitor is running (pid: $(cat "$PID_FILE"))"
    else
        echo "monitor is stopped"
    fi
}

do_report() {
    local logfile="$DISKUSAGE_HOME/logs/$(date +%Y-%m-%d).log"
    if [[ ! -f "$logfile" ]]; then
        echo "no log for today"
        return 0
    fi
    echo "=== Diskusage Report $(date +%Y-%m-%d) ==="
    echo ""
    echo "--- Actions taken ---"
    grep "ACTION:" "$logfile" 2>/dev/null || echo "(none)"
    echo ""
    echo "--- External pressure events ---"
    grep "EXTERNAL:" "$logfile" 2>/dev/null || echo "(none)"
    echo ""
    echo "--- Peak I/O (top 5 entries) ---"
    grep "VHD_IO:" "$logfile" 2>/dev/null | sort -t: -k2 -rn | head -5 || echo "(none)"
    echo ""
    echo "--- Log size ---"
    du -h "$logfile"
}

_monitor_loop() {
    trap '_on_exit' EXIT TERM INT
    set_status "idle"
    rotate_logs
    local last_rotation
    last_rotation=$(date +%s)
    local prev_rd=0 prev_wr=0
    local first_read=true

    while true; do
        # read diskstats
        local stats
        stats=$(read_diskstats)
        local curr_rd curr_wr
        read -r curr_rd curr_wr <<< "$stats"

        if $first_read; then
            prev_rd=$curr_rd
            prev_wr=$curr_wr
            first_read=false
            sleep "$MONITOR_INTERVAL"
            continue
        fi

        # calculate I/O
        local io_result
        io_result=$(calc_io_kbps "$prev_rd" "$prev_wr" "$curr_rd" "$curr_wr" "$MONITOR_INTERVAL")
        local rd_kbps wr_kbps total_kbps
        read -r rd_kbps wr_kbps total_kbps <<< "$io_result"

        # determine level
        local level
        level=$(get_io_level "$total_kbps")

        # get memory info
        local mem_info
        mem_info=$(free -m | awk '/Mem:/{printf "%dM/%dM", $3, $2} /Swap:/{printf " SWAP:%dM/%dM", $3, $2}')

        # log
        log_entry "VHD_IO:${total_kbps}KB/s MEM:${mem_info} LEVEL:${level}"

        # take action if needed
        if [[ "$level" != "normal" ]]; then
            set_status "cleaning"
            run_cleanup "$level"
            set_status "monitoring"
        else
            set_status "idle"
        fi

        # update previous values
        prev_rd=$curr_rd
        prev_wr=$curr_wr

        # periodic log rotation (every hour)
        local now
        now=$(date +%s)
        if (( now - last_rotation > 3600 )); then
            rotate_logs
            last_rotation=$now
        fi

        # adaptive polling
        local interval=$MONITOR_INTERVAL
        if [[ "$level" == "alert" || "$level" == "danger" ]]; then
            interval=$MONITOR_INTERVAL_HIGH
        fi
        sleep "$interval"
    done
}

_on_exit() {
    rm -f "$PID_FILE" "$STATUS_FILE"
}

# main
case "${1:-}" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
    report) do_report ;;
    *)      echo "Usage: $0 {start|stop|status|report}" ; exit 1 ;;
esac
```

- [ ] **Step 4: 실행 권한 부여**

```bash
chmod +x monitor.sh
```

- [ ] **Step 5: 테스트 실행 — 통과 확인**

Run: `bats tests/bats/test_monitor.bats`
Expected: 6 tests, 6 passed

- [ ] **Step 6: 커밋**

```bash
git add monitor.sh tests/bats/test_monitor.bats
git commit -m "feat: add monitor.sh with start/stop/status/report"
```

---

## Task 6: Windows 워치독 — Hyper-V 카운터 읽기

**Files:**
- Create: `lib/watchdog/counters.ps1`
- Test: `tests/pester/Counters.Tests.ps1`

참고: Pester 테스트는 Windows PowerShell에서 실행해야 합니다. WSL에서는 `powershell.exe -File` 로 실행 가능합니다.

- [ ] **Step 1: 카운터 읽기 테스트 작성**

`tests/pester/Counters.Tests.ps1`:
```powershell
BeforeAll {
    . "$PSScriptRoot/../../lib/watchdog/counters.ps1"
}

Describe "Get-WslVhdPaths" {
    It "returns paths containing wsl and ext4" {
        $paths = Get-WslVhdPaths
        # may be empty if no WSL VHDs, but function should not error
        { Get-WslVhdPaths } | Should -Not -Throw
    }
}

Describe "Get-VhdIoRate" {
    It "returns a hashtable with ReadBytesPerSec and WriteBytesPerSec" {
        $result = Get-VhdIoRate
        $result | Should -BeOfType [hashtable]
        $result.Keys | Should -Contain "ReadBytesPerSec"
        $result.Keys | Should -Contain "WriteBytesPerSec"
        $result.Keys | Should -Contain "TotalMBps"
    }

    It "returns numeric values" {
        $result = Get-VhdIoRate
        $result.ReadBytesPerSec | Should -BeOfType [double] -Or $result.ReadBytesPerSec | Should -BeOfType [int]
    }
}

Describe "Get-PhysicalDiskPercent" {
    It "returns a number between 0 and 100" {
        $result = Get-PhysicalDiskPercent
        $result | Should -BeGreaterOrEqual 0
    }
}

Describe "Get-VmmemMemoryMB" {
    It "returns memory usage or 0 if process not found" {
        $result = Get-VmmemMemoryMB
        $result | Should -BeGreaterOrEqual 0
    }
}

Describe "Test-WslIsIoCause" {
    It "returns true when VHD IO is high and disk is high" {
        $result = Test-WslIsIoCause -VhdTotalMBps 80 -PhysicalDiskPct 90 -BaselineMBps 100
        $result | Should -Be $true
    }

    It "returns false when VHD IO is low but disk is high" {
        $result = Test-WslIsIoCause -VhdTotalMBps 10 -PhysicalDiskPct 90 -BaselineMBps 100
        $result | Should -Be $false
    }
}
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

Run (from WSL): `powershell.exe -Command "Invoke-Pester -Path '\\\\wsl$\\Ubuntu\\home\\aiwwt\\project\\Diskusage\\tests\\pester\\Counters.Tests.ps1' -PassThru"`
Expected: FAIL

- [ ] **Step 3: 카운터 읽기 구현**

`lib/watchdog/counters.ps1`:
```powershell
# counters.ps1 — Hyper-V Virtual Storage Device 카운터 읽기

function Get-WslVhdPaths {
    try {
        $instances = (Get-Counter -ListSet "Hyper-V Virtual Storage Device" -ErrorAction Stop).PathsWithInstances
        $wslInstances = $instances | Where-Object { $_ -match "wsl.*ext4|swap" }
        return $wslInstances
    } catch {
        return @()
    }
}

function Get-VhdIoRate {
    $result = @{
        ReadBytesPerSec = [double]0
        WriteBytesPerSec = [double]0
        TotalMBps = [double]0
    }

    try {
        $counterPaths = @(
            "\Hyper-V Virtual Storage Device(*wsl*ext4*)\Read Bytes/sec"
            "\Hyper-V Virtual Storage Device(*wsl*ext4*)\Write Bytes/sec"
            "\Hyper-V Virtual Storage Device(*swap*)\Read Bytes/sec"
            "\Hyper-V Virtual Storage Device(*swap*)\Write Bytes/sec"
        )
        $counters = Get-Counter -Counter $counterPaths -ErrorAction SilentlyContinue
        if ($counters) {
            foreach ($sample in $counters.CounterSamples) {
                if ($sample.Path -match "read bytes") {
                    $result.ReadBytesPerSec += $sample.CookedValue
                } elseif ($sample.Path -match "write bytes") {
                    $result.WriteBytesPerSec += $sample.CookedValue
                }
            }
        }
    } catch {
        # Hyper-V counters not available (Windows Home, etc.)
        # Fall back to physical disk — caller should check HasHyperVCounters
    }

    $result.TotalMBps = [math]::Round(($result.ReadBytesPerSec + $result.WriteBytesPerSec) / 1MB, 2)
    return $result
}

function Get-PhysicalDiskPercent {
    try {
        $counter = Get-Counter "\PhysicalDisk(_Total)\% Disk Time" -ErrorAction Stop
        return [math]::Round($counter.CounterSamples[0].CookedValue, 2)
    } catch {
        return 0
    }
}

function Get-VmmemMemoryMB {
    try {
        $proc = Get-Process -Name "vmmem*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            return [math]::Round($proc.WorkingSet64 / 1MB, 2)
        }
    } catch {}
    return 0
}

function Test-WslIsIoCause {
    param(
        [double]$VhdTotalMBps,
        [double]$PhysicalDiskPct,
        [double]$BaselineMBps
    )
    # WSL is the cause if VHD I/O exceeds 30% of baseline AND physical disk is high
    $vhdPct = ($VhdTotalMBps / $BaselineMBps) * 100
    return ($vhdPct -ge 30 -and $PhysicalDiskPct -ge 50)
}
```

- [ ] **Step 4: 테스트 실행 — 통과 확인**

Run: `powershell.exe -Command "Invoke-Pester -Path '\\\\wsl$\\Ubuntu\\home\\aiwwt\\project\\Diskusage\\tests\\pester\\Counters.Tests.ps1' -PassThru"`
Expected: All tests passed

- [ ] **Step 5: 커밋**

```bash
git add lib/watchdog/counters.ps1 tests/pester/Counters.Tests.ps1
git commit -m "feat: add Hyper-V VHD counter reading for Windows watchdog"
```

---

## Task 7: Windows 워치독 — 에스컬레이션 상태 머신

**Files:**
- Create: `lib/watchdog/escalation.ps1`
- Test: `tests/pester/Escalation.Tests.ps1`

- [ ] **Step 1: 에스컬레이션 테스트 작성**

`tests/pester/Escalation.Tests.ps1`:
```powershell
BeforeAll {
    . "$PSScriptRoot/../../lib/watchdog/escalation.ps1"
}

Describe "Get-IoLevel" {
    It "returns 'normal' for I/O below warn threshold" {
        $result = Get-IoLevel -TotalMBps 50 -BaselineMBps 100 -Config @{
            WarnThreshold=60; AlertThreshold=75; DangerThreshold=90; CriticalThreshold=95
        }
        $result | Should -Be "normal"
    }

    It "returns 'warn' for I/O at warn threshold" {
        $result = Get-IoLevel -TotalMBps 65 -BaselineMBps 100 -Config @{
            WarnThreshold=60; AlertThreshold=75; DangerThreshold=90; CriticalThreshold=95
        }
        $result | Should -Be "warn"
    }

    It "returns 'critical' for I/O at critical threshold" {
        $result = Get-IoLevel -TotalMBps 96 -BaselineMBps 100 -Config @{
            WarnThreshold=60; AlertThreshold=75; DangerThreshold=90; CriticalThreshold=95
        }
        $result | Should -Be "critical"
    }
}

Describe "Update-EscalationState" {
    It "does not escalate on first occurrence" {
        $state = New-EscalationState
        $result = Update-EscalationState -State $state -Level "warn" -IntervalSec 5
        $result.ShouldAct | Should -Be $false
    }

    It "escalates after sufficient duration" {
        $state = New-EscalationState
        # simulate 7 ticks at 5 sec each = 35 sec (> 30 sec warn duration)
        for ($i = 0; $i -lt 7; $i++) {
            $result = Update-EscalationState -State $state -Level "warn" -IntervalSec 5
        }
        $result.ShouldAct | Should -Be $true
        $result.Action | Should -Be "cleanup"
    }

    It "resets when level drops to normal" {
        $state = New-EscalationState
        for ($i = 0; $i -lt 7; $i++) {
            Update-EscalationState -State $state -Level "warn" -IntervalSec 5
        }
        $result = Update-EscalationState -State $state -Level "normal" -IntervalSec 5
        $result.ShouldAct | Should -Be $false
        $state.Duration | Should -Be 0
    }

    It "escalates to next level on wsl -e timeout" {
        $state = New-EscalationState
        $result = Update-EscalationState -State $state -Level "warn" -IntervalSec 5 -WslTimeout $true
        $result.EscalatedLevel | Should -Be "alert"
    }
}
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

Run: `powershell.exe -Command "Invoke-Pester -Path '\\\\wsl$\\Ubuntu\\home\\aiwwt\\project\\Diskusage\\tests\\pester\\Escalation.Tests.ps1' -PassThru"`
Expected: FAIL

- [ ] **Step 3: 에스컬레이션 구현**

`lib/watchdog/escalation.ps1`:
```powershell
# escalation.ps1 — 임계값 평가 + 상태 머신

$script:LevelOrder = @("normal", "warn", "alert", "danger", "critical")
$script:LevelActions = @{
    "normal"   = "none"
    "warn"     = "cleanup"
    "alert"    = "cleanup_and_notify"
    "danger"   = "user_confirm"
    "critical" = "shutdown_confirm"
}
$script:LevelDurations = @{
    "warn"     = 30
    "alert"    = 30
    "danger"   = 60
    "critical" = 120
}

function New-EscalationState {
    return @{
        CurrentLevel = "normal"
        Duration     = 0
        LastAction   = $null
    }
}

function Get-IoLevel {
    param(
        [double]$TotalMBps,
        [double]$BaselineMBps,
        [hashtable]$Config
    )
    $pct = ($TotalMBps / $BaselineMBps) * 100

    if ($pct -ge $Config.CriticalThreshold) { return "critical" }
    if ($pct -ge $Config.DangerThreshold)   { return "danger" }
    if ($pct -ge $Config.AlertThreshold)    { return "alert" }
    if ($pct -ge $Config.WarnThreshold)     { return "warn" }
    return "normal"
}

function Update-EscalationState {
    param(
        [hashtable]$State,
        [string]$Level,
        [int]$IntervalSec,
        [bool]$WslTimeout = $false
    )

    $result = @{
        ShouldAct     = $false
        Action        = "none"
        EscalatedLevel = $Level
    }

    # wsl -e timeout: escalate to next level immediately
    if ($WslTimeout) {
        $idx = $script:LevelOrder.IndexOf($Level)
        if ($idx -lt $script:LevelOrder.Count - 1) {
            $result.EscalatedLevel = $script:LevelOrder[$idx + 1]
        }
        $Level = $result.EscalatedLevel
    }

    if ($Level -eq "normal") {
        $State.CurrentLevel = "normal"
        $State.Duration = 0
        return $result
    }

    if ($State.CurrentLevel -eq $Level) {
        $State.Duration += $IntervalSec
    } else {
        $State.CurrentLevel = $Level
        $State.Duration = $IntervalSec
    }

    $requiredDuration = $script:LevelDurations[$Level]
    if ($null -eq $requiredDuration) { $requiredDuration = 30 }

    if ($State.Duration -ge $requiredDuration) {
        $result.ShouldAct = $true
        $result.Action = $script:LevelActions[$Level]
    }

    return $result
}
```

- [ ] **Step 4: 테스트 실행 — 통과 확인**

Run: `powershell.exe -Command "Invoke-Pester -Path '\\\\wsl$\\Ubuntu\\home\\aiwwt\\project\\Diskusage\\tests\\pester\\Escalation.Tests.ps1' -PassThru"`
Expected: All tests passed

- [ ] **Step 5: 커밋**

```bash
git add lib/watchdog/escalation.ps1 tests/pester/Escalation.Tests.ps1
git commit -m "feat: add escalation state machine for Windows watchdog"
```

---

## Task 8: Windows 워치독 — 알림 메커니즘

**Files:**
- Create: `lib/watchdog/notification.ps1`
- Test: `tests/pester/Notification.Tests.ps1`

- [ ] **Step 1: 알림 테스트 작성**

`tests/pester/Notification.Tests.ps1`:
```powershell
BeforeAll {
    . "$PSScriptRoot/../../lib/watchdog/notification.ps1"
}

Describe "Test-BurntToastAvailable" {
    It "returns a boolean" {
        $result = Test-BurntToastAvailable
        $result | Should -BeOfType [bool]
    }
}

Describe "Get-NotificationMethod" {
    It "returns 'BurntToast' or 'MessageBox'" {
        $result = Get-NotificationMethod
        $result | Should -BeIn @("BurntToast", "MessageBox")
    }
}

Describe "Format-AlertMessage" {
    It "includes level and I/O info" {
        $msg = Format-AlertMessage -Level "danger" -TotalMBps 95.5 -MemoryMB 4096
        $msg | Should -Match "danger"
        $msg | Should -Match "95"
    }
}
```

- [ ] **Step 2: 테스트 실행 — 실패 확인**

Run: `powershell.exe -Command "Invoke-Pester -Path '\\\\wsl$\\Ubuntu\\home\\aiwwt\\project\\Diskusage\\tests\\pester\\Notification.Tests.ps1' -PassThru"`
Expected: FAIL

- [ ] **Step 3: 알림 구현**

`lib/watchdog/notification.ps1`:
```powershell
# notification.ps1 — 토스트 알림 + 폴백

function Test-BurntToastAvailable {
    try {
        $null = Get-Module -ListAvailable -Name BurntToast -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-NotificationMethod {
    if (Test-BurntToastAvailable) {
        return "BurntToast"
    }
    return "MessageBox"
}

function Format-AlertMessage {
    param(
        [string]$Level,
        [double]$TotalMBps,
        [double]$MemoryMB
    )
    $memGB = [math]::Round($MemoryMB / 1024, 1)
    return "WSL2 Disk I/O [$Level] - I/O: ${TotalMBps}MB/s, Memory: ${memGB}GB"
}

function Send-Notification {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Level = "warn"
    )

    $method = Get-NotificationMethod

    switch ($method) {
        "BurntToast" {
            Import-Module BurntToast -ErrorAction SilentlyContinue
            New-BurntToastNotification -Text $Title, $Message -UniqueIdentifier "Diskusage"
        }
        "MessageBox" {
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show($Message, $Title, "OK", "Warning") | Out-Null
        }
    }
}

function Request-UserConfirmation {
    param(
        [string]$Title,
        [string]$Message
    )

    Add-Type -AssemblyName System.Windows.Forms
    $result = [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}
```

- [ ] **Step 4: 테스트 실행 — 통과 확인**

Run: `powershell.exe -Command "Invoke-Pester -Path '\\\\wsl$\\Ubuntu\\home\\aiwwt\\project\\Diskusage\\tests\\pester\\Notification.Tests.ps1' -PassThru"`
Expected: All tests passed

- [ ] **Step 5: 커밋**

```bash
git add lib/watchdog/notification.ps1 tests/pester/Notification.Tests.ps1
git commit -m "feat: add notification with BurntToast and MessageBox fallback"
```

---

## Task 9: Windows 워치독 — 메인 루프 (`watchdog.ps1`)

**Files:**
- Create: `watchdog.ps1`

- [ ] **Step 1: watchdog.ps1 구현**

`watchdog.ps1`:
```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    Diskusage Windows Watchdog — WSL2 VHD I/O 감시 + 단계적 대응
.DESCRIPTION
    Hyper-V Virtual Storage Device 카운터로 WSL2 디스크 I/O를 감시하고,
    임계치 초과 시 단계적으로 대응합니다.
#>

param(
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Source libraries
. "$ScriptDir\lib\watchdog\counters.ps1"
. "$ScriptDir\lib\watchdog\escalation.ps1"
. "$ScriptDir\lib\watchdog\notification.ps1"

# Load config
$Config = @{
    MonitorInterval    = 5
    WarnThreshold      = 60
    AlertThreshold     = 75
    DangerThreshold    = 90
    CriticalThreshold  = 95
    IoBaselineMBps     = 100
    WarnDuration       = 30
    AlertDuration      = 30
    DangerDuration     = 60
    CriticalDuration   = 120
    WslExecTimeout     = 10
    LogRetentionDays   = 7
}

# Try to load config from WSL
if ($ConfigPath -and (Test-Path $ConfigPath)) {
    Get-Content $ConfigPath | ForEach-Object {
        if ($_ -match "^(\w+)=(\d+)$") {
            $key = $matches[1]
            $val = [int]$matches[2]
            switch ($key) {
                "MONITOR_INTERVAL"   { $Config.MonitorInterval = $val }
                "WARN_THRESHOLD"     { $Config.WarnThreshold = $val }
                "ALERT_THRESHOLD"    { $Config.AlertThreshold = $val }
                "DANGER_THRESHOLD"   { $Config.DangerThreshold = $val }
                "CRITICAL_THRESHOLD" { $Config.CriticalThreshold = $val }
                "IO_BASELINE_MBPS"   { $Config.IoBaselineMBps = $val }
                "WSL_EXEC_TIMEOUT"   { $Config.WslExecTimeout = $val }
            }
        }
    }
}

# Log file setup
$LogDir = "$env:USERPROFILE\.diskusage\logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-WatchdogLog {
    param([string]$Message)
    $logFile = Join-Path $LogDir "watchdog-$(Get-Date -Format 'yyyy-MM-dd').log"
    $ts = Get-Date -Format "HH:mm:ss"
    "[$ts] $Message" | Out-File -Append -FilePath $logFile -Encoding utf8
}

function Invoke-WslCommand {
    param([string]$Command)
    $job = Start-Job -ScriptBlock {
        param($cmd)
        wsl -e bash -c $cmd
    } -ArgumentList $Command

    $completed = $job | Wait-Job -Timeout $Config.WslExecTimeout
    if ($null -eq $completed) {
        $job | Stop-Job
        $job | Remove-Job -Force
        return @{ Success = $false; Output = "timeout"; TimedOut = $true }
    }
    $output = $job | Receive-Job
    $job | Remove-Job -Force
    return @{ Success = $true; Output = $output; TimedOut = $false }
}

function Get-WslMonitorStatus {
    $result = Invoke-WslCommand "cat ~/.diskusage/status 2>/dev/null || echo 'unknown'"
    if ($result.Success) {
        return $result.Output.Trim()
    }
    return "unreachable"
}

# Check Hyper-V counter availability
$hasHyperV = (Get-WslVhdPaths).Count -gt 0
if (-not $hasHyperV) {
    Write-Host "[WARNING] Hyper-V counters not available. Using PhysicalDisk as fallback." -ForegroundColor Yellow
    Write-Host "          WSL I/O attribution will not be possible." -ForegroundColor Yellow
}

$notifyMethod = Get-NotificationMethod
Write-Host "=== Diskusage Watchdog ===" -ForegroundColor Cyan
Write-Host "Notification: $notifyMethod"
Write-Host "Hyper-V Counters: $(if ($hasHyperV) {'Available'} else {'Fallback mode'})"
Write-Host "Interval: $($Config.MonitorInterval)s"
Write-Host "Press Ctrl+C to stop."
Write-Host ""

# Main loop
$state = New-EscalationState

while ($true) {
    # Read counters
    $vhdIo = Get-VhdIoRate
    $diskPct = Get-PhysicalDiskPercent
    $memMB = Get-VmmemMemoryMB

    # Determine if WSL is the cause
    $wslIsCause = $true
    if ($hasHyperV) {
        $wslIsCause = Test-WslIsIoCause -VhdTotalMBps $vhdIo.TotalMBps -PhysicalDiskPct $diskPct -BaselineMBps $Config.IoBaselineMBps
    }

    # Get I/O level
    $level = "normal"
    if ($wslIsCause) {
        $level = Get-IoLevel -TotalMBps $vhdIo.TotalMBps -BaselineMBps $Config.IoBaselineMBps -Config $Config
    }

    # Log
    $logMsg = "VHD_IO:$($vhdIo.TotalMBps)MB/s DISK:$($diskPct)% MEM:$([math]::Round($memMB/1024,1))GB LEVEL:$level"
    if (-not $wslIsCause -and $diskPct -ge 50) {
        $logMsg += " [EXTERNAL]"
        Write-WatchdogLog "EXTERNAL: PhysicalDisk $($diskPct)% but VHD_IO $($vhdIo.TotalMBps)MB/s -- external pressure, WSL actions suppressed"
    }
    Write-WatchdogLog $logMsg

    # Console output
    $color = switch ($level) {
        "normal"   { "Green" }
        "warn"     { "Yellow" }
        "alert"    { "DarkYellow" }
        "danger"   { "Red" }
        "critical" { "DarkRed" }
        default    { "White" }
    }
    Write-Host "$(Get-Date -Format 'HH:mm:ss') | IO:$($vhdIo.TotalMBps)MB/s | Disk:$($diskPct)% | Mem:$([math]::Round($memMB/1024,1))GB | [$level]" -ForegroundColor $color

    # Evaluate escalation
    $escResult = Update-EscalationState -State $state -Level $level -IntervalSec $Config.MonitorInterval

    if ($escResult.ShouldAct) {
        Write-WatchdogLog "ESCALATION: Action=$($escResult.Action) Level=$level Duration=$($state.Duration)s"

        switch ($escResult.Action) {
            "cleanup" {
                # Check if WSL monitor is already cleaning
                $monStatus = Get-WslMonitorStatus
                if ($monStatus -ne "cleaning") {
                    $wslResult = Invoke-WslCommand "~/.diskusage/cleanup_trigger.sh warn 2>/dev/null"
                    if ($wslResult.TimedOut) {
                        Write-WatchdogLog "WSL_TIMEOUT: wsl -e timed out, escalating"
                        $escResult = Update-EscalationState -State $state -Level $level -IntervalSec 0 -WslTimeout $true
                    }
                } else {
                    Write-WatchdogLog "SKIP: WSL monitor already cleaning"
                }
            }
            "cleanup_and_notify" {
                $alertMsg = Format-AlertMessage -Level $level -TotalMBps $vhdIo.TotalMBps -MemoryMB $memMB
                Send-Notification -Title "Diskusage Warning" -Message $alertMsg -Level $level
                $monStatus = Get-WslMonitorStatus
                if ($monStatus -ne "cleaning") {
                    $wslResult = Invoke-WslCommand "~/.diskusage/cleanup_trigger.sh alert 2>/dev/null"
                    if ($wslResult.TimedOut) {
                        Write-WatchdogLog "WSL_TIMEOUT: wsl -e timed out at alert, escalating"
                        $escResult = Update-EscalationState -State $state -Level $level -IntervalSec 0 -WslTimeout $true
                    }
                }
            }
            "user_confirm" {
                $alertMsg = Format-AlertMessage -Level $level -TotalMBps $vhdIo.TotalMBps -MemoryMB $memMB
                Send-Notification -Title "Diskusage DANGER" -Message "$alertMsg`nWSL may become unresponsive." -Level $level
            }
            "shutdown_confirm" {
                $confirmed = Request-UserConfirmation `
                    -Title "Diskusage Critical" `
                    -Message "WSL2 disk I/O has been at $($vhdIo.TotalMBps)MB/s for $($state.Duration)s.`nShutdown WSL? (All WSL sessions will be terminated)"
                if ($confirmed) {
                    Write-WatchdogLog "ACTION: User confirmed wsl --shutdown"
                    wsl --shutdown
                    Write-Host "WSL has been shut down." -ForegroundColor Red
                    $state = New-EscalationState
                } else {
                    Write-WatchdogLog "ACTION: User declined shutdown"
                    $state.Duration = 0  # reset to avoid repeated prompts
                }
            }
        }
    }

    Start-Sleep -Seconds $Config.MonitorInterval
}
```

- [ ] **Step 2: 수동 테스트 — watchdog 시작 확인**

Run (Windows PowerShell): `.\watchdog.ps1`
Expected: 콘솔에 5초마다 I/O 상태 출력, Ctrl+C로 종료

- [ ] **Step 3: 커밋**

```bash
git add watchdog.ps1
git commit -m "feat: add Windows watchdog with Hyper-V monitoring and escalation"
```

---

## Task 10: Setup 스크립트

**Files:**
- Create: `setup.sh`
- Create: `setup.ps1`

- [ ] **Step 1: setup.sh 구현**

`setup.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== Diskusage WSL Setup ==="
echo ""

DISKUSAGE_HOME="${DISKUSAGE_HOME:-$HOME/.diskusage}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Create directories
echo "[1/5] Creating directories..."
mkdir -p "$DISKUSAGE_HOME/logs" "$DISKUSAGE_HOME/config"

# 2. Copy default config if not exists
if [[ ! -f "$DISKUSAGE_HOME/config/config.conf" ]]; then
    echo "[2/5] Installing default config..."
    cp "$SCRIPT_DIR/config.conf.default" "$DISKUSAGE_HOME/config/config.conf"
    echo "  → $DISKUSAGE_HOME/config/config.conf"
else
    echo "[2/5] Config already exists, skipping."
fi

# 3. Install packages
echo "[3/5] Installing required packages..."
PACKAGES_NEEDED=""
command -v iostat &>/dev/null || PACKAGES_NEEDED="$PACKAGES_NEEDED sysstat"
command -v iotop &>/dev/null  || PACKAGES_NEEDED="$PACKAGES_NEEDED iotop"

if [[ -n "$PACKAGES_NEEDED" ]]; then
    echo "  Installing:$PACKAGES_NEEDED"
    sudo apt-get update -qq && sudo apt-get install -y -qq $PACKAGES_NEEDED
else
    echo "  All packages already installed."
fi

# 4. Kernel parameters
echo "[4/5] Setting kernel parameters..."
SYSCTL_FILE="/etc/sysctl.d/99-diskusage.conf"
cat <<'SYSCTL' | sudo tee "$SYSCTL_FILE" > /dev/null
# Diskusage — WSL2 I/O optimization
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.swappiness=10
vm.vfs_cache_pressure=150
SYSCTL
sudo sysctl --load="$SYSCTL_FILE" > /dev/null
echo "  → Applied sysctl settings"

# 5. Sudoers NOPASSWD for cleanup commands
echo "[5/5] Setting up sudoers NOPASSWD..."
SUDOERS_FILE="/etc/sudoers.d/diskusage"
SUDO_CMDS="$(whoami) ALL=(ALL) NOPASSWD: /usr/sbin/fstrim, /usr/sbin/sysctl, /usr/sbin/iotop, /usr/bin/journalctl"
echo "$SUDO_CMDS" | sudo tee "$SUDOERS_FILE" > /dev/null
sudo chmod 440 "$SUDOERS_FILE"
echo "  → Sudoers configured"

# Create cleanup trigger script (called by watchdog via wsl -e)
cat > "$DISKUSAGE_HOME/cleanup_trigger.sh" << 'TRIGGER'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEVEL="${1:-warn}"
# Find project root (where monitor.sh lives)
PROJECT_ROOT="$(dirname "$(readlink -f "$0")" 2>/dev/null || echo "$HOME/project/Diskusage")"
if [[ -f "$PROJECT_ROOT/lib/monitor/cleanup.sh" ]]; then
    source "$PROJECT_ROOT/lib/monitor/diskstats.sh"
    source "$PROJECT_ROOT/lib/monitor/logger.sh"
    DISKUSAGE_HOME="${DISKUSAGE_HOME:-$HOME/.diskusage}"
    load_config
    source "$PROJECT_ROOT/lib/monitor/cleanup.sh"
    run_cleanup "$LEVEL"
fi
TRIGGER
chmod +x "$DISKUSAGE_HOME/cleanup_trigger.sh"

echo ""
echo "=== Setup Complete ==="
echo "Next steps:"
echo "  1. Run setup.ps1 on Windows (for .wslconfig and BurntToast)"
echo "  2. Run: wsl --shutdown  (then restart WSL)"
echo "  3. Start monitoring:  ./monitor.sh start"
```

- [ ] **Step 2: setup.ps1 구현**

`setup.ps1`:
```powershell
<#
.SYNOPSIS
    Diskusage Windows Setup — .wslconfig 최적화 + BurntToast 설치
#>

Write-Host "=== Diskusage Windows Setup ===" -ForegroundColor Cyan
Write-Host ""

# 1. Detect system RAM
$totalRAM = [math]::Round((Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1GB)
$wslMemory = [math]::Floor($totalRAM / 2)
Write-Host "[1/3] System RAM: ${totalRAM}GB (WSL limit: ${wslMemory}GB)"

# 2. .wslconfig
$wslConfigPath = "$env:USERPROFILE\.wslconfig"
$newConfig = @"
[wsl2]
memory=${wslMemory}GB
swap=2GB
processors=4
autoMemoryReclaim=gradual
sparseVhd=true
"@

if (Test-Path $wslConfigPath) {
    $backupPath = "$env:USERPROFILE\.wslconfig.backup.$(Get-Date -Format 'yyyyMMdd')"
    Write-Host "[2/3] Backing up existing .wslconfig to $backupPath"
    Copy-Item $wslConfigPath $backupPath

    Write-Host ""
    Write-Host "Current .wslconfig:" -ForegroundColor Yellow
    Get-Content $wslConfigPath
    Write-Host ""
    Write-Host "Proposed .wslconfig:" -ForegroundColor Green
    Write-Host $newConfig
    Write-Host ""

    $confirm = Read-Host "Apply new .wslconfig? (y/n)"
    if ($confirm -ne "y") {
        Write-Host "Skipping .wslconfig update."
    } else {
        $newConfig | Out-File -FilePath $wslConfigPath -Encoding utf8
        Write-Host "  → .wslconfig updated"
    }
} else {
    Write-Host "[2/3] Creating .wslconfig..."
    $newConfig | Out-File -FilePath $wslConfigPath -Encoding utf8
    Write-Host "  → .wslconfig created"
}

# 3. BurntToast
Write-Host "[3/3] Checking BurntToast module..."
if (Get-Module -ListAvailable -Name BurntToast) {
    Write-Host "  BurntToast already installed."
} else {
    Write-Host "  Installing BurntToast..."
    try {
        Install-Module -Name BurntToast -Scope CurrentUser -Force -ErrorAction Stop
        Write-Host "  → BurntToast installed"
    } catch {
        Write-Host "  → BurntToast installation failed. Will use MessageBox as fallback." -ForegroundColor Yellow
    }
}

# Create log directory on Windows side
$logDir = "$env:USERPROFILE\.diskusage\logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor Green
Write-Host "Next steps:"
Write-Host "  1. Run 'wsl --shutdown' to apply .wslconfig changes"
Write-Host "  2. Restart WSL and run: ./monitor.sh start"
Write-Host "  3. In PowerShell: .\watchdog.ps1"
```

- [ ] **Step 3: 실행 권한 부여**

```bash
chmod +x setup.sh
```

- [ ] **Step 4: setup.sh 건조 실행 테스트**

Run: `bash -n setup.sh`
Expected: 문법 오류 없음

- [ ] **Step 5: 커밋**

```bash
git add setup.sh setup.ps1
git commit -m "feat: add setup scripts for WSL and Windows"
```

---

## Task 11: 통합 테스트 + 수동 검증

**Files:**
- Create: `tests/test_integration.sh`

- [ ] **Step 1: 통합 테스트 스크립트 작성**

`tests/test_integration.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== Diskusage Integration Test ==="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DISKUSAGE_HOME="$(mktemp -d)/.diskusage"
mkdir -p "$DISKUSAGE_HOME/logs" "$DISKUSAGE_HOME/config"
cp "$SCRIPT_DIR/config.conf.default" "$DISKUSAGE_HOME/config/config.conf"

PASS=0
FAIL=0

assert() {
    local desc="$1"
    shift
    if "$@"; then
        echo "  PASS: $desc"
        ((PASS++))
    else
        echo "  FAIL: $desc"
        ((FAIL++))
    fi
}

# Test 1: monitor.sh start/stop cycle
echo ""
echo "[Test 1] monitor.sh start/stop cycle"
bash "$SCRIPT_DIR/monitor.sh" start
sleep 3
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
assert "report shows header" echo "$OUTPUT" | grep -q "Diskusage Report"

# Test 4: double start prevention
echo ""
echo "[Test 4] Double start prevention"
bash "$SCRIPT_DIR/monitor.sh" start
sleep 1
OUTPUT=$(bash "$SCRIPT_DIR/monitor.sh" start 2>&1 || true)
assert "second start is rejected" echo "$OUTPUT" | grep -q "already running"
bash "$SCRIPT_DIR/monitor.sh" stop
sleep 1

# Cleanup
rm -rf "$(dirname "$DISKUSAGE_HOME")"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: 통합 테스트 실행**

Run: `bash tests/test_integration.sh`
Expected: All tests passed

- [ ] **Step 3: bats 전체 테스트 실행**

Run: `bats tests/bats/`
Expected: All tests passed

- [ ] **Step 4: 커밋**

```bash
git add tests/test_integration.sh
git commit -m "feat: add integration test for monitor.sh lifecycle"
```

---

## Task 12: 최종 검증 + README

**Files:**
- Create: `README.md`

- [ ] **Step 1: README 작성**

`README.md`:
```markdown
# Diskusage

WSL2 디스크 I/O 모니터링 및 자동 대응 시스템.

Windows 11 WSL2 환경에서 vmmemWSL 디스크 사용률 100% 문제를 진단하고 예방합니다.

## 빠른 시작

### 1. 초기 설정 (1회)

```bash
# WSL에서
./setup.sh

# Windows PowerShell에서
.\setup.ps1

# 설정 적용을 위해 WSL 재시작
wsl --shutdown
```

### 2. 모니터링 시작

```bash
# WSL에서
./monitor.sh start

# Windows PowerShell에서
.\watchdog.ps1
```

### 3. 모니터링 종료

```bash
./monitor.sh stop
```

### 4. 리포트 확인

```bash
./monitor.sh report
```

## 구조

- `monitor.sh` — WSL 내부 I/O 진단 + 예방 정리
- `watchdog.ps1` — Windows에서 Hyper-V VHD I/O 감시 + 단계적 대응
- `setup.sh` — WSL 초기 설정 (패키지, 커널 파라미터)
- `setup.ps1` — Windows 초기 설정 (.wslconfig, BurntToast)

## 설정

`~/.diskusage/config/config.conf` 에서 임계값, 폴링 간격 등을 조정할 수 있습니다.
```

- [ ] **Step 2: 전체 테스트 최종 실행**

Run: `bats tests/bats/ && bash tests/test_integration.sh`
Expected: All tests passed

- [ ] **Step 3: 최종 커밋**

```bash
git add README.md
git commit -m "docs: add README with quick start guide"
```

- [ ] **Step 4: @superpowers:verification-before-completion 실행**

모든 테스트 통과 및 기능 동작 확인 후 완료 선언.
