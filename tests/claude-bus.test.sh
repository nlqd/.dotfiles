#!/usr/bin/env bash
# Tests for claude-bus. Run: bash tests/claude-bus.test.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../.claude/skills/claude-bus/claude-bus"
BASH_BIN="$(command -v bash)"

export CLAUDE_BUS_ROOT; CLAUDE_BUS_ROOT=$(mktemp -d)
trap 'rm -rf "$CLAUDE_BUS_ROOT"' EXIT
BUS() { CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" bash "$SCRIPT" "$@"; }

pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
rc() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want rc=$2 got rc=$3)"; fi; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$2' got '$3')"; fi; }
has() { if grep -q -- "$3" <<<"$2"; then ok "$1"; else no "$1 ('$3' not in [$2])"; fi; }
hasnot() { if grep -q -- "$3" <<<"$2"; then no "$1 ('$3' unexpectedly in [$2])"; else ok "$1"; fi; }
nmsg() { find "$1" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l; }

#############################################################################
# TASK 1: sourceable + guards
#############################################################################
# UNIT: sourcing must define helpers and must NOT execute main (if it did, main
# with no args would `exit 2` and kill this test script before the next line).
source "$SCRIPT"
ok "sourcing did not execute main"
has "inbox_dir builds a path"   "$(inbox_dir S1)"   "/inbox/S1"
has "pending_dir builds a path" "$(pending_dir S1)" "/pending/S1"
eq  "gen_id has ns-rand shape"  "0" "$([[ "$(gen_id)" =~ ^[0-9]+-[0-9]+$ ]]; echo $?)"

# GUARD: bad names are rejected before any path is built (via init, the command
# wired to valid_name in this task; send/publish/dispatch get it in later tasks).
BUS init "../etc/x"; rc "init rejects traversal name" 7 $?
BUS init "bad name"; rc "init rejects spaces in name" 7 $?

# GUARD: jq absence is a hard, early failure (not silent corruption)
env -i PATH=/nonexistent "$BASH_BIN" "$SCRIPT" send a b c; rc "exits 1 without jq" 1 $?

# PROGRESSIVE DISCLOSURE: commands guide the next step via stderr; stdout stays clean
has    "init hints next step (stderr)" "$(BUS init Z 2>&1 >/dev/null)" "wait"
hasnot "init keeps stdout clean"       "$(BUS init Z2 2>/dev/null)"    "next:"

