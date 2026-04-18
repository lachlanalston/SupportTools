#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Script:      get-printer-health.sh
# Synopsis:    Checks CUPS daemon state, printer states, and stuck print jobs.
# Description: Collects all print health data silently, reasons across findings,
#              outputs a clean report sized for ticket screenshots.
#              Use --fix to cancel all queued jobs, re-enable stopped printers,
#              and restart the CUPS daemon.
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

# --fix cancels all queued jobs, re-enables stopped printers, and restarts CUPS.
# Requires root — fails fast if not root when --fix is passed.
fix=false
for arg in "$@"; do [[ "$arg" == "--fix" ]] && fix=true; done
if $fix && [[ $EUID -ne 0 ]]; then
    printf '\n\033[31m  [ERROR] --fix requires root. Re-run with: sudo %s --fix\033[0m\n\n' "$0"
    exit 1
fi

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

# Collect printer state — called once initially, re-called after --fix
collect_print_state() {
    cups_running=false
    if launchctl list com.apple.cupsd &>/dev/null 2>&1 || pgrep -x cupsd &>/dev/null; then
        cups_running=true
    fi

    lpstat_p=$(lpstat -p 2>/dev/null)
    printer_count=$(echo "$lpstat_p" | grep -c '^printer ' 2>/dev/null || echo 0)

    stopped_names=$(echo "$lpstat_p" | awk '/^printer / && /stopped/{print $2}' | tr '\n' ' ' | sed 's/ $//')
    stopped_count=$(echo "$lpstat_p" | awk '/^printer / && /stopped/{n++} END{print n+0}')

    queue_raw=$(lpstat -o 2>/dev/null)
    job_count=0
    [[ -n "$queue_raw" ]] && job_count=$(echo "$queue_raw" | grep -c '.' 2>/dev/null || echo 0)

    default_printer=$(lpstat -d 2>/dev/null | awk -F': ' '{gsub(/^[ \t]+/,"",$2); print $2}')
    [[ -z "$default_printer" ]] && default_printer="(none set)"

    share_enabled=false
    cupsctl 2>/dev/null | grep -q "_share_printers=1" && share_enabled=true
}

collect_print_state

# ── Apply fix ──────────────────────────────────────────────
fix_log=()
if $fix; then
    # Cancel all queued jobs across all printers
    if cancel -a 2>/dev/null; then
        fix_log+=("[OK] All queued print jobs cancelled.")
    else
        fix_log+=("[--] No jobs to cancel, or cancel command unavailable.")
    fi

    # Re-enable any stopped printers
    if [[ -n "$stopped_names" ]]; then
        for p in $stopped_names; do
            if cupsenable "$p" 2>/dev/null; then
                fix_log+=("[OK] Re-enabled printer: ${p}")
            else
                fix_log+=("[!!] Failed to re-enable printer: ${p}")
            fi
        done
    fi

    # Restart CUPS daemon
    if launchctl kickstart -k system/com.apple.cupsd &>/dev/null 2>&1; then
        fix_log+=("[OK] CUPS daemon restarted.")
    else
        fix_log+=("[!!] Failed to restart CUPS daemon — check Console for com.apple.cupsd errors.")
    fi

    sleep 1
    collect_print_state
fi

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

# CUPS not running — compound finding if jobs are also stuck
if ! $cups_running && [[ "$job_count" -gt 0 ]]; then
    add_finding "CRIT" "CUPS daemon is not running and ${job_count} job(s) are stuck in the queue" \
        "Run with --fix to restart CUPS and clear the queue, or: sudo launchctl kickstart -k system/com.apple.cupsd"
elif ! $cups_running; then
    add_finding "CRIT" "CUPS daemon is not running — printing is unavailable" \
        "Restart via: sudo launchctl kickstart -k system/com.apple.cupsd"
fi

# Stopped printers with jobs in queue — stuck queue
if [[ "$stopped_count" -gt 0 && "$job_count" -gt 0 ]]; then
    add_finding "WARN" "${job_count} job(s) stuck — ${stopped_count} printer(s) in stopped/error state: ${stopped_names}" \
        "Run with --fix to cancel jobs and re-enable printers, or clear manually via System Settings > Printers & Scanners."
elif [[ "$stopped_count" -gt 0 ]]; then
    add_finding "WARN" "${stopped_count} printer(s) in stopped/error state: ${stopped_names}" \
        "Check the printer connection, then re-enable via: cupsenable <name> — or re-run with --fix."
elif [[ "$job_count" -gt 0 ]] && $cups_running; then
    # Jobs present but all printers are idle — might be actively printing or actually stuck
    add_finding "INFO" "${job_count} job(s) currently in the print queue" \
        "May be actively printing — if jobs are not completing, re-run with --fix to clear the queue."
