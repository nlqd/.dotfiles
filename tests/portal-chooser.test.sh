#!/usr/bin/env bash
# Tests for portal-chooser. Run: bash tests/portal-chooser.test.sh
# The menu is a stub that logs each call and "picks" the line named in PICK, so nothing is shown.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../.local/scripts/portal-chooser"

W=$(mktemp --directory)
trap 'rm --recursive --force "$W"' EXIT
mkdir "$W/rt"
CALLS="$W/calls"
printf '#!/bin/sh\ncat >/dev/null\necho x >> "%s"\nprintf "%%s\\n" "$PICK"\n' "$CALLS" > "$W/menu"
chmod +x "$W/menu"

fail=0
check() {
  local name=$1 want=$2 got=$3
  if [ "$got" = "$want" ]; then echo "ok: $name"; else echo "FAIL: $name: want '$want', got '$got'"; fail=1; fi
}
calls() { wc --lines < "$CALLS" | tr --delete ' '; }
reset() { : > "$CALLS"; rm --force "$W/rt/portal-chooser.last"; }
run() { printf '%s\n' "$1" | env XDG_RUNTIME_DIR="$W/rt" PORTAL_CHOOSER_MENU="$W/menu" PICK="${PICK-}" PORTAL_CHOOSER_TTL="${TTL:-60}" bash "$SCRIPT"; }

TWO=$'Monitor: DP-5 Samsung\nWindow: Foo (a)'

reset; PICK="" out=$(run "Monitor: DP-5 Samsung")
check "a single choice is returned without asking" "Monitor: DP-5 Samsung" "$out"
check "a single choice never opens the menu" 0 "$(calls)"

reset; PICK="Window: Foo (a)" out=$(run "$TWO")
check "several choices return the picked line" "Window: Foo (a)" "$out"

reset; PICK="Window: Foo (a)" run "$TWO" >/dev/null; PICK="WRONG" out=$(run "$TWO")
check "a second call reuses the first pick" "Window: Foo (a)" "$out"
check "the second call does not open the menu" 1 "$(calls)"

reset; PICK="Window: Foo (a)" run "$TWO" >/dev/null; PICK="WRONG" out=$(run $'Monitor: DP-5 Samsung\nWindow: Foo renamed (a)')
check "a renamed window is still found by its id" "Window: Foo renamed (a)" "$out"

reset; PICK="Window: Foo (a)" run "$TWO" >/dev/null; TTL=0 PICK="Monitor: DP-5 Samsung" out=$(run "$TWO")
check "an expired pick asks again" "Monitor: DP-5 Samsung" "$out"

reset; PICK="Window: Foo (a)" run "$TWO" >/dev/null; PICK="Monitor: DP-5 Samsung" out=$(run $'Monitor: DP-5 Samsung\nWindow: Bar (b)')
check "a pick that left the list asks again" "Monitor: DP-5 Samsung" "$out"

reset; PICK="" run "$TWO" >/dev/null; echo "exit=$?" > "$W/rc"
check "cancelling the menu fails the chooser" "exit=1" "$(cat "$W/rc")"

exit "$fail"
