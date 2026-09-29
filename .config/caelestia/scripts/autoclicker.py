#!/usr/bin/env python3
"""Minimal Wayland autoclicker.

    autoclicker.py          open the window (set the interval, start/stop)
    autoclicker.py toggle   toggle clicking in the running window; opens the
                            window if none is running (bound to F8)

Clicks go through a virtual uinput mouse, so the compositor treats them as a
real mouse and they land on whatever is under the cursor -- any window.
(XTest/pynput under XWayland only reaches X11 windows, which is why earlier
attempts only clicked inside their own tk window.)
"""

import os
import socket
import subprocess
import sys
import threading
import time
import tkinter as tk

from evdev import UInput, ecodes as e

SOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "autoclicker.sock")
STATE = os.path.expanduser("~/.config/caelestia/autoclicker-interval")


def send_toggle():
    try:
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(1)
            s.connect(SOCK)
            s.sendall(b"toggle")
        return True
    except OSError:
        return False


class Clicker:
    def __init__(self):
        # REL_X/REL_Y make libinput treat this as a pointer device.
        self.ui = UInput({e.EV_KEY: [e.BTN_LEFT], e.EV_REL: [e.REL_X, e.REL_Y]},
                         name="autoclicker-virtual-mouse")
        self.running = False
        self.interval = 0.1
        self.clicks = 0

    def loop(self):
        while self.running:
            self.ui.write(e.EV_KEY, e.BTN_LEFT, 1)
            self.ui.syn()
            time.sleep(0.005)
            self.ui.write(e.EV_KEY, e.BTN_LEFT, 0)
            self.ui.syn()
            self.clicks += 1
            time.sleep(max(0.0, self.interval - 0.005))

    def start(self):
        if not self.running:
            self.running = True
            threading.Thread(target=self.loop, daemon=True).start()

    def stop(self):
        self.running = False


class App(tk.Tk):
    BG, FG, ACCENT, GO = "#1a1a2e", "#eaeaea", "#e94560", "#2d7a2d"

    def __init__(self):
        super().__init__(className="autoclicker")
        self.title("Autoclicker")
        self.configure(bg=self.BG, padx=16, pady=12)
        self.resizable(False, False)
        self.clicker = Clicker()

        try:
            ms = open(STATE).read().strip()
        except OSError:
            ms = "100"
        self.ms = tk.StringVar(value=ms)

        row = tk.Frame(self, bg=self.BG)
        row.pack(fill="x")
        tk.Label(row, text="Interval (ms)", bg=self.BG, fg=self.FG).pack(side="left")
        tk.Spinbox(row, from_=1, to=600000, textvariable=self.ms, width=8,
                   bg="#0f3460", fg=self.FG, insertbackground=self.FG,
                   relief="flat", buttonbackground="#0f3460").pack(side="right")

        self.btn = tk.Button(self, command=self.toggle, relief="flat", fg="#fff",
                             font=("sans", 12, "bold"), pady=6)
        self.btn.pack(fill="x", pady=(10, 4))
        self.status = tk.Label(self, bg=self.BG, fg="#8892a4")
        self.status.pack()
        self.refresh()

        threading.Thread(target=self.serve, daemon=True).start()
        self.protocol("WM_DELETE_WINDOW", self.quit_app)
        self.after(200, self.tick)

    def interval_ms(self):
        try:
            return max(1, int(float(self.ms.get())))
        except ValueError:
            return 100

    def toggle(self):
        if self.clicker.running:
            self.clicker.stop()
        else:
            ms = self.interval_ms()
            self.ms.set(str(ms))
            try:
                with open(STATE, "w") as f:
                    f.write(str(ms))
            except OSError:
                pass
            self.clicker.interval = ms / 1000
            self.clicker.clicks = 0
            self.clicker.start()
        self.refresh()

    def refresh(self):
        on = self.clicker.running
        self.btn.config(text="■ STOP  (F8)" if on else "▶ START  (F8)",
                        bg=self.GO if on else self.ACCENT,
                        activebackground=self.GO if on else self.ACCENT)
        self.status.config(text=f"{'clicking' if on else 'idle'} · "
                                f"{self.clicker.clicks} clicks")

    def tick(self):
        self.refresh()
        self.after(200, self.tick)

    def serve(self):
        try:
            os.unlink(SOCK)
        except OSError:
            pass
        srv = socket.socket(socket.AF_UNIX)
        srv.bind(SOCK)
        srv.listen(4)
        while True:
            conn, _ = srv.accept()
            with conn:
                if conn.recv(16).startswith(b"toggle"):
                    self.after(0, self.toggle)

    def quit_app(self):
        self.clicker.stop()
        try:
            os.unlink(SOCK)
        except OSError:
            pass
        self.clicker.ui.close()
        self.destroy()


if __name__ == "__main__":
    if sys.argv[1:2] == ["toggle"]:
        if not send_toggle():
            subprocess.Popen([sys.executable, os.path.abspath(__file__)],
                             start_new_session=True)
        sys.exit(0)
    App().mainloop()