fi

# No printers configured
if [[ "$printer_count" -eq 0 ]] && $cups_running; then
    add_finding "INFO" "No printers are configured on this device" \
        "Add via System Settings > Printers & Scanners, or push printer config via MDM."
fi

# Print sharing enabled
if $share_enabled; then
    add_finding "INFO" "Printer sharing is enabled — this Mac is sharing printer(s) with the local network" \
        "Confirm this is intentional — disable via System Settings > Printers & Scanners > [printer] > Share on Network."
fi

# ─────────────────────────────────────────────────────────────
#  OUTPUT
# ─────────────────────────────────────────────────────────────

term_width=$(tput cols 2>/dev/null || echo "${COLUMNS:-0}")
if [[ "$term_width" -gt 0 && "$term_width" -lt 90 ]]; then
    printf '  \033[33m[WARN] Terminal is %s cols wide — output may wrap. Recommended: 90+ cols.\033[0m\n' "$term_width"
fi
if ! $running_as_root; then
    printf '  \033[33m[WARN] Not running as root — some printer states may be incomplete. Re-run with sudo.\033[0m\n'
fi

cyan='\033[36m'; reset='\033[0m'; white='\033[37m'
w=64; pad=$(( w - 6 ))
box_row() { printf "${cyan}  │  ${reset}${white}%-${pad}s${reset}${cyan}│${reset}\n" "$1"; }

script_title="PRINT HEALTH"
$fix && script_title="PRINT HEALTH (FIX)"
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

# Fix log (shown before findings so the tech sees what changed)
if $fix && [[ ${#fix_log[@]} -gt 0 ]]; then
    write_divider "FIX ACTIONS"
    for entry in "${fix_log[@]}"; do
        case "$entry" in
            \[OK\]*) printf "  \033[32m%s\033[0m\n" "$entry" ;;
            \[!!\]*) printf "  \033[31m%s\033[0m\n" "$entry" ;;
            *)       printf "  \033[90m%s\033[0m\n" "$entry" ;;
        esac
    done
    printf "\n"
fi

# Findings
findings=("${crit_findings[@]}" "${warn_findings[@]}" "${info_findings[@]}")
write_divider "FINDINGS"

if [[ ${#findings[@]} -eq 0 ]]; then
    if $fix; then
        printf "  \033[32m[OK] CUPS healthy and print queue clear after fix.\033[0m\n"
    else
        printf "  \033[32m[OK] CUPS is running and no stuck jobs detected.\033[0m\n"
    fi
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

# Detail — CUPS
printf "\n"
write_divider "DETAIL — CUPS"

cups_color="white"; ! $cups_running && cups_color="red"
write_kv "CUPS"         "$($cups_running && echo Running || echo Not running)"  "$cups_color"
write_kv "Printers"     "$printer_count configured"
write_kv "Queue"        "${job_count} job(s)" "$([[ $job_count -gt 0 ]] && echo yellow || echo white)"
write_kv "Default"      "$default_printer" "gray"
write_kv "Sharing"      "$($share_enabled && echo Enabled || echo Disabled)" "$($share_enabled && echo yellow || echo gray)"

# Detail — Printers
if [[ "$printer_count" -gt 0 ]]; then
    printf "\n"
    write_divider "DETAIL — PRINTERS"
    while IFS= read -r line; do
        if [[ "$line" =~ ^printer[[:space:]] ]]; then
            p_name=$(echo "$line" | awk '{print $2}')
            if echo "$line" | grep -qi "stopped"; then
                p_state="stopped"; p_color="yellow"
            elif echo "$line" | grep -qi "processing"; then
                p_state="printing"; p_color="white"
            else
                p_state="idle"; p_color="white"
            fi
            p_label="$p_name"
            [[ "$p_name" == "$default_printer" ]] && p_label="${p_name} [default]"
            p_jobs=$(echo "$queue_raw" | grep -c "^${p_name}-" 2>/dev/null || echo 0)
            p_detail="$p_state"
            [[ "$p_jobs" -gt 0 ]] && p_detail="${p_state}, ${p_jobs} job(s)" && p_color="yellow"
            write_kv "$p_label" "$p_detail" "$p_color"
        fi
    done < <(echo "$lpstat_p")
fi

mode_str="Read-only"
$fix && mode_str="Fix mode"
printf "\n  \033[90mDone in %ss  |  %s  |  %s\033[0m\n\n" \
    "$(( $(date +%s) - script_start ))" "$current_user" "$mode_str"
