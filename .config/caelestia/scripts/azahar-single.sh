#!/usr/bin/env bash
# Plain Azahar launch. Undoes the Separate Windows layout that azahar-deck.sh
# sets, but leaves any other layout choice alone.
set -uo pipefail
CFG="$HOME/.config/azahar-emu/qt-config.ini"
if [ -f "$CFG" ] && grep -q '^layout_option=4' "$CFG"; then
    sed -i 's/^layout_option=4/layout_option=0/' "$CFG"
fi
# Hand saves back and forth with the Steam Deck (no-op if it is asleep).
SYNC="$(dirname "$0")/deck-3ds-sync.sh"
"$SYNC" launch
# XWayland: Qt's Wayland platform plugin can't provide shared OpenGL contexts,
# which Azahar needs ("OpenGL shared contexts are not supported").
env QT_QPA_PLATFORM=xcb azahar "$@"
rc=$?
"$SYNC" exit
exit $rc
