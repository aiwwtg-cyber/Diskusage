#!/usr/bin/env bash
# cleanup.sh — 안전한 정리 액션

TMP_DIRS="${TMP_DIRS:-/tmp}"

get_cleanup_actions() {
    local level="$1"
    case "$level" in
        warn)
            echo "journal"
            ;;
        alert|danger)
            echo "journal tmp fstrim"
            ;;
        *)
            echo ""
            ;;
    esac
}

run_cleanup() {
    local level="$1"
    local actions
    actions=$(get_cleanup_actions "$level")

    for action in $actions; do
        case "$action" in
            journal)  cleanup_journal ;;
            tmp)      cleanup_tmp ;;
            fstrim)   cleanup_fstrim ;;
        esac
    done
}

cleanup_journal() {
    if command -v journalctl &>/dev/null; then
        sudo journalctl --vacuum-size=50M 2>/dev/null && \
            log_action "journalctl vacuum applied"
    fi
}

cleanup_tmp() {
    local dir
    for dir in $TMP_DIRS; do
        find "$dir" -maxdepth 1 -type f -mtime +2 -delete 2>/dev/null
    done
    log_action "tmp cleanup applied"
}

cleanup_fstrim() {
    if command -v fstrim &>/dev/null; then
        sudo fstrim / 2>/dev/null && \
            log_action "fstrim applied"
    fi
}
