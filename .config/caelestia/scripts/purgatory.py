#!/usr/bin/env python3
"""Minimize windows to a per-workspace "purgatory", and bring them back.

Wayland has no minimize (xdg-shell's set_minimized is a hint hyprland ignores),
so hiding a window means parking it on a special workspace nothing toggles:
special:purg-<workspace>. The name keeps the link to where it came from, so a
restore always sends the window home.

    purgatory.py hide     hide the focused window   (SUPER + N)
    purgatory.py          the restore TUI           (SUPER + SHIFT + N)

TUI keys: j/k or arrows move, g/G jump, / filters, Enter restores, a toggles
between this workspace's purgatory and every workspace's, x closes the hidden
window, q/Esc quits.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import termios
import tty
import unicodedata

HOME = os.path.expanduser("~")
SCHEME = os.path.join(HOME, ".config/hypr/scheme/current.lua")
PREFIX = "special:purg-"

FALLBACK = {
    "background": "131317", "onSurface": "e5e1e7", "onSurfaceVariant": "c8c5d1",
    "primary": "c2c1ff", "onPrimary": "2a2a5e", "tertiary": "e9b9d3",
    "surfaceContainer": "201f23", "surfaceContainerHigh": "2a292e",
    "outlineVariant": "47464f",
}

ESC = "\x1b"
RESET = f"{ESC}[0m"
BOLD = f"{ESC}[1m"


# -- hyprland ------------------------------------------------------------
def hyprctl(*args):
    out = subprocess.run(["hyprctl", "-j", *args], capture_output=True, text=True)
    return json.loads(out.stdout or "null")


def dispatch(expr):
    subprocess.run(["hyprctl", "dispatch", expr], capture_output=True, text=True)


def current_workspace():
    """The focused monitor's workspace -- its special one if one is pulled up."""
    for monitor in hyprctl("monitors") or []:
        if monitor.get("focused"):
            special = (monitor.get("specialWorkspace") or {}).get("name") or ""
            return special or monitor["activeWorkspace"]["name"]
    return ""


def purgatory_name(workspace):
    """special:purg-<workspace>, with the name flattened to something legal."""
    slug = re.sub(r"[^A-Za-z0-9_-]", "_", workspace.replace("special:", "sp_"))
    return PREFIX + (slug or "unknown")


def home_workspace(purgatory):
    name = purgatory[len(PREFIX):]
    return "special:" + name[3:] if name.startswith("sp_") else name


def hidden_windows():
    out = []
    for client in hyprctl("clients") or []:
        name = client.get("workspace", {}).get("name", "")
        if name.startswith(PREFIX):
            out.append({
                "address": client["address"],
                "title": client.get("title") or client.get("class") or "?",
                "cls": client.get("class") or "",
                "purgatory": name,
                "home": home_workspace(name),
            })
    return out


def hide():
    window = hyprctl("activewindow")
    if not window or not window.get("address"):
        return 1
    workspace = window.get("workspace", {}).get("name") or current_workspace()
    if workspace.startswith(PREFIX):
        return 0  # already hidden
    dispatch(f'hl.dsp.window.move({{ window = "address:{window["address"]}", '
             f'workspace = "{purgatory_name(workspace)}", follow = false }})')
    return 0


def restore(entry):
    dispatch(f'hl.dsp.window.move({{ window = "address:{entry["address"]}", '
             f'workspace = "{entry["home"]}", follow = true }})')
    dispatch(f'hl.dsp.focus({{ window = "address:{entry["address"]}" }})')


def close_window(entry):
    dispatch(f'hl.dsp.window.close({{ window = "address:{entry["address"]}" }})')


# -- theme ---------------------------------------------------------------
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

    @staticmethod
    def rgb(hex6, fg=True):
        r, g, b = (int(hex6[i:i + 2], 16) for i in (0, 2, 4))
        return f"{ESC}[{38 if fg else 48};2;{r};{g};{b}m"


def _char_width(c):
    o = ord(c)
    # Private use: nerd-font glyphs. Terminals give these one cell, but their
    # east-asian width is "ambiguous" and the plane-15 ones sort above U+1F000,
    # so both of the tests below would call them wide.
    if 0xE000 <= o <= 0xF8FF or 0xF0000 <= o <= 0xFFFFD or 0x100000 <= o <= 0x10FFFD:
        return 1
    if unicodedata.east_asian_width(c) in "WF" or o >= 0x1F000:
        return 2
    return 1


