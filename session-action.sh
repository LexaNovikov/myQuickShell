#!/usr/bin/env bash

set -u

action="${1:-}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
lock_dir="$script_dir/lockscreen"
request_file="$lock_dir/.request"

case "$action" in
    lock|lock-and-suspend) ;;
    *)
        exit 2
        ;;
esac

# The dedicated Quickshell instance owns the secure Wayland session lock.
# For suspend requests it waits until the compositor confirms secure=true.
umask 077
printf '%s\n%s\n' "$action" "${USER:-}" > "$request_file"

exec env QS_DISABLE_FILE_WATCHER=1 qs \
    --path "$lock_dir" \
    --no-duplicate \
    --daemonize
