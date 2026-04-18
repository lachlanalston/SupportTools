#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Script:      get-mdm-health.sh
# Synopsis:    Checks MDM enrolment health across Intune, Kandji, and Jamf.
# Description: Collects all MDM enrolment and agent data silently, reasons
#              across findings, outputs a clean report sized for ticket screenshots.
# Author:      Lachlan Alston
# Version:     v1
# Updated:     2026-04-17
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

# MDM enrolment status
profiles_status=$(profiles status -type enrollment 2>/dev/null)
[[ -z "$profiles_status" ]] && profiles_status=$(profiles status 2>/dev/null)

mdm_enrolled=false
mdm_supervised=false
enrollment_type="Not enrolled"

if echo "$profiles_status" | grep -qi "MDM enrollment: Yes\|MDM enrollment:Yes"; then
    mdm_enrolled=true
fi
if echo "$profiles_status" | grep -qi "Supervised.*Yes\|supervised: yes"; then
    mdm_supervised=true
fi
if $mdm_enrolled; then
    if echo "$profiles_status" | grep -qi "DEP.*Yes\|Enrolled via DEP.*Yes\|Automated Device Enrollment"; then
        enrollment_type="Automated (DEP)"
    else
        enrollment_type="User Approved"
    fi
fi

# MDM provider detection — profile URL first, then agent/binary fallback
mdm_provider="Unknown"
mdm_url="(unknown)"

profiles_verbose=$(profiles show -type enrollment 2>/dev/null)
[[ -z "$profiles_verbose" ]] && profiles_verbose=$(profiles -P -v 2>/dev/null)

if echo "$profiles_verbose" | grep -qi "manage\.microsoft\.com\|microsoftintune"; then
    mdm_provider="Intune"
    mdm_url=$(echo "$profiles_verbose" | grep -ioE 'https://[^[:space:];]+manage\.microsoft\.com[^[:space:];]*' | head -1)
    [[ -z "$mdm_url" ]] && mdm_url="manage.microsoft.com"
elif echo "$profiles_verbose" | grep -qi "kandji\.io"; then
    mdm_provider="Kandji"
    mdm_url=$(echo "$profiles_verbose" | grep -ioE 'https://[^[:space:];]+kandji\.io[^[:space:];]*' | head -1)
    [[ -z "$mdm_url" ]] && mdm_url="kandji.io"
elif echo "$profiles_verbose" | grep -qi "jamf"; then
    mdm_provider="Jamf"
    mdm_url=$(echo "$profiles_verbose" | grep -ioE 'https://[^[:space:];]+' | grep -i jamf | head -1)
    [[ -z "$mdm_url" ]] && mdm_url="(jamf detected)"
fi

# Fallback via agent/binary presence
if [[ "$mdm_provider" == "Unknown" ]]; then
    if pgrep -qf "IntuneMdmDaemon" 2>/dev/null || [[ -d "/Applications/Company Portal.app" ]] || [[ -d "/Library/Intune" ]]; then
        mdm_provider="Intune"; mdm_url="(detected via agent)"
    elif pgrep -qf "[Kk]andji" 2>/dev/null || [[ -d "/Library/Kandji" ]]; then
        mdm_provider="Kandji"; mdm_url="(detected via agent)"
    elif [[ -f "/usr/local/jamf/bin/jamf" ]] || pgrep -qf "^jamf$" 2>/dev/null; then
        mdm_provider="Jamf"; mdm_url="(detected via binary)"
    fi
fi

# Bootstrap token
bootstrap_supported=false
bootstrap_escrowed=false
bt_status=$(profiles status -type bootstraptoken 2>/dev/null)
echo "$bt_status" | grep -qi "supported.*YES\|Bootstrap Token supported.*: YES" && bootstrap_supported=true
echo "$bt_status" | grep -qi "escrowed.*YES\|escrowed to MDM.*: YES"            && bootstrap_escrowed=true

# Chip type — bootstrap token only relevant for Apple Silicon / T2
chip=$(uname -m)
is_apple_silicon=false
[[ "$chip" == "arm64" ]] && is_apple_silicon=true

# Intune-specific
company_portal_installed=false
intune_daemon_running=false
if [[ "$mdm_provider" == "Intune" ]]; then
    [[ -d "/Applications/Company Portal.app" ]] && company_portal_installed=true
    pgrep -qf "IntuneMdmDaemon" 2>/dev/null      && intune_daemon_running=true
fi

# Kandji-specific
kandji_agent_running=false
if [[ "$mdm_provider" == "Kandji" ]]; then
    pgrep -qf "[Kk]andji" 2>/dev/null || [[ -S "/var/run/kandji_daemon.sock" ]] && kandji_agent_running=true
fi

# Jamf presence (secondary — flagged as INFO since being phased out)
jamf_present=false
[[ -f "/usr/local/jamf/bin/jamf" ]] && jamf_present=true

# Profile count
profile_count=$(profiles list 2>/dev/null | grep -c "attribute: description" 2>/dev/null || echo "(unknown)")

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

# Not enrolled
if ! $mdm_enrolled; then
    add_finding "WARN" "Device is not enrolled in MDM" \
        "Enrol via Company Portal (Intune), Kandji Self Service, or check with your MDM admin for an enrolment link."
fi

# Not supervised
if $mdm_enrolled && ! $mdm_supervised; then
    add_finding "WARN" "Device is not supervised" \
        "Supervision is required for silent app installs and many MDM-managed features — device must be enrolled via DEP/ADE to be supervised."
fi

