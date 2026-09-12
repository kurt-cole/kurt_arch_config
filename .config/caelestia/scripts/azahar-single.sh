#!/usr/bin/env bash
# Plain Azahar launch. Undoes the Separate Windows layout that azahar-deck.sh
# sets, but leaves any other layout choice alone.
set -uo pipefail
CFG="$HOME/.config/azahar-emu/qt-config.ini"
if [ -f "$CFG" ] && grep -q '^layout_option=4' "$CFG"; then
    sed -i 's/^layout_option=4/layout_option=0/' "$CFG"
fi
# XWayland: Qt's Wayland platform plugin can't provide shared OpenGL contexts,
# which Azahar needs ("OpenGL shared contexts are not supported").
exec env QT_QPA_PLATFORM=xcb azahar "$@"