#############################################################################
# TASK 2: JSON envelope
#############################################################################
BUS init S1 >/dev/null; BUS init S2 >/dev/null
BUS send S1 S2 "hello world" >/dev/null
msgs=("$CLAUDE_BUS_ROOT"/inbox/S1/*.msg); eq "one message queued" "1" "${#msgs[@]}"; f="${msgs[0]}"
eq "envelope is valid json" "0" "$(jq empty "$f" >/dev/null 2>&1; echo $?)"
eq "envelope from" "S2" "$(jq -r .from "$f")"
eq "envelope kind" "msg" "$(jq -r .kind "$f")"
eq "envelope body" "hello world" "$(jq -r .body "$f")"
eq "id equals ts"  "$(jq -r .ts "$f")" "$(jq -r .id "$f")"
has "drain prints body" "$(BUS drain S1)" "hello world"
# send rejects bad names (guard wired into send/publish this task)
BUS send "../x" S2 hi; rc "send rejects traversal in peer" 7 $?
# malformed envelope is quarantined, not fatal, and does not wedge the inbox
printf 'not json' > "$CLAUDE_BUS_ROOT/inbox/S1/999.from-X.msg"
BUS drain S1 >/dev/null 2>&1; rc "drain survives a malformed file" 0 $?
eq "malformed file quarantined" "1" "$(ls "$CLAUDE_BUS_ROOT"/inbox/S1/*.bad 2>/dev/null | wc -l)"
# progressive disclosure on send (stderr)
has "send hints next step (stderr)" "$(BUS send S1 S2 hi 2>&1 >/dev/null)" "drain"

#############################################################################
# TASK 3: auto-ack on drain
#############################################################################
BUS init A >/dev/null; BUS init B >/dev/null
BUS send B A "do the thing" >/dev/null
mids=("$CLAUDE_BUS_ROOT"/inbox/B/*.msg); mid="$(jq -r .id "${mids[0]}")"
keepb="$CLAUDE_BUS_ROOT/inbox/B/.keep"; before="$(stat -c %Y "$keepb")"
BUS drain B >/dev/null
acks=("$CLAUDE_BUS_ROOT"/inbox/A/*.msg)
eq "B's drain produced one ack for A" "1" "${#acks[@]}"
eq "ack kind" "ack" "$(jq -r .kind "${acks[0]}")"
eq "ack references original id (ref)" "$mid" "$(jq -r .ref "${acks[0]}")"
eq "drain deposits nothing in B's own inbox" "0" "$(ls "$CLAUDE_BUS_ROOT"/inbox/B/*.msg 2>/dev/null | wc -l)"
eq "drain leaves .keep untouched" "$before" "$(stat -c %Y "$keepb")"
# draining the ack must NOT create a new ack back to B (no ack-of-ack)
BUS drain A >/dev/null
eq "no ack-of-ack" "0" "$(ls "$CLAUDE_BUS_ROOT"/inbox/B/*.msg 2>/dev/null | wc -l)"

#############################################################################
# TASK 4: dispatch opens pending
#############################################################################
BUS init ORCH >/dev/null; BUS init W1 >/dev/null
did=$(BUS dispatch W1 ORCH "build module X" 2>/dev/null)
pf="$CLAUDE_BUS_ROOT/pending/ORCH/$did.json"
eq "dispatch wrote a pending file" "0" "$([ -f "$pf" ]; echo $?)"
eq "pending peer"     "W1"   "$(jq -r .peer "$pf")"
eq "pending state"    "sent" "$(jq -r .state "$pf")"
eq "worker got the task" "1" "$(ls "$CLAUDE_BUS_ROOT"/inbox/W1/*.msg | wc -l)"
has "pending lists it" "$(BUS pending ORCH)" "$did W1 sent"
# dispatch obeys the size cap (regression: it used to bypass it)
big=$(head -c 2000 /dev/zero | tr '\0' x)
BUS dispatch W1 ORCH "$big"; rc "dispatch enforces size cap" 3 $?

#############################################################################
# TASK 5: drain resolves; reply + close
#############################################################################
BUS init O2 >/dev/null; BUS init W2 >/dev/null
tid=$(BUS dispatch W2 O2 "task" 2>/dev/null)
pf="$CLAUDE_BUS_ROOT/pending/O2/$tid.json"
BUS drain W2 >/dev/null      # worker receives + auto-acks
BUS drain O2 >/dev/null      # orch drains the ack -> acked
eq "acked keeps it open" "acked" "$(jq -r .state "$pf")"
# progress is a no-op on state
BUS reply O2 W2 "$tid" progress "halfway" >/dev/null; BUS drain O2 >/dev/null
eq "progress leaves state acked" "acked" "$(jq -r .state "$pf")"
# decision -> awaiting_orch, still open (NOT closed)
BUS reply O2 W2 "$tid" decision "need creds" >/dev/null; BUS drain O2 >/dev/null
eq "decision -> awaiting_orch" "awaiting_orch" "$(jq -r .state "$pf")"
eq "awaiting_orch still open" "0" "$([ -f "$pf" ]; echo $?)"
# explicit close removes it
BUS close O2 "$tid"
eq "close removes pending" "1" "$([ -f "$pf" ]; echo $?)"
# separate flow: done closes directly
t2=$(BUS dispatch W2 O2 "task2" 2>/dev/null); p2="$CLAUDE_BUS_ROOT/pending/O2/$t2.json"
BUS reply O2 W2 "$t2" done "finished" >/dev/null; BUS drain O2 >/dev/null
eq "done closes expectation" "1" "$([ -f "$p2" ]; echo $?)"
has "reply prints id" "$(BUS reply O2 W2 "$t2" progress hi 2>/dev/null)" "$t2"

#############################################################################
# S2-1: meta registration
#############################################################################
BUS init M1 >/dev/null
BUS register M1 --cgroup /user.slice/test.scope --pid 4242 --transcript /tmp/t.jsonl >/dev/null
mf="$CLAUDE_BUS_ROOT/meta/M1.json"
eq "register wrote meta"  "0"  "$([ -f "$mf" ]; echo $?)"
eq "meta cgroup"          "/user.slice/test.scope" "$(jq -r .cgroup "$mf")"
eq "meta pid"             "4242" "$(jq -r .pid "$mf")"
eq "meta transcript"      "/tmp/t.jsonl" "$(jq -r .transcript "$mf")"
BUS register M2 >/dev/null
has "register self-detects cgroup" "$(jq -r .cgroup "$CLAUDE_BUS_ROOT/meta/M2.json")" "/"
has "register hints next step (stderr)" "$(BUS register M3 2>&1 >/dev/null)" "dispatch"

#############################################################################
# S2-2: probe readers
#############################################################################
eq "probe unknown -> not known" "false" "$(BUS probe-snapshot NOPE | jq -r .known)"
if systemd-run --user --version >/dev/null 2>&1 && command -v ss >/dev/null 2>&1; then
  u="cbtest-$$"
  systemd-run --user --unit="$u" -p MemoryMax=256M --quiet -- \
    bash -c 'while true; do curl -s --max-time 4 -o /dev/null https://example.com 2>/dev/null || true; done'
  cg=$(systemctl --user show "$u" -p ControlGroup --value)
  BUS register LIVE --cgroup "$cg" >/dev/null
  snap="$(BUS probe-snapshot LIVE)"
  eq "probe known"      "true" "$(jq -r .known <<<"$snap")"
  eq "probe alive"      "1"    "$(jq -r .alive <<<"$snap")"
  eq "probe oom is 0"   "0"    "$(jq -r .oom   <<<"$snap")"
  eq "probe net is num" "0"    "$([[ "$(jq -r .net <<<"$snap")" =~ ^[0-9]+$ ]]; echo $?)"
  systemctl --user stop "$u" 2>/dev/null; systemctl --user reset-failed "$u" 2>/dev/null
else
  ok "probe live-tree checks skipped (no systemd-run/ss)"
fi

# S2-2b: the readers walk the whole subtree. A coat/bwrap agent puts its procs in
# a child cgroup (podman leaf), leaving the registered scope itself empty; reading
# only the top node would false-fire "dead" every tick.
FAKECG="$CLAUDE_BUS_ROOT/fakecg"
mkdir -p "$FAKECG/user.slice/coat.scope/libpod-abc"
: > "$FAKECG/user.slice/coat.scope/cgroup.procs"                            # scope: internal node, empty
printf '12345\n' > "$FAKECG/user.slice/coat.scope/libpod-abc/cgroup.procs" # procs live in the leaf
printf 'oom_kill 2\n'  > "$FAKECG/user.slice/coat.scope/memory.events"           # hierarchical: top aggregates the subtree
printf 'oom_kill 99\n' > "$FAKECG/user.slice/coat.scope/libpod-abc/memory.events" # must NOT be read (would double-count)
BUS register COATP --cgroup /user.slice/coat.scope >/dev/null
snap="$(CLAUDE_BUS_SYSFS="$FAKECG" BUS probe-snapshot COATP)"
eq "subtree proc -> alive (not false-dead)"    "1" "$(jq -r .alive <<<"$snap")"
eq "oom from hierarchical top node, not child" "2" "$(jq -r .oom   <<<"$snap")"
# a genuinely empty subtree (all leaves drained) still reads dead
mkdir -p "$FAKECG/user.slice/gone.scope/leaf"
: > "$FAKECG/user.slice/gone.scope/cgroup.procs"
: > "$FAKECG/user.slice/gone.scope/leaf/cgroup.procs"
BUS register GONEP --cgroup /user.slice/gone.scope >/dev/null
eq "empty subtree still -> dead" "0" "$(jq -r .alive <<<"$(CLAUDE_BUS_SYSFS="$FAKECG" BUS probe-snapshot GONEP)")"

#############################################################################
# S2-3: pure classifier
#############################################################################
B='{"alive":1,"net":100,"oom":0,"mtime":50}'
eq "working: transcript grew"          "working"  "$(BUS classify "$B" '{"alive":1,"net":100,"oom":0,"mtime":60}')"
eq "retrying: net up, transcript flat" "retrying" "$(BUS classify "$B" '{"alive":1,"net":200,"oom":0,"mtime":50}')"
eq "idle: nothing moved"               "idle"     "$(BUS classify "$B" '{"alive":1,"net":100,"oom":0,"mtime":50}')"
eq "dead: not alive"                   "dead"     "$(BUS classify "$B" '{"alive":0,"net":999,"oom":0,"mtime":99}')"
eq "oom: oom_kill rose"                "oom"      "$(BUS classify "$B" '{"alive":1,"net":100,"oom":1,"mtime":50}')"
eq "unknown: null baseline"            "unknown"  "$(BUS classify "null" '{"alive":1,"net":100,"oom":0,"mtime":50}')"
eq "unknown: peer not known"           "unknown"  "$(BUS classify "$B" '{"alive":0,"net":0,"oom":0,"mtime":0,"known":false}')"

#############################################################################
# S2-4: dispatch captures baseline
#############################################################################
BUS init OB >/dev/null; BUS init WB >/dev/null
BUS register WB --cgroup /user.slice/test.scope >/dev/null
tb=$(BUS dispatch WB OB "task" 2>/dev/null)
pfb="$CLAUDE_BUS_ROOT/pending/OB/$tb.json"
eq "baseline captured (not null)" "true"  "$(jq -r '.baseline != null' "$pfb")"
eq "baseline has net field"       "0"     "$([[ "$(jq -r '.baseline.net' "$pfb")" =~ ^[0-9]+$ ]]; echo $?)"
eq "flat counter starts 0"        "0"     "$(jq -r '.flat' "$pfb")"
eq "alerted starts false"         "false" "$(jq -r '.alerted' "$pfb")"
# unregistered peer -> baseline null (no meta), so the classifier stays 'unknown'.
# Force a non-scope cgroup so init does NOT auto-register WU.
CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" CLAUDE_BUS_SELF_CGROUP=/user.slice bash "$SCRIPT" init WU >/dev/null
tu=$(BUS dispatch WU OB "task" 2>/dev/null)
eq "unregistered peer baseline null" "null" "$(jq -r '.baseline' "$CLAUDE_BUS_ROOT/pending/OB/$tu.json")"

#############################################################################
# S2-5: monitor tick (in-process, stubbed probe)
#############################################################################
source "$SCRIPT"                    # so we can stub probe_snapshot and call the tick
export CLAUDE_BUS_FLAT_MAX=2
mkpend() {                          # <orch> <id> <peer>
  local d="$CLAUDE_BUS_ROOT/pending/$1"; mkdir -p "$d"
  jq -n --arg peer "$3" --arg id "$2" \
    '{peer:$peer,id:$id,sent_ts:$id,state:"acked",baseline:{alive:1,net:100,oom:0,mtime:50},flat:0,alerted:false}' \
    > "$d/$2.json"
}

# dead -> one alert, alerted set, no duplicate on the next tick
BUS init MOND >/dev/null
probe_snapshot() { echo '{"alive":0,"net":100,"oom":0,"mtime":50,"known":true}'; }
mkpend MOND d1 deadpeer
cmd_monitor_tick MOND
eq  "dead -> one alert"       "1"    "$(ls "$CLAUDE_BUS_ROOT"/inbox/MOND/*.msg 2>/dev/null | wc -l)"
has "dead alert says dead"    "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/MOND/*.msg | head -1)")" "dead"
eq  "dead alerted verdict set" "dead" "$(jq -r .alerted "$CLAUDE_BUS_ROOT/pending/MOND/d1.json")"
cmd_monitor_tick MOND
eq  "dead no duplicate alert" "1"    "$(ls "$CLAUDE_BUS_ROOT"/inbox/MOND/*.msg 2>/dev/null | wc -l)"

# idle -> needs FLAT_MAX consecutive ticks before a stall alert
BUS init MONI >/dev/null
probe_snapshot() { echo '{"alive":1,"net":100,"oom":0,"mtime":50,"known":true}'; }
mkpend MONI i1 idlepeer
cmd_monitor_tick MONI
eq  "idle tick1: no alert"   "0" "$(ls "$CLAUDE_BUS_ROOT"/inbox/MONI/*.msg 2>/dev/null | wc -l)"
cmd_monitor_tick MONI
eq  "idle tick2: stall alert" "1" "$(ls "$CLAUDE_BUS_ROOT"/inbox/MONI/*.msg 2>/dev/null | wc -l)"
has "stall alert says stalled" "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/MONI/*.msg | head -1)")" "stalled"

# working -> never alerts
BUS init MONW >/dev/null
probe_snapshot() { echo '{"alive":1,"net":100,"oom":0,"mtime":80,"known":true}'; }
mkpend MONW w1 workingpeer
cmd_monitor_tick MONW
eq "working: no alert" "0" "$(ls "$CLAUDE_BUS_ROOT"/inbox/MONW/*.msg 2>/dev/null | wc -l)"

# awaiting_orch -> liveness suppressed even if the probe would say dead
BUS init MONA >/dev/null
probe_snapshot() { echo '{"alive":0,"net":100,"oom":0,"mtime":50,"known":true}'; }
mkpend MONA a1 awpeer
jq '.state="awaiting_orch"' "$CLAUDE_BUS_ROOT/pending/MONA/a1.json" > "$CLAUDE_BUS_ROOT/aw.$$" \
  && mv "$CLAUDE_BUS_ROOT/aw.$$" "$CLAUDE_BUS_ROOT/pending/MONA/a1.json"
cmd_monitor_tick MONA
eq "awaiting_orch suppresses liveness" "0" "$(ls "$CLAUDE_BUS_ROOT"/inbox/MONA/*.msg 2>/dev/null | wc -l)"

#############################################################################
# S2-6: monitor loop exits cleanly when nothing is pending
#############################################################################
CLAUDE_BUS_TICK=1 timeout 5 bash "$SCRIPT" monitor NOORCH >/dev/null 2>&1
rc "monitor exits when no pending" 0 $?

#############################################################################
# S2-7: init self-registers at startup when in a dedicated scope
#############################################################################
selfinit() { CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" CLAUDE_BUS_SELF_CGROUP="$1" bash "$SCRIPT" init "$2"; }
selfinit /user.slice/foo.scope AR >/dev/null
eq  "init auto-registers in a scope"     "/user.slice/foo.scope" "$(jq -r .cgroup "$CLAUDE_BUS_ROOT/meta/AR.json" 2>/dev/null)"
selfinit /user.slice NS >/dev/null
eq  "init skips register outside a scope" "1" "$([ -f "$CLAUDE_BUS_ROOT/meta/NS.json" ]; echo $?)"
has "init notes not monitorable"          "$(selfinit /user.slice NS2 2>&1 >/dev/null)" "monitorable"
has "init in a scope hints liveness"      "$(selfinit /user.slice/x.scope AR2 2>&1 >/dev/null)" "liveness"

#############################################################################
# S2-8: monitor warns on ack-lateness (message never read), even unregistered
#############################################################################
export CLAUDE_BUS_ACK_MAX=2
mkpend_state() {                    # <orch> <id> <state> <baseline-json> <ticks>
  local d="$CLAUDE_BUS_ROOT/pending/$1"; mkdir -p "$d"
  jq -n --arg id "$2" --arg st "$3" --argjson bl "$4" --argjson tk "$5" \
    '{peer:"w",id:$id,sent_ts:$id,state:$st,baseline:$bl,flat:0,alerted:false,ticks:$tk}' > "$d/$2.json"
}
# unregistered (baseline null) sent expectation -> unacked after ACK_MAX ticks
BUS init MONU >/dev/null
mkpend_state MONU u1 sent null 0
cmd_monitor_tick MONU
eq  "unacked tick1: no alert" "0" "$(ls "$CLAUDE_BUS_ROOT"/inbox/MONU/*.msg 2>/dev/null | wc -l)"
cmd_monitor_tick MONU
eq  "unacked tick2: alert"    "1" "$(ls "$CLAUDE_BUS_ROOT"/inbox/MONU/*.msg 2>/dev/null | wc -l)"
has "alert says unacked" "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/MONU/*.msg | head -1)")" "unacked"
# an acked expectation is never flagged unacked
BUS init MONK >/dev/null
mkpend_state MONK k1 acked null 0
cmd_monitor_tick MONK; cmd_monitor_tick MONK; cmd_monitor_tick MONK
eq  "acked never unacked" "0" "$(ls "$CLAUDE_BUS_ROOT"/inbox/MONK/*.msg 2>/dev/null | wc -l)"
# dead (registered) takes precedence over unacked
BUS init MONDU >/dev/null
mkpend_state MONDU x1 sent '{"alive":1,"net":100,"oom":0,"mtime":50}' 5
probe_snapshot() { echo '{"alive":0,"net":100,"oom":0,"mtime":50,"known":true}'; }
cmd_monitor_tick MONDU
has "dead beats unacked" "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/MONDU/*.msg | head -1)")" "dead"

#############################################################################
# S2-9: wait degrades to polling without entr (no more exit 127)
#############################################################################
# Loud branch assumption: PATH=/usr/bin:/bin must genuinely hide entr for these to
# exercise the poll fallback (else they'd silently test the entr path and pass).
if PATH=/usr/bin:/bin command -v entr >/dev/null 2>&1; then
  ok "S2-9 poll-fallback tests skipped (entr visible on minimal PATH)"
else
  # no entr + no mail: wait must BLOCK (poll) so timeout kills it (rc 124),
  # NOT crash with entr-not-found (rc 127).
  BUS init WP >/dev/null
  PATH=/usr/bin:/bin CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" CLAUDE_BUS_POLL=1 timeout 2 bash "$SCRIPT" wait WP >/dev/null 2>&1
  rc "wait polls (blocks) without entr, not exit 127" 124 $?
  # and it wakes when mail lands
  BUS init WQ >/dev/null
  ( PATH=/usr/bin:/bin CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" CLAUDE_BUS_POLL=1 bash "$SCRIPT" wait WQ; echo $? >"$CLAUDE_BUS_ROOT/wq.rc" ) &
  wqpid=$!
  BUS send WQ X ping >/dev/null
  timeout 6 tail --pid="$wqpid" -f /dev/null 2>/dev/null
  kill "$wqpid" 2>/dev/null
  eq "wait wakes on mail without entr" "0" "$(cat "$CLAUDE_BUS_ROOT/wq.rc" 2>/dev/null)"
fi

#############################################################################
# S2-10: Fable-review regressions
#############################################################################
# fix 1: baseline rolls forward, so progress-then-wedge eventually stalls
# (with the frozen baseline, tick1's mtime 60 > 50 read 'working' forever).
BUS init MONP >/dev/null
mkpend MONP p1 pp                          # baseline mtime:50, state acked
probe_snapshot() { echo '{"alive":1,"net":100,"oom":0,"mtime":60,"known":true}'; }
cmd_monitor_tick MONP                       # tick1: 60>50 working, baseline->60
cmd_monitor_tick MONP                       # tick2: 60 vs 60 idle, flat1
eq "progress then flat: no alert yet" "0" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/MONP")"
cmd_monitor_tick MONP                       # tick3: idle flat2 -> stalled
eq "progress then flat: stall fires"  "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/MONP")"

# fix 7: a fatal verdict escalates past a prior non-fatal alert (unacked -> dead)
BUS init MONE >/dev/null
mkpend_state MONE e1 sent '{"alive":1,"net":100,"oom":0,"mtime":50}' 5   # ticks=5 -> unacked now
probe_snapshot() { echo '{"alive":1,"net":100,"oom":0,"mtime":80,"known":true}'; }  # alive, producing
cmd_monitor_tick MONE
eq  "escalation: unacked first" "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/MONE")"
has "first alert is unacked" "$(jq -r .body "$(ls -t "$CLAUDE_BUS_ROOT"/inbox/MONE/*.msg | head -1)")" "unacked"
probe_snapshot() { echo '{"alive":0,"net":100,"oom":0,"mtime":80,"known":true}'; }  # now dead
cmd_monitor_tick MONE
eq "escalation: dead re-alerts past unacked" "2" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/MONE")"

# fix 2: a well-formed envelope with a hostile from is quarantined, not wedging
BUS init MONBF >/dev/null
jq -n '{from:"../evil",to:"MONBF",ts:"1-1",id:"1-1",kind:"msg",body:"x"}' > "$CLAUDE_BUS_ROOT/inbox/MONBF/1-1.from-x.msg"
CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" bash "$SCRIPT" drain MONBF >/dev/null 2>&1
rc "drain survives a hostile from (no wedge)" 0 $?
eq "hostile-from envelope quarantined" "1" "$(ls "$CLAUDE_BUS_ROOT"/inbox/MONBF/*.bad 2>/dev/null | wc -l)"

# fix 3: reply/close reject a traversal id
BUS reply o w '../../x' done hi; rc "reply rejects traversal id" 7 $?
BUS close o '../../x';            rc "close rejects traversal id" 7 $?

# fix 4: wait via entr returns 0 (not entr's exit 2) on a real wake
if command -v entr >/dev/null 2>&1; then
  BUS init WE >/dev/null
  ( CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" bash "$SCRIPT" wait WE; echo $? >"$CLAUDE_BUS_ROOT/we.rc" ) &
  wepid=$!
  BUS send WE X ping >/dev/null
  timeout 6 tail --pid="$wepid" -f /dev/null 2>/dev/null
  kill "$wepid" 2>/dev/null
  eq "wait via entr returns 0 on wake (not 2)" "0" "$(cat "$CLAUDE_BUS_ROOT/we.rc" 2>/dev/null)"
else
  ok "wait-via-entr test skipped (no entr installed)"
fi

#############################################################################
# S2-11: delegate (transparent inbox interception)
#############################################################################
BUS init CUO >/dev/null; BUS init SEC >/dev/null; BUS init WKR >/dev/null
BUS delegate CUO SEC >/dev/null
BUS send CUO WKR "report" >/dev/null       # worker addresses CUO, unchanged
eq "delegated: nothing in CUO inbox"    "0" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/CUO")"
eq "delegated: lands in SEC inbox"      "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/SEC")"
eq "delegated: envelope 'to' stays CUO" "CUO" "$(jq -r .to "$(ls "$CLAUDE_BUS_ROOT"/inbox/SEC/*.msg | head -1)")"
# a second, independent delegation coexists (nothing hardcoded)
BUS init CUO2 >/dev/null; BUS init SEC2 >/dev/null
BUS delegate CUO2 SEC2 >/dev/null
BUS send CUO2 WKR "hi" >/dev/null
eq "second delegation independent" "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/SEC2")"
eq "first delegation unaffected"   "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/SEC")"
# undelegate restores direct delivery
BUS undelegate CUO >/dev/null
BUS send CUO WKR "again" >/dev/null
eq "undelegated: back to CUO inbox" "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/CUO")"
# delegation must preserve the expectation lifecycle (drain resolves against 'to')
BUS init CUOD >/dev/null; BUS init SECD >/dev/null; BUS init WD >/dev/null
BUS delegate CUOD SECD >/dev/null
tid=$(BUS dispatch WD CUOD "task" 2>/dev/null)   # CUOD dispatches to worker WD
BUS drain WD >/dev/null                          # WD receives + auto-acks (ack to CUOD -> SECD)
BUS drain SECD >/dev/null                        # SECD drains the ack, resolves pending/CUOD
eq "delegated ack resolves orchestrator expectation" "acked" "$(jq -r .state "$CLAUDE_BUS_ROOT/pending/CUOD/$tid.json")"
BUS reply CUOD WD "$tid" done "finished" >/dev/null   # done to CUOD -> SECD
BUS drain SECD >/dev/null
eq "delegated done closes orchestrator expectation" "1" "$([ -f "$CLAUDE_BUS_ROOT/pending/CUOD/$tid.json" ]; echo $?)"

#############################################################################
# S2-12: forward (verbatim relay with provenance + note)
#############################################################################
BUS init FA >/dev/null; BUS init FB >/dev/null; BUS init FC >/dev/null
BUS send FB FA "the agent report" >/dev/null   # FA -> FB
mid=$(jq -r .id "$(ls "$CLAUDE_BUS_ROOT"/inbox/FB/*.msg | head -1)")
BUS drain FB >/dev/null                          # FB drains -> archived to log/FB
eq "drain archives to log"    "1" "$(ls "$CLAUDE_BUS_ROOT"/log/FB/*.msg 2>/dev/null | wc -l)"
eq "drain leaves inbox empty" "0" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/FB")"
BUS forward FB "$mid" FC "looks important" >/dev/null
eq  "forward lands in FC"         "1"       "$(nmsg "$CLAUDE_BUS_ROOT/inbox/FC")"
ff=$(ls "$CLAUDE_BUS_ROOT"/inbox/FC/*.msg | head -1)
eq  "forward kind is forward"     "forward" "$(jq -r .kind "$ff")"
has "forward keeps verbatim body" "$(jq -r .body "$ff")" "the agent report"
has "forward carries the note"    "$(jq -r .body "$ff")" "looks important"
has "forward shows provenance"    "$(jq -r .body "$ff")" "forwarded from FA"
# forwarding an unknown id fails cleanly
BUS forward FB 999-999 FC note; rc "forward unknown id errors" 6 $?
# forward enforces the size cap on its note (check_size before lookup)
big=$(head -c 2000 /dev/zero | tr '\0' x)
BUS forward FB "$mid" FC "$big"; rc "forward enforces note cap" 3 $?

#############################################################################
# S2-13: unique message ids (Fable round 4) — same-task replies don't collide
#############################################################################
BUS init OU >/dev/null; BUS init WU2 >/dev/null
tuid=$(BUS dispatch WU2 OU "task" 2>/dev/null)
BUS drain WU2 >/dev/null                              # WU2 auto-acks (ref=tuid) to OU
BUS reply OU WU2 "$tuid" progress "50%" >/dev/null    # progress (ref=tuid) to OU
eq "same-task ack+progress coexist (no inbox collision)" "2" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/OU")"
# each message has a distinct id; both correlate to the task via ref
ids=$(for m in "$CLAUDE_BUS_ROOT"/inbox/OU/*.msg; do jq -r .id "$m"; done | sort -u | wc -l)
eq "the two messages have distinct ids" "2" "$ids"
refs=$(for m in "$CLAUDE_BUS_ROOT"/inbox/OU/*.msg; do jq -r .ref "$m"; done | sort -u)
eq "both ref the same task" "$tuid" "$refs"
# send-path enforces the size cap on its note too
BUS send-path SP SPF "$SCRIPT" "$big"; rc "send-path enforces note cap" 3 $?
# drain header surfaces the task correlation (ref) for a reply
BUS init OR2 >/dev/null; BUS init WR2 >/dev/null
tri=$(BUS dispatch WR2 OR2 "task" 2>/dev/null)
BUS reply OR2 WR2 "$tri" progress "half" >/dev/null
has "drain header shows ref for a reply" "$(BUS drain OR2 2>/dev/null)" "ref:$tri"

#############################################################################
# S2-14: drain-staleness watch (a sink that stops draining — the incident case)
#############################################################################
export CLAUDE_BUS_DRAIN_MAX=2
# targets here are plain inboxes, not registered; a known:false probe makes the
# dead-poll inert so these assertions isolate the drain-staleness axis.
probe_snapshot() { echo '{"alive":0,"net":0,"oom":0,"mtime":0,"known":false}'; }
BUS init WOBS >/dev/null
BUS watch WOBS SINK >/dev/null
eq "watch writes a record" "0" "$([ -f "$CLAUDE_BUS_ROOT/watch/WOBS/SINK.json" ]; echo $?)"
BUS send SINK SENDER "please handle" >/dev/null   # SINK has undrained mail
cmd_monitor_tick WOBS                             # tick1: mail just arrived, no alert
eq "stale tick1: no alert" "0" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WOBS")"
cmd_monitor_tick WOBS                             # tick2: same oldest persists -> stale
eq "stale tick2: alert" "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WOBS")"
has "stale alert says stale"       "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/WOBS/*.msg | head -1)")" "stale"
has "stale alert names the target" "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/WOBS/*.msg | head -1)")" "SINK"
cmd_monitor_tick WOBS                             # no duplicate while it stays stuck
eq "stale no duplicate alert" "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WOBS")"
BUS unwatch WOBS SINK >/dev/null
eq "unwatch removes the record" "1" "$([ -f "$CLAUDE_BUS_ROOT/watch/WOBS/SINK.json" ]; echo $?)"

# a non-integer drain_max is rejected fast and leaves no zombie record behind
BUS watch WOBS BADT abc; rc "watch rejects non-integer drain_max" 5 $?
eq "rejected watch leaves no record" "1" "$([ -f "$CLAUDE_BUS_ROOT/watch/WOBS/BADT.json" ]; echo $?)"

# a sink that drains within DRAIN_MAX never false-alarms (oldest changes -> reset)
BUS init WOK >/dev/null
BUS watch WOK SINK2 >/dev/null
BUS send SINK2 SENDER hi >/dev/null
cmd_monitor_tick WOK                              # tick1: sees the oldest
BUS drain SINK2 >/dev/null 2>&1                   # sink drains -> inbox empties
cmd_monitor_tick WOK; cmd_monitor_tick WOK        # ticks reset, no alert
eq "drained sink never stale" "0" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WOK")"

# a fresh stuck message after the first drains re-alerts (changed-oldest branch)
BUS init WRE >/dev/null
BUS watch WRE SINK3 >/dev/null
BUS send SINK3 s "first" >/dev/null
cmd_monitor_tick WRE; cmd_monitor_tick WRE        # first goes stale -> 1 alert
eq "re-alert setup: first stale" "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WRE")"
BUS drain SINK3 >/dev/null 2>&1                    # first drains
BUS send SINK3 s "second" >/dev/null               # a new message gets stuck behind it
cmd_monitor_tick WRE; cmd_monitor_tick WRE        # new oldest -> fresh alert
eq "new stuck message re-alerts" "2" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WRE")"

# the monitor loop stays alive while a watch is open (would exit-0 if watches ignored)
BUS init WLOOP >/dev/null; BUS watch WLOOP WTGT >/dev/null; BUS send WTGT s hi >/dev/null
CLAUDE_BUS_TICK=1 timeout 3 bash "$SCRIPT" monitor WLOOP >/dev/null 2>&1
rc "monitor stays alive while a watch is open" 124 $?

#############################################################################
# S2-15: self-ack under delegation warns but still delivers (the footgun)
#############################################################################
BUS init SECX >/dev/null
BUS delegate CUOX SECX >/dev/null                 # mail to CUOX lands in SECX
BUS send SECX CUOX "please" >/dev/null            # a msg in SECX's inbox from CUOX
selfout="$(BUS drain SECX 2>&1 >/dev/null)"       # auto-ack to CUOX loops back to SECX
has "self-ack warns about the loop" "$selfout" "loops back"
eq  "self-ack is still delivered"   "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/SECX")"
# a normal sender (not delegating to the drainer) does not warn
BUS init NRM >/dev/null
BUS send NRM OTHER "hey" >/dev/null
normout="$(BUS drain NRM 2>&1 >/dev/null)"
hasnot "normal ack does not warn" "$normout" "loops back"

#############################################################################
# S2-16: watch also polls registered process liveness (dead outranks stale)
#############################################################################
# a registered target whose tree is gone -> one 'dead' alert, no duplicate
BUS init WLIV >/dev/null
BUS watch WLIV DEADT >/dev/null
probe_snapshot() { echo '{"alive":0,"net":0,"oom":0,"mtime":0,"known":true}'; }
cmd_monitor_tick WLIV
eq  "watch: dead target alerts"      "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WLIV")"
has "watch: dead alert says dead"    "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/WLIV/*.msg | head -1)")" "dead"
cmd_monitor_tick WLIV
eq  "watch: dead no duplicate alert" "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WLIV")"

# a live registered target never dead-alerts
BUS init WLIV2 >/dev/null
BUS watch WLIV2 LIVET >/dev/null
probe_snapshot() { echo '{"alive":1,"net":0,"oom":0,"mtime":0,"known":true}'; }
cmd_monitor_tick WLIV2; cmd_monitor_tick WLIV2
eq "watch: live target never dead-alerts" "0" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WLIV2")"

# dead outranks stale: a dead target with undrained mail alerts 'dead', not 'stale'
BUS init WLIV3 >/dev/null
BUS watch WLIV3 DEADS >/dev/null
BUS send DEADS x "backlog" >/dev/null
probe_snapshot() { echo '{"alive":0,"net":0,"oom":0,"mtime":0,"known":true}'; }
cmd_monitor_tick WLIV3; cmd_monitor_tick WLIV3
has    "dead outranks stale (says dead)"    "$(for m in "$CLAUDE_BUS_ROOT"/inbox/WLIV3/*.msg; do jq -r .body "$m"; done)" "dead"
hasnot "dead outranks stale (not stale)"    "$(for m in "$CLAUDE_BUS_ROOT"/inbox/WLIV3/*.msg; do jq -r .body "$m"; done)" "stale"

# an unregistered watched target skips the dead-poll (known:false) but still goes stale
BUS init WLIV4 >/dev/null
BUS watch WLIV4 UNREG >/dev/null
BUS send UNREG x "backlog" >/dev/null
probe_snapshot() { echo '{"alive":0,"net":0,"oom":0,"mtime":0,"known":false}'; }
cmd_monitor_tick WLIV4
eq  "unregistered watch: tick1 no alert" "0" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WLIV4")"
cmd_monitor_tick WLIV4
has "unregistered watch still goes stale" "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/WLIV4/*.msg | head -1)")" "stale"

#############################################################################
# S2-17: watch reads the transcript tail — an unresolved API error is 'erroring'
#############################################################################
# alive target whose transcript tail is a 429 -> one 'erroring 429' alert
BUS init WERR >/dev/null
TJ="$CLAUDE_BUS_ROOT/werr.jsonl"
printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":429}' > "$TJ"
BUS register ERRT --cgroup /x --transcript "$TJ" >/dev/null
BUS watch WERR ERRT >/dev/null
probe_snapshot() { echo '{"alive":1,"net":0,"oom":0,"mtime":0,"known":true}'; }   # alive, so not dead
cmd_monitor_tick WERR
has "erroring alert on API-error tail"  "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/WERR/*.msg 2>/dev/null | head -1)")" "erroring"
has "erroring alert carries the status" "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/WERR/*.msg 2>/dev/null | head -1)")" "429"
cmd_monitor_tick WERR
eq "erroring no duplicate" "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WERR")"
# recovered: a normal entry after the error -> clean tail -> no error alert
printf '%s\n' '{"type":"assistant","message":{"role":"assistant"}}' >> "$TJ"
BUS init WOK3 >/dev/null; BUS register OKT --cgroup /x --transcript "$TJ" >/dev/null; BUS watch WOK3 OKT >/dev/null
cmd_monitor_tick WOK3
eq "recovered transcript -> no erroring alert" "0" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WOK3")"
# dead outranks erroring: a gone tree with an error tail still alerts 'dead'
DJ="$CLAUDE_BUS_ROOT/de.jsonl"
printf '%s\n' '{"isApiErrorMessage":true,"apiErrorStatus":429}' > "$DJ"
BUS init WDE >/dev/null; BUS register DET --cgroup /x --transcript "$DJ" >/dev/null; BUS watch WDE DET >/dev/null
probe_snapshot() { echo '{"alive":0,"net":0,"oom":0,"mtime":0,"known":true}'; }   # tree gone
cmd_monitor_tick WDE
has "dead outranks erroring" "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/WDE/*.msg 2>/dev/null | head -1)")" "dead"

#############################################################################
# S2-18: per-axis dedup — a stale condition masked by a transient error must not
# re-alert when the error clears (stale -> err -> stale is one stale alert)
#############################################################################
BUS init WIX >/dev/null
IJ="$CLAUDE_BUS_ROOT/wix.jsonl"
printf '%s\n' '{"message":{"role":"assistant"}}' > "$IJ"   # clean tail (no error yet)
BUS register IXT --cgroup /x --transcript "$IJ" >/dev/null
BUS send IXT s "stuck" >/dev/null                          # stale mail that never drains
BUS watch WIX IXT >/dev/null
probe_snapshot() { echo '{"alive":1,"net":0,"oom":0,"mtime":0,"known":true}'; }   # alive
cmd_monitor_tick WIX; cmd_monitor_tick WIX                 # tick2: stale alert
eq "interleave: stale alerted once" "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WIX")"
printf '%s\n' '{"isApiErrorMessage":true,"apiErrorStatus":429}' >> "$IJ"   # tail becomes an error
cmd_monitor_tick WIX                                       # erroring alert (distinct)
eq "interleave: erroring alert added" "2" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WIX")"
printf '%s\n' '{"message":{"role":"assistant"}}' >> "$IJ"  # error clears; the same msg is still stuck
cmd_monitor_tick WIX                                       # must NOT re-alert the already-known stale
eq "interleave: cleared error does not re-alert stale" "2" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WIX")"

#############################################################################
echo "----"; echo "pass=$pass fail=$fail"; [[ $fail -eq 0 ]]
