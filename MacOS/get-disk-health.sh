#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Script:      get-disk-health.sh
# Synopsis:    Checks disk space, APFS container health, swap, SMART, and Time Machine.
# Description: Collects all disk health data in parallel, reasons across findings,
#              outputs a clean report sized for ticket screenshots.
#              Use --deep to also run APFS container verification (adds 20-60s but
#              catches filesystem corruption that standard checks cannot detect).
# Author:      Lachlan Alston
# Version:     v1
# Updated:     2026-04-18
# ─────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────
#  HELPERS
# ─────────────────────────────────────────────────────────────

write_divider() {
    local t="$1"
    local pad=$(( 56 - ${#t} ))
    [[ $pad -lt 1 ]] && pad=1
    printf '\033[36m── %s %s\033[0m\n' "$t" "$(printf '─%.0s' $(seq 1 $pad))"
}

write_kv() {
    local key="$1" val="$2" color="${3:-white}"
    local code
    case "$color" in
        red)    code='\033[31m' ;;
        yellow) code='\033[33m' ;;
        green)  code='\033[32m' ;;
        cyan)   code='\033[36m' ;;
        gray)   code='\033[90m' ;;
        *)      code='\033[37m' ;;
    esac
    printf "  ${code}%-20s %s\033[0m\n" "$key" "$val"
}

crit_findings=(); warn_findings=(); info_findings=()
add_finding() {
    local sev="$1" title="$2" detail="$3"
    case "$sev" in
        CRIT) crit_findings+=("CRIT||${title}||${detail}") ;;
        WARN) warn_findings+=("WARN||${title}||${detail}") ;;
        *)    info_findings+=("INFO||${title}||${detail}") ;;
    esac
}

_load_vars() {
    local file="$1"
    [[ -f "$file" ]] || return
    while IFS= read -r line; do
        [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]] || continue
        local key="${line%%=*}"
        local val="${line#*=}"
        printf -v "$key" '%s' "$val"
    done < "$file"
}

# ─────────────────────────────────────────────────────────────
#  COLLECT
# ─────────────────────────────────────────────────────────────

# --deep runs diskutil verifyContainer which checks for filesystem corruption.
# This adds 20-60s on a typical Mac — omit for routine checks, use when
# the user reports data corruption, unexpected crashes, or disk errors in Console.
deep=false
for arg in "$@"; do [[ "$arg" == "--deep" ]] && deep=true; done

script_start=$(date +%s)
running_as_root=true
[[ $EUID -ne 0 ]] && running_as_root=false

host=$(scutil --get ComputerName 2>/dev/null || hostname)
current_user=$(stat -f %Su /dev/console 2>/dev/null || echo "(unknown)")
model=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/{print $2; exit}')
serial=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Serial Number/{print $2; exit}')
os_name=$(sw_vers -productName 2>/dev/null)
os_ver=$(sw_vers -productVersion 2>/dev/null)

boot_epoch=$(sysctl -n kern.boottime 2>/dev/null | awk -F'[={, ]' '{for(i=1;i<=NF;i++) if($i=="sec") print $(i+1)}')
now_epoch=$(date +%s)
uptime_secs=$(( now_epoch - boot_epoch ))
uptime_days=$(( uptime_secs / 86400 ))
uptime_hrs=$(( (uptime_secs % 86400) / 3600 ))
uptime_mins=$(( (uptime_secs % 3600) / 60 ))
if [[ $uptime_days -gt 0 ]]; then uptime_str="${uptime_days}d ${uptime_hrs}h"
else uptime_str="${uptime_hrs}h ${uptime_mins}m"; fi
run_at=$(date '+%Y-%m-%d %H:%M')

# APFS container and volume space
# /System/Volumes/Data is the user data volume on macOS 10.15+ (Catalina+).
# df on an APFS volume reports the shared container's available space, which is
# what actually matters — two volumes sharing one container compete for the same pool.
data_vol="/System/Volumes/Data"
[[ ! -d "$data_vol" ]] && data_vol="/"

