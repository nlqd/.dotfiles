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
# S2-19: register merges — an unpassed field inherits the prior meta, so the
# launcher (--cgroup) and the agent (--transcript) register independently
# without clobbering. init's self-register goes through the same merge.
#############################################################################
BUS register MG --cgroup /user.slice/real.scope >/dev/null      # launcher: cgroup only
BUS register MG --transcript /tmp/mg.jsonl >/dev/null           # agent: transcript only, later
mfm="$CLAUDE_BUS_ROOT/meta/MG.json"
eq "merge keeps prior cgroup"      "/user.slice/real.scope" "$(jq -r .cgroup "$mfm")"
eq "merge adds new transcript"     "/tmp/mg.jsonl"          "$(jq -r .transcript "$mfm")"
# reverse order (transcript first) also ends with both fields set
BUS register MG2 --transcript /tmp/mg2.jsonl >/dev/null
BUS register MG2 --cgroup /user.slice/real2.scope >/dev/null
mfm2="$CLAUDE_BUS_ROOT/meta/MG2.json"
eq "merge (reverse) keeps transcript" "/tmp/mg2.jsonl"          "$(jq -r .transcript "$mfm2")"
eq "merge (reverse) adds cgroup"      "/user.slice/real2.scope" "$(jq -r .cgroup "$mfm2")"
# an explicitly-passed field still overwrites the prior value (merge != append-only)
BUS register MG2 --cgroup /user.slice/new.scope >/dev/null
eq "explicit flag overwrites prior"   "/user.slice/new.scope" "$(jq -r .cgroup "$mfm2")"
# init's self-register must not blank a launcher-set transcript (goes via merge)
BUS register IM --cgroup /user.slice/im.scope --transcript /tmp/im.jsonl >/dev/null
selfinit /user.slice/im.scope IM >/dev/null
mfim="$CLAUDE_BUS_ROOT/meta/IM.json"
eq "init preserves prior transcript"  "/tmp/im.jsonl"        "$(jq -r .transcript "$mfim")"
eq "init preserves prior cgroup"      "/user.slice/im.scope" "$(jq -r .cgroup "$mfim")"

