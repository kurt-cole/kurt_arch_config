#!/usr/bin/env python3
"""A quick-launch TUI for Archipelago games, themed from the caelestia scheme.

Content comes from ~/.config/Archipelago/launcher.toml -- entries with
visible = true, listed alphabetically (both sections are, always). Everything
installed is listed in that file so new games only need visible flipped.

Keys: j/k or arrows move, g/G jump, / filters, Enter (or F) launches, d launches
in debug mode -- every step (AP client, proton-client injector, each command) gets
its own terminal showing the command, its output and its exit status, held open
afterwards -- c pins the entry and x unpins it, e opens the config in the editor,
q/Esc quits.

Pins are shortcuts repeated in a section at the top of the list, above a
dividing line; the entry stays in the main list too. They live in
launcher-pins.json beside the config, so the TUI never has to rewrite the
hand-maintained launcher.toml (which would cost its comments and layout).

Gamepads (via gamepad.py, if python-evdev is installed): D-pad up/down moves,
left/right jumps to the previous/next starting letter (h/l on the keyboard),
DualSense X / Xbox A launches. Presses only count while this window is focused.
"""
import glob
import json
import os
import re
import select
import shlex
import shutil
import signal
import subprocess
import sys
import termios
import tomllib
import tty
import unicodedata

try:
    sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
    from gamepad import Gamepads
except ImportError:  # no python-evdev: keyboard only
    Gamepads = None

HOME = os.path.expanduser("~")
CONFIG = os.environ.get("AP_LAUNCHER_CONFIG",
                        os.path.join(HOME, ".config/Archipelago/launcher.toml"))
PINS = os.path.join(os.path.dirname(CONFIG), "launcher-pins.json")
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


def load_config():
    with open(CONFIG, "rb") as f:
        data = tomllib.load(f)
    settings = data.get("settings", {})
    # [[entries]] blocks are the configured games; [disabled] holds the one-line
    # rest, so flipping visible = true down there works without moving anything.
    listed = list(data.get("entries", [])) + list(data.get("disabled", {}).get("entries", []))
    entries = [e for e in listed if e.get("visible")]
    return settings, entries


def entry_key(entry):
    """Stable identity for the pins file: the display name."""
    return entry.get("name", "")


def load_pins():
    try:
        with open(PINS) as f:
            data = json.load(f)
        return [k for k in data.get("pinned", []) if isinstance(k, str)]
    except (OSError, ValueError):
        return []


def save_pins(pinned):
    try:
        os.makedirs(os.path.dirname(PINS), exist_ok=True)
        with open(PINS, "w") as f:
            json.dump({"pinned": pinned}, f, indent=2)
            f.write("\n")
        return ""
    except OSError as err:
        return f"could not save pins: {err}"


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


def sort_key(entry):
    """Alphabetical by display name, ignoring case and any leading punctuation."""
    name = entry.get("name", "")
    return (re.sub(r"^[^0-9a-z]+", "", name.casefold()), name.casefold())


def label_of(entry):
    """Right-hand column text: explicit `label`, else the component name."""
    return entry.get("label") or entry.get("component", "")


