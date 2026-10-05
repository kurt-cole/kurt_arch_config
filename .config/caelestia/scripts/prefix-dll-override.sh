#!/usr/bin/env bash
# Set DLLs to native,builtin in a game's Proton prefix.
#
#   prefix-dll-override.sh <appid> <dll>[,<dll>...]
#
# Wine always prefers its own builtin DLL, so a *proxy* DLL dropped into a game
# folder -- BepInEx's winhttp.dll doorstop, an AP world's dsound/dinput hook --
# is silently ignored: the game starts, no mod loads, and nothing is logged
# anywhere. The per-prefix registry override under HKCU\Software\Wine\DllOverrides
# fixes it without any Steam launch options, which is the point: launch options
# are per-game manual setup and are lost if edited while Steam is running.
#
# Run it from a launcher.toml entry's `commands`, before the steam:// launch:
#
#   commands = [".../prefix-dll-override.sh 4384880 winhttp",
#               "steam steam://rungameid/4384880"]
#
# **A prefix rebuild wipes this** (a Proton version bump, or deleting compatdata),
# which is exactly how Horse Riding Classic's doorstop stopped working -- so it
# belongs in `commands`, re-checked on every launch, not applied once by hand.
# Already-set overrides cost nothing: the check is a grep of user.reg and no wine
# process is started.
#
# ap-proton-client.sh does the same thing for entries that have a proton_client;
# this is the standalone version, for a game whose mod talks to the AP server
# itself and so has no client at all.
#
# Logs to ~/.cache/ap-launcher/dll-override-<appid>.log.
set -u

usage='usage: prefix-dll-override.sh <appid> <dll>[,<dll>...]'
appid=${1:?$usage}
dlls=${2:?$usage}

LOG_DIR="$HOME/.cache/ap-launcher"
mkdir -p "$LOG_DIR"
log="$LOG_DIR/dll-override-$appid.log"
verbose=0
[ -t 1 ] && verbose=1
say() {
    line="$(date -Is) $*"
    printf '%s\n' "$line" >> "$log"
    [ "$verbose" = 1 ] && printf '%s\n' "$line"
    return 0
}
run_logged() {
    if [ "$verbose" = 1 ]; then
        "$@" 2>&1 | tee -a "$log"
        return "${PIPESTATUS[0]}"
    fi
    "$@" >> "$log" 2>&1
}

if [ "$appid" = "0" ]; then
    prefix="$HOME/.local/share/Steam/steamapps/compatdata/ap-win"
else
    prefix="$HOME/.local/share/Steam/steamapps/compatdata/$appid"
fi

# The prefix has to exist: Proton builds it on the game's first launch. Say so
# rather than creating a half-made one behind Steam's back.
if [ ! -d "$prefix/pfx" ]; then
    say "no prefix at $prefix yet -- launch the game once, then run this again"
    command -v notify-send >/dev/null && notify-send -u critical \
        "DLL override skipped" "No Proton prefix for $appid yet -- launch the game once first."
    exit 1
fi

missing=""
for d in $(printf '%s' "$dlls" | tr ',' ' '); do
    grep -q "\"$d\"=\"native,builtin\"" "$prefix/pfx/user.reg" 2>/dev/null || missing="$missing $d"
done
if [ -z "$missing" ]; then
    say "already set in $prefix:$(printf '%s' " $dlls" | tr ',' ' ')"
    exit 0
fi

proton=""
for p in $(sed -n 's/.*"path"[[:space:]]*"\(.*\)"/\1/p' "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf" 2>/dev/null | sed 's|$|/steamapps/common/Proton*/proton|') \
         "$HOME"/.local/share/Steam/steamapps/common/Proton*/proton; do
    [ -x "$p" ] && proton="$p"
done
if [ -z "$proton" ]; then
    say "no Proton found"
    exit 1
fi

# One .bat for the whole set, so a single wineserver session covers them all.
# It lives under $HOME, which the prefix sees as Z:\home\...
bat="$LOG_DIR/override-$appid.bat"
{
    printf '@echo off\r\n'
    for d in $missing; do
        printf 'reg add "HKCU\\Software\\Wine\\DllOverrides" /v %s /d "native,builtin" /f\r\n' "$d"
    done
} > "$bat"

say "setting native,builtin in $prefix for:$missing"
export STEAM_COMPAT_DATA_PATH="$prefix"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"
run_logged "$proton" run "Z:$(printf '%s' "$bat" | tr '/' '\\')"

# Leave the prefix idle before Steam launches the game into it -- reg.exe exits
# but the wineserver lingers, and the registry is only flushed to user.reg when
# it goes away, so without this the very next check would still see nothing.
wineserver=$(dirname "$proton")/files/bin/wineserver
if [ -x "$wineserver" ]; then
    WINEPREFIX="$prefix/pfx" run_logged "$wineserver" -w
fi

for d in $missing; do
    if grep -q "\"$d\"=\"native,builtin\"" "$prefix/pfx/user.reg" 2>/dev/null; then
        say "ok: $d"
    else
        say "FAILED to set $d"
        command -v notify-send >/dev/null && notify-send -u critical \
            "DLL override failed" "Could not set $d=native,builtin for $appid"
    fi
done
