#!/usr/bin/env python3
"""Keep an XWayland popup on the special workspace it was opened over.

Hyprland maps Steam's menus (X11 override-redirect, _NET_WM_WINDOW_TYPE_POPUP_MENU)
onto the correct special workspace and then, a moment later, reassigns them to the
monitor's regular active workspace -- so the menu ends up invisible *behind* the
pulled-up group and dies unnoticed when steam loses focus. The reassignment
happens after window.open fires, which is why the lua hook cannot just move it
inline, and window rules never see these windows at all.

So: watch the window for a short while and put it back whenever it drifts off.

Usage: popup-keeper.py <address> <special:workspace>
"""
import json
import subprocess
import sys
import time

WATCH_SECONDS = 2.0
INTERVAL = 0.05


def clients():
    out = subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True).stdout
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return []


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: popup-keeper.py <address> <special:workspace>")
    address, workspace = sys.argv[1], sys.argv[2]

    deadline = time.time() + WATCH_SECONDS
    while time.time() < deadline:
        win = next((c for c in clients() if c["address"] == address), None)
        if win is None:
            return  # popup dismissed already
        if win["workspace"]["name"] != workspace:
            subprocess.run([
                "hyprctl", "dispatch",
                'hl.dsp.window.move({{ window = "address:{}", workspace = "{}", follow = false }})'
                .format(address, workspace),
            ], capture_output=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
