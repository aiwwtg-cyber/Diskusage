#!/usr/bin/env bash
# WSL /init의 OOM 면제를 부팅 시 자동 적용하도록 systemd에 등록한다.
# 배경: docs/plans/2026-07-22-init-oom-guard.md
#
#   sudo ./install-init-guard.sh
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$REPO_DIR/lib/monitor/init-guard.sh"
UNIT_NAME=diskusage-init-guard.service
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
WANTS_DIR=/etc/systemd/system/multi-user.target.wants

[[ $EUID -eq 0 ]] || { echo "root 권한이 필요합니다:  sudo $0" >&2; exit 1; }
[[ -f "$GUARD" ]] || { echo "init-guard.sh를 찾을 수 없습니다: $GUARD" >&2; exit 1; }
chmod +x "$GUARD"

cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Protect WSL /init from the OOM killer
Documentation=file://$REPO_DIR/docs/plans/2026-07-22-init-oom-guard.md
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$GUARD protect 10

[Install]
WantedBy=multi-user.target
EOF

# systemctl enable과 동일한 효과. D-Bus가 죽은 상태에서도 동작하도록 직접 링크한다.
mkdir -p "$WANTS_DIR"
ln -sf "$UNIT_PATH" "$WANTS_DIR/$UNIT_NAME"

if systemctl daemon-reload 2>/dev/null; then
    echo "daemon-reload OK"
else
    echo "daemon-reload 생략 (D-Bus 불가) — 부팅 시 새로 읽으므로 문제 없음"
fi

echo "설치 완료: $UNIT_PATH"
echo "부팅 시 자동 적용: $WANTS_DIR/$UNIT_NAME"
echo

# 지금 바로 적용해 본다. /init이 이미 죽은 상태라면 재시작 후 자동 적용된다.
if "$GUARD" protect 1; then
    "$GUARD" check
else
    echo "→ 현재 /init이 없어 적용 보류. WSL 재시작 시 자동 적용됩니다."
fi
