#!/usr/bin/env bash

set -euo pipefail

action="${1:-install}"
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$project_dir/greeter"
target_dir="/etc/greetd/quickshell-greeter"
backup_dir="/etc/greetd/quickshell-backup"

if [[ "$action" == "preview" ]]; then
    exec qs --path "$source_dir" --no-duplicate
fi

if [[ $EUID -ne 0 ]]; then
    echo "Run this action as root: sudo $0 $action" >&2
    exit 1
fi

case "$action" in
    install)
        login_user="${2:-${SUDO_USER:-}}"
        if [[ -z "$login_user" || "$login_user" == "root" || "$login_user" == "greeter" ]]; then
            echo "Could not determine the desktop user. Pass it explicitly: sudo $0 install USER" >&2
            exit 2
        fi
        if ! getent passwd "$login_user" >/dev/null; then
            echo "User does not exist: $login_user" >&2
            exit 2
        fi

        for command_name in greetd cage qs niri-session; do
            if ! command -v "$command_name" >/dev/null 2>&1; then
                echo "Required command is missing: $command_name" >&2
                exit 3
            fi
        done

        install -d -m 700 "$backup_dir"
        if [[ -f /etc/greetd/config.toml && ! -e "$backup_dir/config.toml" ]]; then
            install -m 600 /etc/greetd/config.toml "$backup_dir/config.toml"
        fi
        if [[ -f /etc/pam.d/greetd && ! -e "$backup_dir/greetd.pam" ]]; then
            install -m 600 /etc/pam.d/greetd "$backup_dir/greetd.pam"
        fi

        install -d -m 755 "$target_dir"
        install -m 644 "$source_dir/shell.qml" "$target_dir/shell.qml"
        printf '%s\n' "$login_user" > "$target_dir/default-user"
        chmod 644 "$target_dir/default-user"

        login_home="$(getent passwd "$login_user" | cut -d: -f6)"
        font_source="$login_home/.local/share/fonts/SF-Pro"
        if [[ -d "$font_source" ]]; then
            font_target="/usr/local/share/fonts/SF-Pro"
            install -d -m 755 "$font_target"
            for font_file in "$font_source"/*.otf "$font_source"/*.ttf; do
                [[ -f "$font_file" ]] || continue
                install -m 644 "$font_file" "$font_target/$(basename "$font_file")"
            done
            if command -v fc-cache >/dev/null 2>&1; then
                fc-cache -f "$font_target"
            fi
        else
            echo "Warning: SF Pro fonts were not found in $font_source" >&2
        fi

        install -m 755 "$source_dir/system/quickshell-greeter-session" /usr/local/bin/quickshell-greeter-session
        install -d -m 755 /usr/local/libexec
        install -m 755 "$source_dir/system/quickshell-greeter-password-mode" /usr/local/libexec/quickshell-greeter-password-mode
        install -m 644 "$source_dir/system/config.toml" /etc/greetd/config.toml
        install -m 644 "$source_dir/system/greetd.pam" /etc/pam.d/greetd

        systemctl enable greetd.service --force

        echo "Quickshell greeter installed for user: $login_user"
        echo "greetd will be used after the next reboot; the current graphical session was not stopped."
        echo "Recovery from a TTY: sudo $0 restore-sddm"
        ;;

    restore-sddm)
        if ! systemctl list-unit-files sddm.service >/dev/null 2>&1; then
            echo "sddm.service is not installed" >&2
            exit 4
        fi
        systemctl enable sddm.service --force
        echo "SDDM will be used after the next reboot."
        ;;

    restore-greetd-config)
        if [[ -f "$backup_dir/config.toml" ]]; then
            install -m 644 "$backup_dir/config.toml" /etc/greetd/config.toml
        fi
        if [[ -f "$backup_dir/greetd.pam" ]]; then
            install -m 644 "$backup_dir/greetd.pam" /etc/pam.d/greetd
        fi
        echo "The previous greetd and PAM configuration has been restored."
        ;;

    *)
        echo "Usage: $0 {preview|install [USER]|restore-sddm|restore-greetd-config}" >&2
        exit 2
        ;;
esac
