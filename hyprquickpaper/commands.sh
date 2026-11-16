#!/usr/bin/env bash
# Sets a wallpaper and makes the colors of the shell from it (DarkShadow's Shell).
# Replace "random" with: fade, wipe, grow, outer, wave, center, any, random
# A video is a live wallpaper: rice-walls plays it (mpvpaper) and gives this script one frame of it.
# What went wrong (no ImageMagick, matugen errors ...) is written to ~/.cache/rice/colors.log.

img="$1"
[[ -f "$img" ]] || { echo "commands.sh: not a file: $img" >&2; exit 1; }
case "${img,,}" in
  *.mp4|*.webm|*.mkv|*.mov|*.avi|*.m4v) exec "$HOME/.local/bin/rice-walls" set "$img" ;;
esac

mkdir -p "$HOME/.cache/rice" "$HOME/.config/waybar"
log="$HOME/.cache/rice/colors.log"
: >"$log"
say() { echo "$(date '+%H:%M:%S') $*" >>"$log"; }

# a picture: a live wallpaper that still plays stops (unless this is its own frame)
# (mpvpaper can miss SIGTERM while it is paused, so it gets SIGKILL when it stays; NixOS names it .mpvpaper-wrapped)
if [ -z "$RICE_LIVE" ]; then
  rm -f "$HOME/.cache/rice/live-wallpaper"
  mp='^([^ ]*/)?\.?mpvpaper(-wrapped)?( |$)'
  if pgrep -f "$mp" >/dev/null 2>&1; then
    pkill -f "$mp" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do pgrep -f "$mp" >/dev/null 2>&1 || break; sleep 0.1; done
    pgrep -f "$mp" >/dev/null 2>&1 && { pkill -9 -f "$mp" 2>/dev/null; sleep 0.2; }
  fi
fi

if [ -z "$RICE_COLORS_ONLY" ]; then
  # the animation you chose (Settings > Wallpaper > Animation): a ripple from your pointer, a wave ...
  targs=()
  [ -x "$HOME/.local/bin/rice-walls" ] && mapfile -t targs < <("$HOME/.local/bin/rice-walls" awww-args 2>/dev/null)
  [ "${#targs[@]}" -gt 0 ] || targs=(-t random --transition-duration 1)
  if command -v awww >/dev/null 2>&1; then
    awww img "$img" "${targs[@]}" 2>>"$log" || awww img "$img" 2>>"$log" || say "awww could not set it (is awww-daemon running?)"
  elif command -v swww >/dev/null 2>&1; then
    swww img "$img" "${targs[@]}" 2>>"$log" || swww img "$img" 2>>"$log"
  else
    say "no awww: the wallpaper itself was not changed"
  fi
fi

src="$HOME/.cache/quickshell/thumbs/$(basename "$img")"
[[ -f "$src" ]] || src="$img"

# ImageMagick 7 is "magick", 6 is "convert"
im=""
if command -v magick >/dev/null 2>&1; then im=magick
elif command -v convert >/dev/null 2>&1; then im=convert
fi
sat=50; lum=50
if [ -n "$im" ]; then
  # how colorful it is: the chroma (HCL), not the HSL saturation. HSL calls a near-black pixel with a hint of blue
  # "saturated", so a black or white wallpaper with a few stars came out pink or blue before
  s=$("$im" -define jpeg:size=200x200 "$src[0]" -resize 100x100! -colorspace HCL -channel G -separate +channel -format "%[fx:mean*100]" info: 2>>"$log")
  l=$("$im" -define jpeg:size=200x200 "$src[0]" -resize 100x100! -colorspace Gray -format "%[fx:mean*100]" info: 2>>"$log")
  [[ "$s" =~ ^[0-9.]+$ ]] && sat="$s"
  [[ "$l" =~ ^[0-9.]+$ ]] && lum="$l"
else
  say "ImageMagick is missing: grey wallpapers are not detected (install imagemagick)"
fi

mode="$(cat "$HOME/.config/rice/color-mode" 2>/dev/null)"
scheme=""
navy=""
case "$mode" in
  grey) sat=0; lum=50 ;;
  navy) navy=1 ;;
  ""|auto) ;;
  *) scheme="$("$HOME/.local/bin/rice-colors" scheme "$mode" 2>/dev/null)" ;;
esac

if [ -n "$scheme" ]; then
  # named color scheme from Settings > Home > Colors: "<matugen type> <seed> <workspace marker>"
  read -r stype seed ws <<<"$scheme"
  cmd=(matugen color hex "$seed" --type "$stype")
elif [ -n "$navy" ]; then
  ws='#8a8a8a'
  cmd=(matugen color hex "#1a2a5e")
elif awk "BEGIN{exit !($sat < 7)}"; then
  # black, white or grey: everything in grey too (no made-up color), the same for dark and light pictures
  ws='#8a8a8a'
  cmd=(matugen color hex "#808080" --type scheme-monochrome)
  say "a grey wallpaper (chroma $sat): monochrome colors"
else
  ws='@on_accent'
  cmd=(matugen image "$src" --source-color-index 0)
fi

printf '@define-color ws_active %s;\n' "$ws" > "$HOME/.config/waybar/ws-active.css"

mat="$(command -v matugen 2>/dev/null)"
[ -z "$mat" ] && [ -x "$HOME/.local/bin/matugen" ] && mat="$HOME/.local/bin/matugen"
if [ -z "$mat" ]; then
  say "matugen is not installed: the colors cannot follow the wallpaper"
  if [ ! -f "$HOME/.cache/rice/colors-told" ]; then
    notify-send -a Wallpaper "Colors need matugen" \
      "Install the matugen package (NixOS: pkgs.matugen), then pick the wallpaper again." 2>/dev/null
    : >"$HOME/.cache/rice/colors-told"
  fi
else
  rm -f "$HOME/.cache/rice/colors-told"
  cmd[0]="$mat"
  # never waits for an answer. Older matugen has no --source-color-index: left out then
  if ! "${cmd[@]}" -q </dev/null 2>>"$log"; then
    say "matugen failed: ${cmd[*]} -q (trying again without the newer options)"
    plain=(); skip=""
    for a in "${cmd[@]}"; do
      if [ -n "$skip" ]; then skip=""; continue; fi
      if [ "$a" = "--source-color-index" ]; then skip=1; continue; fi
      plain+=("$a")
    done
    "${plain[@]}" </dev/null >>"$log" 2>&1 || say "matugen failed again: see the lines above"
  fi
fi

mkdir -p "$HOME/.cache"
echo "$img" > "$HOME/.cache/hyprquickpaper-current"

# recolor notifications and the lock screen (Shadow's Shell)
"$HOME/.local/bin/rice-colors" refresh >/dev/null 2>&1 &
