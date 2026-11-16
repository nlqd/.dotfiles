#!/usr/bin/env bash
# claude-noti turns a Notification hook payload into a popup that stays open,
# and a click on it opens a floating terminal on the tmux window Claude runs in.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NOTI="$HERE/../.local/scripts/claude-noti"

pass=0 fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL - %s\n' "$1"; fail=$((fail+1)); }
has(){ if grep --quiet --fixed-strings -- "$2" <<<"$3"; then ok "$1"; else no "$1"; printf '      missing: [%s]\n      in: [%s]\n' "$2" "$3"; fi; }
lacks(){ if grep --quiet --fixed-strings -- "$2" <<<"$3"; then no "$1"; printf '      unexpected: [%s]\n' "$2"; else ok "$1"; fi; }

TMP=$(mktemp --directory)
trap 'rm --recursive --force "$TMP"' EXIT
mkdir "$TMP/bin"

# Stubs record their arguments, one per line. notify-send prints $STUB_CLICK
# the way the real one prints the action name after a click.
cat >"$TMP/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_DIR/notify-send.args"
printf '%s' "${STUB_CLICK:-}"
EOF
cat >"$TMP/bin/alacritty" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_DIR/alacritty.args"
printf '%s' "${TMUX:-unset}" >"$STUB_DIR/alacritty.tmux-env"
EOF
cat >"$TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf 'dev:3:@7\n'
EOF
chmod +x "$TMP/bin/"*

run(){ rm --force "$TMP"/*.args "$TMP"/*.tmux-env; PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" "$NOTI"; }
payload='{"message":"Claude needs your permission to use Bash","cwd":"/home/u/outlier"}'

export TMUX_PANE=%7 TMUX=/tmp/tmux-1000/default,1,0

run <<<"$payload"
args=$(<"$TMP/notify-send.args")
has "title names the project and the tmux window" "✻ outlier · dev:3" "$args"
has "body is the hook message" "Claude needs your permission to use Bash" "$args"
has "popup stays for 60 seconds" "--expire-time=60000" "$args"
has "popup offers a default action to click" "--action=default=Open" "$args"
[[ ! -e $TMP/alacritty.args ]] && ok "no click opens no terminal" || no "no click opens no terminal"

STUB_CLICK=default run <<<"$payload"
args=$(<"$TMP/alacritty.args")
has "click opens a terminal with the floating class" "--class
claude-float" "$args"
has "click attaches a grouped session of the right tmux session" "_
dev
claude-float-" "$args"
has "click selects the window Claude runs in, by id" "@7" "$args"
has "click cleans up the grouped session on close" "destroy-unattached on" "$args"
has "click unsets TMUX so tmux does not refuse to nest" "unset" "$(<"$TMP/alacritty.tmux-env")"

unset TMUX_PANE
run <<<"$payload"
args=$(<"$TMP/notify-send.args")
lacks "outside tmux there is nothing to open, so no action" "--action" "$args"
has "outside tmux the title is just the project" "✻ outlier" "$args"

run <<<'{}'
args=$(<"$TMP/notify-send.args")
has "empty payload still says Claude needs attention" "Claude needs your attention" "$args"
has "empty payload falls back to a generic title" "✻ Claude Code" "$args"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
