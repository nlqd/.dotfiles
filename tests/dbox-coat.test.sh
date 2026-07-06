#!/usr/bin/env bash
# Tests for the dbox-lib coat-launch decision (should_enter_coat): the auto vs
# opt-in mode, the --coat / --no-coat overrides, and the sandbox / locality
# guards. Run: bash tests/dbox-coat.test.sh
# should_enter_coat (in the sourced lib) reads DBOX_COAT / DBOX_COAT_FORCE /
# DBOX_NO_COAT; shellcheck can't follow that across the non-constant source, so it
# reports them unused and can't check the source. Both are expected here.
# shellcheck disable=SC1090,SC2034
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LIB="$HERE/../.local/scripts/dbox-lib.sh"

pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
rc() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want rc=$2 got rc=$3)"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$2' got '$3')"; fi; }

# Sourcing the lib must define its functions and NOT execute anything (it is a
# function library; dclaude-jen sources it then drives it).
source "$LIB"
ok "sourcing dbox-lib did not run main"

# Dependency-injection: override the three things should_enter_coat touches so the
# decision is exercised in isolation, with no real podman/workit/coat. Scenario
# knobs: SANDBOX, COAT_EXISTS, UP_OK, PID_VAL.
SANDBOX=0 COAT_EXISTS=1 UP_OK=1 PID_VAL=$$
_dbox_in_sandbox() { [ "$SANDBOX" = 1 ]; }
workit() {
    case "$1" in
        name) printf 'workit-testbranch\n' ;;
        up) [ "$UP_OK" = 1 ] ;;
        pid) printf '%s\n' "$PID_VAL" ;;
        *) return 0 ;;
    esac
}
podman() { case "$1 $2" in "pod exists") [ "$COAT_EXISTS" = 1 ] ;; *) return 0 ;; esac; }

reset() {
    SANDBOX=0 COAT_EXISTS=1 UP_OK=1 PID_VAL=$$
    unset DBOX_COAT DBOX_COAT_FORCE DBOX_NO_COAT
}
run() { OUT=$(should_enter_coat 2>/dev/null); RC=$?; }

# PID_VAL=$$ means /proc/$$ exists -> "local"; a huge pid means it does not.

# auto (default): enter when a coat already exists, and hand back its name
reset
run
rc "auto: enters when a coat exists" 0 "$RC"
eq "auto: echoes the coat name" "workit-testbranch" "$OUT"

# auto: no coat -> normal launch (do not create one just because you launched)
reset
COAT_EXISTS=0
run
rc "auto: skips when no coat exists" 1 "$RC"

# opt-in (DBOX_COAT=off): an existing coat is NOT entered without --coat
reset
DBOX_COAT=off
run
rc "off: skips an existing coat without --coat" 1 "$RC"

# opt-in + --coat: force enter, creating the coat even if none pre-existed
reset
DBOX_COAT=off DBOX_COAT_FORCE=1 COAT_EXISTS=0
run
rc "off + --coat: enters (force, creates)" 0 "$RC"
eq "off + --coat: echoes name" "workit-testbranch" "$OUT"

# --no-coat wins over --coat (safe skip when both are given)
reset
DBOX_COAT_FORCE=1 DBOX_NO_COAT=1
run
rc "--no-coat overrides --coat" 1 "$RC"

# inside a sandbox: never enter a host coat, even with --coat
reset
SANDBOX=1 DBOX_COAT_FORCE=1
run
rc "sandbox: never enters even with --coat" 1 "$RC"

# coat's infra pid is not in this pid ns (runs elsewhere) -> skip
reset
PID_VAL=999999999
run
rc "non-local infra pid: skips" 1 "$RC"

# coat exists but it won't start -> skip, and say so on stderr (not silent)
reset
UP_OK=0
ERR=$(should_enter_coat 2>&1 >/dev/null)
RC=$?
rc "up refused: skips" 1 "$RC"
if grep -q 'could not start coat' <<<"$ERR"; then ok "up refused: warns on stderr"; else no "up refused: warns on stderr (no diagnostic)"; fi

# a falsey synonym (DBOX_COAT=false) opts out just like "off"
reset
DBOX_COAT=false
run
rc "off synonym (false): skips an existing coat" 1 "$RC"

# an UNRECOGNIZED DBOX_COAT is not silently treated as off (which would do the
# opposite of a mistyped opt-out): it warns and falls through to auto
reset
DBOX_COAT=bogus
ERR=$(should_enter_coat 2>&1 >/dev/null)
run
rc "unrecognized DBOX_COAT: treated as auto (enters)" 0 "$RC"
if grep -q 'unrecognized DBOX_COAT' <<<"$ERR"; then ok "unrecognized DBOX_COAT: warns"; else no "unrecognized DBOX_COAT: warns (no diagnostic)"; fi

# --coat that provisions a brand-new coat announces the create (accidental --coat
# in the wrong directory shouldn't spawn a pod silently)
reset
DBOX_COAT_FORCE=1 COAT_EXISTS=0
ERR=$(should_enter_coat 2>&1 >/dev/null)
if grep -q 'created coat' <<<"$ERR"; then ok "--coat creating a new coat announces it"; else no "--coat create announce (missing)"; fi

# tool-presence gate: if podman isn't resolvable, skip BEFORE any coat work. This
# has to be pinned carefully. Unsetting BOTH stubs (the obvious way) does NOT test
# the gate: with workit also gone, the later `cn=$(workit name)` returns 1 too, so
# the case passes even with the gate deleted. Instead keep workit resolvable (stub)
# and force mode ON, so the ONLY line that can return 1 is the missing-podman gate:
# unset just podman + empty PATH make `command -v podman` truly fail. Verified: with
# the gate the rc is 1; delete the gate and the force path runs on the workit stub
# alone and returns 0. So this case regresses to a failure if the gate is removed.
reset
DBOX_COAT_FORCE=1
# shellcheck disable=SC2123  # emptying PATH in this subshell is the point of the test
(unset -f podman; PATH=""; should_enter_coat) >/dev/null 2>&1
RC=$?
rc "podman unresolvable (force mode): skips at the tool gate" 1 "$RC"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
