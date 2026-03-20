<#
.SYNOPSIS
    Diskusage Windows Setup — .wslconfig 최적화 + BurntToast 설치
#>

Write-Host "=== Diskusage Windows Setup ===" -ForegroundColor Cyan
Write-Host ""

# 1. Detect system RAM
$totalRAM = [math]::Round((Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1GB)
$wslMemory = [math]::Floor($totalRAM / 2)
Write-Host "[1/3] System RAM: ${totalRAM}GB (WSL limit: ${wslMemory}GB)"

# 2. .wslconfig
$wslConfigPath = "$env:USERPROFILE\.wslconfig"
$newConfig = @"
[wsl2]
memory=${wslMemory}GB
swap=2GB
processors=4
autoMemoryReclaim=gradual
sparseVhd=true
"@

if (Test-Path $wslConfigPath) {
    $backupPath = "$env:USERPROFILE\.wslconfig.backup.$(Get-Date -Format 'yyyyMMdd')"
    Write-Host "[2/3] Backing up existing .wslconfig to $backupPath"
    Copy-Item $wslConfigPath $backupPath

    Write-Host ""
    Write-Host "Current .wslconfig:" -ForegroundColor Yellow
    Get-Content $wslConfigPath
    Write-Host ""
    Write-Host "Proposed .wslconfig:" -ForegroundColor Green
    Write-Host $newConfig
    Write-Host ""

    $confirm = Read-Host "Apply new .wslconfig? (y/n)"
    if ($confirm -ne "y") {
        Write-Host "Skipping .wslconfig update."
    } else {
        $newConfig | Out-File -FilePath $wslConfigPath -Encoding utf8
        Write-Host "  → .wslconfig updated"
    }
} else {
    Write-Host "[2/3] Creating .wslconfig..."
    $newConfig | Out-File -FilePath $wslConfigPath -Encoding utf8
    Write-Host "  → .wslconfig created"
}

# 3. BurntToast
Write-Host "[3/3] Checking BurntToast module..."
if (Get-Module -ListAvailable -Name BurntToast) {
    Write-Host "  BurntToast already installed."
} else {
    Write-Host "  Installing BurntToast..."
    try {
        Install-Module -Name BurntToast -Scope CurrentUser -Force -ErrorAction Stop
        Write-Host "  → BurntToast installed"
    } catch {
        Write-Host "  → BurntToast installation failed. Will use MessageBox as fallback." -ForegroundColor Yellow
    }
}

# Create log directory on Windows side
$logDir = "$env:USERPROFILE\.diskusage\logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor Green
Write-Host "Next steps:"
Write-Host "  1. Run 'wsl --shutdown' to apply .wslconfig changes"
Write-Host "  2. Restart WSL and run: ./monitor.sh start"
Write-Host "  3. In PowerShell: .\watchdog.ps1"
