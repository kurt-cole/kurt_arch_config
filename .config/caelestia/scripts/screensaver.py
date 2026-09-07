#!/usr/bin/env python3
"""Screensaver for hyprland: a fullscreen animation on every monitor while idle.

Wayland has no screensaver protocol, so this is assembled from parts:

  * caelestia's shell owns the idle timer (`general.idle.timeouts` in
    ~/.config/caelestia/shell.json). Its IdleMonitors.qml hands any *array*
    action to Quickshell.execDetached, so `start` and `stop` here can be wired
    straight to an idle/return pair.
  * The savers themselves are HTML pages under ~/.config/caelestia/screensavers,
    displayed by viewer.py -- a small WebKit window whose Wayland app_id is
    SAVER_CLASS, so hyprland rules and this script can find it. A .scr dropped
    into screensavers/scr/ joins the shuffle too and is run through wine.
  * Placement is imperative rather than rule-driven, because a rule cannot spread
    N identical windows across N monitors. Windows are matched by *appearance*
    (addresses that were not there before the spawn), which works for wine's
    windows as well, whose class we do not control.

Usage: screensaver.py {start,stop,toggle,status,list} [--saver NAME] [--stay]
"""

import argparse
import json
import os
import random
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
ROOT = HOME / ".config/caelestia/screensavers"
CONFIG = ROOT / "savers.json"
VIEWER = ROOT / "viewer.py"
STATE = Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "caelestia/screensaver.json"

SAVER_CLASS = "caelestia-screensaver"
WINEPREFIX = HOME / ".local/share/wineprefixes/screensavers"
SPAWN_TIMEOUT = 8.0        # seconds to wait for a saver window to appear


# --------------------------------------------------------------- hyprland ---
def hypr(*args: str) -> object:
    out = subprocess.run(["hyprctl", "-j", *args], capture_output=True, text=True)
    return json.loads(out.stdout) if out.returncode == 0 and out.stdout.strip() else []


def dispatch(expr: str) -> None:
    # This config is hyprland's lua flavour, so `hyprctl dispatch` takes a lua
    # expression rather than the usual "dispatcher args" string.
    subprocess.run(["hyprctl", "dispatch", expr], capture_output=True, text=True)


def monitors() -> list[dict]:
    return hypr("monitors")


def visible_workspace(monitor: dict) -> tuple[int, str]:
    """The workspace actually on screen, as (id, lua selector).

    A pulled-up special workspace wins -- and it has to be addressed by *name*:
    the move dispatcher accepts a special workspace's negative id and then does
    nothing with it.
    """
    special = monitor.get("specialWorkspace") or {}
    if special.get("id"):
        return special["id"], json.dumps(special["name"])
    active = monitor["activeWorkspace"]
    return active["id"], str(active["id"])


def client_addresses() -> set[str]:
    return {c["address"] for c in hypr("clients")}


# ------------------------------------------------------------------ state ---
def read_state() -> dict:
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def write_state(state: dict) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, indent=2))


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def running() -> bool:
    return any(alive(pid) for pid in read_state().get("pids", []))


# ------------------------------------------------------------------- pool ---
def load_pool() -> list[dict]:
    try:
        config = json.loads(CONFIG.read_text())
    except (OSError, ValueError) as e:
        print(f"cannot read {CONFIG}: {e}", file=sys.stderr)
        return []

    savers = [s for s in config.get("savers", []) if s.get("enabled", True)]
    listed = {s["name"] for s in config.get("savers", [])}

    # Anything dropped into scr/ joins the pool on its own; it only needs an
    # entry in savers.json to be renamed or switched off.
    for path in sorted((ROOT / "scr").glob("*.scr")):
        if path.stem not in listed:
            savers.append({"name": path.stem, "label": path.stem,
                           "type": "scr", "file": f"scr/{path.name}"})
    return savers


def command_for(saver: dict, monitor: str) -> tuple[list[str], dict]:
    """The argv and extra environment that show `saver` on `monitor`."""
    env = dict(os.environ)
    path = ROOT / saver["file"]

    if saver["type"] == "html":
        argv = [str(VIEWER), f"file://{path}?mon={monitor}", "--app-id", SAVER_CLASS]
        return argv, env

    if saver["type"] == "scr":
        if not shutil.which("wine"):
            raise RuntimeError("wine is not installed, cannot run .scr savers")
        env["WINEPREFIX"] = str(WINEPREFIX)
        env["WINEDEBUG"] = "-all"
        return ["wine", str(path), "/s"], env

    if saver["type"] == "cmd":
        return list(saver["command"]), env

    raise RuntimeError(f"unknown saver type {saver['type']!r}")


# ------------------------------------------------------------------ start ---
def move_to(address: str, monitor: dict, attempts: int = 6) -> bool:
    """Move a saver window onto `monitor`'s visible workspace.

    A window appears in `hyprctl clients` a moment before the compositor has
    finished mapping it, and dispatches aimed at it in that window are accepted
    ("ok") and then quietly do nothing -- hence verify-and-retry rather than a
    single dispatch.
    """
    target_id, selector = visible_workspace(monitor)
    for _ in range(attempts):
        dispatch(f'hl.dsp.window.move({{ window = "address:{address}", '
                 f'workspace = {selector}, follow = false }})')
        time.sleep(0.15)
        for client in hypr("clients"):
            if client["address"] == address:
                if client["workspace"]["id"] == target_id:
                    return True
                break
    return False


