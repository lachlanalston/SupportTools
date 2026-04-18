#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Script:      get-battery-health.sh
# Synopsis:    Checks battery health, condition, charge state, and adapter info.
# Description: Collects all battery data silently, reasons across findings,
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

# system_profiler SPPowerDataType is the slow call — run in background
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
system_profiler SPPowerDataType 2>/dev/null > "$tmpdir/sppower" &
sp_pid=$!

# ioreg AppleSmartBattery — fast, run inline while system_profiler loads
ioreg_out=$(ioreg -l -n AppleSmartBattery -r 2>/dev/null)

# pmset — fast
pmset_batt=$(pmset -g batt 2>/dev/null)

# Recent power events — last 300 lines covers several days on most devices
pmset_log_tail=$(pmset -g log 2>/dev/null | tail -300)
low_batt_count=$(echo "$pmset_log_tail" | grep -ci "low battery\|battery empty\|sleep reason: Low Battery" 2>/dev/null || echo 0)

# Wait for system_profiler
wait "$sp_pid"
sp_out=$(cat "$tmpdir/sppower" 2>/dev/null)

# ── Battery installed check ────────────────────────────────
battery_installed=$(echo "$ioreg_out" | awk -F' = ' '/"BatteryInstalled"/{gsub(/ /,"",$2); print $2; exit}')
# If ioreg has no BatteryInstalled key at all, check system_profiler
if [[ -z "$battery_installed" ]]; then
    echo "$sp_out" | grep -q "Battery Information" && battery_installed="Yes" || battery_installed="No"
fi

# ── Capacity values ────────────────────────────────────────
design_cap=$(echo "$ioreg_out"  | awk -F' = ' '/"DesignCapacity"/{print $2+0; exit}')
raw_max_cap=$(echo "$ioreg_out" | awk -F' = ' '/"AppleRawMaxCapacity"/{print $2+0; exit}')
max_cap=$(echo "$ioreg_out"     | awk -F' = ' '/"MaxCapacity"/{print $2+0; exit}')
current_cap=$(echo "$ioreg_out" | awk -F' = ' '/"CurrentCapacity"/{print $2+0; exit}')

# AppleRawMaxCapacity is the reliable mAh value on Apple Silicon — prefer it when present
[[ -n "$raw_max_cap" && "$raw_max_cap" -gt 100 ]] && max_cap="$raw_max_cap"

# Calculate health %
health_pct=""
if [[ -n "$design_cap" && "$design_cap" -gt 0 && -n "$max_cap" && "$max_cap" -gt 100 ]]; then
    health_pct=$(( max_cap * 100 / design_cap ))
fi
# Fallback: system_profiler reports Maximum Capacity directly on newer macOS
if [[ -z "$health_pct" ]]; then
    health_pct=$(echo "$sp_out" | awk -F': ' '/Maximum Capacity:/{gsub(/[^0-9]/,"",$2); print $2+0; exit}')
fi
# Clamp to a sane range — anything outside 0-105% is a parsing error
if [[ -n "$health_pct" && ( "$health_pct" -lt 1 || "$health_pct" -gt 105 ) ]]; then
    health_pct=""
fi

# ── Cycle count ────────────────────────────────────────────
cycle_count=$(echo "$ioreg_out" | awk -F' = ' '/"CycleCount"/{print $2+0; exit}')
[[ -z "$cycle_count" ]] && cycle_count=$(echo "$sp_out" | awk -F': ' '/Cycle Count:/{gsub(/[^0-9]/,"",$2); print $2+0; exit}')

# ── Temperature (ioreg reports in centi-Celsius) ───────────
temp_raw=$(echo "$ioreg_out" | awk -F' = ' '/"Temperature"/{print $2+0; exit}')
temp_c=""
if [[ -n "$temp_raw" && "$temp_raw" -gt 0 ]]; then
    temp_c=$(awk "BEGIN {t=$temp_raw/100; if(t>5 && t<80) printf \"%.1f\", t; else print \"\"}")
fi

