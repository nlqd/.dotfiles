#!/usr/bin/env bash
# Claude Code status line. Order: model+effort ctx rate dir branch version
# Sections are color-coded and joined by two spaces. ctx renders as a 5-cell
# bar; the 7-day rate shows what's left (time + budget) with a yellow tint
# when budget lags time by more than 10 points. 5h hidden unless >95%. PR is
# omitted (Claude Code renders it natively); commented block kept to restore.

input=$(cat)

# One jq pass, one value per line; readarray -t keeps empty fields aligned.
# Percentages are rounded in jq to avoid locale-sensitive shell float printf.
readarray -t fields < <(
  printf '%s' "$input" | jq -r '
    [ .model.display_name // "",
      .effort.level // "",
      (.context_window.used_percentage // "" | if type == "number" then round else . end),
      (.pr.number // ""),
      .pr.review_state // "",
      .pr.url // "",
      (.rate_limits.five_hour.used_percentage // "" | if type == "number" then round else . end),
      (.rate_limits.seven_day.used_percentage // "" | if type == "number" then round else . end),
      (.rate_limits.seven_day.resets_at // 0),
      .version // "",
      (.workspace.current_dir // .cwd // "")
    ] | .[] | tostring'
)
model=${fields[0]} effort=${fields[1]} used=${fields[2]}
pr_num=${fields[3]} pr_state=${fields[4]} pr_url=${fields[5]}
five_h=${fields[6]} seven_d=${fields[7]} seven_d_reset=${fields[8]}
version=${fields[9]} dir=${fields[10]}

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
  [ "$branch" = HEAD ] && branch=""
  [ -n "${g[0]}" ] && [ "${g[0]}" != "${g[1]}" ] && [ -n "$branch" ] && in_worktree=1
fi

# Minimal colors: default fg for most text, color only for ctx and 7d.
# Bold marks active warnings (5h shown, 7d over-pace).
c_ctx=$'\033[32m'                 # green - ctx bar fill
c_track=$'\033[38;5;240m'         # dim grey - ctx bar empty track
c_acct_orange=$'\033[38;5;208m'   # orange - "rememberizer" account
bold=$'\033[1m'
reset=$'\033[0m'

# 7d color is the account indicator: default fg for the personal email
# (dung.ngo), orange for the work one (rememberizer). Read from oauthAccount.
# Prefer ~/.claude.json (canonical), fall back to the nested copy.
acct_file="$HOME/.claude.json"
[ -f "$acct_file" ] || acct_file="$HOME/.claude/.claude.json"
acct_email=$(jq -r '.oauthAccount.emailAddress // ""' "$acct_file" 2>/dev/null)
case "${acct_email%%@*}" in
  rememberizer) c_acct=$c_acct_orange ;;
  *)            c_acct="" ;;
esac

# bar PCT CELLS FILL TRACK — git-diff style gauge at half-cell resolution.
# + is a full cell, - the half-filled boundary (a makeshift partial so low
# values still register), · the empty track. FILL colors the +/-, TRACK the ·.
bar() {
  local pct=$1 cells=$2 fill=$3 track=$4
  local max=$((cells * 2))
  local e=$(( (pct * max + 50) / 100 ))
  [ $e -lt 0 ] && e=0
  [ $e -gt $max ] && e=$max
  local full=$((e / 2)) half=$((e % 2))
  local out="" i
  for ((i = 0; i < cells; i++)); do
    if   [ $i -lt $full ]; then out="${out}+"
    elif [ $i -eq $full ] && [ $half -gt 0 ]; then out="${out}-"
    else out="${out}${reset}${track}·${fill}"
    fi
  done
  printf '%s%s%s' "$fill" "$out" "$reset"
}

# join SEP ITEMS... — joins items with SEP into a single string.
join() {
  local sep=$1; shift
  local out="" x
  for x in "$@"; do out="${out:+$out$sep}$x"; done
  printf '%s' "$out"
}

parts=()

# Model initial + effort as one token: "Oxhigh", "Smax".
[ -n "$model" ] && parts+=("${model:0:1}${effort}")

# ctx as a 5-cell bar; precise % isn't shown since position is the signal.
[ -n "$used" ] && parts+=("$(bar "$used" 5 "$c_ctx" "$c_track")")

# Rate limits group:
#   5h: only when >95% — bold since its presence is already a warning.
#   7d: shown as remaining-time + remaining-budget. Color = account (orange
#       for rememberizer, default for personal); bold when pct_left lags
#       days_left*100/7 by more than 10 points (over-pace, hold horses).
rl_pieces=()
[ -n "$five_h" ] && [ "$five_h" -gt 95 ] 2>/dev/null && \
  rl_pieces+=("${bold}5h:${five_h}%${reset}")
if [ -n "$seven_d" ] && [ -n "$seven_d_reset" ] && [ "$seven_d_reset" -gt 0 ]; then
  sec_left=$(( seven_d_reset - $(date +%s) ))
  if [ $sec_left -gt 0 ]; then
    days_left=$(( (sec_left + 86399) / 86400 ))   # ceil so <24h shows 1d
    pct_left=$(( 100 - seven_d ))
    [ $pct_left -lt 0 ] && pct_left=0
    if [ $(( pct_left - days_left * 100 / 7 )) -lt -10 ]; then
      pace_bold=$bold
    else
      pace_bold=""
    fi
    rl_pieces+=("${c_acct}${pace_bold}${days_left}d:${pct_left}%${reset}")
  fi
fi
[ ${#rl_pieces[@]} -gt 0 ] && parts+=("$(join " " "${rl_pieces[@]}")")

# In a worktree the dir is per-branch scratch named after the branch, so show
# the dir only when not in a worktree.
[ -z "$in_worktree" ] && [ -n "$dir_name" ] && parts+=("$dir_name")
[ -n "$branch" ] && parts+=("$branch")

# PR omitted: Claude Code shows it natively. Uncomment to restore.
# if [ -n "$pr_num" ]; then
#   pr="PR#$pr_num"
#   [ -n "$pr_state" ] && pr="$pr ($pr_state)"
#   # OSC 8 hyperlink so the PR text opens its URL on click
#   [ -n "$pr_url" ] && pr=$'\033]8;;'"$pr_url"$'\007'"$pr"$'\033]8;;\007'
#   parts+=("$pr")
# fi

[ -n "$version" ] && parts+=("v${version}")

printf '%s' "$(join "  " "${parts[@]}")"
