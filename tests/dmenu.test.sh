#!/usr/bin/env bash
# Tests for the dmenu shim. Run: bash tests/dmenu.test.sh
# Stubs both menus, so no display is needed.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SHIM="$HERE/../.local/scripts/dmenu"

W=$(mktemp --directory)
trap 'rm --recursive --force "$W"' EXIT
printf '#!/bin/sh\nprintf "REAL"; for a in "$@"; do printf "|%%s" "$a"; done; printf "\\n"; cat\n' > "$W/real"
printf '#!/bin/sh\nprintf "WMENU"; for a in "$@"; do printf "|%%s" "$a"; done; printf "\\n"; cat\n' > "$W/wmenu"
chmod +x "$W/real" "$W/wmenu"

fail=0
check() {
  local name=$1 want=$2 got=$3
  if [ "$got" = "$want" ]; then echo "ok: $name"; else echo "FAIL: $name: want '$want', got '$got'"; fail=1; fi
}
run() { env DMENU_REAL="$W/real" WMENU="$W/wmenu" "$@"; }

SWAY_FLAGS=(-i -fn "Iosevka NF-16" -nb "#C4C6CD" -nf "#07080D" -sb "#004C63" -sf "#FFFFFF")

check "Wayland: sway's dmenu flags become wmenu flags" \
  "WMENU|-i|-f|Iosevka NF 16|-N|#C4C6CD|-n|#07080D|-S|#004C63|-s|#FFFFFF" \
  "$(run WAYLAND_DISPLAY=wayland-1 sh "$SHIM" "${SWAY_FLAGS[@]}" </dev/null | head --lines=1)"

check "Wayland: font without a size is passed through" \
  "WMENU|-f|JetBrainsMono NF" \
  "$(run WAYLAND_DISPLAY=wayland-1 sh "$SHIM" -fn "JetBrainsMono NF" </dev/null | head --lines=1)"

check "Wayland: prompt and lines are kept, monitor and grab-keyboard dropped" \
  "WMENU|-b|-l|5|-p|run:" \
  "$(run WAYLAND_DISPLAY=wayland-1 sh "$SHIM" -b -f -m 1 -l 5 -p "run:" </dev/null | head --lines=1)"

check "Wayland: stdin choices reach wmenu" \
  "alpha beta" \
  "$(printf 'alpha\nbeta\n' | run WAYLAND_DISPLAY=wayland-1 sh "$SHIM" -i | tail --lines=+2 | tr '\n' ' ' | sed 's/ $//')"

check "X11: real dmenu gets the original arguments untouched" \
  "REAL|-i|-fn|Iosevka NF-16|-nb|#C4C6CD|-nf|#07080D|-sb|#004C63|-sf|#FFFFFF" \
  "$(run WAYLAND_DISPLAY= sh "$SHIM" "${SWAY_FLAGS[@]}" </dev/null | head --lines=1)"

check "Wayland without wmenu falls back to the real dmenu" \
  "REAL|-i" \
  "$(env DMENU_REAL="$W/real" WMENU="$W/missing" WAYLAND_DISPLAY=wayland-1 sh "$SHIM" -i </dev/null | head --lines=1)"

exit "$fail"
