#!/usr/bin/env bash
# Reinstall the snapshotted package set on a fresh machine.
# Native packages first, then AUR (needs an AUR helper -- paru or yay).
set -euo pipefail
dir="$(dirname "$(readlink -f "$0")")"
sudo pacman -S --needed - < "$dir/pkglist-native.txt"
helper=$(command -v paru || command -v yay || true)
if [ -z "$helper" ]; then
    echo "No AUR helper found; install paru, then: paru -S --needed - < $dir/pkglist-aur.txt"
    exit 0
fi
"$helper" -S --needed - < "$dir/pkglist-aur.txt"
