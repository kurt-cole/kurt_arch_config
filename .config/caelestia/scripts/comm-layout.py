#!/usr/bin/env python3
"""Lay out special:communication: a 2/3 column on the left, discord over the
Universal Tracker on the right (70/30). Bound to SUPER + [.

The left column is whatever other tiled window already lives there (firefox, a
stream, another tracker -- the most recently focused one if there are several);
with none, a new firefox window is opened for it. A missing discord or tracker
is started too, and the layout is applied once every window has drawn.

Nothing started here takes focus: each app is caught by a window rule
(defined in hypr-user.lua, disabled until this script switches it on) that
sends it straight to the workspace with no_initial_focus. A pid-based exec
rule would not do for firefox, since a running firefox opens the new window
from its existing process.

The tree itself is rebuilt around discord by comm-layout.lua in one synchronous dispatch, so
the focus hops that dwindle's preselect/splitratio need never hit the screen,
and focus ends up back where it was.
"""
import fcntl
import json
import os
import subprocess
import sys
import time

WS = "special:communication"
SCRIPTS = os.path.expanduser("~/.config/caelestia/scripts")
LOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "comm-layout.lock")
WAIT = 90     # the tracker alone takes ~17s to map while it loads worlds
SETTLE = 1.5  # a window maps before it has painted

APPS = {
    "discord": {
        "match": lambda c: c["class"] == "discord",
        "command": "discord",
    },
    "tracker": {
        "match": lambda c: c["class"] == "ArchipelagoLauncher" and c["title"].startswith("Tracker"),
        "command": os.path.expanduser('~/Applications/Archipelago/AppRun "Universal Tracker"'),
    },
    "firefox": {
        "match": lambda c: c["class"] == "firefox",
        "command": "firefox --new-window",
    },
}


def hyprctl(*args):
    return subprocess.run(["hyprctl", *args], capture_output=True, text=True).stdout


def lua(expr):
    """Run a lua statement inside hyprland (dispatch wraps it in hl.dispatch)."""
    return hyprctl("dispatch", "(function() %s return hl.dsp.no_op() end)()" % expr)


def pick_monitor():
    """$COMM_MONITOR, else the right-most monitor -- it always lives there,
    whichever monitor has focus."""
    if os.environ.get("COMM_MONITOR"):
        return os.environ["COMM_MONITOR"]
    mons = json.loads(hyprctl("monitors", "-j"))
    return max(mons, key=lambda m: m["x"])["name"]


def clients():
    return [c for c in json.loads(hyprctl("clients", "-j")) if c["mapped"]]


def notify(msg):
    subprocess.run(["notify-send", "-a", "comm-layout", "Communication layout", msg])


def launch(name):
    """Start an app with its catch-rule on; return the new window's address."""
    before = {c["address"] for c in clients()}
    lua("comm_layout_rules.%s:set_enabled(true)" % name)
    try:
        hyprctl("dispatch", "hl.dsp.exec_cmd(%s)" % json.dumps(APPS[name]["command"]))
        deadline = time.time() + WAIT
        while time.time() < deadline:
            for c in clients():
                if c["address"] not in before and APPS[name]["match"](c):
                    return c["address"]
            time.sleep(0.25)
    finally:
        lua("comm_layout_rules.%s:set_enabled(false)" % name)
    return None


def main():
    # A second press while the first is still waiting on a slow app would
    # launch everything twice.
    lock = open(LOCK, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return

    # Before anything lands on it: a rule-placed window goes wherever the
    # workspace currently lives, which may be the wrong monitor.
    lua("hl.dispatch(hl.dsp.workspace.move({ workspace = %s, monitor = %s }))"
        % (json.dumps(WS), json.dumps(pick_monitor())))

    cl = clients()
    found = {}
    for name in ("discord", "tracker"):
        found[name] = next((c["address"] for c in cl if APPS[name]["match"](c)), None)

    taken = set(found.values())
    others = sorted(
        (c for c in cl
         if c["workspace"]["name"] == WS and not c["floating"] and c["address"] not in taken),
        key=lambda c: c["focusHistoryID"],
    )
    found["left"] = others[0]["address"] if others else None

    launched = False
    for key, app in (("discord", "discord"), ("tracker", "tracker"), ("left", "firefox")):
        if not found[key]:
            found[key] = launch(app)
            launched = True
            if not found[key]:
                notify("%s didn't open a window within %ds" % (app, WAIT))
                return
    if launched:
        time.sleep(SETTLE)

    lua('dofile(%s)(%s, %s, %s, %s, %s)' % tuple(json.dumps(x) for x in (
        SCRIPTS + "/comm-layout.lua", WS, pick_monitor(), found["left"], found["discord"], found["tracker"])))


if __name__ == "__main__":
    sys.exit(main())
