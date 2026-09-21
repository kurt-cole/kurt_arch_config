#!/usr/bin/env bash
# Halo: The Master Chief Collection + Archipelago, under Proton.
#
# Launched from the SUPER + ; Archipelago launcher, which opens this in a foot
# window because HaloAP_launcher.exe prompts for the room info on stdin.
#
# Three Linux-specific things, all found the hard way -- see
# ~/Projects/claude-scratchwork/halo-mcc-ap.md for the full write-up:
#
#  1. `proton runinprefix`, NOT `proton run`. `run` wraps the target in
#     c:\windows\system32\steam.exe, which relaunches it and exits -- that
#     orphans stdio, so the console launcher shows no prompts, reads no input
#     and looks hung.
#
#  2. The launcher must be the /MT (static CRT) build. Built /MD it imports
#     MSVCP140.dll, the prefix's copy does not match what it was built against,
#     and std::mutex's _Mtx_lock takes a null pointer -- the launcher dies on
#     its first APClient::poll(), before reaching the AP server.
#
#  3. HALOAP_NO_CONSOLE is REQUIRED. HaloAP.dll's AllocConsole() under Proton
#     makes MCC throw "Fatal Error" and crash, usually before the DLL even
#     connects. Both this and /MT need the locally built binaries in
#     /games/HaloAP -- the upstream release has neither.
#
# The launcher must not launch the game itself (HALOAP_NO_LAUNCH): it talks to
# HaloAP.dll over the named pipe \\.\pipe\HaloAP, which belongs to the
# wineserver, so both must share one. Steam starts a Proton game with the
# `waitforexitandrun` verb, which runs `wineserver -w` and refuses to start
# until the prefix's wineserver has exited -- and the launcher IS that
# wineserver. So MCC is started here with runinprefix on the same prefix.
# Cost: no Steam overlay, and Steam does not show the game as running.
set -u

APPID=976730
HALOAP="/games/HaloAP"
GAME_ROOT="/mnt/win/f/SteamLibrary/steamapps/common/Halo The Master Chief Collection"
BIN="$GAME_ROOT/MCC/Binaries/Win64"
PROTON="/mnt/win/f/SteamLibrary/steamapps/common/Proton Hotfix/proton"
LOG_DIR="$HOME/.cache/ap-launcher"
GAME_LOG="$LOG_DIR/halo-ap-game.log"

die() { echo "halo-ap: $*" >&2; echo; echo "press enter to close"; read -r _; exit 1; }

[ -x "$PROTON" ]                  || die "Proton Hotfix not found at $PROTON"
[ -f "$HALOAP/HaloAP_launcher.exe" ] || die "missing $HALOAP/HaloAP_launcher.exe"
[ -d "$BIN" ]                     || die "MCC not found at $BIN"
# MCC is started outside Steam (see above), so it needs the Steam client
# already running -- without it MCC exits silently a few seconds after launch.
pgrep -x steam >/dev/null         || die "Steam is not running -- start Steam first"
mkdir -p "$LOG_DIR"

# A previous run that was force-killed leaves the mod files in place; the game
# will not start like that. Put it back before doing anything else.
if [ -f "$BIN/bink2w64_original.dll" ]; then
    echo "halo-ap: recovering from an unclean exit -- restoring vanilla bink2w64.dll"
    rm -f "$BIN/bink2w64.dll" "$BIN/HaloAP.dll"
    mv "$BIN/bink2w64_original.dll" "$BIN/bink2w64.dll"
fi

export STEAM_COMPAT_DATA_PATH="$HOME/.local/share/Steam/steamapps/compatdata/$APPID"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"
export HALOAP_NO_LAUNCH=1
export HALOAP_NO_CONSOLE=1
export HALOAP_LOG="Z:\\home\\barretglass\\.cache\\ap-launcher\\haloap-dll.log"

[ -s "$HALOAP/haloap_config.txt" ] || \
    printf 'Z:\\mnt\\win\\f\\SteamLibrary\\steamapps\\common\\Halo The Master Chief Collection' \
    > "$HALOAP/haloap_config.txt"

echo "Server address must include the scheme: ws://host:port"
echo "(this build has no OpenSSL, so a bare host:port is assumed wss:// and fails)"
echo

# Once the launcher has installed the mod files, start MCC in the same prefix so
# it joins the launcher's wineserver and can reach the named pipe.
(
    for _ in $(seq 1 900); do
        [ -f "$BIN/HaloAP.dll" ] && [ -f "$BIN/bink2w64_original.dll" ] && break
        sleep 1
    done
    [ -f "$BIN/HaloAP.dll" ] || exit 0   # launcher aborted; nothing to launch
    sleep 2
    cd "$BIN" || exit 1
    SteamAppId="$APPID" SteamGameId="$APPID" HALOAP_NO_LAUNCH= \
        "$PROTON" runinprefix "$BIN/MCC-Win64-Shipping.exe" -no-eac \
        >> "$GAME_LOG" 2>&1
) &
watcher=$!
trap 'kill $watcher 2>/dev/null' EXIT

cd "$HALOAP" || die "cannot cd to $HALOAP"
"$PROTON" runinprefix "$HALOAP/HaloAP_launcher.exe"

echo
echo "Launcher exited. Quit MCC before closing this window if it is still running."
echo "press enter to close"
read -r _
