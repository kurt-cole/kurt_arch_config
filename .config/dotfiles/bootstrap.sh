#!/usr/bin/env bash
# kurt-arch bootstrap: turn a fresh, booting Arch install into Barret's
# caelestia/Hyprland setup. Run as your normal user (with sudo rights), from a
# TTY or any terminal, with network up. The repo is private, so you need read
# access (GitHub collaborator) and either an SSH key on GitHub or `gh auth login`:
#
#   git clone --branch kurt-arch git@github.com:barretg/arch-caelestia-config.git /tmp/dots
#   DOTFILES_REPO=git@github.com:barretg/arch-caelestia-config.git bash /tmp/dots/.config/dotfiles/bootstrap.sh
#
# DOTFILES_REPO / DOTFILES_BRANCH override where the dotfiles come from (e.g.
# your own fork).
#
# Safe to re-run. Every step skips itself when already done. Files the dotfiles
# would overwrite are moved to ~/.dotfiles-backup/<timestamp>/ first.
#
# NOT done here (machine-specific -- see KURT.md): GPU driver and CPU microcode,
# monitor modes, optional apps (pkglist-extras.txt).
set -euo pipefail

REPO="${DOTFILES_REPO:-https://github.com/barretg/arch-caelestia-config.git}"
BRANCH="${DOTFILES_BRANCH:-kurt-arch}"
GITDIR="$HOME/.dotfiles.git"
cfg() { git --git-dir="$GITDIR" --work-tree="$HOME" "$@"; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not root."; exit 1; }
[ -f /etc/arch-release ] || { echo "This is for Arch Linux."; exit 1; }
sudo -v

step "Base tools"
sudo pacman -Syu --needed --noconfirm git base-devel fish

step "paru (AUR helper)"
if ! command -v paru >/dev/null; then
    tmp=$(mktemp -d)
    git clone https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin"
    (cd "$tmp/paru-bin" && makepkg -si --noconfirm)
    rm -rf "$tmp"
fi

step "caelestia (shell, CLI, upstream Hyprland config in ~/.config/hypr)"
paru -S --needed --noconfirm caelestia-cli
if [ ! -f "$HOME/.config/hypr/hyprland.lua" ]; then
    caelestia install --aur-helper paru --noconfirm
fi

step "Dotfiles ($BRANCH)"
if [ ! -d "$GITDIR" ]; then
    git clone --bare --branch "$BRANCH" "$REPO" "$GITDIR"
    cfg config status.showUntrackedFiles no
    backup="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"
    # Move aside anything the checkout would clobber (caelestia install just
    # wrote fish/foot/btop/... configs; ours replace them).
    cfg ls-tree -r --name-only "$BRANCH" | while read -r f; do
        if [ -e "$HOME/$f" ] || [ -L "$HOME/$f" ]; then
            mkdir -p "$backup/$(dirname "$f")"
            mv "$HOME/$f" "$backup/$f"
        fi
    done
    (cd "$HOME" && cfg checkout "$BRANCH" -- .)
    echo "Replaced files (if any) are in $backup"
fi

step "Per-user paths"
for f in .config/appimagelauncher.cfg .config/Thunar/uca.xml .config/gtk-3.0/bookmarks; do
    if grep -q '@HOME@' "$HOME/$f" 2>/dev/null; then
        sed -i "s|@HOME@|$HOME|g" "$HOME/$f"
        cfg update-index --skip-worktree "$f"
    fi
done
xdg-user-dirs-update 2>/dev/null || true
mkdir -p "$HOME/Projects" "$HOME/Applications"

step "Packages (core set)"
bash "$HOME/.config/dotfiles/install-packages.sh"

step "System files: greetd login, keyd (caps = super/esc), bluetooth agent"
sudo install -Dm644 "$HOME/.config/dotfiles/etc/greetd/config.toml" /etc/greetd/config.toml
sudo install -Dm644 "$HOME/.config/caelestia/keyd-default.conf" /etc/keyd/default.conf
sudo install -Dm644 "$HOME/.config/dotfiles/etc/systemd/system/bt-agent.service" /etc/systemd/system/bt-agent.service
sudo install -Dm644 /dev/stdin /etc/systemd/system/bt-agent.service.d/quick-stop.conf <<'UNIT'
[Service]
# bt-agent ignores SIGTERM, which otherwise stalls every shutdown by 90s.
KillSignal=SIGKILL
FinalKillSignal=SIGKILL
TimeoutStopSec=5s
SuccessExitStatus=SIGKILL
UNIT
sudo systemctl daemon-reload
sudo systemctl enable NetworkManager bluetooth bt-agent keyd greetd

step "Shell"
[ "$(getent passwd "$USER" | cut -d: -f7)" = /usr/bin/fish ] || sudo chsh -s /usr/bin/fish "$USER"

# x-terminal-emulator wrapper, so Archipelago-style "open in terminal" works
sudo ln -sf "$HOME/.config/caelestia/scripts/x-terminal-emulator" /usr/local/bin/x-terminal-emulator

systemctl --user daemon-reload 2>/dev/null || true

cat <<'MSG'

Done. Still to do by hand (see ~/.config/dotfiles/KURT.md):
  1. GPU driver + CPU microcode for THIS machine (pkglist-extras.txt has a cheat sheet)
  2. Reboot -> log in through tuigreet -> Hyprland starts
  3. Pin your monitor modes in ~/.config/caelestia/hypr-user.lua (hyprctl monitors -j)
  4. Optional apps: ~/.config/dotfiles/pkglist-extras.txt
  5. Point the dotfiles at your own repo:  config remote set-url origin <your repo>
MSG
