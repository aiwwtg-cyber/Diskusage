# Diskusage - WSL2 디스크 I/O 모니터링 및 자동 대응 시스템

## 개요

Windows 11 WSL2 환경에서 `vmmemWSL` 프로세스의 디스크 사용률이 100%로 치솟아 WSL이 먹통이 되는 문제를 진단하고 예방하는 듀얼 워치독 시스템.

## 문제 정의

- WSL2에서 Claude Code 등 작업 시 디스크 I/O가 100%로 올라감
- 한번 100%가 되면 WSL 내부에서 키 입력이 안 먹힘
- `wsl --shutdown` 외에는 복구 방법이 없음
- 원인 패턴이 불명확하여 진단이 필요

## 아키텍처: 듀얼 워치독

```
┌─────────────────────────────────────────┐
│              Windows 11                  │
│                                          │
│  ┌──────────────────────────────────┐   │
│  │   watchdog.ps1 (PowerShell)      │   │
│  │   - Hyper-V VHD 카운터로 감시    │   │
│  │   - 단계적 대응 (알림→킬→종료)    │   │
│  │   - 로그 기록                     │   │
│  └──────────┬───────────────────────┘   │
│             │ wsl -e (10초 타임아웃)      │
│             │ wsl --shutdown (최후)       │
│  ┌──────────▼───────────────────────┐   │
│  │         WSL2 Ubuntu               │   │
│  │                                    │   │
│  │  ┌────────────────────────────┐   │   │
│  │  │  monitor.sh (Bash)         │   │   │
│  │  │  - 자율적 I/O 감시 + 정리  │   │   │
│  │  │  - 진단 로그 기록           │   │   │
│  │  │  - 상태 파일로 조율         │   │   │
│  │  └────────────────────────────┘   │   │
│  │                                    │   │
│  │  ┌────────────────────────────┐   │   │
│  │  │  setup.sh + setup.ps1      │   │   │
│  │  │  - .wslconfig 최적화       │   │   │
│  │  │  - 필요 패키지/모듈 설치    │   │   │
│  │  └────────────────────────────┘   │   │
│  └────────────────────────────────────┘  │
└──────────────────────────────────────────┘
```

### 구성 파일

| 파일 | 위치 | 역할 |
|------|------|------|
| `watchdog.ps1` | Windows 아무 경로 | WSL VHD I/O 감시 + 단계적 대응 |
| `monitor.sh` | WSL 프로젝트 루트 | 자율적 I/O 진단 + 예방 정리 |
| `setup.sh` | WSL 프로젝트 루트 | WSL 측 초기 환경 설정 |
| `setup.ps1` | Windows 아무 경로 | Windows 측 초기 설정 (BurntToast 등) |

## 컴포넌트 상세

### 1. Windows 워치독 (`watchdog.ps1`)

**모니터링 대상 (Hyper-V Virtual Storage Device 카운터):**
- `Hyper-V Virtual Storage Device(*wsl*ext4*)\Read Bytes/sec` — WSL ext4.vhdx 읽기량
- `Hyper-V Virtual Storage Device(*wsl*ext4*)\Write Bytes/sec` — WSL ext4.vhdx 쓰기량
- `Hyper-V Virtual Storage Device(*swap*)\Read Bytes/sec` — WSL swap.vhdx 읽기량
- `Hyper-V Virtual Storage Device(*swap*)\Write Bytes/sec` — WSL swap.vhdx 쓰기량
- `PhysicalDisk(_Total)\% Disk Time` — 보조 지표 (상관관계 분석용)
- `Get-Process vmmem` — vmmemWSL 메모리 사용량 (I/O는 사용 불가)
- 감시 주기: 5초

**WSL I/O vs 시스템 I/O 구분:**
- Hyper-V VHD I/O가 높고 + PhysicalDisk도 높으면 → WSL이 원인 → 대응 실행
- Hyper-V VHD I/O가 낮고 + PhysicalDisk만 높으면 → 외부 원인 → "외부 디스크 부하 감지" 로그, WSL 대응 억제

**단계적 대응 (WSL VHD I/O 기준):**

임계값은 WSL VHD의 Read+Write Bytes/sec 합산 기준으로 판단합니다.
초기 기본값은 100MB/s를 기준으로 비율로 환산하며, 사용자 환경에 맞게 config에서 조정합니다.

| 단계 | I/O 수준 | 지속 시간 | 대응 |
|------|---------|----------|------|
| 정상 | 기준 미만 | - | 로그만 기록 |
| 주의 | 60%+ | 30초 이상 | `wsl -e` 정리 호출 (10초 타임아웃) |
| 경고 | 75%+ | 30초 이상 | Windows 토스트 알림 + `wsl -e` 정리 호출 |
| 위험 | 90%+ | 60초 이상 | 토스트 알림으로 사용자에게 확인 요청 |
| 최후 | 95%+ | 120초 이상 | 사용자 확인 후 `wsl --shutdown` |

