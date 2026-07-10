# claude-bus: design

A file-based message bus between independent Claude sessions on one machine, with
delivery acks and out-of-process liveness so an orchestrator can tell a working
agent from a stalled or dead one.

## Status

Built and tested: the transport layer (`init`, `send`, `send-path`, `wait`,
`drain`), the ack and expectation model (`dispatch`, `reply`, `pending`, `close`,
auto-ack on drain), the liveness layer described below, the probe (`register`,
`probe-snapshot`, the pure `classify`) and the per-orchestrator monitor (`monitor`,
`monitor-tick`), the expectation-free watch (`watch`, `unwatch`) that flags a
persistent sink on three axes, `dead` (its process tree is gone), `erroring` (its
transcript ends on an unresolved API error) and `stale` (its inbox stops draining),
and the secretary membrane (`delegate`
for transparent inbox interception, `forward` for verbatim relay, and the
drained-message `log/`).
It all sits on the same foundation: plain files and a backgrounded
process whose exit re-invokes the model. There is no always-on daemon; the only
background process is a thin per-orchestrator monitor that lives just as long as
work is outstanding.

Registration is wired into `init`: a worker that joins the bus from inside its own
scope (a dbox session runs under `systemd-run --user --scope`) auto-detects its
scope cgroup and writes `meta/<name>.json`, so it is monitorable with no extra step.
`init` skips this when the caller sits in a shared user slice rather than a dedicated
unit, because registering the shared slice would read as immortal. The only remaining
optional wiring is the launch wrapper calling `register` explicitly to supply the
transcript path (which sharpens working versus retrying) or to register a worker that
cannot self-detect its cgroup.

`register` MERGES: a field not passed on a call inherits the prior meta, so the two
parties that each know only half can register independently without clobbering. The
launch wrapper supplies `--cgroup` (the container's real cgroup, which the agent
cannot see from inside its own cgroup namespace) and `--transcript`; the agent's own
`init` refreshes its scope cgroup and leaves the transcript untouched. An empty flag
value means inherit, not clear, so a wrapper passing an unset variable cannot blank a
correct field, and a reused bus name never keeps a dead prior session's scope. A
failed meta write is surfaced loudly rather than silently reported as success.
`register <worker> --supervisor <parent>` additionally wires the parent's watch of
the worker at spawn (create-if-absent, so it never resets a live record), which is
how a secretary that spawns fresh coats in batches learns when one of them 529s
without hand-wiring each ephemeral worker. That auto-watch is erroring-only by
default (role `ephemeral`): a worker dying is its normal terminal state, so a clean
death is silent and the record is garbage-collected, keeping a churning fleet quiet,
while erroring and stale still alarm. A worker that dies mid-error is not a clean
exit, so its final API-error status is surfaced once before the record is reaped.
The death-alarm is opt-in via `--role supervisor`, for a long-lived agent whose
unexpected exit is itself the incident; `watch` (used for the persistent
supervisors) defaults to that role, and a record with no role field reads as
`supervisor`, so a legacy watch keeps alarming on death.

## The layers

### 1. Transport (built)

One inbox directory per session under `$CLAUDE_BUS_ROOT`. `send` atomically drops
a short message, `wait` blocks in the background until a message lands and its
exit re-invokes the receiver, `drain` prints and clears the inbox. Large payloads
travel by path via `send-path`, never inline.

### 2. Ack: a property of reading, not of the agent

Every message already carries an id (its timestamp). `drain` auto-emits an
`ack <id>` back to the sender for each message it pops. The ack is a side effect
of reading, not a step the agent has to remember. An agent that never drains
never read the message, so withholding the ack there is the correct behavior, not
a lost ack. This is why ack lives inside `drain` rather than in the agent's
discretion.

The bus has carried a single boundary-test message in its life, and it sat
undrained, so we do not assume agents will choose to ack. Binding ack to the read
removes that assumption.

An ack is not terminal. It confirms receipt and keeps the task in WORKING. Only a
`done` result or a decision-request closes the expectation (see below).

