#!/usr/bin/env bash
# A claude-bus inbox watch for the Claude Code Monitor tool: Monitor on 'bash bus-watch.sh <me>' (DN 10-15).
# Emits one line when a NON-ack message has sat undrained for GRACE seconds, then repeats it every REMIND
# seconds until that backlog is drained. Acks never wake the agent (they are drained with the next real message), same rule as
# the old one-shot wait. The grace keeps it silent during a live turn, when the agent drains within seconds.
# Senders listed one per line in $BUS/quiet-senders/<me> do not wake the agent either (DN 10-27, cost: each wake
# re-reads the whole context); their mail is drained with the next real message or the 30-min re-arm.
ME="${1:?usage: bus-watch.sh <me>}"
BUS="${CLAUDE_BUS_ROOT:-$HOME/.cache/claude-bus}"
INBOX="$BUS/inbox/$ME"
QUIET="$BUS/quiet-senders/$ME"
GRACE=${BUS_WATCH_GRACE:-10}
# Repeat the line while the same backlog stays undrained (kaizen 10-29 F1: mgr missed the single line 3 times).
REMIND=${BUS_WATCH_REMIND:-180}
[[ "$REMIND" =~ ^[0-9]+$ ]] && [ "$REMIND" -ge 3 ] || REMIND=180
shopt -s nullglob

is_quiet() {
  [ -f "$QUIET" ] || return 1
  local sender="${1##*.from-}"
  grep --quiet --line-regexp --fixed-strings "${sender%.msg}" "$QUIET"
}

real_msgs() {
  local f
  for f in "$INBOX"/*.msg; do
    grep --quiet --extended-regexp '"kind": *"ack"' "$f" && continue
    is_quiet "$f" && continue
    printf '%s\n' "$f"
  done
}

summary() {
  local senders
  senders=$(printf '%s\n' "$1" | sed -E 's/.*\.from-([^.]+)\.msg/\1/' | sort | uniq --count | tr -s ' \n' ' ')
  echo "$(printf '%s\n' "$1" | wc --lines) real msg (from:${senders})"
}

any_left() {
  local f
  while read -r f; do [ -e "$f" ] && return 0; done <<<"$1"
  return 1
}

while true; do
  if [ -n "$(real_msgs)" ]; then
    sleep "$GRACE"
    pending="$(real_msgs)"
    if [ -n "$pending" ]; then
      echo "bus: $(summary "$pending") waiting - drain $ME"
      # Wait for THESE messages to go, not for an empty inbox: mail that lands while the agent drains must wake it
      # again (10-28: a message 2.4 s after a drain kept the inbox non-empty through every 3 s poll, 5 min silent).
      waited=0
      while any_left "$pending"; do
        if [ "$waited" -ge "$REMIND" ]; then
          # Count the inbox as it is now: part of the batch may be gone and new mail may have joined it.
          echo "bus: still undrained: $(summary "$(real_msgs)") - drain $ME"
          waited=0
        fi
        sleep 3; waited=$((waited + 3))
      done
    fi
  fi
  sleep 2
done