#############################################################################
# S2-20: register --supervisor <parent> auto-wires the parent's watch of this
# agent, so an ephemeral worker is watched at spawn without hand-wiring and the
# parent learns when it 529s. Create-if-absent: a re-register never resets a
# live watch's dedup state.
#############################################################################
BUS init SUP >/dev/null
BUS register WRK --cgroup /user.slice/wrk.scope --supervisor SUP >/dev/null
swf="$CLAUDE_BUS_ROOT/watch/SUP/WRK.json"
eq "supervisor auto-creates a watch record" "0"   "$([ -f "$swf" ]; echo $?)"
eq "auto watch targets the worker"          "WRK" "$(jq -r .target "$swf")"
# end to end: worker registers its transcript (merge keeps cgroup + the watch),
# then the parent's tick alerts on the worker's 529
WJ="$CLAUDE_BUS_ROOT/wrk.jsonl"
printf '%s\n' '{"isApiErrorMessage":true,"apiErrorStatus":529}' > "$WJ"
BUS register WRK --transcript "$WJ" >/dev/null
probe_snapshot() { echo '{"alive":1,"net":0,"oom":0,"mtime":0,"known":true}'; }   # alive
cmd_monitor_tick SUP
supbody() { jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/SUP/*.msg 2>/dev/null | head -1)"; }
has "supervisor learns worker erroring"      "$(supbody)" "erroring"
has "supervisor erroring alert has status"   "$(supbody)" "529"
eq  "supervisor erroring alerts once"        "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/SUP")"
# re-supplying --supervisor must not reset the record (would re-fire the alert)
BUS register WRK --supervisor SUP >/dev/null
cmd_monitor_tick SUP
eq "re-register --supervisor preserves dedup" "1" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/SUP")"
# a self-supervisor is meaningless and creates no watch record
BUS register SELFS --cgroup /x --supervisor SELFS >/dev/null 2>&1
eq "self-supervisor creates no watch" "1" "$([ -f "$CLAUDE_BUS_ROOT/watch/SELFS/SELFS.json" ]; echo $?)"
# a bad supervisor name is rejected before any write
BUS register BADSUP --supervisor "../x" >/dev/null 2>&1; rc "register rejects bad supervisor name" 7 $?

#############################################################################
# S2-21: adversarial-review fixes (Fable round on merge + --supervisor)
#############################################################################
# (1) init refreshes THIS process's own scope cgroup — a reused bus name must not
# keep a dead prior session's scope (which would false-fire 'dead'); transcript kept.
BUS register RU --cgroup /user.slice/old.scope --transcript /tmp/ru.jsonl >/dev/null
selfinit /user.slice/new.scope RU >/dev/null
mfru="$CLAUDE_BUS_ROOT/meta/RU.json"
eq "init refreshes its own scope cgroup" "/user.slice/new.scope" "$(jq -r .cgroup "$mfru")"
eq "init keeps the launcher transcript"  "/tmp/ru.jsonl"          "$(jq -r .transcript "$mfru")"
# (3) an explicitly empty flag value means "inherit", not "clear": a launcher
# passing an unset $CG must not blank a correct cgroup.
BUS register EC --cgroup /user.slice/keep.scope >/dev/null
BUS register EC --cgroup "" --transcript /tmp/ec.jsonl >/dev/null
mfec="$CLAUDE_BUS_ROOT/meta/EC.json"
eq "empty --cgroup inherits prior"        "/user.slice/keep.scope" "$(jq -r .cgroup "$mfec")"
eq "empty --cgroup still sets transcript" "/tmp/ec.jsonl"          "$(jq -r .transcript "$mfec")"
# (4) a value flag with no value is rejected, not an unbound crash or a spin
BUS register NV --supervisor; rc "register --supervisor needs a value" 2 $?
BUS register NV --cgroup;     rc "register --cgroup needs a value"     2 $?
# (2a) a bad drain_max with --supervisor fails fast, before writing meta
BUS init SUPV >/dev/null
CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" CLAUDE_BUS_DRAIN_MAX=five bash "$SCRIPT" register WV --cgroup /x --supervisor SUPV >/dev/null 2>&1
rc "bad drain_max with --supervisor rejected" 5 $?
eq "rejected register wrote no meta" "1" "$([ -f "$CLAUDE_BUS_ROOT/meta/WV.json" ]; echo $?)"
# (2b) if the auto-watch write fails, register still exits 0 after a successful meta
# write (the tip must not leak a non-zero status under set -e). Root ignores 0555.
if [ "$(id -u)" -ne 0 ]; then
  BUS init SUPW >/dev/null
  mkdir -p "$CLAUDE_BUS_ROOT/watch/SUPW"; chmod 0555 "$CLAUDE_BUS_ROOT/watch/SUPW"
  BUS register WW --cgroup /x --supervisor SUPW >/dev/null 2>&1; rc "auto-watch write failure still exits 0" 0 $?
  chmod 0755 "$CLAUDE_BUS_ROOT/watch/SUPW"
  eq "meta written despite watch failure" "0" "$([ -f "$CLAUDE_BUS_ROOT/meta/WW.json" ]; echo $?)"
else
  ok "auto-watch write-failure test skipped (root)"; ok "meta-write test skipped (root)"
fi

#############################################################################
# S2-22: init surfaces a self-register failure (fail loud), plus arg-parse and
# drain_max coverage the review flagged as untested.
#############################################################################
# (N1) init must not swallow a self-register failure behind a silent exit 1
if [ "$(id -u)" -ne 0 ]; then
  R2="$(mktemp -d)"; mkdir -p "$R2/meta"; chmod 0555 "$R2/meta"
  ierr="$(CLAUDE_BUS_ROOT="$R2" CLAUDE_BUS_SELF_CGROUP=/user.slice/ix.scope bash "$SCRIPT" init IX 2>&1 >/dev/null)"
  has "init surfaces a self-register failure" "$ierr" "self-register failed"
  chmod 0755 "$R2/meta"; rm -rf "$R2"
else
  ok "init self-register failure test skipped (root)"
fi
# a fresh name with an explicitly empty --cgroup still self-detects (fix-3 case b)
CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" CLAUDE_BUS_SELF_CGROUP=/user.slice/se.scope bash "$SCRIPT" register FE --cgroup "" >/dev/null
eq "fresh empty --cgroup self-detects" "/user.slice/se.scope" "$(jq -r .cgroup "$CLAUDE_BUS_ROOT/meta/FE.json")"
# every value flag shares the missing-value guard; an unknown flag still exits 2
BUS register NV2 --pid;        rc "register --pid needs a value"        2 $?
BUS register NV2 --transcript; rc "register --transcript needs a value" 2 $?
BUS register NV2 --bogus;      rc "register rejects unknown flag"       2 $?
# the auto-watch record honors a custom CLAUDE_BUS_DRAIN_MAX (not just the default)
BUS init SUPD >/dev/null
CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" CLAUDE_BUS_DRAIN_MAX=5 bash "$SCRIPT" register WD --cgroup /x --supervisor SUPD >/dev/null
eq "auto-watch honors CLAUDE_BUS_DRAIN_MAX" "5" "$(jq -r .drain_max "$CLAUDE_BUS_ROOT/watch/SUPD/WD.json")"
# (D1) write_meta must surface a jq failure, not silently succeed: the redirect
# creates a 0-byte tmp, so a non-atomic jq-then-mv would rename the empty file and
# report success over corrupt meta. Simulate jq dying after the redirect.
d1rc=0
( jq() { return 1; }; write_meta D1M /x "" "" ) || d1rc=$?
eq "write_meta reports a jq failure"   "0" "$([ "$d1rc" -ne 0 ]; echo $?)"
eq "write_meta leaves no corrupt meta" "1" "$([ -f "$CLAUDE_BUS_ROOT/meta/D1M.json" ]; echo $?)"
eq "write_meta leaves no stale tmp"    "0" "$(find "$CLAUDE_BUS_ROOT/meta" -name 'D1M.json.tmp.*' 2>/dev/null | wc -l)"

#############################################################################
# S2-23: role-gated death alarm. --supervisor watches are erroring-only by default
# (role=ephemeral): a clean worker death is silent and GC'd (no churn), while
# erroring/stale still alarm. The death-alarm is opt-in via role=supervisor, which
# is also `watch`'s default (the mgr<-sec/onc case).
#############################################################################
# register --supervisor tags the auto-watch ephemeral
BUS init SP >/dev/null
BUS register EW --cgroup /x --supervisor SP >/dev/null
eq "register --supervisor role is ephemeral" "ephemeral" "$(jq -r .role "$CLAUDE_BUS_ROOT/watch/SP/EW.json")"
# an ephemeral worker that dies is silent AND its watch record is GC'd
probe_snapshot() { echo '{"alive":0,"net":0,"oom":0,"mtime":0,"known":true}'; }
cmd_monitor_tick SP
eq "ephemeral death: no alert"    "0" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/SP")"
eq "ephemeral death: record GC'd" "1" "$([ -f "$CLAUDE_BUS_ROOT/watch/SP/EW.json" ]; echo $?)"
# but an ephemeral worker still alarms on erroring (the core signal)
BUS init SP2 >/dev/null
EWJ="$CLAUDE_BUS_ROOT/ew2.jsonl"; printf '%s\n' '{"isApiErrorMessage":true,"apiErrorStatus":529}' > "$EWJ"
BUS register EW2 --cgroup /x --transcript "$EWJ" --supervisor SP2 >/dev/null
probe_snapshot() { echo '{"alive":1,"net":0,"oom":0,"mtime":0,"known":true}'; }
cmd_monitor_tick SP2
has "ephemeral still alarms on erroring" "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/SP2/*.msg 2>/dev/null | head -1)")" "erroring"
# watch defaults to role=supervisor and DOES alarm on death, not GC'd
BUS init SP3 >/dev/null
BUS watch SP3 SUPT >/dev/null
eq "watch default role is supervisor" "supervisor" "$(jq -r .role "$CLAUDE_BUS_ROOT/watch/SP3/SUPT.json")"
probe_snapshot() { echo '{"alive":0,"net":0,"oom":0,"mtime":0,"known":true}'; }
cmd_monitor_tick SP3
has "supervisor death DOES alarm" "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/SP3/*.msg 2>/dev/null | head -1)")" "dead"
eq "supervisor watch not GC'd"    "0" "$([ -f "$CLAUDE_BUS_ROOT/watch/SP3/SUPT.json" ]; echo $?)"
# register --supervisor --role supervisor opts into the death-alarm
BUS init SP4 >/dev/null
BUS register LV --cgroup /x --supervisor SP4 --role supervisor >/dev/null
eq "register --role supervisor honored" "supervisor" "$(jq -r .role "$CLAUDE_BUS_ROOT/watch/SP4/LV.json")"
probe_snapshot() { echo '{"alive":0,"net":0,"oom":0,"mtime":0,"known":true}'; }
cmd_monitor_tick SP4
has "opted-in supervisor death alarms" "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/SP4/*.msg 2>/dev/null | head -1)")" "dead"
# an unregistered/old record with no role field defaults to supervisor (dead alarms)
BUS init SP5 >/dev/null
printf '{"target":"OLDT","drain_max":2,"last":"","ticks":0}' > "$CLAUDE_BUS_ROOT/watch/SP5/OLDT.json" 2>/dev/null || { mkdir -p "$CLAUDE_BUS_ROOT/watch/SP5"; printf '{"target":"OLDT","drain_max":2,"last":"","ticks":0}' > "$CLAUDE_BUS_ROOT/watch/SP5/OLDT.json"; }
probe_snapshot() { echo '{"alive":0,"net":0,"oom":0,"mtime":0,"known":true}'; }
cmd_monitor_tick SP5
has "role-less record defaults to supervisor (alarms)" "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/SP5/*.msg 2>/dev/null | head -1)")" "dead"
# an invalid role is rejected before any write
BUS register BR --cgroup /x --supervisor SP4 --role bogus >/dev/null 2>&1; rc "register rejects bad role" 5 $?
# --role is validated even without --supervisor (catch a typo'd invocation early)
BUS register NR --cgroup /x --role bogus >/dev/null 2>&1; rc "register validates --role without --supervisor" 5 $?
# (F1) an ephemeral worker that dies WHILE erroring surfaces the 529 before GC — the
# primary signal must survive even if no alive+erroring tick landed in between
BUS init SPF >/dev/null
FWJ="$CLAUDE_BUS_ROOT/spf.jsonl"; printf '%s\n' '{"isApiErrorMessage":true,"apiErrorStatus":529}' > "$FWJ"
BUS register FWK --cgroup /x --transcript "$FWJ" --supervisor SPF >/dev/null
probe_snapshot() { echo '{"alive":0,"net":0,"oom":0,"mtime":0,"known":true}'; }   # dead, mid-error
cmd_monitor_tick SPF
has "ephemeral died-while-erroring alerts 529" "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/SPF/*.msg 2>/dev/null | head -1)")" "erroring"
eq  "ephemeral died-while-erroring still GC'd" "1" "$([ -f "$CLAUDE_BUS_ROOT/watch/SPF/FWK.json" ]; echo $?)"
# (F2) a same-name respawn re-registered before the GC lands must not lose its fresh
# watch: the GC re-confirms death under the lock, so an alive target is not deleted.
# Emulate the race with a probe that reads dead first (the tick's decision) then alive
# (the respawn, seen by the under-lock re-confirm).
BUS init SPR >/dev/null
BUS register RWK --cgroup /x --supervisor SPR >/dev/null
# file-backed toggle (each probe call runs in its own $() subshell, so an in-memory
# counter would not persist): first read dead, every read after alive.
rm -f "$CLAUDE_BUS_ROOT/.pcflag"
probe_snapshot() { if [ -e "$CLAUDE_BUS_ROOT/.pcflag" ]; then echo '{"alive":1,"net":0,"oom":0,"mtime":0,"known":true}'; else : > "$CLAUDE_BUS_ROOT/.pcflag"; echo '{"alive":0,"net":0,"oom":0,"mtime":0,"known":true}'; fi; }
cmd_monitor_tick SPR
eq "respawn race: record NOT GC'd (re-confirmed alive)" "0" "$([ -f "$CLAUDE_BUS_ROOT/watch/SPR/RWK.json" ]; echo $?)"
eq "respawn race: no spurious alert"                    "0" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/SPR")"

#############################################################################
# S2-24: the monitor is HOST-ONLY. Inside a sandbox the metas' host-absolute cgroup
# paths are unreadable, so every probe reads dead -> false 'dead' alarms and, with
# the ephemeral GC, deletion of LIVE workers. monitor must refuse rather than nuke.
#############################################################################
# the detector: a real host (no sandbox marker, cgroupfs readable) passes
( monitor_host_ok ); eq "host passes the monitor guard" "0" "$?"
# an explicit sandbox marker fails it
( IS_SANDBOX=1 monitor_host_ok ); eq "IS_SANDBOX fails the guard" "1" "$?"
# no usable cgroupfs fails it
( CLAUDE_BUS_SYSFS="$CLAUDE_BUS_ROOT/nocg" monitor_host_ok ); eq "missing cgroupfs fails the guard" "1" "$?"
# a CONTAINER-shaped cgroupfs (root cgroup.procs readable but NO host user.slice) must
# fail — this is the rootless-podman false-negative the belt exists to catch
FAKECGP="$CLAUDE_BUS_ROOT/cg-container"; mkdir -p "$FAKECGP"; : > "$FAKECGP/cgroup.procs"
( CLAUDE_BUS_SYSFS="$FAKECGP" monitor_host_ok ); eq "container cgroupfs fails the guard" "1" "$?"
# a host-shaped fake (cgroup.procs + user.slice) passes without relying on the real /sys
FAKECGH="$CLAUDE_BUS_ROOT/cg-host"; mkdir -p "$FAKECGH/user.slice"; : > "$FAKECGH/cgroup.procs"
( CLAUDE_BUS_SYSFS="$FAKECGH" monitor_host_ok ); eq "host-shaped cgroupfs passes the guard" "0" "$?"
# cmd_monitor REFUSES to start in a sandbox (exit 8), before any tick/GC
BUS init HMON >/dev/null
IS_SANDBOX=1 CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" timeout 5 bash "$SCRIPT" monitor HMON >/dev/null 2>&1
rc "monitor refuses in a sandbox" 8 $?
has "monitor refusal says HOST-ONLY" "$(IS_SANDBOX=1 CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" bash "$SCRIPT" monitor HMON 2>&1)" "HOST-ONLY"
# monitor-tick (the destructive primitive) also refuses in a sandbox — else one call
# from inside a dbox performs the full nuke, bypassing the monitor guard
IS_SANDBOX=1 CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" bash "$SCRIPT" monitor-tick HMON >/dev/null 2>&1; rc "monitor-tick refuses in a sandbox" 8 $?

#############################################################################
# S2-25: the SessionStart register hook (session-register) — glue that self-
# registers name + transcript (+ optional supervisor) from the hook's stdin JSON.
#############################################################################
HK="$HERE/../.claude/skills/claude-bus/session-register"
echo '{"transcript_path":"/tmp/sess.jsonl","hook_event_name":"SessionStart"}' \
  | CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" CLAUDE_BUS_NAME=HOOKA bash "$HK"
eq "hook registers the name"  "0" "$([ -f "$CLAUDE_BUS_ROOT/meta/HOOKA.json" ]; echo $?)"
eq "hook sets the transcript" "/tmp/sess.jsonl" "$(jq -r .transcript "$CLAUDE_BUS_ROOT/meta/HOOKA.json")"
# no CLAUDE_BUS_NAME -> clean no-op
echo '{"transcript_path":"/tmp/x.jsonl"}' | CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" bash "$HK"; rc "hook no-ops without a name" 0 $?
# a worker forwards supervisor+role -> the parent's watch record is created ephemeral
echo '{"transcript_path":"/tmp/w.jsonl"}' \
  | CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" CLAUDE_BUS_NAME=HOOKW CLAUDE_BUS_SUPERVISOR=HOOKP CLAUDE_BUS_ROLE=ephemeral bash "$HK"
eq "hook creates the supervisor watch" "0" "$([ -f "$CLAUDE_BUS_ROOT/watch/HOOKP/HOOKW.json" ]; echo $?)"
eq "hook watch role is ephemeral"      "ephemeral" "$(jq -r .role "$CLAUDE_BUS_ROOT/watch/HOOKP/HOOKW.json")"

#############################################################################
# S2-26: register --wake stores the agent's self-registered wake command in meta
# (0600, user-owned), and merges like the other fields (a later update never blanks it).
#############################################################################
# The wake is STRUCTURED (socket + pane), never a command string: the monitor builds
# the argv itself, so nothing in this file — which any same-uid agent can write — is
# ever parsed as a command.
BUS register WK1 --cgroup /x --wake-socket /tmp/s --wake-pane %3 >/dev/null
eq "register stores the wake socket" "/tmp/s" "$(jq -r .wake.tmux_socket "$CLAUDE_BUS_ROOT/meta/WK1.json")"
eq "register stores the wake pane"   "%3"     "$(jq -r .wake.pane "$CLAUDE_BUS_ROOT/meta/WK1.json")"
# 0600 is hygiene against OTHER users. It is NOT a control against peer agents: they
# share this uid and the dir is theirs to write. Do not read this as one.
eq "meta is 0600 (hygiene, not a peer control)" "600" "$(stat -c %a "$CLAUDE_BUS_ROOT/meta/WK1.json")"
# a transcript-only update keeps the wake (merge)
BUS register WK1 --transcript /t.jsonl >/dev/null
eq "wake survives a later update"    "%3"     "$(jq -r .wake.pane "$CLAUDE_BUS_ROOT/meta/WK1.json")"
# a malformed pane is rejected at register time (fail fast; the real control is at exec)
BUS register WKBAD --wake-socket /tmp/s --wake-pane 'x; rm -rf /' >/dev/null 2>&1
rc "register rejects a malformed pane" 5 $?
# the session-register hook self-registers a tmux wake action when in a pane
# (CLAUDE_BUS_BIN points the hook at the under-test claude-bus, not the installed one)
echo '{"transcript_path":"/tmp/h.jsonl"}' \
  | CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" CLAUDE_BUS_BIN="$SCRIPT" CLAUDE_BUS_NAME=HOOKT TMUX="/tmp/tmux-1000/default,123,0" TMUX_PANE="%7" bash "$HK"
eq "hook registers its own pane"   "%7" "$(jq -r .wake.pane "$CLAUDE_BUS_ROOT/meta/HOOKT.json")"
eq "hook registers its own socket" "/tmp/tmux-1000/default" "$(jq -r .wake.tmux_socket "$CLAUDE_BUS_ROOT/meta/HOOKT.json")"
# no tmux env -> no wake action registered (unset TMUX/TMUX_PANE: the test runner
# itself is in tmux, so the hook would otherwise inherit the runner's pane)
echo '{"transcript_path":"/tmp/h2.jsonl"}' | CLAUDE_BUS_ROOT="$CLAUDE_BUS_ROOT" CLAUDE_BUS_BIN="$SCRIPT" CLAUDE_BUS_NAME=HOOKNT TMUX= TMUX_PANE= bash "$HK"
eq "hook without tmux registers no wake" "null" "$(jq -r '.wake // "null"' "$CLAUDE_BUS_ROOT/meta/HOOKNT.json")"

#############################################################################
# S2-27: the wakebot — `watch --nudge` runs the TARGET's own registered wake
# command when its inbox goes stale, INSTEAD of publishing a stale alert that
# only another (possibly asleep) session would read. Cadence: first fire at the
# stale threshold, then every CLAUDE_BUS_WAKE_EVERY stale ticks until it drains.
#############################################################################
probe_snapshot() { echo '{"alive":0,"net":0,"oom":0,"mtime":0,"known":false}'; }
export CLAUDE_BUS_DRAIN_MAX=2 CLAUDE_BUS_WAKE_EVERY=3
# A fake tmux on PATH records the argv the monitor builds (the tick execs tmux
# directly, so a shell function would not survive `timeout`). Each nudge is two
# send-keys calls (the literal text, then Enter — count the Enters); a display-message
# query returns $FAKE_PANE_PID so the pane-ownership check has a pid to resolve.
export WOKE="$CLAUDE_BUS_ROOT/woke.log"; : > "$WOKE"
export FAKE_PANE_PID="$$"                 # the test runner's own pid (real, resolvable)
FAKEBIN="$CLAUDE_BUS_ROOT/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<'FAKE'
#!/usr/bin/env bash
[ -n "${FAKE_TMUX_HANG:-}" ] && sleep 30
for a in "$@"; do [ "$a" = "display-message" ] && { printf '%s\n' "${FAKE_PANE_PID}"; exit 0; }; done
printf '%s\n' "$*" >> "$WOKE"
[ -n "${FAKE_TMUX_FAIL_SEND:-}" ] && exit 1   # ownership query still answers; the send fails
exit 0
FAKE
chmod +x "$FAKEBIN/tmux"
export PATH="$FAKEBIN:$PATH"
nwake() { grep -c 'Enter' "$WOKE" 2>/dev/null || true; }
# a real socket file, so the exec-time -S check has something valid to accept
SOCK="$CLAUDE_BUS_ROOT/tmux.sock"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$SOCK"
# The pane-ownership check requires the named pane's live pane_pid to sit in the
# target's registered cgroup. The fake tmux reports FAKE_PANE_PID (the runner), so a
# nudge target must register the runner's OWN cgroup to be considered its pane's owner.
MYCG="$(awk -F: '$1=="0"{print $3}' /proc/$$/cgroup)"
nudgereg() { BUS register "$1" --cgroup "$MYCG" --wake-socket "$SOCK" --wake-pane "$2" >/dev/null; }

BUS init WBOT >/dev/null
nudgereg NAP %7
BUS watch WBOT NAP --nudge >/dev/null
eq "watch --nudge records nudge" "true"  "$(jq -r .nudge "$CLAUDE_BUS_ROOT/watch/WBOT/NAP.json")"
BUS watch WBOT PLAIN >/dev/null
eq "plain watch is not a nudge"  "false" "$(jq -r .nudge "$CLAUDE_BUS_ROOT/watch/WBOT/PLAIN.json")"
BUS unwatch WBOT PLAIN >/dev/null

BUS send NAP SENDER "wake up" >/dev/null
cmd_monitor_tick WBOT                             # tick1: mail just landed, under threshold
eq "nudge tick1: no wake yet" "0" "$(nwake)"
cmd_monitor_tick WBOT                             # tick2: stale -> the wake fires
eq "nudge tick2: wake fires"  "1" "$(nwake)"
eq "nudge replaces the stale alert" "0" "$(nmsg "$CLAUDE_BUS_ROOT/inbox/WBOT")"
# the SUCCESS line specifically: grepping the target name alone passes identically on
# `nudge-FAILED`, so it would certify a wakebot that never actually woke anyone
has "wake exec is logged for audit" "$(cat "$CLAUDE_BUS_ROOT/log/WBOT/wake.log" 2>/dev/null)" "nudge WBOT -> NAP"
# the argv is the monitor's own: its socket, its pane, and text the MONITOR composed
has "wake targets the registered pane"   "$(cat "$WOKE")" "send-keys -t %7"
has "wake uses the registered socket"    "$(cat "$WOKE")" "-S $SOCK"
has "wake types the drain instruction"   "$(cat "$WOKE")" "drain NAP"
cmd_monitor_tick WBOT; cmd_monitor_tick WBOT      # cadence: silent while it stays stuck
eq "nudge respects the cadence" "1" "$(nwake)"
cmd_monitor_tick WBOT                             # WAKE_EVERY ticks on -> nudge again
eq "nudge re-fires after WAKE_EVERY" "2" "$(nwake)"
BUS drain NAP >/dev/null 2>&1                     # it woke up and drained -> stop nudging
cmd_monitor_tick WBOT; cmd_monitor_tick WBOT; cmd_monitor_tick WBOT
eq "drained target stops the wake" "2" "$(nwake)"

# A typo'd or hostile CLAUDE_BUS_WAKE_EVERY must not silently break the cadence:
# non-numeric falls back to the default (it used to fire once, then never re-fire,
# because the arithmetic compare errored inside an `if` where set -e cannot see it),
# and 0 must not storm one nudge per tick.
: > "$WOKE"
BUS init WEV >/dev/null
nudgereg NAP2 %8
BUS watch WEV NAP2 --nudge >/dev/null
BUS send NAP2 s "hi" >/dev/null
CLAUDE_BUS_WAKE_EVERY=abc cmd_monitor_tick WEV     # tick1: under threshold
CLAUDE_BUS_WAKE_EVERY=abc cmd_monitor_tick WEV     # tick2: stale -> first fire
eq "junk WAKE_EVERY still fires once" "1" "$(nwake)"
CLAUDE_BUS_WAKE_EVERY=abc cmd_monitor_tick WEV
CLAUDE_BUS_WAKE_EVERY=abc cmd_monitor_tick WEV
CLAUDE_BUS_WAKE_EVERY=abc cmd_monitor_tick WEV     # 3 ticks on (the default cadence)
eq "junk WAKE_EVERY re-fires on the default" "2" "$(nwake)"
: > "$WOKE"
BUS init WEV0 >/dev/null
nudgereg NAP3 %9
BUS watch WEV0 NAP3 --nudge >/dev/null
BUS send NAP3 s "hi" >/dev/null
CLAUDE_BUS_WAKE_EVERY=0 cmd_monitor_tick WEV0
CLAUDE_BUS_WAKE_EVERY=0 cmd_monitor_tick WEV0      # first fire
CLAUDE_BUS_WAKE_EVERY=0 cmd_monitor_tick WEV0      # must not storm
eq "WAKE_EVERY=0 does not nudge every tick" "1" "$(nwake)"

# a wedged tmux must not stall the whole monitor loop (every other watch would stop
# being checked). A server that will not even answer the ownership query cannot be
# verified, so the nudge is bounded, refused, and degraded to a stale alert.
: > "$WOKE"
BUS init WHANG >/dev/null
nudgereg NAPH %10
BUS watch WHANG NAPH --nudge >/dev/null
BUS send NAPH s "hi" >/dev/null
cmd_monitor_tick WHANG
SECONDS=0; FAKE_TMUX_HANG=1 CLAUDE_BUS_WAKE_TIMEOUT=1 cmd_monitor_tick WHANG
eq "a wedged tmux is bounded"                 "0" "$([ "$SECONDS" -lt 15 ]; echo $?)"
eq "a wedged tmux sends nothing"              "0" "$(nwake)"
has "a wedged tmux degrades to a stale alert" "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/WHANG/*.msg 2>/dev/null | head -1)")" "stale NAPH"

# ownership verifies (the server answers display-message), but the send-keys itself
# fails: that IS a nudge attempt, so it counts as no wake and is logged nudge-FAILED.
: > "$WOKE"
BUS init WSF >/dev/null
nudgereg NAPSF %31
BUS watch WSF NAPSF --nudge >/dev/null
BUS send NAPSF s "hi" >/dev/null
cmd_monitor_tick WSF
FAKE_TMUX_FAIL_SEND=1 cmd_monitor_tick WSF
eq "a failed send is not counted as woken" "0" "$(nwake)"
has "a failed send is logged nudge-FAILED"  "$(cat "$CLAUDE_BUS_ROOT/log/WSF/wake.log" 2>/dev/null)" "nudge-FAILED"

# The exec timeout is validated like the cadence: coreutils reads `timeout 0` as
# UNBOUNDED, which would silently re-open the tick-stalling hang, and a non-numeric
# makes timeout exit 125 so every nudge dies with only a FAILED line nobody reads.
: > "$WOKE"
BUS init WTO >/dev/null
nudgereg NAPT %12
BUS watch WTO NAPT --nudge >/dev/null
BUS send NAPT s "hi" >/dev/null
cmd_monitor_tick WTO
SECONDS=0; FAKE_TMUX_HANG=1 CLAUDE_BUS_WAKE_TIMEOUT=0 cmd_monitor_tick WTO
eq "WAKE_TIMEOUT=0 is still bounded" "0" "$([ "$SECONDS" -lt 20 ]; echo $?)"
: > "$WOKE"
BUS init WTO2 >/dev/null
nudgereg NAPT2 %13
BUS watch WTO2 NAPT2 --nudge >/dev/null
BUS send NAPT2 s "hi" >/dev/null
CLAUDE_BUS_WAKE_TIMEOUT=abc cmd_monitor_tick WTO2
CLAUDE_BUS_WAKE_TIMEOUT=abc cmd_monitor_tick WTO2
eq "junk WAKE_TIMEOUT still wakes" "1" "$(nwake)"

# dead outranks the nudge: waking a corpse is pointless and the watcher must still
# hear that it died (the axes are priority-ordered, and the nudge sits under them).
: > "$WOKE"
BUS init WDN >/dev/null
nudgereg NAPD %14
BUS watch WDN NAPD --nudge >/dev/null
BUS send NAPD s "hi" >/dev/null
probe_snapshot() { echo '{"alive":0,"net":0,"oom":0,"mtime":0,"known":true}'; }
cmd_monitor_tick WDN; cmd_monitor_tick WDN
eq "a dead target is not nudged"   "0" "$(nwake)"
has "a dead target still alerts"   "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/WDN/*.msg 2>/dev/null | head -1)")" "dead NAPD"
probe_snapshot() { echo '{"alive":0,"net":0,"oom":0,"mtime":0,"known":false}'; }

# nudge/wl sit BEFORE the empty-able `last` in the @tsv row, so a junk value in either
# would collapse the columns under read's IFS and freeze the record forever (ticks stop
# advancing: never stale, never alerts, silently). They must fail closed instead.
BUS init WTSV >/dev/null
mkdir -p "$CLAUDE_BUS_ROOT/watch/WTSV"
jq -n '{target:"TSINK",drain_max:2,role:"supervisor",nudge:"",wl:"",last:"",ticks:0}' \
  > "$CLAUDE_BUS_ROOT/watch/WTSV/TSINK.json"
BUS send TSINK s "stuck" >/dev/null
cmd_monitor_tick WTSV; cmd_monitor_tick WTSV
eq "a corrupt record still advances its ticks" "2" "$(jq -r .ticks "$CLAUDE_BUS_ROOT/watch/WTSV/TSINK.json")"
has "a corrupt nudge field falls back to a stale alert" \
  "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/WTSV/*.msg 2>/dev/null | head -1)")" "stale TSINK"

# THE SECURITY CONTROL. The bus root is bound read-write into every sandbox and all
# agents share one uid, so ANY agent can hand-write another's meta — register-time
# validation is UX, not a control. The monitor must therefore re-validate at exec and
# refuse to act on a hostile record, rather than exec a shell.
: > "$WOKE"
BUS init WSEC >/dev/null
BUS register EVIL --cgroup /x >/dev/null
BUS watch WSEC EVIL --nudge >/dev/null
BUS send EVIL s "hi" >/dev/null
jq '.wake={tmux_socket:"'"$SOCK"'",pane:"$(touch '"$CLAUDE_BUS_ROOT"'/pwned); rm -rf /"}' \
  "$CLAUDE_BUS_ROOT/meta/EVIL.json" > "$CLAUDE_BUS_ROOT/meta/EVIL.tmp" && mv "$CLAUDE_BUS_ROOT/meta/EVIL.tmp" "$CLAUDE_BUS_ROOT/meta/EVIL.json"
cmd_monitor_tick WSEC; cmd_monitor_tick WSEC
eq "a hand-written hostile pane executes nothing" "1" "$([ -e "$CLAUDE_BUS_ROOT/pwned" ]; echo $?)"
eq "a hostile pane is not sent to tmux at all"    "0" "$(nwake)"
has "a hostile pane degrades to a stale alert"    \
  "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/WSEC/*.msg 2>/dev/null | head -1)")" "stale EVIL"
# a socket that is not actually a socket (a planted regular file) is refused too
: > "$WOKE"
BUS init WSEC2 >/dev/null
BUS register EVIL2 --cgroup /x --wake-pane %11 --wake-socket "$CLAUDE_BUS_ROOT/notasock" >/dev/null
: > "$CLAUDE_BUS_ROOT/notasock"
BUS watch WSEC2 EVIL2 --nudge >/dev/null
BUS send EVIL2 s "hi" >/dev/null
cmd_monitor_tick WSEC2; cmd_monitor_tick WSEC2
eq "a non-socket wake path is refused" "0" "$(nwake)"

# PANE-OWNERSHIP: even a well-formed pane %id and a valid socket are refused unless the
# pane's LIVE pane_pid sits in the target's registered cgroup. This is what stops a
# hostile record aiming an otherwise-valid nudge at another pane (an operator's shell or
# editor, or a different agent). The record is attacker-writable, so the check is at exec
# against a LIVE-read pid, not the stored record.
: > "$WOKE"
BUS init WSEC3 >/dev/null
# valid socket + valid pane, but the target's cgroup does NOT contain FAKE_PANE_PID's cg
BUS register EVIL3 --cgroup /not/the/runners/scope --wake-socket "$SOCK" --wake-pane %20 >/dev/null
BUS watch WSEC3 EVIL3 --nudge >/dev/null
BUS send EVIL3 s "hi" >/dev/null
cmd_monitor_tick WSEC3; cmd_monitor_tick WSEC3
eq "a pane not owned by the target is not nudged" "0" "$(nwake)"
has "an unowned pane degrades to a stale alert" \
  "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/WSEC3/*.msg 2>/dev/null | head -1)")" "stale EVIL3"
# and the positive: when the pane_pid genuinely resolves into the target's cgroup, it fires
: > "$WOKE"
BUS init WSEC4 >/dev/null
nudgereg OWN %21
BUS watch WSEC4 OWN --nudge >/dev/null
BUS send OWN s "hi" >/dev/null
cmd_monitor_tick WSEC4; cmd_monitor_tick WSEC4
eq "a pane owned by the target IS nudged" "1" "$(nwake)"

# Upgrade path: watch records persist on disk, so a monitor running this version will
# read records written by the PREVIOUS one, which have no nudge/wl fields. They must
# keep behaving exactly as before (plain stale alert), not break or start nudging.
BUS init WOLD >/dev/null
mkdir -p "$CLAUDE_BUS_ROOT/watch/WOLD"
jq -n '{target:"OSINK",drain_max:2,role:"supervisor",last:"",ticks:0}' > "$CLAUDE_BUS_ROOT/watch/WOLD/OSINK.json"
BUS send OSINK s "stuck" >/dev/null
cmd_monitor_tick WOLD; cmd_monitor_tick WOLD
has "a pre-upgrade watch record still alerts stale" \
  "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/WOLD/*.msg | head -1)")" "stale OSINK"

# a nudge watch on a target that registered NO wake (a non-tmux agent) must not go
# silent: it falls back to the ordinary stale alert so the signal is not lost.
BUS init WBOT2 >/dev/null
BUS watch WBOT2 DEAF --nudge >/dev/null
BUS send DEAF SENDER "hi" >/dev/null
cmd_monitor_tick WBOT2; cmd_monitor_tick WBOT2
has "unwakeable target falls back to a stale alert" \
  "$(jq -r .body "$(ls "$CLAUDE_BUS_ROOT"/inbox/WBOT2/*.msg | head -1)")" "stale DEAF"

#############################################################################
# S2-28: arithmetic-injection defense. The monitor reads numeric fields out of
# watch/pending records and feeds them to bash arithmetic; bash re-evaluates a
# variable's VALUE as an expression, so a field like `dmax[$(cmd)]` runs cmd in the
# HOST monitor. Any same-uid agent can hand-write these records (bind-mounted bus
# root), so the coercion must happen at READ time, not at the write-path validation
# the attacker bypasses. set -u does NOT help: the payload names an in-scope var.
#############################################################################
probe_snapshot() { echo '{"alive":1,"net":0,"oom":0,"mtime":0,"known":false}'; }
rm -f "$CLAUDE_BUS_ROOT/PWNED_WATCH" "$CLAUDE_BUS_ROOT/PWNED_PENDING"
# a hostile WATCH record: .ticks is an arithmetic payload naming an in-scope local
BUS init WARITH >/dev/null
BUS send ASINK sender "stuck" >/dev/null
mkdir -p "$CLAUDE_BUS_ROOT/watch/WARITH"
jq -n --arg l "$(ls "$CLAUDE_BUS_ROOT"/inbox/ASINK/*.msg | head -1 | xargs -n1 basename)" \
  '{target:"ASINK",drain_max:2,role:"supervisor",last:$l,ticks:"dmax[$(touch '"$CLAUDE_BUS_ROOT"'/PWNED_WATCH)]"}' \
  > "$CLAUDE_BUS_ROOT/watch/WARITH/ASINK.json"
cmd_monitor_tick WARITH; cmd_monitor_tick WARITH
eq "hostile watch .ticks executes nothing" "1" "$([ -e "$CLAUDE_BUS_ROOT/PWNED_WATCH" ]; echo $?)"
# and a hostile drain_max on the other arithmetic site (-ge) is inert too
rm -f "$CLAUDE_BUS_ROOT/PWNED_DMAX"
jq -n --arg l "$(ls "$CLAUDE_BUS_ROOT"/inbox/ASINK/*.msg | head -1 | xargs -n1 basename)" \
  '{target:"ASINK",drain_max:"role[$(touch '"$CLAUDE_BUS_ROOT"'/PWNED_DMAX)]",role:"supervisor",last:$l,ticks:1}' \
  > "$CLAUDE_BUS_ROOT/watch/WARITH/ASINK.json"
cmd_monitor_tick WARITH; cmd_monitor_tick WARITH
eq "hostile watch .drain_max executes nothing" "1" "$([ -e "$CLAUDE_BUS_ROOT/PWNED_DMAX" ]; echo $?)"
# a hostile PENDING record: .ticks feeds `ticks=$((ticks+1))` unconditionally (line 563,
# before any baseline gate), so it is the reachable arithmetic site in the other loop
BUS init OARITH >/dev/null
mkdir -p "$CLAUDE_BUS_ROOT/pending/OARITH"
jq -n '{state:"sent",peer:"P",id:"1-1",flat:0,ticks:"flat_max[$(touch '"$CLAUDE_BUS_ROOT"'/PWNED_PENDING)]",baseline:null,alerted:""}' \
  > "$CLAUDE_BUS_ROOT/pending/OARITH/1-1.json"
cmd_monitor_tick OARITH; cmd_monitor_tick OARITH
eq "hostile pending .ticks executes nothing" "1" "$([ -e "$CLAUDE_BUS_ROOT/PWNED_PENDING" ]; echo $?)"
# the non-obvious site: the pending record's .baseline is passed into classify(), whose
# (( co > bo )) comparisons evaluate baseline.oom/.net/.mtime as arithmetic. A live
# registered peer makes the current probe known+alive, so the oom compare is reached.
rm -f "$CLAUDE_BUS_ROOT/PWNED_BASELINE"
probe_snapshot() { echo '{"alive":1,"net":0,"oom":0,"mtime":0,"known":true}'; }
BUS init OARITH2 >/dev/null
mkdir -p "$CLAUDE_BUS_ROOT/pending/OARITH2"
jq -n '{state:"sent",peer:"LIVE",id:"1-1",flat:0,ticks:0,alerted:"",baseline:{alive:1,net:0,mtime:0,known:true,oom:"flat_max[$(touch '"$CLAUDE_BUS_ROOT"'/PWNED_BASELINE)]"}}' \
  > "$CLAUDE_BUS_ROOT/pending/OARITH2/1-1.json"
cmd_monitor_tick OARITH2; cmd_monitor_tick OARITH2
eq "hostile baseline in classify executes nothing" "1" "$([ -e "$CLAUDE_BUS_ROOT/PWNED_BASELINE" ]; echo $?)"
probe_snapshot() { echo '{"alive":0,"net":0,"oom":0,"mtime":0,"known":false}'; }

#############################################################################
echo "----"; echo "pass=$pass fail=$fail"; [[ $fail -eq 0 ]]
