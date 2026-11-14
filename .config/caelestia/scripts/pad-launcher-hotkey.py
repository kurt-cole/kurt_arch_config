#!/usr/bin/env python3
"""Global gamepad hotkey: the PS / Xbox guide button toggles the Archipelago
launcher, exactly like SUPER + ;.

Hyprland can't bind gamepad buttons, so this runs as a user service
(pad-launcher-hotkey.service) reading every pad through gamepad.py. Nothing is
grabbed, so Steam still sees the button too.
"""
import os
import select
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from gamepad import Gamepads  # noqa: E402

SCRIPTS = os.path.dirname(os.path.realpath(__file__))
TOGGLE = [
    f"{SCRIPTS}/tui-toggle.sh", "ap-launcher,ap-config",
    "foot", "-a", "ap-launcher", "-T", "Archipelago", f"{SCRIPTS}/ap-launcher.py",
]
DEBOUNCE = 0.5  # a pad seen twice (e.g. bluetooth + usb) must not toggle twice
# Pads whose guide button must NOT toggle the launcher. The 8BitDo's home
# button is also its power button, so every power-on popped the launcher.
# (The launcher's own gamepad navigation still uses these pads.)
IGNORE = ("8bitdo",)


class HotkeyPads(Gamepads):
    def rescan(self):
        super().rescan()
        for path, dev in list(self.devices.items()):
            if any(word in dev.name.lower() for word in IGNORE):
                self.drop(path)  # reopened + dropped again each rescan; cheap


def main():
    pads = HotkeyPads()
    last = 0.0
    while True:
        fds = pads.fds()
        if not fds:
            time.sleep(2)
            continue
        ready, _, _ = select.select(fds, [], [], 2.0)
        if "mode" in pads.read(ready) and time.monotonic() - last > DEBOUNCE:
            last = time.monotonic()
            subprocess.Popen(TOGGLE, start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
