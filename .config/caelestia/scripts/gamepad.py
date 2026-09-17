"""Minimal gamepad reader for the caelestia TUIs, over evdev.

Picks up every connected pad (anything with BTN_SOUTH -- which drops the
DualSense's separate motion-sensor and touchpad nodes and every keyboard) and
rescans /dev/input for hotplugged ones. Devices are never grabbed, so games and
Steam still see every press.

Pads need no special group: systemd's 70-uaccess.rules gives the logged-in user
an ACL on every ID_INPUT_JOYSTICK node.

Events come out as names: "up", "down", "left", "right", "south" (DualSense X /
Xbox A), "mode" (PS / Xbox guide button). Held D-pad directions repeat.
"""
import time

import evdev
from evdev import ecodes as e

RESCAN = 2.0          # seconds between looks for new pads
REPEAT_DELAY = 0.35   # held D-pad: first repeat
REPEAT_RATE = 0.09    # held D-pad: later repeats

BUTTONS = {
    e.BTN_SOUTH: "south",
    e.BTN_MODE: "mode",
    e.BTN_DPAD_UP: "up",      # hid-steam and some other drivers use buttons
    e.BTN_DPAD_DOWN: "down",  # for the D-pad instead of a hat
    e.BTN_DPAD_LEFT: "left",
    e.BTN_DPAD_RIGHT: "right",
}
HATS = {e.ABS_HAT0Y: ("up", "down"), e.ABS_HAT0X: ("left", "right")}


class Gamepads:
    def __init__(self):
        self.devices = {}      # path -> InputDevice
        self.last_scan = 0.0
        self.held = {}         # (path, hat) -> (direction, next repeat time)
        self.rescan()

    def rescan(self):
        self.last_scan = time.monotonic()
        for path in evdev.list_devices():
            if path in self.devices:
                continue
            try:
                dev = evdev.InputDevice(path)
            except OSError:
                continue
            keys = dev.capabilities().get(e.EV_KEY, [])
            if e.BTN_SOUTH in keys:
                self.devices[path] = dev
            else:
                dev.close()

    def fds(self):
        """File descriptors to select() on. Call each loop -- pads come and go."""
        if time.monotonic() - self.last_scan > RESCAN:
            self.rescan()
        return [dev.fd for dev in self.devices.values()]

    def timeout(self, default):
        """How long select() may block without missing a D-pad repeat."""
        if not self.held:
            return default
        wait = min(t for _, t in self.held.values()) - time.monotonic()
        return max(0.0, min(default, wait))

    def read(self, ready):
        """Events from the fds select() returned, plus any due repeats."""
        out = []
        for path, dev in list(self.devices.items()):
            if dev.fd not in ready:
                continue
            try:
                events = list(dev.read())
            except OSError:  # unplugged
                self.drop(path)
                continue
            for ev in events:
                name = self.translate(path, ev)
                if name:
                    out.append(name)

        now = time.monotonic()
        for held, (direction, due) in list(self.held.items()):
            if now >= due:
                out.append(direction)
                self.held[held] = (direction, now + REPEAT_RATE)
        return out

    def translate(self, path, ev):
        if ev.type == e.EV_ABS and ev.code in HATS:
            held = (path, ev.code)
            if ev.value == 0:
                self.held.pop(held, None)
                return None
            direction = HATS[ev.code][ev.value > 0]
            self.held[held] = (direction, time.monotonic() + REPEAT_DELAY)
            return direction
        if ev.type == e.EV_KEY and ev.code in BUTTONS:
            name = BUTTONS[ev.code]
            if name in ("up", "down", "left", "right"):
                held = (path, ev.code)
                if ev.value == 0:
                    self.held.pop(held, None)
                    return None
                if ev.value == 1:
                    self.held[held] = (name, time.monotonic() + REPEAT_DELAY)
                    return name
                return None  # kernel autorepeat (2) -- we do our own
            return name if ev.value == 1 else None
        return None

    def drop(self, path):
        dev = self.devices.pop(path, None)
        for held in [h for h in self.held if h[0] == path]:
            del self.held[held]
        if dev:
            try:
                dev.close()
            except OSError:
                pass