# User-approved only (not DEP)
if $mdm_enrolled && [[ "$enrollment_type" == "User Approved" ]]; then
    add_finding "INFO" "Enrolment is user-approved — not Automated Device Enrolment (DEP)" \
        "User-approved enrolment has limitations vs DEP — consider wiping and re-enrolling via ADE if supervision is required."
fi

# Bootstrap token not escrowed (Apple Silicon + enrolled)
if $mdm_enrolled && $is_apple_silicon && $bootstrap_supported && ! $bootstrap_escrowed; then
    add_finding "WARN" "Bootstrap token is not escrowed to MDM" \
        "Required for MDM to push silent OS updates on Apple Silicon — trigger escrow by re-enrolling or running: profiles install -type bootstraptoken"
fi

# Intune — Company Portal not installed
if [[ "$mdm_provider" == "Intune" ]] && ! $company_portal_installed; then
    add_finding "WARN" "Company Portal is not installed" \
        "Required for Intune compliance and app delivery — install from the Mac App Store or push via Intune."
fi

# Intune — daemon not running
if [[ "$mdm_provider" == "Intune" ]] && $company_portal_installed && ! $intune_daemon_running; then
    add_finding "WARN" "Intune MDM daemon is not running" \
        "Open Company Portal and sign in — if issue persists, reinstall Company Portal or check Console logs for com.microsoft.intune errors."
fi

# Kandji — agent not running
if [[ "$mdm_provider" == "Kandji" ]] && ! $kandji_agent_running; then
    add_finding "WARN" "Kandji agent is not running" \
        "Restart the agent via: sudo launchctl kickstart -k system/io.kandji.KandjiAgent — if it fails, reinstall from the Kandji dashboard."
fi

# Jamf still present
if $jamf_present; then
    add_finding "INFO" "Jamf binary is still present on this device" \
        "Jamf is being phased out — confirm unenrolment and remove binary if migration to Intune/Kandji is complete."
fi

# ─────────────────────────────────────────────────────────────
#  OUTPUT
# ─────────────────────────────────────────────────────────────

term_width=$(tput cols 2>/dev/null || echo "${COLUMNS:-0}")
if [[ "$term_width" -gt 0 && "$term_width" -lt 90 ]]; then
    printf '  \033[33m[WARN] Terminal is %s cols wide — output may wrap. Recommended: 90+ cols.\033[0m\n' "$term_width"
fi
if ! $running_as_root; then
    printf '  \033[33m[WARN] Not running as root — profiles and agent checks may return incomplete data. Re-run with sudo.\033[0m\n'
fi

cyan='\033[36m'; reset='\033[0m'; white='\033[37m'
w=64; pad=$(( w - 6 ))
box_row() { printf "${cyan}  │  ${reset}${white}%-${pad}s${reset}${cyan}│${reset}\n" "$1"; }

script_title="MDM HEALTH"
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
    printf "  \033[32m[OK] No issues found — MDM enrolment looks healthy.\033[0m\n"
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

# Detail — Enrolment
printf "\n"
write_divider "DETAIL — ENROLMENT"
write_kv "Enrolled"    "$($mdm_enrolled && echo Yes || echo No)"   "$($mdm_enrolled && echo white || echo yellow)"
write_kv "Provider"    "$mdm_provider"
write_kv "MDM URL"     "$mdm_url"                                  "gray"
write_kv "Supervised"  "$($mdm_supervised && echo Yes || echo No)" "$($mdm_supervised && echo white || echo yellow)"
write_kv "Enrol Type"  "$enrollment_type"                          "$([[ "$enrollment_type" == "User Approved" ]] && echo yellow || echo white)"
write_kv "Profiles"    "$profile_count installed"                  "gray"

# Detail — Bootstrap Token
printf "\n"
write_divider "DETAIL — BOOTSTRAP TOKEN"
chip_str="$chip"; $is_apple_silicon && chip_str="Apple Silicon (arm64)"
write_kv "Chip"        "$chip_str"
write_kv "Supported"   "$($bootstrap_supported && echo Yes || echo No/Unknown)"
bt_color="white"
$bootstrap_supported && ! $bootstrap_escrowed && bt_color="yellow"
write_kv "Escrowed"    "$($bootstrap_escrowed && echo Yes || echo No)" "$bt_color"

# Detail — Provider Agent
if [[ "$mdm_provider" == "Intune" ]]; then
    printf "\n"
    write_divider "DETAIL — INTUNE"
    write_kv "Company Portal" "$($company_portal_installed && echo Installed || echo Missing)"  "$($company_portal_installed && echo white || echo yellow)"
    write_kv "MDM Daemon"     "$($intune_daemon_running && echo Running || echo Not running)"   "$($intune_daemon_running && echo white || echo yellow)"
fi

if [[ "$mdm_provider" == "Kandji" ]]; then
    printf "\n"
    write_divider "DETAIL — KANDJI"
    write_kv "Agent"          "$([[ -d /Library/Kandji ]] && echo Installed || echo Missing)"   "$([[ -d /Library/Kandji ]] && echo white || echo yellow)"
    write_kv "Agent Running"  "$($kandji_agent_running && echo Yes || echo No)"                 "$($kandji_agent_running && echo white || echo yellow)"
fi

if $jamf_present; then
    printf "\n"
    write_divider "DETAIL — JAMF (PHASE-OUT)"
    write_kv "Binary"         "/usr/local/jamf/bin/jamf" "yellow"
    printf "  \033[90mJamf is being phased out — confirm unenrolment before removing.\033[0m\n"
fi

printf "\n  \033[90mDone in %ss  |  %s\033[0m\n\n" "$(( $(date +%s) - script_start ))" "$current_user"
