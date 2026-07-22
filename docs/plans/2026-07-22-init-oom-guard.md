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

---

## 2차 재설계 (2026-07-22 재시작 후) — 핵심 가정 붕괴와 수정

### 무엇이 틀렸나

재시작 후 검증에서 **계획의 핵심 가정("재시작 후 /init이 동일 구조로 재생성")이 거짓**으로 판명됐다.

이전 부팅의 OOM 태스크 덤프(144개)를 전수 분석한 결과:

- 덤프의 pid 176 = `DebugShell`인데, 같은 시각 Ubuntu의 pid 176 = `tailscaled` → **덤프는 커널 전역 PID, Ubuntu는 별도 PID 네임스페이스.**
- 덤프에는 Ubuntu에서 안 보이는 `weston`, `WSLGd`, `pulseaudio`, `Xwayland`, `chronyd`, `GnsEngine`이 있다.
- **희생자 init(전역 pid 219, VmSize 12,291MB)은 루트 네임스페이스의 WSL 배관 프로세스** — Ubuntu 안에서는 보이지도, `oom_score_adj`를 쓸 수도 없다.
- 따라서 1차 구현(Ubuntu /proc 스캔)이 보호한 것은 plan9(9p 서버, Ubuntu pid 7)뿐이며, **진짜 희생자에게는 닿지 않았다.**

### 돌파구 — `wsl.exe --system`

시스템 배포판(WSLg CBL-Mariner)은 **루트 PID 네임스페이스를 공유**한다. `wsl.exe --system -u root ls /proc`에서 커널 스레드(pid 2,3,13,…)가 보이는 것으로 확인. 매핑 검증: Ubuntu pid 7(plan9, adj=-1000) = 전역 pid 27(adj=-1000 동일 확인).

→ **`wsl.exe --system -u root sh -s protect < rootns-scan.sh`** 로 전역 /proc에 직접 쓸 수 있다. 인증 불필요(WSL 권한 모델상 로컬 사용자는 VM 전권).

### 수정된 구현

| 구성 요소 | 내용 |
|---|---|
| `lib/monitor/rootns-scan.sh` (신규) | 루트 ns에서 stdin 주입으로 실행. comm=init 나열, `protect` 모드면 **VmSize ≥ 4GB인 init에만** -1000 기록(배관 init은 12GB 예약, SessionLeader/plan9는 수 MB라 오인 불가). |
| `init-guard.sh` | `rootns_init_guard(mode)` — wsl.exe --system 호출 래퍼(timeout 20s). `get_hidden_anon_mb` — **전역 AnonPages − Ubuntu 가시 RssAnon 합 = 루트 ns 익명 메모리 추정치.** wsl.exe 없이 /proc만 읽어 매 주기 실행 가능. CLI에 `hidden`/`rootns` 추가. |
| `monitor.sh` | ① 매 주기 `HID:<N>MB` 로깅(INIT: 필드 대체 — 가시 init 합은 희생자를 못 보므로 무의미) + 1500MB 임계 경고. ② 매 주기 dmesg `__vm_enough_memory` 카운트 증가 감지 → 로그 + 텔레그램(10분 쿨다운). ③ **60초마다 루트 ns protect 재적용** — 배관 init은 세션 형태에 따라 늦게 생길 수 있어(이번 부팅엔 부재) 1회성 보호로는 놓친다. 호스트 정체 중엔 wsl.exe가 안 돌아오므로 평시 선제 적용이 요점. |
| `config.sh` | `INIT_RSS_WARN_MB` 삭제 → `HIDDEN_ANON_WARN_MB=1500`(실측 평시 26MB, 사고 시 5,600MB), `ROOTNS_GUARD_INTERVAL=60` |
| `telegram.sh` | `notify_init_bloat` 재작성(숨은 메모리 기준), `notify_init_vm_pressure` 신규 |

systemd 유닛(`diskusage-init-guard.service`)은 가시 init(plan9) 보호용으로 존치 — 무해하며 9p 서버 보호는 그 자체로 유효.

### 방아쇠 규명 (호스트 디스크 점유자)

- **호스트 RAM 96% 사용(여유 0.6GB)** — 페이징 폭풍 직전 상태 상시.
- Cowork VM은 소멸(회수 완료). 호스트 상위: vmmemWSL 7.3GB, 이하 브라우저류 수백 MB.
- **OneDrive: 누적 CPU 23분** — `광장주류\백업`에 **매일 04:00 suho001 7.1GB** + **매주 일 05:00 ubuntu VHDX 68GB**가 들어가고 OneDrive가 이를 업로드. 68GB 업로드는 통상 회선에서 수십 시간 → **주중 내내 디스크 연마**. 무작위 시각 `[EXTERNAL]` 폭풍·사고 시각(07:39/11:39)과 정합.
- 예약 작업 스윕(07:25~07:50, 11:25~11:50): 유의미한 항목 없음 → 스케줄 작업설 기각.
- Defender: 7/15 퀵스캔 2분이 전부 → 기각.
- 주간 패턴 재해석: 7/5·7/12·7/19의 05:0x FROZEN/VM_DOWN은 **일요일 VHDX 백업**(문서상 "월 05:00"은 오기 — 실제 트리거는 일요일) 유발로 별건.

