#!/usr/bin/env python3
"""A quick-launch TUI for Archipelago games, themed from the caelestia scheme.

Content comes from ~/.config/Archipelago/launcher.toml -- entries with
visible = true, in file order. Everything installed is listed in that file so
new games only need visible flipped.

Keys: j/k or arrows move, g/G jump, / filters, Enter launches, d launches with
the Archipelago client in a terminal (Linux stand-in for Windows'
ArchipelagoLauncherDebug), e opens the config in the editor, q/Esc quits.
"""
import glob
import os
import re
import shutil
import signal
import subprocess
import sys
import termios
import tomllib
import tty
import unicodedata

HOME = os.path.expanduser("~")
CONFIG = os.environ.get("AP_LAUNCHER_CONFIG",
                        os.path.join(HOME, ".config/Archipelago/launcher.toml"))
SCHEME = os.path.join(HOME, ".config/hypr/scheme/current.lua")

FALLBACK = {
    "background": "131317", "onSurface": "e5e1e7", "onSurfaceVariant": "c8c5d1",
    "primary": "c2c1ff", "onPrimary": "2a2a5e", "tertiary": "e9b9d3",
    "surfaceContainer": "201f23", "surfaceContainerHigh": "2a292e",
    "outlineVariant": "47464f",
}

ESC = "\x1b"
RESET = f"{ESC}[0m"
BOLD = f"{ESC}[1m"


def load_scheme():
    colours = dict(FALLBACK)
    try:
        with open(SCHEME) as f:
            for key, value in re.findall(r'(\w+)\s*=\s*"([0-9a-fA-F]{6})"', f.read()):
                colours[key] = value
    except OSError:
        pass
    return colours


class Theme:
    def __init__(self):
        c = load_scheme()
        self.bg = self.rgb(c["background"], fg=False)
        self.text = self.rgb(c["onSurface"])
        self.dim = self.rgb(c["onSurfaceVariant"])
        self.faint = self.rgb(c["outlineVariant"])
        self.accent = self.rgb(c["primary"])
        self.accent2 = self.rgb(c["tertiary"])
        self.sel_bg = self.rgb(c["primary"], fg=False)
        self.sel_fg = self.rgb(c.get("onPrimary", FALLBACK["onPrimary"]))
        self.bar_bg = self.rgb(c["surfaceContainer"], fg=False)
        self.row_bg = self.rgb(c["surfaceContainerHigh"], fg=False)

    @staticmethod
    def rgb(hex6, fg=True):
        r, g, b = (int(hex6[i:i + 2], 16) for i in (0, 2, 4))
        return f"{ESC}[{38 if fg else 48};2;{r};{g};{b}m"


def display_len(s):
    """Printed width, counting wide glyphs (emoji, CJK) as two columns."""
    plain = re.sub(r"\x1b\[[0-9;]*m", "", s)
    return sum(2 if unicodedata.east_asian_width(c) in "WF" or c >= "\U0001f000" else 1
               for c in plain)


def load_config():
    with open(CONFIG, "rb") as f:
        data = tomllib.load(f)
    settings = data.get("settings", {})
    # [[entries]] blocks are the configured games; [disabled] holds the one-line
    # rest, so flipping visible = true down there works without moving anything.
    listed = list(data.get("entries", [])) + list(data.get("disabled", {}).get("entries", []))
    entries = [e for e in listed if e.get("visible")]
    return settings, entries


def archipelago_path(settings):
    """The configured AppImage, falling back to the newest one installed."""
    path = os.path.expanduser(settings.get("archipelago", ""))
    if path and os.path.exists(path):
        return path
    found = sorted(glob.glob(os.path.join(HOME, "Applications/Archipelago*.AppImage")))
    return found[-1] if found else path


def spawn(argv, shell=False):
    """Detach fully: these outlive the terminal this TUI is drawn in."""
    subprocess.Popen(
        argv, shell=shell, start_new_session=True,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        cwd=HOME,
    )


