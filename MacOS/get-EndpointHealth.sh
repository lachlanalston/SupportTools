#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Script:      get-EndpointHealth.sh
# Synopsis:    Broad endpoint health check — disk, CPU, RAM, updates, AV/EDR, battery.
# Description: Collects all endpoint data in parallel, reasons across findings,
#              outputs a clean report sized for ticket screenshots.
# Author:      Lachlan Alston
# Version:     v3
# Updated:     2026-04-30
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

# Safe key=value loader — only accepts valid variable names
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

# Parallel data collection — all jobs write key=value pairs to temp files
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Disk
(
    read -r size_kb free_kb <<< "$(df -k / 2>/dev/null | awk 'NR==2 {print $2, $4}')"
    if [[ -n "$size_kb" && "$size_kb" -gt 0 ]]; then
        pct_free=$(( free_kb * 100 / size_kb ))
        total_gb=$(awk "BEGIN {printf \"%.1f\", $size_kb/1048576}")
        free_gb=$(awk  "BEGIN {printf \"%.1f\", $free_kb/1048576}")
    else
        pct_free=0; total_gb="?"; free_gb="?"
    fi
    printf 'disk_pct_free=%s\ndisk_free_gb=%s\ndisk_total_gb=%s\n' "$pct_free" "$free_gb" "$total_gb"
) > "$tmpdir/disk" 2>/dev/null &

# CPU — 3 samples × 1s (runs in parallel so total cost is absorbed)
(
    ncpu=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 1)
    total_load=0
    for _ in 1 2 3; do
        sample=$(ps -A -o %cpu 2>/dev/null | awk -v n="$ncpu" '{s+=$1} END {v=int(s/n); print (v>100?100:v)}')
        total_load=$(( total_load + ${sample:-0} ))
        sleep 1
    done
    printf 'cpu_load=%s\n' "$(( total_load / 3 ))"
) > "$tmpdir/cpu" 2>/dev/null &

# RAM
(
    page_size=$(vm_stat 2>/dev/null | awk '/page size/ {print $8}')
    [[ -z "$page_size" || "$page_size" -eq 0 ]] && page_size=4096
    total_kb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))
    free_pages=$(vm_stat 2>/dev/null | awk '/Pages free:/ {gsub(/\./,"",$3); print $3}')
    spec_pages=$(vm_stat 2>/dev/null | awk '/Pages speculative:/ {gsub(/\./,"",$3); print $3}')
    free_pages=${free_pages:-0}; spec_pages=${spec_pages:-0}
    avail_kb=$(( (free_pages + spec_pages) * page_size / 1024 ))
    total_gb=$(awk "BEGIN {printf \"%.1f\", $total_kb/1048576}")
    free_gb=$(awk  "BEGIN {printf \"%.1f\", $avail_kb/1048576}")
    free_pct=$(( total_kb > 0 ? avail_kb * 100 / total_kb : 0 ))
    printf 'ram_total_gb=%s\nram_free_gb=%s\nram_free_pct=%s\n' "$total_gb" "$free_gb" "$free_pct"
) > "$tmpdir/ram" 2>/dev/null &

# Updates (slow — benefit of parallel is highest here)
(
    count=$(softwareupdate -l 2>/dev/null | grep -c '^\*' || echo 0)
    printf 'update_count=%s\n' "${count:-0}"
) > "$tmpdir/updates" 2>/dev/null &

# SMART disk health
(
    smart_available=false; smart_total=0; smart_unhealthy=0; smart_new=0
    smart_unhealthy_names=""
    if command -v smartctl &>/dev/null; then
        smart_available=true
        while IFS= read -r disk; do
            health=$(smartctl -H "$disk" 2>/dev/null | awk '/overall-health|result:/ {print $NF}')
            [[ -z "$health" ]] && continue
            power_on=$(smartctl -A "$disk" 2>/dev/null | awk '/Power_On_Hours/ {print $10}' | head -1)
            smart_total=$(( smart_total + 1 ))
            if [[ -n "$power_on" && "$power_on" -lt 100 ]]; then
                smart_new=$(( smart_new + 1 ))
                continue
            fi
            if [[ "$health" != "PASSED" && "$health" != "OK" ]]; then
                smart_unhealthy=$(( smart_unhealthy + 1 ))
                smart_unhealthy_names="${smart_unhealthy_names}${disk} "
            fi
        done < <(diskutil list 2>/dev/null | awk '/^\/dev\/disk[0-9]+$/ {print $1}')
    fi
    printf 'smart_available=%s\nsmart_total=%s\nsmart_unhealthy=%s\nsmart_new=%s\nsmart_unhealthy_names=%s\n' \
        "$smart_available" "$smart_total" "$smart_unhealthy" "$smart_new" "${smart_unhealthy_names% }"
) > "$tmpdir/smart" 2>/dev/null &