def display_len(s):
    """Printed width in terminal columns.

    Emoji are grapheme clusters, not characters: a ZWJ sequence (\U0001f9d1 ZWJ
    \U0001f33e) draws in two columns, not four, and a variation selector turns a
    one-column glyph into a two-column one without occupying a cell itself.
    Counting per character overshoots those rows and shifts their right-hand
    label left.
    """
    plain = re.sub(r"\x1b\[[0-9;]*m", "", s)
    total, prev, joined = 0, 0, False
    for c in plain:
        o = ord(c)
        if o == 0x200D:                          # ZWJ: the next glyph joins this one
            joined = True
            continue
        if o == 0xFE0F:                          # VS16: emoji presentation, so wide
            if prev == 1:
                total, prev = total + 1, 2
            continue
        if o == 0xFE0E:                          # VS15: text presentation, so narrow
            if prev == 2:
                total, prev = total - 1, 1
            continue
        if (0x1F3FB <= o <= 0x1F3FF                      # skin tone modifiers
                or unicodedata.combining(c)
                or unicodedata.category(c) in ("Mn", "Me", "Cf")):
            continue
        if joined:                               # part of the previous cluster
            joined = False
            continue
        prev = _char_width(c)
        total += prev
    return total


def clip(s, width):
    while display_len(s) > width and s:
        s = s[:-1]
    return s


# -- tui -----------------------------------------------------------------
class Purgatory:
    def __init__(self, workspace):
        self.workspace = workspace
        self.mine = purgatory_name(workspace)
        self.all = False
        self.filter = ""
        self.searching = False
        self.cursor = 0
        self.top = 0
        self.status = ""
        self.reload()

    def reload(self):
        self.windows = hidden_windows()

    def visible(self):
        needle = self.filter.lower()
        rows = [w for w in self.windows if self.all or w["purgatory"] == self.mine]
        return [w for w in rows
                if not needle or needle in w["title"].lower() or needle in w["cls"].lower()]

    def current(self):
        rows = self.visible()
        return rows[self.cursor] if rows else None

    # -- drawing ---------------------------------------------------------
    def draw(self):
        width, height = shutil.get_terminal_size((80, 24))
        rows = self.visible()
        view = max(1, height - 4)
        self.cursor = max(0, min(self.cursor, max(0, len(rows) - 1)))
        self.top = max(min(self.top, self.cursor), self.cursor - view + 1, 0)

        out = [f"{ESC}[H{ESC}[2J", self.t.bg]

        scope = "all workspaces" if self.all else self.workspace
        title = f" Hidden · {scope} "
        if self.filter or self.searching:
            title = f" Hidden · {scope} · /{self.filter} "
        count = f"{len(rows)} "
        pad = " " * max(0, width - len(title) - len(count))
        out.append(f"{self.t.bar_bg}{self.t.accent}{BOLD}{title}{RESET}"
                   f"{self.t.bar_bg}{pad}{self.t.dim}{count}{RESET}{self.t.bg}\r\n")
        out.append(f"{self.t.faint}{'━' * width}{RESET}\r\n")

        if not rows:
            hint = ("nothing matches" if self.filter else
                    "nothing hidden here -- SUPER + N puts a window in purgatory")
            out.append(f"\r\n  {self.t.dim}{hint}{RESET}{ESC}[K\r\n")
            blanks = view - 2
        else:
            for i, entry in enumerate(rows[self.top:self.top + view], self.top):
                note = entry["home"] if self.all else entry["cls"]
                left = clip(f"  {entry['title']}", max(4, width - len(note) - 4))
                gap = width - display_len(left) - display_len(note) - 2
                if gap < 2:
                    note, gap = "", width - display_len(left) - 2
                body = f"{left}{' ' * max(1, gap)}{note} "
                fill = " " * max(0, width - display_len(body))
                if i == self.cursor:
                    out.append(f"{self.t.sel_bg}{self.t.sel_fg}{BOLD}{body}{fill}{RESET}{self.t.bg}")
                else:
                    out.append(f"{self.t.text}{left}{RESET}{self.t.bg}{' ' * max(1, gap)}"
                               f"{self.t.faint}{note} {RESET}{self.t.bg}{fill}")
                out.append(f"{ESC}[K\r\n")
            blanks = view - len(rows[self.top:self.top + view])
        for _ in range(max(0, blanks)):
            out.append(f"{ESC}[K\r\n")

        hint = self.status or "enter restore · a all workspaces · x close · / filter · q quit"
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
            entry = self.current()
            if entry:
                restore(entry)
                return False  # restored -- close the picker
            return True
        if ch == "x":
            entry = self.current()
            if entry:
                close_window(entry)
                self.reload()
                self.status = f"closed {entry['cls'] or entry['title']}"
            return True
        if ch == "a":
            self.all, self.cursor = not self.all, 0
            self.reload()
        elif ch == "/":
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


def tui(workspace):
    app = Purgatory(workspace)
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


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "hide":
        return hide()
    # Safe to read here: the picker floats on the workspace it lists, and
    # mapping a floating window doesn't change which workspace is active.
    workspace = current_workspace()
    # A purgatory can end up pulled up despite having no toggle, if something
    # activates a window hidden on it (hypr-user.lua sends those home, but a
    # stale one may still be on screen). Scoping to purg-sp_purg-<ws> would then
    # list nothing at all -- list the purgatory we are standing in instead.
    if workspace.startswith(PREFIX):
        workspace = home_workspace(workspace)
    return tui(workspace)


if __name__ == "__main__":
    sys.exit(main())
