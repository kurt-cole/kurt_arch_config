# Game Launcher Sync

Automatically adds every installed **Steam** and **Heroic** (Epic / GOG / Amazon / sideloaded) game to the app menu, so you can search for games like any other app. Each game gets its own icon. Uninstalling a game removes its entry.

Made for Arch Linux with native (non-Flatpak) Steam and Heroic. It works with any desktop that reads `~/.local/share/applications`.

## Install

```bash
cd game-launcher-sync
bash install.sh
```

This:
1. Copies `steam-desktop-sync` and `heroic-desktop-sync` to `~/.local/bin/`.
2. Installs systemd **user** units into `~/.config/systemd/user/`. It builds the Steam watcher from your own `libraryfolders.vdf`, so extra drives are picked up automatically.
3. Enables the `.path` watchers and runs one sync right away.

You don't need root.

**Added a new Steam library folder later?** Re-run `bash install.sh` so the watcher picks it up.

## How it works

| Piece | What it does |
|---|---|
| `steam-desktop-sync` | Reads `appmanifest_*.acf` from every Steam library and writes `~/.local/share/applications/steam-<appid>.desktop` for each fully installed game. Launches via `steam://rungameid/<appid>`. Icons are copied from Steam's cache into `~/.local/share/icons/steam-desktop-sync/`. Skips Proton, the Steam Linux Runtimes and the redistributables. |
| `steam-desktop-sync.path` | Watches each library's `steamapps` folder and triggers the sync when it changes. |
| `heroic-desktop-sync` | Reads Heroic's installed lists (`~/.config/heroic/...`) and writes `heroic-<runner>-<app>.desktop`. Launches via `heroic://launch?...`. Uses the game's cover art as the icon. |
| `heroic-desktop-sync.path` | Watches Heroic's `installed.json` files. |

Safety details:
- The scripts only delete entries they created themselves. Each one is tagged `X-Steam-Desktop-Sync=true` or `X-Heroic-Desktop-Sync=true`.
- A game that already has a shortcut, such as one made with Steam's "Add desktop shortcut", is skipped so it doesn't show up twice.
- If a Steam library drive isn't mounted, the Steam sync still adds new games but won't delete any entries.

## Check / troubleshoot

```bash
systemctl --user status steam-desktop-sync.path heroic-desktop-sync.path
journalctl --user -u steam-desktop-sync -u heroic-desktop-sync -n 30
steam-desktop-sync          # run a sync by hand
```

- **Removing a game:** uninstall it through Steam or Heroic. Deleting the game folder by hand leaves Steam thinking the game is installed, so the entry stays.
- **Flatpak Steam or Heroic** uses different paths (`~/.var/app/...`), and these scripts won't find them as-is.

## Uninstall

```bash
systemctl --user disable --now steam-desktop-sync.path heroic-desktop-sync.path
rm ~/.local/bin/{steam,heroic}-desktop-sync ~/.config/systemd/user/{steam,heroic}-desktop-sync.*
grep -l 'X-\(Steam\|Heroic\)-Desktop-Sync=true' ~/.local/share/applications/*.desktop | xargs -r rm
rm -rf ~/.local/share/icons/{steam,heroic}-desktop-sync
systemctl --user daemon-reload
```

## Note for an AI assistant (Claude Code etc.)

If you're helping someone install this:
- Run `bash install.sh` from this folder. Don't hand-edit the Steam `.path` unit, because the installer generates it.
- If Steam is a Flatpak, change `STEAM` in `steam-desktop-sync` and `install.sh` to `~/.var/app/com.valvesoftware.Steam/.local/share/Steam`.
- If Heroic is a Flatpak, change `HEROIC` in `heroic-desktop-sync` and the paths in `heroic-desktop-sync.path` to `~/.var/app/com.heroicgameslauncher.hgl/config/heroic`.
- Afterwards, check that it worked with `ls ~/.local/share/applications/{steam,heroic}-*.desktop`.
