# dotfiles

A **bare** git repo at `~/.dotfiles.git` whose work tree is `$HOME`, so every
tracked config lives in its normal place — no symlinks, nothing for an app to
break when it rewrites its own config file.

## Using it

`config` is git, scoped to `$HOME` (fish function in
`~/.config/fish/functions/config.fish`, bash alias in `~/.bashrc`):

    config status
    config add ~/.config/caelestia/keybinds.json
    config commit -m "keybinds: add SUPER + N"
    config push

Untracked files are hidden (`status.showUntrackedFiles=no`), so `config status`
only reports changes to files you have deliberately added. Track something new
with an explicit `config add <path>`.

`~/.dotfiles.git/info/exclude` is a safety net: caches, browser profiles,
Electron app data, keys and `~/.claude` (which holds credentials) are listed
there so a stray `config add -A` cannot sweep them in.

## Restoring on a fresh install

On the `kurt-arch` branch, use `bootstrap.sh` (see `KURT.md`). By hand:

    pacman -S --needed git fish
    git clone --bare <remote> ~/.dotfiles.git
    alias config='git --git-dir=$HOME/.dotfiles.git --work-tree=$HOME'
    config config status.showUntrackedFiles no
    config checkout                     # may complain about files already there
    ~/.config/dotfiles/install-packages.sh

`config checkout` refuses to clobber existing files (a fresh install ships
default `.bashrc`, `.config/fish/config.fish`, …). Move the offenders aside and
re-run, or `config checkout -f` if you are sure nothing local matters.

## What is deliberately NOT here

- `~/.config/hypr/` — caelestia owns it; reinstalling caelestia restores it, and
  local changes belong in `~/.config/caelestia/` anyway.
- Browser profiles, Discord/Todoist/VSCodium app state, `~/.local/share`,
  caches — big, machine-specific, and regenerated.
- `~/.claude/` — contains credentials.
- `~/Applications/*.AppImage` (Archipelago) — download it again; only
  `~/.config/Archipelago/launcher.toml` is tracked, and its `[settings]
  archipelago = …` path will need updating for a new AppImage version.

## Packages

`pkglist-native.txt` (explicitly installed repo packages) and `pkglist-aur.txt`
(foreign/AUR). Refresh with `~/.config/dotfiles/refresh-pkglist.sh`.
