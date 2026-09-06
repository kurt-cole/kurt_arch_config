#!/usr/bin/env python3
"""A keybind cheatsheet TUI, themed from the live caelestia colour scheme.

Content comes from ~/.config/caelestia/keybinds.json -- keep that file in sync
when keybinds change; this script only renders it.

Keys: j/k or arrows scroll, PgUp/PgDn, g/G jump, / filters, Esc clears the
filter, q quits.
"""
import json
import os
import re
import shutil
import select
import signal
import sys
import termios
import tty

HOME = os.path.expanduser("~")
DATA = os.path.join(HOME, ".config/caelestia/keybinds.json")
SCHEME = os.path.join(HOME, ".config/hypr/scheme/current.lua")

# Fallbacks if the scheme file isn't readable (matches caelestia's dark default).
FALLBACK = {
    "background": "131317", "onSurface": "e5e1e7", "onSurfaceVariant": "c8c5d1",
    "primary": "c2c1ff", "secondary": "c5c4dd", "tertiary": "e9b9d3",
    "surfaceContainer": "201f23", "surfaceContainerHigh": "2a292e",
    "outlineVariant": "47464f",
}

ESC = "\x1b"


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
        self.chip_bg = self.rgb(c["surfaceContainerHigh"], fg=False)
        self.chip_fg = self.rgb(c["primary"])
        self.bar_bg = self.rgb(c["surfaceContainer"], fg=False)

    @staticmethod
    def rgb(hex6, fg=True):
        r, g, b = (int(hex6[i:i + 2], 16) for i in (0, 2, 4))
        return f"{ESC}[{38 if fg else 48};2;{r};{g};{b}m"


RESET = f"{ESC}[0m"
BOLD = f"{ESC}[1m"


def display_len(s):
    return len(re.sub(r"\x1b\[[0-9;]*m", "", s))


def wrap(text, width):
    if width < 4:
        return [text]
    lines, current = [], ""
    for word in text.split():
        candidate = f"{current} {word}".strip()
        if len(candidate) > width and current:
            lines.append(current)
            current = word
        else:
            current = candidate
    lines.append(current)
    return lines or [""]


