#!/bin/sh
# rootns-scan.sh — WSL VM 루트 네임스페이스에서 실행되는 스캔/보호 스크립트.
#
# 반드시 `wsl.exe --system -u root sh -s [protect]` 의 stdin으로 주입해 실행한다.
# (시스템 배포판은 루트 PID ns를 공유하므로 커널 전역 프로세스가 보인다.
#  Ubuntu ns 안에서는 VM 배관 init이 보이지 않아 이 경로가 유일하다.)
#
# 출력: "<pid> vsz=<kB> rss=<kB> adj=<oom_score_adj>" — comm=init인 프로세스만.
# protect 인자: VmSize 4GB 이상인 init(= 12GB 예약을 가진 배관 init)에
# oom_score_adj=-1000을 기록한다. SessionLeader/plan9 등 작은 init은 건드리지 않는다.
MODE="${1:-scan}"
for p in /proc/[0-9]*; do
    [ -r "$p/comm" ] || continue
    c=$(cat "$p/comm" 2>/dev/null)
    [ "$c" = "init" ] || continue
    v=$(grep VmSize "$p/status" 2>/dev/null | tr -dc '0-9')
    r=$(grep VmRSS "$p/status" 2>/dev/null | tr -dc '0-9')
    if [ "$MODE" = "protect" ] && [ "${v:-0}" -ge 4000000 ]; then
        echo -1000 > "$p/oom_score_adj" 2>/dev/null
    fi
    a=$(cat "$p/oom_score_adj" 2>/dev/null)
    echo "${p#/proc/} vsz=${v:-0} rss=${r:-0} adj=${a:-?}"
done
