#!/usr/bin/env bash
# Launch Azahar with its bottom (touch) screen on a headless output that
# Sunshine streams to the Steam Deck via Moonlight, and OBS composing both
# screens for Discord.
#
# Azahar's "Separate Windows" layout (layout_option=4) puts the bottom screen
# in its own toplevel titled "... | Secondary Window". That window is moved to
# a dedicated "deck" workspace bound to the headless output and fullscreened,
# so it fills 1280x800 exactly (Deck panel resolution, no client-side scaling).
#
# The headless output is created once and then kept for the life of the
# Hyprland session. It is NOT torn down, because:
#   - OBS captures it through the PipeWire portal, and a portal restore token
#     can only restore an output that still exists. Recreating it every session
#     means re-picking the screen in a portal dialog every session.
#   - caelestia's shell does not survive monitor hotplug (dangling screen
#     objects, per-screen bindings go null, the bar disappears), so each
#     create/remove costs a shell restart. Creating it once costs one.
# It is PARKED far away when idle and MOVED next to the desktop for a session:
# repositioning an output keeps its identity (same wl_output, same PipeWire
# node, restore token still valid) where destroying it would not. Parked far
# away nothing can wander onto it; while playing it must be adjacent, because
# touch input warps the cursor onto it and an output with no adjacent neighbour
# cannot be left again by relative mouse motion -- the pointer would strand.
set -uo pipefail

MODE="1280x800@60"
PARK="10000x10000"          # idle: unreachable by pointer motion
CFG="$HOME/.config/azahar-emu/qt-config.ini"
SUN_CONF="$HOME/.config/sunshine/sunshine.conf"
SUN_UNIT="app-dev.lizardbyte.app.Sunshine.service"
AZ_LOG="${XDG_CACHE_HOME:-$HOME/.cache}/azahar-deck.log"
WD=""
STARTED_OBS=0
STARTED_SUN=0

SCRIPT_LOG="${XDG_CACHE_HOME:-$HOME/.cache}/azahar-deck-script.log"
msg() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$SCRIPT_LOG" >&2
}
hj()  { hyprctl "$@" -j; }
py()  { python3 -c "$1" "${@:2}"; }

restart_shell() {
    pkill -x qs 2>/dev/null            # -x: exact process name, never matches our own argv
    sleep 1
    setsid caelestia shell -d >/dev/null 2>&1 &
    sleep 4
}

headless_name() {
    hj monitors | py 'import sys,json
n=[m["name"] for m in json.load(sys.stdin) if m["name"].startswith("HEADLESS")]
print(n[0] if n else "")'
}

real_monitors() {
    hj monitors | py 'import sys,json
for m in json.load(sys.stdin):
    if not m["name"].startswith("HEADLESS"):
        print(m["name"], m["x"], m["y"], m["width"], m["height"])'
}

place_headless() {   # $1 = position, e.g. "0x1440" or "$PARK"
    hyprctl eval "hl.monitor({ output = \"$HL\", mode = \"$MODE\", position = \"$1\", scale = 1 })" >/dev/null
    sleep 0.5
}

# Create the headless output only if there is not one already, then bring it
# alongside the desktop for this session.
ensure_headless() {
    HL=$(headless_name)
    if [ -n "$HL" ]; then
        msg "reusing headless output $HL"
        pin_monitors
        place_headless "0x$(below_y)"
        return 0
    fi

    pin_monitors
    hyprctl output create headless >/dev/null
    sleep 1
    HL=$(headless_name)
    [ -n "$HL" ] || { msg "failed to create headless output"; return 1; }
    place_headless "0x$(below_y)"
    msg "created headless output $HL at 0x$(below_y) ($MODE)"
    restart_shell                      # only on creation, never again
}

# The real monitors use position "auto", which packs by x regardless of y, so
# an output placed at 0x1440 still shifts DP-1 sideways unless they are pinned.
pin_monitors() {
    while read -r n x y w h; do
        hyprctl eval "hl.monitor({ output = \"$n\", mode = \"preferred\", position = \"${x}x${y}\", scale = 1 })" >/dev/null
    done < <(real_monitors)
}

