#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Script:      get-recent-changes.sh
# Synopsis:    Reports all notable changes on a macOS endpoint in the last 72 hours.
# Description: Collects all change data silently first, then reasons across the
#              findings to surface actionable issues. Outputs a clean header, a
#              FINDINGS block with interpreted results, a DETAIL block with a
#              categorised change timeline, and a plain-text TICKET NOTE ready
#              for copy-paste into a PSA.
#              Designed to fit in one ticket note or terminal screenshot.
# Author:      Lachlan Alston
# Version:     v1
# Updated:     2026-04-21
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
cutoff=$(( script_start - 259200 ))
cutoff_label=$(date -r "$cutoff" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "(unknown)")
run_at=$(date '+%Y-%m-%d %H:%M')

current_user=$(stat -f %Su /dev/console 2>/dev/null || echo "(unknown)")
host=$(scutil --get ComputerName 2>/dev/null || hostname)

hw_info=$(system_profiler SPHardwareDataType 2>/dev/null)
model=$(printf '%s\n' "$hw_info" | awk -F': ' '/Model Name/{print $2; exit}' | xargs 2>/dev/null)
serial=$(printf '%s\n' "$hw_info" | awk -F': ' '/Serial Number \(system\)/{print $2; exit}' | xargs 2>/dev/null)
[[ -z "$model" ]]  && model="(unknown)"
[[ -z "$serial" ]] && serial="(unknown)"

os_name=$(sw_vers -productName 2>/dev/null || echo "macOS")
os_ver=$(sw_vers -productVersion 2>/dev/null || echo "(unknown)")

boot_epoch=$(sysctl -n kern.boottime 2>/dev/null | awk -F'[={, ]' '{for(i=1;i<=NF;i++) if($i=="sec") print $(i+1)}')
now_epoch=$(date +%s)
if [[ -n "$boot_epoch" && "$boot_epoch" -gt 0 ]]; then
    uptime_secs=$(( now_epoch - boot_epoch ))
    uptime_days=$(( uptime_secs / 86400 ))
    uptime_hrs=$(( (uptime_secs % 86400) / 3600 ))
    uptime_mins=$(( (uptime_secs % 3600) / 60 ))
    if [[ $uptime_days -gt 0 ]]; then uptime_str="${uptime_days}d ${uptime_hrs}h"
    else uptime_str="${uptime_hrs}h ${uptime_mins}m"; fi
else
    uptime_str="(unknown)"
fi

# Software changes — InstallHistory.plist covers OS updates + pkg installs/removals
install_items=()
install_skip_reason=""
if ! command -v python3 &>/dev/null; then
    install_skip_reason="python3 not found — install Xcode Command Line Tools to enable this section"
elif [[ ! -f /Library/Receipts/InstallHistory.plist ]]; then
    install_skip_reason="InstallHistory.plist not found — software change history unavailable"
else
    while IFS= read -r line; do
        [[ -n "$line" ]] && install_items+=("$line")
    done < <(python3 <<PYEOF 2>/dev/null
import plistlib
from datetime import datetime

cutoff = $cutoff
try:
    with open('/Library/Receipts/InstallHistory.plist', 'rb') as f:
        data = plistlib.load(f)
    for item in reversed(data):
        dt = item.get('date')
        if dt is None:
            continue
        epoch = dt.timestamp()
        if epoch >= cutoff:
            name    = item.get('displayName', '(unknown)')
            ver     = item.get('displayVersion', '')
            proc    = item.get('processName', '')
            ts      = datetime.fromtimestamp(epoch).strftime('%Y-%m-%d %H:%M')
            tag     = '[update]' if 'softwareupdate' in proc.lower() else '[install]'
            label   = (name + (' ' + ver if ver else '')).strip()
            print(f"{ts}  {label}  {tag}")
except Exception:
    pass
PYEOF
)
fi  # closes the python3/plist check

