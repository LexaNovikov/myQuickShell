#!/usr/bin/env bash
set -euo pipefail

wallpaper_dir() {
    if [[ -n "${QS_WALLPAPER_DIR:-}" ]]; then
        printf '%s\n' "$QS_WALLPAPER_DIR"
        return
    fi

    local pictures_dir="${HOME}/Pictures"
    if command -v xdg-user-dir >/dev/null 2>&1; then
        pictures_dir="$(xdg-user-dir PICTURES)"
    fi

    local candidate
    for candidate in \
        "$pictures_dir/wallpaper" \
        "$pictures_dir/Wallpapers" \
        "$pictures_dir/Обои"; do
        if [[ -d "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    done

    printf '%s\n' "$pictures_dir/wallpaper"
}

command_name="${1:-list}"
directory="$(wallpaper_dir)"

case "$command_name" in
    directory)
        printf '%s\n' "$directory"
        ;;
    list)
        [[ -d "$directory" ]] || exit 0
        find "$directory" -maxdepth 1 -type f \
            \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
            -print | sort
        ;;
    accent)
        wallpaper="${2:-}"
        [[ -n "$wallpaper" && -f "$wallpaper" ]] || exit 2
        resolved_directory="$(realpath -e "$directory")"
        resolved_wallpaper="$(realpath -e "$wallpaper")"
        [[ "$(dirname "$resolved_wallpaper")" == "$resolved_directory" ]] || exit 2
        command -v magick >/dev/null 2>&1 || exit 127
        magick "$resolved_wallpaper" -resize 64x64 -colors 12 -depth 8 \
            -format %c histogram:info:- \
            | sort -nr \
            | tail -n 1 \
            | sed -E 's/.*#([0-9A-Fa-f]{6}).*/#\1/'
        ;;
    set)
        wallpaper="${2:-}"
        output_name="${3:-}"
        [[ -n "$wallpaper" ]] || { printf 'Wallpaper path is empty\n' >&2; exit 2; }
        [[ -f "$wallpaper" ]] || { printf 'Wallpaper does not exist\n' >&2; exit 2; }

        resolved_directory="$(realpath -e "$directory")"
        resolved_wallpaper="$(realpath -e "$wallpaper")"
        [[ "$(dirname "$resolved_wallpaper")" == "$resolved_directory" ]] || {
            printf 'Wallpaper is outside the configured directory\n' >&2
            exit 2
        }

        command -v awww >/dev/null 2>&1 || {
            printf 'awww is not installed\n' >&2
            exit 127
        }

        if ! awww query >/dev/null 2>&1; then
            command -v awww-daemon >/dev/null 2>&1 || {
                printf 'awww daemon is unavailable\n' >&2
                exit 1
            }
            awww-daemon --quiet >/dev/null 2>&1 &
            for _ in {1..20}; do
                awww query >/dev/null 2>&1 && break
                sleep 0.05
            done
        fi

        image_command=(img "$resolved_wallpaper" \
            --resize crop \
            --transition-type grow \
            --transition-duration 0.8 \
            --transition-fps 60)
        if [[ -n "$output_name" ]]; then
            image_command+=(--outputs "$output_name")
            for _ in {1..10}; do
                awww "${image_command[@]}" && exit 0
                sleep 0.2
            done
            exit 1
        fi
        awww "${image_command[@]}"
        ;;
    *)
        printf 'Usage: %s {directory|list|accent PATH|set PATH [OUTPUT]}\n' "$0" >&2
        exit 2
        ;;
esac
