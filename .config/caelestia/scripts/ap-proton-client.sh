#!/usr/bin/env bash
# Start an Archipelago *Windows* client inside a running Steam game's Proton
# container, so clients that read or patch game memory (pymem, ReadProcessMemory,
# VirtualProtectEx) can reach it. A Linux AP client cannot: from the host side the
# game is one opaque wine process, and a client started outside the container gets
# its own wineserver, sharing nothing.
#
# Usage:  ap-proton-client.sh <appid> <client> [debug] [apworld] [mode] [dll_overrides]
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
#     appid may be 0 for a game Steam doesn't own at all (Cave Story's freeware
#     build): nothing is waited for, and dll_overrides land in the client prefix,
#     which is where the client starts the game.
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
dll_overrides=${6:-}   # comma-separated, e.g. "dsound" -- set native in the GAME's prefix

AP_DIR="$HOME/Applications/Archipelago-win"
WORLDS="$HOME/.local/share/Archipelago/worlds"
LOG_DIR="$HOME/.cache/ap-launcher"
TIMEOUT=180
GRACE=20      # how long to hold out for a container name that is provably new
SETTLE=15     # let the game finish starting before injecting into its container
SURVIVED=30   # a client alive this long started fine; a quicker exit is a failure
ATTEMPTS=3

mkdir -p "$LOG_DIR"
# appid 0 means "not a Steam game" -- the client launches the game itself, in the
# client's own prefix (Cave Story). Name the log after the client instead.
slug=$appid
[ "$appid" = "0" ] && slug=$(printf '%s' "$client" | tr -c 'A-Za-z0-9' '-')
log="$LOG_DIR/inject-$slug.log"
# When stdout is a terminal (the launcher's debug mode opens one per command),
# mirror everything to it as well as to the log -- otherwise a debug window shows
# an empty terminal while all the output goes to a file.
verbose=0
[ -t 1 ] && verbose=1
run_logged() {  # run "$@", to the log and, when verbose, to the terminal too
    if [ "$verbose" = 1 ]; then
        "$@" 2>&1 | tee -a "$log"
        return "${PIPESTATUS[0]}"
    fi
    "$@" >> "$log" 2>&1
}
say() {
    line="$(date -Is) $*"
    printf '%s\n' "$line" >> "$log"
    [ "$verbose" = 1 ] && printf '%s\n' "$line"
    return 0
}
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
run_in_prefix() {
    # Run a generated .bat in a prefix. The .bat must live somewhere the prefix
    # can see; $LOG_DIR is under $HOME, which is Z:\home\... inside wine.
    prefix_="$1"
    proton_="$2"
    bat_="$3"
    (
        export STEAM_COMPAT_DATA_PATH="$prefix_"
        export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"
        run_logged "$proton_" run "Z:$(printf '%s' "$bat_" | tr '/' '\\')"
    )
}

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
    run_in_prefix "$prefix_" "$proton_" "$bat_"
}

# Proton prefers its own builtin DLLs, so a proxy DLL dropped in a game folder
# (the usual way an AP world injects a hook) is silently ignored and the client
# just reports "not connected". Wine reads per-prefix overrides from the
# registry, so this needs no Steam launch options.
override_dll() {
    prefix_="$1"
    proton_="$2"
    dll_="$3"
    grep -q "\"$dll_\"=\"native,builtin\"" "$prefix_/pfx/user.reg" 2>/dev/null && return 0
    bat_="$LOG_DIR/override-$dll_.bat"
    printf '@echo off\r\nreg add "HKCU\\Software\\Wine\\DllOverrides" /v %s /d "native,builtin" /f\r\n' \
        "$dll_" > "$bat_"
    say "overriding $dll_ to native in prefix $prefix_"
    run_in_prefix "$prefix_" "$proton_" "$bat_"
}

if [ "$how" = "standalone" ]; then
    # Deliberately NOT the game's prefix. Running the client there with the game's
    # SteamAppId makes Steam think the app is already running -- its launch then
    # stalls in WaitingPrevProcess and the game never appears -- and it would put
    # a second wineserver on one prefix. The client reaches the game's hook over
    # loopback TCP, so a prefix of its own costs nothing.
    say "standalone: starting $client in the shared client prefix"
    prefix="$HOME/.local/share/Steam/steamapps/compatdata/ap-win"
    mkdir -p "$prefix"
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
    if [ -d "$prefix/pfx" ]; then
        register_steam_url_handler "$prefix" "$proton"
    fi
    # These belong to the prefix the GAME runs in, where it will load them. For a
    # non-Steam game (appid 0) that is this same client prefix, since the client
    # starts the game itself.
    if [ -n "$dll_overrides" ]; then
        if [ "$appid" = "0" ]; then
            game_prefix="$prefix"
        else
            game_prefix="$HOME/.local/share/Steam/steamapps/compatdata/$appid"
        fi
        if [ -d "$game_prefix/pfx" ]; then
            for d in $(printf '%s' "$dll_overrides" | tr ',' ' '); do
                override_dll "$game_prefix" "$proton" "$d"
            done
        else
            say "no prefix at $game_prefix yet -- launch once more to set: $dll_overrides"
        fi
    fi
    export STEAM_COMPAT_DATA_PATH="$prefix"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"
    export SteamAppId="$appid" SteamGameId="$appid"
    run_logged "$proton" run "$exe" "$client"
    exit $?
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
waited=0