# ── Condition label ────────────────────────────────────────
# Apple sets this to: Normal | Replace Soon | Replace Now | Service Battery
condition=$(echo "$sp_out" | awk -F': ' '/[[:space:]]Condition:/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
[[ -z "$condition" ]] && condition="(unknown)"

# ── Charge state ───────────────────────────────────────────
is_charging=$(echo "$ioreg_out"     | awk -F' = ' '/"IsCharging"/{gsub(/ /,"",$2); print $2; exit}')
fully_charged=$(echo "$ioreg_out"   | awk -F' = ' '/"FullyCharged"/{gsub(/ /,"",$2); print $2; exit}')
ext_connected=$(echo "$ioreg_out"   | awk -F' = ' '/"ExternalConnected"/{gsub(/ /,"",$2); print $2; exit}')

charge_state="Discharging"
[[ "$is_charging"   == "Yes" ]] && charge_state="Charging"
[[ "$fully_charged" == "Yes" ]] && charge_state="Fully charged"
[[ "$ext_connected" == "Yes" && "$is_charging" != "Yes" && "$fully_charged" != "Yes" ]] && charge_state="Plugged in (not charging)"

# Current charge % — pmset is the most reliable source for the displayed %
charge_pct=$(echo "$pmset_batt" | grep -oE '[0-9]+%' | head -1 | tr -d '%')

# Time remaining
time_remaining="N/A"
if [[ "$charge_state" == "Discharging" ]]; then
    time_remaining=$(echo "$pmset_batt" | grep -oE '[0-9]+:[0-9]+ remaining' | head -1)
    [[ -z "$time_remaining" ]] && time_remaining="(calculating)"
fi

# ── Adapter info ───────────────────────────────────────────
adapter_watts=$(echo "$sp_out" | awk -F': ' '/Wattage \(W\):/{gsub(/[^0-9]/,"",$2); print $2; exit}')
adapter_name=$(echo "$sp_out"  | awk -F': ' '/Adapter Name:/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
[[ -z "$adapter_name" && "$ext_connected" == "Yes" ]] && adapter_name="Connected (name unknown)"
[[ -z "$adapter_name" ]] && adapter_name="Not connected"

# ─────────────────────────────────────────────────────────────
#  REASON
# ─────────────────────────────────────────────────────────────

if [[ "$battery_installed" != "Yes" ]]; then
    # Desktop Mac — no battery checks to run
    :
else
    # Condition label takes priority — Apple's own assessment
    case "$condition" in
        "Service Battery")
            add_finding "CRIT" "Battery condition is Service Battery" \
                "Battery requires immediate service — book a Genius Bar appointment or arrange replacement through your hardware vendor."
            ;;
        "Replace Now")
            add_finding "CRIT" "Battery condition is Replace Now" \
                "Battery is at end of life — arrange replacement immediately. Back up data in case of unexpected shutdowns."
            ;;
        "Replace Soon")
            add_finding "WARN" "Battery condition is Replace Soon" \
                "Battery is degrading — plan for replacement and warn the user about shorter run times and possible unexpected shutdowns."
            ;;
    esac

    # Health % thresholds (independent of condition label — catches edge cases Apple misses)
    if [[ -n "$health_pct" ]]; then
        if [[ "$health_pct" -le 60 && "$condition" == "Normal" ]]; then
            add_finding "CRIT" "Battery capacity critically low (${health_pct}%) despite Normal condition label" \
                "Capacity is well below the Replace Now threshold — raise with Apple or the device vendor as the condition label may not have updated yet."
        elif [[ "$health_pct" -le 79 && "$condition" == "Normal" ]]; then
            add_finding "WARN" "Battery capacity below 80% (${health_pct}%)" \
                "User may notice significantly shorter battery life — plan for replacement if they report run-time complaints."
        fi
    fi

    # Cycle count approaching rated limit (Apple rates most MacBooks at 1000 cycles)
    if [[ -n "$cycle_count" && "$cycle_count" -gt 900 ]]; then
        add_finding "WARN" "Cycle count is ${cycle_count} — approaching Apple's 1000-cycle rated limit" \
            "Capacity degradation will accelerate past 1000 cycles — plan for replacement at the next service opportunity."
    fi

    # High temperature
    if [[ -n "$temp_c" ]]; then
        temp_int=${temp_c%.*}
        if [[ "$temp_int" -ge 40 ]]; then
            add_finding "WARN" "Battery temperature is elevated (${temp_c}°C)" \
                "Sustained high temps degrade battery faster — check for blocked vents, heavy load, or direct sunlight on the device."
        fi
    fi

    # Recent low-battery shutdowns
    if [[ "$low_batt_count" -gt 0 ]]; then
        add_finding "WARN" "${low_batt_count} low-battery event(s) detected in recent power log" \
            "Device has been shutting down due to low battery — may indicate the battery can no longer hold charge reliably."
    fi
