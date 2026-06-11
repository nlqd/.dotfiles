#!/usr/bin/env bash
# gather/scatter round-trip tests on a throwaway tmux server.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../.local/scripts/tmux-hub"
export XDG_CONFIG_HOME; XDG_CONFIG_HOME=$(mktemp -d)
_d=$(cd "$(dirname "$SCRIPT")" && pwd); export PATH="$_d:$PATH"

pass=0 fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL - %s\n' "$1"; fail=$((fail+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1"; printf '      want: %s\n      got : %s\n' "$2" "$3"; fi; }
has(){ if grep -qxF -- "$3" <<<"$2"; then ok "$1"; else no "$1 ('$3' missing)"; fi; }
hasnot(){ if grep -qxF -- "$3" <<<"$2"; then no "$1 ('$3' should be gone)"; else ok "$1"; fi; }

SOCK="tmhgather-$$"; TM(){ tmux -L "$SOCK" "$@"; }
RUN(){ TM run-shell "'$SCRIPT' $* ; tmux wait-for -S g"; TM wait-for g; }
cleanup(){ TM kill-server 2>/dev/null; rm -rf "$BIN" "$XDG_CONFIG_HOME"; }
trap cleanup EXIT
BIN=$(mktemp -d); printf '#!/bin/sh\nsleep 600\n' >"$BIN/claude"; chmod +x "$BIN/claude"
agents(){ pgrep -fc "$BIN/claude" 2>/dev/null || echo 0; }    # count live fake agents

TM -f /dev/null new-session -d -s proj -x 120 -y 40
TM set -g base-index 1; TM set -g pane-base-index 1           # mirror the real config
TM rename-window -t proj:0 plain                              # window 0: no claude
TM new-window -t proj -n w-a "$BIN/claude"
WB=$(TM new-window -t proj -n w-b -P -F '#{window_id}' "$BIN/claude")
WB_CLAUDE=$(TM list-panes -t "$WB" -F '#{pane_id}')          # single pane = claude
TM split-window -h -t "$WB"                                  # w-b also gets a shell pane
TM select-pane -t "$WB_CLAUDE" -T "claude-B-title"
TM new-window -t proj -n w-c "$BIN/claude"

sleep 0.3
n_before=$(agents)
before=$(TM list-windows -t proj -F '#{window_index} #{window_name} #{window_layout}')

# === gather ===
RUN gather proj
gv=$(TM list-windows -t proj -F '#{?@gather_view,#{window_id},}' | grep . || true)
{ [[ -n $gv ]] && ok "gather created a view window"; } || no "gather created a view window"
eq "view holds all 3 claude panes" "3" "$(TM list-panes -t "$gv" 2>/dev/null | wc -l | tr -d ' ')"
g_wins=$(TM list-windows -t proj -F '#{window_name}')
hasnot "single-claude w-a is gone"   "$g_wins" "w-a"
hasnot "single-claude w-c is gone"   "$g_wins" "w-c"
has    "mixed w-b survives"           "$g_wins" "w-b"
has    "plain window untouched"       "$g_wins" "plain"
hasnot "view NOT aggregated into the hub" "$(TM list-windows -t '=claude-hub' -F '#{window_id}' 2>/dev/null)" "$gv"

# === scatter (toggle) ===
RUN gather proj
after=$(TM list-windows -t proj -F '#{window_index} #{window_name} #{window_layout}')
eq "no agents killed by scatter" "$n_before" "$(agents)"
eq "scatter restores index+name+layout exactly" "$before" "$after"
eq "no gather view remains" "0" "$(TM list-windows -t proj -F '#{?@gather_view,V,}' | grep -c V || true)"
has "claude-B-title restored on its pane" "$(TM list-panes -s -t proj -F '#{pane_title}')" "claude-B-title"

# === refuse in the hub ===
TM new-session -d -s claude-hub; TM set -t claude-hub @is_hub 1
RUN gather claude-hub
eq "gather refuses inside claude-hub" "0" "$(TM list-windows -t claude-hub -F '#{?@gather_view,V,}' | grep -c V || true)"

echo "----"; echo "pass=$pass fail=$fail"; [[ $fail -eq 0 ]]
