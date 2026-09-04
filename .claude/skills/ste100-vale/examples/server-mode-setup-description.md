# Server mode: how it works

Sway server mode keeps the laptop running with the lid closed. The system stops the
screen when the lid closes. The system starts the screen when the lid
opens. The system does not suspend.

Server mode also caps the battery charge. This lowers wear on a battery
that already lost about half of its original capacity. When server mode stops,
the battery charges to full. This prepares the laptop for
travel.

The sway-server-mode-toggle script writes the state file. It changes the
battery policy through the battery-charge-mode script. It sends a
notification. It signals waybar.

The sway-lid-handler script watches the sway bindswitch event. On lid
close, it stops the screen in server mode. It suspends the system in
normal mode. On lid open, it checks the ACPI lid switch. This check
rejects a false open event from the kanata virtual keyboard.

The battery-charge-mode script sets the Dell charge policy. The cap
command sets the Custom policy. The full command sets the Standard
policy. The sync command matches the saved mode. Sway runs the sync
command at boot.

The system disables a verbose libinput lid trace by default. It once
wrote about 107,000 journal lines each day. A commented block in the
script re-enables it for lid debugging.
