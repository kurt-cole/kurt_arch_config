#!/usr/bin/env bash
# Start an Archipelago *Windows* client inside a running Steam game's Proton
# container, so clients that read or patch game memory (pymem, ReadProcessMemory,
# VirtualProtectEx) can reach it. A Linux AP client cannot: from the host side the
# game is one opaque wine process, and a client started outside the container gets
# its own wineserver, sharing nothing.
#
# Usage:  ap-proton-client.sh <appid> <client name> [debug] [apworld] [mode]
#
# mode = attach (default)
#     Wait for Steam to publish the *running* game's container and start the
#     client inside it. For clients that read or patch game memory, which needs
#     the same wineserver session as the game (ANIMAL WELL).
# mode = standalone
#     Start the client in the game's prefix right away, without waiting for
#     anything. For clients that launch the game themselves, and for clients that
#     talk to an injected DLL over loopback TCP rather than touching the game's
#     memory -- that crosses the container boundary fine (Feeding Frenzy 2).
#
# Requires STEAM_COMPAT_LAUNCHER_SERVICE=proton in Steam's environment (set for
# the session in ~/.config/uwsm/env-hyprland), which makes pressure-vessel publish
# each game's container as com.steampowered.App<appid> on the session bus.
# Nothing needs to be configured per game -- no Steam launch options.
set -u

appid=${1:?usage: ap-proton-client.sh <appid> <client> [debug] [apworld]}
client=${2:?usage: ap-proton-client.sh <appid> <client> [debug] [apworld]}
mode=${3:-}
apworld=${4:-}
how=${5:-attach}

AP_DIR="$HOME/Applications/Archipelago-win"
WORLDS="$HOME/.local/share/Archipelago/worlds"
LOG_DIR="$HOME/.cache/ap-launcher"
TIMEOUT=180

mkdir -p "$LOG_DIR"
log="$LOG_DIR/inject-$appid.log"
say() { echo "$(date -Is) $*" >> "$log"; }
: > "$log"

exe="$AP_DIR/ArchipelagoLauncher.exe"
[ "$mode" = "debug" ] && exe="$AP_DIR/ArchipelagoLauncherDebug.exe"
if [ ! -f "$exe" ]; then
    say "no Windows Archipelago at $exe -- install it with:"
    say "  proton run Setup.Archipelago.<version>.exe /VERYSILENT \"/DIR=Z:\\home\\$USER\\Applications\\Archipelago-win\""
    exit 1
fi

# Keep the Windows install's custom worlds in step with the Linux one, so turning
# on proton_client for a game needs nothing but the flag. Naming the entry's
# apworld copies just that one; otherwise every custom world is mirrored, which
# works but makes the client log a warning for each world it can't parse.
if [ -d "$WORLDS" ]; then
    mkdir -p "$AP_DIR/custom_worlds"
    if [ -n "$apworld" ] && [ -f "$WORLDS/$apworld" ]; then
        cp -u "$WORLDS/$apworld" "$AP_DIR/custom_worlds/" && say "synced $apworld"
    else
        cp -u "$WORLDS"/*.apworld "$AP_DIR/custom_worlds/" 2>/dev/null && say "synced all apworlds"
    fi
fi

launch_client=""
for c in \
    /mnt/win/f/SteamLibrary/steamapps/common/SteamLinuxRuntime_4/pressure-vessel/bin/steam-runtime-launch-client \
    "$HOME"/.local/share/Steam/steamapps/common/SteamLinuxRuntime_*/pressure-vessel/bin/steam-runtime-launch-client \
    "$HOME"/.local/share/Steam/ubuntu12_32/steam-runtime/amd64/usr/bin/steam-runtime-launch-client
do
    [ -x "$c" ] && { launch_client="$c"; break; }
done
if [ -z "$launch_client" ]; then
    say "steam-runtime-launch-client not found"
    exit 1
fi

# A bare Proton prefix has no steam:// handler -- Steam registers one only inside
# its own container -- so a Windows client that launches its game with
# os.startfile("steam://run/<appid>") dies there. Proton's own steam.exe forwards
# the URL to the host Steam, so point the protocol at it. Idempotent.
register_steam_url_handler() {
    prefix_="$1"
    proton_="$2"
    grep -q 'Classes\\\\steam\\\\shell' "$prefix_/pfx/user.reg" 2>/dev/null && return 0
    bat_="$LOG_DIR/register-steam-url.bat"
    cat > "$bat_" <<'BAT'
@echo off
reg add "HKCU\Software\Classes\steam" /ve /d "URL:steam protocol" /f
reg add "HKCU\Software\Classes\steam" /v "URL Protocol" /d "" /f
reg add "HKCU\Software\Classes\steam\shell\open\command" /ve /d "\"C:\windows\system32\steam.exe\" \"%%1\"" /f
BAT
    say "registering the steam:// handler in the prefix"
    STEAM_COMPAT_DATA_PATH="$prefix_" \
    STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam" \
        "$proton_" run cmd /c "Z:$(printf '%s' "$bat_" | tr '/' '\\')" >> "$log" 2>&1
}

if [ "$how" = "standalone" ]; then
    say "standalone: starting $client in the prefix for $appid"
    prefix="$HOME/.local/share/Steam/steamapps/compatdata/$appid"
    proton=""
    for p in /mnt/win/f/SteamLibrary/steamapps/common/Proton*/proton \
             "$HOME"/.local/share/Steam/steamapps/common/Proton*/proton; do
        [ -x "$p" ] && proton="$p"
    done
    if [ -z "$proton" ]; then
        say "no Proton found"
        exit 1
    fi
    say "using $proton with prefix $prefix"
    [ -d "$prefix/pfx" ] && register_steam_url_handler "$prefix" "$proton"
    export STEAM_COMPAT_DATA_PATH="$prefix"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"
    export SteamAppId="$appid" SteamGameId="$appid"
    exec "$proton" run "$exe" "$client" >> "$log" 2>&1
fi

# --- attach mode ------------------------------------------------------------
# If Steam itself was started without the variable, no container will ever
# publish a service -- say so now instead of waiting out the timeout.
steam_pid=$(pgrep -f "ubuntu12_32/steam$" | head -1)
if [ -n "${steam_pid:-}" ] &&
   ! tr '\0' '\n' < "/proc/$steam_pid/environ" 2>/dev/null |
     grep -q '^STEAM_COMPAT_LAUNCHER_SERVICE='; then
    say "Steam is running without STEAM_COMPAT_LAUNCHER_SERVICE -- restart Steam"
    command -v notify-send >/dev/null && notify-send -u critical \
        "Archipelago: no Proton client" \
        "Steam was started without STEAM_COMPAT_LAUNCHER_SERVICE=proton, so $client cannot be attached to the game. Restart Steam and launch again."
    exit 1
fi

bus="com.steampowered.App$appid"
say "waiting for $bus"
waited=0
until busctl --user --no-pager list 2>/dev/null | grep -q "^$bus "; do
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge "$TIMEOUT" ]; then
        say "gave up after ${TIMEOUT}s waiting for the game's container"
        command -v notify-send >/dev/null && notify-send -u critical \
            "Archipelago: no Proton client" \
            "$client was not started: the game's container never appeared. See $log"
        exit 1
    fi
done
say "container up after ${waited}s, starting: $client"

# Inside the container wine is on PATH with the game's WINEPREFIX already set.
exec "$launch_client" --bus-name="$bus" -- wine "$exe" "$client" >> "$log" 2>&1
