# 2026-07-22 — WSL `/init` OOM 자살 방지 + 폭주 조기 감지

## 배경 — 진단으로 확정된 사실

2026-07-22 하루에 동일 사고가 2회 발생했다.

| | 1차 | 2차 |
|---|---|---|
| 폭증 시작 | 07:39:16 · vmmemWSL 3.3GB | 11:39:35 · 3.5GB |
| `[EXTERNAL]` 동반 | 07:40:20 (+1.2GB) | 11:40:22 (+0.9GB) |
| 정점 | 07:40:36 · **7.0GB** | 11:40:58 · **7.3GB** |
| 소요 | **80초** | **83초** |
| OOM 희생자 | PID 220 `init` anon-rss **4.9GB** | PID 219 `init` anon-rss **5.6GB** |
| `/init` total-vm | 12,586,212kB | 12,586,212kB (완전 동일) |

### 인과 사슬

1. 호스트 디스크가 WSL 외부 프로세스에 포화 (`[EXTERNAL]`: PhysicalDisk 85~150% / VHD I/O 0MB/s)
2. → WSL의 9p·VHD I/O 요청이 호스트에서 블록
3. → `/init`(9p 서버 + interop 중개)의 미완료 요청 버퍼가 힙에 무제한 축적 — 80초에 +3.8GB (초당 47MB)
4. → 게스트 global OOM → killer가 시스템 최대 프로세스인 `/init`을 선택해 킬
5. → **소켓 계층 전면 붕괴**: `bind()`가 AF_UNIX / AF_VSOCK / AF_NETLINK 모두 `ENOSYS(38)` 반환
6. → `Wsl/Service/E_UNEXPECTED`(세션 리더 생성 불가), containerd shim 생성 불가(mssql_suho001 재시작 실패), D-Bus 불가, udev 불가

### 배제된 원인

- **Claude Code 메모리 누수** (github.com/anthropics/claude-code/issues/41765): OOM 당시 claude 계열 6개 프로세스 RSS 합계 **425MB**. 무관. 설치 버전 2.1.217(이슈는 2.1.87).
- **`.wslconfig` 메모리 부족**: 폭주가 80초에 3.8GB이므로 8GB든 12GB든 결과 동일. 현행 유지(사용자 결정 2026-07-22).

### 구조적 결함

커널은 PID 1만 OOM에서 보호한다. WSL2에서 소켓·interop을 담당하는 `/init`은 **별도 PID(219/220)라 보호받지 못한다.** 그래서 자기가 시스템 최대 프로세스가 되는 순간 자기가 죽고 시스템 전체를 무너뜨린다. 버퍼 상한 부재(3번)는 Microsoft 측 결함이나, **OOM 면제 부재(4번)는 우리가 막을 수 있다.**

## Goal

`/init` 자살로 인한 소켓 계층 붕괴를 차단하고, 폭주를 사후 부검이 아닌 상시 관측으로 포착한다.

성공의 정의: 다음 폭주 때 OOM이 발생하더라도 **`/init`이 생존**하여 WSL이 계속 동작하고, Docker가 죽은 컨테이너를 자동 복구한다. 사고 등급이 "WSL 전체 수동 재시작"에서 "컨테이너 자동 복구"로 격하된다.

## Steps

1. `lib/monitor/init-guard.sh` 신규 — `/init` 탐색 · OOM 면제 · RSS 조회 함수
2. `systemd/diskusage-init-guard.service` 신규 — 부팅 시 OOM 면제 자동 적용
3. `monitor.sh` 수정 — 루프에 `/init` RSS 로깅 추가, 임계치 초과 시 텔레그램 경고
4. `lib/monitor/telegram.sh` 수정 — `/init` 폭주 경고 함수 추가
5. `lib/monitor/config.sh` 수정 — 경고 임계치 설정 추가
6. 사용자가 설치 명령 실행(sudo 필요) → Windows에서 `wsl --shutdown` → 재시작
7. 재시작 후 검증

## Files-to-Touch

| 파일 | 종류 | 내용 |
|---|---|---|
| `lib/monitor/init-guard.sh` | 신규 | `find_wsl_init_pids` / `protect_wsl_init` / `get_wsl_init_rss_mb` |
| `systemd/diskusage-init-guard.service` | 신규 | `Type=oneshot`, `RemainAfterExit=yes`, root 실행 |
| `monitor.sh` | 수정 | 루프에 `INIT:` 필드 로깅 + 임계치 경고 (재무장 로직 포함) |
| `lib/monitor/telegram.sh` | 수정 | `notify_init_bloat` 추가 |
| `lib/monitor/config.sh` | 수정 | `INIT_RSS_WARN_MB` (기본 2500) 추가 |