read -r disk_total_kb disk_free_kb <<< "$(df -k "$data_vol" 2>/dev/null | awk 'NR==2 {print $2, $4}')"
if [[ -n "$disk_total_kb" && "$disk_total_kb" -gt 0 ]]; then
    disk_pct_free=$(( disk_free_kb * 100 / disk_total_kb ))
    disk_total_gb=$(awk "BEGIN {printf \"%.1f\", $disk_total_kb/1048576}")
    disk_free_gb=$(awk  "BEGIN {printf \"%.1f\", $disk_free_kb/1048576}")
else
    disk_pct_free=0; disk_total_gb="?"; disk_free_gb="?"
fi

# APFS container disk identifier — needed for --deep verifyContainer
container_disk=$(diskutil info "$data_vol" 2>/dev/null | awk '/APFS Container Disk Identifier/{print $NF}')
[[ -z "$container_disk" ]] && container_disk=$(diskutil info / 2>/dev/null | awk '/APFS Container Disk Identifier/{print $NF}')

# Swap usage
swap_raw=$(sysctl vm.swapusage 2>/dev/null)
swap_total_mb=$(echo "$swap_raw" | grep -oE 'total = [0-9.]+' | grep -oE '[0-9.]+')
swap_used_mb=$(echo "$swap_raw"  | grep -oE 'used = [0-9.]+'  | grep -oE '[0-9.]+')
swap_free_mb=$(echo "$swap_raw"  | grep -oE 'free = [0-9.]+'  | grep -oE '[0-9.]+')
if [[ -n "$swap_total_mb" ]]; then
    swap_pct=$(awk "BEGIN {if ($swap_total_mb>0) printf \"%d\", $swap_used_mb*100/$swap_total_mb; else print 0}")
    swap_display="${swap_used_mb} MB used of ${swap_total_mb} MB"
else
    swap_pct=0; swap_display="(unavailable)"
fi

# Chip type — Apple Silicon does not expose full SMART data
chip=$(uname -m)
is_apple_silicon=false
[[ "$chip" == "arm64" ]] && is_apple_silicon=true

# Primary disk identifier for SMART (the container's physical disk)
primary_disk=""
if [[ -n "$container_disk" ]]; then
    primary_disk="/dev/$(echo "$container_disk" | sed 's/s[0-9]*$//')"
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# SMART health and sector counts
(
    smart_available=false; smart_healthy=true
    smart_reallocated=0; smart_pending=0; smart_uncorrectable=0
    smart_status="(unavailable)"

    if $is_apple_silicon; then
        smart_status="Not available (Apple Silicon)"
    elif [[ -n "$primary_disk" ]] && command -v smartctl &>/dev/null; then
        smart_available=true
        overall=$(smartctl -H "$primary_disk" 2>/dev/null | awk '/overall-health|result:/ {print $NF}')
        if [[ "$overall" == "PASSED" || "$overall" == "OK" ]]; then
            smart_status="Healthy"
        elif [[ -n "$overall" ]]; then
            smart_healthy=false
            smart_status="FAILED ($overall)"
        else
            smart_status="(no data returned)"
        fi
        smart_reallocated=$(smartctl -A "$primary_disk" 2>/dev/null | awk '/Reallocated_Sector_Ct/ {print $10+0}')
        smart_pending=$(smartctl -A "$primary_disk"     2>/dev/null | awk '/Current_Pending_Sector/ {print $10+0}')
        smart_uncorrectable=$(smartctl -A "$primary_disk" 2>/dev/null | awk '/Offline_Uncorrectable/ {print $10+0}')
        smart_reallocated=${smart_reallocated:-0}
        smart_pending=${smart_pending:-0}
        smart_uncorrectable=${smart_uncorrectable:-0}
    elif ! command -v smartctl &>/dev/null; then
        smart_status="smartmontools not installed"
    fi

    printf 'smart_available=%s\nsmart_healthy=%s\nsmart_status=%s\n' "$smart_available" "$smart_healthy" "$smart_status"
    printf 'smart_reallocated=%s\nsmart_pending=%s\nsmart_uncorrectable=%s\n' \
        "${smart_reallocated:-0}" "${smart_pending:-0}" "${smart_uncorrectable:-0}"
) > "$tmpdir/smart" 2>/dev/null &

