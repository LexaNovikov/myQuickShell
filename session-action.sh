#!/usr/bin/env bash

set -u

action="${1:-}"

# Use Noctalia's lock screen while it is installed and running.
if command -v noctalia >/dev/null 2>&1 && pgrep -x noctalia >/dev/null 2>&1; then
    exec noctalia msg session "$action"
fi

# systemd handles the action when the shell is used without Noctalia. A
# standalone lock screen must listen for loginctl's lock request.
case "$action" in
    lock)
        exec loginctl lock-session
        ;;
    lock-and-suspend)
        loginctl lock-session || true
        sleep 0.4
        exec systemctl suspend
        ;;
    *)
        exit 2
        ;;
esac
