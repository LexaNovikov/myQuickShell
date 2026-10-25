#!/usr/bin/env bash
set -euo pipefail

forced="${1:-false}"
scheduled="${2:-false}"
temperature="${3:-5600}"
from_time="${4:-21:00:00}"
to_time="${5:-07:00:00}"

settings_file="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/settings.toml"
temp_file="${settings_file}.night-mode.$$"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

enabled=false
if [[ "$forced" == true || "$scheduled" == true ]]; then
    enabled=true
fi

if [[ -f "$settings_file" ]]; then
awk \
    -v forced="$forced" \
    -v scheduled="$scheduled" \
    -v enabled="$enabled" \
    -v temperature="$temperature" \
    -v sunrise="${to_time:0:5}" \
    -v sunset="${from_time:0:5}" '
function finish_section() {
    if (section == "[location]") {
        if (!seen_custom) print "custom_schedule = " scheduled
        if (!seen_sunrise) print "sunrise = \"" sunrise "\""
        if (!seen_sunset) print "sunset = \"" sunset "\""
    } else if (section == "[nightlight]") {
        if (!seen_enabled) print "enabled = " enabled
        if (!seen_force) print "force = " forced
        if (!seen_temperature) print "temperature_night = " temperature
    }
}

/^\[/ {
    finish_section()
    section = $0
    if (section == "[location]") found_location = 1
    if (section == "[nightlight]") found_nightlight = 1
    seen_custom = seen_sunrise = seen_sunset = 0
    seen_enabled = seen_force = seen_temperature = 0
    print
    next
}

section == "[location]" && /^custom_schedule[[:space:]]*=/ {
    print "custom_schedule = " scheduled; seen_custom = 1; next
}
section == "[location]" && /^sunrise[[:space:]]*=/ {
    print "sunrise = \"" sunrise "\""; seen_sunrise = 1; next
}
section == "[location]" && /^sunset[[:space:]]*=/ {
    print "sunset = \"" sunset "\""; seen_sunset = 1; next
}
section == "[nightlight]" && /^enabled[[:space:]]*=/ {
    print "enabled = " enabled; seen_enabled = 1; next
}
section == "[nightlight]" && /^force[[:space:]]*=/ {
    print "force = " forced; seen_force = 1; next
}
section == "[nightlight]" && /^temperature_night[[:space:]]*=/ {
    print "temperature_night = " temperature; seen_temperature = 1; next
}

{ print }

END {
    finish_section()
    if (!found_location) {
        print ""
        print "[location]"
        print "custom_schedule = " scheduled
        print "sunrise = \"" sunrise "\""
        print "sunset = \"" sunset "\""
    }
    if (!found_nightlight) {
        print ""
        print "[nightlight]"
        print "enabled = " enabled
        print "force = " forced
        print "temperature_night = " temperature
    }
}
' "$settings_file" > "$temp_file"

mv "$temp_file" "$settings_file"
fi

fallback_pid_file="${XDG_RUNTIME_DIR:-/tmp}/quickshell-night-mode.pid"

stop_fallback() {
    if [[ -f "$fallback_pid_file" ]]; then
        fallback_pid="$(cat "$fallback_pid_file")"
        if [[ "$fallback_pid" =~ ^[0-9]+$ ]]; then
            kill "$fallback_pid" 2>/dev/null || true
        fi
        rm -f "$fallback_pid_file"
    fi
}

if [[ -f "$settings_file" ]] && command -v noctalia >/dev/null 2>&1 \
    && noctalia msg config-reload >/dev/null 2>&1; then
    stop_fallback
    exit 0
fi

stop_fallback
if [[ "$enabled" == true ]]; then
    if command -v wlsunset >/dev/null 2>&1; then
        wlsunset_bin="$(command -v wlsunset)"
    else
        wlsunset_bin="$script_dir/bin/wlsunset"
    fi
    if [[ "$forced" == true ]]; then
        "$wlsunset_bin" -T "$((temperature + 1))" -t "$temperature" -S 00:00 -s 12:00 >/dev/null 2>&1 &
    else
        "$wlsunset_bin" -T 6500 -t "$temperature" -S "${to_time:0:5}" -s "${from_time:0:5}" >/dev/null 2>&1 &
    fi
    echo "$!" > "$fallback_pid_file"
fi