# Time Machine
(
    tm_configured=false; tm_dest="(none)"; tm_backup_date="(never)"
    tm_backup_age_days=-1; tm_backup_display="Never backed up"

    if tmutil destinationinfo &>/dev/null 2>&1; then
        tm_dest=$(tmutil destinationinfo 2>/dev/null | awk -F': ' '/^Name/{print $2; exit}')
        [[ -z "$tm_dest" ]] && tm_dest=$(tmutil destinationinfo 2>/dev/null | awk -F': ' '/^Kind/{print $2; exit}')
        [[ -n "$tm_dest" ]] && tm_configured=true
    fi

    if $tm_configured; then
        last_path=$(tmutil latestbackup 2>/dev/null | tail -1)
        if [[ -n "$last_path" ]]; then
            backup_datestr=$(basename "$last_path" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')
            if [[ -n "$backup_datestr" ]]; then
                backup_epoch=$(date -j -f "%Y-%m-%d" "$backup_datestr" "+%s" 2>/dev/null)
                if [[ -n "$backup_epoch" ]]; then
                    tm_backup_age_days=$(( ($(date +%s) - backup_epoch) / 86400 ))
                    tm_backup_date="$backup_datestr"
                    tm_backup_display="${backup_datestr} (${tm_backup_age_days} days ago)"
                fi
            fi
        fi
    fi

    printf 'tm_configured=%s\ntm_dest=%s\ntm_backup_date=%s\ntm_backup_age_days=%s\ntm_backup_display=%s\n' \
        "$tm_configured" "$tm_dest" "$tm_backup_date" "$tm_backup_age_days" "$tm_backup_display"
) > "$tmpdir/timemachine" 2>/dev/null &

# I/O load snapshot — 3 samples × 1s; skip first row (cumulative since boot)
(
    io_tps="?"; io_mbs="?"
    if command -v iostat &>/dev/null && [[ -n "$container_disk" ]]; then
        iostat_out=$(iostat -d "$container_disk" -c 4 1 2>/dev/null)
        io_tps=$(echo "$iostat_out" | awk 'NR>3 && /^[ ]+[0-9]/ {t+=$2; n++} END {if(n>0) printf "%d", t/n; else print "?"}')
        io_mbs=$(echo "$iostat_out" | awk 'NR>3 && /^[ ]+[0-9]/ {m+=$3; n++} END {if(n>0) printf "%.1f", m/n; else print "?"}')
    fi
    printf 'io_tps=%s\nio_mbs=%s\n' "${io_tps:-?}" "${io_mbs:-?}"
) > "$tmpdir/iostat" 2>/dev/null &

# --deep: APFS container verification
# verifyContainer checks the container's metadata and all volume structures.
# Exit 0 = healthy. Non-zero = errors found that may require Disk Utility First Aid.
# This is the only check that can detect filesystem-level corruption.
if $deep && [[ -n "$container_disk" ]]; then
    (
        verify_out=$(diskutil verifyContainer "$container_disk" 2>&1)
        verify_exit=$?
        if [[ $verify_exit -eq 0 ]]; then
            verify_status="Healthy"
            verify_ok=true
        else
            verify_status="Errors found"
            verify_ok=false
        fi
        last_line=$(echo "$verify_out" | tail -1)
        printf 'verify_ok=%s\nverify_status=%s\nverify_detail=%s\n' "$verify_ok" "$verify_status" "$last_line"
    ) > "$tmpdir/verify" 2>/dev/null &
fi

wait

_load_vars "$tmpdir/smart"
_load_vars "$tmpdir/timemachine"
_load_vars "$tmpdir/iostat"
$deep && _load_vars "$tmpdir/verify"

# Defaults
smart_available="${smart_available:-false}"; smart_healthy="${smart_healthy:-true}"
smart_status="${smart_status:-(unavailable)}"
smart_reallocated="${smart_reallocated:-0}"; smart_pending="${smart_pending:-0}"
smart_uncorrectable="${smart_uncorrectable:-0}"
tm_configured="${tm_configured:-false}"; tm_dest="${tm_dest:-(none)}"
tm_backup_display="${tm_backup_display:-Never backed up}"; tm_backup_age_days="${tm_backup_age_days:--1}"
io_tps="${io_tps:-?}"; io_mbs="${io_mbs:-?}"
verify_ok="${verify_ok:-}"; verify_status="${verify_status:-}"; verify_detail="${verify_detail:-}"

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

# Disk space — compound finding if both swap and space are critical together
# (this combination is the most common cause of severe macOS slowness)
if [[ "$swap_pct" -ge 80 && "$disk_pct_free" -le 10 ]]; then
    add_finding "CRIT" "High swap usage (${swap_pct}%) combined with low disk space (${disk_pct_free}% free)" \
        "This combination is the most common cause of severe macOS slowness — free up disk space first, then restart."
elif [[ "$disk_pct_free" -le 5 ]]; then
    add_finding "CRIT" "Startup disk critically low (${disk_pct_free}% free — ${disk_free_gb} GB of ${disk_total_gb} GB)" \
        "Immediately remove large files or offload data — macOS needs free space for swap and APFS snapshots."
elif [[ "$disk_pct_free" -le 10 ]]; then
    add_finding "WARN" "Startup disk running low (${disk_pct_free}% free — ${disk_free_gb} GB of ${disk_total_gb} GB)" \
        "Clean up Downloads, Trash, and large files — check Storage in System Settings > General > Storage."
elif [[ "$disk_pct_free" -le 15 ]]; then
    add_finding "WARN" "Startup disk below 15% free (${disk_pct_free}% — ${disk_free_gb} GB of ${disk_total_gb} GB)" \
        "Monitor and clean up proactively — macOS performance degrades as free space drops."
fi

# Swap alone (not already covered by compound finding above)
if [[ "$swap_pct" -ge 80 && "$disk_pct_free" -gt 10 ]]; then
    add_finding "WARN" "High swap usage (${swap_pct}% of ${swap_total_mb} MB used)" \
        "Indicates RAM pressure — check Activity Monitor > Memory for top consumers. Consider adding RAM if persistent."
elif [[ "$swap_pct" -ge 50 && "$disk_pct_free" -gt 10 ]]; then
    add_finding "WARN" "Elevated swap usage (${swap_pct}% of ${swap_total_mb} MB used)" \
        "Device is using more swap than usual — monitor Memory Pressure in Activity Monitor."
fi

# SMART — overall failure
if [[ "$smart_available" == "true" && "$smart_healthy" == "false" ]]; then
    add_finding "CRIT" "SMART health check failed on ${primary_disk}" \
        "Back up data immediately and arrange drive replacement — physical disk failure is imminent or in progress."
fi

# SMART — sector-level warnings (can precede a full SMART failure by weeks)
if [[ "$smart_available" == "true" && "$smart_healthy" == "true" ]]; then
    if [[ "$smart_reallocated" -gt 0 || "$smart_pending" -gt 0 || "$smart_uncorrectable" -gt 0 ]]; then
        add_finding "WARN" "SMART sector errors detected — reallocated: ${smart_reallocated}, pending: ${smart_pending}, uncorrectable: ${smart_uncorrectable}" \
            "Drive is compensating for bad sectors — back up data and plan for replacement before a full SMART failure occurs."
    fi
fi

# Time Machine — never backed up
if $tm_configured && [[ "$tm_backup_age_days" -eq -1 ]]; then
    add_finding "WARN" "Time Machine is configured but has no completed backups" \
        "Verify the backup destination is connected and accessible — check System Settings > General > Time Machine."
fi

# Time Machine — backup overdue
if $tm_configured && [[ "$tm_backup_age_days" -ge 30 ]]; then
    add_finding "CRIT" "Time Machine last backup was ${tm_backup_age_days} days ago" \
        "Backup is severely overdue — connect the backup destination and allow Time Machine to complete a full backup."
elif $tm_configured && [[ "$tm_backup_age_days" -ge 7 ]]; then
    add_finding "WARN" "Time Machine last backup was ${tm_backup_age_days} days ago" \
        "Check that the backup destination is connected and Time Machine is running in System Settings."
fi

# Time Machine — not configured
if ! $tm_configured; then
    add_finding "INFO" "Time Machine is not configured on this device" \
        "Consider setting up Time Machine or confirming that another backup solution (e.g. iCloud, Backblaze) is in place."
fi

# --deep: container verification
if $deep; then
    if [[ "$verify_ok" == "false" ]]; then
        add_finding "CRIT" "APFS container verification failed: ${verify_detail}" \
            "Run First Aid on the container in Disk Utility — if it cannot repair, back up and erase/reinstall."
    fi
fi

# ─────────────────────────────────────────────────────────────
#  OUTPUT
# ─────────────────────────────────────────────────────────────

term_width=$(tput cols 2>/dev/null || echo "${COLUMNS:-0}")
if [[ "$term_width" -gt 0 && "$term_width" -lt 90 ]]; then
    printf '  \033[33m[WARN] Terminal is %s cols wide — output may wrap. Recommended: 90+ cols.\033[0m\n' "$term_width"
fi
if ! $running_as_root; then
    printf '  \033[33m[WARN] Not running as root — SMART and swap data may be incomplete. Re-run with sudo.\033[0m\n'
fi

cyan='\033[36m'; reset='\033[0m'; white='\033[37m'
w=64; pad=$(( w - 6 ))
box_row() { printf "${cyan}  │  ${reset}${white}%-${pad}s${reset}${cyan}│${reset}\n" "$1"; }

script_title="DISK HEALTH"
$deep && script_title="DISK HEALTH (DEEP)"
title_fill=$(( w - ${#script_title} - 7 ))
printf "\n${cyan}  ┌─ %s %s┐${reset}\n" "$script_title" "$(printf '─%.0s' $(seq 1 $title_fill))"
box_row "Host    $host"
box_row "User    $current_user"
box_row "Model   $model"
box_row "S/N     $serial"
box_row "OS      $os_name $os_ver"
box_row "Uptime  $uptime_str"
box_row "Run     $run_at"
printf "${cyan}  └%s┘${reset}\n\n" "$(printf '─%.0s' $(seq 1 $(( w - 4 ))))"

# Findings
findings=("${crit_findings[@]}" "${warn_findings[@]}" "${info_findings[@]}")
write_divider "FINDINGS"

if [[ ${#findings[@]} -eq 0 ]]; then
    printf "  \033[32m[OK] No issues found — disk looks healthy.\033[0m\n"
else
    for entry in "${findings[@]}"; do
        sev="${entry%%||*}"
        rest="${entry#*||}"
        title="${rest%%||*}"
        detail="${rest##*||}"
        case "$sev" in
            CRIT) icon="[!!]"; color='\033[31m' ;;
            WARN) icon="[!!]"; color='\033[33m' ;;
            *)    icon="[--]"; color='\033[36m' ;;
        esac
        printf "  ${color}%s %s\033[0m\n       \033[90m%s\033[0m\n" "$icon" "$title" "$detail"
    done
fi

issue_count=$(( ${#crit_findings[@]} + ${#warn_findings[@]} ))
count_label="${issue_count} issue(s) found"
count_fill=$(( 56 - ${#count_label} ))
[[ $count_fill -lt 1 ]] && count_fill=1
if [[ $issue_count -gt 0 ]]; then count_color='\033[33m'; else count_color='\033[32m'; fi
printf "\n${count_color}── %s %s\033[0m\n" "$count_label" "$(printf '─%.0s' $(seq 1 $count_fill))"

# Detail — Disk Space & Swap
printf "\n"
write_divider "DETAIL — DISK SPACE & SWAP"

disk_color="white"
[[ "$disk_pct_free" -le 15 ]] && disk_color="yellow"
[[ "$disk_pct_free" -le 5  ]] && disk_color="red"
write_kv "Container Free" "${disk_pct_free}% (${disk_free_gb} GB of ${disk_total_gb} GB)" "$disk_color"

swap_color="white"
[[ "$swap_pct" -ge 50 ]] && swap_color="yellow"
[[ "$swap_pct" -ge 80 ]] && swap_color="red"
write_kv "Swap Used"    "${swap_pct}% — ${swap_display}" "$swap_color"

[[ -n "$container_disk" ]] && write_kv "Container"   "$container_disk" "gray"

# Detail — Disk Health
printf "\n"
write_divider "DETAIL — DISK HEALTH"

smart_color="white"
[[ "$smart_healthy" == "false" ]] && smart_color="red"
[[ "$smart_available" == "true" && ( "$smart_reallocated" -gt 0 || "$smart_pending" -gt 0 ) ]] && smart_color="yellow"
write_kv "SMART"       "$smart_status" "$smart_color"

if [[ "$smart_available" == "true" ]]; then
    realloc_color="white"; [[ "$smart_reallocated" -gt 0 ]] && realloc_color="yellow"
    pend_color="white";    [[ "$smart_pending"     -gt 0 ]] && pend_color="yellow"
    uncorr_color="white";  [[ "$smart_uncorrectable" -gt 0 ]] && uncorr_color="red"
    write_kv "Reallocated"  "${smart_reallocated} sector(s)" "$realloc_color"
    write_kv "Pending"      "${smart_pending} sector(s)"     "$pend_color"
    write_kv "Uncorrectable" "${smart_uncorrectable} sector(s)" "$uncorr_color"
elif ! $is_apple_silicon && ! command -v smartctl &>/dev/null; then
    printf "  \033[90mInstall smartmontools for sector-level health: brew install smartmontools\033[0m\n"
fi

if [[ "$io_tps" != "?" ]]; then
    write_kv "I/O Load"    "${io_tps} tps  |  ${io_mbs} MB/s (3s snapshot)" "gray"
fi

# Detail — Time Machine
printf "\n"
write_divider "DETAIL — TIME MACHINE"

if $tm_configured; then
    tm_age_color="white"
    [[ "$tm_backup_age_days" -ge 7  ]] && tm_age_color="yellow"
    [[ "$tm_backup_age_days" -ge 30 ]] && tm_age_color="red"
    write_kv "Configured"   "Yes"
    write_kv "Destination"  "$tm_dest" "gray"
    write_kv "Last Backup"  "$tm_backup_display" "$tm_age_color"
else
    write_kv "Configured"   "No" "gray"
fi

# Detail — Container Verify (only shown with --deep)
if $deep; then
    printf "\n"
    write_divider "DETAIL — CONTAINER VERIFY"
    if [[ "$verify_ok" == "true" ]]; then
        write_kv "Result"     "Healthy" "white"
    elif [[ "$verify_ok" == "false" ]]; then
        write_kv "Result"     "Errors found — run First Aid in Disk Utility" "red"
        [[ -n "$verify_detail" ]] && printf "  \033[90m%s\033[0m\n" "$verify_detail"
    elif [[ -z "$container_disk" ]]; then
        write_kv "Result"     "Container disk not detected" "gray"
    else
        write_kv "Result"     "(no output)" "gray"
    fi
fi

printf "\n  \033[90mDone in %ss  |  %s\033[0m\n\n" "$(( $(date +%s) - script_start ))" "$current_user"
