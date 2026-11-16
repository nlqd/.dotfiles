#!/usr/bin/env bash
# Tests for hostrelay. Run: bash tests/hostrelay.test.sh
# Drives the real client and a real server against a throwaway HOSTRELAY_ROOT and
# a small controlled target binary (hr_target.sh, checked in alongside this file).
# No Slack, no network: this tests the relay mechanics in isolation.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HR="$HERE/../.local/scripts/hostrelay"
TARGET="$HERE/hr_target.sh"

W=$(mktemp --directory)
trap 'kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; rm --recursive --force "$W"' EXIT

export HOSTRELAY_ROOT="$W/root"
mkdir --parents "$HOSTRELAY_ROOT"

pass=0 fail=0
check() {
  local name="$1"
  shift
  if "$@"; then
    printf 'ok   - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL - %s\n' "$name"
    fail=$((fail + 1))
  fi
}
contains() { grep --quiet --fixed-strings -- "$2" <<<"$1"; }
lacks() { ! contains "$@"; }
equals() { [[ "$1" == "$2" ]]; }

call() { "$HR" call test -- "$@"; }

start_server() {
  "$HR" serve test "$TARGET" "$@" >"$W/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 50); do
    [[ -f "$HOSTRELAY_ROOT/test/heartbeat" ]] && return 0
    sleep 0.1
  done
  echo "server never became live" >&2
  return 1
}
stop_server() {
  kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
  SERVER_PID=""
}

###
echo "-- no server running"
out=$(call foo 2>&1)
check "no relay dir at all: clear error, not a hang" contains "$out" "is this box wired to one"
mkdir --parents "$HOSTRELAY_ROOT/test/requests"
out=$(call foo 2>&1)
check "relay dir exists but nothing is serving: clear error, not a hang" contains "$out" "no live 'hostrelay serve"
rm --recursive --force "$HOSTRELAY_ROOT/test"

###
echo "-- basic round trip"
start_server || exit 1

out=$(call hello world)
check "argv reaches the target, one per line" equals "$out" $'hello\nworld'

out=$(call 'dangerous; $(whoami) `id` && rm -rf /')
check "shell metacharacters in argv arrive literal, unexecuted" equals "$out" 'dangerous; $(whoami) `id` && rm -rf /'

call exit 42 >/dev/null 2>&1
check "the target's exit code reaches the client" equals "$?" "42"

out=$(call stderr 'careful now' 2>&1 >/dev/null)
check "the target's stderr reaches the client's stderr" contains "$out" "careful now"

###
echo "-- validation and quarantine"
: >"$HOSTRELAY_ROOT/test/requests/notjson.json"
sleep 0.5
check "invalid JSON is quarantined, not executed" [ -f "$HOSTRELAY_ROOT/test/requests/notjson.bad" ]
check "and a response is still written so a caller does not hang" [ -f "$HOSTRELAY_ROOT/test/responses/notjson.rc" ]

echo '{"argv": "not-an-array"}' >"$HOSTRELAY_ROOT/test/requests/badtype.json"
sleep 0.5
check "argv that is not an array is quarantined" [ -f "$HOSTRELAY_ROOT/test/requests/badtype.bad" ]

echo '{"argv": ["ok", 5]}' >"$HOSTRELAY_ROOT/test/requests/badelem.json"
sleep 0.5
check "a non-string argv element is quarantined" [ -f "$HOSTRELAY_ROOT/test/requests/badelem.bad" ]

out=$("$HR" call "../etc" -- x 2>&1)
check "a path-traversal-shaped service name is rejected client-side, before touching any path" contains "$out" "not a valid service name"
check "and nothing was written outside the relay root" [ ! -e "$W/etc" ]

###
echo "-- concurrency: one slow request must not block another"
rm --force "$W/slow-done"
"$HR" call test -- touch-then-sleep "$W/slow-done" 3 >/dev/null 2>&1 &
slow_pid=$!
for _ in $(seq 50); do
  [[ -f "$W/slow-done" ]] && break
  sleep 0.1
done
check "the slow request actually started" [ -f "$W/slow-done" ]
start=$SECONDS
out=$(call quick)
elapsed=$((SECONDS - start))
check "a request submitted while another is still running completes quickly" equals "$out" "quick"
check "and is not stuck waiting behind the slow one" [ "$elapsed" -lt 2 ]
wait "$slow_pid" 2>/dev/null

###
echo "-- .stop: cooperative kill of a backgrounded client"
# bash unconditionally ignores SIGINT for an async (&) job, and a script's own
# trap cannot override that: kill -TERM is the realistic way to stop one (this
# is exactly what happens under `kill <pid>`, whose default signal is TERM).
# Interactive Ctrl-C on a FOREGROUND run is unaffected and uses SIGINT normally,
# not exercised here since this harness always backgrounds the client.
rm --force "$W/stop-marker"
"$HR" call test -- touch-then-sleep "$W/stop-marker" 30 >/dev/null 2>&1 &
client_pid=$!
for _ in $(seq 50); do
  [[ -f "$W/stop-marker" ]] && break
  sleep 0.1
done
check "the long request actually started" [ -f "$W/stop-marker" ]
start=$SECONDS
kill -TERM "$client_pid"
wait "$client_pid" 2>/dev/null
elapsed=$((SECONDS - start))
check "the client exits promptly, not after the full sleep" [ "$elapsed" -lt 15 ]
check "the target process was actually killed, not left running" equals "$(pgrep --full 'touch-then-sleep.*stop-marker' | wc --lines)" "0"

