#!/bin/sh
# Open a .archipelago multidata file with the Archipelago server in a console
# window. Registered as the handler for application/x-archipelago-multidata
# (see ~/.local/share/mime/packages/archipelago-multidata.xml).
#
# The frozen ArchipelagoServer binary is used directly rather than
# `AppRun <file>`: the Launcher would identify the Host component and re-launch
# it through x-terminal-emulator, which is an extra hop for the same result.
AP_DIR="$HOME/Applications/Archipelago-0.6.7/opt/Archipelago"
[ -x "$AP_DIR/ArchipelagoServer" ] || {
    notify-send "Archipelago" "ArchipelagoServer not found in $AP_DIR"
    exit 1
}
exec foot -a archipelago-server -T "Archipelago Server" \
    sh -c 'cd "$1" || exit 1; shift; ./ArchipelagoServer "$@"; status=$?; printf "\n[exited with %s] press Enter to close" "$status"; read _' \
    sh "$AP_DIR" "$@"
