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
│  │   - vmmemWSL 디스크 I/O 감시     │   │
│  │   - 단계적 대응 (알림→킬→종료)    │   │
│  │   - 로그 기록                     │   │
│  └──────────┬───────────────────────┘   │
│             │ wsl -e (정상 시)            │
│             │ wsl --shutdown (최후)       │
│  ┌──────────▼───────────────────────┐   │
│  │         WSL2 Ubuntu               │   │
│  │                                    │   │
│  │  ┌────────────────────────────┐   │   │
│  │  │  monitor.sh (Bash)         │   │   │
│  │  │  - I/O 원인 프로세스 추적   │   │   │
│  │  │  - 예방적 정리              │   │   │
│  │  │  - 진단 로그 기록           │   │   │
│  │  └────────────────────────────┘   │   │
│  │                                    │   │
│  │  ┌────────────────────────────┐   │   │
│  │  │  setup.sh                  │   │   │
│  │  │  - .wslconfig 최적화       │   │   │
│  │  │  - 필요 패키지 설치         │   │   │
│  │  └────────────────────────────┘   │   │
│  └────────────────────────────────────┘  │
└──────────────────────────────────────────┘
```

### 구성 파일

| 파일 | 위치 | 역할 |
|------|------|------|
| `watchdog.ps1` | Windows 아무 경로 | vmmemWSL 감시 + 단계적 대응 |
| `monitor.sh` | WSL 프로젝트 루트 | I/O 진단 + 예방 정리 |
| `setup.sh` | WSL 프로젝트 루트 | 초기 환경 설정 (1회 실행) |

## 컴포넌트 상세

### 1. Windows 워치독 (`watchdog.ps1`)

**모니터링 대상:**
- `Get-Counter '\PhysicalDisk(_Total)\% Disk Time'` — 전체 디스크 사용률
- `Get-Process vmmem` — vmmemWSL 메모리/I/O 사용량
- 감시 주기: 5초

**단계적 대응:**

| 단계 | 디스크 사용률 | 지속 시간 | 대응 |
|------|-------------|----------|------|
| 정상 | ~60% 미만 | - | 로그만 기록 |
| 주의 | 60~75% | 30초 이상 | `wsl -e`로 WSL 내부 정리 스크립트 호출 |
| 경고 | 75~90% | 30초 이상 | Windows 토스트 알림 + WSL 내부 공격적 정리 |
| 위험 | 90%+ | 60초 이상 | 토스트 알림으로 사용자에게 확인 요청 |
| 최후 | 95%+ | 120초 이상 | 사용자 확인 후 `wsl --shutdown` |

**핵심 규칙:**
- `wsl --shutdown`은 절대 자동 실행 안 함 — 항상 사용자 확인 필요
- 각 단계는 "지속 시간" 조건을 만족해야 발동 (일시적 스파이크 무시)
- 모든 이벤트는 로그 파일에 기록

### 2. WSL 모니터 (`monitor.sh`)

**진단 수집 (5초 주기):**
- `/proc/diskstats` — 디스크 I/O 통계
- `/proc/[pid]/io` — 프로세스별 I/O 읽기/쓰기량 추적
- `free -m` — 메모리/스왑 사용량
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

**로그 출력:**
- `~/.diskusage/logs/` 에 날짜별 진단 로그 저장

### 3. 초기 설정 (`setup.sh`)

**`.wslconfig` 생성/최적화 (Windows `%UserProfile%\.wslconfig`):**

```ini
[wsl2]
memory=8GB
swap=2GB
processors=4
localhostForwarding=true

[experimental]
autoMemoryReclaim=gradual
sparseVhd=true
```

**WSL 커널 파라미터 (`/etc/sysctl.d/99-diskusage.conf`):**

```ini
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.swappiness=10
vm.vfs_cache_pressure=150
```

**필요 패키지:** `sysstat`, `inotify-tools` (선택)

**디렉토리 생성:** `~/.diskusage/logs/`, `~/.diskusage/config/`

**sudo NOPASSWD:** `sysctl`, `fstrim` 등 정리 명령에 한정

## 설정 파일

`~/.diskusage/config/config.conf`:

```ini
# 감시 주기 (초)
MONITOR_INTERVAL=5

# Windows 워치독 임계값
WARN_THRESHOLD=60
ALERT_THRESHOLD=75
DANGER_THRESHOLD=90
CRITICAL_THRESHOLD=95

# 지속 시간 (초)
WARN_DURATION=30
ALERT_DURATION=30
DANGER_DURATION=60
CRITICAL_DURATION=120

# 로그 보관 기간 (일)
LOG_RETENTION_DAYS=7
```

## 사용 흐름

```
1. 최초 1회: setup.sh 실행
   └─ .wslconfig 설정, 패키지 설치, 커널 파라미터 적용

2. 작업 시작 전:
   ├─ WSL에서:  ./monitor.sh start   (백그라운드 실행)
   └─ Windows:  .\watchdog.ps1        (PowerShell 창에서 실행)

3. 작업 중:
   ├─ monitor.sh: 조용히 진단 수집 + 예방 정리
   └─ watchdog.ps1: 디스크 감시 + 임계치 초과 시 단계적 대응

4. 작업 종료:
   └─ ./monitor.sh stop

5. 사후 분석 (선택):
   └─ ./monitor.sh report   → 최근 로그 요약 출력
```

## 로그 형식

`~/.diskusage/logs/2026-03-20.log`:

```
[14:32:05] DISK:45% MEM:3.2G/8G SWAP:0.1G/2G TOP_IO: node(pid:1234,R:5MB/s,W:12MB/s)
[14:32:10] DISK:72% MEM:5.1G/8G SWAP:0.8G/2G TOP_IO: git(pid:5678,R:45MB/s,W:2MB/s)
[14:32:10] ACTION: sysctl vm.dirty_ratio applied
[14:32:15] DISK:68% MEM:4.8G/8G SWAP:0.5G/2G TOP_IO: git(pid:5678,R:20MB/s,W:1MB/s)
```

## 기술 스택

- **Windows 측:** PowerShell 5.1+ (Windows 11 기본 내장)
- **WSL 측:** Bash + 표준 Linux 도구 (iostat, /proc 파일시스템)
- **알림:** Windows BurntToast PowerShell 모듈 (토스트 알림)

## 에러 처리

- WSL이 응답 없을 때: `wsl -e` 타임아웃 설정 → 실패 시 사용자에게 알림
- 권한 부족: setup.sh에서 NOPASSWD 미설정 시 안내 메시지 출력
- 로그 디스크 풀: LOG_RETENTION_DAYS 기반 자동 로테이션

## 테스트 전략

- **단위 테스트:** 각 함수별 입출력 검증 (임계값 판단 로직, 로그 파싱 등)
- **통합 테스트:** 인위적 디스크 부하 생성 후 단계별 대응 동작 확인
- **수동 테스트:** 실제 Claude Code 작업 중 모니터링 동작 확인
