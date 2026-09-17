#!/usr/bin/env python3
"""Start prompt shown on the Deck's screen before Azahar launches.

Azahar enumerates controllers once, at startup. Sunshine creates its virtual
pad lazily -- on the Deck's first controller input, not when Moonlight connects
-- so launching on connect (or on a screen tap) still starts Azahar before the
pad exists. This window therefore waits for a Sunshine pad created *after* it
opened (a pad from a previous session can linger) and exits by itself as soon
as one appears. Tapping still starts Azahar anyway, without a controller.

Exit 0 to launch Azahar, 1 when closed (abort the session).
"""
import glob
import os
import time

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

GLib.set_prgname("azahar-deck-prompt")  # Wayland app_id / class to place it by

STARTED = time.time()
result = {"code": 1}


def fresh_sunshine_pad():
    for js in glob.glob("/sys/class/input/js*"):
        try:
            name = open(os.path.join(js, "device", "name")).read().strip()
            created = os.stat("/dev/input/" + os.path.basename(js)).st_mtime
        except OSError:
            continue
        # gamepad = xone in sunshine.conf keeps the name stable; its virtual
        # mouse shares the prefix and is not a pad.
        if name.startswith("Sunshine (libvirtualhid)") and created >= STARTED:
            return True
    return False


def finish(code):
    result["code"] = code
    Gtk.main_quit()
    return False


def poll():
    if fresh_sunshine_pad():
        label.set_text("Controller found - starting Azahar")
        GLib.timeout_add(700, finish, 0)  # let the message be seen
        return False
    return True


win = Gtk.Window(title="Azahar Deck prompt")
win.connect("destroy", Gtk.main_quit)

css = Gtk.CssProvider()
css.load_from_data(b"""
window, button { background: #111; color: #eee; border: none; box-shadow: none; }
button { font-size: 40px; font-weight: bold; }
button:hover, button:active { background: #1d3b2a; }
""")
Gtk.StyleContext.add_provider_for_screen(
    win.get_screen(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

label = Gtk.Label(label="Press any button on the controller\n\n"
                        "(or tap to start without one)")
label.set_justify(Gtk.Justification.CENTER)
button = Gtk.Button()
button.add(label)
button.connect("clicked", lambda _: finish(0))
win.add(button)
win.show_all()
GLib.timeout_add(500, poll)
Gtk.main()
raise SystemExit(result["code"])
