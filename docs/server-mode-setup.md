# Server mode: per-machine setup

Sway "server mode" (toggle: `$mod+F7`) keeps the laptop running with the lid
closed: screen off on lid close, screen back on via lid open, no suspend. While
on, it also caps the battery at 90% (AC passthrough); off, it charges to full
for travel.

The scripts and the sway/waybar config travel with this repo (symlinked into
place by stow). The pieces below need root, so they live under `etc/` and `usr/`
instead. Those two directories are stow-ignored on purpose: a symlink from `/etc`
into `$HOME` would let anything running as you edit files that root executes.

## Root-owned files

    rootsync            # dry run: shows new/changed files, exits 1 on drift
    rootsync --apply    # install what differs, then reload what reads it

`--apply` runs `visudo --check` on sudoers files before installing them, and
only reloads what changed (udev, `tlp start`, `daemon-reload`, enabling the
timer). After the logind drop-in changes, restart `systemd-logind` or reboot.

| File | Purpose |
|---|---|
| `etc/systemd/logind.conf.d/10-server-mode.conf` | logind ignores the lid so sway's `bindswitch` can handle it |
| `etc/sudoers.d/battery-charge-mode` | lets the toggle flip the Dell charge policy without a password, scoped to one BIOS attribute |
| `etc/sudoers.d/hibernate` | lets `sush` run `suspend-then-hibernate` (Ubuntu's polkit rule denies hibernate to user sessions) |
| `etc/tlp.d/10-server-cool.conf` | CPU energy bias `power` and platform profile `cool` on AC so the closed chassis stays cool |
| `etc/udev/rules.d/90-thermal-ac.rules` | Dell thermal profile `Cool` on AC, `Optimized` on battery (agrees with the TLP drop-in; both write it, so they must match) |
| `etc/systemd/system/battery-guard.{service,timer}` and `usr/local/sbin/battery-guard` | low-battery hibernate, see below |

## Per-user piece: libinput quirk

This sway build bundles its own libinput and reads overrides from its own prefix:

    ln -sf ~/dotfiles/.config/libinput/local-overrides.quirks \
      ~/.local/sway-1.12/etc/libinput/local-overrides.quirks

It takes effect when the kanata device re-registers (restart kanata) or on the
next sway restart. It reduces phantom lid-opens but does not remove them, which
is why `sway-lid-handler` still cross-checks the ACPI lid.

## BIOS / firmware prerequisites (Dell)

- The `dell-wmi-sysman` driver must expose
  `/sys/class/firmware-attributes/dell-wmi-sysman/attributes/PrimaryBattChargeCfg`
  (and `dell_laptop` the matching `charge_types` on `BAT0`, kernel 6.12 or newer).
- No BIOS admin / power-on password set, else writes need authentication
  (check `.../authentication/*/is_enabled` is `0`).
- The cap window lives in BIOS NVRAM, not this repo. Currently
  `CustomChargeStart=50`, `CustomChargeStop=90` (firmware allows start 50-95,
  stop 55-100, at least 5 apart). The window is kept high on purpose: this
  battery is worn well below its design capacity, so a low cap left too little
  reserve to undock with. Write order matters: raise `CustomChargeStop` before
  raising `CustomChargeStart`. Only the 90% ceiling is reliable: the pack
  charged from 60% on plug-in even with start at 50.

## How it works

- `sway-server-mode-toggle` (F7, `--no-repeat`): writes the state file, flips
  battery policy via `battery-charge-mode`, notifies, signals waybar.
- `sway-lid-handler` (sway `bindswitch`): on close, power the panel off (server)
  or suspend (normal); on open, cross-check the ACPI lid and refuse a phantom
  open (see the script for why).
- `battery-charge-mode cap|full|sync`: sets Dell policy `Custom` (cap) /
  `Standard` (full). `sync` runs from sway's boot `exec` to match the saved mode.
  Server mode survives reboots, including a reboot on battery.

## Low battery

`battery-guard` runs every minute as root. While discharging it hibernates at
7% and powers off at 3%, percent of the pack's current full charge. It exists
because UPower's critical action never reached logind on 2026-10-15 (the pack
ran from 2% to a hard cutoff in server mode, and UPower's call is
fire-and-forget, so the failure was silent). It is unit-tested with a fake
battery (`tests/battery-guard.test.sh`) but has not run against the real pack.

Hibernate needs `resume=` and `resume_offset=` on the kernel command line, and
the offset must equal the first extent of `/swapfile`:

    sudo filefrag -v /swapfile | head -n 4

To test the resume path without powering off (save your work first), write the
image and load it straight back:

    echo test_resume | sudo tee /sys/power/disk
    echo disk | sudo tee /sys/power/state
    echo platform | sudo tee /sys/power/disk

A pass looks like a 10-20 second freeze, then the prompt returns. The kernel log
is misleading afterwards: restoring reverts kernel memory, including the log
ring, so the image write and read lines vanish and the monotonic clock skips
that time. To see proof, run `echo 1 | sudo tee /sys/power/pm_debug_messages`
first (set it back to 0 after) and look for `Hibernation image restored
successfully` in `journalctl --dmesg`. Passed on 7.2.6 on 2026-10-17, and so did a
real `systemctl hibernate` with power off and resume (logind logs "System
returned from sleep operation 'hibernate'").

As a user, logind reports `CanHibernate` as "no" because of Ubuntu's polkit rule.
Check capability as root.

## Verify

None of this needs sudo:

    # server mode on: charge_types [Custom], thresholds 50 and 90; off: [Standard]
    cat /sys/class/power_supply/BAT0/{charge_types,charge_control_start_threshold,charge_control_end_threshold}
    # cap holding on AC: status "Not charging" once capacity reaches 90
    cat /sys/class/power_supply/BAT0/{status,capacity}
    systemctl list-timers battery-guard.timer
    journalctl --identifier=battery-guard --since today

## Diagnostics (optional)

The verbose libinput lid trace is disabled (it wrote ~107k journal lines/day).
Re-enable for fresh lid debugging via the commented block in
`sway-server-mode-toggle`. Decision history lives in the script comments.