###
echo "-- hard timeout backstop, with and without .stop"
stop_server
start_server --timeout 2
start=$SECONDS
call sleep 20 >/dev/null 2>&1
rc=$?
elapsed=$((SECONDS - start))
check "a wedged command with no .stop is still killed, by the server-side timeout" [ "$elapsed" -lt 10 ]
check "and reports a non-zero exit" [ "$rc" -ne 0 ]

start=$SECONDS
call ignore-term 20 >/dev/null 2>&1
elapsed=$((SECONDS - start))
check "a target that ignores SIGTERM is still killed via the SIGKILL escalation" [ "$elapsed" -lt 10 ]
stop_server

###
echo "-- --long-running gets a different, longer backstop"
start_server --timeout 2 --long-running sleep --long-timeout 20
start=$SECONDS
out=$(call sleep 4)
elapsed=$((SECONDS - start))
check "a verb listed in --long-running is not cut off by the short default timeout" [ "$elapsed" -ge 4 ]
check "and it completes normally" equals "$?" "0"
stop_server

###
echo "-- sweep: never touches a live, unfinished stream; reaps a finished, unread one"
start_server
rm --force "$W/quiet-started"
"$HR" call test -- touch-then-sleep "$W/quiet-started" 6 >/dev/null 2>&1 &
quiet_pid=$!
for _ in $(seq 50); do
  [[ -f "$W/quiet-started" ]] && break
  sleep 0.1
done
stdout_file=$(find "$HOSTRELAY_ROOT/test/responses" -name '*.stdout' | head --lines 1)
check "found the in-flight response file" [ -n "$stdout_file" ]
touch --date '2 hours ago' "$stdout_file"
sleep 1 # let at least one sweep cycle run
check "an in-flight stream (no .rc yet) survives the sweep even when its mtime is old" [ -f "$stdout_file" ]
wait "$quiet_pid" 2>/dev/null

: >"$HOSTRELAY_ROOT/test/responses/finished123.stdout"
: >"$HOSTRELAY_ROOT/test/responses/finished123.stderr"
echo -n "0" >"$HOSTRELAY_ROOT/test/responses/finished123.rc"
touch --date '2 hours ago' "$HOSTRELAY_ROOT/test/responses/finished123.stdout" "$HOSTRELAY_ROOT/test/responses/finished123.stderr" "$HOSTRELAY_ROOT/test/responses/finished123.rc"
sleep 1
check "a finished (.rc present), old, unread response is reaped" [ ! -e "$HOSTRELAY_ROOT/test/responses/finished123.rc" ]
stop_server

###
echo "-- startup recovery of an orphaned .processing request"
mkdir --parents "$HOSTRELAY_ROOT/test/processing" "$HOSTRELAY_ROOT/test/responses"
echo '{"argv": ["recovered"]}' >"$HOSTRELAY_ROOT/test/processing/orphan1.json"
start_server
for _ in $(seq 50); do
  [[ -f "$HOSTRELAY_ROOT/test/responses/orphan1.rc" ]] && break
  sleep 0.1
done
check "a request orphaned by a dead server instance is requeued and answered by the next one" [ -f "$HOSTRELAY_ROOT/test/responses/orphan1.rc" ]
stop_server

###
echo "-- per-box directories: the server watches boxes/*/ too, not just the top level"
mkdir --parents "$HOSTRELAY_ROOT/test/boxes/box-a/requests" "$HOSTRELAY_ROOT/test/boxes/box-a/responses"
start_server
echo '{"argv": ["from-box-a"]}' >"$HOSTRELAY_ROOT/test/boxes/box-a/requests/req1.json.tmp"
mv "$HOSTRELAY_ROOT/test/boxes/box-a/requests/req1.json.tmp" "$HOSTRELAY_ROOT/test/boxes/box-a/requests/req1.json"
for _ in $(seq 50); do
  [[ -f "$HOSTRELAY_ROOT/test/boxes/box-a/responses/req1.rc" ]] && break
  sleep 0.1
done
check "a request placed directly in a box's own directory is picked up" [ -f "$HOSTRELAY_ROOT/test/boxes/box-a/responses/req1.rc" ]
check "and answered in that SAME box's directory, not the top-level one" equals "$(cat "$HOSTRELAY_ROOT/test/boxes/box-a/responses/req1.stdout")" "from-box-a"
for _ in $(seq 50); do
  [[ -f "$HOSTRELAY_ROOT/test/boxes/box-a/heartbeat" ]] && break
  sleep 0.1
done
check "that box's own heartbeat is kept fresh too" [ -f "$HOSTRELAY_ROOT/test/boxes/box-a/heartbeat" ]

###
echo "-- audit log"
: >"$HOSTRELAY_ROOT/test/audit.log"
call audit-me test-argument >/dev/null 2>&1
check "one line per request lands in the audit log" contains "$(cat "$HOSTRELAY_ROOT/test/audit.log")" 'audit-me'
check "with the exact argv" contains "$(cat "$HOSTRELAY_ROOT/test/audit.log")" '["audit-me","test-argument"]'
stop_server

echo
echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