class Launcher:
    def __init__(self, settings, entries):
        self.settings = settings
        self.entries = entries
        self.filter = ""
        self.searching = False
        self.cursor = 0
        self.top = 0
        self.status = ""
        self.pins = load_pins()

    # -- content ---------------------------------------------------------
    def visible(self):
        needle = self.filter.lower()
        return sorted((e for e in self.entries
                       if not needle or needle in e.get("name", "").lower()
                       or needle in label_of(e).lower()), key=sort_key)

    def rows(self):
        """Display rows: the pinned shortcuts, a separator, then every entry.

        A pinned entry appears twice on purpose -- the pin is a shortcut, not a
        move. Both sections are alphabetical, so a pin never changes where an
        entry sits; the pins file's order is irrelevant to the display.
        Separator rows carry no entry and the cursor is never left on one.
        """
        matched = self.visible()
        by_key = {entry_key(e): e for e in matched}
        pinned = sorted((by_key[k] for k in self.pins if k in by_key), key=sort_key)
        rows = [("pin", e) for e in pinned]
        if pinned:
            rows.append(("sep", None))
        return rows + [("entry", e) for e in matched]

    def current(self):
        rows = self.rows()
        return rows[self.cursor][1] if 0 <= self.cursor < len(rows) else None

    def clamp(self, rows):
        """Keep the cursor in range and off the separator."""
        self.cursor = max(0, min(self.cursor, max(0, len(rows) - 1)))
        if rows and rows[self.cursor][0] == "sep":
            self.cursor = self.cursor + 1 if self.cursor + 1 < len(rows) else self.cursor - 1

    # -- pinning ---------------------------------------------------------
    def pin(self, pinned=True):
        entry = self.current()
        if not entry:
            return True
        was = self.rows()[self.cursor][0]
        key = entry_key(entry)
        if not key:
            self.status = "this entry has no name to pin"
            return True
        if pinned and key not in self.pins:
            self.pins.append(key)
        elif not pinned and key in self.pins:
            self.pins.remove(key)
        else:
            self.status = f"{key} is {'already pinned' if pinned else 'not pinned'}"
            return True
        # Keep the cursor on the row it was on: pinning from the main list
        # shouldn't yank the cursor up into the pin section, and unpinning a
        # shortcut leaves it on that entry down in the list.
        rows = self.rows()
        for want in ((was, "entry") if was == "pin" else (was,)):
            match = next((i for i, (kind, e) in enumerate(rows)
                          if e is entry and kind == want), None)
            if match is not None:
                self.cursor = match
                break
        self.status = save_pins(self.pins) or f"{'pinned' if pinned else 'unpinned'} {key}"
        return True

    # -- launching -------------------------------------------------------
    def proton_client_argv(self, entry, debug=False):
        """The ap-proton-client.sh call for an entry, or None.

        Clients that read or patch game memory have to live in the same wine
        session as the game; that script waits for the container to come up and
        injects the client there.
        """
        pc = entry.get("proton_client")
        if not pc:
            return None
        script = os.path.join(HOME, ".config/caelestia/scripts/ap-proton-client.sh")
        overrides = pc.get("dll_overrides", [])
        return [script, str(pc["appid"]), pc["client"], "debug" if debug else "",
                pc.get("apworld", ""), pc.get("mode", "attach"),
                ",".join(overrides) if isinstance(overrides, list) else str(overrides)]

    def debug_term(self, command, title=""):
        """Run one command in its own terminal, echoing it and holding the window
        open after it exits.

        Debug mode has to show *everything* a launch does, so each step gets a
        window: the AP client, the proton-client injector, and every entry
        command. Without the hold, a command that fails immediately closes its
        terminal before anything can be read.
        """
        term = list(self.settings.get("terminal") or ["foot"])
        if title and "-T" in term:                 # retitle per window (foot's -T)
            i = len(term) - 1 - term[::-1].index("-T")
            if i + 1 < len(term):
                term[i + 1] = title
        body = "\n".join([
            'printf "\\033[1m$ %s\\033[0m\\n\\n" ' + shlex.quote(command),
            command,
            "status=$?",
            'printf "\\n\\033[2m[exited %s] press enter to close\\033[0m\\n" "$status"',
            "read -r _",
        ])
        spawn([*term, "bash", "-c", body])

    def launch(self, debug=False):
        entry = self.current()
        if not entry:
            return True
        ap = archipelago_path(self.settings)
        component = entry.get("component", "")
        name = entry.get("name", "Archipelago")
        pc_argv = self.proton_client_argv(entry, debug)
        # `commands = [""]` is a placeholder, not a command -- skip blanks so it
        # hits the "nothing to launch" status instead of silently doing nothing.
        commands = [c for c in entry.get("commands", []) if c.strip()]

        if component and not ap:
            self.status = "no Archipelago AppImage found"
            return True
        if not component and not commands and not entry.get("proton_client"):
            self.status = f"{name} has nothing to launch"
            return True

        if debug:
            # ap-proton-client.sh and proton-run.sh tee their log to stdout when
            # it is a terminal, so a debug window shows their progress live
            # instead of an empty screen with everything in ~/.cache/ap-launcher.
            if pc_argv:
                self.debug_term(shlex.join(pc_argv), f"{name} — proton client")
            if component:
                self.debug_term(shlex.join([ap, component]), f"{name} — {component}")
            for command in commands:
                self.debug_term(command, f"{name} — command")
            return False

        if pc_argv:
            spawn(pc_argv)
        if component:
            spawn([ap, component])
        for command in commands:
            spawn(command, shell=True)
        return False  # launched -- close the launcher

    def edit(self):
        editor = self.settings.get("editor") or ["foot", "nvim"]
        spawn([*editor, CONFIG])
        return False

    # -- drawing ---------------------------------------------------------
    def draw(self):
        width, height = shutil.get_terminal_size((80, 24))
        rows = self.rows()
        view = max(1, height - 4)
        self.clamp(rows)
        self.top = max(min(self.top, self.cursor), self.cursor - view + 1, 0)

        out = [f"{ESC}[H{ESC}[2J", self.t.bg]

        title = " Archipelago "
        if self.filter or self.searching:
            title = f" Archipelago · /{self.filter} "
        count = f"{len(self.visible())}/{len(self.entries)} "
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
            for i, (kind, entry) in enumerate(rows[self.top:self.top + view], self.top):
                if kind == "sep":
                    out.append(f"{self.t.faint}{'─' * width}{RESET}{self.t.bg}{ESC}[K\r\n")
                    continue
                left = f" {entry.get('emoji', ' ')}  {entry.get('name', '?')}"
                note = label_of(entry)
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

        hint = self.status or ("enter launch · c/x pin · h/l letter · d debug "
                               "· e config · / filter · q quit")
        colour = self.t.accent2 if self.status else self.t.dim
        status = f"{self.t.bar_bg}{colour} {hint}"
        out.append(f"{status}{' ' * max(0, width - display_len(status))}{RESET}")

        sys.stdout.write("".join(out))
        sys.stdout.flush()

    # -- input -----------------------------------------------------------
    def key(self, ch):
        self.status = ""
        rows = self.rows()
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
        if ch in ("\r", "\n", "F"):
            return self.launch()
        if ch == "c":
            return self.pin(True)
        if ch == "x":
            return self.pin(False)
        if ch == "d":
            return self.launch(debug=True)
        if ch == "e":
            return self.edit()
        if ch == "/":
            self.searching, self.filter, self.cursor = True, "", 0
        elif ch in ("j", f"{ESC}B"):
            self.step(rows, 1)
        elif ch in ("k", f"{ESC}A"):
            self.step(rows, -1)
        elif ch == f"{ESC}6":
            self.step(rows, page)
        elif ch == f"{ESC}5":
            self.step(rows, -page)
        elif ch in ("h", "l") and rows:
            self.cursor = letter_jump(rows, self.cursor, ch == "l")
        elif ch == "g":
            self.cursor = 0
        elif ch == "G":
            self.cursor = max(0, len(rows) - 1)
        self.clamp(rows)
        return True

    def step(self, rows, delta):
        """Move by delta rows, hopping the separator rather than landing on it."""
        target = max(0, min(max(0, len(rows) - 1), self.cursor + delta))
        if rows and rows[target][0] == "sep":
            nudge = 1 if delta > 0 else -1
            if 0 <= target + nudge < len(rows):
                target += nudge
        self.cursor = target


