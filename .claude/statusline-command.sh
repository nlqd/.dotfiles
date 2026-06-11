#!/usr/bin/env bash
# Claude Code status line. Order: model effort ctx pr rate version
# Sections are color-coded and separated by two spaces. dir + branch are
# commented out below; uncomment their extraction and part lines to restore.

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

# dir_name="${dir##*/}"
# branch=$(git --git-dir="$dir/.git" --work-tree="$dir" branch --show-current 2>/dev/null)

# Per-section colors
c_model=$'\033[36m'    # cyan
c_effort=$'\033[35m'   # magenta
c_ctx=$'\033[32m'      # green
# c_dir=$'\033[37m'    # white
# c_branch=$'\033[34m' # blue
c_pr=$'\033[33m'       # yellow
c_rl=$'\033[34m'       # blue
c_ver=$'\033[90m'      # grey
reset=$'\033[0m'

parts=()

[ -n "$model" ]  && parts+=("${c_model}${model}${reset}")
[ -n "$effort" ] && parts+=("${c_effort}${effort}${reset}")
[ -n "$used" ]   && parts+=("${c_ctx}ctx:${used}%${reset}")
# [ -n "$dir_name" ] && parts+=("${c_dir}${dir_name}${reset}")
# [ -n "$branch" ]   && parts+=("${c_branch} $branch${reset}")

if [ -n "$pr_num" ]; then
  pr="PR#$pr_num"
  [ -n "$pr_state" ] && pr="$pr ($pr_state)"
  # OSC 8 hyperlink so the PR text opens its URL on click
  [ -n "$pr_url" ] && pr=$'\033]8;;'"$pr_url"$'\007'"$pr"$'\033]8;;\007'
  parts+=("${c_pr}${pr}${reset}")
fi

rl=""
[ -n "$five_h" ]  && rl="5h:${five_h}%"
[ -n "$seven_d" ] && rl="${rl:+$rl }7d:${seven_d}%"
[ -n "$rl" ] && parts+=("${c_rl}${rl}${reset}")

[ -n "$version" ] && parts+=("${c_ver}v${version}${reset}")

# Two spaces between sections
out=""
for p in "${parts[@]}"; do
  out="${out:+$out  }$p"
done
printf '%s' "$out"