# Reboots / startups from last
# Anchor on the day-of-week token rather than fixed columns — last -F output column
# positions shift when the hostname field is absent, present, or multi-char.
reboot_lines=()
startup_count=0
while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ (wtmp|begins) ]] && continue
    date_str=$(awk '{
        for (i=1; i<=NF; i++) {
            if ($i ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/ && $(i+4) ~ /^[0-9]{4}$/) {
                print $i, $(i+1), $(i+2), $(i+3), $(i+4); break
            }
        }
    }' <<< "$line")
    [[ -z "$date_str" ]] && continue
    ts_epoch=$(date -j -f "%a %b %d %H:%M:%S %Y" "$date_str" +%s 2>/dev/null || echo 0)
    if [[ $ts_epoch -ge $cutoff && $ts_epoch -gt 0 ]]; then
        ts_fmt=$(date -r "$ts_epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$date_str")
        reboot_lines+=("$ts_fmt  System startup")
        (( startup_count++ ))
    fi
done < <(last -F reboot 2>/dev/null | head -50)

# Unexpected shutdowns — kernel panic files
shutdown_lines=()
unexpected_shutdowns=0
if [[ -d /Library/Logs/DiagnosticReports ]]; then
    while IFS= read -r panic_file; do
        file_epoch=$(stat -f %m "$panic_file" 2>/dev/null || echo 0)
        if [[ "$file_epoch" -ge "$cutoff" ]]; then
            ts_fmt=$(date -r "$file_epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "(unknown)")
            shutdown_lines+=("$ts_fmt  Kernel panic  [!!]")
            (( unexpected_shutdowns++ ))
        fi
    done < <(find /Library/Logs/DiagnosticReports -maxdepth 1 \
        \( -name "*.panic" -o -name "Panic-*" \) 2>/dev/null)
fi

# Application crashes — system and current-user DiagnosticReports
crash_lines=()
crash_app_names=()
for report_dir in \
    "/Library/Logs/DiagnosticReports" \
    "/Users/${current_user}/Library/Logs/DiagnosticReports"; do
    [[ -d "$report_dir" ]] || continue
    while IFS= read -r crash_file; do
        file_epoch=$(stat -f %m "$crash_file" 2>/dev/null || echo 0)
        if [[ "$file_epoch" -ge "$cutoff" ]]; then
            app_name=$(basename "$crash_file" | sed 's/_[0-9-].*//; s/\.crash$//; s/\.ips$//')
            ts_fmt=$(date -r "$file_epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "(unknown)")
            crash_lines+=("$ts_fmt  $app_name")
            crash_app_names+=("$app_name")
        fi
    done < <(find "$report_dir" -maxdepth 1 \
        \( -name "*.crash" -o -name "*.ips" \) 2>/dev/null | grep -iv panic | sort)
done

# New LaunchDaemons/Agents — third-party services added in the window
service_lines=()
for svc_dir in "/Library/LaunchDaemons" "/Library/LaunchAgents"; do
    [[ -d "$svc_dir" ]] || continue
    while IFS= read -r svc_file; do
        file_epoch=$(stat -f %m "$svc_file" 2>/dev/null || echo 0)
        if [[ "$file_epoch" -ge "$cutoff" ]]; then
            ts_fmt=$(date -r "$file_epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "(unknown)")
            service_lines+=("$ts_fmt  $(basename "$svc_file")  ($(basename "$svc_dir"))")
        fi
    done < <(find "$svc_dir" -maxdepth 1 -name "*.plist" 2>/dev/null)
done

# Kernel extension changes
driver_lines=()
for ext_dir in "/Library/Extensions" "/Library/StagedExtensions"; do
    [[ -d "$ext_dir" ]] || continue
    while IFS= read -r kext; do
        file_epoch=$(stat -f %m "$kext" 2>/dev/null || echo 0)
        if [[ "$file_epoch" -ge "$cutoff" ]]; then
            ts_fmt=$(date -r "$file_epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "(unknown)")
            driver_lines+=("$ts_fmt  $(basename "$kext")")
        fi
    done < <(find "$ext_dir" -maxdepth 1 -name "*.kext" 2>/dev/null)
done

# User logons — console and SSH/terminal sessions only
logon_lines=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    user=$(awk '{print $1}' <<< "$line")
    [[ "$user" =~ ^(reboot|shutdown|wtmp)$ || -z "$user" ]] && continue
    [[ "${user:0:1}" == "_" ]] && continue
    [[ "$user" =~ ^(daemon|nobody|sshd|loginwindow)$ ]] && continue
    tty=$(awk '{print $2}' <<< "$line")
    date_str=$(awk '{
        for (i=1; i<=NF; i++) {
            if ($i ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/ && $(i+4) ~ /^[0-9]{4}$/) {
                print $i, $(i+1), $(i+2), $(i+3), $(i+4); break
            }
        }
    }' <<< "$line")
    [[ -z "$date_str" ]] && continue
    ts_epoch=$(date -j -f "%a %b %d %H:%M:%S %Y" "$date_str" +%s 2>/dev/null || echo 0)
    if [[ $ts_epoch -ge $cutoff && $ts_epoch -gt 0 ]]; then
        ts_fmt=$(date -r "$ts_epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$date_str")
        if   [[ "$tty" == "console" ]]; then logon_type="Console"
        elif [[ "$tty" == "ttys"*   ]]; then logon_type="SSH/Terminal"
        else logon_type="Remote"; fi
        logon_lines+=("$ts_fmt  $user  ($logon_type)")
    fi
done < <(last -F 2>/dev/null | head -200)

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

# Kernel panics
if [[ $unexpected_shutdowns -gt 0 ]]; then
    add_finding 'WARN' "Kernel panic detected (${unexpected_shutdowns} in the last 72h)" \
        "Open Console.app > Crash Reports and filter .panic files — look for kext or hardware causes."
fi

# Multiple reboots suggest instability
if [[ $startup_count -ge 3 ]]; then
    add_finding 'WARN' "Machine started up ${startup_count} times in the last 72 hours" \
        "Review Console.app for unexpected restarts — may indicate update loops, panics, or power loss."
fi

# App crashes — group and threshold by app name
if [[ ${#crash_app_names[@]} -gt 0 ]]; then
    while IFS= read -r count_line; do
        count=$(awk '{print $1}' <<< "$count_line")
        app=$(awk '{$1=""; print $0}' <<< "$count_line" | xargs)
        [[ -z "$app" ]] && continue
        if [[ $count -ge 3 ]]; then
            add_finding 'WARN' "$app crashed ${count} time(s) in the last 72h" \
                "Check for pending updates, corrupt preferences, or conflicting plugins. Repair or reinstall."
        else
            add_finding 'INFO' "$app crashed ${count} time(s) in the last 72h" \
                "Monitor — if it recurs, delete prefs in ~/Library/Preferences or check for updates."
        fi
    done < <(printf '%s\n' "${crash_app_names[@]}" | sort | uniq -c | sort -rn)
fi

# New LaunchDaemons/Agents — advisory only
if [[ ${#service_lines[@]} -gt 0 ]]; then
    add_finding 'INFO' "${#service_lines[@]} new LaunchDaemon/Agent(s) added in the last 72h" \
        "Review new entries in /Library/LaunchDaemons and /Library/LaunchAgents for unexpected additions."
fi

# ─────────────────────────────────────────────────────────────
#  OUTPUT
# ─────────────────────────────────────────────────────────────

# Terminal width check
term_width=$(tput cols 2>/dev/null || echo "${COLUMNS:-0}")
if [[ "$term_width" -gt 0 && "$term_width" -lt 90 ]]; then
    printf '  \033[33m[WARN] Terminal is %s cols wide — output may wrap. Recommended: 90+ cols.\033[0m\n' "$term_width"
fi

cyan='\033[36m'; reset='\033[0m'; white='\033[37m'
w=64; pad=$(( w - 6 ))
box_row() { printf "${cyan}  │  ${reset}${white}%-${pad}s${reset}${cyan}│${reset}\n" "$1"; }

script_title="RECENT CHANGES"
title_fill=$(( w - ${#script_title} - 7 ))
printf "\n${cyan}  ┌─ %s %s┐${reset}\n" "$script_title" "$(printf '─%.0s' $(seq 1 $title_fill))"
box_row "Host    $host"
box_row "User    $current_user"
box_row "Model   $model"
box_row "S/N     $serial"
box_row "OS      $os_name $os_ver"
box_row "Uptime  $uptime_str"
box_row "Run     $run_at  (since $cutoff_label)"
printf "${cyan}  └%s┘${reset}\n\n" "$(printf '─%.0s' $(seq 1 $(( w - 4 ))))"

# FINDINGS
findings=("${crit_findings[@]}" "${warn_findings[@]}" "${info_findings[@]}")
write_divider "FINDINGS"

if [[ ${#findings[@]} -eq 0 ]]; then
    printf "  \033[32m[OK] No notable issues in the last 72 hours.\033[0m\n"
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

# DETAIL — categorised change timeline
write_change_section() {
    local sec_title="$1"; shift
    printf '\n  \033[37m%s\033[0m\n' "$sec_title"
    if [[ $# -eq 0 ]]; then
        printf '    \033[90m(none in last 72h)\033[0m\n'
    else
        for item in "$@"; do
            printf '    \033[37m%s\033[0m\n' "$item"
        done
    fi
}

printf "\n"
write_divider "DETAIL"

write_change_section "REBOOTS / STARTUPS"   "${reboot_lines[@]}"
write_change_section "UNEXPECTED SHUTDOWNS" "${shutdown_lines[@]}"
write_change_section "SOFTWARE CHANGES"     "${install_items[@]}"
[[ -n "$install_skip_reason" ]] && printf '    \033[90mNote: %s\033[0m\n' "$install_skip_reason"
write_change_section "DRIVER CHANGES"       "${driver_lines[@]}"
write_change_section "NEW SERVICES"         "${service_lines[@]}"
write_change_section "APPLICATION CRASHES"  "${crash_lines[@]}"
write_change_section "USER LOGONS"          "${logon_lines[@]}"

# TICKET NOTE — plain text, copy-paste ready
printf "\n\n"
write_divider "TICKET NOTE"
printf "\n"

note_section() {
    local sec_title="$1"; shift
    printf '[%s]\n' "$sec_title"
    if [[ $# -eq 0 ]]; then printf '  (none)\n'
    else for item in "$@"; do printf '  %s\n' "$item"; done; fi
    printf '\n'
}

printf '=== RECENT CHANGES — %s ===\n' "$host"
printf 'Period: %s  to  %s\n\n' "$cutoff_label" "$run_at"

note_section "REBOOTS / STARTUPS"   "${reboot_lines[@]}"
note_section "UNEXPECTED SHUTDOWNS" "${shutdown_lines[@]}"
note_section "SOFTWARE CHANGES"     "${install_items[@]}"
[[ -n "$install_skip_reason" ]] && printf '  Note: %s\n\n' "$install_skip_reason"
note_section "DRIVER CHANGES"       "${driver_lines[@]}"
note_section "NEW SERVICES"         "${service_lines[@]}"
note_section "APPLICATION CRASHES"  "${crash_lines[@]}"
note_section "USER LOGONS"          "${logon_lines[@]}"

if [[ $issue_count -gt 0 ]]; then
    printf '[FLAGGED]\n'
    for entry in "${crit_findings[@]}" "${warn_findings[@]}"; do
        rest="${entry#*||}"
        title="${rest%%||*}"
        detail="${rest##*||}"
        printf '  [!!] %s\n' "$title"
        printf '       %s\n' "$detail"
    done
    printf '\n'
fi

# Footer
elapsed=$(( $(date +%s) - script_start ))
printf '\n  \033[90mDone in %ss  |  %s\033[0m\n\n' "$elapsed" "$current_user"
