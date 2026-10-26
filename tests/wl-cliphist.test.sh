#!/usr/bin/env bash
# Tests for wl-cliphist. Run: bash tests/wl-cliphist.test.sh
# cliphist, fzf, chafa and wl-copy are stubs, so no clipboard or terminal is involved.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../.local/scripts/wl-cliphist"

W=$(mktemp --directory)
trap 'rm --recursive --force "$W"' EXIT
mkdir "$W/bin"
LOG="$W/log"

# cliphist: "list" prints entries; "decode" takes an id (argument) or an entry line (stdin).
cat > "$W/bin/cliphist" <<'EOF'
#!/bin/sh
case "$1" in
  list) printf '7\thello world\n6\t[[ binary data 1 KiB png 4x4 ]]\n' ;;
  decode)
    id=${2:-$(cut --fields=1)}
    case "$id" in
      6) printf '\211PNG\r\n\032\n\000\000\000\rIHDR\000\000\000\004\000\000\000\004\010\006\000\000\000' ;;
      *) printf 'text-of-%s' "$id" ;;
    esac ;;
esac
EOF
printf '#!/bin/sh\nhead --lines=1\n' > "$W/bin/fzf"                  # "selects" the first entry
printf '#!/bin/sh\necho "CHAFA $*"\n' > "$W/bin/chafa"
printf '#!/bin/sh\necho "wl-copy:$(cat)" >> "%s"\n' "$LOG" > "$W/bin/wl-copy"
chmod +x "$W/bin"/*

fail=0
check() {
  local name=$1 want=$2 got=$3
  if [ "$got" = "$want" ]; then echo "ok: $name"; else echo "FAIL: $name: want '$want', got '$got'"; fail=1; fi
}
run() { env PATH="$W/bin:/usr/bin:/bin" "$@" bash "$SCRIPT"; }

: > "$LOG"; run >/dev/null 2>&1
check "picking an entry copies its decoded content" "wl-copy:text-of-7" "$(cat "$LOG")"

check "preview of text shows the text" "text-of-7" "$(env PATH="$W/bin:/usr/bin:/bin" bash "$SCRIPT" --preview 7)"

check "preview of an image renders it with chafa in sixel" \
  "CHAFA --format=sixel --size=40x20" \
  "$(env PATH="$W/bin:/usr/bin:/bin" FZF_PREVIEW_COLUMNS=40 FZF_PREVIEW_LINES=20 bash "$SCRIPT" --preview 6 | sed -E 's|( /tmp/[^ ]+)$||')"

out=$(env PATH="$W/bin:/usr/bin:/bin" WL_CLIPHIST_FORMAT=symbols bash "$SCRIPT" --preview 6)
check "chafa format can be overridden for other terminals" "yes" "$(case $out in *--format=symbols*) echo yes ;; *) echo no ;; esac)"

# A PATH without cliphist, so one installed on this machine stays hidden.
mkdir "$W/nobin"
for tool in bash; do ln --symbolic "$(command -v "$tool")" "$W/nobin/$tool"; done
out=$(env PATH="$W/nobin" bash -c 'sleep() { :; }; export -f sleep; bash "$0"' "$SCRIPT" 2>&1)
check "without cliphist it says what to install" "yes" "$(case $out in *"apt install cliphist"*) echo yes ;; *) echo no ;; esac)"

exit "$fail"