The ack does not create a feedback loop, which is a real risk worth being explicit
about. Draining lands the ack in the sender's inbox, not your own, so your own
drain never re-invokes you. And acks are themselves never acked: `drain` emits an
ack for a content message but not for an ack, so the chain is exactly one hop and
stops. Session B receiving a message wakes once, drains, and acks A. A wakes once
to clear its pending entry, drains the ack, and emits nothing further. No
ping-pong.

Draining does not re-trigger your own wake either. The backgrounded `wait` has
already exited by the time you drain, that exit is what woke you, so the deletes
happen with no watcher armed, and you re-arm `wait` only after the inbox is empty.
Even if it were armed, the watch fires on a new file arriving, not on a removal, and
`drain` removes only `.msg` files, never the `.keep` sentinel it actually watches.
So the only thing that ever wakes a session is a genuinely new inbound message.

### 3. Expectation: what liveness is scoped to

Liveness is not a free-running heartbeat. It exists only while an orchestrator is
expecting an agent to be working. That expectation is a file, `pending/<id>`,
written by the orchestrator when it dispatches work. It holds the peer name, the
dispatch time, and a baseline liveness snapshot.

A dispatched task moves through these states:

- WORKING: the expectation is open and the orchestrator expects a result.
  Liveness is sampled.
- AWAITING_ORCH: the agent sent back a question or a decision-request. The ball is
  now in the orchestrator's court, the agent is legitimately idle, so liveness
  stops. The orchestrator is not bombarded, and the agent is never pinged for
  being blocked on the orchestrator.
- DONE: the agent sent a result. The expectation closes and liveness stops.
- IDLE: nothing pending, no liveness at all.

Liveness runs only in WORKING. The moment the agent finishes or hands a decision
back, it goes quiet.

### 4. The monitor: automatic, not the orchestrator's job

The orchestrator should not run the wait-and-probe loop itself. It dispatches work
and forgets. A thin external monitor, a backgrounded shell loop and not an agent,
does the juggling: it watches the open expectations in `pending/`, ticks every 3
minutes (configurable), runs the liveness probe, and only when it finds unliveness
(dead, OOM-killed, or stalled past the threshold) does it drop a message into the
orchestrator's own inbox. Normal completion still arrives as the worker's own
`done` message.

So from the orchestrator's seat, both outcomes look the same: mail in its inbox.
"worker S3 finished" and "worker S3 is dead" arrive the same way, through the
normal push that re-invokes it. The orchestrator never runs a probe or classifies
state in its own reasoning, which keeps its context clean. It only ever hears about
unliveness, never about liveness.

This is a per-orchestrator sidecar, not a global daemon. The orchestrator launches
it in the background, passing its own mailbox name, since only the orchestrator
knows that name. From then on the orchestrator forgets it: launching one background
process is a single fire-and-forget action, not the ongoing juggling of running the
loop in its own turns.

The monitor reports unliveness by `send`-ing to that mailbox, so the alert arrives
through the orchestrator's normal inbox `wait`, the same single wake channel as
every other message, not through the monitor's own exit. It reads the same
`pending/` files each tick and exits when no expectation remains. Each tick does
double duty, catch a terminal message or sample liveness, on the one 3-minute knob.
Only the owner moved, from the orchestrator's turn loop to a dumb adjacent process.

The monitor watches two independent axes, not just process liveness. One is the
probe below (dead, OOM, stalled), which needs a registered peer. The other is
ack-timeliness: an expectation still in `sent` past `ACK_MAX` ticks means the worker
never read the message, so it never acked. That fires an `unacked` alert, and it
needs no probe or registration, because it is a fact about the expectation's state,
not the process. It catches the case the probe cannot: a worker that is alive and
busy with other work, so the probe reads `working`, yet never drained your task.
Priority is dead/oom, then unacked, then stalled.

