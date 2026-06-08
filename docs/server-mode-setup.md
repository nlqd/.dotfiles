# Server mode — per-machine setup

Sway "server mode" (toggle: `$mod+F7`) keeps the laptop running with the lid
closed: screen off on lid close, screen back on via lid open, no suspend. While
on, it also caps the battery (AC passthrough); off, it charges to full for travel.

The scripts and the sway/waybar config travel with this repo (symlinked into
place). The pieces below need root, so they are **not** carried by the dotfiles
and must be set up once per machine.

## 1. logind: don't suspend on lid close

Server mode relies on systemd-logind ignoring the lid so sway's `bindswitch` can
handle it. In `/etc/systemd/logind.conf`:

    HandleLidSwitch=ignore

Then `sudo systemctl restart systemd-logind` (or reboot).

## 2. sudoers: let the toggle flip the Dell charge policy without a password

Create `/etc/sudoers.d/battery-charge-mode` with this one rule. It is scoped to a
single BIOS attribute; the only values the kernel accepts there are the charge
policies (Adaptive/Standard/Express/PrimAcUse/Custom), all benign.

    sudo install -m 0440 /dev/stdin /etc/sudoers.d/battery-charge-mode <<'EOF'
    qd ALL=(root) NOPASSWD: /usr/bin/tee /sys/class/firmware-attributes/dell-wmi-sysman/attributes/PrimaryBattChargeCfg/current_value
    EOF
    sudo visudo -cf /etc/sudoers.d/battery-charge-mode      # expect: parsed OK

## 3. BIOS / firmware prerequisites (Dell)

- The `dell-wmi-sysman` driver must expose
  `/sys/class/firmware-attributes/dell-wmi-sysman/attributes/PrimaryBattChargeCfg`.
- No BIOS admin / power-on password set, else writes need authentication
  (check `.../authentication/*/is_enabled` is `0`).
- The cap window lives in BIOS NVRAM, not this repo. Set once:
  `CustomChargeStart=80`, `CustomChargeStop=90`. Retune the cap by changing
  `CustomChargeStop` (firmware allows stop 55-100, start 50-95). The window is
  kept high here on purpose: this battery is worn to ~50% of design, so a low
  cap left too little reserve to undock with. Write order matters -- raise
  `CustomChargeStop` before raising `CustomChargeStart` (start must stay below
  stop).

## How it works (all in this repo)

- `sway-server-mode-toggle` (F7): writes the state file, flips battery policy via
  `battery-charge-mode`, notifies, signals waybar.
- `sway-lid-handler` (sway `bindswitch`): on close, power the panel off (server)
  or suspend (normal); on open, cross-check the ACPI lid and refuse a phantom
  open (a synthesized lid event from kanata's virtual keyboard — see the script).
- `battery-charge-mode cap|full|sync`: sets Dell policy `Custom` (cap) /
  `Standard` (full). `sync` runs from sway's boot `exec` to match the saved mode.

## Verify

    # policy reflects mode: Custom in server mode, Standard otherwise
    sudo cat /sys/class/firmware-attributes/dell-wmi-sysman/attributes/PrimaryBattChargeCfg/current_value
    # cap holding: capacity drifts toward 60 and status reads "Not charging"
    cat /sys/class/power_supply/BAT0/{capacity,status}

## Diagnostics (optional)

The verbose libinput lid trace is disabled (it wrote ~107k journal lines/day).
Re-enable for fresh lid debugging via the commented block in
`sway-server-mode-toggle`. Decision history lives in the script comments.
