#!/usr/bin/env bash
set -euo pipefail

echo "=== Diskusage WSL Setup ==="
echo ""

DISKUSAGE_HOME="${DISKUSAGE_HOME:-$HOME/.diskusage}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Create directories
echo "[1/5] Creating directories..."
mkdir -p "$DISKUSAGE_HOME/logs" "$DISKUSAGE_HOME/config"

# 2. Copy default config if not exists
if [[ ! -f "$DISKUSAGE_HOME/config/config.conf" ]]; then
    echo "[2/5] Installing default config..."
    cp "$SCRIPT_DIR/config.conf.default" "$DISKUSAGE_HOME/config/config.conf"
    echo "  → $DISKUSAGE_HOME/config/config.conf"
else
    echo "[2/5] Config already exists, skipping."
fi

# 3. Install packages
echo "[3/5] Installing required packages..."
PACKAGES_NEEDED=""
command -v iostat &>/dev/null || PACKAGES_NEEDED="$PACKAGES_NEEDED sysstat"
command -v iotop &>/dev/null  || PACKAGES_NEEDED="$PACKAGES_NEEDED iotop"

if [[ -n "$PACKAGES_NEEDED" ]]; then
    echo "  Installing:$PACKAGES_NEEDED"
    sudo apt-get update -qq && sudo apt-get install -y -qq $PACKAGES_NEEDED
else
    echo "  All packages already installed."
fi

# 4. Kernel parameters
echo "[4/5] Setting kernel parameters..."
SYSCTL_FILE="/etc/sysctl.d/99-diskusage.conf"
cat <<'SYSCTL' | sudo tee "$SYSCTL_FILE" > /dev/null
# Diskusage — WSL2 I/O optimization
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.swappiness=10
vm.vfs_cache_pressure=150
SYSCTL
sudo sysctl --load="$SYSCTL_FILE" > /dev/null
echo "  → Applied sysctl settings"

# 5. Sudoers NOPASSWD for cleanup commands
echo "[5/5] Setting up sudoers NOPASSWD..."
SUDOERS_FILE="/etc/sudoers.d/diskusage"
SUDO_CMDS="$(whoami) ALL=(ALL) NOPASSWD: /usr/sbin/fstrim, /usr/sbin/sysctl, /usr/sbin/iotop, /usr/bin/journalctl"
echo "$SUDO_CMDS" | sudo tee "$SUDOERS_FILE" > /dev/null
sudo chmod 440 "$SUDOERS_FILE"
echo "  → Sudoers configured"

# Create cleanup trigger script (called by watchdog via wsl -e)
TRIGGER_SCRIPT="$DISKUSAGE_HOME/cleanup_trigger.sh"
cat > "$TRIGGER_SCRIPT" << 'TRIGGER'
#!/usr/bin/env bash
LEVEL="${1:-warn}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Try to find project root from a stored path
if [[ -f "$SCRIPT_DIR/project_root" ]]; then
    PROJECT_ROOT="$(cat "$SCRIPT_DIR/project_root")"
else
    PROJECT_ROOT="$HOME/project/Diskusage"
fi
if [[ -f "$PROJECT_ROOT/lib/monitor/cleanup.sh" ]]; then
    source "$PROJECT_ROOT/lib/monitor/config.sh"
    source "$PROJECT_ROOT/lib/monitor/logger.sh"
    DISKUSAGE_HOME="${DISKUSAGE_HOME:-$HOME/.diskusage}"
    load_config
    source "$PROJECT_ROOT/lib/monitor/cleanup.sh"
    run_cleanup "$LEVEL"
fi
TRIGGER
chmod +x "$TRIGGER_SCRIPT"
# Store project root for the trigger script
echo "$SCRIPT_DIR" > "$DISKUSAGE_HOME/project_root"

echo ""
echo "=== Setup Complete ==="
echo "Next steps:"
echo "  1. Run setup.ps1 on Windows (for .wslconfig and BurntToast)"
echo "  2. Run: wsl --shutdown  (then restart WSL)"
echo "  3. Start monitoring:  ./monitor.sh start"
