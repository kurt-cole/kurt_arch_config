#!/bin/sh
# Reboot straight into the UEFI setup (asks first -- it reboots immediately).
zenity --question --title="Boot to BIOS" --text="Reboot into the BIOS setup now?" \
    --ok-label=Reboot --cancel-label=Cancel || exit 0
exec systemctl reboot --firmware-setup
