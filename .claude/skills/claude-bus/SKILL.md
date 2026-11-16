---
name: claude-bus
description: Use when one Claude session or process must message, hand off work to, or coordinate with another independent Claude session on the same machine, or dispatch a task to another session and track its acknowledgement or completion. Also use when native SendMessage cannot reach the target session (it is team-scoped and cannot reach one it did not spawn), or when told to coordinate over claude-bus.
---

# claude-bus

File-based mailbox for short messages between independent Claude sessions on one machine. The substitute for cross-session SendMessage, which is team-scoped and cannot reach a session it did not spawn. Script: `/home/dungngo/.claude/skills/claude-bus/claude-bus`. Mailboxes live under `$CLAUDE_BUS_ROOT` (default `~/.cache/claude-bus`).

## The one thing you cannot discover by running it

Push works because a backgrounded `wait <me>` exits the moment mail lands, and a background command exiting re-invokes the model. So the loop per session is: `init <me>` once, then background `wait <me>`; when it exits, `drain <me>` to read and clear the inbox, act, then re-arm `wait` in the background. Always drain before re-arming. Run `wait` in the BACKGROUND, never the foreground, or it blocks the turn.

### In Claude Code, watch your inbox with a Monitor (the single-shot wait is brittle)

The `background wait -> drain -> re-arm` loop above makes you re-arm after every message, and a busy session reliably forgets: it gets absorbed in a multi-step task, never re-arms, and goes silently DEAF while mail piles up. If you have the Monitor tool, use the shared watch script instead:

```
Monitor(description: "bus: real mail in <me> inbox", timeout_ms: 1800000,
        command: "bash ~/.claude/skills/claude-bus/bus-watch.sh <me>")
```

It is edge-triggered so it never floods the too-many-events auto-stop: one line when a real (non-ack) message has sat undrained for 10 s, then quiet until you drain. Acks never wake you. On each event, `drain <me>` and act; no re-arm. The Claude Code build in use caps a Monitor at 30 minutes and has no persistent flag (10-15), so re-arm the same Monitor when its expiry notice arrives, and start it again after any restart or resume. The `wait`/`monitor` host commands below remain for non-Claude-Code processes and for cross-session liveness watching.

## The one hard rule

Short messages only. `send`, `dispatch`, and `reply` refuse a body over `$CLAUDE_BUS_MAX` bytes (default 1024). Pass anything large BY PATH with `send-path`: the content stays on disk, only the pointer travels. Do not chunk a long message into many sends.

## Everything else self-documents

Run `claude-bus` with no arguments for the command list, and follow the `next:` hint each command prints to stderr. For tracked work that expects a reply or completion, use `dispatch` (it opens an expectation), then `reply`, `pending`, and `close`. To catch a worker that stalls or dies, a worker `register`s at spawn (so the probe can find its process tree) and the orchestrator backgrounds `claude-bus monitor <me>` (on the HOST, never inside a sandbox: the monitor reads host cgroups, so from within a dbox it would read every agent dead and GC live workers — it refuses to run there); unliveness (a dead, OOM-killed, or stalled worker, or one that never read the message so its expectation is stuck `sent`) arrives in the orchestrator's inbox as a `kind: alert` message. A persistent sink that holds no expectation of its own (a secretary, an oncall) can still be covered with `watch <me> <target>`: the monitor sends a `dead` alert if a registered `<target>`'s process tree is gone (OOM, crash), an `erroring` alert with the HTTP status if its registered transcript ends on an unresolved API error (a rate limit or server error), and a `stale` alert if its inbox stops draining, catching a killed session, a throttled one, and a hung-but-alive one respectively. A `stale` alert only helps if someone is awake to read it, which is the very thing in doubt, so `watch <me> <target> --nudge` instead pushes the target directly: the monitor types a drain instruction into the pane the target self-registered at startup. The monitor stores no command and runs no shell for this — see `README.md` for why that matters. The alert lands in the watcher's inbox, so a supervisor watches its direct children and their failures route up to it; `register <worker> --supervisor <parent>` wires that watch at spawn, so a parent spawning many short-lived workers learns when one 529s without hand-wiring each `watch`. A `--supervisor` auto-watch is erroring-only by default (a worker's clean death is silent and its record is reaped, keeping a churning fleet quiet), with the death-alarm opt-in via `--role supervisor` for a long-lived agent that should never exit. A secretary can front a coordinator's inbox with `delegate <coordinator> <secretary>` (transparent, senders keep addressing the coordinator) and relay an agent's verbatim report upward with `forward <me> <id> <to> [note]`. `drain` archives each message it reads into `log/<me>/`, which is what `forward` reads back. See `README.md` in this directory for the full design: the JSON envelope, the `sent -> acked -> done/awaiting_orch` expectation state machine, and the liveness probe and monitor.

## Constraints

- Same machine or shared filesystem only. It is files, not a network protocol.
- Depends on `entr` for the blocking watch.
- A session drains only its own inbox, one drain at a time.
