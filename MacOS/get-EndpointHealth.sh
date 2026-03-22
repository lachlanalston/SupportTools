#!/usr/bin/env bash
# get-endpoint-health.sh
# MSP diagnostic tool — paste into a terminal during a remote session.
# Requires: bash 4+, coreutils, smartmontools (optional), upower (optional)

# --- Elevation ---
if [[ $EUID -ne 0 ]]; then
    echo ""
    echo "  ERROR: This script must be run as root." >&2
    echo "  Re-run with: sudo $0" >&2
    echo ""
    exit 1
fi

# --- Layout ---
COL_CHECK=22
COL_STATUS=10
COL_VALUE=26
COL_MSG=44
WIDTH=$(( COL_CHECK + COL_STATUS + COL_VALUE + COL_MSG + 5 ))

# --- Colors (ANSI) ---
C_RESET="\e[0m"
C_WHITE="\e[97m"
C_CYAN="\e[96m"
C_GREEN="\e[92m"
C_YELLOW="\e[93m"
C_RED="\e[91m"
C_MAGENTA="\e[95m"
C_GRAY="\e[37m"
C_DARK_GRAY="\e[90m"

# --- Detect OS family ---
OS_TYPE="linux"
[[ "$(uname -s)" == "Darwin" ]] && OS_TYPE="macos"

# --- Helpers ---
write_divider() {
    local color="${1:-$C_DARK_GRAY}"
    printf "${color}%${WIDTH}s${C_RESET}\n" | tr ' ' '-'
}

# Truncate or pad a string to exactly N chars
pad() { printf "%-${2}s" "${1:0:$2}"; }