## Assumptions

- 재시작 후 `/init` 최상위 프로세스가 동일 구조(`comm=init`, `uid=0`, total-vm 12GB)로 재생성된다.
- systemd가 부팅 시 유닛을 실행할 수 있다 (현재 systemd 구동 중 확인됨 — PID 1 = `/sbin/init`).
- `oom_score_adj`를 음수로 낮추려면 `CAP_SYS_RESOURCE`가 필요하므로 root 실행이 필수다.
- 최상위 `/init`은 부팅 시 1회 생성되고 이후 재생성되지 않는다 (재생성 = 이미 WSL 붕괴). 따라서 부팅 시 1회 적용으로 충분하다.

## Verification Criteria

| # | 항목 | 판정 |
|---|---|---|
| V1 | 재시작 후 `/init`(comm=init, uid=0)의 `oom_score_adj` | `== -1000` |
| V2 | monitor 로그에 `INIT:<N>MB` 필드가 매 주기 기록 | 5초 주기로 연속 적재 |
| V3 | `bind()` 정상 복구 | AF_UNIX / AF_VSOCK bind 성공 |
| V4 | mssql_suho001 | `healthy` 상태로 자동 기동 |
| V5 | (장기) 다음 `[EXTERNAL]` 폭주 시 | `/init` 생존 + WSL 계속 동작 |

## Known Risks

- **커널 패닉 가능성**: `/init` 완전 면제 시 OOM killer가 다른 프로세스를 순차 kill하다 죽일 대상이 없으면 패닉. 다만 OOM 당시 `/init` 외 프로세스 RSS 합계가 약 2.9GB(sqlservr 731MB, next-server 891MB, streamlit 458MB 등)로 kill 후보가 충분하다. 현재는 100% WSL 붕괴이므로 순개선.
- **임계치 2500MB는 추정값**: `/init`의 평시 RSS 관측 데이터가 없다(사고 시 프로세스가 소멸해 부검 불가). 실측 축적 후 조정한다.
- **방아쇠 미제거**: 호스트 디스크를 점유한 Windows 측 프로세스는 미식별. interop 복구 후 별도 조사 필요.

## Execution Outcome

### 실제로 한 일

계획한 5개 파일을 모두 작성·수정했다. 그 외에 **계획에 없던 monitor 버그 2건을 발견해 함께 고쳤다** — 둘 다 이번 변경의 검증을 직접 방해했기 때문이다.

| 파일 | 변경 |
|---|---|
| `lib/monitor/init-guard.sh` | 신규. `find_wsl_init_pids`(comm=init && uid=0) / `protect_wsl_init`(재시도 지원) / `get_wsl_init_rss_mb` / `get_wsl_init_oom_adj` |
| `install-init-guard.sh` | 신규. 유닛 생성 + `multi-user.target.wants` 심볼릭 링크 직접 생성(D-Bus 사망 상태에서도 동작) |
| `monitor.sh` | 루프에 `INIT:<N>MB` 로깅 + 임계치 경고(80% 히스테리시스). **추가로 stop 버그 2건 수정** |
| `lib/monitor/telegram.sh` | `notify_init_bloat` 추가 |
| `lib/monitor/config.sh` | `INIT_RSS_WARN_MB=2500` + allowlist 등록 |

계획에서는 `systemd/diskusage-init-guard.service`를 별도 파일로 두려 했으나, 유닛에 repo 절대경로가 필요해 **설치 스크립트가 heredoc으로 생성**하도록 바꿨다. 파일이 하나 줄고 경로 치환 로직도 불필요해졌다.

### 계획에 없던 수정 — monitor stop 버그 2건

1. **`trap '_on_exit' EXIT TERM INT`에 `exit`가 없었다.** bash는 trap을 걸면 시그널의 기본 동작(종료)을 없앤다. 따라서 SIGTERM을 받으면 `_on_exit`로 정리만 하고 **루프가 계속 돌았다.** `do_stop`이 "monitor stopped"를 출력해도 프로세스는 살아남았다.
   - → `trap '_on_exit; exit'`로 수정 + `_on_exit`에 재진입 가드(`_MONITOR_EXITING`) 추가. TERM 핸들러의 exit가 EXIT trap을 다시 부르면 Stopped 알림이 두 번 발송되기 때문.
