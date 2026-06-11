#!/usr/bin/env bash
# Tests for tmux-hub. Run: bash tests/tmux-hub.test.sh
# Unit tests source the script as a library; integration tests drive a
# throwaway tmux server on a private socket so the real server is untouched.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../.local/scripts/tmux-hub"

# deterministic predicate config (defaults) and the script on PATH for the
# hub's landing window + the bare `tmux` calls inside run-shell
export XDG_CONFIG_HOME; XDG_CONFIG_HOME=$(mktemp -d)
_scriptdir=$(cd "$(dirname "$SCRIPT")" && pwd); export PATH="$_scriptdir:$PATH"

pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
rc() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want rc=$2 got rc=$3)"; fi; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$2' got '$3')"; fi; }
has()    { if grep -qx -- "$3" <<<"$2"; then ok "$1"; else no "$1 ('$3' not in [$2])"; fi; }
hasnot() { if grep -qx -- "$3" <<<"$2"; then no "$1 ('$3' unexpectedly in [$2])"; else ok "$1"; fi; }

#############################################################################
# UNIT
#############################################################################
# shellcheck source=/dev/null
source "$SCRIPT"

tmh_match "node /home/u/.local/share/claude/cli.js"; rc "match: node claude cli path" 0 $?
tmh_match "/home/qd/.local/bin/claude";               rc "match: bare claude path"     0 $?
tmh_match "dclaude --dangerously-skip";               rc "match: dclaude wrapper"       0 $?
tmh_match "sdai c";                                   rc "match: sdai"                  0 $?
tmh_match "claude";                                   rc "match: bare claude"           0 $?
tmh_match "vim claude-notes.md";                      rc "reject: claude- substring"    1 $?
tmh_match "node server.js";                           rc "reject: plain node"           1 $?
tmh_match "-zsh";                                     rc "reject: login shell"          1 $?
tmh_match "";                                         rc "reject: empty"                1 $?

tmpd=$(mktemp -d)
eq "label: non-repo is basename" "$(basename "$tmpd")" "$(tmh_label "$tmpd")"
git -C "$tmpd" init -q && git -C "$tmpd" symbolic-ref HEAD refs/heads/feature
eq "label: repo is basename@branch" "$(basename "$tmpd")@feature" "$(tmh_label "$tmpd")"
rm -rf "$tmpd"

#############################################################################
# INTEGRATION  (private socket, no user config loaded)
#############################################################################
SOCK="tmuxhubtest-$$"
TM() { tmux -L "$SOCK" "$@"; }
# run the script inside the server (so $TMUX targets THIS server) and block
HUBRUN() { TM run-shell "'$SCRIPT' $* ; tmux wait-for -S tmh"; TM wait-for tmh; }
hub_wins() { TM list-windows -t '=claude-hub' -F '#{?@hub_landing,,#{window_id}}' 2>/dev/null | grep . || true; }

cleanup() { TM kill-server 2>/dev/null || true; rm -rf "$BIN" "$WD" "$WD2"; }
trap cleanup EXIT

BIN=$(mktemp -d); WD=$(mktemp -d); WD2=$(mktemp -d)
printf '#!/bin/sh\nsleep 600\n' >"$BIN/claude"; chmod +x "$BIN/claude"

TM -f /dev/null new-session -d -s work -x 80 -y 24
HUBRUN reconcile
has "hub created with a landing window" "$(TM list-windows -t '=claude-hub' -F '#{@hub_landing}')" "1"

# an agent window gets linked; a plain shell window does not
AW=$(TM new-window -t work -c "$WD" -P -F '#{window_id}' "$BIN/claude")
SW=$(TM new-window -t work -P -F '#{window_id}')
HUBRUN reconcile
has    "agent window linked into hub"     "$(hub_wins)" "$AW"
hasnot "plain shell window not linked"    "$(hub_wins)" "$SW"

# label + home are recorded on the linked window
eq "home session recorded" "work"               "$(TM show -wv -t "$AW" @hub_home)"
eq "label recorded"        "$(basename "$WD")"   "$(TM show -wv -t "$AW" @hub_label)"

# reconcile is idempotent
a=$(hub_wins | sort); HUBRUN reconcile; b=$(hub_wins | sort)
eq "reconcile idempotent" "$a" "$b"

# multi-pane: claude in one pane links the window; when that pane dies the
# window is plain-unlinked from the hub but survives in its home session
MW=$(TM new-window -t work -c "$WD2" -P -F '#{window_id}' "$BIN/claude")
CP=$(TM list-panes -t "$MW" -F '#{pane_id}' | head -1)
TM split-window -t "$MW"
HUBRUN reconcile
has "multi-pane agent window linked" "$(hub_wins)" "$MW"
TM kill-pane -t "$CP"               # agent gone, shell pane remains
HUBRUN reconcile
hasnot "window unlinked after agent exits" "$(hub_wins)" "$MW"
has    "window still alive in home session" "$(TM list-windows -t work -F '#{window_id}')" "$MW"

echo "----"
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
