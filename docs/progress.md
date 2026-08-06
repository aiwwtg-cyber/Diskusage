# Project Progress

## Current Status

**Phase:** 알림 정밀도 확보 (스팸 제거 + 압박 기반 판정) → 다음은 루트 ns 접근 재조사
**Last completed:** 커널경고 알림의 정밀도가 **0%**(8일 121건 감지 / 실사건 0건)임을 규명하고 압박 기반 판정으로 재설계 (2026-08-06)
**Next up:** ① **`wsl --system`이 루트 ns가 아님이 확증됨 → `ROOTNS_GUARD`가 헛돌고 있다. 진짜 루트 ns 접근 가능성 재조사** ② HID 이중계상 해소 방안(현재 상시 `n/a`) ③ 다음 압박 사건에서 `notify_memory_pressure` 실수신 확인
**Latest commit:** `6bc2a92 fix: reach root-namespace plumbing init via wsl --system, harden HID detection`

> ⚠️ **2026-08-06 정정:** 아래 2026-07-22 2차 기록의 핵심 전제 — "`wsl.exe --system`이 루트 PID ns를 공유한다" — 는 **틀렸다.** ns inode 실측으로 확인: Ubuntu `pid:[4026532223]` vs system `pid:[4026532211]` — 서로 다르고 둘 다 루트가 아니다(루트라면 `pid2=kthreadd`여야 하나 실제로는 `systemd`). `dmesg`가 지목하는 배관 init(전역 pid 222)은 **양쪽 ns 어디에서도 보이지 않는다.** 따라서 `ROOTNS_GUARD`의 OOM 면제는 엉뚱한 프로세스(pid 22, rss 1.8MB)에 적용되고 있으며 **실효가 없다.**

---

## 코드 인벤토리

### 위치 1 — WSL git repo `/home/aiwwt/project/Diskusage/`

**루트 PowerShell 스크립트**

| 파일 | 역할 |
|---|---|
| `watchdog.ps1` | Windows 측 메인 워치독. Hyper-V VHD I/O와 vmmemWSL 메모리 폴링. `MEM < 50MB`가 30초 지속되면 `Send-WslVmDownAlert` + `Start-TelegramCallbackListener`. WSL 응답성 테스트 2회 연속 실패 → frozen 진입, 30초 지속 시 `Send-WslFrozenAlert`. **에스컬레이션 액션:** `cleanup`(warn)/`cleanup_and_notify`(alert) 시 `wsl -e ~/.diskusage/cleanup_trigger.sh <level>` 호출(WSL monitor가 이미 cleaning이면 스킵). 타임아웃 시 frozen 단계 진입. |
| `command-listener.ps1` | 텔레그램 봇 getUpdates 롱폴링. `/start_watchdog`, `/watchdog_status` 명령 + `listener_start_watchdog` 콜백 처리. 워치독 프로세스 부재를 60초 안에 감지하면 별도 알림. |
| `register-task.ps1` | `DiskusageWatchdog` Task Scheduler 작업 등록. LogonTrigger + TimeTrigger(PT1M Repetition) + `MultipleInstancesPolicy=IgnoreNew`. wscript.exe로 `watchdog-hidden.vbs` 실행. |
| `register-listener-task.ps1` | `DiskusageListener` 작업 등록. 동일 트리거 패턴으로 `listener-hidden.vbs` 실행. |
| `watchdog-hidden.vbs` | `shell.Run cmd, 0, True` 패턴으로 `watchdog.ps1`을 창 표시 0(완전 숨김)으로 실행. 내부 keepalive 루프 없음. |
| `listener-hidden.vbs` | 동일 패턴으로 `command-listener.ps1` 실행. |
| `test-buttons.ps1` | 텔레그램 봇 토큰 → 메시지 전송 → 콜백 수신까지 6단계 검증 스크립트. |
| `setup.ps1`, `config.conf.default` | (최근 미수정) |

**`lib/watchdog/`**

| 파일 | 역할 |
|---|---|
| `telegram.ps1` | `Initialize-Telegram`, `Send-TelegramMessage`(UTF-8 JSON 본문, 3회 재시도), `Send-WslFrozenAlert`(3개 버튼: wsl_restart/wsl_shutdown/ignore), `Send-WslVmDownAlert`(동일 3개 버튼), `Start-TelegramCallbackListener`(Job, 5분 폴링, 버튼 클릭 시 wsl --shutdown 또는 wsl 재시작), `Send-WslRecoveredAlert`, `Send-WatchdogStarted`, `Send-WatchdogStopped`, `Send-WatchdogHeartbeat`(정의는 남아있으나 호출 없음), `_TelegramLog`(첫 시도 성공만 silent. 스킵·재시도 성공·에러·최종실패는 모두 기록). |
| `counters.ps1`, `escalation.ps1`, `notification.ps1` | (최근 미수정) |

**`lib/monitor/`** — WSL bash 측 (이번 세션 미수정, 단 **실행 중인 핵심 컴포넌트**)