# AV / EDR
(
    av_names=""; av_no_edr=true
    if pgrep -qf "falcond\|falcon-sensor" 2>/dev/null || [[ -d "/Applications/Falcon.app" ]]; then
        av_names="${av_names:+$av_names, }CrowdStrike"; av_no_edr=false
    fi
    if pgrep -qf "SentinelAgent\|sentineld" 2>/dev/null || [[ -d "/Library/Sentinel" ]]; then
        av_names="${av_names:+$av_names, }SentinelOne"; av_no_edr=false
    fi
    if pgrep -qf "SophosScanD\|sophosav" 2>/dev/null || [[ -d "/Library/Sophos Anti-Virus" ]]; then
        av_names="${av_names:+$av_names, }Sophos"; av_no_edr=false
    fi
    if pgrep -qf "cbdaemon\|cbagentd" 2>/dev/null; then
        av_names="${av_names:+$av_names, }Carbon Black"; av_no_edr=false
    fi
    if [[ -d "/Applications/Microsoft Defender.app" ]] || command -v mdatp &>/dev/null; then
        av_names="${av_names:+$av_names, }Microsoft Defender"; av_no_edr=false
    fi
    xprotect=false
    [[ -d "/Library/Apple/System/Library/CoreServices/XProtect.bundle" ]] && xprotect=true
    [[ -z "$av_names" ]] && av_names="None detected"
    printf 'av_names=%s\nav_no_edr=%s\nav_xprotect=%s\n' "$av_names" "$av_no_edr" "$xprotect"
) > "$tmpdir/av" 2>/dev/null &

