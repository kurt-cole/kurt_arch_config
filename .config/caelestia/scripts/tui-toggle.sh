#!/usr/bin/env bash
# Toggle one of the floating TUIs (ap-launcher, purgatory): close it if it is
# already up, otherwise run the command that spawns it.
#
# These float over the current workspace rather than living on a special one, so
# there is no fn.toggle() to lean on -- the window either exists or it doesn't.
# Matching is on class, and every window of that class is closed, so a stale one
# left on another workspace can't make the key look dead.
#
# Usage: tui-toggle.sh <class> <command> [args...]
set -euo pipefail

class=${1:?usage: tui-toggle.sh <class> <command> [args...]}
shift

mapfile -t addrs < <(hyprctl clients -j | jq -r --arg c "$class" '.[] | select(.class == $c) | .address')

if ((${#addrs[@]})); then
    for addr in "${addrs[@]}"; do
        hyprctl dispatch "hl.dsp.window.close({ window = \"address:$addr\" })" >/dev/null
    done
else
    exec "$@"
fi
