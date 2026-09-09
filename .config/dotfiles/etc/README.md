# `/etc` files (not symlinked — copies)

The dotfiles repo's work tree is `$HOME`, so root-owned files under `/etc`
cannot be tracked in place. These are **copies**, kept here so a fresh install
can restore them. Editing a file here changes nothing until you copy it back.

## Restore

    sudo install -m644 etc/systemd/system/bt-agent.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now bt-agent.service

    sudo install -m644 etc/bluetooth/main.conf /etc/bluetooth/main.conf
    sudo systemctl restart bluetooth

Requires the `bluez-tools` package (in `pkglist-native.txt`).

## Why these exist

`bt-agent.service` runs a BlueZ pairing agent (`org.bluez.Agent1`) at all times.
Nothing else on this system provides one — quickshell/caelestia's Bluetooth panel
calls `Device1.Pair()` with no agent registered, which completes as "paired" but
never persists a link key, so every bond is lost on reboot. See the Bluetooth
section of `~/Projects/claude-scratchwork/CLAUDE.md` for the full diagnosis.

`main.conf` has its `DisablePlugins` line commented out — the key was removed in
BlueZ 5.87 and bluetoothd logged an "Unknown key" warning at every start while
loading `sap`/`hfp`/`hsp` regardless.
