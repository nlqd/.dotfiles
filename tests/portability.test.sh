#!/usr/bin/env bash
# Tests for dotfiles portability. Run: bash tests/portability.test.sh [--write-baseline]
# Desktop (dungngo) and laptop (qd) share this repo, so a literal /home/<user> path works on one
# machine and breaks on the other. Files that are host-specific on purpose are allowed. Files that
# already offend are listed in tests/portability.known: the list may only shrink, so fixing one
# means removing it from the list (run with --write-baseline).
set -uo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
KNOWN="$HERE/portability.known"

# Per-host by design: ghr manifests, alacritty host configs, system udev rules (no $HOME there),
# remote-server ansible targets, docs, and vendored or generated files.
ALLOWED='^(\.config/alacritty/host_configs_.*|\.config/ghr/manifest-.*|\.config/udev/.*|ansible/.*|.*\.md|tests/.*|.*/resurrect/.*|.*/plugins/.*|.*\.bak.*)$'

offenders() {
  cd "$ROOT" || exit 1
  git ls-files -z \
    | xargs --null grep --files-with-matches --binary-files=without-match \
        --extended-regexp '/home/[a-z_][a-z0-9_-]*' 2>/dev/null \
    | grep --extended-regexp --invert-match "$ALLOWED" \
    | sort
}

if [ "${1-}" = "--write-baseline" ]; then
  offenders > "$KNOWN"
  echo "wrote $(wc --lines < "$KNOWN") files to $KNOWN"
  exit 0
fi

status=0

new=$(comm -23 <(offenders) "$KNOWN")
if [ -n "$new" ]; then
  echo "FAIL: hard-coded /home/<user> path, use \$HOME or ~ (or %h in systemd units):"
  printf '  %s\n' $new
  status=1
fi

stale=$(comm -13 <(offenders) "$KNOWN")
if [ -n "$stale" ]; then
  echo "FAIL: fixed but still listed in portability.known, run with --write-baseline:"
  printf '  %s\n' $stale
  status=1
fi

[ "$status" -eq 0 ] && echo "ok: no new hard-coded /home paths ($(wc --lines < "$KNOWN") known)"
exit "$status"