below_y() {   # y just under the tallest real monitor
    real_monitors | py 'import sys
print(max(int(l.split()[2]) + int(l.split()[4]) for l in sys.stdin))'
}

go_fullscreen() {
    local addr=$1 prev
    prev=$(hj activewindow | py 'import sys,json;print(json.load(sys.stdin).get("address",""))')
    [ "$prev" = "$addr" ] && prev=""
    hyprctl dispatch "hl.dsp.focus({ window = \"address:$addr\" })" >/dev/null
    sleep 0.4
    hyprctl dispatch 'hl.dsp.window.fullscreen({})' >/dev/null
    sleep 0.4
    [ -n "$prev" ] && hyprctl dispatch "hl.dsp.focus({ window = \"address:$prev\" })" >/dev/null
}

watchdog() {
    while sleep 3; do
        local state
        state=$(hj clients | py 'import sys,json
for c in json.load(sys.stdin):
    if "Secondary Window" in c["title"]:
        print(c["address"], c["fullscreen"], c["workspace"]["name"]); break')
        [ -n "$state" ] || continue
        set -- $state
        [ "$2" = "0" ] && [ "$3" = "deck" ] && go_fullscreen "$1"
    done
}

# A Sunshine pad from the *previous* session can still be present when the
# script starts -- the uinput device outlives the disconnect by a moment -- and
# a bare existence check then skips the wait entirely and Azahar comes up with
# no controller again. Require one that appeared after we started.
START_TS=$(date +%s)
# Sunshine otherwise creates sink-sunshine-* and makes it the *default* sink for
# the whole session, so desktop audio disappears into the stream. Pointing
# audio_sink at the real output's monitor makes it capture that instead, and it
# stops touching the default. The default is read fresh each launch because it
# changes (AirPods vs speakers).
configure_audio_sink() {
    local cur want
    cur=$(pactl get-default-sink 2>/dev/null) || return 0
    case "$cur" in
        sink-sunshine*|"") return 0 ;;      # already hijacked or unknown; leave it
    esac
    want="audio_sink = ${cur}.monitor"
    grep -qxF "$want" "$SUN_CONF" && return 1   # unchanged
    sed -i '/^audio_sink/d' "$SUN_CONF"
    echo "$want" >> "$SUN_CONF"
    msg "audio capture pinned to ${cur}.monitor"
    return 0                                    # changed -> needs a restart
}

have_pad() {
    py '
import os, sys, glob
start = int(sys.argv[1])
for js in glob.glob("/sys/class/input/js*"):
    try:
        name = open(os.path.join(js, "device", "name")).read()
    except OSError:
        continue
    if "sunshine" not in name.lower():
        continue
    dev = "/dev/input/" + os.path.basename(js)
    try:
        if os.stat(dev).st_mtime >= start:
            sys.exit(0)
    except OSError:
        continue
sys.exit(1)
' "$START_TS"
}

wait_for_gamepad() {
    local waited=0
    if have_pad; then
        msg "gamepad already present at start -- not waiting"
        return 0
    fi
    msg "waiting for the Deck to connect (Moonlight -> Desktop); Ctrl-C to skip"
    while [ $waited -lt ${GAMEPAD_WAIT:-180} ]; do
        sleep 2; waited=$((waited + 2))
        have_pad && { msg "gamepad detected after ${waited}s"; sleep 1; return 0; }
    done
    msg "no gamepad after ${waited}s -- starting without one"
}

