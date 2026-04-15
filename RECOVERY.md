# Diskusage 복구 가이드

PC 포맷 / WSL 재설치 / 다른 PC 이전 시 복구 절차.

## 백업 상태

### ✅ GitHub에 있음 (자동 복구)
- 모든 스크립트 (`monitor.sh`, `watchdog.ps1`, `setup.sh`, `setup.ps1`, `register-task.ps1` 등)
- 라이브러리 (`lib/monitor/`, `lib/watchdog/`)
- 기본 설정 템플릿 (`config.conf.default`)
- 문서 (`README.md`, `RECOVERY.md`)

### ❌ GitHub에 없음 (수동 재설정 필요)

이 값들은 민감정보라 레포에 포함시키지 않습니다. **별도로 백업**하세요:

| 파일 | 내용 | 백업 위치 권장 |
|------|------|----------------|
| `C:\Users\aiwwt\.wslconfig` | WSL 메모리/스왑 설정 | 개인 Notion / 암호 관리자 |
| `~/project/Chatbot/.env` | Telegram BOT_TOKEN 등 | 암호 관리자 |
| `~/.diskusage/config/telegram.conf` | CHAT_ID | 암호 관리자 |
| `C:\Users\aiwwt\.diskusage\config\telegram.conf` | BOT_TOKEN + CHAT_ID | 암호 관리자 |

## 복구 절차

### 1. WSL 환경 준비

Windows에 WSL2 + Ubuntu 설치:
```powershell
wsl --install -d Ubuntu
```

### 2. Windows `.wslconfig` 복원

`C:\Users\aiwwt\.wslconfig` 생성:

```ini
[wsl2]
networkingMode=mirrored
memory=10GB
swap=4GB
processors=4
```

(메모리/스왑 값은 사용 RAM에 맞게 조정, 기본: 총 RAM의 50% 이하)

### 3. 레포 복제

WSL 접속 후:

```bash
cd ~ && mkdir -p project && cd project
git clone https://github.com/aiwwtg-cyber/Diskusage.git
cd Diskusage
```

### 4. WSL 측 초기 설정

```bash
./setup.sh
```

수행하는 일:
- `sysstat`, `iotop` 패키지 설치
- `/etc/sysctl.d/99-diskusage.conf` 커널 파라미터 적용
- `/etc/sudoers.d/diskusage` NOPASSWD 설정
- `~/.diskusage/` 디렉토리 생성
- `cleanup_trigger.sh` 생성

### 5. 텔레그램 설정 복원

WSL 측 chat_id:
```bash
echo "CHAT_ID=YOUR_CHAT_ID" > ~/.diskusage/config/telegram.conf
```

Chatbot 프로젝트의 `.env`에 `TELEGRAM_BOT_TOKEN`이 있어야 WSL 측 모니터가 알림을 보낼 수 있습니다 (`lib/monitor/telegram.sh`가 거기서 읽음). Chatbot 프로젝트가 없다면 직접 `.env` 생성:
```bash
mkdir -p ~/project/Chatbot
echo 'TELEGRAM_BOT_TOKEN=YOUR_BOT_TOKEN' > ~/project/Chatbot/.env
```

### 6. Windows 측 파일 복사

WSL에서 Windows로 PS1 파일 복사:

```bash
WIN_DIR="/mnt/c/Users/aiwwt/Diskusage"
mkdir -p "$WIN_DIR/lib/watchdog" "/mnt/c/Users/aiwwt/.diskusage/config"
cp ~/project/Diskusage/watchdog.ps1 \
   ~/project/Diskusage/setup.ps1 \
   ~/project/Diskusage/register-task.ps1 \
   ~/project/Diskusage/watchdog-hidden.vbs \
   ~/project/Diskusage/config.conf.default \
   "$WIN_DIR/"
cp ~/project/Diskusage/lib/watchdog/*.ps1 "$WIN_DIR/lib/watchdog/"
```

### 7. Windows 텔레그램 설정 복원

`C:\Users\aiwwt\.diskusage\config\telegram.conf` 생성:

```
BOT_TOKEN=YOUR_BOT_TOKEN
CHAT_ID=YOUR_CHAT_ID
```

### 8. Windows 작업 스케줄러 등록

Windows PowerShell에서:

```powershell
cd C:\Users\aiwwt\Diskusage
powershell -ExecutionPolicy Bypass -File .\register-task.ps1
```

### 9. WSL 재시작 및 모니터 시작

```powershell
# Windows PowerShell
wsl --shutdown
```

WSL 재접속 후:

```bash
cd ~/project/Diskusage
./monitor.sh start
```

### 10. 동작 확인

- 텔레그램에 `✅ Diskusage Monitor Started` 알림 수신
- Windows 스케줄러 실행 시 `🟢 Windows Watchdog Started` 알림 수신
- `./monitor.sh status` → running 확인
- `./monitor.sh report` → 로그 정상 기록 확인

## 복구 시 체크리스트

- [ ] `wsl --install`로 WSL2 + Ubuntu 설치
- [ ] `.wslconfig` 복원 (메모리/스왑)
- [ ] GitHub에서 레포 clone
- [ ] `./setup.sh` 실행
- [ ] `~/.diskusage/config/telegram.conf` 에 CHAT_ID 입력
- [ ] `~/project/Chatbot/.env` 에 TELEGRAM_BOT_TOKEN 입력 (또는 Chatbot 프로젝트 복원)
- [ ] Windows에 PS1 파일 복사
- [ ] Windows `.diskusage\config\telegram.conf` 에 BOT_TOKEN + CHAT_ID 입력
- [ ] `register-task.ps1` 실행
- [ ] `wsl --shutdown` 후 재접속
- [ ] `./monitor.sh start`
- [ ] 텔레그램 Started 알림 수신 확인

## 참고

- 로그는 `~/.diskusage/logs/`에 쌓이며 포맷되면 사라집니다. 과거 로그 보존이 필요하면 주기적으로 외부 백업.
- `config.conf`를 수정했다면 개인 백업 권장 (기본값은 `config.conf.default`로 복구 가능).