| 파일 | 역할 |
|---|---|
| `monitor.sh` | WSL 데몬. 5초 주기 `/proc/diskstats` 폴링 → `get_io_level` → normal 아니면 `set_status cleaning` + `run_cleanup` 호출 + `set_status monitoring`. warn 이상 또는 mem ≥ 85% 시 메모리 Top 5 프로세스도 로그에 기록. **2026-08-06:** 커널경고(`__vm_enough_memory`)는 `log_entry` + 60초 창 밀도 집계 **전용으로 강등**(알림 없음). 알림은 통합 `MEM_PRESSURE` 판정 하나 — `mem ≥ 90% AND (io ≥ 100MB/s OR HID ≥ 1500MB)`, 2주기 연속, 급등(`mem ≥ 95%` 또는 `HID ≥ 3000MB`)이면 1주기 즉시, 30분 쿨다운. |
| `lib/monitor/cleanup.sh` | `run_cleanup <level>` 함수. journalctl/tmp/fstrim 단계적 실행. |
| `lib/monitor/config.sh` | `load_config` — 기본값 + `~/.diskusage/config/config.conf` 병합. |
| `lib/monitor/diskstats.sh`, `logger.sh` | I/O 계산 / 일별 로그 + 7일 로테이션. |
| `lib/monitor/telegram.sh` | curl 송신. `notify_monitor_started/stopped`, **`notify_memory_pressure`**(2026-08-06 신설 — 메모리%·I/O·HID·커널경고 burst를 한 화면에). 폐기: `notify_init_bloat`, `notify_init_vm_pressure`. |
| `lib/monitor/init-guard.sh` | **WSL init OOM 면제 + 메모리 관측** (2026-07-22). Ubuntu ns: `find_wsl_init_pids` / `protect_wsl_init`(root 전용). `rootns_init_guard(mode)` — `wsl.exe --system -u root sh -s < rootns-scan.sh`. ⚠️ **이 경로는 루트 ns가 아니다**(2026-08-06 확증) — 배관 init에 도달 못 함. `get_hidden_anon_mb` — 전역 AnonPages − Ubuntu RssAnon 합. **2026-08-06:** 음수(= RssAnon 이중계상으로 측정 불가)를 0이 아닌 `-1`로 반환해 "숨은 메모리 없음"과 구분. CLI: `protect\|rss\|pids\|check\|hidden\|rootns`. |
| `lib/monitor/rootns-scan.sh` | stdin 주입 실행되는 POSIX sh 스크립트. comm=init 나열, protect 모드 시 **VmSize ≥ 4GB init에만** adj=-1000. ⚠️ 실행되는 ns가 루트가 아니라 현재 pid 22(rss 1.8MB)만 잡힌다 — 의도한 12GB 배관 init이 아니다. |
| `install-init-guard.sh` (루트) | systemd 유닛 생성 + wants 심볼릭 링크 직접 생성(D-Bus 사망 시에도 동작). 가시 init(plan9) 보호용. sudo 필요, 2026-07-22 설치 완료. |
| `~/.diskusage/cleanup_trigger.sh` (setup.sh가 생성) | **Windows 워치독 ↔ WSL 정리 브리지.** `watchdog.ps1`이 `cleanup` (warn) 또는 `cleanup_and_notify` (alert) 액션 시 `Invoke-WslCommand`로 호출. config + cleanup.sh를 source 후 `run_cleanup $LEVEL` 실행. 단, `Get-WslMonitorStatus`가 `cleaning`이면 중복 방지로 스킵. |

### 위치 2 — Windows 실행 사본 `C:\Users\aiwwt\Diskusage\`

WSL repo와 **별개 사본**. 실제 워치독·리스너가 이 경로에서 실행됨. **자동 동기화 없음.**

| 파일 | 시점 | 비고 |
|---|---|---|
| `watchdog.ps1` | May 2 07:53 | repo 최신본과 동기화됨 |
| `lib/watchdog/telegram.ps1` | May 2 07:53 | repo 최신본과 동기화됨 |
| 나머지 (`command-listener.ps1`, `register-*.ps1`, VBS, `setup.ps1` 등) | Apr 26~27 | 코드 변경 없어 미동기화 |

### 위치 3 — Windows 시스템 설정

