#!/usr/bin/env bash
# Tests for wl-screenshot, including its annotate mode. Run: bash tests/wl-screenshot.test.sh
# Every tool is a stub, HOME is a temp dir, so no display and no real screenshots are involved.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../.local/scripts/wl-screenshot"

W=$(mktemp --directory)
trap 'rm --recursive --force "$W"' EXIT
mkdir "$W/bin" "$W/home"
LOG="$W/log"

printf '#!/bin/sh\necho "{\\"type\\":\\"root\\",\\"nodes\\":[]}"\n' > "$W/bin/swaymsg"
printf '#!/bin/sh\ncat >/dev/null; echo "10,10 600x300"\n' > "$W/bin/slurp"
printf '#!/bin/sh\nprintf RAWPIXELS\n' > "$W/bin/grim"
printf '#!/bin/sh\necho "wl-copy:$(cat)" >> "%s"\n' "$LOG" > "$W/bin/wl-copy"
# swappy stand-in: writes "ANNOTATED:<input>" to the --output-file, like swappy does on exit
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in --file) f=$2; shift;; --output-file) o=$2; shift;; esac; shift; done\nprintf "ANNOTATED:%%s" "$(cat "$f")" > "$o"\n' > "$W/bin/swappy"
chmod +x "$W/bin"/*

fail=0
check() {
  local name=$1 want=$2 got=$3
  if [ "$got" = "$want" ]; then echo "ok: $name"; else echo "FAIL: $name: want '$want', got '$got'"; fail=1; fi
}
shots() { ls "$W/home/Pictures/Screenshots" 2>/dev/null | wc --lines | tr -d ' '; }
reset() { : > "$LOG"; rm --recursive --force "$W/home/Pictures"; }
run() { env HOME="$W/home" PATH="$W/bin:/usr/bin:/bin" "$@" bash "$SCRIPT" ${ARGS:-}; }

reset; ARGS="" run --unset=DISPLAY
check "plain capture saves one file" 1 "$(shots)"
check "plain capture copies the raw pixels" "wl-copy:RAWPIXELS" "$(cat "$LOG")"

reset; ARGS="annotate" run --unset=DISPLAY
check "annotate keeps only the annotated file" 1 "$(shots)"
check "annotate file is the annotated one" yes "$(ls "$W/home/Pictures/Screenshots" | grep --quiet 'annotated' && echo yes || echo no)"
check "annotate copies the annotated image" "wl-copy:ANNOTATED:RAWPIXELS" "$(cat "$LOG")"

# A PATH of only the tools the script needs, so a swappy installed on this machine stays hidden.
mkdir "$W/tools"
for tool in mkdir date jq rm cat head sed tr printf bash sh; do ln --symbolic "$(command -v "$tool")" "$W/tools/$tool"; done
reset; mv "$W/bin/swappy" "$W/swappy.off"
env HOME="$W/home" PATH="$W/bin:$W/tools" bash "$SCRIPT" annotate
mv "$W/swappy.off" "$W/bin/swappy"
check "annotate without swappy falls back to the plain capture" "wl-copy:RAWPIXELS" "$(cat "$LOG")"

exit "$fail"