Both of those axes hang off an expectation the orchestrator holds. A persistent
sink has none: a secretary that fronts a coordinator's inbox, or an oncall session,
receives mail by `send`, `forward`, or a delegated redirect, not by a tracked
`dispatch`. So when one goes dark, and the failure that exposed this was a
server-side rate limit that left the process alive but unable to act, nothing points
at it and its freeze is invisible. `watch <me> <target>` closes that, on three
failure modes the expectation path already knows but without needing an expectation.
If the target is registered, each tick probes its process tree and sends a `dead`
alert when it is gone, the OOM or crash case (an instrumented build blowing past the
sandbox's memory cap and getting SIGKILL'd is exactly this). If instead it is alive
but its registered transcript ends on an unresolved API error, it sends an `erroring`
alert carrying the HTTP status, the rate-limit or server-error case, read from the
structured `isApiErrorMessage` entry Claude Code writes rather than by scraping a
screen. And it remembers the oldest undrained message in the target's inbox and
sends a `stale` alert if the same one persists past `DRAIN_MAX` ticks, the hung-but-
alive case. Priority is `dead`, then `erroring`, then `stale`: a gone process cannot
drain, and a stuck-erroring one is more specific than merely quiet. None of these
needs cooperation from the target (a rate-limited session cannot self-report), and
the drain axis resets the moment the target drains, so a merely slow sink never
false-alarms. `dead` needs no baseline (a death is a death), and `erroring` reads the
cause straight from the transcript, which is why it beats a naive transcript-mtime-
flat check: flatness cannot separate a frozen agent from one healthily idle between
tasks. This is liveness for the agents no expectation covers.

The alert lands in the watcher's own inbox, so routing is the watch relationship
itself: there is no `parent` field on the agent and no global tree the bus
maintains. A supervisor watches its direct children, and their `dead`/`erroring`/
`stale` events surface to it; each supervisor owns its own watch list, so the
hierarchy (a coordinator watching its secretaries, a secretary watching the workers
it spawned) emerges from who-watches-whom rather than from any central registry.
`register --supervisor` is just the shorthand that creates that watch at spawn.

### 5. Liveness probe: stateless and out-of-process

The monitor runs this, not the orchestrator. A pure read of four OS-level signals
for the peer, with no memory of its own:

- PID alive. Gone means dead, escalate now.
- Network bytes for the peer's process tree, summed from `ss` over the tree's
  sockets. Advancing means it is talking to the API, whether working or retrying.
  Flat means silent.
- Transcript file mtime. Growing means it is producing output.
- OOM kills in the tree, the `oom_kill` counter in the scope cgroup's
  `memory.events`. Any increase since dispatch means the kernel reaped a process in
  the tree under the memory cap. This is the signal that catches a dead subagent
  while the main process lives on, which the other three miss.

The probe reads kernel-held numbers and exits. The baseline captured in
`pending/<id>` at dispatch turns the later sample into a simple then-vs-now diff,
which is why nothing of ours has to run in between.

Classification from the diff:

- counter up, transcript up: healthy, working.
- counter up, transcript flat: grinding through 429 or 529 retries, alive, keep
  waiting. This is the case no on-disk signal can see, because retries are
  transparent until they exhaust.
- counter flat, PID alive, in a benign idle state: it will pick up mail when it
  re-arms.
- counter flat, PID gone: dead, escalate.
- oom_kill up since baseline: a process in the tree was OOM-killed. If the main pid
  is also gone it is the dead case above. If the main pid survives, a child or
  subagent died and the awaited result will never arrive, so escalate with that
  specific reason rather than waiting out the full timeout.

In-process signals (hooks, transcript writes, statusline) are cooperative and go
dark exactly when a process wedges, so liveness leans on the out-of-process
signals. The one cooperative signal worth keeping is the `permission_prompt`
notification, used only to tell a permission block apart from a wedge, never as a
heartbeat.

### 6. Tree scoping: teams of agents

The bytes must cover the agent's whole process tree, because an agent that is
itself an orchestrator may be quiet while its subagents do the API work.

The sessions here share the host network namespace and are not automatically under
workit, so a per-session netns counter does not apply. What every dbox session does
have is its own transient `systemd-run --user --scope`, whose cgroup lists the
entire session subtree in `cgroup.procs`. That is the tree handle: read the pid set
from the scope's `cgroup.procs`, then sum `ss` byte counters across those pids'
sockets. A parent awaiting a busy child still reads as alive because the child's
pid is in the same scope.

This path is unprivileged. The privileged alternatives, a custom cgroup eBPF
egress program or systemd `IPAccounting`, are out: a live test showed user-scope
`IPAccounting` reports `no`, because installing the BPF accounting program needs
capabilities the user manager lacks.

