#!/usr/bin/env bash
# Tests for wl-session. Run: bash tests/wl-session.test.sh
# swaymsg, foot, the browsers and sleep are stubs, /proc is a fake tree, HOME is a temp dir:
# no compositor and no real window is involved.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../.local/scripts/wl-session"

W=$(mktemp --directory)
trap 'rm --recursive --force "$W"' EXIT
mkdir --parents "$W/stubs" "$W/tools" "$W/home" "$W/dir" "$W/proc/100/task/100" "$W/proc/101/task/101" "$W/proc/102"
SWLOG="$W/swaymsg.log"
APPLOG="$W/apps.log"
STATE="$W/state/layout.json"

TREE_FILE="$W/tree.json"
WS_FILE="$W/workspaces.json"
cat >"$W/tree-full.json" <<'JSON'
{"type":"root","nodes":[{"type":"output","name":"DP-5","nodes":[
 {"type":"workspace","name":"1","nodes":[
   {"type":"con","id":11,"pid":100,"app_id":"foot","name":"~/dev","nodes":[],"floating_nodes":[]},
   {"type":"con","id":12,"pid":200,"app_id":"google-chrome","name":"Blog - Google Chrome","nodes":[],"floating_nodes":[]}],"floating_nodes":[]},
 {"type":"workspace","name":"2","nodes":[
   {"type":"con","id":21,"pid":300,"app_id":"pavucontrol","name":"Volume","nodes":[],"floating_nodes":[]},
   {"type":"con","id":22,"pid":400,"app_id":"firefox","name":"Mozilla Firefox","nodes":[],"floating_nodes":[]}],"floating_nodes":[]},
 {"type":"workspace","name":"__i3_scratch","nodes":[],"floating_nodes":[{"type":"floating_con","id":31,"pid":500,"app_id":"foot","name":"hidden","nodes":[]}]}
]}]}
JSON
echo '{"type":"root","nodes":[{"type":"output","name":"DP-5","nodes":[{"type":"workspace","name":"1","nodes":[],"floating_nodes":[]}]}]}' >"$W/tree-empty.json"
echo '[{"name":"1","focused":false},{"name":"2","focused":true}]' >"$WS_FILE"

# the first child of the foot process (pid 100) is a shell sitting in $W/dir, running a tmux client (102)
echo 101 >"$W/proc/100/task/100/children"
echo 102 >"$W/proc/101/task/101/children"
ln --symbolic "$W/dir" "$W/proc/101/cwd"
printf 'tmux\0-2\0a\0' >"$W/proc/102/cmdline"

cat >"$W/stubs/swaymsg" <<EOF
#!/bin/sh
case "\$*" in
  *get_tree*) cat "$TREE_FILE" ;;
  *get_workspaces*) cat "$WS_FILE" ;;
  *) echo "\$*" >> "$SWLOG" ;;
esac
EOF
for app in foot google-chrome firefox; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$app" "$APPLOG" >"$W/stubs/$app"
done
printf '#!/bin/sh\nexit 0\n' >"$W/stubs/sleep"
printf '#!/bin/sh\necho "102 work"\n' >"$W/stubs/tmux"
chmod +x "$W/stubs"/*
# only what the script needs, so the real foot and browsers on this machine stay hidden
for tool in bash jq cut readlink mkdir mv dirname setsid cat tr; do ln --symbolic "$(command -v "$tool")" "$W/tools/$tool"; done

fail=0
check() {
  local name=$1 want=$2 got=$3
  if [ "$got" = "$want" ]; then echo "ok: $name"; else echo "FAIL: $name: want '$want', got '$got'"; fail=1; fi
}
reset() { : >"$SWLOG"; : >"$APPLOG"; rm --recursive --force "$W/state"; cp "$W/tree-full.json" "$TREE_FILE"; }
run() { env PATH="$W/stubs:$W/tools" HOME="$W/home" WL_SESSION_STATE="$STATE" WL_SESSION_PROC="$W/proc" WL_SESSION_TICKS=2 bash "$SCRIPT" "$@"; }
settle() { local i; for i in $(seq 1 30); do [ "$(wc --lines <"$APPLOG")" -ge "$1" ] && return; sleep 0.1; done; }
saved() { jq --raw-output "$1" "$STATE"; }

reset; run save
check "save keeps only foot, chrome and firefox windows" "foot,google-chrome,firefox" "$(saved '[.windows[].app_id] | join(",")')"
check "save ignores the scratchpad" 3 "$(saved '.windows | length')"
check "save records each window's workspace" "1,1,2" "$(saved '[.windows[].workspace] | join(",")')"
check "save records the focused workspace" 2 "$(saved .focused_workspace)"
check "save records a foot window's working directory" "$W/dir" "$(saved '.windows[0].cwd')"
check "save adds no working directory to a browser" null "$(saved '.windows[1].cwd')"
check "save records the tmux session a foot window shows" work "$(saved '.windows[0].tmux_session')"
check "save adds no tmux session to a browser" null "$(saved '.windows[1].tmux_session')"

cp "$STATE" "$W/before.json"
cp "$W/tree-empty.json" "$TREE_FILE"
run save
check "save with no windows keeps the old file" "$(cat "$W/before.json")" "$(cat "$STATE")"

reset
mkdir --parents "$W/state"
cat >"$STATE" <<JSON
{"focused_workspace":"2","windows":[
 {"app_id":"foot","workspace":"1","title":"x","cwd":"$W/dir"},
 {"app_id":"foot","workspace":"3","title":"y"},
 {"app_id":"foot","workspace":"6","title":"z","cwd":"$W/dir","tmux_session":"work"},
 {"app_id":"google-chrome","workspace":"4","title":"Blog - Google Chrome"},
 {"app_id":"firefox","workspace":"5","title":"Mozilla Firefox"}]}
JSON
run restore
settle 5
check "restore opens a foot window in its saved directory" yes "$(grep --quiet --fixed-strings "foot --working-directory=$W/dir" "$APPLOG" && echo yes || echo no)"
check "restore opens a foot window without a directory plainly" 1 "$(grep --count --line-regexp 'foot ' "$APPLOG")"
check "restore reattaches a tmux window to its session" yes "$(grep --quiet --fixed-strings 'sh work' "$APPLOG" && grep --quiet --fixed-strings 'foot sh -c' "$APPLOG" && echo yes || echo no)"
check "restore starts chrome once, restoring its session" 1 "$(grep --count --fixed-strings 'google-chrome --restore-last-session' "$APPLOG")"
check "restore starts firefox once" 1 "$(grep --count --line-regexp 'firefox ' "$APPLOG")"
check "restore moves a restored chrome window by its title" yes "$(grep --quiet --fixed-strings '[con_id=12] move container to workspace "4"' "$SWLOG" && echo yes || echo no)"
check "restore moves a restored firefox window by its title" yes "$(grep --quiet --fixed-strings '[con_id=22] move container to workspace "5"' "$SWLOG" && echo yes || echo no)"
check "restore goes to each foot window's workspace first" 'workspace "1"' "$(sed --quiet 1p "$SWLOG")"
check "restore ends on the saved focused workspace" 'workspace "2"' "$(tail --lines=1 "$SWLOG")"

reset
run restore
check "restore with no saved state launches nothing" 0 "$(wc --lines <"$APPLOG" | tr --delete ' ')"

run bogus 2>/dev/null
check "an unknown mode is a usage error" 2 "$?"

exit "$fail"