2. **`kill -- "-$pid" || kill "$pid"`의 단축평가.** 그룹 kill이 성공하면 개별 kill을 건너뛴다. 대상 PID가 다른 그룹(PGID 854)에 있어 살아남았다.
   - → 두 kill을 각각 `|| true`로 분리.

이 두 버그로 **PID 1420이 4.4시간(15,967초)째 고아(PPID=1)로 중복 실행 중**이었다. 로그에 서로 다른 두 프로세스의 출력이 번갈아 기록되고 있었다.

### 진단 중 추가로 밝혀진 사실

- **PID 7의 정체는 `/init plan9 --control-socket 7 --server-fd 8 --pipe-fd 10`** — 9p 파일서버. 백업 스크립트가 `\\wsl.localhost\Ubuntu\tmp\*.bak`를 PowerShell로 읽을 때 통과하는 그 서버다. 현재 VmSize 3,160kB로 작다.
- **죽은 PID 219/220은 PID 7과 다른 프로세스다.** VmSize 12,586,212kB(12,291MB)로 두 부팅 모두 동일한 고정 예약. 게스트 RAM 9,947MB + swap 4,096MB = 14,043MB와도 불일치해 정체 미확정. 재시작 후 `comm=init` 프로세스 목록으로 특정 가능.
- **커널이 OOM 전에 사전 경고를 남긴다** — `__vm_enough_memory: pid: N, comm: init, not enough memory for the allocation`
  - 1차 사고: 이전 부팅에서 총 9회. 마지막 07:38:05 → **07:40:36 OOM (2분 31초 전)**
  - 2차 사고: 현재 부팅에서 2회. 08:00:13, 10:57:49 → **11:40:47 OOM (43분 전)**
  - RSS 임계치보다 정확한 신호다. 감시 대상으로 추가할 가치가 있으나 **계획 범위 밖이라 미구현.**

### Verification

| # | 항목 | 결과 |
|---|---|---|
| — | 문법 검사 `bash -n` | **5/5 PASS** (monitor.sh, install-init-guard.sh, init-guard.sh, telegram.sh, config.sh) |
| — | `init-guard.sh pids/rss/check` | PASS — PID 7 탐지, RSS 1MB, oom_score_adj 0 정상 조회 |
| — | 비root `protect` 거부 메시지 | PASS — `found 1 /init process(es) but cannot write oom_score_adj — must run as root` |
| — | `load_config` | PASS — `INIT_RSS_WARN_MB=2500` |
| V2 | monitor 로그 `INIT:<N>MB` 적재 | **PASS** — 재기동 후 최근 4줄 100% 포함 |
| — | stop 버그 수정 | **PASS** — 수정 전 SIGTERM 후에도 생존, 수정 후 루프 정상 종료 |
| — | 고아 프로세스 정리 | PASS — 1420 제거, 단일 인스턴스(458492) |
| V1 | `/init` oom_score_adj == -1000 | **미검증** — 재시작 후 |
| V3 | `bind()` 복구 | **미검증** — 재시작 후 |
| V4 | mssql_suho001 healthy | **미검증** — 재시작 후 |
| V5 | 다음 폭주 시 `/init` 생존 | **미검증** — 장기 관측 |

### Known Limitations

- **V1·V3·V4는 WSL 재시작 전까지 검증 불가.** 현재 `/init`(219 역할)이 죽어 있어 보호 대상 자체가 없다.
- **`install-init-guard.sh`는 아직 실행되지 않았다.** sudo 비밀번호가 필요하고(NOPASSWD 목록은 fstrim/sysctl/iotop/journalctl뿐) 사용자가 직접 실행해야 한다.
- **임계치 2500MB는 여전히 추정값.** 재시작 후 평시 `/init` RSS가 로그에 쌓이면 실측 기반으로 조정할 것.
- **`__vm_enough_memory` 감시 미구현.** OOM 2분~43분 전 선행하는 커널 신호로, 다음 작업 단위 후보.
- **방아쇠(호스트 디스크 점유자) 미식별.** interop 복구 후 조사 필요.
