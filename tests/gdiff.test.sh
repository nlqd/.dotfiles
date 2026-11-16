#!/usr/bin/env bash
# gdiff diffs against the merge-base with the branch this one was created from,
# not against the base branch's moving tip.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
GDIFF="$HERE/../.local/scripts/gdiff"

pass=0 fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL - %s\n' "$1"; fail=$((fail+1)); }
has(){ if grep --quiet --fixed-strings -- "$2" <<<"$3"; then ok "$1"; else no "$1"; printf '      missing: [%s]\n      in: [%s]\n' "$2" "$3"; fi; }
lacks(){ if grep --quiet --fixed-strings -- "$2" <<<"$3"; then no "$1"; printf '      unexpected: [%s]\n' "$2"; else ok "$1"; fi; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
TMP=$(mktemp --directory)
trap 'rm --recursive --force "$TMP"' EXIT

git init --quiet --bare --initial-branch=main "$TMP/origin.git"
git init --quiet --initial-branch=main "$TMP/work"
cd "$TMP/work" || exit 1
git remote add origin "$TMP/origin.git"

echo base >base.txt; git add base.txt; git commit --quiet --message base
git push --quiet origin main
git checkout --quiet -b feature origin/main
echo mine >mine.txt; git add mine.txt; git commit --quiet --message mine

# main moves on after feature branched off
git checkout --quiet main
echo theirs >theirs.txt; git add theirs.txt; git commit --quiet --message theirs
git push --quiet origin main
git checkout --quiet feature

out=$("$GDIFF")
has   "guesses the base branch from the reflog and shows our change" "mine.txt" "$out"
lacks "ignores commits that landed on the base after branching" "theirs.txt" "$out"

out=$("$GDIFF" main)
has   "explicit branch shows our change" "mine.txt" "$out"
lacks "explicit branch ignores later base commits" "theirs.txt" "$out"

out=$("$GDIFF" -- mine.txt)
has   "extra args without a branch use the guessed base" "mine.txt" "$out"

out=$("$GDIFF" main -- mine.txt)
has   "extra args after a branch are forwarded to git diff" "mine.txt" "$out"

out=$("$GDIFF" main -- base.txt)
if [[ -z "$out" ]]; then ok "pathspec excludes unchanged files"; else no "pathspec excludes unchanged files"; fi

echo "----"; echo "pass=$pass fail=$fail"; [[ $fail -eq 0 ]]