# Critical system services
(
    svc_ids=(
        "com.apple.mDNSResponder"
        "com.apple.logd"
        "com.apple.ntpd"
        "com.apple.configd"
        "com.apple.securityd"
        "com.apple.opendirectoryd"
    )
    svc_labels=(
        "mDNS Responder"
        "Log Daemon"
        "NTP"
        "Config Daemon"
        "Security Daemon"
        "Directory Services"
    )
    svc_checked=0; svc_stopped=""
    for (( i=0; i<${#svc_ids[@]}; i++ )); do
        svc_checked=$(( svc_checked + 1 ))
        if ! launchctl list "${svc_ids[$i]}" &>/dev/null; then
            svc_stopped="${svc_stopped:+$svc_stopped, }${svc_labels[$i]}"
        fi
    done
    printf 'svc_checked=%s\nsvc_stopped=%s\n' "$svc_checked" "$svc_stopped"
) > "$tmpdir/services" 2>/dev/null &

# Battery
(
    batt_present=false; batt_health_pct=""; batt_cycles=""; batt_charge=""
    batt_info=$(system_profiler SPPowerDataType 2>/dev/null)
    if echo "$batt_info" | grep -q "Battery Information"; then
        batt_present=true
        batt_cycles=$(echo "$batt_info"  | awk '/Cycle Count:/ {print $NF}')
        max_cap=$(echo "$batt_info"      | awk '/Full Charge Capacity/ {print $NF}')
        design_cap=$(echo "$batt_info"   | awk '/Design Capacity:/ {print $NF}')
        if [[ -n "$max_cap" && -n "$design_cap" && "$design_cap" -gt 0 ]]; then
            batt_health_pct=$(( max_cap * 100 / design_cap ))
        fi
        batt_charge=$(pmset -g batt 2>/dev/null | awk -F'[;%]' '/InternalBattery/ {gsub(/ /,"",$2); print $2}')
    fi
    printf 'batt_present=%s\nbatt_health_pct=%s\nbatt_cycles=%s\nbatt_charge=%s\n' \
        "$batt_present" "${batt_health_pct}" "${batt_cycles}" "${batt_charge}"
) > "$tmpdir/battery" 2>/dev/null &

# Temperature — powermetrics requires root; graceful degrade if unavailable or on VMs
(
    cpu_temp=""; gpu_temp=""
    if $running_as_root; then
        pm_out=$(powermetrics -n 1 -i 100 --samplers smc 2>/dev/null)
        cpu_temp=$(echo "$pm_out" | awk '/CPU die temperature:/ {print $4; exit}')
        gpu_temp=$(echo "$pm_out" | awk '/GPU die temperature:/ {print $4; exit}')
    fi
    printf 'temp_cpu=%s\ntemp_gpu=%s\n' "${cpu_temp}" "${gpu_temp}"
) > "$tmpdir/temps" 2>/dev/null &

wait

# Load all results into the current shell
_load_vars "$tmpdir/disk"
_load_vars "$tmpdir/cpu"
_load_vars "$tmpdir/ram"
_load_vars "$tmpdir/updates"
_load_vars "$tmpdir/smart"
_load_vars "$tmpdir/av"
_load_vars "$tmpdir/services"
_load_vars "$tmpdir/battery"
_load_vars "$tmpdir/temps"

# Safe defaults for any blocks that failed silently
disk_pct_free="${disk_pct_free:-0}"; disk_free_gb="${disk_free_gb:-?}"; disk_total_gb="${disk_total_gb:-?}"
cpu_load="${cpu_load:-0}"
ram_free_pct="${ram_free_pct:-0}"; ram_free_gb="${ram_free_gb:-?}"; ram_total_gb="${ram_total_gb:-?}"
update_count="${update_count:-0}"
smart_available="${smart_available:-false}"; smart_total="${smart_total:-0}"
smart_unhealthy="${smart_unhealthy:-0}"; smart_new="${smart_new:-0}"; smart_unhealthy_names="${smart_unhealthy_names:-}"
av_names="${av_names:-None detected}"; av_no_edr="${av_no_edr:-true}"; av_xprotect="${av_xprotect:-false}"
svc_checked="${svc_checked:-0}"; svc_stopped="${svc_stopped:-}"
batt_present="${batt_present:-false}"
temp_cpu="${temp_cpu:-}"; temp_gpu="${temp_gpu:-}"

# Top processes — collected after CPU/RAM results are known, before REASON
top_cpu_procs=""; top_ram_procs=""
if [[ "${cpu_load:-0}" -gt 80 ]]; then
    top_cpu_procs=$(ps -A -o pcpu=,comm= 2>/dev/null | awk '$1 > 0' | sort -rn -k1 | head -5 | \
        awk '{printf "    %-44s %5.1f%%\n", $2, $1}')
fi
if [[ "${ram_free_pct:-100}" -le 20 ]]; then
    top_ram_procs=$(ps -A -o rss=,comm= 2>/dev/null | awk '$1 > 0' | sort -rn -k1 | head -5 | \
        awk '{mb=int($1/1024); printf "    %-44s %5d MB\n", $2, mb}')
fi

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

# Disk
if   [[ "$disk_pct_free" -le 2  ]]; then
    add_finding "CRIT" "Startup disk critically low (${disk_pct_free}% free)" \
        "Immediately remove large files or offload data — only ${disk_free_gb} GB remaining of ${disk_total_gb} GB."
elif [[ "$disk_pct_free" -le 5  ]]; then
    add_finding "WARN" "Startup disk running low (${disk_pct_free}% free)" \
        "Clean up Downloads, Trash, and large files — ${disk_free_gb} GB free of ${disk_total_gb} GB."
elif [[ "$disk_pct_free" -le 10 ]]; then
    add_finding "WARN" "Startup disk below 10% free (${disk_pct_free}%)" \
        "Monitor and clean up proactively — ${disk_free_gb} GB free of ${disk_total_gb} GB."
fi

# CPU
if [[ "$cpu_load" -gt 80 ]]; then
    add_finding "WARN" "CPU under sustained high load (${cpu_load}%)" \
        "Check Activity Monitor for runaway processes — may cause slowness or thermal throttling."
fi

# RAM — skip if system just booted (< 30 min), usage not yet representative
uptime_mins_total=$(( uptime_secs / 60 ))
if [[ "$uptime_mins_total" -ge 30 ]]; then
    if   [[ "$ram_free_pct" -le 10 ]]; then
        add_finding "CRIT" "Critically low available RAM (${ram_free_pct}% free)" \
            "Close unused applications immediately — ${ram_free_gb} GB available of ${ram_total_gb} GB total."
    elif [[ "$ram_free_pct" -le 20 ]]; then
        add_finding "WARN" "Low available RAM (${ram_free_pct}% free)" \
            "Close unused applications — ${ram_free_gb} GB available of ${ram_total_gb} GB total."
    fi
fi

# Uptime
if [[ "$uptime_days" -ge 14 ]]; then
    add_finding "WARN" "Device has not been restarted in ${uptime_days} days" \
        "Restarting clears memory pressure, applies pending updates, and resolves many performance issues."
fi

# Updates
if [[ "$update_count" -gt 0 ]]; then
    add_finding "WARN" "${update_count} pending macOS update(s)" \
        "Install via System Settings > General > Software Update, or run: sudo softwareupdate -ia"
fi

# SMART
if [[ "$smart_available" == "true" && "$smart_unhealthy" -gt 0 ]]; then
    add_finding "CRIT" "SMART health failure on ${smart_unhealthy} disk(s): ${smart_unhealthy_names}" \
        "Back up data immediately and arrange drive replacement — disk failure is imminent or already in progress."
fi

# AV / EDR
if [[ "$av_no_edr" == "true" ]]; then
    add_finding "WARN" "No third-party AV/EDR agent detected" \
        "Verify EDR deployment via Intune or Kandji — XProtect alone does not meet MSP endpoint protection standards."
fi

# Critical services
if [[ -n "$svc_stopped" ]]; then
    add_finding "WARN" "Critical system service(s) not running: ${svc_stopped}" \
        "Restart via: sudo launchctl kickstart -k system/<label> — if it fails to start, escalate for further investigation."
fi

# Temperatures
temp_sev=""; temp_hot_parts=""
for _tsource in cpu gpu; do
    _tval=$(eval echo "\$temp_${_tsource}")
    [[ -z "$_tval" ]] && continue
    _tint=${_tval%.*}
    _tlabel=$(echo "$_tsource" | tr '[:lower:]' '[:upper:]')
    if   [[ "$_tint" -ge 90 ]]; then
        temp_sev="CRIT"; temp_hot_parts="${temp_hot_parts:+$temp_hot_parts, }${_tlabel} ${_tval}°C"
    elif [[ "$_tint" -ge 80 ]]; then
        [[ "$temp_sev" != "CRIT" ]] && temp_sev="WARN"
        temp_hot_parts="${temp_hot_parts:+$temp_hot_parts, }${_tlabel} ${_tval}°C"
    fi
done
if [[ "$temp_sev" == "CRIT" ]]; then
    add_finding "CRIT" "Critical temperature: ${temp_hot_parts}" \
        "Check for blocked vents and heavy load — thermal throttling likely active, performance degraded."
elif [[ "$temp_sev" == "WARN" ]]; then
    add_finding "WARN" "Elevated temperature: ${temp_hot_parts}" \
        "Check for blocked vents or sustained load — continued high temps accelerate hardware wear."
fi

# Battery
if [[ "$batt_present" == "true" && -n "$batt_health_pct" ]]; then
    if   [[ "$batt_health_pct" -le 60 ]]; then
        add_finding "CRIT" "Battery significantly degraded (${batt_health_pct}% capacity)" \
            "Battery replacement recommended — device may shut down unexpectedly under load."
    elif [[ "$batt_health_pct" -le 80 ]]; then
        add_finding "WARN" "Battery wear detected (${batt_health_pct}% capacity)" \
            "Health is below 80% — plan for replacement if user reports short battery life."
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
    printf '  \033[33m[WARN] Not running as root — SMART and service checks may return incomplete data. Re-run with sudo.\033[0m\n'
fi

cyan='\033[36m'; reset='\033[0m'; white='\033[37m'
w=64; pad=$(( w - 6 ))
box_row() { printf "${cyan}  │  ${reset}${white}%-${pad}s${reset}${cyan}│${reset}\n" "$1"; }

script_title="ENDPOINT HEALTH"
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
    printf "  \033[32m[OK] No issues found — endpoint looks healthy.\033[0m\n"
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

# Detail — Storage & Performance
printf "\n"
write_divider "DETAIL — STORAGE & PERFORMANCE"

disk_color="white"
[[ "$disk_pct_free" -le 5  ]] && disk_color="red"
[[ "$disk_pct_free" -gt 5 && "$disk_pct_free" -le 10 ]] && disk_color="yellow"
write_kv "Disk Free"  "${disk_pct_free}% (${disk_free_gb} GB of ${disk_total_gb} GB)" "$disk_color"

ram_color="white"
[[ "$ram_free_pct" -le 20 ]] && ram_color="yellow"
[[ "$ram_free_pct" -le 10 ]] && ram_color="red"
write_kv "RAM Free"   "${ram_free_pct}% (${ram_free_gb} GB of ${ram_total_gb} GB)" "$ram_color"

cpu_color="white"; [[ "$cpu_load" -gt 80 ]] && cpu_color="yellow"
write_kv "CPU Load"   "${cpu_load}% (3-sample avg)" "$cpu_color"

if [[ -n "$temp_cpu" || -n "$temp_gpu" ]]; then
    temp_parts=""
    temp_disp_color="white"
    [[ -n "$temp_cpu" ]] && temp_parts="CPU ${temp_cpu}°C"
    [[ -n "$temp_gpu" ]] && temp_parts="${temp_parts:+$temp_parts | }GPU ${temp_gpu}°C"
    for _t in "$temp_cpu" "$temp_gpu"; do
        [[ -z "$_t" ]] && continue
        _ti=${_t%.*}
        [[ "$_ti" -ge 80 ]] && temp_disp_color="yellow"
        [[ "$_ti" -ge 90 ]] && temp_disp_color="red"
    done
    write_kv "Temperature"  "$temp_parts" "$temp_disp_color"
elif $running_as_root; then
    write_kv "Temperature"  "(unavailable)" "gray"
else
    write_kv "Temperature"  "(requires root)" "gray"
fi

uptime_color="white"; [[ "$uptime_days" -ge 14 ]] && uptime_color="yellow"
write_kv "Uptime"     "$uptime_str" "$uptime_color"

# Detail — Updates & Disk Health
printf "\n"
write_divider "DETAIL — UPDATES & DISK HEALTH"

upd_color="white"; [[ "$update_count" -gt 0 ]] && upd_color="yellow"
write_kv "Pending Updates" "${update_count}" "$upd_color"

if [[ "$smart_available" == "true" ]]; then
    smart_color="white"; smart_str="${smart_total} disk(s) checked"
    [[ "$smart_new" -gt 0 ]] && smart_str="${smart_str} (${smart_new} too new to assess)"
    if [[ "$smart_unhealthy" -gt 0 ]]; then
        smart_color="red"; smart_str="${smart_unhealthy} unhealthy: ${smart_unhealthy_names}"
    fi
    write_kv "SMART"    "$smart_str" "$smart_color"
else
    write_kv "SMART"    "smartmontools not installed" "gray"
    printf "  \033[90mInstall with: brew install smartmontools\033[0m\n"
fi

# Detail — Security
printf "\n"
write_divider "DETAIL — SECURITY"

av_color="white"; [[ "$av_no_edr" == "true" ]] && av_color="yellow"
write_kv "AV / EDR"   "$av_names" "$av_color"

xp_str="Not found"; [[ "$av_xprotect" == "true" ]] && xp_str="Present"
write_kv "XProtect"   "$xp_str" "gray"

if [[ -n "$svc_stopped" ]]; then
    write_kv "Services"   "${svc_checked} checked — stopped: ${svc_stopped}" "yellow"
else
    write_kv "Services"   "${svc_checked} of ${svc_checked} running"
fi

# Detail — Battery (only shown on laptops)
if [[ "$batt_present" == "true" ]]; then
    printf "\n"
    write_divider "DETAIL — BATTERY"

    batt_color="white"
    [[ -n "$batt_health_pct" && "$batt_health_pct" -le 80 ]] && batt_color="yellow"
    [[ -n "$batt_health_pct" && "$batt_health_pct" -le 60 ]] && batt_color="red"
    write_kv "Capacity"   "${batt_health_pct:-(unknown)}%" "$batt_color"
    write_kv "Cycles"     "${batt_cycles:-(unknown)}"  "gray"
    write_kv "Charge"     "${batt_charge:-(unknown)}%" "gray"
fi

if [[ -n "$top_cpu_procs" || -n "$top_ram_procs" ]]; then
    printf "\n"
    write_divider "HIGH RESOURCE PROCESSES"
    if [[ -n "$top_cpu_procs" ]]; then
        printf "  \033[33mCPU — Top processes by usage:\033[0m\n"
        printf "%s\n" "$top_cpu_procs"
        printf "\n"
    fi
    if [[ -n "$top_ram_procs" ]]; then
        printf "  \033[33mRAM — Top processes by working set:\033[0m\n"
        printf "%s\n" "$top_ram_procs"
        printf "\n"
    fi
fi

printf "\n  \033[90mDone in %ss  |  %s\033[0m\n\n" "$(( $(date +%s) - script_start ))" "$current_user"