**`wsl -e` 타임아웃 및 에스컬레이션:**
- 모든 `wsl -e` 호출에 10초 타임아웃 적용
- 타임아웃 발생 시 현재 단계를 건너뛰고 다음 단계로 즉시 에스컬레이션
- 예: 주의 단계에서 `wsl -e` 타임아웃 → 경고 단계로 즉시 승격

**알림 메커니즘:**
- 1순위: BurntToast PowerShell 모듈 (토스트 알림)
- 폴백: `[System.Windows.Forms.MessageBox]` (BurntToast 미설치 시)
- `watchdog.ps1` 시작 시 BurntToast 존재 여부 확인 후 자동 선택

**핵심 규칙:**
- `wsl --shutdown`은 절대 자동 실행 안 함 — 항상 사용자 확인 필요
- 각 단계는 "지속 시간" 조건을 만족해야 발동 (일시적 스파이크 무시)
- 모든 이벤트는 로그 파일에 기록

### 2. WSL 모니터 (`monitor.sh`)

**자율적 동작:**
monitor.sh는 Windows 워치독의 `wsl -e` 호출에만 의존하지 않고, 자체적으로 `/proc/diskstats`를 읽어 I/O 상태를 판단하고 독립적으로 정리 액션을 실행합니다. WSL이 아직 응답 가능한 상태에서 선제적으로 대응합니다.

**진단 수집 (적응형 폴링):**
- 정상 시: 5초 간격
- 디스크 I/O 경고 수준 초과 시: 15초 간격 (모니터링 자체의 I/O 부하 감소)

기본 수집 (매 주기):
- `/proc/diskstats` — 디스크 I/O 통계
- `free -m` — 메모리/스왑 사용량

확장 수집 (경고 수준 초과 시에만):
- `iotop -b -o -n 1` — 프로세스별 I/O (root 권한 필요, NOPASSWD 설정)
- `df -h` — 디스크 공간

**자동 식별:**
- I/O를 가장 많이 유발하는 Top 5 프로세스를 실시간 추적
- 급격한 I/O 증가 감지 시 해당 프로세스명 + PID + 파일 경로 로그 기록

**안전한 예방적 정리 액션:**

| 액션 | 명령 | 효과 |
|------|------|------|
| 저널 로그 축소 | `journalctl --vacuum-size=50M` | 디스크 공간 확보 |
| 임시 파일 정리 | `/tmp`, 캐시 디렉토리 정리 | 공간 확보 |
| 가상 디스크 트림 | `fstrim /` | ext4.vhdx 공간 회수 |

**제외된 위험 액션 (의도적으로 제외):**
- `drop_caches` — 캐시 제거 후 재읽기로 I/O 증가 역효과 가능
- `swapoff -a` — RAM 부족 시 OOM Kill 위험

**상태 파일 조율 (`~/.diskusage/status`):**
- monitor.sh는 현재 상태(idle/cleaning/monitoring)를 `~/.diskusage/status`에 기록
- watchdog.ps1은 `wsl -e cat ~/.diskusage/status` 로 확인 후, 이미 정리 중이면 중복 호출 건너뜀
- 이를 통해 watchdog과 monitor 간 충돌 방지

**프로세스 관리:**
- `./monitor.sh start` — 백그라운드 실행, PID를 `~/.diskusage/monitor.pid`에 기록
- `./monitor.sh stop` — PID 파일 읽어서 SIGTERM 전송, PID 파일 정리
- `./monitor.sh status` — 현재 실행 상태 확인
- stale PID 체크: stop 시 PID가 실제 monitor.sh 프로세스인지 프로세스명 확인 후 종료

**로그 출력:**
- `~/.diskusage/logs/` 에 날짜별 진단 로그 저장

### 3. 초기 설정

#### `setup.sh` (WSL 측)

**WSL 커널 파라미터 (`/etc/sysctl.d/99-diskusage.conf`):**

```ini
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.swappiness=10
vm.vfs_cache_pressure=150
```

**필요 패키지 (필수):** `sysstat` (iostat), `iotop`

**선택 패키지:** `inotify-tools` (파일 변경 감시)

**디렉토리 생성:** `~/.diskusage/logs/`, `~/.diskusage/config/`

**sudo NOPASSWD 설정:** `sysctl`, `fstrim`, `iotop`, `journalctl` 에 한정

#### `setup.ps1` (Windows 측)