# Touch input warps the cursor onto the headless output, so it can still be
# sitting there when the session ends. Parking the output far away with the
# cursor on it would strand the pointer on a screen that has no neighbour and
# cannot be seen, so put it back on a real monitor first.
recover_cursor() {
    local moved
    moved=$(hj monitors | py '
import sys, json, subprocess
mons = json.load(sys.stdin)
hl = [m for m in mons if m["name"].startswith("HEADLESS")]
real = [m for m in mons if not m["name"].startswith("HEADLESS")]
if not hl or not real:
    raise SystemExit
h = hl[0]
x, y = (int(v) for v in subprocess.run(["hyprctl","cursorpos"],
        capture_output=True, text=True).stdout.split(","))
if h["x"] <= x < h["x"] + h["width"] and h["y"] <= y < h["y"] + h["height"]:
    r = real[0]
    print(r["x"] + r["width"] // 2, r["y"] + r["height"] // 2)
')
    [ -n "$moved" ] || return 0
    set -- $moved
    hyprctl dispatch "hl.dsp.cursor.move({ x = $1, y = $2 })" >/dev/null
    msg "cursor was on $HL -- moved back to $1,$2"
}

cleanup() {
    msg "tearing down"
    [ -n "$WD" ] && kill "$WD" 2>/dev/null
    # Kept, but parked far away so nothing can wander onto it while idle.
    if [ -n "${HL:-}" ]; then
        recover_cursor
        place_headless "$PARK"
    fi
    if [ "$STARTED_OBS" = 1 ]; then
        pkill -x obs 2>/dev/null        # SIGTERM so OBS shuts down clean and
    fi                                  # does not show its crash dialog next time
    # Leaving Sunshine up would keep it streaming an output that is parked far
    # away and invisible, so stop it again unless it was already running.
    if [ "$STARTED_SUN" = 1 ]; then
        systemctl --user stop "$SUN_UNIT" >/dev/null 2>&1
        msg "sunshine stopped"
    fi
}
trap cleanup EXIT INT TERM

[ -f "$CFG" ] || { msg "no Azahar config yet; run azahar once first"; exit 1; }
sed -i 's/^layout_option=.*/layout_option=4/' "$CFG"
sed -i 's/^layout_option\\default=.*/layout_option\\default=false/' "$CFG"

ensure_headless || exit 1

hyprctl eval "hl.workspace_rule({ workspace = \"name:deck\", monitor = \"$HL\", default = true, gaps_in = 0, gaps_out = 0, no_border = true, no_rounding = true, decorate = false })" >/dev/null

# Sunshine only needs restarting when the output it points at actually changes,
# which with a persistent output is once per boot. The packaged unit allows only
# 5 starts per 500s (overridden in a drop-in), so restarts are worth avoiding.
mkdir -p "$(dirname "$SUN_CONF")"; touch "$SUN_CONF"
AUDIO_CHANGED=0
configure_audio_sink && AUDIO_CHANGED=1
if ! grep -qx "output_name = $HL" "$SUN_CONF" || [ "$AUDIO_CHANGED" = 1 ]; then
    sed -i '/^output_name/d' "$SUN_CONF"
    echo "output_name = $HL" >> "$SUN_CONF"
    systemctl --user restart "$SUN_UNIT" >/dev/null 2>&1
    STARTED_SUN=1
    msg "sunshine now streaming $HL"
else
    if ! systemctl --user is-active --quiet "$SUN_UNIT"; then
        systemctl --user start "$SUN_UNIT"
        STARTED_SUN=1
    fi
    msg "sunshine already streaming $HL"
fi

# OBS composes both screens for Discord; share its projector window there.
# Minimised to tray so it is not a window in the way.
if ! pgrep -x obs >/dev/null; then
    QT_QPA_PLATFORM=xcb setsid obs --minimize-to-tray --disable-shutdown-check \
        >/dev/null 2>&1 &
    STARTED_OBS=1
    msg "obs started (minimised to tray)"
fi

wait_for_gamepad

: > "$AZ_LOG"
QT_QPA_PLATFORM=xcb azahar "$@" >>"$AZ_LOG" 2>&1 &
AZ=$!
msg "azahar log: $AZ_LOG"

for _ in $(seq 1 60); do
    sleep 1
    kill -0 $AZ 2>/dev/null || break
    ADDR=$(hj clients | py 'import sys,json
for c in json.load(sys.stdin):
    if "Secondary Window" in c["title"]:
        print(c["address"]); break')
    [ -n "$ADDR" ] || continue
    hyprctl dispatch "hl.dsp.window.move({ window = \"address:$ADDR\", workspace = \"name:deck\", follow = false })" >/dev/null
    sleep 0.5
    go_fullscreen "$ADDR"
    msg "bottom screen placed on $HL"
    watchdog & WD=$!
    break
done

wait $AZ