write_row() {
    local check="$1" status="$2" value="$3" message="$4" color="$5"
    local c s v m
    c=$(pad "$check"   $COL_CHECK)
    s=$(pad "$status"  $COL_STATUS)
    v=$(pad "$value"   $COL_VALUE)
    # Truncate message
    if (( ${#message} > COL_MSG )); then
        m="${message:0:$(( COL_MSG - 3 ))}..."
    else
        m="$message"
    fi
    printf "${color}  %s %s %s %s${C_RESET}\n" "$c" "$s" "$v" "$m"
}

write_info_row() {
    local l_label="$1" l_value="$2" r_label="${3:-}" r_value="${4:-}"
    local lbl lval left right
    lbl=$(pad "$l_label" 9)
    # Truncate lval to 34
    if (( ${#l_value} > 34 )); then lval="${l_value:0:31}..."; else lval=$(printf "%-34s" "$l_value"); fi
    left="  ${lbl} : ${lval}"
    if [[ -n "$r_label" ]]; then
        local rlbl
        rlbl=$(pad "$r_label" 9)
        right="${rlbl} : ${r_value}"
    else
        right=""
    fi
    printf "${C_GRAY}%s%s${C_RESET}\n" "$left" "$right"
}

# Result helpers — write STATUS|VALUE|COLOR|MESSAGE to a temp file
# Usage: result_file STATUS VALUE COLOR "Message"
write_result() {
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
}

# --- Checks ---

check_uptime() {
    local boot_epoch now elapsed_s days hours mins display
    if [[ "$OS_TYPE" == "macos" ]]; then
        boot_epoch=$(sysctl -n kern.boottime | awk -F'[ ,]' '{print $4}')
    else
        boot_epoch=$(date -d "$(uptime -s 2>/dev/null)" +%s 2>/dev/null || \
                     awk '{print int(systime() - $1)}' /proc/uptime | xargs -I{} date -d "@{}" +%s 2>/dev/null)
        # Fallback: parse /proc/uptime directly
        if [[ -z "$boot_epoch" ]]; then
            local uptime_s
            uptime_s=$(awk '{print int($1)}' /proc/uptime)
            boot_epoch=$(( $(date +%s) - uptime_s ))
        fi
    fi
    now=$(date +%s)
    elapsed_s=$(( now - boot_epoch ))
    days=$(( elapsed_s / 86400 ))
    hours=$(( (elapsed_s % 86400) / 3600 ))
    mins=$(( (elapsed_s % 3600) / 60 ))
    display="${days} days, ${hours} hrs, ${mins} min"

    if (( elapsed_s >= 172800 )); then  # 48 hours
        write_result "Warning" "$display" "Yellow" "Restart overdue — running for ${days} day(s)"
    else
        write_result "Healthy" "$display" "Green"  "Last restart within the past 48 hours"
    fi
}

check_disk() {
    local mount="/"
    local pct_used pct_free size_kb free_kb total_gb free_gb display
    if [[ "$OS_TYPE" == "macos" ]]; then
        read -r size_kb free_kb <<< "$(df -k / | awk 'NR==2 {print $2, $4}')"
    else
        read -r size_kb free_kb <<< "$(df -k / | awk 'NR==2 {print $2, $4}')"
    fi
    pct_free=$(( free_kb * 100 / size_kb ))
    total_gb=$(awk "BEGIN {printf \"%.1f\", $size_kb/1048576}")
    free_gb=$(awk  "BEGIN {printf \"%.1f\", $free_kb/1048576}")
    display="${pct_free}% free (${free_gb} GB of ${total_gb} GB)"

    if   (( pct_free <= 2  )); then write_result "Critical" "$display" "Red"    "/ (root) nearly full — immediate action required"
    elif (( pct_free <= 5  )); then write_result "Warning"  "$display" "Yellow" "/ (root) running low — cleanup recommended"
    elif (( pct_free <= 10 )); then write_result "Warning"  "$display" "Yellow" "/ (root) below 10% — monitor closely"
    else                             write_result "Healthy"  "$display" "Green"  "Root filesystem has adequate free space"
    fi
}

check_cpu() {
    # Sample CPU load 3 times, 1s apart; detect throttling via scaling_cur_freq vs scaling_max_freq
    local samples=3 total_load=0 s load
    for (( s=0; s<samples; s++ )); do
        if [[ "$OS_TYPE" == "macos" ]]; then
            local ncpu
            ncpu=$(sysctl -n hw.logicalcpu)
            load=$(ps -A -o %cpu | awk -v n="$ncpu" '{s+=$1} END {v=int(s/n); print (v>100?100:v)}')
        else
            # Measure CPU busy% as a 1-second delta of /proc/stat counters
            local idle1 total1 idle2 total2
            read -r idle1 total1 < <(awk '/^cpu / {idle=$5; t=0; for(i=2;i<=NF;i++) t+=$i; print idle, t}' /proc/stat)
            sleep 1
            read -r idle2 total2 < <(awk '/^cpu / {idle=$5; t=0; for(i=2;i<=NF;i++) t+=$i; print idle, t}' /proc/stat)
            load=$(( 100 - (idle2 - idle1) * 100 / (total2 - total1) ))
            total_load=$(( total_load + load ))
            continue
        fi
        sleep 1
        total_load=$(( total_load + load ))
    done
    local mean_load=$(( total_load / samples ))

    # Throttle detection
    local throttled=false throttle_note=""
    if [[ "$OS_TYPE" == "linux" ]] && ls /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq &>/dev/null; then
        local cur_khz max_khz cur_total=0 max_total=0 cpu_count=0
        for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
            cur_total=$(( cur_total + $(cat "$f") ))
            max_total=$(( max_total + $(cat "${f%cur_freq}max_freq") ))
            (( cpu_count++ ))
        done
        local clock_pct=$(( cur_total * 100 / max_total ))
        if (( mean_load > 80 && clock_pct < 100 )); then
            throttled=true
            throttle_note=" | clock: ${clock_pct}%"
        fi
    fi

    local display="load: ${mean_load}%${throttle_note}"
    if   $throttled;              then write_result "Critical" "$display" "Red"    "CPU throttled — high load but below max clock"
    elif (( mean_load > 80 ));    then write_result "Warning"  "$display" "Yellow" "CPU under sustained high load"
    else                               write_result "Healthy"  "$display" "Green"  "CPU operating normally"
    fi
}

check_power_profile() {
    if [[ "$OS_TYPE" == "macos" ]]; then
        local mode
        mode=$(pmset -g | awk '/^[ \t]*powernap|^Active Power/ {print}' | head -1)
        local profile
        profile=$(pmset -g | awk '/^Active Power/{print $NF}')
        # Detect battery (mobile)
        local is_mobile=false
        pmset -g batt 2>/dev/null | grep -q 'Battery' && is_mobile=true

        if $is_mobile; then
            write_result "Healthy" "${profile:-Automatic}" "Green" "macOS manages power automatically on laptops"
        else
            write_result "Healthy" "${profile:-Automatic}" "Green" "macOS manages power automatically on desktop"
        fi
        return
    fi

    # Linux: check cpufreq governor
    local gov_path="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
    if [[ ! -f "$gov_path" ]]; then
        write_result "Unknown" "N/A" "Yellow" "cpufreq governor not available on this system"
        return
    fi
    local governor
    governor=$(cat "$gov_path")
    # Is this a laptop?
    local is_mobile=false
    [[ -d /sys/class/power_supply ]] && ls /sys/class/power_supply/ | grep -qi 'bat' && is_mobile=true

    if   [[ "$governor" == "performance" ]]; then
        write_result "Healthy" "$governor" "Green"  "CPU governor set to maximum performance"
    elif $is_mobile && [[ "$governor" == "powersave" || "$governor" == "schedutil" || "$governor" == "ondemand" ]]; then
        write_result "Healthy" "$governor" "Green"  "Governor appropriate for laptop power management"
    elif [[ "$governor" == "powersave" ]]; then
        write_result "Warning" "$governor" "Yellow" "powersave governor may restrict CPU performance on desktop"
    else
        write_result "Healthy" "$governor" "Green"  "Governor: $governor"
    fi
}

check_updates() {
    local count=0 pkg_mgr=""

    if [[ "$OS_TYPE" == "macos" ]]; then
        if command -v softwareupdate &>/dev/null; then
            count=$(softwareupdate -l 2>/dev/null | grep -c '^\*' || true)
            pkg_mgr="softwareupdate"
        fi
        if command -v brew &>/dev/null; then
            local brew_count
            brew_count=$(brew outdated 2>/dev/null | wc -l | tr -d ' ')
            count=$(( count + brew_count ))
        fi
    elif command -v apt-get &>/dev/null; then
        apt-get update -qq &>/dev/null
        count=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)
        pkg_mgr="apt"
    elif command -v dnf &>/dev/null; then
        count=$(dnf check-update -q 2>/dev/null | grep -cv '^$' || true)
        pkg_mgr="dnf"
    elif command -v yum &>/dev/null; then
        count=$(yum check-update -q 2>/dev/null | grep -cv '^$' || true)
        pkg_mgr="yum"
    elif command -v zypper &>/dev/null; then
        count=$(zypper list-updates 2>/dev/null | grep -c '^v ' || true)
        pkg_mgr="zypper"
    elif command -v pacman &>/dev/null; then
        count=$(pacman -Qu 2>/dev/null | wc -l | tr -d ' ')
        pkg_mgr="pacman"
    else
        write_result "Unknown" "N/A" "Yellow" "No supported package manager found"
        return
    fi

    if (( count > 0 )); then
        write_result "Warning" "$count pending" "Yellow" "$count update(s) waiting to be installed"
    else
        write_result "Healthy" "Up to date" "Green" "System is fully up to date"
    fi
}

check_ram() {
    local total_kb free_kb avail_kb boot_epoch now uptime_s
    if [[ "$OS_TYPE" == "macos" ]]; then
        total_kb=$(( $(sysctl -n hw.memsize) / 1024 ))
        # vm_stat gives pages; page size typically 4096
        local page_size
        page_size=$(vm_stat | awk '/page size/ {print $8}')
        local free_pages
        free_pages=$(vm_stat | awk '/Pages free:/ {gsub(/\./,"",$3); print $3}')
        local speculative
        speculative=$(vm_stat | awk '/Pages speculative:/ {gsub(/\./,"",$3); print $3}')
        avail_kb=$(( (free_pages + speculative) * page_size / 1024 ))
        boot_epoch=$(sysctl -n kern.boottime | awk -F'[ ,]' '{print $4}')
    else
        total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
        avail_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
        uptime_s=$(awk '{print int($1)}' /proc/uptime)
        boot_epoch=$(( $(date +%s) - uptime_s ))
    fi

    local now uptime_min
    now=$(date +%s)
    uptime_min=$(( (now - boot_epoch) / 60 ))

    local total_gb free_gb free_pct display
    total_gb=$(awk "BEGIN {printf \"%.1f\", $total_kb/1048576}")
    free_gb=$(awk  "BEGIN {printf \"%.1f\", $avail_kb/1048576}")
    free_pct=$(( avail_kb * 100 / total_kb ))
    display="${free_gb} GB free of ${total_gb} GB"

    if (( uptime_min < 30 )); then
        write_result "Unknown" "$display" "Cyan" "System just booted — RAM usage not yet representative"
    elif (( free_pct <= 10 )); then
        write_result "Critical" "$display" "Red"    "Critically low RAM — ${free_pct}% free"
    elif (( free_pct <= 20 )); then
        write_result "Warning"  "$display" "Yellow" "Low RAM — ${free_pct}% free"
    else
        write_result "Healthy"  "$display" "Green"  "RAM usage normal — ${free_pct}% free"
    fi
}

check_smart() {
    if ! command -v smartctl &>/dev/null; then
        write_result "Unknown" "N/A" "Yellow" "smartmontools not installed — install with apt/brew install smartmontools"
        return
    fi

    local disks=() total=0 unhealthy=0 new_disks=0 unhealthy_names=""
    if [[ "$OS_TYPE" == "macos" ]]; then
        while IFS= read -r line; do disks+=("$line"); done \
            < <(diskutil list | awk '/^\/dev\/disk[0-9]+$/ {print $1}')
    else
        while IFS= read -r line; do disks+=("$line"); done \
            < <(lsblk -dpno NAME,TYPE | awk '$2=="disk" {print $1}')
    fi

    for disk in "${disks[@]}"; do
        local health power_on
        health=$(smartctl -H "$disk" 2>/dev/null | awk '/overall-health|result:/ {print $NF}')
        power_on=$(smartctl -A "$disk" 2>/dev/null | awk '/Power_On_Hours|Power On Hours/ {print $10}' | head -1)
        [[ -z "$health" ]] && continue
        (( total++ ))

        if [[ -n "$power_on" ]] && (( power_on < 100 )); then
            (( new_disks++ ))
            continue
        fi

        if [[ "$health" != "PASSED" && "$health" != "OK" ]]; then
            (( unhealthy++ ))
            unhealthy_names="${unhealthy_names}${disk} "
        fi
    done

    if (( total == 0 )); then
        write_result "Unknown" "N/A" "Yellow" "No SMART-capable disks detected"
    elif (( total == new_disks )); then
        write_result "Unknown" "${total} disk(s)" "Cyan" "Disk(s) too new for reliable SMART data (< 100 hrs)"
    elif (( unhealthy > 0 )); then
        write_result "Critical" "${unhealthy_names% }" "Red" "${unhealthy} disk(s) reporting unhealthy SMART status"
    else
        local note=""
        (( new_disks > 0 )) && note=" (${new_disks} new disk(s) skipped)"
        write_result "Healthy" "${total} disk(s) checked" "Green" "All disk(s) healthy${note}"
    fi
}

check_av() {
    # Check for common Linux/macOS AV/EDR daemons
    local found_avs=() rtp_disabled=() found=false

    # CrowdStrike Falcon
    if pgrep -x falcond &>/dev/null || pgrep -x falcon-sensor &>/dev/null; then
        found_avs+=("CrowdStrike Falcon"); found=true
    fi
    # SentinelOne
    if pgrep -x sentineld &>/dev/null || pgrep -x SentinelAgent &>/dev/null; then
        found_avs+=("SentinelOne"); found=true
    fi
    # Sophos
    if pgrep -x sophosav &>/dev/null || pgrep -x SophosScanD &>/dev/null; then
        found_avs+=("Sophos"); found=true
    fi
    # Carbon Black
    if pgrep -x cbdaemon &>/dev/null || pgrep -x cbagentd &>/dev/null; then
        found_avs+=("Carbon Black"); found=true
    fi
    # Defender for Endpoint (Linux)
    if command -v mdatp &>/dev/null; then
        found_avs+=("Microsoft Defender")
        local rtp_status
        rtp_status=$(mdatp health --field real_time_protection_enabled 2>/dev/null | tr -d '[:space:]')
        [[ "$rtp_status" == "false" ]] && rtp_disabled+=("Microsoft Defender")
        found=true
    fi
    # macOS XProtect / built-in
    if [[ "$OS_TYPE" == "macos" ]]; then
        if pgrep -x XProtectRemediator &>/dev/null || [[ -d /Library/Apple/System/Library/CoreServices/XProtect.bundle ]]; then
            found_avs+=("XProtect (macOS built-in)"); found=true
        fi
    fi
    # ClamAV
    if pgrep -x clamd &>/dev/null; then
        found_avs+=("ClamAV"); found=true
    fi

    local av_names
    av_names=$(IFS=', '; echo "${found_avs[*]}")

    if ! $found; then
        write_result "Warning" "None detected" "Yellow" "No known AV/EDR agent found — manual verification recommended"
    elif (( ${#rtp_disabled[@]} > 0 )); then
        local dis_names
        dis_names=$(IFS=', '; echo "${rtp_disabled[*]}")
        write_result "Critical" "$av_names" "Red" "Real-time protection disabled: ${dis_names}"
    else
        write_result "Healthy" "$av_names" "Green" "AV/EDR agent detected and running"
    fi
}

check_services() {
    local stopped=() checked=0

    if [[ "$OS_TYPE" == "macos" ]]; then
        # macOS launchd daemons — parallel arrays (bash 3.2 compatible)
        local svc_ids=(
            "com.apple.mDNSResponder"
            "com.apple.logd"
            "com.apple.ntpd"
            "com.apple.configd"
            "com.apple.securityd"
            "com.apple.opendirectoryd"
        )
        local svc_labels=(
            "mDNS Responder"
            "Log Daemon"
            "NTP"
            "Config Daemon"
            "Security Daemon"
            "Directory Services"
        )
        local idx
        for (( idx=0; idx<${#svc_ids[@]}; idx++ )); do
            (( checked++ ))
            if ! launchctl list "${svc_ids[$idx]}" &>/dev/null; then
                stopped+=("${svc_labels[$idx]}")
            fi
        done
    elif command -v systemctl &>/dev/null; then
        local svc_ids=(
            "dbus"
            "systemd-logind"
            "systemd-resolved"
            "systemd-timesyncd"
            "cron"
            "rsyslog"
            "NetworkManager"
            "sshd"
            "firewalld"
            "auditd"
        )
        local svc_labels=(
            "D-Bus"
            "Login Manager"
            "DNS Resolver"
            "Time Sync"
            "Cron / Scheduler"
            "Syslog"
            "Network Manager"
            "SSH Daemon"
            "Firewall"
            "Audit Daemon"
        )
        local idx
        for (( idx=0; idx<${#svc_ids[@]}; idx++ )); do
            local svc="${svc_ids[$idx]}"
            systemctl list-unit-files "${svc}.service" &>/dev/null || continue
            systemctl is-enabled "${svc}.service" --quiet 2>/dev/null || continue
            (( checked++ ))
            if ! systemctl is-active "${svc}.service" --quiet 2>/dev/null; then
                stopped+=("${svc_labels[$idx]}")
            fi
        done
    else
        write_result "Unknown" "N/A" "Yellow" "No supported init system found (systemd/launchd)"
        return
    fi

    if (( ${#stopped[@]} > 0 )); then
        local stop_names
        stop_names=$(IFS=', '; echo "${stopped[*]}")
        write_result "Critical" "${#stopped[@]} of ${checked} down" "Red" "Stopped: ${stop_names}"
    else
        write_result "Healthy" "${checked} checked" "Green" "All critical services running"
    fi
}

check_battery() {
    if [[ "$OS_TYPE" == "macos" ]]; then
        local batt_info
        batt_info=$(system_profiler SPPowerDataType 2>/dev/null)
        if [[ -z "$batt_info" ]] || ! echo "$batt_info" | grep -q "Battery Information"; then
            write_result "N/A" "N/A" "Gray" "No battery — desktop or battery not present"
            return
        fi
        local cycle_count max_cap design_cap health_pct
        cycle_count=$(echo "$batt_info" | awk '/Cycle Count:/ {print $NF}')
        max_cap=$(echo "$batt_info"     | awk '/Full Charge Capacity/ {print $NF}')
        design_cap=$(echo "$batt_info"  | awk '/Design Capacity:/ {print $NF}')

        if [[ -n "$max_cap" && -n "$design_cap" && "$design_cap" -gt 0 ]]; then
            health_pct=$(( max_cap * 100 / design_cap ))
            local cycle_note=""
            [[ -n "$cycle_count" ]] && cycle_note=" | ${cycle_count} cycles"

            if [[ -n "$cycle_count" ]] && (( cycle_count < 10 )); then
                write_result "Unknown" "${cycle_count} cycles / ${health_pct}% capacity" "Cyan" "Battery too new — only ${cycle_count} cycle(s) recorded"
            elif (( health_pct <= 60 )); then
                write_result "Critical" "${health_pct}% health" "Red"    "Battery significantly degraded — ${health_pct}% capacity${cycle_note}"
            elif (( health_pct <= 80 )); then
                write_result "Warning"  "${health_pct}% health" "Yellow" "Battery wear detected — ${health_pct}% capacity${cycle_note}"
            else
                write_result "Healthy"  "${health_pct}% health" "Green"  "Battery health good — ${health_pct}% capacity${cycle_note}"
            fi
        else
            local charge_pct
            charge_pct=$(pmset -g batt 2>/dev/null | awk -F'[;%]' '/InternalBattery/ {gsub(/ /,"",$2); print $2}')
            write_result "Unknown" "${charge_pct}% charge" "Yellow" "Capacity data unavailable"
        fi
        return
    fi

    # Linux: /sys/class/power_supply
    local bat_path=""
    for p in /sys/class/power_supply/BAT* /sys/class/power_supply/battery; do
        [[ -d "$p" ]] && { bat_path="$p"; break; }
    done

    if [[ -z "$bat_path" ]]; then
        write_result "N/A" "N/A" "Gray" "No battery — desktop or battery not present"
        return
    fi

    local energy_full energy_full_design cycle_count health_pct
    energy_full=$(cat "${bat_path}/energy_full" 2>/dev/null || cat "${bat_path}/charge_full" 2>/dev/null)
    energy_full_design=$(cat "${bat_path}/energy_full_design" 2>/dev/null || cat "${bat_path}/charge_full_design" 2>/dev/null)
    cycle_count=$(cat "${bat_path}/cycle_count" 2>/dev/null)

    if [[ -n "$energy_full" && -n "$energy_full_design" && "$energy_full_design" -gt 0 ]]; then
        health_pct=$(( energy_full * 100 / energy_full_design ))
        local cycle_note=""
        [[ -n "$cycle_count" && "$cycle_count" -gt 0 ]] && cycle_note=" | ${cycle_count} cycles"

        if [[ -n "$cycle_count" ]] && (( cycle_count < 10 )); then
            write_result "Unknown" "${cycle_count} cycles / ${health_pct}% capacity" "Cyan" "Battery too new — only ${cycle_count} cycle(s) recorded"
        elif (( health_pct <= 60 )); then
            write_result "Critical" "${health_pct}% health" "Red"    "Battery significantly degraded — ${health_pct}% capacity${cycle_note}"
        elif (( health_pct <= 80 )); then
            write_result "Warning"  "${health_pct}% health" "Yellow" "Battery wear detected — ${health_pct}% capacity${cycle_note}"
        else
            write_result "Healthy"  "${health_pct}% health" "Green"  "Battery health good — ${health_pct}% capacity${cycle_note}"
        fi
    else
        local capacity
        capacity=$(cat "${bat_path}/capacity" 2>/dev/null || echo "?")
        local status
        status=$(cat "${bat_path}/status" 2>/dev/null || echo "Unknown")
        write_result "Unknown" "${capacity}% charge" "Yellow" "Capacity data unavailable — status: ${status}"
    fi
}

# --- Color lookup ---
color_for() {
    case "$1" in
        Green)   echo -n "$C_GREEN"   ;;
        Yellow)  echo -n "$C_YELLOW"  ;;
        Red)     echo -n "$C_RED"     ;;
        Cyan)    echo -n "$C_CYAN"    ;;
        Gray)    echo -n "$C_GRAY"    ;;
        Magenta) echo -n "$C_MAGENTA" ;;
        *)       echo -n "$C_WHITE"   ;;
    esac
}

# --- Parallel execution via background subshells + temp files ---
TMPDIR_RUN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# Start WAN IP lookup in background
WAN_FILE="$TMPDIR_RUN/wan_ip"
( curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "Unavailable" ) > "$WAN_FILE" &
WAN_PID=$!

clear
printf "${C_WHITE}%${WIDTH}s${C_RESET}\n" | tr ' ' '='
printf "${C_WHITE}  RUNNING CHECKS...${C_RESET}\n"
printf "${C_WHITE}%${WIDTH}s${C_RESET}\n" | tr ' ' '='
echo ""

# Define check names and functions
CHECK_NAMES=(
    "Uptime"
    "Disk Space"
    "CPU Performance"
    "Power Profile"
    "OS Updates"
    "RAM Usage"
    "SMART Disk Health"
    "Antivirus / EDR"
    "Critical Services"
    "Battery Health"
)
CHECK_FUNCS=(
    check_uptime
    check_disk
    check_cpu
    check_power_profile
    check_updates
    check_ram
    check_smart
    check_av
    check_services
    check_battery
)

TOTAL=${#CHECK_NAMES[@]}
declare -a PIDS

# Launch all checks in background
for (( i=0; i<TOTAL; i++ )); do
    outfile="$TMPDIR_RUN/check_${i}"
    ( "${CHECK_FUNCS[$i]}" > "$outfile" 2>/dev/null || echo -e "Error\tN/A\tMagenta\tCheck failed unexpectedly" > "$outfile" ) &
    PIDS[$i]=$!
done

# Live progress display
START=$(date +%s)
while true; do
    done_count=0
    for pid in "${PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null || (( done_count++ ))
    done
    elapsed=$(( $(date +%s) - START ))
    elapsed_fmt=$(printf "%02d:%02d" $(( elapsed / 60 )) $(( elapsed % 60 )))
    printf "\r${C_DARK_GRAY}  %d/%d checks complete   [%s]   ${C_RESET}" "$done_count" "$TOTAL" "$elapsed_fmt"
    (( done_count == TOTAL )) && break
    sleep 0.5
done
elapsed=$(( $(date +%s) - START ))
elapsed_fmt=$(printf "%02d:%02d" $(( elapsed / 60 )) $(( elapsed % 60 )))
printf "\r${C_DARK_GRAY}  All checks complete [%s]          ${C_RESET}\n\n" "$elapsed_fmt"

# Wait for WAN IP
wait "$WAN_PID" 2>/dev/null
WAN_IP=$(cat "$WAN_FILE" 2>/dev/null | tr -d '[:space:]')
[[ -z "$WAN_IP" ]] && WAN_IP="Unavailable"

# --- Device info ---
HOSTNAME_VAL=$(hostname 2>/dev/null || echo "Unknown")
USERNAME_VAL=$(logname 2>/dev/null || echo "${SUDO_USER:-$(whoami)}")
GENERATED=$(date '+%Y-%m-%d %H:%M:%S')

if [[ "$OS_TYPE" == "macos" ]]; then
    OS_VAL=$(sw_vers -productName 2>/dev/null)" "$(sw_vers -productVersion 2>/dev/null)
    SERIAL=$(system_profiler SPHardwareDataType 2>/dev/null | awk '/Serial Number/ {print $NF}')
    MODEL=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/ {print $2}' | head -1)
    DOMAIN=$(dsconfigad -show 2>/dev/null | awk -F'=' '/Active Directory Domain/ {gsub(/ /,"",$2); print $2}' || echo "N/A")
    BOOT_TIME=$(sysctl -n kern.boottime | awk -F'[= ,]' '{cmd="date -r "$5" +\"%Y-%m-%d %H:%M:%S\""; cmd | getline r; print r}')
    LOCAL_IP=$(ifconfig 2>/dev/null | awk '/inet / && !/127\./ {print $2; exit}')
else
    OS_VAL=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Unknown}" || uname -sr)
    KERNEL=$(uname -r)
    OS_VAL="${OS_VAL} ($(uname -r))"
    SERIAL=$(dmidecode -s system-serial-number 2>/dev/null | grep -v '^#' | head -1 || echo "N/A")
    MODEL=$(dmidecode -s system-product-name 2>/dev/null | grep -v '^#' | head -1 || echo "N/A")
    DOMAIN=$(hostname -d 2>/dev/null || echo "N/A")
    local_boot=$(date -d "$(uptime -s 2>/dev/null)" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    if [[ -z "$local_boot" ]]; then
        local_boot=$(date -d "@$(( $(date +%s) - $(awk '{print int($1)}' /proc/uptime) ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "N/A")
    fi
    BOOT_TIME="$local_boot"
    LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
fi

[[ -z "$LOCAL_IP" ]] && LOCAL_IP="Not detected"
[[ -z "$SERIAL"   ]] && SERIAL="N/A"
[[ -z "$MODEL"    ]] && MODEL="N/A"
[[ -z "$DOMAIN"   ]] && DOMAIN="N/A"
[[ -z "$BOOT_TIME" ]] && BOOT_TIME="N/A"

# --- Results ---
clear

printf "${C_WHITE}%${WIDTH}s${C_RESET}\n" | tr ' ' '='
printf "${C_CYAN}%-$(( WIDTH ))s${C_RESET}\n" "  ENDPOINT HEALTH CHECK"
printf "${C_WHITE}%${WIDTH}s${C_RESET}\n" | tr ' ' '='
write_info_row "Host"      "$HOSTNAME_VAL"  "Serial"    "$SERIAL"
write_info_row "User"      "$USERNAME_VAL"  "Model"     "$MODEL"
write_info_row "Domain"    "$DOMAIN"        "OS"        "$OS_VAL"
write_info_row "Local IP"  "$LOCAL_IP"      "WAN IP"    "$WAN_IP"
write_info_row "Boot Time" "$BOOT_TIME"     "Generated" "$GENERATED"
printf "${C_WHITE}%${WIDTH}s${C_RESET}\n" | tr ' ' '='
echo ""

write_row "CHECK" "STATUS" "VALUE" "DETAILS" "$C_WHITE"
write_divider "$C_WHITE"

for (( i=0; i<TOTAL; i++ )); do
    outfile="$TMPDIR_RUN/check_${i}"
    if [[ -f "$outfile" ]]; then
        IFS=$'\t' read -r status value color_name message < "$outfile"
    else
        status="Error"; value="N/A"; color_name="Magenta"; message="Result file missing"
    fi
    color=$(color_for "$color_name")
    write_row "${CHECK_NAMES[$i]}" "$status" "$value" "$message" "$color"
done

write_divider "$C_WHITE"
echo ""
