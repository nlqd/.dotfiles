# Server mode setup

Do these steps one time on each new machine.

## Step 1: Stop the system from sleeping when you close the lid

Open /etc/systemd/logind.conf. Set this value:

    HandleLidSwitch=ignore

Restart the logind service. Run this command:

    sudo systemctl restart systemd-logind

## Step 2: Let the toggle change the battery charge policy without a password

Create the file /etc/sudoers.d/battery-charge-mode. Add this rule:

    qd ALL=(root) NOPASSWD: /usr/bin/tee /sys/class/firmware-attributes/dell-wmi-sysman/attributes/PrimaryBattChargeCfg/current_value

Check the file. Run this command:

    sudo visudo -cf /etc/sudoers.d/battery-charge-mode

Confirm the output shows "parsed OK".

## Step 3: Check the BIOS settings

Confirm the dell-wmi-sysman driver shows this path:

    /sys/class/firmware-attributes/dell-wmi-sysman/attributes/PrimaryBattChargeCfg

Remove the BIOS admin password. A password blocks writes to this path.

Set the charge window in the BIOS. Use these values:

    CustomChargeStart=80
    CustomChargeStop=90

Raise CustomChargeStop before you raise CustomChargeStart. The start value must stay below the stop value.

## Step 4: Test the setup

Read the current charge policy. Run this command:

    sudo cat /sys/class/firmware-attributes/dell-wmi-sysman/attributes/PrimaryBattChargeCfg/current_value

Confirm the policy shows "Custom" in server mode.

Read the battery capacity and status. Run this command:

    cat /sys/class/power_supply/BAT0/capacity /sys/class/power_supply/BAT0/status

Confirm the capacity drifts toward 60. Confirm the status shows "Not charging".