fi

# ─────────────────────────────────────────────────────────────
#  OUTPUT
# ─────────────────────────────────────────────────────────────

term_width=$(tput cols 2>/dev/null || echo "${COLUMNS:-0}")
if [[ "$term_width" -gt 0 && "$term_width" -lt 90 ]]; then
    printf '  \033[33m[WARN] Terminal is %s cols wide — output may wrap. Recommended: 90+ cols.\033[0m\n' "$term_width"
fi

cyan='\033[36m'; reset='\033[0m'; white='\033[37m'
w=64; pad=$(( w - 6 ))
box_row() { printf "${cyan}  │  ${reset}${white}%-${pad}s${reset}${cyan}│${reset}\n" "$1"; }

script_title="BATTERY HEALTH"
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

# No battery — short exit
if [[ "$battery_installed" != "Yes" ]]; then
    write_divider "FINDINGS"
    printf "  \033[36m[--] No battery detected — desktop Mac, no battery checks apply.\033[0m\n"
    printf "\n  \033[90mDone in %ss  |  %s\033[0m\n\n" "$(( $(date +%s) - script_start ))" "$current_user"
    exit 0
fi

# Findings
findings=("${crit_findings[@]}" "${warn_findings[@]}" "${info_findings[@]}")
write_divider "FINDINGS"

if [[ ${#findings[@]} -eq 0 ]]; then
    printf "  \033[32m[OK] No issues found — battery looks healthy.\033[0m\n"
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

# Detail — Battery Health
printf "\n"
write_divider "DETAIL — BATTERY HEALTH"

cond_color="white"
[[ "$condition" == "Replace Soon" ]]                              && cond_color="yellow"
[[ "$condition" == "Replace Now" || "$condition" == "Service Battery" ]] && cond_color="red"
write_kv "Condition"    "$condition" "$cond_color"

if [[ -n "$health_pct" ]]; then
    hp_color="white"
    [[ "$health_pct" -le 79 ]] && hp_color="yellow"
    [[ "$health_pct" -le 60 ]] && hp_color="red"
    write_kv "Capacity"    "${health_pct}%" "$hp_color"
    if [[ -n "$max_cap" && "$max_cap" -gt 100 && -n "$design_cap" ]]; then
        write_kv "Max / Design" "${max_cap} mAh / ${design_cap} mAh" "gray"
    fi
else
    write_kv "Capacity"    "(unavailable)" "gray"
fi

if [[ -n "$cycle_count" ]]; then
    cyc_color="gray"
    [[ "$cycle_count" -gt 900 ]] && cyc_color="yellow"
    write_kv "Cycle Count"  "${cycle_count} of ~1000 rated" "$cyc_color"
fi

if [[ -n "$temp_c" ]]; then
    temp_color="gray"
    temp_int=${temp_c%.*}
    [[ "$temp_int" -ge 40 ]] && temp_color="yellow"
    write_kv "Temperature"  "${temp_c}°C" "$temp_color"
fi

# Detail — Charge State
printf "\n"
write_divider "DETAIL — CHARGE STATE"

write_kv "Charge"       "${charge_pct:-(unknown)}%"
write_kv "State"        "$charge_state"
[[ "$charge_state" == "Discharging" ]] && write_kv "Time Remaining" "$time_remaining" "gray"

if [[ "$ext_connected" == "Yes" ]]; then
    adapter_str="$adapter_name"
    [[ -n "$adapter_watts" ]] && adapter_str="${adapter_str} (${adapter_watts}W)"
    write_kv "Adapter"      "$adapter_str"
else
    write_kv "Adapter"      "Not connected" "gray"
fi

if [[ "$low_batt_count" -gt 0 ]]; then
    write_kv "Low Batt Events" "${low_batt_count} in recent log" "yellow"
else
    write_kv "Low Batt Events" "None detected" "gray"
fi

printf "\n  \033[90mDone in %ss  |  %s\033[0m\n\n" "$(( $(date +%s) - script_start ))" "$current_user"
