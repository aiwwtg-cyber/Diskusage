#!/usr/bin/env bash
# diskstats.sh — /proc/diskstats 파싱 + 설정 로딩

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

parse_diskstats_line() {
    local line="$1"
    local fields
    read -ra fields <<< "$line"
    echo "${fields[5]} ${fields[9]}"
}

read_diskstats() {
    local total_rd=0 total_wr=0
    while read -r line; do
        local fields
        read -ra fields <<< "$line"
        local name="${fields[2]}"
        if [[ "$name" =~ ^(sd|vd|nvme)[a-z]+$ ]] || [[ "$name" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
            local rd="${fields[5]}"
            local wr="${fields[9]}"
            total_rd=$((total_rd + rd))
            total_wr=$((total_wr + wr))
        fi
    done < /proc/diskstats
    echo "$total_rd $total_wr"
}

calc_io_kbps() {
    local prev_rd="$1" prev_wr="$2" curr_rd="$3" curr_wr="$4" interval="$5"
    local delta_rd=$(( curr_rd - prev_rd ))
    local delta_wr=$(( curr_wr - prev_wr ))
    local rd_kbps=$(( delta_rd * 512 / 1024 / interval ))
    local wr_kbps=$(( delta_wr * 512 / 1024 / interval ))
    local total=$(( rd_kbps + wr_kbps ))
    echo "$rd_kbps $wr_kbps $total"
}

get_io_level() {
    local total_kbps="$1"
    if (( total_kbps >= MONITOR_IO_DANGER_KB )); then
        echo "danger"
    elif (( total_kbps >= MONITOR_IO_ALERT_KB )); then
        echo "alert"
    elif (( total_kbps >= MONITOR_IO_WARN_KB )); then
        echo "warn"
    else
        echo "normal"
    fi
}