class Cheatsheet:
    def __init__(self, sections):
        self.sections = sections
        self.filter = ""
        self.searching = False
        self.top = 0

    # -- content ---------------------------------------------------------
    def matches(self):
        needle = self.filter.lower()
        out = []
        for section in self.sections:
            binds = [
                b for b in section["binds"]
                if not needle or needle in b[0].lower() or needle in b[1].lower()
                or needle in section["title"].lower()
            ]
            if binds:
                out.append({"title": section["title"], "binds": binds})
        return out

    def render_body(self, width):
        """Build the scrollable body as a list of ready-to-print lines."""
        sections = self.matches()
        keywidth = max((len(b[0]) for s in sections for b in s["binds"]), default=0)
        keywidth = min(keywidth, max(10, width - 22))
        stacked = width - keywidth - 5 < 14  # too narrow for a description column

        lines = []
        for i, section in enumerate(sections):
            if i:
                lines.append("")
            rule = "─" * max(0, width - len(section["title"]) - 3)
            lines.append(f"{T.accent2}{BOLD}{section['title']}{RESET} {T.faint}{rule}{RESET}")
            for key, desc in section["binds"]:
                chip = f"{T.chip_bg}{T.chip_fg} {key} {RESET}"
                pad = " " * max(0, keywidth - len(key))
                if stacked:
                    lines.append(f" {chip}")
                    for line in wrap(desc, width - 4):
                        lines.append(f"   {T.dim}{line}{RESET}")
                else:
                    body = wrap(desc, width - keywidth - 5)
                    lines.append(f" {chip}{pad}  {T.text}{body[0]}{RESET}")
                    for line in body[1:]:
                        lines.append(f" {' ' * (keywidth + 4)}{T.dim}{line}{RESET}")
        if not lines:
            lines = [f" {T.dim}no keybinds match {T.accent}{self.filter}{RESET}"]
        return lines

    # -- drawing ---------------------------------------------------------
    def draw(self):
        width, height = shutil.get_terminal_size((80, 24))
        body = self.render_body(width)
        view = max(1, height - 3)
        self.top = max(0, min(self.top, max(0, len(body) - view)))

        out = [f"{ESC}[H{ESC}[2J", T.bg]

        title = " Keybinds "
        if self.filter or self.searching:
            title = f" Keybinds · /{self.filter} "
        out.append(f"{T.bar_bg}{T.accent}{BOLD}{title}{RESET}{T.bg}")
        out.append(f"{' ' * max(0, width - len(title))}\r\n")
        out.append(f"{T.faint}{'━' * width}{RESET}\r\n")

        for line in body[self.top:self.top + view]:
            # Erase first, then print: a line that fills the whole width leaves
            # the cursor in the pending-wrap state on the last column, and an
            # EL there eats the character that was just written.
            out.append(f"{ESC}[K{line}\r\n")
        for _ in range(view - len(body[self.top:self.top + view])):
            out.append(f"{ESC}[K\r\n")

        if len(body) > view:
            pos = f"{int(100 * self.top / max(1, len(body) - view))}%"
        else:
            pos = "all"
        hint = "  j/k scroll  ·  / search  ·  q quit"
        status = f"{T.bar_bg}{T.dim} {pos}{hint}"
        out.append(f"{status}{' ' * max(0, width - display_len(status))}{RESET}")

        sys.stdout.write("".join(out))
        sys.stdout.flush()

    # -- input -----------------------------------------------------------
    def key(self, ch):
        _, height = shutil.get_terminal_size((80, 24))
        page = max(1, height - 5)

        if self.searching:
            if ch in ("\r", "\n"):
                self.searching = False
            elif ch == ESC:
                self.searching, self.filter, self.top = False, "", 0
            elif ch in ("\x7f", "\b"):
                self.filter, self.top = self.filter[:-1], 0
            elif ch.isprintable():
                self.filter, self.top = self.filter + ch, 0
            return True

        if ch in ("q", "\x03"):
            return False
        if ch == "/":
            self.searching, self.filter = True, ""
        elif ch == ESC:
            self.filter, self.top = "", 0
        elif ch in ("j", "\x1bB"):
            self.top += 1
        elif ch in ("k", "\x1bA"):
            self.top = max(0, self.top - 1)
        elif ch in ("d", "\x1b6"):
            self.top += page
        elif ch in ("u", "\x1b5"):
            self.top = max(0, self.top - page)
        elif ch == "g":
            self.top = 0
        elif ch == "G":
            self.top = 10 ** 6
        return True


def read_key():
    ch = sys.stdin.read(1)
    if ch != ESC:
        return ch
    # Escape sequence, or a bare Esc if nothing follows.
    os.set_blocking(sys.stdin.fileno(), False)
    try:
        rest = sys.stdin.read(8) or ""
    finally:
        os.set_blocking(sys.stdin.fileno(), True)
    if not rest:
        return ESC
    return ESC + rest[-1]  # final byte identifies the key (A/B/5/6/...)


def load_sections():
    with open(DATA) as f:
        return json.load(f)["sections"]


def main():
    global T
    T = Theme()
    app = Cheatsheet(load_sections())
    stamp = os.stat(DATA).st_mtime

    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    sys.stdout.write(f"{ESC}[?1049h{ESC}[?25l")  # alt screen, hide cursor
    signal.signal(signal.SIGWINCH, lambda *_: app.draw())
    try:
        tty.setraw(fd)
        app.draw()
        while True:
            # Poll rather than block, so an edit to keybinds.json shows up in an
            # already-running instance -- SUPER + ` only toggles the workspace,
            # it never restarts this process, so a startup-only read would go
            # stale the moment a keybind is added.
            try:
                ready, _, _ = select.select([fd], [], [], 1.0)
            except InterruptedError:  # resize woke up the select
                continue
            if not ready:
                try:
                    latest = os.stat(DATA).st_mtime
                except OSError:
                    continue
                if latest != stamp:
                    stamp = latest
                    try:
                        app.sections = load_sections()
                    except (OSError, ValueError, KeyError):
                        continue  # mid-write or malformed; retry next tick
                    app.top = 0
                    app.draw()
                continue
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


if __name__ == "__main__":
    main()
