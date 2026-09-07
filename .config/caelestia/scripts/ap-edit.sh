#!/usr/bin/env bash
# nvim on the launcher config, listening on a socket named after its window
# class so tui-toggle.sh can ask it to quit -- letting nvim raise its own
# "save changes?" prompt -- instead of closing the terminal out from under it.
set -euo pipefail

sock="${XDG_RUNTIME_DIR:-/tmp}/nvim-ap-config.sock"

# A socket left behind by a crash makes --listen fail, which would break edit
# mode entirely; drop it, but only once it is confirmed dead.
if [[ -S $sock ]] && ! nvim --server "$sock" --remote-expr 1 >/dev/null 2>&1; then
    rm -f "$sock"
fi

exec nvim --listen "$sock" "$@"