def fullscreen(address: str, attempts: int = 6) -> bool:
    for _ in range(attempts):
        for client in hypr("clients"):
            if client["address"] == address:
                if client.get("fullscreen"):
                    return True
                break
        dispatch(f'hl.dsp.window.fullscreen({{ window = "address:{address}" }})')
        time.sleep(0.2)
    return False


def start(name: str | None, stay: bool) -> int:
    if running():
        return 0

    pool = load_pool()
    if name:
        pool = [s for s in pool if s["name"] == name]
        if not pool:
            print(f"no saver named {name!r}", file=sys.stderr)
            return 1
    if not pool:
        print("no savers enabled", file=sys.stderr)
        return 1

    saver = random.choice(pool)
    mons = monitors()
    focused = next((m["name"] for m in mons if m.get("focused")), None)
    previous = (hypr("activewindow") or {}).get("address")

    pids, placed, focus_address = [], [], None

    # Two passes on purpose. A new window is mapped onto the *focused*
    # workspace before it can be moved, and that arrival knocks any window
    # already fullscreen there back into the tiling layout -- so every saver
    # has to exist and be on its own monitor before any of them is
    # fullscreened.
    for monitor in mons:
        before = client_addresses()
        try:
            argv, env = command_for(saver, monitor["name"])
        except RuntimeError as e:
            print(e, file=sys.stderr)
            return 1
        if saver["type"] == "html" and stay:
            argv.append("--no-quit-on-input")

        proc = subprocess.Popen(argv, env=env, start_new_session=True,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        pids.append(proc.pid)

        address = wait_for_window(before)
        if address is None:
            continue
        move_to(address, monitor)
        placed.append(address)
        if monitor["name"] == focused:
            focus_address = address

    for address in placed:
        fullscreen(address)

    # Keep the keyboard on the saver so a stray keystroke lands there rather
    # than in whatever was underneath.
    if focus_address:
        dispatch(f'hl.dsp.focus({{ window = "address:{focus_address}" }})')

    write_state({"pids": pids, "saver": saver["name"], "previous": previous})
    if not stay:
        supervise(pids)
    return 0


def supervise(pids: list[int]) -> None:
    """Tear the whole screensaver down as soon as any one window is dismissed.

    Each viewer only sees the input aimed at its own monitor, so moving the
    mouse closes exactly one of them and leaves the others up. Waiting for the
    first exit and then stopping everything makes any monitor's dismissal
    dismiss the lot. (The idle manager's returnAction would eventually do this
    too, but not for a manual start, and not without a visible gap.)
    """
    if os.fork() != 0:
        return                       # parent returns to the caller immediately
    os.setsid()
    if os.fork() != 0:
        os._exit(0)                  # orphan the supervisor so nothing reaps it

    try:
        while all(alive(pid) for pid in pids):
            time.sleep(0.2)
        stop()
    finally:
        os._exit(0)


def wait_for_window(before: set[str]) -> str | None:
    deadline = time.monotonic() + SPAWN_TIMEOUT
    while time.monotonic() < deadline:
        new = client_addresses() - before
        if new:
            return sorted(new)[0]
        time.sleep(0.1)
    return None


# ------------------------------------------------------------------- stop ---
def stop() -> int:
    state = read_state()

    for pid in state.get("pids", []):
        try:
            os.killpg(os.getpgid(pid), signal.SIGTERM)
        except OSError:
            pass

    # Belt and braces: anything still on screen wearing our class, e.g. after a
    # crash lost the state file.
    for client in hypr("clients"):
        if client.get("class") == SAVER_CLASS:
            dispatch(f'hl.dsp.window.close({{ window = "address:{client["address"]}" }})')

    previous = state.get("previous")
    if previous:
        dispatch(f'hl.dsp.focus({{ window = "address:{previous}" }})')

    STATE.unlink(missing_ok=True)
    return 0


# ------------------------------------------------------------------- main ---
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["start", "stop", "toggle", "status", "list"])
    ap.add_argument("--saver", help="run this saver instead of a random one")
    ap.add_argument("--stay", action="store_true",
                    help="do not dismiss on input; for previewing a saver")
    args = ap.parse_args()

    if args.action == "list":
        for saver in load_pool():
            print(f"{saver['name']:<16} {saver.get('label', ''):<18} {saver['type']}")
        return 0

    if args.action == "status":
        state = read_state()
        if running():
            print(f"running: {state.get('saver')} (pids {state.get('pids')})")
        else:
            print("stopped")
        return 0

    if args.action == "start":
        return start(args.saver, args.stay)
    if args.action == "stop":
        return stop()
    return stop() if running() else start(args.saver, args.stay)


if __name__ == "__main__":
    sys.exit(main())
