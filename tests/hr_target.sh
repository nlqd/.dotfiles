#!/usr/bin/env bash
# Test target for hostrelay. Prints one argv per line, verbatim, unless the
# first argument is one of these test verbs:
#   sleep N          sleep N seconds, exit 0
#   exit N           exit with code N
#   stderr TEXT      print TEXT to stderr, exit 0
#   ignore-term N    ignore SIGTERM, sleep N seconds regardless (tests SIGKILL escalation)
#   touch-then-sleep FILE N   touch FILE, then sleep N (so a test can prove the process
#                              actually started before checking whether it got killed)
case "${1:-}" in
sleep)
  sleep "$2"
  exit 0
  ;;
exit)
  exit "$2"
  ;;
stderr)
  echo "$2" >&2
  exit 0
  ;;
ignore-term)
  trap '' TERM
  sleep "$2"
  exit 0
  ;;
touch-then-sleep)
  touch "$2"
  sleep "$3"
  exit 0
  ;;
esac
printf '%s\n' "$@"
