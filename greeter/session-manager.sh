#!/usr/bin/env bash

set -euo pipefail

session_kind="${2:-}"
session_id="${3:-}"
entry_name=""
entry_exec=""
entry_try_exec=""
entry_desktop_names=""
entry_hidden="false"
entry_no_display="false"

session_directory() {
    case "$1" in
        wayland) printf '%s' 'wayland-sessions' ;;
        x11) printf '%s' 'xsessions' ;;
        *) return 1 ;;
    esac
}

valid_session_id() {
    [[ "$1" =~ ^[a-zA-Z0-9._+-]+$ && "$1" != *..* ]]
}

find_session_file() {
    local directory
    directory="$(session_directory "$1")" || return 1
    valid_session_id "$2" || return 1

    local data_root
    for data_root in /usr/local/share /usr/share; do
        if [[ -f "$data_root/$directory/$2.desktop" ]]; then
            printf '%s' "$data_root/$directory/$2.desktop"
            return 0
        fi
    done
    return 1
}

load_entry() {
    entry_name=""
    entry_exec=""
    entry_try_exec=""
    entry_desktop_names=""
    entry_hidden="false"
    entry_no_display="false"

    local line in_main_section=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" == '[Desktop Entry]' ]]; then
            in_main_section=true
            continue
        fi
        if [[ "$line" == \[*\] ]]; then
            in_main_section=false
            continue
        fi
        [[ "$in_main_section" == true ]] || continue

        case "$line" in
            Name=*) entry_name="${line#Name=}" ;;
            Exec=*) entry_exec="${line#Exec=}" ;;
            TryExec=*) entry_try_exec="${line#TryExec=}" ;;
            DesktopNames=*) entry_desktop_names="${line#DesktopNames=}" ;;
            Hidden=*) entry_hidden="${line#Hidden=}" ;;
            NoDisplay=*) entry_no_display="${line#NoDisplay=}" ;;
        esac
    done < "$1"
}

entry_is_available() {
    [[ -n "$entry_exec" && "${entry_hidden,,}" != true && "${entry_no_display,,}" != true ]] || return 1
    if [[ -n "$entry_try_exec" ]]; then
        command -v -- "$entry_try_exec" >/dev/null 2>&1 || return 1
    fi
}

case "${1:-}" in
    list)
        declare -A seen_sessions=()
        for session_kind in wayland x11; do
            if [[ "$session_kind" == x11 ]] && ! command -v startx >/dev/null 2>&1; then
                continue
            fi
            directory="$(session_directory "$session_kind")"
            for data_root in /usr/local/share /usr/share; do
                [[ -d "$data_root/$directory" ]] || continue
                for session_file in "$data_root/$directory"/*.desktop; do
                    [[ -f "$session_file" ]] || continue
                    session_id="${session_file##*/}"
                    session_id="${session_id%.desktop}"
                    valid_session_id "$session_id" || continue
                    [[ ! -v "seen_sessions[$session_kind:$session_id]" ]] || continue
                    seen_sessions["$session_kind:$session_id"]=1
                    load_entry "$session_file"
                    entry_is_available || continue
                    entry_name="${entry_name:-$session_id}"
                    entry_desktop_names="${entry_desktop_names:-$session_id}"
                    entry_desktop_names="${entry_desktop_names//;/:}"
                    entry_desktop_names="${entry_desktop_names%:}"
                    printf '%s\t%s\t%s\t%s\n' "$session_kind" "$session_id" \
                        "${entry_name//$'\t'/ }" "${entry_desktop_names//$'\t'/ }"
                done
            done
        done
        ;;

    launch)
        session_file="$(find_session_file "$session_kind" "$session_id")" || exit 2
        load_entry "$session_file"
        entry_is_available || exit 2

        if [[ "$session_kind" == x11 ]]; then
            command -v startx >/dev/null 2>&1 || exit 2
            unset WAYLAND_DISPLAY DISPLAY
            exec startx /usr/bin/env -S "$entry_exec"
        fi

        if [[ "$session_kind" == wayland && "$session_id" == gnome ]]; then
            # GNOME starts its session units through the user's systemd bus.
            # A private dbus-run-session bus cannot reach org.freedesktop.systemd1.
            user_bus="/run/user/$(id -u)/bus"
            if [[ ! -S "$user_bus" ]]; then
                printf 'GNOME user bus is unavailable: %s\n' "$user_bus" >&2
                exit 1
            fi
            export DBUS_SESSION_BUS_ADDRESS="unix:path=$user_bus"
        fi
        exec /usr/bin/env -S "$entry_exec"
        ;;

    *)
        printf '%s\n' 'Usage: session-manager.sh {list|launch TYPE ID}' >&2
        exit 2
        ;;
esac
