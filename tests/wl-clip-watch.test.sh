#!/usr/bin/env bash
# Tests for wl-clip-watch. Run: bash tests/wl-clip-watch.test.sh
# pgrep, setsid and wl-paste are stubs: no clipboard and no real process is involved.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../.local/scripts/wl-clip-watch"

W=$(mktemp --directory)
trap 'rm --recursive --force "$W"' EXIT
mkdir --parents "$W/stubs" "$W/tools"
STARTED="$W/started.log"
RUNNING="$W/running.txt"

# pgrep finds a watcher when its exact command line is listed in $RUNNING
cat >"$W/stubs/pgrep" <<EOF
#!/bin/sh
for a in "\$@"; do last=\$a; done
grep --quiet --fixed-strings --line-regexp -- "\$last" "$RUNNING"
EOF
printf '#!/bin/sh\nexec "$@"\n' >"$W/stubs/setsid"
printf '#!/bin/sh\necho "wl-paste $*" >>"%s"\n' "$STARTED" >"$W/stubs/wl-paste"
printf '#!/bin/sh\n' >"$W/stubs/cliphist"
chmod +x "$W"/stubs/*
for tool in bash env grep; do ln --symbolic "$(command -v "$tool")" "$W/tools/$tool"; done

FAILED=0
check() { # name, expected started lines
  local name="$1" want="$2" got
  sleep 0.2
  got=$(sort "$STARTED" 2>/dev/null)
  if [[ "$got" == "$(sort <<<"$want")" ]]; then echo "ok   $name"; else echo "FAIL $name"; echo "  want: $want"; echo "  got:  $got"; FAILED=1; fi
}
run() { : >"$STARTED"; PATH="$W/stubs:$W/tools" bash "$SCRIPT"; }

: >"$RUNNING"
run
check "starts both watchers when none runs" "wl-paste --type image --watch cliphist store
wl-paste --type text --watch cliphist store"

echo "wl-paste --type text --watch cliphist store" >"$RUNNING"
run
check "starts only the image watcher when text runs" "wl-paste --type image --watch cliphist store"

echo "wl-paste --type image --watch cliphist store" >"$RUNNING"
run
check "starts only the text watcher when image runs" "wl-paste --type text --watch cliphist store"

printf 'wl-paste --type text --watch cliphist store\nwl-paste --type image --watch cliphist store\n' >"$RUNNING"
run
check "starts nothing when both run" ""

: >"$RUNNING"
rm "$W/stubs/cliphist"
run
check "starts nothing without cliphist" ""

exit "$FAILED"
