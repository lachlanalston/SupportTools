#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Script:      get-filevault-health.sh
# Synopsis:    Checks FileVault encryption status and recovery key health.
# Description: Collects all FileVault data silently, reasons across findings,
#              outputs a clean report sized for ticket screenshots.
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

# FileVault status
fv_status_raw=$(fdesetup status 2>/dev/null)
fv_enabled=false
fv_deferred=false
fv_in_progress=false
fv_pct="?"
fv_status_display="Unknown"

if echo "$fv_status_raw" | grep -q "FileVault is On"; then
    fv_enabled=true
    fv_status_display="Enabled"
    if echo "$fv_status_raw" | grep -q "in progress"; then
        fv_in_progress=true
        fv_pct=$(echo "$fv_status_raw" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
        fv_status_display="Encrypting (${fv_pct}%)"
    fi
elif echo "$fv_status_raw" | grep -qi "deferred"; then
    fv_deferred=true
    fv_status_display="Deferred"
elif echo "$fv_status_raw" | grep -q "FileVault is Off"; then
    fv_status_display="Disabled"
fi

# Recovery key type
fv_has_personal=$(fdesetup haspersonalrecoverykey 2>/dev/null | tr '[:upper:]' '[:lower:]')
fv_has_institutional=$(fdesetup hasinstitutionalrecoverykey 2>/dev/null | tr '[:upper:]' '[:lower:]')

fv_key_type="None"
if [[ "$fv_has_personal" == "true" && "$fv_has_institutional" == "true" ]]; then
    fv_key_type="Personal + Institutional"
elif [[ "$fv_has_personal" == "true" ]]; then
    fv_key_type="Personal"
elif [[ "$fv_has_institutional" == "true" ]]; then
    fv_key_type="Institutional"
fi

# FileVault-enabled users
fv_users="(none)"
if [[ "$fv_enabled" == "true" ]]; then
    users_raw=$(fdesetup list 2>/dev/null | awk -F',' '{print $1}' | tr '\n' ', ')
    fv_users="${users_raw%, }"
    [[ -z "$fv_users" ]] && fv_users="(unknown)"
fi

# Secure Token for logged-in user
fv_secure_token="(unknown)"
if [[ "$current_user" != "(unknown)" ]]; then
    st_out=$(sysadminctl -secureTokenStatus "$current_user" 2>&1)
    if echo "$st_out" | grep -q "ENABLED";  then fv_secure_token="Enabled"
    elif echo "$st_out" | grep -q "DISABLED"; then fv_secure_token="Disabled"
    fi
fi

# MDM escrow profile
fv_escrow_configured=false
if system_profiler SPConfigurationProfileDataType 2>/dev/null | grep -qi "FDERecoveryKeyEscrow"; then
    fv_escrow_configured=true
fi

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

# FileVault not enabled
if [[ "$fv_enabled" == "false" && "$fv_deferred" == "false" ]]; then
    add_finding "CRIT" "FileVault is not enabled" \
        "Enable via System Settings > Privacy & Security > FileVault, or push MDM policy to enforce encryption."
fi

# FileVault deferred
if [[ "$fv_deferred" == "true" ]]; then
    add_finding "WARN" "FileVault is deferred — waiting for user login to activate" \
        "Ask the user to log out and back in to trigger FileVault activation, or re-push the MDM FileVault policy."
fi

# Encryption in progress
if [[ "$fv_in_progress" == "true" ]]; then
    add_finding "WARN" "FileVault encryption is in progress (${fv_pct}%)" \
        "Keep the device powered on to complete — monitor progress with: fdesetup status"
fi

# No recovery key
if [[ "$fv_enabled" == "true" && "$fv_key_type" == "None" ]]; then
    add_finding "CRIT" "No FileVault recovery key exists (personal or institutional)" \
        "No recovery path if password is lost — re-enable FileVault to generate a new key and ensure MDM escrow is configured."
fi

# Secure Token missing for logged-in user
if [[ "$fv_secure_token" == "Disabled" ]]; then
    add_finding "WARN" "Logged-in user ($current_user) does not have a Secure Token" \
        "Required for FileVault unlock — grant via: sudo sysadminctl -secureTokenOn $current_user -password [admin-password]"
fi

# MDM escrow profile not installed
if [[ "$fv_enabled" == "true" && "$fv_escrow_configured" == "false" ]]; then
    add_finding "WARN" "MDM FileVault key escrow profile is not installed" \
        "Recovery key may not be backed up to Intune/Kandji — check MDM policy and re-push the FileVault configuration profile."
fi

# ─────────────────────────────────────────────────────────────
#  OUTPUT
# ─────────────────────────────────────────────────────────────

term_width=$(tput cols 2>/dev/null || echo "${COLUMNS:-0}")
if [[ "$term_width" -gt 0 && "$term_width" -lt 90 ]]; then
    printf '  \033[33m[WARN] Terminal is %s cols wide — output may wrap. Recommended: 90+ cols.\033[0m\n' "$term_width"
fi
if ! $running_as_root; then
    printf '  \033[33m[WARN] Not running as root — fdesetup and sysadminctl may return incomplete data. Re-run with sudo.\033[0m\n'
fi

cyan='\033[36m'; reset='\033[0m'; white='\033[37m'
w=64; pad=$(( w - 6 ))
box_row() { printf "${cyan}  │  ${reset}${white}%-${pad}s${reset}${cyan}│${reset}\n" "$1"; }

script_title="FILEVAULT HEALTH"
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
    printf "  \033[32m[OK] No issues found — FileVault looks healthy.\033[0m\n"
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
write_divider "DETAIL — FILEVAULT"

fv_color="white"
[[ "$fv_status_display" == "Disabled" ]] && fv_color="red"
[[ "$fv_deferred" == "true" ]]           && fv_color="yellow"
write_kv "Status"      "$fv_status_display" "$fv_color"
write_kv "Recovery Key" "$fv_key_type" "$([[ "$fv_key_type" == "None" ]] && echo red || echo white)"

escrow_color="yellow"; escrow_str="Not configured"
$fv_escrow_configured && { escrow_str="Configured"; escrow_color="white"; }
write_kv "MDM Escrow"   "$escrow_str" "$escrow_color"

st_color="white"
[[ "$fv_secure_token" == "Disabled" ]] && st_color="yellow"
write_kv "Secure Token" "$fv_secure_token" "$st_color"
write_kv "FV Users"     "$fv_users" "gray"

printf "\n  \033[90mDone in %ss  |  %s\033[0m\n\n" "$(( $(date +%s) - script_start ))" "$current_user"
