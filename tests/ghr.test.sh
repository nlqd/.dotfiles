#!/usr/bin/env bash
# Tests for ghr's update path: a new release must be linked from its own files, even when
# the cache still holds an older extraction whose path the manifest names.
# Run: bash tests/ghr.test.sh
# shellcheck disable=SC1090
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$2' got '$3')"; fi; }
rc() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want rc=$2 got rc=$3)"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache" XDG_CONFIG_HOME="$TMP/config" HOME="$TMP/home"

source "$HERE/../.local/scripts/ghr"
ok "sourcing ghr did not run main"

# A release v5.0.1 whose archive unpacks to tool-v5.0.1/tool.
NEW_ASSET="tool-linux-x86_64-v5.0.1.tar.gz"
mkdir -p "$TMP/src/tool-v5.0.1"
printf '#!/bin/sh\necho 5.0.1\n' >"$TMP/src/tool-v5.0.1/tool"
chmod +x "$TMP/src/tool-v5.0.1/tool"
tar -czf "$TMP/$NEW_ASSET" -C "$TMP/src" tool-v5.0.1

gh_api() { printf '{"tag_name":"v5.0.1","assets":[{"name":"%s","browser_download_url":"https://example.invalid/%s"}]}' "$NEW_ASSET" "$NEW_ASSET"; }
curl() {
  local out=""
  while [ $# -gt 0 ]; do
    [ "$1" = "-o" ] && out="$2"
    shift
  done
  cp "$TMP/$NEW_ASSET" "$out"
}

# The cache still holds v4.0, and the manifest names its path.
DIR=$(get_dir "owner/tool")
mkdir -p "$DIR/tool-v4.0" "$TMP/bin"
printf '#!/bin/sh\necho 4.0\n' >"$DIR/tool-v4.0/tool"
chmod +x "$DIR/tool-v4.0/tool"
echo v4.0 >"$DIR/.version"
ln -s "$DIR/tool-v4.0/tool" "$TMP/bin/tool"
OLD_LINKS="{\"tool-v4.0/tool\":\"$TMP/bin/tool\"}"

restore_single "owner/tool" "tool-linux-x86_64-v4.0.tar.gz" "$OLD_LINKS" "[1/1]" "$TMP/result" quiet >/dev/null 2>&1
rc "update succeeds" 0 $?
eq "the link points at the new release's binary" "$DIR/tool-v5.0.1/tool" "$(readlink "$TMP/bin/tool")"
eq "the manifest records the new release's path" "tool-v5.0.1/tool" "$(cut -f4 "$TMP/result" | jq -r 'keys[0]')"

# The up-to-date check: a working link to some other file than the manifest names is stale.
ln -sf "$DIR/tool-v4.0/tool" "$TMP/bin/tool"
all_links_valid "{\"tool-v5.0.1/tool\":\"$TMP/bin/tool\"}" "$DIR"
rc "a link to an older extraction is not up to date" 1 $?
ln -sf "$DIR/tool-v5.0.1/tool" "$TMP/bin/tool"
all_links_valid "{\"tool-v5.0.1/tool\":\"$TMP/bin/tool\"}" "$DIR"
rc "a link to the named binary is up to date" 0 $?

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
