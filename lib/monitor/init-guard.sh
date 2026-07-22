#!/usr/bin/env bash
# init-guard.sh — WSL 최상위 /init 프로세스의 OOM 면제 및 메모리 관측
#
# WSL2에서 소켓·interop을 중개하는 /init은 PID 1이 아니라 별도 PID다.
# 커널은 PID 1만 OOM에서 보호하므로, /init이 시스템 최대 프로세스가 되는 순간
# OOM killer가 이를 골라 죽인다. 그러면 bind()가 AF_UNIX·AF_VSOCK·AF_NETLINK
# 전 계열에서 ENOSYS(38)를 반환하고 WSL이 반죽음 상태가 된다
# (새 세션 불가 = Wsl/Service/E_UNEXPECTED, containerd shim 생성 불가).
#
# 2026-07-22 하루에 2회 재현. docs/plans/2026-07-22-init-oom-guard.md 참조.

# comm이 정확히 'init'이고 uid 0인 프로세스 = WSL 최상위 /init.
# SessionLeader / Relay(N)도 같은 /init 바이너리지만 세션 단위로 생멸하고
# 크기가 MB 단위라 OOM 후보가 아니다. 최상위만 대상으로 한다.
find_wsl_init_pids() {
    local d pid comm uid
    for d in /proc/[0-9]*; do
        [[ -r "$d/comm" ]] || continue
        read -r comm < "$d/comm" || continue
        [[ "$comm" == "init" ]] || continue
        uid=$(awk '/^Uid:/{print $2; exit}' "$d/status" 2>/dev/null) || continue
        [[ "$uid" == "0" ]] || continue
        pid=${d#/proc/}
        echo "$pid"
    done
}

# oom_score_adj를 음수로 낮추려면 CAP_SYS_RESOURCE가 필요하다 → root 전용.
# 부팅 직후 /init이 아직 없을 수 있어 attempts 회 재시도한다.
protect_wsl_init() {
    local attempts="${1:-1}" i pid protected found
    for (( i = 1; i <= attempts; i++ )); do
        protected=0
        found=0
        for pid in $(find_wsl_init_pids); do
            found=$(( found + 1 ))
            echo -1000 > "/proc/$pid/oom_score_adj" 2>/dev/null && protected=$(( protected + 1 ))
        done
        if (( protected > 0 )); then
            echo "protected $protected /init process(es) with oom_score_adj=-1000"
            return 0
        fi
        if (( found > 0 )); then
            echo "found $found /init process(es) but cannot write oom_score_adj — must run as root" >&2
            return 1
        fi
        (( i < attempts )) && sleep 1
    done
    echo "no WSL /init process found after $attempts attempt(s)" >&2
    return 1
}

get_wsl_init_rss_mb() {
    local pid total=0 kb
    for pid in $(find_wsl_init_pids); do
        kb=$(awk '/^VmRSS:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null) || continue
        [[ -n "$kb" ]] && total=$(( total + kb ))
    done
    echo $(( total / 1024 ))
}

get_wsl_init_oom_adj() {
    local pid adj
    for pid in $(find_wsl_init_pids); do
        adj=$(cat "/proc/$pid/oom_score_adj" 2>/dev/null) || continue
        echo "$pid:$adj"
    done
}

# 라이브러리로 source될 때는 아래를 실행하지 않는다.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-protect}" in
        protect) protect_wsl_init "${2:-1}" ;;
        rss)     echo "$(get_wsl_init_rss_mb)MB" ;;
        pids)    find_wsl_init_pids ;;
        check)   get_wsl_init_oom_adj ;;
        *)       echo "Usage: $0 {protect [attempts]|rss|pids|check}" >&2; exit 1 ;;
    esac
fi
