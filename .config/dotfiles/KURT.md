# kurt-arch: Barret's Arch + caelestia setup, generalised

This branch is Barret's dotfiles with the machine- and person-specific parts
removed, plus a bootstrap script. Hardware, monitors and app choices are yours
to fill in.

## Install order

1. **Base Arch** with `archinstall` (or by hand). Recommended answers:
   - Profile: *Minimal* (no desktop -- caelestia provides it)
   - Audio: *pipewire*; Network: *NetworkManager*
   - Bootloader: systemd-boot (UEFI) or GRUB -- either works
   - Kernel: `linux` (add `linux-lts` as a fallback if you like)
   - Graphics driver: pick yours here, or later from the cheat sheet in
     `pkglist-extras.txt`
   - Create your user with sudo rights
2. Reboot into the TTY, log in, run **`bootstrap.sh`** (instructions are in its header).
3. Install the **GPU driver + CPU microcode** for your hardware if archinstall didn't.
   NVIDIA also needs `nvidia_drm.modeset=1` on the kernel cmdline (default on
   recent drivers) and `nvidia-utils`/`lib32-nvidia-utils` for Steam.
4. Reboot. tuigreet comes up on tty1 and starts Hyprland through uwsm.
5. Pin monitor modes in `~/.config/caelestia/hypr-user.lua` (there's an example
   in there; get names from `hyprctl monitors -j`).
6. Pick extras from `pkglist-extras.txt`.
7. Run `claude` once to sign in; after that **Super + '** opens it.
8. `config push` sends your commits to the `kurt-arch` branch (the bootstrap clones
   it with that upstream), never to Barret's `main`.

## What bootstrap.sh does

- installs git/base-devel/fish and paru
- `caelestia install` (caelestia-shell, caelestia-cli, upstream `~/.config/hypr`)
- clones this branch as a bare repo at `~/.dotfiles.git`, work tree `$HOME`, and
  checks it out over caelestia's defaults (anything replaced goes to `~/.dotfiles-backup/`)
- installs the core package lists (`pkglist-native.txt`, `pkglist-aur.txt`)
- installs Claude Code (native installer, `~/.local/bin/claude`)
- installs `/etc` files: greetd (tuigreet -> `uwsm start hyprland.desktop`),
  keyd, and the bt-agent service. It enables NetworkManager, bluetooth,
  bt-agent, keyd and greetd.
- sets fish as login shell

## Things that will surprise you

- **Caps Lock is Super when held and Esc when tapped** (keyd,
  `~/.config/caelestia/keyd-default.conf` -> `/etc/keyd/default.conf`). Super + ]
  toggles that off. Don't want it? `sudo systemctl disable --now keyd`.
- **Never edit `~/.config/hypr/`.** caelestia owns it and updates overwrite it.
  Your changes go in `~/.config/caelestia/`: `hypr-vars.lua` (override caelestia's
  keybind variables), `hypr-user.lua` (extra binds and rules), `cli.json`
  (special-workspace app groups), `shell.json` (bar/shell settings; no comments allowed).
- **Super + `** shows a keybind cheatsheet built from
  `~/.config/caelestia/keybinds.json`. Edit that file whenever you change a bind.
- The Hyprland config is **Lua**, so `hyprctl dispatch` takes a Lua expression
  (`hyprctl dispatch 'hl.dsp.window.float()'`), and `hyprctl keyword` doesn't work.
  Use `hyprctl eval`.
- Window rules matched by **tag** apply after rules matched by class, whatever
  order they were declared in. To override one of caelestia's tagged rules, match
  the tag too.
- Bind keys are resolved through the keymap. Odd mouse buttons often emit
  `XF86Tools`-style keysyms, not `F13`. Check with `wev`.
- **Super + N** "minimises" a window by parking it on a hidden special
  workspace. **Super + Shift + N** opens a picker to bring it back. Wayland has no real minimise.
- Bluetooth: caelestia's panel pairs without an agent, so bonds don't survive a
  reboot. `bt-agent.service` fixes that. Run `bluetoothctl trust <mac>` after pairing.
- Discord's own keybinds don't work under native Wayland. The mouse side-button
  binds in `hypr-user.lua` send its built-in Ctrl+Shift+M / D instead.
- Apps on `ELECTRON_OZONE_PLATFORM_HINT=auto` (uwsm env) run native Wayland. If
  an Electron/Unity app misbehaves, try forcing X11 (`SDL_VIDEODRIVER=x11` for Unity,
  `QT_QPA_PLATFORM=xcb` for Qt).

## Removed from Barret's version

Steam Deck streaming/3DS-sync/sshfs scripts, the Halo MCC Archipelago launcher,
boot-to-BIOS/Windows helpers, x64dbg MCP config, Sunshine overrides, Logitech
(solaar) device config, the bluetooth `main.conf` (it forced BR/EDR-only), his
monitor pins and Steam library paths. The Archipelago tooling (Super + ; game
launcher, Proton client injection) is still here. `~/.config/Archipelago/launcher.toml`
has every game hidden, so flip on the ones you play.