### 검증 (2차)

| # | 항목 | 결과 |
|---|---|---|
| V1′ | 루트 ns 접근 + 매핑 검증 | **PASS** — 전역 27 = Ubuntu 7, adj=-1000 일치 |
| V1′ | 배관 init 보호 | **대기** — 이번 부팅엔 배관 init 미생성(숨은 anon 26MB로 방증). 생성 즉시 60초 내 protect가 적용되는 구조 가동 중 |
| V2′ | `HID:` 필드 적재 | **PASS** — 12:49:16부터 연속 기록 (29MB, 21MB…) |
| V3 | bind() 복구 | **PASS** — AF_UNIX·AF_VSOCK 모두 OK |
| V4 | mssql_suho001 | **PASS** — Up (healthy), 12:31 자동 기동 |
| — | 문법 `bash -n` | 4/4 PASS |
| — | `rootns scan` CLI | PASS — 2개 init 반환(18:adj=0, 27:adj=-1000) |
| — | stop 버그 수정 실증 | PASS — serveronoff가 띄운 구코드 monitor(1341)가 새 stop으로 정상 종료 |
| — | dmesg 사전 경고 | 새 부팅 0건(정상 기준선) |

### 남은 한계 (2차 갱신)

- **배관 init의 생성 조건 미규명.** 이전 두 부팅(wsl -e로 기동)엔 부팅 직후 존재, 이번(터미널 로그인 기동)엔 부재. 60초 주기 protect가 생성 시점을 커버하지만, 어떤 트래픽이 만들고 키우는지는 HID 로그 축적으로 확인할 것.
- **wsl.exe 호출이 루프를 최대 20초 지연 가능**(분당 1회, timeout 봉인). 위기 중엔 rootns 재적용이 실패할 수 있으나 그 시점엔 이미 평시 적용분이 유효.
- **serveronoff.service가 띄우는 monitor에서 interop 동작 여부는 다음 부팅에서 확정.** (같은 데몬 문맥인 cron에서 powershell.exe 백업이 매일 성공 중이므로 성립 개연성 높음.)
- **OneDrive 부하는 권고만 하고 미조치** — 백업 파이프라인 변경은 사용자 결정 사안.

---

## 3차 수정 (2026-07-22 13:0x) — HID 측정 경합 가짜 경보

### 증상

가동 40분 만에 13:00:59~13:08:18 사이 `HIDDEN_BLOAT` 텔레그램 경보 4건(3136~3167MB). 그러나 같은 시간대 5초 주기 `HID:` 시계열은 내내 25~29MB, 루트 ns 실측 상위 프로세스도 sqlservr 897MB가 최대 — **전부 가짜 경보.**

### 원인 (재현 입증)

`get_hidden_anon_mb`의 두 가지 경합:

1. **mawk 즉사**: `awk '...' /proc/[0-9]*/status`는 glob 확장 후 스윕 도중 프로세스가 죽어 파일이 사라지면 mawk(Ubuntu 기본 awk)가 그 지점에서 치명 종료 → 합계가 조기 중단 → `전역 − 부분합` 차액 수 GB가 "숨은 메모리"로 둔갑.
2. **읽기 순서**: meminfo(전역)를 먼저 읽고 스윕을 나중에 하면, 그 사이 종료된 프로세스가 전역엔 있고 합산엔 빠져 과대평가.

트리거는 2분 주기 `run_review.sh`, 5분 주기 `watchdog_mssql.sh` 등 단명 프로세스의 상시 생멸.

### 수정

- 합산을 `cat /proc/[0-9]*/status | awk`로 변경 — cat은 사라진 파일을 건너뛰고 계속 진행.
- 스윕 먼저 → meminfo 나중: 경합의 방향이 과대평가(가짜 경보)에서 과소평가(음수→0 클램프)로 뒤집힘.
- monitor 판정에 **3주기 연속 확인**(실제 폭주는 수십 초 지속, 1주기 스파이크는 경합 잔재) + **30분 알림 쿨다운** 추가. 기존 80% 히스테리시스 유지.

### 검증

프로세스 생멸 폭풍(sleep 0.01 × 2000개) 아래 300회 측정 대조:

| 구현 | 1GB 초과 스파이크 | 최대치 |
|---|---|---|
| 옛 구현 | **32/300회** | **3178MB** (실제 경보 3149MB와 동일 규모 — 버그 재현 확정) |
| 새 구현 | **0/300회** | 32MB |

수정판 가동(13:08:36~) 후 HID 29MB 안정, 추가 경보 0건.
