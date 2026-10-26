#!/usr/bin/env bash
# Tests for the clipboard call sites: each picks wl-copy on Wayland, xclip/xsel on X11 and pbcopy
# on macOS, deciding from the environment at the moment it runs. Run: bash tests/clipboard.test.sh
# Every clipboard tool is a stub that logs what it received, so no display is needed.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="$HERE/.."

W=$(mktemp --directory)
trap 'rm --recursive --force "$W"' EXIT
mkdir "$W/bin"
LOG="$W/log"

stub() { # name: logs "name:<stdin>" and prints $PASTE_TEXT when asked to read
  printf '#!/bin/sh\nif [ "$1" = "--no-newline" ] || [ "$*" = "-selection clipboard -o" ]; then printf "%%s" "$PASTE_TEXT"; exit 0; fi\nprintf "%s:%%s\\n" "$(cat | tr "\\n" " ")" >> "%s"\n' "$1" "$LOG" > "$W/bin/$1"
  chmod +x "$W/bin/$1"
}
for tool in wl-copy wl-paste xclip xsel pbcopy; do stub "$tool"; done

fail=0
check() {
  local name=$1 want=$2 got=$3
  if [ "$got" = "$want" ]; then echo "ok: $name"; else echo "FAIL: $name: want '$want', got '$got'"; fail=1; fi
}
tools_used() { sed -E 's/:.*//' "$LOG" 2>/dev/null | sort --unique | tr '\n' ' ' | sed 's/ $//'; }
fresh() { : > "$LOG"; }

# tmux: copy-command is a shell string chosen at copy time, so run the exact string tmux holds.
copy_cmd=$(env HOME="$W" tmux -L clip-test-$$ -f "$ROOT/.config/tmux/tmux.conf" start-server \; show-options -sv copy-command 2>/dev/null)
tmux -L clip-test-$$ kill-server 2>/dev/null
run_tmux_copy() { printf 'text' | env PATH="$W/bin:/usr/bin:/bin" "$@" sh -c "$copy_cmd"; }

fresh; run_tmux_copy WAYLAND_DISPLAY=wayland-1 DISPLAY=:0
check "tmux copy on Wayland (Xwayland DISPLAY also set) uses wl-copy" "wl-copy" "$(tools_used)"
fresh; run_tmux_copy WAYLAND_DISPLAY= DISPLAY=:0
check "tmux copy on macOS (pbcopy present, no Wayland) uses pbcopy" "pbcopy" "$(tools_used)"
mv "$W/bin/pbcopy" "$W/pbcopy.off"
fresh; run_tmux_copy WAYLAND_DISPLAY= DISPLAY=:0
check "tmux copy on X11 (no pbcopy) uses xsel" "xsel" "$(tools_used)"
mv "$W/pbcopy.off" "$W/bin/pbcopy"

# newsboat macro "c": the exact pipeline from the config. wl-copy failing falls through to xclip.
macro=$(sed -nE 's/^macro c set browser "([^"]*)".*/\1/p' "$ROOT/.config/newsboat/config" | sed 's/%u/https:\/\/example.com/g')
fresh; env PATH="$W/bin:/usr/bin:/bin" sh -c "$macro"
check "newsboat copy with wl-copy working uses only wl-copy" "wl-copy" "$(tools_used)"
printf '#!/bin/sh\ncat >/dev/null; exit 1\n' > "$W/bin/wl-copy"; chmod +x "$W/bin/wl-copy"
fresh; env PATH="$W/bin:/usr/bin:/bin" sh -c "$macro"
check "newsboat copy falls back to xclip when wl-copy fails" "xclip" "$(tools_used)"
stub wl-copy

# zshrc.aiws: pbcopy/pbpaste aliases follow the session type.
alias_block=$(sed -n '/^if \[\[ -n \${WAYLAND_DISPLAY-} \]\]; then$/,/^fi$/p' "$ROOT/.zshrc.aiws")
check "zshrc.aiws aliases pbcopy to wl-copy on Wayland" "wl-copy" \
  "$(WAYLAND_DISPLAY=wayland-1 zsh -c "$alias_block; alias pbcopy" | sed -E "s/^pbcopy='?//; s/'$//")"
check "zshrc.aiws aliases pbcopy to xclip on X11" "xclip -sel c" \
  "$(env WAYLAND_DISPLAY= zsh -c "$alias_block; alias pbcopy" | sed -E "s/^pbcopy='?//; s/'$//")"

# sdai: the copy branch, extracted from the script. uname is stubbed to pick the platform.
sdai_branch=$(sed -n "/if \[\[ \$(uname) = 'Darwin' \]\]; then pbcopy/,/^        fi$/p" "$ROOT/.local/scripts/sdai")
run_sdai() { printf 'reply' | env PATH="$W/bin:/usr/bin:/bin" "$@" bash -c "$sdai_branch"; }
fresh; run_sdai WAYLAND_DISPLAY=wayland-1
check "sdai copies with wl-copy on Wayland" "wl-copy" "$(tools_used)"
fresh; run_sdai WAYLAND_DISPLAY=
check "sdai copies with xclip on X11" "xclip" "$(tools_used)"
printf '#!/bin/sh\necho Darwin\n' > "$W/bin/uname"; chmod +x "$W/bin/uname"
fresh; run_sdai WAYLAND_DISPLAY=wayland-1
check "sdai copies with pbcopy on macOS, whatever the display variables" "pbcopy" "$(tools_used)"
rm "$W/bin/uname"

# md2tsv: the Wayland rule must ignore DISPLAY (Xwayland sets it inside a Wayland session).
table=$'| a | b |\n|---|---|\n| 1 | 2 |'
fresh; PASTE_TEXT=$table env PATH="$W/bin:/usr/bin:/bin" WAYLAND_DISPLAY=wayland-1 DISPLAY=:0 python3 -I "$ROOT/.local/scripts/md2tsv" >/dev/null 2>&1
check "md2tsv uses wl-copy when both WAYLAND_DISPLAY and DISPLAY are set" "wl-copy" "$(tools_used)"

exit "$fail"
