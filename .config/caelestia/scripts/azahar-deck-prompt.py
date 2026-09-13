#!/usr/bin/env python3
"""Tap-to-start prompt shown on the Deck's screen before Azahar launches.

azahar-deck.sh puts this fullscreen on the headless output that Sunshine
streams. Azahar only enumerates controllers at startup, and Sunshine's virtual
pad only exists once Moonlight has connected -- and it has presented under
different names and types from one boot to the next -- so rather than guess
when the pad is ready, the user taps this once connected.

Exit 0 when tapped (launch Azahar), 1 when closed (abort the session).
"""
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

GLib.set_prgname("azahar-deck-prompt")  # Wayland app_id / class to place it by

result = {"code": 1}

win = Gtk.Window(title="Azahar Deck prompt")
win.connect("destroy", Gtk.main_quit)

css = Gtk.CssProvider()
css.load_from_data(b"""
window, button { background: #111; color: #eee; border: none; box-shadow: none; }
button { font-size: 44px; font-weight: bold; }
button:hover, button:active { background: #1d3b2a; }
""")
Gtk.StyleContext.add_provider_for_screen(
    win.get_screen(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

button = Gtk.Button(label="Connected?\n\nTap to start Azahar")


def start(_):
    result["code"] = 0
    Gtk.main_quit()


button.connect("clicked", start)
win.add(button)
win.show_all()
Gtk.main()
raise SystemExit(result["code"])
