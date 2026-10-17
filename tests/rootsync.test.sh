#!/usr/bin/env bash
# Tests for rootsync. Run: bash tests/rootsync.test.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../.local/scripts/rootsync"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo" DEST="$WORK/root" BIN="$WORK/bin" CALLS="$WORK/calls"
mkdir -p "$REPO"/etc/{tlp.d,sudoers.d,udev/rules.d,systemd/system,systemd/logind.conf.d} \
    "$REPO/usr/local/sbin" "$DEST" "$BIN"
for stub in udevadm tlp systemctl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$stub" "$CALLS" > "$BIN/$stub"
    chmod +x "$BIN/$stub"
done

echo 'CPU_ENERGY_PERF_POLICY_ON_AC=power' > "$REPO/etc/tlp.d/a.conf"
echo 'qd ALL=(root) NOPASSWD: /usr/bin/true' > "$REPO/etc/sudoers.d/ok"
echo 'ACTION=="add", RUN+="/bin/true"' > "$REPO/etc/udev/rules.d/r.rules"
echo '[Timer]' > "$REPO/etc/systemd/system/g.timer"
echo '[Login]' > "$REPO/etc/systemd/logind.conf.d/l.conf"
printf '#!/bin/sh\n' > "$REPO/usr/local/sbin/tool"
chmod +x "$REPO/usr/local/sbin/tool"

pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; fail=$((fail + 1)); }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want '$2' got '$3')"; fi; }
has() { if grep --quiet --fixed-strings -- "$3" <<<"$2"; then ok "$1"; else no "$1 ('$3' not in [$2])"; fi; }
hasnot() { if grep --quiet --fixed-strings -- "$3" <<<"$2"; then no "$1 ('$3' unexpectedly in [$2])"; else ok "$1"; fi; }

# rs [ARGS] -> runs rootsync against the temp repo and root; no sudo, hooks off unless HOOKS=1
rs() {
    ROOTSYNC_REPO="$REPO" ROOTSYNC_DEST="$DEST" ROOTSYNC_SUDO='' ROOTSYNC_HOOKS="${HOOKS:-0}" \
        PATH="$BIN:$PATH" "$SCRIPT" "$@"
}

out=$(rs); eq "dry run exits 1 when files are missing" "1" "$?"
has "dry run reports a new file" "$out" "new      etc/tlp.d/a.conf"
eq "dry run installs nothing" "0" "$(find "$DEST" -type f | wc --lines)"

rs --apply > /dev/null; rc=$?; eq "apply exits 0" "0" "$rc"
eq "apply copies content" "$(cat "$REPO/etc/tlp.d/a.conf")" "$(cat "$DEST/etc/tlp.d/a.conf")"
eq "sudoers is mode 0440" "440" "$(stat --format=%a "$DEST/etc/sudoers.d/ok")"
eq "executable keeps 0755" "755" "$(stat --format=%a "$DEST/usr/local/sbin/tool")"
eq "plain file is 0644" "644" "$(stat --format=%a "$DEST/etc/tlp.d/a.conf")"

out=$(rs); eq "dry run exits 0 once in sync" "0" "$?"
hasnot "nothing is reported as new" "$out" "new "
hasnot "nothing is reported as changed" "$out" "changed "

echo 'CPU_ENERGY_PERF_POLICY_ON_AC=balance_power' > "$REPO/etc/tlp.d/a.conf"
out=$(rs); has "an edited file is reported as changed" "$out" "changed  etc/tlp.d/a.conf"
rs --apply > /dev/null
eq "apply updates the edited file" "CPU_ENERGY_PERF_POLICY_ON_AC=balance_power" "$(cat "$DEST/etc/tlp.d/a.conf")"

echo 'this is not sudoers' > "$REPO/etc/sudoers.d/bad"
if command -v visudo > /dev/null; then
    rs --apply > /dev/null 2>&1; rc=$?
    if [[ "$rc" -ne 0 ]]; then ok "apply fails on an unparsable sudoers file"; else no "apply fails on an unparsable sudoers file"; fi
    eq "the bad sudoers file is not installed" "no" "$([[ -e "$DEST/etc/sudoers.d/bad" ]] && echo yes || echo no)"
else
    ok "visudo missing, sudoers validation test skipped"
fi
rm "$REPO/etc/sudoers.d/bad"

rs --bogus 2> /dev/null; eq "unknown argument exits 2" "2" "$?"

# Reloads: only what changed is reloaded, timers get enabled.
rm --recursive --force "$DEST" && mkdir "$DEST" && : > "$CALLS"
out=$(HOOKS=1 rs --apply)
calls=$(cat "$CALLS")
has "udev rule change reloads udev"   "$calls" "udevadm control --reload"
has "udev rule change retriggers power_supply" "$calls" "udevadm trigger --subsystem-match=power_supply"
has "tlp drop-in change runs tlp start" "$calls" "tlp start"
has "unit change reloads systemd"     "$calls" "systemctl daemon-reload"
has "a new timer is enabled"          "$calls" "systemctl enable --now g.timer"
has "logind change prints a note"     "$out"   "note: restart systemd-logind"

echo 'CPU_ENERGY_PERF_POLICY_ON_AC=power' > "$REPO/etc/tlp.d/a.conf"; : > "$CALLS"
HOOKS=1 rs --apply > /dev/null
eq "only the changed area is reloaded" "tlp start" "$(cat "$CALLS")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
