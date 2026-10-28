#!/usr/bin/env bash
# Tests for hostrelay's server side against a box that plants symlinks in its own writable dirs.
# Run: bash tests/hostrelay-symlink.test.sh
# The "victim" files stand for anything on the host that a relayed binary must never overwrite.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../.local/scripts/hostrelay"

W=$(mktemp --directory)
SERVER=""
trap '[[ -n "$SERVER" ]] && kill -TERM "$SERVER" 2>/dev/null; rm --recursive --force "$W"' EXIT

printf '#!/bin/sh\necho "relayed $*"\n' >"$W/tool"
chmod +x "$W/tool"

export HOSTRELAY_ROOT="$W/root"
mkdir --parents "$W/root"
bash "$SCRIPT" serve t "$W/tool" 2>/dev/null &
SERVER=$!

D="$W/root/t"
until [[ -e "$D/heartbeat" ]]; do sleep 0.1; done

fail=0
check() {
  local name=$1 want=$2 got=$3
  if [[ "$got" == "$want" ]]; then echo "ok: $name"; else echo "FAIL: $name: want '$want', got '$got'"; fail=1; fi
}
wait_for() { local i; for i in $(seq 1 100); do [[ -e "$1" ]] && return 0; sleep 0.1; done; return 1; }
send() { # dir id json: drop a request the way the client does, atomically
  printf '%s' "$3" >"$1/requests/$2.json.tmp"
  mv "$1/requests/$2.json.tmp" "$1/requests/$2.json"
}

out=$(bash "$SCRIPT" call t -- hi there)
check "a normal call returns the relayed output" "relayed hi there" "$out"

printf KEEP >"$W/victim-out"
printf KEEP >"$W/victim-err"
ln --symbolic "$W/victim-out" "$D/responses/aaa.stdout"
ln --symbolic "$W/victim-err" "$D/responses/aaa.stderr"
send "$D" aaa '{"argv":["x"]}'
wait_for "$D/responses/aaa.rc"
check "a planted .stdout symlink is not written through" KEEP "$(cat "$W/victim-out")"
check "a planted .stderr symlink is not written through" KEEP "$(cat "$W/victim-err")"

printf KEEP >"$W/victim-rc"
ln --symbolic "$W/victim-rc" "$D/responses/bbb.rc.tmp"
send "$D" bbb '{"argv":"not-an-array"}'
wait_for "$D/responses/bbb.rc"
check "a planted .rc.tmp symlink is not written through" KEEP "$(cat "$W/victim-rc")"
check "the bad request still gets a failing rc" 1 "$(cat "$D/responses/bbb.rc")"

mkdir --parents "$D/boxes/b1/requests" "$W/decoy"
ln --symbolic "$W/decoy" "$D/boxes/b1/responses"
send "$D/boxes/b1" ccc '{"argv":["x"]}'
sleep 1.5
check "a responses/ symlink is not served into" 0 "$(find "$W/decoy" -type f | wc --lines)"
check "a box with a symlinked dir keeps its request unclaimed" yes "$([[ -e $D/boxes/b1/requests/ccc.json ]] && echo yes || echo no)"

exit "$fail"
