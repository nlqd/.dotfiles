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
      (.rate_limits.five_hour.resets_at // 0),
      (.rate_limits.seven_day.used_percentage // "" | if type == "number" then round else . end),
      (.rate_limits.seven_day.resets_at // 0),
      .version // "",
      (.workspace.current_dir // .cwd // "")
    ] | .[] | tostring'
)
model=${fields[0]} effort=${fields[1]} used=${fields[2]}
pr_num=${fields[3]} pr_state=${fields[4]} pr_url=${fields[5]}
five_h=${fields[6]} five_h_reset=${fields[7]}
seven_d=${fields[8]} seven_d_reset=${fields[9]}
version=${fields[10]} dir=${fields[11]}

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

# Minimal colors: default fg for most text, green only for the ctx bar.
# Bold marks active warnings (5h shown, 7d over-pace).
c_ctx=$'\033[32m'          # green - ctx bar fill
c_track=$'\033[38;5;240m'  # dim grey - ctx bar empty track
bold=$'\033[1m'
reset=$'\033[0m'

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

# fmt_dur SECONDS — largest sensible unit, rounded up: 5d / 5h / 45m. Days
# above 24h, hours above 1h, minutes below, so a reset near its deadline reads
# in the unit that actually tells you how soon.
fmt_dur() {
  local s=$1
  if   [ "$s" -ge 86400 ]; then printf '%dd' $(( (s + 86399) / 86400 ))
  elif [ "$s" -ge 3600 ];  then printf '%dh' $(( (s + 3599) / 3600 ))
  else                          printf '%dm' $(( (s + 59) / 60 ))
  fi
}

# join SEP ITEMS... — joins items with SEP into a single string.
join() {
  local sep=$1; shift
  local out="" x
  for x in "$@"; do out="${out:+$out$sep}$x"; done
  printf '%s' "$out"
}

# vlen STR — visible width of STR, ignoring ANSI \033[..m color escapes.
vlen() {
  local s=$1 out=""
  while [[ $s == *$'\033['* ]]; do
    out+="${s%%$'\033['*}"   # text before the escape
    s="${s#*m}"              # drop the escape up to its final 'm'
  done
  out+="$s"
  printf '%s' "${#out}"
}

# Segments are collected with a drop-priority: higher numbers are shed first
# when the line is too wide for $COLUMNS. ctx and branch are kept longest.
parts=() prios=()
push() { prios+=("$1"); parts+=("$2"); }

# Model initial + effort as one token: "Oxhigh", "Smax".
[ -n "$model" ] && push 30 "${model:0:1}${effort}"

# ctx as a 5-cell bar; precise % isn't shown since position is the signal.
[ -n "$used" ] && push 10 "$(bar "$used" 5 "$c_ctx" "$c_track")"

# Rate limits group. Both windows read "{time_to_reset}:{budget_left}%", with
# time_to_reset in whatever unit is closest (d/h/m), so a near reset tells you
# how soon in real terms.
#   5h: only when >95% used — bold, since its presence is already a warning.
#   7d: always; bold when budget-left lags time-left (as % of the window) by
#       over 10 points (over-pace, slow down).
now_ts=$(date +%s)
rl_pieces=()
if [ -n "$five_h" ] && [ "$five_h" -gt 95 ] 2>/dev/null; then
  fh="5h:${five_h}%"
  if [ -n "$five_h_reset" ] && [ "$five_h_reset" -gt 0 ]; then
    fh_left=$(( five_h_reset - now_ts ))
    [ $fh_left -gt 0 ] && fh="${fh} $(fmt_dur $fh_left)"
  fi
  rl_pieces+=("${bold}${fh}${reset}")
fi
if [ -n "$seven_d" ] && [ -n "$seven_d_reset" ] && [ "$seven_d_reset" -gt 0 ]; then
  sec_left=$(( seven_d_reset - now_ts ))
  if [ $sec_left -gt 0 ]; then
    pct_left=$(( 100 - seven_d ))
    [ $pct_left -lt 0 ] && pct_left=0
    time_left_pct=$(( sec_left * 100 / 604800 ))
    if [ $(( pct_left - time_left_pct )) -lt -10 ]; then
      pace_bold=$bold
    else
      pace_bold=""
    fi
    rl_pieces+=("${pace_bold}$(fmt_dur "$sec_left"):${pct_left}%${reset}")
  fi
fi
[ ${#rl_pieces[@]} -gt 0 ] && push 40 "$(join " " "${rl_pieces[@]}")"

# In a worktree the dir is per-branch scratch named after the branch, so show
# the dir only when not in a worktree.
[ -z "$in_worktree" ] && [ -n "$dir_name" ] && push 50 "$dir_name"
[ -n "$branch" ] && push 20 "$branch"

# PR omitted: Claude Code shows it natively. Uncomment to restore.
# if [ -n "$pr_num" ]; then
#   pr="PR#$pr_num"
#   [ -n "$pr_state" ] && pr="$pr ($pr_state)"
#   # OSC 8 hyperlink so the PR text opens its URL on click
#   [ -n "$pr_url" ] && pr=$'\033]8;;'"$pr_url"$'\007'"$pr"$'\033]8;;\007'
#   push 45 "$pr"
# fi

[ -n "$version" ] && push 60 "v${version}"

# Width-aware layout. Claude Code exports $COLUMNS before running this script
# (tput cols won't work — the output is captured, not a tty). Drop the
# highest-priority-number segment until the visible line fits; always keep at
# least the single most important segment.
cols=${COLUMNS:-0}
if [ "$cols" -gt 0 ]; then
  while [ ${#parts[@]} -gt 1 ]; do
    n=${#parts[@]} total=0
    for ((i = 0; i < n; i++)); do total=$(( total + $(vlen "${parts[i]}") )); done
    total=$(( total + 2 * (n - 1) ))   # two-space separators
    [ "$total" -le "$cols" ] && break
    worst=0
    for ((i = 1; i < n; i++)); do
      [ "${prios[i]}" -gt "${prios[worst]}" ] && worst=$i
    done
    parts=( "${parts[@]:0:worst}" "${parts[@]:worst+1}" )
    prios=( "${prios[@]:0:worst}" "${prios[@]:worst+1}" )
  done
fi

printf '%s' "$(join "  " "${parts[@]}")"
