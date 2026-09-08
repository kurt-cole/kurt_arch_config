#!/usr/bin/env bash
# Run an arbitrary Windows .exe under Proton, outside Steam.
#
#   proton-run.sh <appid> <exe> [args...]
#
# <appid>  the Steam game the exe belongs to: its prefix
#          (~/.local/share/Steam/steamapps/compatdata/<appid>) is used and
#          SteamAppId is exported, so a game started by this exe finds Steam.
#          0 means "not a Steam game" -- the shared `ap-win` prefix is used and
#          no SteamAppId is set.
# <exe>    a Linux path to the .exe; it is run with its own directory as cwd,
#          which is what mod loaders expect.
#
# For mod loaders and launchers (Nickel, SML, MCC) rather than AP clients --
# ap-proton-client.sh is the one that knows about Archipelago. Nothing here
# waits for or attaches to a running game: Proton starts a wineserver on the
# prefix and the exe runs in it, so do NOT also launch the game from Steam, or
# two wineservers end up on one prefix.
#
# Logs to ~/.cache/ap-launcher/proton-run-<exe name>.log.
set -u

appid=${1:?usage: proton-run.sh <appid> <exe> [args...]}
exe=${2:?usage: proton-run.sh <appid> <exe> [args...]}
shift 2

LOG_DIR="$HOME/.cache/ap-launcher"
mkdir -p "$LOG_DIR"
log="$LOG_DIR/proton-run-$(printf '%s' "$(basename "$exe" .exe)" | tr -c 'A-Za-z0-9' '-').log"
say() { echo "$(date -Is) $*" >> "$log"; }
: > "$log"

if [ ! -f "$exe" ]; then
    say "no such exe: $exe"
    command -v notify-send >/dev/null && notify-send -u critical \
        "Proton run failed" "Not found: $exe"
    exit 1
fi

proton=""
for p in /mnt/win/f/SteamLibrary/steamapps/common/Proton*/proton \
         "$HOME"/.local/share/Steam/steamapps/common/Proton*/proton; do
    [ -x "$p" ] && proton="$p"
done
if [ -z "$proton" ]; then
    say "no Proton found"
    command -v notify-send >/dev/null && notify-send -u critical \
        "Proton run failed" "No Proton install found"
    exit 1
fi

if [ "$appid" = "0" ]; then
    prefix="$HOME/.local/share/Steam/steamapps/compatdata/ap-win"
else
    prefix="$HOME/.local/share/Steam/steamapps/compatdata/$appid"
    export SteamAppId="$appid" SteamGameId="$appid"
fi
mkdir -p "$prefix"

export STEAM_COMPAT_DATA_PATH="$prefix"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"

say "using $proton, prefix $prefix"
say "running: $exe $*"
cd "$(dirname "$exe")" || exit 1
exec "$proton" run "$exe" "$@" >> "$log" 2>&1
