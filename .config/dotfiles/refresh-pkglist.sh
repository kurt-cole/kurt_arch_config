#!/usr/bin/env bash
# Re-snapshot the explicitly installed packages. Run after installing things.
set -euo pipefail
dir="$(dirname "$(readlink -f "$0")")"
pacman -Qqen > "$dir/pkglist-native.txt"
pacman -Qqem > "$dir/pkglist-aur.txt"
echo "updated $dir/pkglist-{native,aur}.txt"
