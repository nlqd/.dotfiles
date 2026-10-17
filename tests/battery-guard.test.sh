#!/usr/bin/env bash
# Tests for battery-guard. Run: bash tests/battery-guard.test.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../usr/local/sbin/battery-guard"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin" "$WORK/bat"
CALLS="$WORK/calls"
for stub in systemctl logger; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$stub" "$CALLS" > "$WORK/bin/$stub"
    chmod +x "$WORK/bin/$stub"
done

pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$2' got '$3')"; fi; }

# run_guard STATUS CAPACITY -> prints the systemctl calls the guard made
run_guard() {
    : > "$CALLS"
    printf '%s\n' "$1" > "$WORK/bat/status"
    printf '%s\n' "$2" > "$WORK/bat/capacity"
    PATH="$WORK/bin:$PATH" BATTERY_GUARD_BAT="$WORK/bat" sh "$SCRIPT"
    grep '^systemctl' "$CALLS" || true
}

eq "does nothing at 50% on battery"         ""                      "$(run_guard Discharging 50)"
eq "does nothing just above the threshold"  ""                      "$(run_guard Discharging 8)"
eq "hibernates at the threshold"            "systemctl hibernate"   "$(run_guard Discharging 7)"
eq "hibernates below the threshold"         "systemctl hibernate"   "$(run_guard Discharging 4)"
eq "powers off at the last-resort level"    "systemctl poweroff"    "$(run_guard Discharging 3)"
eq "powers off below the last-resort level" "systemctl poweroff"    "$(run_guard Discharging 0)"
eq "ignores a low battery while charging"   ""                      "$(run_guard Charging 2)"
eq "ignores a low battery when not charging (on AC)" ""             "$(run_guard 'Not charging' 5)"

PATH="$WORK/bin:$PATH" BATTERY_GUARD_BAT="$WORK/missing" sh "$SCRIPT"
eq "exits 0 when there is no battery" "0" "$?"

: > "$CALLS"
printf 'Discharging\n' > "$WORK/bat/status"; printf 'garbage\n' > "$WORK/bat/capacity"
PATH="$WORK/bin:$PATH" BATTERY_GUARD_BAT="$WORK/bat" sh "$SCRIPT"
eq "fails fast on an unreadable capacity"    "1" "$?"
eq "takes no power action on bad capacity"   ""  "$(grep '^systemctl' "$CALLS" || true)"

: > "$CALLS"
printf 'Discharging\n' > "$WORK/bat/status"; printf '15\n' > "$WORK/bat/capacity"
eq "thresholds can be overridden" "systemctl hibernate" \
    "$(PATH="$WORK/bin:$PATH" BATTERY_GUARD_BAT="$WORK/bat" BATTERY_GUARD_HIBERNATE_AT=20 sh "$SCRIPT"; grep '^systemctl' "$CALLS")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
