#!/usr/bin/env bash
# Run an Archipelago *Windows* client in the same Proton container as the game,
# so clients that read or patch game memory (pymem, VirtualProtectEx, ...) work.
# A Linux AP client cannot do that -- from the host the game is one opaque wine
# process -- and a client started outside the container gets its own wineserver.
#
# Set once per game, in Steam -> Properties -> Launch Options:
#     /home/barretglass/.config/caelestia/scripts/ap-proton-wrap.sh %command%
#
# Inert unless ap-launcher.py has just dropped a request file naming the client,
# so launching the game from Steam normally is unaffected. The request is
# one-shot and expires, so a cancelled launch can't haunt the next one.
set -u

REQ_DIR="$HOME/.config/Archipelago/proton-clients"
AP_DIR="$HOME/Applications/Archipelago-win"
STALE_SECONDS=300
mkdir -p "$REQ_DIR"

req="$REQ_DIR/${SteamAppId:-none}"
[ -f "$req" ] || exec "$@"

age=$(( $(date +%s) - $(stat -c %Y "$req") ))
client=$(sed -n 1p "$req")
mode=$(sed -n 2p "$req")
rm -f "$req"

log="$REQ_DIR/wrap.log"
{ echo "=== $(date -Is) appid=${SteamAppId:-?} client=$client mode=${mode:-normal} age=${age}s"
  printf '  arg: %s\n' "$@"; } > "$log"

if [ "$age" -gt "$STALE_SECONDS" ]; then
    echo "  request is stale, ignoring" >> "$log"
    exec "$@"
fi

# %command% ends with the game exe; everything before it is
# steam-launch-wrapper / reaper / the runtime entry point / proton waitforexitandrun
args=("$@")
game="${args[-1]}"
case "$game" in
  *.exe|*.EXE) ;;
  *) echo "  last arg is not an .exe, running untouched" >> "$log"; exec "$@" ;;
esac

exe="$AP_DIR/ArchipelagoLauncher.exe"
[ "$mode" = "debug" ] && exe="$AP_DIR/ArchipelagoLauncherDebug.exe"

# Z: is the prefix's view of /
towin() { printf 'Z:%s' "$(printf '%s' "$1" | tr '/' '\\')"; }

# Both processes have to start *inside* the container to share its wineserver,
# so hand proton a .bat that starts each of them rather than the game directly.
bat="$REQ_DIR/launch-${SteamAppId}.bat"
{
  printf '@echo off\r\n'
  printf 'start "" "%s" "%s"\r\n' "$(towin "$exe")" "$client"
  printf 'start /wait "" "%s"\r\n' "$(towin "$game")"
} > "$bat"

args[-1]="$STEAM_COMPAT_DATA_PATH/pfx/drive_c/windows/system32/cmd.exe"
args+=("/c" "$(towin "$bat")")
echo "  -> $client via $bat" >> "$log"
exec "${args[@]}"
