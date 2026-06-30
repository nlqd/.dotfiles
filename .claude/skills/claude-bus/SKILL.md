---
name: claude-bus
description: Use when one Claude session or process must message, hand off work to, or coordinate with another independent Claude session on the same machine, or dispatch a task to another session and track its acknowledgement or completion. Also use when native SendMessage cannot reach the target session (it is team-scoped and cannot reach one it did not spawn), or when told to coordinate over claude-bus.
---

# claude-bus

File-based mailbox for short messages between independent Claude sessions on one machine. The substitute for cross-session SendMessage, which is team-scoped and cannot reach a session it did not spawn. Script: `/home/dungngo/.claude/skills/claude-bus/claude-bus`. Mailboxes live under `$CLAUDE_BUS_ROOT` (default `/tmp/claude-bus`).

## The one thing you cannot discover by running it

Push works because a backgrounded `wait <me>` exits the moment mail lands, and a background command exiting re-invokes the model. So the loop per session is: `init <me>` once, then background `wait <me>`; when it exits, `drain <me>` to read and clear the inbox, act, then re-arm `wait` in the background. Always drain before re-arming. Run `wait` in the BACKGROUND, never the foreground, or it blocks the turn.

## The one hard rule

Short messages only. `send`, `dispatch`, and `reply` refuse a body over `$CLAUDE_BUS_MAX` bytes (default 1024). Pass anything large BY PATH with `send-path`: the content stays on disk, only the pointer travels. Do not chunk a long message into many sends.

## Everything else self-documents

Run `claude-bus` with no arguments for the command list, and follow the `next:` hint each command prints to stderr. For tracked work that expects a reply or completion, use `dispatch` (it opens an expectation), then `reply`, `pending`, and `close`. To catch a worker that stalls or dies, a worker `register`s at spawn (so the probe can find its process tree) and the orchestrator backgrounds `claude-bus monitor <me>`; unliveness (a dead, OOM-killed, or stalled worker, or one that never read the message so its expectation is stuck `sent`) arrives in the orchestrator's inbox as a `kind: alert` message. A persistent sink that holds no expectation of its own (a secretary, an oncall) can still be covered with `watch <me> <target>`: the monitor sends a `dead` alert if a registered `<target>`'s process tree is gone (OOM, crash) and a `stale` alert if its inbox stops draining, catching both a killed session and a rate-limited one that stays alive but goes dark. A secretary can front a coordinator's inbox with `delegate <coordinator> <secretary>` (transparent, senders keep addressing the coordinator) and relay an agent's verbatim report upward with `forward <me> <id> <to> [note]`. `drain` archives each message it reads into `log/<me>/`, which is what `forward` reads back. See `README.md` in this directory for the full design: the JSON envelope, the `sent -> acked -> done/awaiting_orch` expectation state machine, and the liveness probe and monitor.

## Constraints

- Same machine or shared filesystem only. It is files, not a network protocol.
- Depends on `entr` for the blocking watch.
- A session drains only its own inbox, one drain at a time.
