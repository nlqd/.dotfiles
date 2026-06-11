#!/usr/bin/env bash
# Hub windows are ordered by (home-session, home-index), contiguously after the
# landing window, and home sessions are left untouched.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../.local/scripts/tmux-hub"
export XDG_CONFIG_HOME; XDG_CONFIG_HOME=$(mktemp -d)
_d=$(cd "$(dirname "$SCRIPT")" && pwd); export PATH="$_d:$PATH"

pass=0 fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL - %s\n' "$1"; fail=$((fail+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1"; printf '      want: [%s]\n      got : [%s]\n' "$2" "$3"; fi; }

SOCK="tmhorder-$$"; TM(){ tmux -L "$SOCK" "$@"; }
RUN(){ TM run-shell "'$SCRIPT' $* ; tmux wait-for -S o"; TM wait-for o; }
cleanup(){ TM kill-server 2>/dev/null; rm -rf "$BIN" "$XDG_CONFIG_HOME"; }
trap cleanup EXIT
BIN=$(mktemp -d); printf '#!/bin/sh\nsleep 600\n' >"$BIN/claude"; chmod +x "$BIN/claude"

# Create sessions out of sorted order (zeta before alpha) so a naive link order
# would be wrong; reorder must group by session name then home index.
TM -f /dev/null new-session -d -s zeta -x 80 -y 24
TM set -g base-index 1; TM set -g pane-base-index 1
TM new-window -t zeta -n z1 "$BIN/claude"
TM new-session -d -s alpha
TM new-window -t alpha -n a1 "$BIN/claude"
TM new-window -t alpha -n a2 "$BIN/claude"
sleep 0.3

RUN reconcile
order=$(TM list-windows -t '=claude-hub' -F '#{?@hub_landing,,#{window_name}}' | grep .)
eq "hub ordered by (session, home-index): a1 a2 z1" $'a1\na2\nz1' "$order"

# indices are contiguous after the landing (no gaps)
idxs=$(TM list-windows -t '=claude-hub' -F '#{window_index}' | paste -sd' ' -)
eq "hub indices contiguous from base-index 1" "1 2 3 4" "$idxs"

# home sessions untouched
eq "alpha still has a1,a2 in place" "a1 a2" "$(TM list-windows -t alpha -F '#{window_name}' | grep -E '^a[12]$' | paste -sd' ' -)"
eq "zeta still has z1" "z1" "$(TM list-windows -t zeta -F '#{window_name}' | grep -E '^z1$')"

echo "----"; echo "pass=$pass fail=$fail"; [[ $fail -eq 0 ]]
