# 2026-07-10 — vmmem 와일드카드로 인한 WSL VM down 오탐 수정

## Goal

워치독이 다른 HCS VM(Claude Desktop Cowork 샌드박스 등)에 속지 않고 WSL VM(`vmmemWSL`)만 측정하도록 수정하여, 7/9~7/10 반복된 "WSL VM 종료/재시작" 오탐을 제거한다.

## 배경 (조사 결과)

- WSL VM은 7/5 05:06부터 무중단 가동 중 (`vmmemWSL` PID 8868, WS 2.9GB).
- 7/9 06:33 Claude Desktop 업데이트로 `cowork-svc.exe` 설치 → 06:38 Cowork 샌드박스 VM 기동 (plain `vmmem` PID 25500, 커밋 4.1GB, 워킹셋 40~170MB).
- `Get-VmmemMemoryMB`의 `Get-Process -Name "vmmem*" | Select -First 1`이 알파벳순으로 `vmmem`(Cowork)을 선택 → 워킹셋이 50MB 경계를 오르내리며 down/up 플래핑 발생.
- 모든 "재시작됨" 알림의 Memory 0.1~0.2GB = Cowork VM 워킹셋. 진짜 WSL은 한 번도 안 죽음.

## Steps

1. `lib/watchdog/counters.ps1`의 `Get-VmmemMemoryMB`: `-Name "vmmem*"` → `-Name "vmmemWSL"` 정확 일치. `vmmem` 폴백은 넣지 않음 (Cowork VM 존재 시 실제 다운을 가릴 수 있음).
2. Windows 실행 사본 `C:\Users\aiwwt\Diskusage\lib\watchdog\counters.ps1`으로 복사.
3. 실행 중 워치독 프로세스 종료 → Task Scheduler(PT1M)로 부활 (또는 `schtasks /Run`).
4. 검증 후 progress.md 갱신.

## Files-to-Touch

- `lib/watchdog/counters.ps1` (repo)
- `C:\Users\aiwwt\Diskusage\lib\watchdog\counters.ps1` (Windows 사본)

## Assumptions

- 이 머신의 WSL VM 프로세스명은 `vmmemWSL`로 고정 (WSL 2.x 명명).
- 새 워치독 프로세스는 상태가 리셋되므로 7/10 07:17 down 건에 대한 "재시작됨" 메시지는 발송되지 않음 (의도된 동작).

## Verification Criteria

- 재시작 후 워치독 로그 2분 관찰: MEM 2.5~3GB대, `WSL_VM_DOWN` 0건.
- 텔레그램 SELFTEST_OK 로그 확인.

## Execution Outcome

- **실제 수행:** 계획대로 1줄 수정(+주석 2줄), Windows 사본 복사, 워치독 재시작 완료.
- **계획과 차이:**
  1. 워치독 프로세스가 예상(1개)과 달리 2개 발견됨 — 6/19 기동된 옛 코드 인스턴스(PID 20260)가 살아있었음. `IgnoreNew` 정책이 중복을 못 막은 사례. 둘 다 종료 후 Task Scheduler가 새 인스턴스(PID 32368, 07:39:01) 부활.
  2. 프로세스 조회 시 `CommandLine -match 'watchdog.ps1'` 필터가 조회용 powershell 자기 자신도 매칭함 → `$_.ProcessId -ne $PID` 제외 필요 (향후 진단 시 주의).
- **검증 수치:** 재시작 후 로그 — MEM 2.8→4.1GB (실제 vmmemWSL 워킹셋), `WSL_VM_DOWN` 0건, `SELFTEST_OK: bot authenticated`. 워치독 단일 인스턴스 확인.
- **Known limitations:**
  - 7/10 07:17 오탐 down 건은 프로세스 재시작으로 상태가 리셋되어 "재시작됨" 정정 메시지가 발송되지 않음 (사용자 인지 완료).
  - Cowork VM(plain `vmmem`, 커밋 4.1GB)은 그대로 실행 중 — 처리 여부는 사용자 결정 사항.
  - down 판정이 여전히 "vmmemWSL 워킹셋 < 50MB" 프록시. 프로세스 부재 기반 판정으로의 보강은 미적용 (현재 오탐 원인은 아님).