**`.wslconfig` 생성/최적화 (Windows `%UserProfile%\.wslconfig`):**
- 기존 `.wslconfig`를 `.wslconfig.backup.YYYYMMDD`로 백업
- 시스템 총 RAM 감지: `(Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1GB`
- memory는 총 RAM의 50% 이하로 설정 (Windows 메모리 압박 방지)
- 변경 사항을 사용자에게 표시하고 확인 요청

```ini
[wsl2]
memory={동적: 총RAM의 50%}
swap=2GB
processors=4
autoMemoryReclaim=gradual
sparseVhd=true
```

참고: `autoMemoryReclaim`은 현재 WSL 버전에서 `[wsl2]` 섹션에 위치 (더 이상 `[experimental]` 아님). `localhostForwarding`은 디스크 I/O와 무관하여 제외.

**BurntToast 모듈 설치:**
- `Install-Module -Name BurntToast -Scope CurrentUser` (관리자 권한 불필요)
- 설치 실패 시 폴백 알림 메커니즘 안내

## 설정 파일

`~/.diskusage/config/config.conf`:

```ini
# 감시 주기 (초)
MONITOR_INTERVAL=5
# 경고 수준 초과 시 폴링 간격 (초)
MONITOR_INTERVAL_HIGH=15

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

## 사용 흐름

```
1. 최초 1회:
   ├─ WSL에서:    ./setup.sh          (패키지, 커널 파라미터, 디렉토리)
   └─ Windows에서: .\setup.ps1         (.wslconfig, BurntToast)
   └─ wsl --shutdown 후 재시작 (설정 적용)

2. 작업 시작 전:
   ├─ WSL에서:  ./monitor.sh start   (백그라운드 실행)
   └─ Windows:  .\watchdog.ps1        (PowerShell 창에서 실행)

3. 작업 중:
   ├─ monitor.sh: 자율적으로 진단 수집 + 예방 정리
   └─ watchdog.ps1: VHD I/O 감시 + 임계치 초과 시 단계적 대응

4. 작업 종료:
   └─ ./monitor.sh stop

5. 사후 분석 (선택):
   └─ ./monitor.sh report   → 최근 로그 요약 출력
```

## 로그 형식

`~/.diskusage/logs/2026-03-20.log`:

```
[14:32:05] VHD_IO:45MB/s MEM:3.2G/8G SWAP:0.1G/2G TOP_IO: node(pid:1234,R:5MB/s,W:12MB/s)
[14:32:10] VHD_IO:72MB/s MEM:5.1G/8G SWAP:0.8G/2G TOP_IO: git(pid:5678,R:45MB/s,W:2MB/s)
[14:32:10] ACTION: journalctl vacuum applied
[14:32:15] VHD_IO:68MB/s MEM:4.8G/8G SWAP:0.5G/2G TOP_IO: git(pid:5678,R:20MB/s,W:1MB/s)
[14:33:00] EXTERNAL: PhysicalDisk 95% but VHD_IO 12MB/s — external disk pressure, WSL actions suppressed
```

**로그 로테이션:**
- `monitor.sh` 시작 시 + 실행 중 1시간마다 오래된 로그 정리
- `LOG_RETENTION_DAYS` (기본 7일) 이전 로그 삭제
- `MAX_LOG_SIZE_MB` (기본 50MB) 초과 시 해당 일자 로그를 트렁케이트

## 기술 스택

- **Windows 측:** PowerShell 5.1+ (Windows 11 기본 내장)
- **WSL 측:** Bash + 표준 Linux 도구 (iotop, /proc 파일시스템)
- **알림:** BurntToast PowerShell 모듈 (1순위), System.Windows.Forms.MessageBox (폴백)

## 에러 처리

- `wsl -e` 타임아웃 (10초): 실패 시 다음 단계로 즉시 에스컬레이션, 로그 기록
- WSL 완전 응답 없음: Windows 워치독이 독립적으로 사용자에게 알림
- 권한 부족: setup.sh에서 NOPASSWD 미설정 시 안내 메시지 출력, 가능한 액션만 실행
- 로그 디스크 풀: MAX_LOG_SIZE_MB + LOG_RETENTION_DAYS 기반 자동 로테이션
- Hyper-V 카운터 없음: 일부 Windows Home 에디션에서 미지원 시 PhysicalDisk 카운터로 폴백 + 경고 표시

## 테스트 전략

- **단위 테스트:** 각 함수별 입출력 검증 (임계값 판단 로직, 로그 파싱 등)
- **통합 테스트:** 인위적 디스크 부하 생성 후 단계별 대응 동작 확인
- **수동 테스트:** 실제 Claude Code 작업 중 모니터링 동작 확인
