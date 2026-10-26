#!/usr/bin/env bash
# Tests for statusbar, the i3bar-protocol status line shared by i3 (X11) and sway (Wayland).
# Run: bash tests/statusbar.test.sh
# Every external tool is a stub and every file the script touches is redirected into a temp dir,
# so no display, network or recording is needed.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../.local/scripts/statusbar"

W=$(mktemp --directory)
trap 'rm --recursive --force "$W"' EXIT
mkdir "$W/bin"
say() { printf '#!/bin/sh\necho "%s"\n' "$2" > "$W/bin/$1"; chmod +x "$W/bin/$1"; }
say i3status I3S
say wl-brightness .WL
say xbrightness .X
for quiet in curl nvidia-smi bluetoothctl; do printf '#!/bin/sh\nexit 0\n' > "$W/bin/$quiet"; chmod +x "$W/bin/$quiet"; done

fail=0
check() {
  local name=$1 want=$2 got=$3
  if [ "$got" = "$want" ]; then echo "ok: $name"; else echo "FAIL: $name: want '$want', got '$got'"; fail=1; fi
}

pid=""
start() { # env assignments...
  : > "$W/out"
  setsid env PATH="$W/bin:$PATH" STATUSBAR_CACHE_DIR="$W/cache" STATUSBAR_POKE_FILE="$W/poke" \
    STATUSBAR_WEATHER_CACHE="$W/weather" STATUSBAR_REC_FILE="$W/rec" "$@" bash "$SCRIPT" > "$W/out" 2>/dev/null &
  pid=$!
  local i
  for i in $(seq 1 40); do [ -s "$W/out" ] && return 0; sleep 0.1; done
  return 1
}
stop() { kill -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null; pid=""; }
first_line() { head --lines=1 "$W/out"; }
has() { case "$(first_line)" in *"$1"*) echo yes ;; *) echo no ;; esac; }

start WAYLAND_DISPLAY=wayland-1;           check "Wayland session shows the wl-brightness level" yes "$(has '🔆 .WL')"
check "Wayland session does not call xbrightness" no "$(has '.X')"; stop
start WAYLAND_DISPLAY=;             check "X11 session shows the xbrightness level" yes "$(has '🔆 .X')"
check "X11 session does not call wl-brightness" no "$(has '.WL')"; stop
start WAYLAND_DISPLAY=;             check "includes the i3status part" yes "$(has 'I3S')"
check "no recording indicator without a pid file" no "$(has 'REC')"; stop

touch "$W/rec"
start WAYLAND_DISPLAY=;             check "recording indicator when xrecord or wl-record is running" yes "$(has 'REC: ●')"; stop
rm "$W/rec"

start WAYLAND_DISPLAY=
touch "$W/poke"; consumed=no
for _ in $(seq 1 40); do [ -e "$W/poke" ] || { consumed=yes; break; }; sleep 0.1; done
check "statusbar-poke triggers an immediate refresh (poke file consumed)" yes "$consumed"; stop

POKE_OUT=$(env STATUSBAR_POKE_FILE="$W/poke2" bash "$HERE/../.local/scripts/statusbar-poke"; [ -e "$W/poke2" ] && echo created)
check "statusbar-poke creates the file statusbar waits on" created "$POKE_OUT"

exit "$fail"
