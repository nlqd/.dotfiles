#!/usr/bin/env bash
# Claude Code status line. Order: model+effort ctx rate dir branch version
# Sections are color-coded and separated by two spaces. Model is shortened to
# its initial (O/S) concatenated with effort. ctx and rate (both %) are kept
# adjacent. 5h rate hidden unless >95%. PR is omitted (Claude Code renders it
# natively) but kept below, commented, to restore.

input=$(cat)

# One jq pass, one value per line; readarray -t keeps empty fields aligned.
# Percentages are rounded in jq to avoid locale-sensitive shell float printf.
readarray -t f < <(
  printf '%s' "$input" | jq -r '
    [ .model.display_name // "",
      .effort.level // "",
      (.context_window.used_percentage // "" | if type == "number" then round else . end),
      (.pr.number // ""),
      .pr.review_state // "",
      .pr.url // "",
      (.rate_limits.five_hour.used_percentage // "" | if type == "number" then round else . end),
      (.rate_limits.seven_day.used_percentage // "" | if type == "number" then round else . end),
      .version // "",
      (.workspace.current_dir // .cwd // "")
    ] | .[] | tostring'
)
model=${f[0]} effort=${f[1]} used=${f[2]}
pr_num=${f[3]} pr_state=${f[4]} pr_url=${f[5]}
five_h=${f[6]} seven_d=${f[7]} version=${f[8]} dir=${f[9]}

dir_name="${dir##*/}"
# One git call: git-dir, common-dir, branch. A linked worktree's git-dir lives
# under .git/worktrees/<name> while common-dir is the main .git, so they differ
# no matter how the worktree dir was named. There the branch alone identifies
# the checkout, so the dir is dropped as redundant.
in_worktree=""
if [ -n "$dir" ]; then
  readarray -t g < <(git -C "$dir" rev-parse --path-format=absolute \
    --git-dir --git-common-dir --abbrev-ref HEAD 2>/dev/null)
  branch=${g[2]}
  [ "$branch" = HEAD ] && branch=""   # detached HEAD: no branch name
  [ -n "${g[0]}" ] && [ "${g[0]}" != "${g[1]}" ] && [ -n "$branch" ] && in_worktree=1
fi

# Per-section colors
c_model=$'\033[36m'    # cyan
c_effort=$'\033[35m'   # magenta
c_ctx=$'\033[32m'      # green
c_rl=$'\033[34m'       # blue
c_dir=$'\033[37m'      # white
c_branch=$'\033[34m'   # blue
c_ver=$'\033[90m'      # grey
# c_pr=$'\033[33m'     # yellow (PR rendered natively by Claude Code)
reset=$'\033[0m'

parts=()

# Model initial + effort as one token: "Oxhigh", "Smax".
[ -n "$model" ] && parts+=("${c_model}${model:0:1}${c_effort}${effort}${reset}")

# ctx and rate kept adjacent (all %). 5h hidden unless >95%.
[ -n "$used" ] && parts+=("${c_ctx}ctx:${used}%${reset}")
rl=""
[ -n "$five_h" ] && [ "$five_h" -gt 95 ] 2>/dev/null && rl="5h:${five_h}%"
[ -n "$seven_d" ] && rl="${rl:+$rl }7d:${seven_d}%"
[ -n "$rl" ] && parts+=("${c_rl}${rl}${reset}")

# In a worktree the dir is per-branch scratch named after the branch, so show
# the dir only when not in a worktree.
[ -z "$in_worktree" ] && [ -n "$dir_name" ] && parts+=("${c_dir}${dir_name}${reset}")
[ -n "$branch" ] && parts+=("${c_branch}$branch${reset}")

# PR omitted: Claude Code shows it natively. Uncomment to restore.
# if [ -n "$pr_num" ]; then
#   pr="PR#$pr_num"
#   [ -n "$pr_state" ] && pr="$pr ($pr_state)"
#   # OSC 8 hyperlink so the PR text opens its URL on click
#   [ -n "$pr_url" ] && pr=$'\033]8;;'"$pr_url"$'\007'"$pr"$'\033]8;;\007'
#   parts+=("${c_pr}${pr}${reset}")
# fi

[ -n "$version" ] && parts+=("${c_ver}v${version}${reset}")

# Two spaces between sections
out=""
for p in "${parts[@]}"; do
  out="${out:+$out  }$p"
done
printf '%s' "$out"
