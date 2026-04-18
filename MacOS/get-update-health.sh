#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Script:      get-update-health.sh
# Synopsis:    Checks pending macOS updates, last install date, and restart state.
# Description: Collects all software update data silently, reasons across findings,
#              outputs a clean report sized for ticket screenshots.
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

# ─────────────────────────────────────────────────────────────
#  COLLECT
# ─────────────────────────────────────────────────────────────
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

# softwareupdate -l is the slow call (10-30s) — run in background
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
( softwareupdate -l 2>/dev/null > "$tmpdir/swlist" ) &
sw_pid=$!

# Update history — fast, run inline while softwareupdate loads
# softwareupdate --history output: Display Name  Version  Date (MM/DD/YYYY, HH:MM:SS AM/PM)
history_out=$(softwareupdate --history 2>/dev/null | tail -30)

last_age_days=-1
last_install_display="(unavailable)"
if [[ -n "$history_out" ]]; then
    last_date_str=$(echo "$history_out" | grep -oE '[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}' | tail -1)
    if [[ -n "$last_date_str" ]]; then
        last_epoch=$(date -j -f "%m/%d/%Y" "$last_date_str" "+%s" 2>/dev/null)
        if [[ -n "$last_epoch" ]]; then
            last_age_days=$(( (now_epoch - last_epoch) / 86400 ))
            last_install_display="${last_date_str} (${last_age_days} days ago)"
        fi
    fi
fi

# Recent update names from history (last 5 entries, skipping header rows)
recent_updates=$(echo "$history_out" | awk 'NR>2 && /[0-9]+\/[0-9]+\/[0-9]+/ {
    # Strip trailing date/version — keep display name (first few fields)
    n=NF; for(i=n;i>=1;i--) { if($i ~ /^[0-9]/) NF=i-1; else break }
    if(NF>0) print $0
}' | tail -5 | sed 's/^[[:space:]]*//')

# Wait for softwareupdate -l
wait "$sw_pid"
sw_list=$(cat "$tmpdir/swlist" 2>/dev/null)

# Parse pending updates
update_count=$(echo "$sw_list" | grep -c '^\*' 2>/dev/null || echo 0)
restart_required=false
echo "$sw_list" | grep -qi '\[restart\]' && restart_required=true

# Build a readable list of pending update names
update_names=""
if [[ "$update_count" -gt 0 ]]; then
    update_names=$(echo "$sw_list" | awk '/^\* /{sub(/^\* /,""); print "  •", $0}')
fi

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

# Restart required — compound finding if uptime is also long
if $restart_required && [[ "$uptime_days" -ge 7 ]]; then
    add_finding "CRIT" "Restart required for pending update(s) — device has not restarted in ${uptime_days} days" \
        "Restart the device to apply updates — schedule with the user during non-critical hours."
elif $restart_required; then
    add_finding "WARN" "Restart required to complete pending update(s)" \
        "Schedule a restart with the user to apply the update(s) — remind them to save open work first."
fi

# Pending updates (without restart — informational but actionable)
if [[ "$update_count" -gt 0 ]] && ! $restart_required; then
    add_finding "WARN" "${update_count} pending macOS update(s)" \
        "Install via System Settings > General > Software Update, or run: sudo softwareupdate -ia"
elif [[ "$update_count" -gt 0 ]] && $restart_required; then
    # Already covered by the restart finding — add INFO with count only
    add_finding "INFO" "${update_count} update(s) waiting to install after restart" \
        "Updates will apply on next restart — no additional action required."
fi

# Last update age
if [[ "$last_age_days" -ge 180 ]]; then
    add_finding "CRIT" "Last software update was ${last_age_days} days ago" \
        "Device is severely out of date — check for update blocks in Intune/Kandji policy and push updates immediately."
elif [[ "$last_age_days" -ge 60 ]]; then
    add_finding "WARN" "Last software update was ${last_age_days} days ago" \
        "Install pending updates via System Settings > General > Software Update or via MDM policy."
fi

# ─────────────────────────────────────────────────────────────
#  OUTPUT
# ─────────────────────────────────────────────────────────────

term_width=$(tput cols 2>/dev/null || echo "${COLUMNS:-0}")
if [[ "$term_width" -gt 0 && "$term_width" -lt 90 ]]; then
    printf '  \033[33m[WARN] Terminal is %s cols wide — output may wrap. Recommended: 90+ cols.\033[0m\n' "$term_width"
fi
if ! $running_as_root; then
    printf '  \033[33m[WARN] Not running as root — softwareupdate may return incomplete results. Re-run with sudo.\033[0m\n'
fi

cyan='\033[36m'; reset='\033[0m'; white='\033[37m'
w=64; pad=$(( w - 6 ))
box_row() { printf "${cyan}  │  ${reset}${reset}${white}%-${pad}s${reset}${cyan}│${reset}\n" "$1"; }

script_title="UPDATE HEALTH"
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
    printf "  \033[32m[OK] No issues found — updates are current.\033[0m\n"
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

# Detail — Pending Updates
printf "\n"
write_divider "DETAIL — PENDING UPDATES"

upd_color="white"; [[ "$update_count" -gt 0 ]] && upd_color="yellow"
write_kv "Pending"      "${update_count} update(s)" "$upd_color"

rst_color="gray"; $restart_required && rst_color="yellow"
write_kv "Restart Req." "$($restart_required && echo Yes || echo No)" "$rst_color"

if [[ -n "$update_names" ]]; then
    printf "\n%s\n" "$update_names" | head -10
fi

# Detail — Update History
printf "\n"
write_divider "DETAIL — UPDATE HISTORY"

age_color="white"
[[ "$last_age_days" -ge 60  ]] && age_color="yellow"
[[ "$last_age_days" -ge 180 ]] && age_color="red"
write_kv "Last Install"  "$last_install_display" "$age_color"

if [[ -n "$recent_updates" ]]; then
    printf "  \033[90mRecent:\033[0m\n"
    echo "$recent_updates" | while IFS= read -r line; do
        [[ -n "$line" ]] && printf "  \033[90m  %s\033[0m\n" "$line"
    done
fi

printf "\n  \033[90mDone in %ss  |  %s\033[0m\n\n" "$(( $(date +%s) - script_start ))" "$current_user"
