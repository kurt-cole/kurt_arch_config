#!/usr/bin/env bash
# Installs automatic app-menu entries for Steam and Heroic games.
# Safe to re-run (do so after adding a new Steam library folder).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.local/bin"
UNITS="$HOME/.config/systemd/user"
STEAM="$HOME/.local/share/Steam"

command -v python3 >/dev/null || { echo "python3 is required (sudo pacman -S python)"; exit 1; }
mkdir -p "$BIN" "$UNITS"

install -m 755 "$HERE/steam-desktop-sync" "$HERE/heroic-desktop-sync" "$BIN/"
install -m 644 "$HERE/steam-desktop-sync.service" "$HERE/heroic-desktop-sync.service" "$HERE/heroic-desktop-sync.path" "$UNITS/"

# Build the Steam watcher from this machine's own library list.
{
    echo "[Unit]"
    echo "Description=Watch Steam libraries for installs and uninstalls"
    echo
    echo "[Path]"
    echo "PathChanged=%h/.local/share/Steam/steamapps"
    if [ -f "$STEAM/steamapps/libraryfolders.vdf" ]; then
        grep -oP '"path"\s+"\K[^"]+' "$STEAM/steamapps/libraryfolders.vdf" | while read -r lib; do
            [ "$(realpath -m "$lib")" = "$(realpath -m "$STEAM")" ] && continue
            echo "PathChanged=$lib/steamapps"
        done
    fi
    echo
    echo "[Install]"
    echo "WantedBy=default.target"
} > "$UNITS/steam-desktop-sync.path"

echo "Steam libraries being watched:"
grep '^PathChanged=' "$UNITS/steam-desktop-sync.path" | sed 's/^PathChanged=/  /'

systemctl --user daemon-reload
if [ -d "$STEAM" ]; then
    systemctl --user enable --now steam-desktop-sync.path
    systemctl --user restart steam-desktop-sync.path
    "$BIN/steam-desktop-sync"
else
    echo "Steam not found at $STEAM; skipped enabling the Steam watcher."
fi
if [ -d "$HOME/.config/heroic" ]; then
    systemctl --user enable --now heroic-desktop-sync.path
    "$BIN/heroic-desktop-sync"
else
    echo "Heroic not found at ~/.config/heroic; skipped enabling the Heroic watcher."
fi
echo "Done."
