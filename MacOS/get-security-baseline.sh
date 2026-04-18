#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Script:      get-security-baseline.sh
# Synopsis:    Checks macOS security baseline — SIP, Gatekeeper, Firewall,
#              FileVault, Secure Boot, XProtect, and remote access state.
# Description: Collects all baseline security data silently, reasons across
#              findings, outputs a clean report sized for ticket screenshots.
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

# SIP
sip_raw=$(csrutil status 2>/dev/null)
sip_enabled=false
echo "$sip_raw" | grep -qi "enabled" && sip_enabled=true

# Gatekeeper
gk_raw=$(spctl --status 2>/dev/null)
gk_enabled=false
echo "$gk_raw" | grep -qi "assessments enabled" && gk_enabled=true

# Firewall
fw_raw=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)
fw_enabled=false
echo "$fw_raw" | grep -qi "enabled" && fw_enabled=true

# FileVault (brief — full check is get-filevault-health.sh)
fv_raw=$(fdesetup status 2>/dev/null)
fv_enabled=false
echo "$fv_raw" | grep -q "FileVault is On" && fv_enabled=true

# Secure Boot — system_profiler SPiBridgeDataType covers T2 and Apple Silicon
# Returns empty on Intel Macs without T2 (pre-2018) — handled as N/A
sp_bridge=$(system_profiler SPiBridgeDataType 2>/dev/null)
secure_boot="(not applicable)"
boot_policy="(not applicable)"
if [[ -n "$sp_bridge" ]]; then
    secure_boot=$(echo "$sp_bridge" | awk -F': ' '/Secure Boot:/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
    boot_policy=$(echo "$sp_bridge" | awk -F': ' '/Boot Policy:/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
    [[ -z "$secure_boot" ]] && secure_boot="(not applicable)"
    [[ -z "$boot_policy" ]] && boot_policy=""
fi

# XProtect version
xprotect_ver=$(defaults read /Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist \
    CFBundleShortVersionString 2>/dev/null || echo "(unavailable)")

# MRT (Malware Removal Tool) version
mrt_ver=$(defaults read /Library/Apple/System/Library/CoreServices/MRT.app/Contents/Info.plist \
    CFBundleShortVersionString 2>/dev/null || echo "(unavailable)")

# Remote Login (SSH)
ssh_status="Off"
if $running_as_root; then
    systemsetup -getremotelogin 2>/dev/null | grep -qi ": on" && ssh_status="On"
else
    launchctl list 2>/dev/null | grep -q "com.openssh.sshd" && ssh_status="On"
fi

# Remote Management / Screen Sharing
screenshare_status="Off"
launchctl list 2>/dev/null | grep -qE "com.apple.screensharing|com.apple.remotedesktop" && screenshare_status="On"

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

# SIP — core OS integrity protection; disabling it is rare and risky
if ! $sip_enabled; then
    add_finding "CRIT" "System Integrity Protection (SIP) is disabled" \
        "Re-enable via Recovery Mode: boot to Recovery, open Terminal, run: csrutil enable — then restart."
fi

# Gatekeeper — prevents unsigned/unnotarised apps from running silently
if ! $gk_enabled; then
    add_finding "CRIT" "Gatekeeper is disabled" \
        "Re-enable via Terminal: sudo spctl --master-enable — or System Settings > Privacy & Security > App Store and identified developers."
fi

# Firewall
if ! $fw_enabled; then
    add_finding "WARN" "macOS Firewall is disabled" \
        "Enable via System Settings > Network > Firewall, or run: sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on"
fi

# FileVault
if ! $fv_enabled; then
    add_finding "WARN" "FileVault is not enabled" \
        "Enable via System Settings > Privacy & Security > FileVault — or run get-filevault-health.sh for a full FileVault diagnostic."
fi

# Secure Boot — flag if T2/Apple Silicon detected but not Full Security
if [[ "$secure_boot" != "(not applicable)" && -n "$secure_boot" ]]; then
    if echo "$secure_boot" | grep -qi "medium\|reduced\|no security\|disabled"; then
        add_finding "WARN" "Secure Boot is not set to Full Security (current: ${secure_boot})" \
            "Change in Startup Security Utility (hold power/Cmd-R at boot) — Full Security prevents booting unauthorised OS versions."
    fi
fi

# Remote Login — SSH on is worth flagging as an advisory on managed endpoints
if [[ "$ssh_status" == "On" ]]; then
    add_finding "INFO" "Remote Login (SSH) is enabled" \
        "Confirm this is intentional — disable via System Settings > General > Sharing > Remote Login if not required."
fi

# Screen Sharing / Remote Management
if [[ "$screenshare_status" == "On" ]]; then
    add_finding "INFO" "Screen Sharing or Remote Management is enabled" \
        "Confirm this is intentional — disable via System Settings > General > Sharing if not required."
fi

# ─────────────────────────────────────────────────────────────
#  OUTPUT
# ─────────────────────────────────────────────────────────────

term_width=$(tput cols 2>/dev/null || echo "${COLUMNS:-0}")
if [[ "$term_width" -gt 0 && "$term_width" -lt 90 ]]; then
    printf '  \033[33m[WARN] Terminal is %s cols wide — output may wrap. Recommended: 90+ cols.\033[0m\n' "$term_width"
fi
if ! $running_as_root; then
    printf '  \033[33m[WARN] Not running as root — SSH state and some checks may be incomplete. Re-run with sudo.\033[0m\n'
fi

cyan='\033[36m'; reset='\033[0m'; white='\033[37m'
w=64; pad=$(( w - 6 ))
box_row() { printf "${cyan}  │  ${reset}${white}%-${pad}s${reset}${cyan}│${reset}\n" "$1"; }

script_title="SECURITY BASELINE"
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
    printf "  \033[32m[OK] No issues found — security baseline looks healthy.\033[0m\n"
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

# Detail — Security Controls
printf "\n"
write_divider "DETAIL — SECURITY CONTROLS"

sip_color="white"; ! $sip_enabled && sip_color="red"
write_kv "SIP"         "$($sip_enabled && echo Enabled || echo Disabled)"  "$sip_color"

gk_color="white"; ! $gk_enabled && gk_color="red"
write_kv "Gatekeeper"  "$($gk_enabled && echo Enabled || echo Disabled)"   "$gk_color"

fw_color="white"; ! $fw_enabled && fw_color="yellow"
write_kv "Firewall"    "$($fw_enabled && echo Enabled || echo Disabled)"   "$fw_color"

fv_color="white"; ! $fv_enabled && fv_color="yellow"
write_kv "FileVault"   "$($fv_enabled && echo Enabled || echo Disabled)"   "$fv_color"

# Detail — Secure Boot
printf "\n"
write_divider "DETAIL — SECURE BOOT"

if [[ "$secure_boot" == "(not applicable)" ]]; then
    write_kv "Secure Boot"  "N/A — Intel Mac without T2 chip" "gray"
else
    sb_color="white"
    echo "$secure_boot" | grep -qi "medium\|reduced\|no security\|disabled" && sb_color="yellow"
    write_kv "Secure Boot"  "$secure_boot" "$sb_color"
    [[ -n "$boot_policy" ]] && write_kv "Boot Policy"  "$boot_policy" "gray"
fi

# Detail — Threat Protection
printf "\n"
write_divider "DETAIL — THREAT PROTECTION"
write_kv "XProtect"    "$xprotect_ver" "gray"
write_kv "MRT"         "$mrt_ver"      "gray"

# Detail — Remote Access
printf "\n"
write_divider "DETAIL — REMOTE ACCESS"

ssh_color="gray"; [[ "$ssh_status" == "On" ]] && ssh_color="yellow"
write_kv "Remote Login" "$ssh_status (SSH)" "$ssh_color"

ss_color="gray"; [[ "$screenshare_status" == "On" ]] && ss_color="yellow"
write_kv "Screen Sharing" "$screenshare_status" "$ss_color"

printf "\n  \033[90mDone in %ss  |  %s\033[0m\n\n" "$(( $(date +%s) - script_start ))" "$current_user"