class Launcher:
    def __init__(self, settings, entries):
        self.settings = settings
        self.entries = entries
        self.filter = ""
        self.searching = False
        self.cursor = 0
        self.top = 0
        self.status = ""

    # -- content ---------------------------------------------------------
    def visible(self):
        needle = self.filter.lower()
        return [e for e in self.entries
                if not needle or needle in e.get("name", "").lower()
                or needle in e.get("component", "").lower()]

    def current(self):
        rows = self.visible()
        return rows[self.cursor] if rows else None

    # -- launching -------------------------------------------------------
    def start_proton_client(self, entry, debug=False):
        """Start a Windows AP client inside the game's Proton container.

        Clients that read or patch game memory have to live in the same wine
        session as the game; ap-proton-client.sh waits for the container to come
        up and injects it there. Detached, so it outlives this TUI.
        """
        pc = entry.get("proton_client")
        if not pc:
            return
        script = os.path.join(HOME, ".config/caelestia/scripts/ap-proton-client.sh")
        argv = [script, str(pc["appid"]), pc["client"], "debug" if debug else ""]
        argv.append(pc.get("apworld", ""))
        spawn(argv)

    def launch(self, debug=False):
        entry = self.current()
        if not entry:
            return True
        ap = archipelago_path(self.settings)
        component = entry.get("component", "")
        self.start_proton_client(entry, debug)
        if component:
            if not ap:
                self.status = "no Archipelago AppImage found"
                return True
            if debug:
                term = self.settings.get("terminal") or ["foot"]
                spawn([*term, ap, component])
            else:
                spawn([ap, component])
        for command in entry.get("commands", []):
            spawn(command, shell=True)
        if not component and not entry.get("commands"):
            self.status = f"{entry.get('name')} has no component or commands"
            return True
        return False  # launched -- close the launcher

    def edit(self):
        editor = self.settings.get("editor") or ["foot", "nvim"]
        spawn([*editor, CONFIG])
        return False

    # -- drawing ---------------------------------------------------------
    def draw(self):
        width, height = shutil.get_terminal_size((80, 24))
        rows = self.visible()
        view = max(1, height - 4)
        self.cursor = max(0, min(self.cursor, max(0, len(rows) - 1)))
        self.top = max(min(self.top, self.cursor), self.cursor - view + 1, 0)

        out = [f"{ESC}[H{ESC}[2J", self.t.bg]

        title = " Archipelago "
        if self.filter or self.searching:
            title = f" Archipelago · /{self.filter} "
        count = f"{len(rows)}/{len(self.entries)} "
        pad = " " * max(0, width - len(title) - len(count))
        out.append(f"{self.t.bar_bg}{self.t.accent}{BOLD}{title}{RESET}"
                   f"{self.t.bar_bg}{pad}{self.t.dim}{count}{RESET}{self.t.bg}\r\n")
        out.append(f"{self.t.faint}{'━' * width}{RESET}\r\n")

        if not rows:
            hint = ("nothing matches" if self.filter else
                    "no entries yet -- press e and set visible = true on a game")
            out.append(f"\r\n  {self.t.dim}{hint}{RESET}{ESC}[K\r\n")
            blanks = view - 2
        else:
            for i, entry in enumerate(rows[self.top:self.top + view], self.top):
                left = f" {entry.get('emoji', ' ')}  {entry.get('name', '?')}"
                note = entry.get("component", "")
                gap = width - display_len(left) - display_len(note) - 2
                if note and gap < 2:
                    note, gap = "", width - display_len(left) - 2
                body = f"{left}{' ' * max(1, gap)}{note} "
                pad = " " * max(0, width - display_len(body))
                if i == self.cursor:
                    out.append(f"{self.t.sel_bg}{self.t.sel_fg}{BOLD}{body}{pad}{RESET}{self.t.bg}")
                else:
                    out.append(f"{self.t.text}{left}{RESET}{self.t.bg}{' ' * max(1, gap)}"
                               f"{self.t.faint}{note} {RESET}{self.t.bg}{pad}")
                out.append(f"{ESC}[K\r\n")
            blanks = view - len(rows[self.top:self.top + view])
        for _ in range(max(0, blanks)):
            out.append(f"{ESC}[K\r\n")

        hint = self.status or "enter launch · d debug · e config · / filter · q quit"
        colour = self.t.accent2 if self.status else self.t.dim
        status = f"{self.t.bar_bg}{colour} {hint}"
        out.append(f"{status}{' ' * max(0, width - display_len(status))}{RESET}")

        sys.stdout.write("".join(out))
        sys.stdout.flush()

    # -- input -----------------------------------------------------------
    def key(self, ch):
        self.status = ""
        rows = self.visible()
        _, height = shutil.get_terminal_size((80, 24))
        page = max(1, height - 6)

        if self.searching:
            if ch in ("\r", "\n"):
                self.searching = False
            elif ch == ESC:
                self.searching, self.filter, self.cursor = False, "", 0
            elif ch in ("\x7f", "\b"):
                self.filter, self.cursor = self.filter[:-1], 0
            elif ch.isprintable():
                self.filter, self.cursor = self.filter + ch, 0
            return True

        if ch in ("q", "\x03", ESC):
            return False
        if ch in ("\r", "\n"):
            return self.launch()
        if ch == "d":
            return self.launch(debug=True)
        if ch == "e":
            return self.edit()
        if ch == "/":
            self.searching, self.filter, self.cursor = True, "", 0
        elif ch in ("j", f"{ESC}B"):
            self.cursor = min(max(0, len(rows) - 1), self.cursor + 1)
        elif ch in ("k", f"{ESC}A"):
            self.cursor = max(0, self.cursor - 1)
        elif ch == f"{ESC}6":
            self.cursor = min(max(0, len(rows) - 1), self.cursor + page)
        elif ch == f"{ESC}5":
            self.cursor = max(0, self.cursor - page)
        elif ch == "g":
            self.cursor = 0
        elif ch == "G":
            self.cursor = max(0, len(rows) - 1)
        return True


def read_key():
    ch = sys.stdin.read(1)
    if ch != ESC:
        return ch
    os.set_blocking(sys.stdin.fileno(), False)
    try:
        rest = sys.stdin.read(8) or ""
    finally:
        os.set_blocking(sys.stdin.fileno(), True)
    if not rest:
        return ESC
    return ESC + rest[-1]  # final byte identifies the key (A/B/5/6/...)


def main():
    try:
        settings, entries = load_config()
    except (OSError, ValueError) as err:
        sys.stderr.write(f"{CONFIG}: {err}\n")
        input("press enter to close ")
        return 1

    app = Launcher(settings, entries)
    app.t = Theme()

    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    sys.stdout.write(f"{ESC}[?1049h{ESC}[?25l")  # alt screen, hide cursor
    signal.signal(signal.SIGWINCH, lambda *_: app.draw())
    try:
        tty.setraw(fd)
        app.draw()
        while True:
            try:
                ch = read_key()
            except InterruptedError:  # resize woke up the read
                continue
            if not ch or not app.key(ch):
                break
            app.draw()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        sys.stdout.write(f"{ESC}[?25h{ESC}[?1049l")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
