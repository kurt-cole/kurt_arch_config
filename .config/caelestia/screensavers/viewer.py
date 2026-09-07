#!/usr/bin/env python3
"""Minimal WebKit window used to display the HTML screensavers.

Firefox would do the job, but it costs ~300 MB per monitor and has no --class
flag (so its windows can only be matched by title). This is a much smaller
WebKit2 window whose Wayland app_id is set from the process name, which gives
hyprland a normal `class` to match on.

It exits on any key press or pointer motion of its own accord, so it still
behaves like a screensaver if it is ever started outside screensaver.py.
"""

import argparse
import os
import sys
import time

# WebKit's DMABUF renderer cannot allocate GBM buffers under this compositor --
# it fails with "Failed to create GBM buffer of size 200x200" and then kills the
# Wayland connection with a protocol error before anything is drawn. The
# fallback renderer still has working WebGL, which is all the savers need.
os.environ.setdefault("WEBKIT_DISABLE_DMABUF_RENDERER", "1")

import gi  # noqa: E402

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import GLib, Gdk, Gtk, WebKit2  # noqa: E402


# The window maps under the pointer, so X/Wayland delivers a motion event
# immediately -- without a grace period and a movement threshold the saver
# closes itself before it has drawn a single frame.
GRACE = 0.7          # seconds of input ignored after the window is mapped
DEADZONE = 12        # pixels the pointer must actually travel to count


class Dismisser:
    def __init__(self) -> None:
        self.mapped = time.monotonic()
        self.origin: tuple[float, float] | None = None

    def on_input(self, _widget, event) -> bool:
        if time.monotonic() - self.mapped < GRACE:
            return True
        if event.type == Gdk.EventType.MOTION_NOTIFY:
            if self.origin is None:
                self.origin = (event.x_root, event.y_root)
                return True
            dx = event.x_root - self.origin[0]
            dy = event.y_root - self.origin[1]
            if dx * dx + dy * dy < DEADZONE * DEADZONE:
                return True
        Gtk.main_quit()
        return True


def on_key(_widget, event) -> bool:
    if Gdk.keyval_name(event.keyval) in ("Escape", "q", "Q"):
        Gtk.main_quit()
        return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--app-id", default="caelestia-screensaver",
                    help="Wayland app_id, i.e. the class hyprland rules match on")
    ap.add_argument("--no-quit-on-input", action="store_true",
                    help="leave dismissal to whoever started us")
    args = ap.parse_args()

    # On GTK3/Wayland the app_id comes from the program name, not from any
    # window property -- this line is what makes the hyprland rule work.
    GLib.set_prgname(args.app_id)

    settings = WebKit2.Settings()
    settings.set_property("enable-webgl", True)
    settings.set_property("hardware-acceleration-policy", WebKit2.HardwareAccelerationPolicy.ALWAYS)

    view = WebKit2.WebView()
    view.set_settings(settings)
    view.set_background_color(Gdk.RGBA(0, 0, 0, 1))
    view.load_uri(args.url)

    win = Gtk.Window()
    win.set_decorated(False)
    win.add(view)
    win.connect("destroy", Gtk.main_quit)

    # Escape and q always close, so a preview started with --no-quit-on-input
    # can still be dismissed without hunting for its pid.
    win.add_events(Gdk.EventMask.KEY_PRESS_MASK)
    win.connect("key-press-event", on_key)

    if not args.no_quit_on_input:
        dismisser = Dismisser()
        win.add_events(Gdk.EventMask.KEY_PRESS_MASK
                       | Gdk.EventMask.BUTTON_PRESS_MASK
                       | Gdk.EventMask.POINTER_MOTION_MASK
                       | Gdk.EventMask.SCROLL_MASK)
        for signal in ("key-press-event", "button-press-event",
                       "motion-notify-event", "scroll-event"):
            win.connect(signal, dismisser.on_input)

    win.fullscreen()
    win.show_all()

    # The page's CSS only hides the cursor over the WebKit surface, and not
    # until first paint; this covers the window from the moment it is mapped.
    gdk_win = win.get_window()
    if gdk_win is not None:
        gdk_win.set_cursor(Gdk.Cursor.new_for_display(gdk_win.get_display(),
                                                      Gdk.CursorType.BLANK_CURSOR))

    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
