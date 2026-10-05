#!/usr/bin/env bash
# Install the core package set. Native packages first, then AUR via paru
# (bootstrapped from the AUR if missing). Optional and hardware-specific
# packages are listed in pkglist-extras.txt and are NOT installed here.
set -euo pipefail
dir="$(dirname "$(readlink -f "$0")")"
sudo pacman -S --needed - < "$dir/pkglist-native.txt"
if ! command -v paru >/dev/null; then
    tmp=$(mktemp -d)
    git clone https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin"
    (cd "$tmp/paru-bin" && makepkg -si --noconfirm)
    rm -rf "$tmp"
fi
paru -S --needed - < "$dir/pkglist-aur.txt"
