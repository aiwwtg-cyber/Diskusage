# counters.ps1 — Hyper-V Virtual Storage Device 카운터 읽기

function Get-WslVhdPaths {
    try {
        $instances = (Get-Counter -ListSet "Hyper-V Virtual Storage Device" -ErrorAction Stop).PathsWithInstances
        $wslInstances = $instances | Where-Object { $_ -match "wsl.*ext4|swap" }
        return $wslInstances
    } catch {
        return @()
    }
}

function Get-VhdIoRate {
    $result = @{
        ReadBytesPerSec = [double]0
        WriteBytesPerSec = [double]0
        TotalMBps = [double]0
    }

    try {
        $counterPaths = @(
            "\Hyper-V Virtual Storage Device(*wsl*ext4*)\Read Bytes/sec"
            "\Hyper-V Virtual Storage Device(*wsl*ext4*)\Write Bytes/sec"
            "\Hyper-V Virtual Storage Device(*swap*)\Read Bytes/sec"
            "\Hyper-V Virtual Storage Device(*swap*)\Write Bytes/sec"
        )
        $counters = Get-Counter -Counter $counterPaths -ErrorAction SilentlyContinue
        if ($counters) {
            foreach ($sample in $counters.CounterSamples) {
                if ($sample.Path -match "read bytes") {
                    $result.ReadBytesPerSec += $sample.CookedValue
                } elseif ($sample.Path -match "write bytes") {
                    $result.WriteBytesPerSec += $sample.CookedValue
                }
            }
        }
    } catch {
        # Hyper-V counters not available (Windows Home, etc.)
    }

    $result.TotalMBps = [math]::Round(($result.ReadBytesPerSec + $result.WriteBytesPerSec) / 1MB, 2)
    return $result
}

function Get-PhysicalDiskPercent {
    try {
        $counter = Get-Counter "\PhysicalDisk(_Total)\% Disk Time" -ErrorAction Stop
        return [math]::Round($counter.CounterSamples[0].CookedValue, 2)
    } catch {
        return 0
    }
}

function Get-VmmemMemoryMB {
    try {
        # 정확 일치 필수: 다른 HCS VM(Claude Cowork 샌드박스 등)이 plain "vmmem"으로 떠서
        # 와일드카드로 잡으면 그쪽 워킹셋을 WSL 메모리로 오인함 (2026-07-09 오탐 사태)
        $proc = Get-Process -Name "vmmemWSL" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            return [math]::Round($proc.WorkingSet64 / 1MB, 2)
        }
    } catch {}
    return 0
}

function Test-WslIsIoCause {
    param(
        [double]$VhdTotalMBps,
        [double]$PhysicalDiskPct,
        [double]$BaselineMBps
    )
    $vhdPct = ($VhdTotalMBps / $BaselineMBps) * 100
    return ($vhdPct -ge 30 -and $PhysicalDiskPct -ge 50)
}
