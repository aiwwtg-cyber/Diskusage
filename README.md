# Diskusage

WSL2 디스크 I/O 모니터링 및 자동 대응 시스템.

Windows 11 WSL2 환경에서 vmmemWSL 디스크 사용률 100% 문제를 진단하고 예방합니다.

## 초기 설정 (최초 1회만)

### 1. WSL에서 setup.sh 실행

```bash
cd ~/project/Diskusage
./setup.sh
```

하는 일: 패키지 설치, 커널 파라미터 최적화, 정리 명령 sudo 설정

### 2. Windows PowerShell에서 setup.ps1 실행

PowerShell 파일은 WSL에서 Windows로 미리 복사해야 합니다:

```bash
# WSL에서 실행
WIN_DIR="/mnt/c/Users/aiwwt/Diskusage"
mkdir -p "$WIN_DIR/lib/watchdog"
cp ~/project/Diskusage/setup.ps1 "$WIN_DIR/"
cp ~/project/Diskusage/watchdog.ps1 "$WIN_DIR/"
cp ~/project/Diskusage/lib/watchdog/*.ps1 "$WIN_DIR/lib/watchdog/"
cp ~/project/Diskusage/config.conf.default "$WIN_DIR/"
```

Windows PowerShell을 열고 (시작 메뉴 > "PowerShell" 검색):

```powershell
cd C:\Users\aiwwt\Diskusage
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

- "Apply new .wslconfig?" 물으면 → `.wslconfig`을 이미 수정했으면 `n`, 아니면 `y`

### 3. .wslconfig 확인

WSL에서 직접 수정 가능:

```bash
cat /mnt/c/Users/aiwwt/.wslconfig
```

권장 설정 (16GB RAM 기준):

```ini
[wsl2]
memory=8GB
swap=4GB
processors=4
autoMemoryReclaim=gradual
sparseVhd=true
```

### 4. WSL 재시작

```bash
wsl.exe --shutdown
```

SSH 연결이 끊기므로 다시 접속합니다.

## 일상 사용법

### 모니터링 시작 (WSL 재시작할 때마다)

```bash
cd ~/project/Diskusage
./monitor.sh start
```

이것만 하면 됩니다. 백그라운드에서 자동으로:
- 5초마다 디스크 I/O 감시
- I/O 60%+ 시 journal/tmp 자동 정리
- I/O 75%+ 시 fstrim 추가 실행
- 모든 이벤트 로그 기록

### 상태 확인

```bash
./monitor.sh status    # 실행 중인지 확인
./monitor.sh report    # 오늘의 I/O 리포트
```

### 모니터링 종료

```bash
./monitor.sh stop
```

### Windows 워치독 (선택사항)

WSL이 먹통이 돼도 Windows에서 알림을 받고 싶을 때:

```powershell
cd C:\Users\aiwwt\Diskusage
powershell -ExecutionPolicy Bypass -File .\watchdog.ps1
```

- 5초마다 콘솔에 상태 출력
- 위험 시 Windows 토스트 알림
- `wsl --shutdown`은 사용자 확인 후에만 실행 (자동 아님)
- 끄려면 `Ctrl+C`

## 동작 흐름

```
정상 (I/O < 60%)
  → 로그만 기록

주의 (I/O 60%+, 30초 지속)
  → journal 로그 축소

경고 (I/O 75%+, 30초 지속)
  → journal + tmp 정리 + fstrim
  → 폴링 간격 15초로 전환 (모니터 자체 부하 감소)

위험 (I/O 90%+, 60초 지속)
  → Windows 워치독이 알림 표시

최후 (I/O 95%+, 120초 지속)
  → Windows 워치독이 "WSL 종료할까요?" 확인 대화상자
  → 사용자가 Yes 눌러야만 wsl --shutdown 실행
```

## 되돌리기

모든 변경을 원래대로 되돌리려면:

```bash
# WSL: 커널 파라미터 제거
sudo rm /etc/sysctl.d/99-diskusage.conf
sudo rm /etc/sudoers.d/diskusage

# WSL: 모니터 데이터 제거
rm -rf ~/.diskusage

# Windows: .wslconfig 복원 (PowerShell에서)
# Copy-Item C:\Users\aiwwt\.wslconfig.backup.20260320 C:\Users\aiwwt\.wslconfig

# Windows: BurntToast 제거 (PowerShell에서)
# Uninstall-Module BurntToast

# Windows: Diskusage 폴더 제거 (PowerShell에서)
# Remove-Item -Recurse C:\Users\aiwwt\Diskusage
```

## 파일 구조

```
~/project/Diskusage/          ← WSL (원본)
├── monitor.sh                 ← 모니터 (매일 사용)
├── setup.sh                   ← WSL 설정 (1회)
├── config.conf.default        ← 기본 설정 템플릿
├── lib/monitor/               ← 모니터 라이브러리
│   ├── config.sh
│   ├── diskstats.sh
│   ├── logger.sh
│   └── cleanup.sh
└── lib/watchdog/              ← 워치독 라이브러리
    ├── counters.ps1
    ├── escalation.ps1
    └── notification.ps1

C:\Users\aiwwt\Diskusage\     ← Windows (복사본)
├── watchdog.ps1               ← 워치독 (선택)
├── setup.ps1                  ← Windows 설정 (1회)
└── lib\watchdog\              ← 워치독 라이브러리

~/.diskusage/                  ← 런타임 데이터
├── config/config.conf         ← 사용자 설정
├── logs/                      ← 날짜별 로그
├── monitor.pid                ← 실행 중 PID
└── status                     ← 현재 상태 (idle/cleaning)
```

## 설정 변경

`~/.diskusage/config/config.conf` 에서 임계값, 폴링 간격 등을 조정할 수 있습니다.
모니터 재시작 후 적용: `./monitor.sh stop && ./monitor.sh start`