give_up() {  # give_up <what>
    say "gave up after ${waited}s: $1"
    command -v notify-send >/dev/null && notify-send -u critical \
        "Archipelago: no Proton client" \
        "$client was not started: $1. See $log"
    exit 1
}

# A container OUTLIVES the game process by a good while, so the bus name alone is
# not proof that anything is running -- relaunching a game you just quit, the
# stale container is still published and the client is injected into it a moment
# before it dies (empty log, no client). Steam's reaper carries "AppId=<appid>"
# on its command line for exactly as long as the game runs, so wait for a live
# game first, and only then for its container.
game_running() {
    # Filter out this script's own pid and its parent, the trap that makes a
    # -f pattern find the shell that is looking for it.
    pgrep -f "SteamLaunch AppId=$appid " 2>/dev/null |
        grep -qvE "^($$|$PPID)$"
}

# Note which containers are already published before waiting. pressure-vessel
# owns both the well-known name and a per-instance one
# (com.steampowered.App<appid>.Instance<pid>), so anything listed now belongs to
# a run that is already over or on its way out; the new game's container is the
# instance name that appears after this point.
names() {  # every bus name this appid's containers own, well-known and per-instance
    busctl --user --no-pager --list list 2>/dev/null |
        awk -v b="$bus" '$1 == b || index($1, b ".Instance") == 1 { print $1 }'
}
stale=$(names)

say "waiting for the game (AppId=$appid) to be running"
until game_running; do
    sleep 2
    waited=$((waited + 2))
    [ "$waited" -ge "$TIMEOUT" ] && give_up "the game never started"
done
say "game running after ${waited}s, waiting for a fresh $bus container"

# Wait for an instance name that was not there before, then prove it is usable by
# running a trivial command in it -- a container that is tearing down still owns
# its names but fails the probe.
target=""
since=0
while :; do
    for i in $(names); do
        # After GRACE seconds the old container is long gone, so the well-known
        # name is the new one's -- accept it then, in case this Steam build
        # publishes no per-instance name at all.
        if printf '%s\n' "$stale" | grep -qxF "$i"; then
            [ "$since" -ge "$GRACE" ] || continue
        fi
        "$launch_client" --bus-name="$i" -- /bin/true >/dev/null 2>&1 || continue
        target=$i
        break
    done
    [ -n "$target" ] && break
    game_running || give_up "the game exited before its container was usable"
    sleep 2
    waited=$((waited + 2))
    since=$((since + 2))
    [ "$waited" -ge "$TIMEOUT" ] && give_up "the game's container never appeared"
done
bus=$target
say "container up after ${waited}s"

# Do not inject the instant the container is usable. A game whose first process
# re-execs during startup (Mirror's Edge does) makes the container tear down
# everything it launched when that first process exits, and a client started in
# that window is SIGTERMed a second later -- exit 143, and a zero-byte launcher
# log with no clue in it. Let the game settle, then verify the client survives:
# an early death by signal means we were still too soon, so try again.
attempt=1
while :; do
    say "settling ${SETTLE}s before injecting (attempt $attempt/$ATTEMPTS)"
    sleep "$SETTLE"
    game_running || give_up "the game exited before the client could be started"
    say "starting: $client"
    started=$(date +%s)
    # Inside the container wine is on PATH with the game's WINEPREFIX already set.
    run_logged "$launch_client" --bus-name="$bus" -- wine "$exe" "$client"
    rc=$?
    ran=$(( $(date +%s) - started ))
    say "client exited with status $rc after ${ran}s"
    # A client that lived a while was working and has simply been closed.
    [ "$ran" -ge "$SURVIVED" ] && exit "$rc"
    [ "$rc" -eq 0 ] && exit 0
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$ATTEMPTS" ]; then
        give_up "the client kept dying on startup (last status $rc)"
    fi
    game_running || give_up "the game exited before the client could be started"
    say "client died in ${ran}s -- the game was probably still starting, retrying"
done
