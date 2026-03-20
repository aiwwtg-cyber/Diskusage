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
