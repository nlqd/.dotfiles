#!/usr/bin/env bash
# Tests for quicklaunch's candidate heuristic. Run: bash tests/quicklaunch.test.sh
# Uses the real fd on a temp tree, so no terminal, fzf or opener is involved.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../.local/scripts/quicklaunch"

command -v fd >/dev/null || { echo "SKIP fd is not installed"; exit 0; }

W=$(mktemp --directory)
trap 'rm --recursive --force "$W"' EXIT
ROOT="$W/root"
mkdir --parents "$ROOT"

mk() { # path, mtime
  mkdir --parents "$(dirname "$ROOT/$1")"
  : >"$ROOT/$1"
  touch -d "$2" "$ROOT/$1"
}

mk "work/deep/er/notes.md" "2026-01-05"
mk "work/deep/er/spec.PDF" "2026-01-04"
mk "media/clip.mp4" "2026-01-03"
mk "work/api/schema.json" "2026-01-02"
mk "work/src/main.rs" "2026-01-09"
mk "work/src/tool.py" "2026-01-09"
mk ".cargo/registry/README.md" "2026-01-09"
mk "work/node_modules/lib/README.md" "2026-01-09"
mk "work/package.json" "2026-01-09"
mk "repo/docs/guide.md" "2026-01-06"
mk "repo/build/out.md" "2026-01-09"
git init --quiet "$ROOT/repo" && echo "build/" >"$ROOT/repo/.gitignore"
mk "dump/one.csv" "2026-01-07"
mk "keep/single.csv" "2026-01-06 06:00"
mk "work/tests/fixture.json" "2026-01-08"
for n in $(seq 1 26); do mk "bulk/rows-$n.json" "2026-01-08"; done
for n in $(seq 1 21); do mk "cases/c$n/data.csv" "2026-01-08"; done

LIST="$W/list.txt"
bash "$SCRIPT" --list "$ROOT" >"$LIST"

FAILED=0
has() { rg --quiet --fixed-strings --line-regexp -- "$1" "$LIST"; }
check() { # name, command that must succeed
  local name=$1
  shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; FAILED=1; fi
}
absent() { ! has "$1"; }

check "finds a deeply nested markdown file" has "work/deep/er/notes.md"
check "finds a pdf with an upper-case extension" has "work/deep/er/spec.PDF"
check "finds media" has "media/clip.mp4"
check "finds a lone json file" has "work/api/schema.json"
check "skips rust code" absent "work/src/main.rs"
check "skips python code" absent "work/src/tool.py"
check "skips dot-directories" absent ".cargo/registry/README.md"
check "skips node_modules" absent "work/node_modules/lib/README.md"
check "skips package.json" absent "work/package.json"
check "keeps a tracked doc in a repo" has "repo/docs/guide.md"
check "skips gitignored build output" absent "repo/build/out.md"
check "keeps a lone csv" has "keep/single.csv"
check "skips json in a tests folder" absent "work/tests/fixture.json"
check "skips a folder with more than 25 json files" absent "bulk/rows-1.json"
check "skips a file name repeated in more than 20 places" absent "cases/c1/data.csv"
check "lists the newest file first" test "$(head --lines=1 "$LIST")" = "dump/one.csv"
check "orders older files after newer ones" test "$(rg --line-number --fixed-strings 'repo/docs/guide.md' "$LIST" | cut --delimiter=: --fields=1)" -lt "$(rg --line-number --fixed-strings 'work/deep/er/notes.md' "$LIST" | cut --delimiter=: --fields=1)"

# The picker's feed: files fresh in a drop folder come first, and nothing is listed twice.
HOME_DIR="$W/home"
mkdir --parents "$HOME_DIR/Downloads" "$HOME_DIR/old"
: >"$HOME_DIR/old/ancient.md"
touch -d '2020-01-01' "$HOME_DIR/old/ancient.md"
: >"$HOME_DIR/Downloads/dup.pdf" # in the index and fresh at once
CACHE="$W/cache"
export XDG_CACHE_HOME="$CACHE"
HOME="$HOME_DIR" bash "$SCRIPT" --refresh "$HOME_DIR"
: >"$HOME_DIR/Downloads/new.pdf"
FEED="$W/feed.txt"
HOME="$HOME_DIR" bash "$SCRIPT" --candidates "$HOME_DIR" >"$FEED"
check "feed starts with the fresh download" test "$(head --lines=1 "$FEED")" = "Downloads/new.pdf"
check "feed still has the indexed files" rg --quiet --fixed-strings --line-regexp 'old/ancient.md' "$FEED"
check "feed lists each path once" test "$(rg --count --fixed-strings --line-regexp 'Downloads/dup.pdf' "$FEED")" -eq 1

exit "$FAILED"
