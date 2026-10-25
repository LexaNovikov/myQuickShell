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

awk -v memory="$mem_used_kib" -v idle="$delta_idle" -v total="$delta_total" 'BEGIN {
    memory_gib = memory / 1048576
    cpu = total > 0 ? (total - idle) * 100 / total : 0
    printf "%.1f|%.0f\n", memory_gib, cpu
}'
