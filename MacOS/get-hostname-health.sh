#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Script:      get-hostname-health.sh
# Synopsis:    Checks macOS hostname consistency and flags .local suffix drift.
# Description: Collects ComputerName, HostName, and LocalHostName, reasons across
#              mismatches and .local suffix issues, outputs a clean report sized
#              for ticket screenshots. Use --fix to strip .local suffixes.
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

# --fix requires root — fail fast before any output
fix=false
[[ "$1" == "--fix" ]] && fix=true
if $fix && [[ $EUID -ne 0 ]]; then
    printf '\n\033[31m  [ERROR] --fix requires root. Re-run with: sudo %s --fix\033[0m\n\n' "$0"
    exit 1
fi

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

# All three hostname values
computer_name=$(scutil --get ComputerName 2>/dev/null || echo "(not set)")
local_hostname=$(scutil --get LocalHostName 2>/dev/null || echo "(not set)")

host_name_set=true
host_name=$(scutil --get HostName 2>/dev/null)
[[ -z "$host_name" ]] && host_name_set=false
[[ "$host_name_set" == "false" ]] && host_name="(not set)"

bsd_hostname=$(hostname 2>/dev/null || echo "(unknown)")

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

hn_has_local=false; lhn_has_local=false
[[ "$host_name"    == *".local" ]] && hn_has_local=true
[[ "$local_hostname" == *".local" ]] && lhn_has_local=true

# .local suffix on HostName — primary issue (Bluetooth/AirDrop drift)
if $hn_has_local; then
    clean="${host_name%.local}"
    add_finding "WARN" "HostName has a .local suffix (${host_name})" \
        "Caused by Bluetooth or AirDrop activity — breaks DNS lookups. Fix: sudo scutil --set HostName ${clean}  or re-run with --fix"
fi

# .local suffix on LocalHostName (Bonjour name)
if $lhn_has_local; then
    clean="${local_hostname%.local}"
    add_finding "WARN" "LocalHostName (Bonjour) has a .local suffix (${local_hostname})" \
        "Fix: sudo scutil --set LocalHostName ${clean}  or re-run with --fix"
fi

# HostName not explicitly set
if ! $host_name_set; then
    add_finding "INFO" "HostName has not been explicitly set" \
        "macOS falls back to ComputerName for the network hostname — set it with: sudo scutil --set HostName <name>"
fi

# HostName and LocalHostName don't match (only flag if neither has a .local issue)
if $host_name_set && ! $hn_has_local && ! $lhn_has_local; then
    if [[ "$host_name" != "$local_hostname" ]]; then
        add_finding "INFO" "HostName and LocalHostName do not match" \
            "HostName: ${host_name}  |  LocalHostName: ${local_hostname} — align with: sudo scutil --set LocalHostName ${host_name}"
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
    printf '  \033[33m[WARN] Not running as root — scutil changes require sudo. Re-run with sudo for --fix.\033[0m\n'
fi

cyan='\033[36m'; reset='\033[0m'; white='\033[37m'
w=64; pad=$(( w - 6 ))
box_row() { printf "${cyan}  │  ${reset}${white}%-${pad}s${reset}${cyan}│${reset}\n" "$1"; }

script_title="HOSTNAME HEALTH"
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
    printf "  \033[32m[OK] No issues found — hostnames look consistent.\033[0m\n"
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

# Detail
printf "\n"
write_divider "DETAIL — HOSTNAMES"

hn_color="white"; $hn_has_local && hn_color="yellow"
lhn_color="white"; $lhn_has_local && lhn_color="yellow"
hns_color="white"; ! $host_name_set && hns_color="gray"

write_kv "ComputerName"  "$computer_name"
write_kv "HostName"      "$host_name"       "$hns_color"
write_kv "LocalHostName" "$local_hostname"  "$lhn_color"
write_kv "BSD hostname"  "$bsd_hostname"    "gray"
printf "  \033[90mComputerName = Finder display name  |  HostName = network/DNS name  |  LocalHostName = Bonjour name\033[0m\n"

# Fix section
if $fix; then
    printf "\n"
    write_divider "FIX"
    fixed_anything=false

    if $hn_has_local; then
        clean="${host_name%.local}"
        if scutil --set HostName "$clean" 2>/dev/null; then
            printf "  \033[32m[OK] HostName set to: %s\033[0m\n" "$clean"
            fixed_anything=true
        else
            printf "  \033[31m[!!] Failed to set HostName — check permissions.\033[0m\n"
        fi
    fi

    if $lhn_has_local; then
        clean="${local_hostname%.local}"
        if scutil --set LocalHostName "$clean" 2>/dev/null; then
            printf "  \033[32m[OK] LocalHostName set to: %s\033[0m\n" "$clean"
            fixed_anything=true
        else
            printf "  \033[31m[!!] Failed to set LocalHostName — check permissions.\033[0m\n"
        fi
    fi

    if ! $fixed_anything; then
        printf "  \033[90mNothing to fix — no .local suffixes detected.\033[0m\n"
    fi
fi

printf "\n  \033[90mDone in %ss  |  %s\033[0m\n\n" "$(( $(date +%s) - script_start ))" "$current_user"
