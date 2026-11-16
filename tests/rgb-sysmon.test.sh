#!/usr/bin/env bash
# rgb-sysmon turns load into LED colors: watts fill the fan ring, heat picks its hue,
# RAM and VRAM are bars on the two sticks, and stale sensors turn everything red.
# Run: bash tests/rgb-sysmon.test.sh   (renders frames only, touches no hardware)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SYSMON="$HERE/../.local/scripts/rgb-sysmon"

pass=0 fail=0
ok(){ printf 'ok   - %s\n' "$1"; pass=$((pass+1)); }
no(){ printf 'FAIL - %s\n' "$1"; fail=$((fail+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1"; printf '      want: [%s]\n      got:  [%s]\n' "$2" "$3"; fi; }

row(){ "$SYSMON" render "${@:2}" | awk -v z="$1" '$1 == z { $1 = ""; sub(/^ /, ""); print }'; }

cool='--watts 0 --cpu-c 30 --gpu-c 30 --ram 0 --vram 0'
hot='--watts 1000 --cpu-c 100 --gpu-c 100 --ram 1 --vram 1'

# shellcheck disable=SC2086
{
eq "idle ring is dim blue" \
    '000819 000819 000819 000819 000819 000819 000819 000819' "$(row fans $cool)"
eq "full load fills the ring red" \
    'ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000' "$(row fans $hot)"
eq "logo follows heat" 'ff0000' "$(row logo $hot)"
eq "half RAM lights half the stick yellow" 6 "$(row ram $cool --ram 0.5 | tr ' ' '\n' | grep --count --line-regexp ffff00)"
eq "full VRAM stick is red" \
    'ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000' "$(row vram $hot)"
eq "hotter GPU wins over cool CPU" 'ff0000' "$(row logo --watts 0 --cpu-c 30 --gpu-c 100 --ram 0 --vram 0)"
}

eq "stale sensors turn the ring red" \
    'ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000' "$(row fans --stale)"
eq "stale sensors turn the RAM red" \
    'ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000 ff0000' "$(row ram --stale)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