Validated with a throwaway tree: a parent forking three network-looping children
under a `systemd-run --user` scope. From outside, `cgroup.procs` listed all seven
pids and `ss` returned live `bytes_acked` for their sockets, all unprivileged. One
caveat fell out of it. `ss` only shows sockets open at the instant you look, so
short-lived connections are caught by luck. The real claude-to-API connection is
long-lived keep-alive and so is reliably visible, but the probe should still sample
a few times across the tick rather than trust a single instant, and diff
`bytes_acked` only within one persistent socket.

### Registration

The probe needs to map a bus name to its pid, its systemd scope (for the
`cgroup.procs` pid set), and its transcript path. The launch wrapper (workit, dbox)
knows all of this at spawn and writes a static `meta/<name>.json` once. No hook and
no cooperation from the running session, since the in-process signals are the ones
that go dark when a session stalls.

## Data format

Everything structured is JSON: the message envelope (`{from, to, ts, id, ref,
kind, body}`, where `id` is unique per message and `ref` is the task it
correlates to), `meta/<name>.json`, and the `pending/<id>` records. The reason is the
toolset already in reach. `jq` is everywhere for the shell side, and Python ships
`json` in the standard library. YAML would pull in PyYAML, and TOML reads with
`tomllib` but has no standard-library writer, which is awkward when bash is the one
writing these files via `jq -n`. So JSON is the path of least resistance for both
the shell producers and the Python or `jq` consumers. The message `body` stays a
plain string field, so a human can still read an envelope at a glance.

## Why stateless

The only continuously updated state is the network counter, and the kernel
already keeps it. Everything else is on disk (pending files, baselines, meta).
The per-orchestrator monitor holds no state of its own either: it re-reads the
`pending/` files and the kernel counters each tick, so killing and respawning it
loses nothing. That is the line between this sidecar and a real daemon. A global
always-on daemon would earn its place only if you later want a health view of
sessions that nobody is currently waiting on, and it would read the same probe.

## Resolved and open

Resolved:

- Counter backbone: the session's systemd-scope `cgroup.procs` for the tree pid
  set, plus `ss` byte deltas across those pids' sockets. Unprivileged. netns
  counters do not apply, because normal sessions share the host network namespace
  and workit is opt-in (one active worktree pod at last check). systemd
  `IPAccounting` is unavailable to user scopes, confirmed by a live test that
  reported `no`.
- Interval: 3 minutes by default, configurable through one knob shared by the
  waiter and the liveness tick.

Open:

- No-traffic window: do not escalate on a single flat tick. Require two consecutive
  flat ticks, about 6 minutes at the 3-minute interval, which comfortably exceeds
  any single exponential-backoff burst. As a positive cross-check, exhausted retries
  (without `CLAUDE_CODE_RETRY_WATCHDOG=1`) surface an API-error line in the
  transcript after roughly ten attempts, so a give-up becomes visible on disk
  anyway. The two-tick rule mainly covers the watchdog-on case, where retries never
  end and the transcript stays silent.
- The probe must handle both cases: the common host-netns dbox session and the
  occasional netns-isolated workit session.
- Source-side OOM handling, checked against systemd and Red Hat cgroup-v2 guidance:
  `OOMPolicy=kill` is the right call for an atomic tree kill (it sets
  `memory.oom.group=1`), so add `-p OOMPolicy=kill` to dbox's scope. Two refinements
  from the guidance. Set `MemoryHigh` below the `MemoryMax=12G` hard wall, say
  `MemoryHigh=10G`, so the cgroup is throttled and reclaimed under backpressure
  before the hard kill, since leaning on `MemoryMax` alone punishes a bursty
  workload that thrashes in reclaim first. And note that dbox's `MemorySwapMax=0`
  trades graceful degradation for a harder, faster kill, defensible for a
  containment sandbox but a conscious choice, not a free win. dbox today sets
  `MemoryMax=12G` and `MemorySwapMax=0` with no `OOMPolicy`, so the kernel reaps a
  single victim. The `oom_kill` probe still earns its keep as the diagnosis even
  with all of this set.
