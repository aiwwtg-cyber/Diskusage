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

# ── 루트 네임스페이스 (2026-07-22 2차 규명) ────────────────────────────────
# OOM 희생자였던 12GB init(전역 PID 219/220)은 Ubuntu ns 밖 — 여기 함수들로는
# 보이지 않는다. 유일한 접근로는 `wsl.exe --system`: 시스템 배포판이 루트
# PID ns를 공유하므로(커널 스레드 가시성으로 확인) 그 안에서 전역 /proc에
# 쓸 수 있다. 인증 불필요(-u root는 WSL 기본 권한 모델).

WSL_EXE="${WSL_EXE:-/mnt/c/Windows/System32/wsl.exe}"
ROOTNS_SCAN_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rootns-scan.sh"

# 루트 ns의 comm=init 목록을 "<pid> vsz=<kB> rss=<kB> adj=<N>" 형식으로 출력.
# mode=protect면 VmSize 4GB 이상(=12GB 예약 배관 init)에 -1000을 먼저 기록.
# 호스트 정체 중엔 wsl.exe 자체가 걸릴 수 있어 timeout 필수 — 보호는 평시에
# 미리 걸어두는 것이 요점이다.
rootns_init_guard() {
    local mode="${1:-protect}"
    [[ -x "$WSL_EXE" && -f "$ROOTNS_SCAN_SCRIPT" ]] || return 1
    (cd /mnt/c 2>/dev/null || cd /
     timeout 20 "$WSL_EXE" --system -u root sh -s "$mode" < "$ROOTNS_SCAN_SCRIPT" 2>/dev/null
    ) | tr -d '\0\r'
}

# 루트 ns 익명 메모리 추정치(MB) = 전역 AnonPages − Ubuntu ns 프로세스 합.
# 희생자 init의 비대가 그대로 이 값으로 드러난다 (평시 ~26MB, 사고 시 5.6GB).
# wsl.exe 호출 없이 /proc만 읽으므로 매 주기 돌려도 된다.
#
# 경합 주의(2026-07-22 가짜 경보 3건의 원인):
# - awk에 파일 목록을 직접 주면 스윕 도중 프로세스가 죽는 순간 mawk가 즉사해
#   합계가 조기 중단 → 차액 수 GB가 "숨은 메모리"로 둔갑한다.
#   cat은 사라진 파일을 건너뛰고 계속 가므로 cat 경유로 합산한다.
# - 스윕을 먼저, meminfo를 나중에 읽는다. 그러면 스윕 중 종료된 프로세스는
#   양쪽 모두에서 빠져 과대평가(가짜 경보) 대신 과소평가(음수)가 된다.
#
# 음수는 측정 불가다 (2026-08-06). RssAnon은 fork CoW·공유 익명 페이지를 프로세스마다
# 중복 계상하지만 AnonPages는 물리 페이지를 1회만 센다. 이중계상 총량이 실제 숨은
# 메모리를 넘으면 차액이 음수가 된다(실측 -70MB). 이를 0으로 뭉개면 "숨은 메모리
# 없음"과 구분되지 않아 게이지가 조용히 눈이 먼다 — 08-06 하루에만 1,286건이 그랬다.
# 따라서 -1을 돌려 호출부가 명시적으로 무효 처리하게 한다.
#
# Pss_Anon(smaps_rollup)을 쓰면 이중계상이 사라지지만 PTRACE_MODE_READ 권한이 필요해
# monitor 실행 사용자(aiwwt)로는 119개 중 49개를 못 읽는다(차액 2553MB로 과대평가). 배제.
HIDDEN_ANON_INVALID=-1

get_hidden_anon_mb() {
    local total seen diff
    seen=$(cat /proc/[0-9]*/status 2>/dev/null | awk '/^RssAnon:/{s+=$2} END{print s+0}')
    total=$(awk '/^AnonPages:/{print $2}' /proc/meminfo)
    diff=$(( (total - seen) / 1024 ))
    (( diff < 0 )) && diff=$HIDDEN_ANON_INVALID
    echo "$diff"
}

# 라이브러리로 source될 때는 아래를 실행하지 않는다.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-protect}" in
        protect) protect_wsl_init "${2:-1}" ;;
        rss)     echo "$(get_wsl_init_rss_mb)MB" ;;
        pids)    find_wsl_init_pids ;;
        check)   get_wsl_init_oom_adj ;;
        hidden)  h=$(get_hidden_anon_mb)
                 (( h < 0 )) && echo "n/a (RssAnon 이중계상이 차액을 삼킴)" || echo "${h}MB" ;;
        rootns)  rootns_init_guard "${2:-scan}" ;;
        *)       echo "Usage: $0 {protect [attempts]|rss|pids|check|hidden|rootns [scan|protect]}" >&2; exit 1 ;;
    esac
fi
