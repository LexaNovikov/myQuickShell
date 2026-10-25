#!/usr/bin/env bash

set -u

read_cpu() {
    local label user nice system idle iowait irq softirq steal guest guest_nice
    read -r label user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    CPU_IDLE=$((idle + iowait))
    CPU_TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal))
}

read_cpu
first_idle=$CPU_IDLE
first_total=$CPU_TOTAL
sleep 0.15
read_cpu

delta_idle=$((CPU_IDLE - first_idle))
delta_total=$((CPU_TOTAL - first_total))

mem_total_kib=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
mem_available_kib=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
mem_used_kib=$((mem_total_kib - mem_available_kib))

battery_present=0
battery_percent=0
battery_status="unknown"
battery_minutes=-1
battery_health=0

shopt -s nullglob
for candidate in /sys/class/power_supply/BAT*; do
    if [[ -d "$candidate" ]]; then
        battery_path="$candidate"
        battery_present=1
        break
    fi
done

if (( battery_present )); then
    [[ -r "$battery_path/capacity" ]] && read -r battery_percent < "$battery_path/capacity"
    if [[ -r "$battery_path/status" ]]; then
        read -r battery_status < "$battery_path/status"
        battery_status=${battery_status,,}
        battery_status=${battery_status// /-}
    fi

    stored_now=0
    stored_full=0
    stored_design=0
    rate=0

    if [[ -r "$battery_path/energy_now" ]]; then
        read -r stored_now < "$battery_path/energy_now"
        [[ -r "$battery_path/energy_full" ]] && read -r stored_full < "$battery_path/energy_full"
        [[ -r "$battery_path/energy_full_design" ]] && read -r stored_design < "$battery_path/energy_full_design"
        [[ -r "$battery_path/power_now" ]] && read -r rate < "$battery_path/power_now"
    elif [[ -r "$battery_path/charge_now" ]]; then
        read -r stored_now < "$battery_path/charge_now"
        [[ -r "$battery_path/charge_full" ]] && read -r stored_full < "$battery_path/charge_full"
        [[ -r "$battery_path/charge_full_design" ]] && read -r stored_design < "$battery_path/charge_full_design"
        [[ -r "$battery_path/current_now" ]] && read -r rate < "$battery_path/current_now"
    fi

    if (( stored_design > 0 && stored_full > 0 )); then
        battery_health=$((stored_full * 100 / stored_design))
        (( battery_health > 100 )) && battery_health=100
    else
        battery_health=$battery_percent
    fi

    if [[ "$battery_status" == "charging" ]] && (( rate > 0 && stored_full > stored_now )); then
        battery_minutes=$(((stored_full - stored_now) * 60 / rate))
    fi
fi

power_profile="balanced"
if command -v busctl >/dev/null 2>&1; then
    detected_profile=$(busctl --system get-property \
        net.hadess.PowerProfiles /net/hadess/PowerProfiles \
        net.hadess.PowerProfiles ActiveProfile 2>/dev/null || true)
    if [[ "$detected_profile" =~ \"([^\"]+)\" ]]; then
        power_profile="${BASH_REMATCH[1]}"
    fi
fi

awk -v memory="$mem_used_kib" -v idle="$delta_idle" -v total="$delta_total" \
    -v battery_present="$battery_present" -v battery_percent="$battery_percent" \
    -v battery_status="$battery_status" -v battery_minutes="$battery_minutes" \
    -v battery_health="$battery_health" -v power_profile="$power_profile" 'BEGIN {
    memory_gib = memory / 1048576
    cpu = total > 0 ? (total - idle) * 100 / total : 0
    printf "%.1f|%.0f|%d|%d|%s|%d|%d|%s\n", memory_gib, cpu,
        battery_present, battery_percent, battery_status, battery_minutes,
        battery_health, power_profile
}'
