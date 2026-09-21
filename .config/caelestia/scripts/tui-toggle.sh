#!/usr/bin/env bash
# Toggle one of the floating TUIs (ap-launcher, purgatory, cheatsheet): close it if it is
# already up, otherwise run the command that spawns it.
#
# These float over the current workspace rather than living on a special one, so
# there is no fn.toggle() to lean on -- the window either exists or it doesn't.
# Every window of the given classes is closed, so a stale one left on another
# workspace can't make the key look dead.
#
# A class may have spawned an editor rather than a TUI (SUPER + ; -> e opens
# nvim as class ap-config). Closing that window SIGHUPs nvim, which preserves
# the buffer to a swap file and exits -- the edits survive, but silently, and
# the next open greets you with a recovery prompt. So if the class has a live
# nvim socket, focus the window and ask nvim to quit instead: it raises its own
# "save changes?" prompt when the buffer is dirty, and exits when it is not.
#
# Usage: tui-toggle.sh <class[,class...]> <command> [args...]
set -euo pipefail

classes=${1:?usage: tui-toggle.sh <class[,class...]> <command> [args...]}
shift

IFS=',' read -ra want <<< "$classes"
filter=$(printf '%s\n' "${want[@]}" | jq -R . | jq -sc .)

mapfile -t found < <(
    hyprctl clients -j |
        jq -r --argjson want "$filter" '.[] | select(.class as $c | $want | index($c)) | "\(.class) \(.address)"'
)

if ((${#found[@]} == 0)); then
    exec "$@"
fi

for entry in "${found[@]}"; do
    read -r class addr <<< "$entry"
    sock="${XDG_RUNTIME_DIR:-/tmp}/nvim-${class}.sock"

    if [[ -S $sock ]] && nvim --server "$sock" --remote-expr 1 >/dev/null 2>&1; then
        # Focus first: a save prompt you cannot see is worse than no prompt.
        hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null
        # <C-\><C-N> leaves insert/terminal mode so the command line is reachable.
        nvim --server "$sock" --remote-send '<C-\><C-N>:confirm qa<CR>' >/dev/null 2>&1 || true
    else
        hyprctl dispatch "hl.dsp.window.close({ window = \"address:$addr\" })" >/dev/null
    fi
done
