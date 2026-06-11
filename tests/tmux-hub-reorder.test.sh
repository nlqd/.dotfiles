#!/usr/bin/env bash
# Regression: the reorder must rename only the hub's own links. A window linked
# to both the hub and its home session must keep its home link. The earlier bug
# used `move-window -s <window-id>` whose source session is ambiguous; with a
# pre-existing hub tmux resolved it to the HOME link and unlinked the window
# from home, destroying the home session once its last window left.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../.local/scripts/tmux-hub"
export XDG_CONFIG_HOME; XDG_CONFIG_HOME=$(mktemp -d)
_d=$(cd "$(dirname "$SCRIPT")" && pwd); export PATH="$_d:$PATH"

pass=0 fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL - %s\n' "$1"; fail=$((fail+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1"; printf '      want: [%s]\n      got : [%s]\n' "$2" "$3"; fi; }

SOCK="tmhreorder-$$"; TM(){ tmux -L "$SOCK" "$@"; }
RUN(){ TM run-shell "'$SCRIPT' $* ; tmux wait-for -S r"; TM wait-for r; }
cleanup(){ TM kill-server 2>/dev/null; rm -rf "$BIN" "$XDG_CONFIG_HOME"; }
trap cleanup EXIT
BIN=$(mktemp -d); printf '#!/bin/sh\nsleep 600\n' >"$BIN/claude"; chmod +x "$BIN/claude"

# Pre-create the hub (mirrors a live server where claude-hub already exists).
TM -f /dev/null new-session -d -s claude-hub -x 200 -y 50
TM set -g base-index 1; TM set -g pane-base-index 1
TM set -t claude-hub @is_hub 1

# A project session with two agent windows.
TM new-session -d -s proj -x 120 -y 40
WA=$(TM new-window -t proj -n a1 -P -F '#{window_id}' "$BIN/claude")
WB=$(TM new-window -t proj -n a2 -P -F '#{window_id}' "$BIN/claude")
sleep 0.3

RUN reconcile

# both agents now live in the hub AND remain in proj (two links each)
eq "a1 linked to proj and hub" "2" "$(TM list-windows -a -F '#{window_id}' | grep -cF "$WA")"
eq "a2 linked to proj and hub" "2" "$(TM list-windows -a -F '#{window_id}' | grep -cF "$WB")"
eq "proj keeps both agent windows" "a1 a2" \
   "$(TM list-windows -t proj -F '#{window_name}' | grep -E '^a[12]$' | paste -sd' ' -)"
eq "proj still alive" "yes" "$(TM has-session -t proj 2>/dev/null && echo yes || echo no)"
# no stale parked links left behind in the hub (the old bug left dup links at 1001+)
eq "no parked links remain" "" \
   "$(TM list-windows -t '=claude-hub' -F '#{window_index}' | awk '$1>=1000' | paste -sd' ' -)"

# a second reconcile is a no-op and still leaves home intact
RUN reconcile
eq "proj intact after second reconcile" "a1 a2" \
   "$(TM list-windows -t proj -F '#{window_name}' | grep -E '^a[12]$' | paste -sd' ' -)"

echo "----"; echo "pass=$pass fail=$fail"; [[ $fail -eq 0 ]]