def initial(entry):
    name = entry.get("name", "")
    return next((c.upper() for c in name if c.isalnum()), "")


def letter_jump(rows, cursor, forward):
    """Row index of the first entry of the next (or previous) starting letter.

    Letters only make sense in the main list, which holds every entry; the pin
    section is a short subset, so a jump from a pin lands on that entry's letter
    neighbour down in the list.
    """
    main = [i for i, (kind, _) in enumerate(rows) if kind == "entry"]
    if not main:
        return cursor
    entry = rows[cursor][1]
    here = next((n for n, i in enumerate(main) if rows[i][1] is entry), 0)
    entries = [rows[i][1] for i in main]
    return main[_letter_jump(entries, here, forward)]


def _letter_jump(rows, cursor, forward):
    letter = initial(rows[cursor])
    if forward:
        i = cursor
        while i < len(rows) and initial(rows[i]) == letter:
            i += 1
        return i if i < len(rows) else cursor
    i = cursor
    while i > 0 and initial(rows[i - 1]) == letter:  # start of this letter
        i -= 1
    if i == 0:
        return 0
    prev = initial(rows[i - 1])
    i -= 1
    while i > 0 and initial(rows[i - 1]) == prev:    # start of the previous one
        i -= 1
    return i


def read_key():
    data = os.read(sys.stdin.fileno(), 32).decode(errors="replace")
    if not data.startswith(ESC):
        return list(data)
    if len(data) == 1:
        return [ESC]
    return [ESC + data[-1]]  # final byte identifies the key (A/B/5/6/...)


def focused():
    """Is this launcher the focused window? Pads are global, so ask hyprland."""
    try:
        out = subprocess.run(["hyprctl", "activewindow", "-j"],
                             capture_output=True, text=True, timeout=1).stdout
        return json.loads(out or "{}").get("class") == "ap-launcher"
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False


PAD_KEYS = {"up": "k", "down": "j", "left": "h", "right": "l", "south": "\r"}


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
        pads = Gamepads() if Gamepads else None
        app.draw()
        running = True
        while running:
            watch = [fd] + (pads.fds() if pads else [])
            wait = pads.timeout(1.0) if pads else None
            try:
                ready, _, _ = select.select(watch, [], [], wait)
            except InterruptedError:  # resize woke up the select
                continue

            keys = []
            if fd in ready:
                keys = read_key()
                if not keys:  # stdin closed
                    break
            if pads:
                events = [PAD_KEYS[ev] for ev in pads.read(ready) if ev in PAD_KEYS]
                if events and not app.searching and focused():
                    keys += events

            for ch in keys:
                if not app.key(ch):
                    running = False
                    break
            if keys and running:
                app.draw()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        sys.stdout.write(f"{ESC}[?25h{ESC}[?1049l")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