| 경로 | 내용 |
|---|---|
| `C:\Users\aiwwt\.wslconfig` | `[wsl2] memory=10GB swap=4GB processors=4 networkingMode=mirrored` / `[experimental] autoMemoryReclaim=gradual sparseVhd=true` |
| `C:\Users\aiwwt\.diskusage\config\telegram.conf` | `BOT_TOKEN`, `CHAT_ID=7437534009` |
| `C:\Users\aiwwt\.diskusage\logs\` | `watchdog-YYYY-MM-DD.log`, `listener-YYYY-MM-DD.log`, `telegram-YYYY-MM-DD.log`(에러 시에만 작성) |

### Task Scheduler 등록

| 작업명 | 상태 | 비고 |
|---|---|---|
| `DiskusageWatchdog` | Running | 1분마다 살아있는지 체크, 죽었으면 부활 |
| `DiskusageListener` | Running | 동일 패턴 |

### 외부 작업 (이 프로젝트 외부, 본 프로젝트와 상호작용)

| 작업명 | 트리거 | 동작 |
|---|---|---|
| `WSL Weekly VHDX Backup` | 매주 **일** 05:00 (구기록 "월"은 오기 — VHDX 생성일 06-28·07-12·07-19 모두 일요일, 매주 일 05:0x FROZEN/VM_DOWN과 정합) | `wsl --shutdown` → `wsl --export Ubuntu <OneDrive>\광장주류\백업\ubuntu_*.vhdx --vhd` (68GB) → 최신 3개 보존 → `wsl -d Ubuntu -e true` |
| `Scripts Weekly Backup` | 매주 월 05:30 | `C:\Users\aiwwt\Scripts\Scripts-Backup\scripts-backup.ps1` 실행 |

---

## Work Log

### 2026-08-06 — 알림 정밀도 0% 규명 + 압박 기반 재설계

- **What was done:** 사용자의 "알림이 스팸 같다"는 보고를 검증해 `KERNEL_VM_PRESSURE` 알림의 정밀도가 **0%**임을 규명하고, 판정을 실제 압박 지표로 재설계했다. 조사 중 `__vm_enough_memory`를 "OOM 선행 신호"로 본 원래 가설과 "`wsl --system`이 루트 ns"라는 전제가 **둘 다 데이터로 부정**됐다. 커널경고는 로그 전용으로 강등하고, `HIDDEN_BLOAT`와 통합해 `MEM_PRESSURE` 알림 하나로 정리했다. HID 음수(측정 불가)를 0이 아닌 `n/a`로 구분해 게이지가 눈이 먼 구간이 드러나게 했다.
- **Artifacts:** `monitor.sh`(판정부 교체 + `pressure_*` 리네임), `lib/monitor/telegram.sh`(`notify_memory_pressure` 신설, `notify_init_bloat`·`notify_init_vm_pressure` 폐기), `lib/monitor/config.sh`(임계 5종 + allowlist), `lib/monitor/init-guard.sh`(`HIDDEN_ANON_INVALID=-1`), `docs/plans/2026-08-06-alert-precision-fix.md`
- **Verification:** 문법 **4/4 PASS** · 6일치 **91,069 샘플** 리플레이(실제 `config.sh` 임계값 + `monitor.sh` 판정식 재현)에서 **오탐 0건**, 진짜 사건 **1건 포착**(`08-06 15:22:56` mem 98% / io 21731KB/s / hid 2074MB — 급등 예외로 목표보다 9초 조기) · 커널경고 알림 **121건 → 0건(−100%)** · 실기동 32분21초/**356 사이클** 관측에서 알림 **0건**, `HID:0MB` **0건**(전부 `n/a`) · 기존 bats **22/24**(실패 2건은 `HEAD`에서도 동일한 기존 결함)
- **Known limitations:** 관측 구간에 커널 경고가 0건이라 **억제 검증은 리플레이에만 의존**한다 · 텔레그램 실수신은 다음 압박 사건에서 확인 필요 · HID 이중계상 자체는 미해결(상시 `n/a`이므로 판정이 실질적으로 `MEM ≥ 90% AND IO ≥ 100MB/s`로 동작) · 임계 90%의 근거는 6일 표본(평시 최대 83.1%, 사건 98.8%) · **`ROOTNS_GUARD`는 헛돌고 있으나 이번엔 문서 정정만 했다**

### 2026-07-22 (3차) — HID 측정 경합으로 인한 가짜 경보 수정

- **What was done:** 가동 40분 만에 발생한 HIDDEN_BLOAT 가짜 경보 4건(3.1GB대)의 원인을 규명·수정. `awk`에 /proc 파일 목록을 직접 주면 스윕 도중 프로세스가 죽는 순간 mawk가 즉사해 합계가 조기 중단되는 경합이었다(HID 시계열은 내내 25~29MB로 정상). cat 경유 합산 + 스윕→meminfo 순서 반전(과대평가→과소평가로 방향 전환) + 3주기 연속 확인 + 30분 알림 쿨다운.
- **Artifacts:** `lib/monitor/init-guard.sh`(`get_hidden_anon_mb`), `monitor.sh`(HIDDEN_BLOAT 판정부), `docs/plans/2026-07-22-init-oom-guard.md`(3차 수정 절)
- **Verification:** 생멸 폭풍(sleep 0.01×2000) 아래 300회 대조 — 옛 구현 스파이크 **32/300회, 최대 3178MB**(실경보 3149MB와 동일 규모, 버그 재현 확정) vs 새 구현 **0/300회, 최대 32MB**. 수정판 가동 후 HID 29MB 안정, 추가 경보 0건.
- **Known limitations:** 신규 프로세스가 스윕 후 meminfo 전에 대량 할당하면 잔여 과대평가 가능(수 MB 수준, 3주기 확인이 흡수). 30분 쿨다운은 지속 폭주 시 재알림 간격의 하한.

### 2026-07-22 (2차) — 진범은 루트 네임스페이스: `wsl --system` 경유 보호 + 이중 감지망 가동

- **What was done:** 재시작 후 검증에서 1차 가정이 붕괴 — OOM 희생자(12GB init)는 **Ubuntu ns 밖, 루트 네임스페이스의 WSL 배관 프로세스**였다(OOM 덤프의 pid 176=DebugShell vs Ubuntu의 pid 176=tailscaled로 입증). `wsl.exe --system`이 루트 ns를 공유함을 확인(커널 스레드 가시)하고, ① 60초 주기 루트 ns 보호 재적용, ② 숨은 익명 메모리(HID) 상시 관측+1500MB 경고, ③ 커널 `__vm_enough_memory` 선행 신호 감시를 monitor에 탑재. 방아쇠는 **OneDrive 백업 업로드(매일 7.1GB + 매주 68GB VHDX) + 호스트 RAM 96%**로 압축.
- **Artifacts:** `lib/monitor/rootns-scan.sh`(신규), `lib/monitor/init-guard.sh`(`rootns_init_guard`/`get_hidden_anon_mb`), `monitor.sh`(HID·KERNEL_VM_PRESSURE·ROOTNS_GUARD), `lib/monitor/config.sh`(`HIDDEN_ANON_WARN_MB=1500`/`ROOTNS_GUARD_INTERVAL=60`), `lib/monitor/telegram.sh`(`notify_init_vm_pressure`), `docs/plans/2026-07-22-init-oom-guard.md`(2차 재설계 절)
- **Verification:** bind() AF_UNIX·AF_VSOCK 복구 PASS · mssql_suho001 healthy 자동 기동 PASS · ns 매핑 검증 PASS(Ubuntu 7 = 전역 27, adj=-1000 일치) · `HID:` 필드 연속 적재 PASS(평시 21~30MB) · 문법 4/4 · rootns scan 2개 init 반환 · 구코드 monitor(serveronoff 기동분) 새 stop으로 정상 종료. **배관 init 보호는 대기 상태** — 이번 부팅엔 미생성(숨은 anon 26MB로 방증), 생성 시 60초 내 자동 적용.
- **Known limitations:** 배관 init 생성 조건 미규명(이전 두 부팅=wsl -e 기동 시 존재, 터미널 기동인 이번엔 부재) · wsl.exe 호출이 분당 1회 루프를 최대 20초 지연 가능 · serveronoff 문맥 interop은 다음 부팅에서 확정(cron의 powershell.exe 백업 성공이 방증) · OneDrive 부하는 권고만(사용자 결정 대기).

### 2026-07-22 (1차) — `/init` OOM 자살로 인한 WSL 소켓 계층 붕괴 규명 + 방어

- **What was done:** 하루 2회(07:40, 11:40) 발생한 `Wsl/Service/E_UNEXPECTED` + mssql 재시작 실패의 근본 원인이 **WSL `/init`의 OOM 자살**임을 규명하고, OOM 면제(`oom_score_adj=-1000`)와 `/init` RSS 상시 관측을 구현. 진단 중 발견한 monitor stop 버그 2건도 수정.
- **Artifacts:** `lib/monitor/init-guard.sh`(신규), `install-init-guard.sh`(신규), `monitor.sh`(INIT 로깅 + stop 버그 2건), `lib/monitor/telegram.sh`(`notify_init_bloat`), `lib/monitor/config.sh`(`INIT_RSS_WARN_MB=2500`), `docs/plans/2026-07-22-init-oom-guard.md`
- **Verification:** `bash -n` 5/5 PASS · init-guard 4개 서브커맨드 정상 · 비root protect 거부 메시지 정상 · monitor 로그 `INIT:<N>MB` 100% 적재 · stop 버그 수정 후 루프 정상 종료(수정 전엔 SIGTERM 무시) · 4.4시간짜리 고아 monitor(PID 1420) 제거 후 단일 인스턴스 확인. **V1(oom_score_adj=-1000) / V3(bind 복구) / V4(mssql healthy)는 WSL 재시작 전이라 미검증.**
- **Known limitations:** `install-init-guard.sh` 미실행(sudo 비밀번호 필요, 사용자 직접 실행) · 임계치 2500MB는 추정값(평시 `/init` RSS 관측 데이터 없음) · `__vm_enough_memory` 커널 사전 경고 감시 미구현 · 방아쇠(호스트 디스크 점유 프로세스) 미식별.

#### 인과 사슬 (두 사고 모두 동일하게 재현)

| | 1차 | 2차 |
|---|---|---|
| 폭증 시작 | 07:39:16 · 3.3GB | 11:39:35 · 3.5GB |
| `[EXTERNAL]` 동반 | 07:40:20 (+1.2GB) | 11:40:22 (+0.9GB) |
| 정점 | 07:40:36 · **7.0GB** | 11:40:58 · **7.3GB** |
| 소요 | **80초** | **83초** |
| OOM 희생자 | PID 220 `init` anon-rss 4.9GB | PID 219 `init` anon-rss 5.6GB |
| `/init` total-vm | 12,586,212kB | 12,586,212kB (완전 동일) |

호스트 디스크 포화(`[EXTERNAL]`) → WSL의 9p·VHD I/O 블록 → `/init` 요청 버퍼가 힙에 무제한 축적(초당 47MB) → global OOM → killer가 시스템 최대 프로세스인 `/init` 선택 → **`bind()`가 AF_UNIX·AF_VSOCK·AF_NETLINK 전 계열에서 `ENOSYS(38)`** → 세션 생성 불가(E_UNEXPECTED) · containerd shim 불가(mssql 재시작 실패) · D-Bus 불가 · udev 불가.

**구조적 결함:** 커널은 PID 1만 OOM에서 보호한다. WSL2에서 소켓·interop을 담당하는 `/init`은 별도 PID(219/220)라 보호받지 못해, 자기가 최대 프로세스가 되는 순간 자기가 죽고 시스템 전체를 무너뜨린다.

### 2026-07-10 — vmmem 와일드카드 오탐 수정 (WSL VM down 플래핑 해소)

- **What was done:** 7/9~7/10 반복된 "WSL VM 종료/재시작" 알림이 오탐임을 규명하고 원인(`Get-VmmemMemoryMB`의 `vmmem*` 와일드카드가 7/9 06:38 생성된 Claude Desktop Cowork 샌드박스 VM `vmmem`을 매칭)을 수정 — `vmmemWSL` 정확 일치로 변경, Windows 사본 동기화, 워치독 재시작.
- **Artifacts:** `lib/watchdog/counters.ps1:56-58` (repo + `C:\Users\aiwwt\Diskusage` 사본), `docs/plans/2026-07-10-fix-vmmem-wildcard-false-down.md`
- **Verification:** 재시작 후 MEM 2.8→4.1GB(실제 vmmemWSL), WSL_VM_DOWN 0건, SELFTEST_OK, 단일 인스턴스(PID 32368). WSL VM은 7/5 05:06부터 무중단이었음을 프로세스 생성 시각으로 입증 — 7/9~7/10 down 알림 6건 전부 오탐.
- **Known limitations:** Cowork VM(커밋 4.1GB)은 그대로 실행 중(사용자 결정 대기). down 판정은 여전히 워킹셋<50MB 프록시(프로세스 부재 기반 아님). 6/19 기동 옛 워치독이 7/10까지 살아있던 중복 인스턴스 문제 재확인.

### 2026-05-02 — WSL VM down 알림 버튼화 + Windows 사본 동기화

- **What was done:**
  - `lib/watchdog/telegram.ps1`에 `Send-WslVmDownAlert` 함수 추가. frozen 알림과 동일한 3-버튼 inline_keyboard(`wsl_restart`/`wsl_shutdown`/`ignore`) 부착.
  - `watchdog.ps1`의 VM down 분기를 단순 텍스트 메시지에서 `Send-WslVmDownAlert` + `Start-TelegramCallbackListener` 시작으로 변경.
  - WSL repo의 두 파일을 Windows 실행 사본(`C:\Users\aiwwt\Diskusage\`)으로 복사.
  - 옛 워치독 프로세스(PID 7120, 04-30 기동분) 종료, 새 프로세스(PID 29712, 05-02 07:53) 가동.
- **Artifacts:**
  - 커밋 `58f26b6 feat: add action buttons to WSL VM down alert`
  - `lib/watchdog/telegram.ps1:213-224` (Send-WslVmDownAlert 정의)
  - `watchdog.ps1:177-185` (호출부)
- **Verification:**
  - Windows 사본 파일 mtime이 May 2 07:53로 갱신됨 확인.
  - 새 워치독 프로세스 CreationDate=2026-05-02 07:53:18 확인 (`Get-CimInstance Win32_Process`).
  - ⚠️ **실제 VM down 트리거로 버튼이 정상 노출되는지는 미검증.** 5/2 07:53 새 워치독 가동 후 본 진단 시점까지 VM down 사례가 없어 end-to-end 검증 미완료. 다음 다운 시 확인 필요.
- **Known limitations:**
  - WSL repo와 Windows 사본은 자동 동기화되지 않음. 향후 파일 변경 시 `cp` + 워치독 프로세스 재시작 필요.
  - `Just Shutdown` 버튼은 VM이 이미 다운된 상태에선 의미 없는 액션이지만 UX 일관성 위해 유지.

### 2026-05-03 — 메모리 누수 점검 + memento MCP 완전 제거

- **What was done:**
  - 새벽 05:00경 시작된 1.5시간 WSL 다운 사태 원인 분석.
  - WSL 측 메모리 누수 점검: 프로세스 RSS 분포, FD 카운트, Threads, OOM 이력, slab, 시간별 평균 메모리 변동.
  - Docker 컨테이너별 메모리 사용량 측정 — `memento-memento-1`이 1.23GB로 단일 최대.
  - 사용자 결정에 따라 memento MCP 서버 흔적 완전 제거 (Docker artifacts + 프로젝트 디렉터리 + MCP 설정 + 캐시).
  - `/mcp` 결과로 사용자 레벨 설정에 별도 잔존 확인되어 추가 정리.
- **Artifacts (제거된 항목):**
  - Docker 컨테이너: `memento-memento-1`, `memento-redis-1`, `memento-postgres-1`
  - Docker 이미지: `memento-memento:latest`(1.83GB), `pgvector/pgvector:pg16`(621MB)
  - Docker 볼륨: `memento_pgdata`, `memento_redisdata`
  - Docker 네트워크: `memento_default`
  - 디렉터리: `/home/aiwwt/project/Memento/`
  - 캐시: `~/.cache/claude-cli-nodejs/*/mcp-logs-memento/` (16개)
  - 설정: `~/.claude/.mcp.json`의 `mcpServers.memento`, `~/.claude.json`의 `mcpServers.memento` + `skillUsage.mcp__memento__onboarding`
  - 백업 보관: `~/.claude/.mcp.json.bak.20260503`, `~/.claude.json.bak.20260503`
- **Verification:**
  - `docker ps -a`, `docker images`, `docker volume ls`, `docker network ls`에서 memento 관련 항목 0건.
  - `/mcp` 다이얼로그에서 memento 항목 사라짐 확인.
  - MCP 도구(`mcp__memento__*`)가 즉시 disconnect됨.
- **Known limitations:**
  - 백업 후 재시작 폭주 패턴은 memento 제거만으로는 해결 안 됨. `.wslconfig` 조정이 별도로 필요.
  - 과거 대화 로그(`.jsonl`)에는 "memento" 문자열이 남아있음 — 사용자 합의로 손대지 않음.

### 2026-04-30 — 같은 패턴의 두 번째 VM down 사태 분석 + 워치독 재시작 절차 정립

- **What was done:**
  - 10:54:45 VM down 알림이 옛 텍스트 형식으로 도착(버튼 없음) 원인 추적.
  - 원인 두 가지 발견:
    1. PowerShell 프로세스는 시작 시 한 번만 dot-source. 파일 수정해도 메모리에 옛 함수 정의 보관.
    2. WSL repo와 Windows 사본 분리 — repo만 수정하면 실행 코드는 변하지 않음.
- **Artifacts:**
  - 본 progress.md (위 Known limitations 항목)
- **Verification:**
  - `Get-CimInstance Win32_Process`로 옛 PID(14264, 04-27 기동분) 확인 후 Stop-Process.
  - `schtasks /Run /TN DiskusageWatchdog`으로 새 프로세스 트리거.
- **Known limitations:**
  - 이 시점 워치독은 여전히 옛 코드 실행 중이었음(Windows 사본 미동기화). 5/2에서야 완전 해결.

### 이전 세션들 (요약)

- **VBS 키퍼 제거 → 복원 사이클** (`e522568` → `a8ee4f8`):
  - 한 번 VBS 내부 keepalive 루프를 제거했다가, 헤드리스 요구로 VBS 래퍼만 단순화해 복원.
  - 죽음 감지·재시작은 Task Scheduler PT1M Repetition + `IgnoreNew`로 일원화.
- **command-listener 분리** (`409f2d3`):
  - 워치독이 죽으면 알릴 자가 없는 문제 해결을 위해 별도 프로세스로 분리. 워치독 부재를 60초 안에 감지 후 알림.
- **일일 09시 하트비트 제거** (`1f7dc12`):
  - 사용자 요청으로 노이즈 제거.
- **HTTP 400 버그 수정** (커밋 `14b11c8 fix: send Telegram messages as UTF-8 JSON, fix nested keyboard array`):
  - PS5.1 form-encoded body의 emoji 깨짐 → JSON 본문으로 전환.
  - inline_keyboard ConvertTo-Json 3중 중첩 문제 → 리터럴 JSON 문자열로 회피.
- **30초 frozen 디바운스 도입**:
  - 10~15초 짧은 스파이크에 대한 false-positive 알림 항의 후.

---

## Decisions & Rationale (코드만 봐선 모를 정보)

| 결정 | 이유 |
|---|---|
| VBS 래퍼 부활 | `-WindowStyle Hidden`만으론 Task Scheduler 컨텍스트에서 창 깜빡임. 사용자 명시 요구 "헤드리스로 못해?". |
| VBS 내부 keepalive 제거 | 책임 분산이 디버깅을 어렵게 함. 죽음 감지·재시작 책임을 Task Scheduler 한 곳으로 일원화. |
| 09시 하트비트 제거 | 사용자가 노이즈로 판단함. |
| 30초 frozen 디바운스 | 짧은 I/O 스파이크에서 알림이 과민하게 발사되는 것을 사용자가 지적. |
| Telegram body를 JSON으로 | PS5.1 form-encoded에서 emoji 깨짐 → HTTP 400 → 몇 주간 알림이 묵묵히 안 가던 진짜 원인. |
| inline_keyboard를 리터럴 문자열로 | PS5.1 ConvertTo-Json이 inline_keyboard를 3중 중첩 배열로 만들어 Telegram이 거부. |
| VM down 알림에도 frozen과 동일 3-버튼 | 사용자 명시 요구 + UX 일관성. |
| `_TelegramLog`는 첫 시도 성공만 silent | 스킵(`[SKIP]`)·재시도 성공(`[OK] sent on retry #N`)·에러(`[ERROR]`)·최종실패(`[FAIL]`)는 모두 기록. 빈 telegram 로그 = "발송 시도 자체가 없음" 또는 "모든 발송이 첫 시도에 성공"을 의미. |
| memento MCP 완전 제거 | 사용자가 안 씀 + 1.3GB 메모리 회수. |
| **OneDrive 백업 현행 유지** (2026-07-22) | 매일 7.1GB(suho001) + 매주 68GB(VHDX) 업로드가 `[EXTERNAL]` 디스크 정체의 유력 원인이나, **사용자가 OneDrive 백업 자체를 업무상 필수로 판단**해 D:\ 이전안을 기각. 따라서 방아쇠는 상시 존재한다는 전제로 방어(루트 ns OOM 면제 + 이중 감지망)에 의존한다. |
| **커널경고를 알림 트리거에서 제외** (2026-08-06) | `__vm_enough_memory`를 "OOM 선행 신호"로 본 가설이 데이터로 부정됨 — 6일간 119건 발생 시점의 메모리가 **최대 77.2%**로 시스템 압박과 무상관이고, 실제 압박 사건(08-06 15:23, mem 98.8%)엔 경고가 **없었다**. AND 조건에 두면 경고 없이 오는 진짜 위험을 필터로 걸러낸다. 신호는 버리지 않고 로그 + 알림 본문의 참고 정보로 남겼다. |
| **알림 권고문에서 "OneDrive 일시중지" 삭제** (2026-08-06) | 7/22에 업무상 필수로 판단해 이미 기각한 조치를 반복 권고하고 있었다. 실행 불가능한 지시는 알림을 스팸으로 만든다. |
| **HID 음수를 0이 아닌 `-1`로** (2026-08-06) | 0으로 뭉개면 "숨은 메모리 없음"과 "이중계상으로 측정 불가"가 구분되지 않아 게이지가 조용히 눈이 먼다 — 08-06 하루에 1,286건이 그랬다. `n/a`로 드러내면 사후에 눈먼 구간을 식별할 수 있다. |
| **`Pss_Anon`(smaps_rollup) 방식 배제** (2026-08-06) | 이중계상을 원천 해결하지만 `PTRACE_MODE_READ` 권한이 필요해 monitor 실행 사용자(`aiwwt`)로는 119개 중 49개를 못 읽는다(차액 2553MB로 과대평가). root 실행은 침습적이라 채택하지 않음. |

---

## 작업 가정 (Assumptions)

- **WSL repo ↔ Windows 사본은 수동 동기화.** repo 변경 시 `cp` + 워치독 재시작 둘 다 필요.
- **PowerShell 프로세스는 시작 시 한 번만 dot-source.** 파일 변경 후엔 프로세스 재시작 필수.
- **Task Scheduler의 `IgnoreNew` 정책으로 단일 인스턴스 보장.** 1분 트리거 + 살아있으면 무시 = 죽었을 때만 1분 내 부활.
- **`[EXTERNAL]` 가드는 WSL이 원인 아닌 디스크 압박 식별용.** `PhysicalDisk` 높지만 `VHD I/O` 낮으면 = Windows 측 다른 프로세스 → WSL 액션 억제.
- **WSL 응답성 테스트는 비싼 작업이라 조건부 실행.** VHD I/O ≥ 50MB/s OR DiskPct ≥ 50% OR 이미 frozen일 때만. 부작용으로 죽은 WSL을 깨우는 효과도 있음.
- **이중 정리 경로의 중복 방지는 status 파일로 일원화.** WSL monitor가 자체 정리 중이면 `~/.diskusage/status=cleaning` 기록 → Windows 워치독이 `Get-WslMonitorStatus`로 확인하고 cleanup 트리거 스킵. 양쪽이 동시에 fstrim/journalctl 도는 사고 방지.

---

## 발견한 이상치 / 엣지 케이스

- **`wsl --system`은 루트 PID ns가 아니다** (2026-08-06 확증). ns inode `4026532211`(system) ≠ `4026532223`(Ubuntu), 둘 다 루트 아님. system ns의 `pid1=init() pid2=systemd pid3=init-systemd(Ub…)` — 루트라면 pid2가 `kthreadd`여야 한다. system ns는 Ubuntu ns를 **포함**하는 상위 ns이지만(Ubuntu의 pid1 systemd가 여기선 pid2) 여전히 루트가 아니다. **`dmesg`의 pid 222는 어느 ns에서도 접근 불가.**
- **`__vm_enough_memory` 경고는 메모리 압박과 무상관.** 6일 119건 전수에서 발생 시점 메모리 최대 **77.2%**. 경고 원문은 47회 전부 `pid: 222, comm: init`으로 동일 — 특정 프로세스가 큰 매핑을 시도하다 overcommit 회계에 걸리는 자체 동작이며, 커널이 할당을 **거부**한(= 방어가 작동한) 기록이다.
- **`HID` 게이지가 조용히 눈이 멀 수 있다.** `RssAnon`은 fork CoW·공유 익명 페이지를 프로세스마다 중복 계상하지만 `AnonPages`는 물리 페이지를 1회만 센다. 이중계상 총량이 실제 숨은 메모리를 넘으면 차액이 음수가 된다(실측 −70MB). 08-06 13:46:55 큰 I/O 시작과 함께 음수 영역에 진입해 그날 1,286건이 `0MB`로 기록됐다. **평시 26MB라는 기준선 자체가 이중계상 총량에 의존한다.**
- **04/27 기동된 워치독이 04/30까지 옛 코드로 살아있음.** Task Scheduler PT1M 반복은 기존 인스턴스가 살아있으면 새로 안 띄움 → 코드 갱신 시 자동 적용 안 됨.
- **WSL 메모리가 비정상 속도로 빠져나감.** 5/2 10:51:13 MEM 3.3GB → 10:51:34 MEM 0.8GB (21초 -2.5GB). 5/3 새벽도 동일 패턴.
- **WSL 죽음→회복→재죽음 사이클.** 5/3 05:06:30 백업 후 wsl restart 성공 → 05:07:08 즉시 메모리 다시 빠짐 → 05:08:28 재죽음 → 06:47까지 1.5시간 다운.
- **워치독 자체가 응답 못 한 갭.** 5/3 05:00:13~05:02:03 약 2분간 워치독 로그 없음 (host 디스크 마비로 워치독 자신도 멈춤).
- **PhysicalDisk 카운터 비현실적 값** (2020%, 4312%). Windows 카운터 누적 큐 깊이 표현 — 사용률 자체는 아니지만 압박 신호로는 유효.
- **Host 메모리 87.6% 상시 점유.** Total 15.9GB 중 13.9GB used (WSL이 4.1GB 잡은 상태). `autoMemoryReclaim=disabled`로 바꾸면 WSL이 풀로 10GB 잡을 때 host에 6GB만 남는 구조적 한계.
- **memento MCP 설정이 두 곳에 분산.** `~/.claude/.mcp.json`(프로젝트) + `~/.claude.json`(사용자) 양쪽에 있어 두 번에 걸쳐 정리.
- **Listener 409 Conflict** (이전 세션). getUpdates 동시 폴링 시 Telegram이 한쪽 강제 종료 → Task Scheduler 단일 인스턴스 정책으로 해결.
- **백업 자체는 정상 동작.** 5/3 05:00:01~05:06:12 (6분, 59GB → OneDrive). 1.5h 다운타임의 대부분은 백업 후 재시작이 자리잡지 못한 시간.

---

## Memory Leak 점검 결론

- **누수 없음.**
- 근거:
  1. OOM kill 0건 (3일치 dmesg/journalctl).
  2. 어제(5/2) 시간별 평균 vmmemWSL 메모리는 4.87~5.91GB 사이 변동 — 단조증가 아님.
  3. memento Node 프로세스 FD 26개 (누수 시 수천 개).
  4. Threads 17개, VmData 1.1GB (V8 정상 범위).
  5. 커널 Slab 193MB / SUnreclaim 89MB (낮음).
- **진짜 원인:** 워킹셋 자체가 host RAM 대비 빠듯 + autoMemoryReclaim 폭주.
- **다음 행동의 축:** "WSL 안에서 뭘 줄일까"가 아니라 "host와의 관계를 어떻게 조정할까".

---

## Confidence Markers (검증 수준)

본 문서의 진술 중 추측이 섞이거나 데이터로 입증 안 된 항목 표시.

### ⛔ 반증됨 (2026-08-06 실측으로 폐기)

- **"`wsl.exe --system`이 루트 PID ns를 공유한다"** (2026-07-22 2차 기록) — **틀렸다.** ns inode 대조와 `pid2=systemd`(루트라면 `kthreadd`)로 반증. 당시 판정 근거였던 "커널 스레드 가시성"은 재현되지 않는다. → `ROOTNS_GUARD` 무효.
- **"`__vm_enough_memory`는 OOM 붕괴의 선행 신호"** — 6일 119건 전수에서 발생 시점 메모리 최대 77.2%, 실제 압박 사건엔 경고 0건. 시스템 압박과 상관없이 특정 프로세스의 매핑 시도로 발생한다. → 알림 트리거에서 제외.
- **"HID 평시 ~26MB"** — 이중계상 총량에 의존하는 우연한 값이다. 08-06 13:46 이후 상시 음수(측정 불가) 영역. 절대 기준선으로 쓸 수 없다.

### 🟡 일반 지식 + 정황 일치 (직접 입증 안 함)

- **"PowerShell 프로세스는 시작 시 한 번만 dot-source"** — PS의 일반 동작 지식에 정황 증거(코드 갱신 후에도 옛 메시지 도착)가 부합. 메모리 덤프 등으로 직접 입증 안 함.
- **"Test-WslResponsive(`wsl -e true`)가 죽은 WSL을 깨우는 부작용 가능"** — wsl.exe 동작에 대한 추정. 본 세션에서 직접 검증 안 함.
- **"PhysicalDisk 카운터의 누적 큐 깊이 표현"** — Windows perfmon 카운터 일반 정의. 본 세션에서 직접 확인 안 함.

### 🟡 분석적 결론 (실험적 입증 미완)

- **"진짜 원인은 워킹셋이 host RAM 대비 빠듯 + autoMemoryReclaim 폭주"** — 누수 0건 + 폭주 패턴은 데이터로 확인됨. 그러나 "이것이 근본 원인"이라는 결론은 `.wslconfig` 변경 후 재현 여부로 검증해야 확정.
- **"백업 후 재시작이 자리잡지 못한 이유 = autoMemoryReclaim 폭주"** — 5/3 05:06:30 재시작 직후 메모리 빠짐은 로그 사실. 그러나 host 측 행동은 직접 관측 안 함.
- **"21초간 -2.5GB는 비정상 속도"** — 측정값은 사실. "비정상" 평가는 autoMemoryReclaim의 정상 회수 속도 기준을 모르는 상태에서의 판정.
- **"4/27 워치독이 옛 코드로 살아있었음"** — 프로세스 시작 시각 + 알림 형식의 정황 증거로 추정. 실행 중인 코드를 직접 dump해서 확인한 것 아님.

### 🔴 단일 데이터 포인트 / 표본 부족

- **"WSL 워킹셋 어제 평균 4.8~5.9GB"** — 5/2 1일치 watchdog 로그만 분석. 평일/주말, 작업 부하 변동 미고려. **`memory=8GB` 캡 권장의 근거가 1일 표본임에 유의.**
- **"`Scripts Weekly Backup` 매주 월 05:30 동작"** — schtask 정의(트리거)만 확인. 실제 스크립트 내용/로그는 확인 안 함.
- **"Listener 409 Conflict 해결됨"** — 이전 세션 기록. 본 세션에서 재발 여부 검증 안 함.
- **"memento 1.3GB 회수가 백업 시 압박 감소로 이어진다"** — 단순 산술 추정. 다음 백업(2026-05-10 05:00)에서 관측 필요.

### ⚠️ 가정 (자동 검증 안 됨)

- **"WSL repo와 Windows 사본은 자동 동기화 없음"** — 현 시점에서 사용자가 동기화 도구를 안 쓰는 것으로 보이지만, 향후 도입 가능성 미확인. 새로 도입되면 본 문서의 "수동 cp 필요" 가정은 무효.
- **"Send-WatchdogHeartbeat 호출 없음"** — `watchdog.ps1` grep 결과 0. 다른 곳에서 import해 쓰지 않는다는 가정.

---

## Known Issues & Pending

### ✅ 결론 — `.wslconfig` 조정안 (2026-07-22 결정: **A. 현행 유지**)

> **판단 근거가 바뀌었다.** 2026-07-22 진단에서 장애 원인이 "워킹셋이 host RAM 대비 빠듯함"이 아니라 **`/init`의 80초 폭주(초당 47MB)** 로 밝혀졌다. 폭주 속도가 이 정도면 캡이 8GB든 12GB든 결과가 같고, 오히려 8GB로 줄이면 OOM이 더 빨리 온다. 아래 C안 추천은 **근거가 무효화되었다.** 사용자 결정으로 `memory=10GB` + `autoMemoryReclaim=gradual` 현행 유지.
>
> 단, `autoMemoryReclaim`은 메모리 *크기*가 아니라 *회수 동작*이므로 `/init` 폭주와의 상관은 여전히 미검증이다. 재시작 후 `/init` RSS 실측이 쌓이면 재평가할 것.

과거 검토안 (기록 보존용):

| 방안 | memory= | autoMemoryReclaim | 영향 |
|---|---|---|---|
| A. 현재 유지 | 10GB | gradual | 백업·압박 시 WSL kill 계속 |
| B. memory 축소만 | 8GB | gradual | host 여유 +2GB, kill 빈도 감소 |
| **C. 둘 다** (추천) | **8GB** | **disabled** | host 여유 +2GB, WSL kill 거의 없음 |
| D. disabled만 | 10GB | disabled | host 메모리 부족, 페이징 악화. 비권장 |
| E. dropcache | 10GB | dropcache | 페이지 캐시만 회수, 워킹셋 보호. 중간 절충 |

추천 근거:
- WSL 워킹셋 어제 평균 4.8~5.9GB → 8GB cap이면 여유 2GB.
- Host에 8GB 확보 → 13.9GB 점유 → 약 11.9GB로 떨어짐 → 여유 4GB.

### 🔴 `ROOTNS_GUARD`가 헛돌고 있음 (2026-08-06 발견, 미해결)

`wsl --system`이 루트 ns가 아니므로 **2026-07-22에 구축한 배관 init OOM 면제는 실효가 없다.**
현재 `rootns-scan.sh`가 잡는 것은 pid 22(rss 1.8MB)뿐이고, 정작 `dmesg`가 지목하는
배관 init(전역 pid 222)에는 도달하지 못한다.

다음 작업 단위에서 다룰 것:

1. WSL2 구조상 루트 PID ns에 접근할 경로가 존재하는지 (Windows 호스트가 VM을 관리하므로 없을 가능성)
2. 접근 불가로 확정되면 방어를 포기하고 **관측 + 조기 경보**로 전환 — 그 경우 `MEM_PRESSURE` 알림이 유일한 방어선이 되므로 HID 이중계상 해소가 더 중요해진다
3. 또는 `.wslconfig`로 압박 자체를 줄이는 접근 (2026-07-22에 기각된 근거가 이번 발견으로 다시 흔들림)

### 미합의 사항

- **백업 시간 이동 여부.** 매주 월 05:00(사용자 수면 중) → 깨어있는 시간으로 옮길지. 메리트: 다운타임 시 즉시 반응. 디메리트: 사용 중 백업.
- **memento 제거 효과 검증.** 1.3GB 회수가 백업 시 압박 감소로 이어지는지는 다음 백업(2026-05-10 05:00)에서 관측 필요.
- **워치독에 host 측 top-IO 프로세스 캡처 추가** 제안 — 사용자 미응답.

### 기술 부채

- WSL repo와 Windows 사본 동기화가 수동. 자동 sync 스크립트 또는 symlink 검토 필요.
- 워치독 코드 변경 시 프로세스 재시작이 사람의 기억에 의존. 배포 스크립트화 필요.
- 텔레그램 발송 성공 케이스도 로그 남기는 옵션 추가 검토 (현재는 빈 로그 = OK 인지 미발송인지 구분 불가).
