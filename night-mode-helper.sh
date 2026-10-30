#!/usr/bin/env bash
set -euo pipefail

temperature="${3:-5600}"
active="${6:-false}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
settings_file="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/settings.toml"
pid_file="${XDG_RUNTIME_DIR:-/tmp}/quickshell-night-mode.pid"

if [[ ! "$temperature" =~ ^[0-9]+$ ]] || ((temperature < 3000 || temperature > 6500)); then
    exit 2
fi

# Noctalia and wlsunset use the same gamma-control interface. Keep one owner.
if [[ -f "$settings_file" ]]; then
    temp_file="$(mktemp "${settings_file}.night-mode.XXXXXX")"
    awk '
function finish_section() {
    if (section == "[nightlight]") {
        if (!seen_enabled) print "enabled = false"
        if (!seen_force) print "force = false"
    }
}
/^\[/ {
    finish_section()
    section = $0
    if (section == "[nightlight]") found_nightlight = 1
    seen_enabled = seen_force = 0
    print
    next
}
section == "[nightlight]" && /^enabled[[:space:]]*=/ {
    print "enabled = false"; seen_enabled = 1; next
}
section == "[nightlight]" && /^force[[:space:]]*=/ {
    print "force = false"; seen_force = 1; next
}
{ print }
END {
    finish_section()
    if (!found_nightlight) {
        print ""
        print "[nightlight]"
        print "enabled = false"
        print "force = false"
    }
}
' "$settings_file" > "$temp_file"

    if cmp -s "$temp_file" "$settings_file"; then
        rm -f "$temp_file"
    else
        mv "$temp_file" "$settings_file"
        if command -v noctalia >/dev/null 2>&1; then
            noctalia msg config-reload >/dev/null 2>&1 || true
        fi
    fi
fi

exec 9>"${pid_file}.lock"
flock -x 9

current_pid=""
current_temperature=""
if [[ -f "$pid_file" ]]; then
    read -r current_pid current_temperature < "$pid_file" || true
fi

owns_process=false
if [[ "$current_pid" =~ ^[0-9]+$ && -r "/proc/$current_pid/comm" ]] \
    && [[ "$(cat "/proc/$current_pid/comm")" == "wlsunset" ]]; then
    owns_process=true
fi

if [[ "$active" == true && "$owns_process" == true \
    && "$current_temperature" == "$temperature" ]]; then
    exit 0
fi

if [[ "$owns_process" == true ]]; then
    kill "$current_pid" 2>/dev/null || true
fi
rm -f "$pid_file"

if [[ "$active" != true ]]; then
    exit 0
fi

if command -v wlsunset >/dev/null 2>&1; then
    wlsunset_bin="$(command -v wlsunset)"
else
    wlsunset_bin="$script_dir/bin/wlsunset"
fi

# Hold one temperature; Quickshell changes it only at the schedule boundaries.
"$wlsunset_bin" -T "$((temperature + 1))" -t "$temperature" -S 00:00 -s 12:00 9>&- >/dev/null 2>&1 &
printf '%s %s\n' "$!" "$temperature" > "$pid_file"
