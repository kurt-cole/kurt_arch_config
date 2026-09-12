#!/usr/bin/env bash
# Launch Azahar with its bottom (touch) screen on a headless output that
# Sunshine streams to the Steam Deck via Moonlight.
#
# Azahar's "Separate Windows" layout (layout_option=4) puts the bottom screen
# in its own toplevel titled "... | Secondary Window". That window is moved to
# a dedicated "deck" workspace bound to the headless output and fullscreened,
# so it fills 1280x800 exactly (Deck panel resolution, no client-side scaling).
set -uo pipefail

MODE="1280x800@60"
CFG="$HOME/.config/azahar-emu/qt-config.ini"
SUN_CONF="$HOME/.config/sunshine/sunshine.conf"
SUN_UNIT="app-dev.lizardbyte.app.Sunshine.service"
HL=""

# caelestia's shell does not survive monitor hotplug -- its per-screen bindings
# go null and it logs "attempted to use dangling screen object" -- so it gets
# restarted on both sides of the headless output appearing/disappearing.
restart_shell() {
    pkill -x qs 2>/dev/null            # -x: exact process name, never matches our own argv
    sleep 1
    setsid caelestia shell -d >/dev/null 2>&1 &
    sleep 4
}

msg() { printf '[azahar-deck] %s\n' "$*" >&2; }
hj()  { hyprctl "$@" -j; }

py() { python3 -c "$1" "${@:2}"; }

real_monitors() {   # name x y w h, one per line, excluding headless
    hj monitors | py '
import sys,json
for m in json.load(sys.stdin):
    if not m["name"].startswith("HEADLESS"):
        print(m["name"], m["x"], m["y"], m["width"], m["height"])
'
}

# --- Azahar: force the Separate Windows layout -------------------------------
[ -f "$CFG" ] || { msg "no Azahar config yet; run azahar once first"; exit 1; }
sed -i 's/^layout_option=.*/layout_option=4/' "$CFG"
sed -i 's/^layout_option\\default=.*/layout_option\\default=false/' "$CFG"

# --- pin the real monitors so 'auto' placement can't shift them --------------
BELOW_Y=0
while read -r n x y w h; do
    hyprctl eval "hl.monitor({ output = \"$n\", mode = \"preferred\", position = \"${x}x${y}\", scale = 1 })" >/dev/null
    (( y + h > BELOW_Y )) && BELOW_Y=$(( y + h ))
done < <(real_monitors)

# --- headless output, parked below the desktop (positive coords only, so
#     Sunshine's absolute uinput touch mapping works) -----------------------
before=$(hj monitors | py 'import sys,json;print("\n".join(m["name"] for m in json.load(sys.stdin)))')
hyprctl output create headless >/dev/null
sleep 1
after=$(hj monitors | py 'import sys,json;print("\n".join(m["name"] for m in json.load(sys.stdin)))')
HL=$(comm -13 <(sort <<<"$before") <(sort <<<"$after") | head -1)
[ -n "$HL" ] || { msg "failed to create headless output"; exit 1; }
hyprctl eval "hl.monitor({ output = \"$HL\", mode = \"$MODE\", position = \"0x${BELOW_Y}\", scale = 1 })" >/dev/null
sleep 0.5
msg "headless output $HL at 0x${BELOW_Y} ($MODE)"
restart_shell

cleanup() {
    msg "tearing down"
    [ -n "$HL" ] && hyprctl output remove "$HL" >/dev/null 2>&1
    while read -r n x y w h; do
        hyprctl eval "hl.monitor({ output = \"$n\", mode = \"preferred\", position = \"auto\", scale = 1 })" >/dev/null 2>&1
    done < <(real_monitors)
    if [ -f "$SUN_CONF" ]; then
        sed -i '/^output_name/d' "$SUN_CONF"
        systemctl --user restart "$SUN_UNIT" >/dev/null 2>&1
    fi
    restart_shell
}
trap cleanup EXIT INT TERM

# --- workspace bound to that output, no gaps/border -------------------------
hyprctl eval "hl.workspace_rule({ workspace = \"name:deck\", monitor = \"$HL\", default = true, gaps_in = 0, gaps_out = 0, no_border = true, no_rounding = true, decorate = false })" >/dev/null

# --- point Sunshine at it ---------------------------------------------------
mkdir -p "$(dirname "$SUN_CONF")"
touch "$SUN_CONF"
sed -i '/^output_name/d' "$SUN_CONF"
echo "output_name = $HL" >> "$SUN_CONF"
systemctl --user restart "$SUN_UNIT" >/dev/null 2>&1
msg "sunshine streaming $HL -- connect Moonlight on the Deck"

# --- launch Azahar (XWayland: Qt's Wayland plugin can't do shared GL contexts)
QT_QPA_PLATFORM=xcb azahar "$@" &
AZ=$!

# --- place the secondary window once it appears -----------------------------
for _ in $(seq 1 60); do
    sleep 1
    kill -0 $AZ 2>/dev/null || break
    ADDR=$(hj clients | py '
import sys,json
for c in json.load(sys.stdin):
    if "Secondary Window" in c["title"]:
        print(c["address"]); break
')
    [ -n "$ADDR" ] || continue
    PREV=$(hj activewindow | py 'import sys,json;print(json.load(sys.stdin).get("address",""))')
    hyprctl dispatch "hl.dsp.window.move({ window = \"address:$ADDR\", workspace = \"name:deck\", follow = false })" >/dev/null
    sleep 0.5
    # fullscreen ignores the reserved area caelestia's bar claims on every
    # output; the dispatcher only acts on the focused window, so focus, then
    # hand focus back to whatever had it.
    hyprctl dispatch "hl.dsp.focus({ window = \"address:$ADDR\" })" >/dev/null
    sleep 0.5
    hyprctl dispatch 'hl.dsp.window.fullscreen({})' >/dev/null
    sleep 0.5
    [ -n "$PREV" ] && hyprctl dispatch "hl.dsp.focus({ window = \"address:$PREV\" })" >/dev/null
    msg "bottom screen placed on $HL"
    break
done

wait $AZ
