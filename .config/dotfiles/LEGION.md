# Legion Slim 7 laptop: dual-boot install

Ryzen 7 5800H + RTX 3060, Windows kept alongside Arch. You end up with the same
setup as the desktop (same packages, look and keybinds), plus laptop hardware support.

## 1. In Windows (before touching Linux)

1. **BitLocker / Device Encryption**: if it's on, save the recovery key
   (aka.ms/myrecoverykey) or turn it off. Changing boot settings can trigger a
   recovery-key prompt.
2. **Turn off Fast Startup**: Control Panel -> Power Options -> "Choose what the
   power buttons do" -> untick *Turn on fast startup*. (Otherwise Windows leaves
   the disk half-locked, and Linux can corrupt it.)
3. **Make room**: Disk Management -> right-click C: -> *Shrink Volume*. Give Arch
   at least 150 GB. Leave the space **unallocated**.
4. Make an Arch USB (archlinux.org/download, flash with Rufus in GPT mode, or
   `dd` from this desktop).

## 2. BIOS (F2 at the Lenovo logo, or the Novo pinhole button)

- **Secure Boot: Disabled**
- If there's a GPU mode setting, leave it on **Hybrid / Dynamic** (not Discrete).
- Boot the USB from the **F12** boot menu.

## 3. Install Arch (archinstall)

Connect to Wi-Fi first: `iwctl` -> `station wlan0 connect <SSID>`. Then run `archinstall`:

- **Disk configuration**: choose *Manual partitioning* on the internal NVMe. Do
  **not** pick the best-effort default (it wipes Windows). In the free space, create:
  - a **1 GiB FAT32** partition, mountpoint `/boot`, *boot/ESP* flag. This is a
    separate EFI partition for Arch, because Lenovo's Windows EFI partition is too small
    for kernels plus the NVIDIA initramfs.
  - the rest **ext4** (or btrfs), mountpoint `/`
  - Leave every existing Windows partition untouched (don't format, don't mount).
- **Bootloader: GRUB**. laptop-legion.sh adds Windows to its menu.
- Profile: *Minimal*. Audio: *pipewire*. Network: *NetworkManager*.
- Kernel: `linux`. Graphics driver: skip it (the script handles it).
- Hostname e.g. `kurtlegion`; create user `kurt` with sudo.
- Enable the multilib repo (Additional repositories), which Steam needs.

Reboot and pull the USB.

## 4. Set it up

Log in at the TTY and connect Wi-Fi with `nmtui`. Then:

    git clone https://github.com/kurt-cole/kurt_arch_config.git /tmp/dots
    bash /tmp/dots/.config/dotfiles/bootstrap.sh
    bash ~/.config/dotfiles/laptop-legion.sh
    reboot

Pick Arch in GRUB, log in through tuigreet, and Hyprland starts.

## Notes

- The desktop's monitor pins in `hypr-user.lua` (DP-1/DP-2) don't match the laptop's
  panel (`eDP-1`), so they're ignored and the laptop panel auto-configures.
- The laptop's HDMI port is probably wired to the RTX 3060, so plugging in an
  external monitor wakes the dGPU. That's normal.
- If Hyprland ever starts on the NVIDIA GPU (laggy, battery drains fast), pin it
  to the iGPU: find the AMD card with `ls -l /dev/dri/by-path`, then add
  `export AQ_DRM_DEVICES=/dev/dri/cardN` to `~/.config/uwsm/env-hyprland`.
- Windows clock off by hours after switching OS: that's the RTC; the script sets
  Linux to local time, so re-run it if needed.
- Windows not in GRUB: boot Arch once with Windows' partitions present, then run
  `sudo grub-mkconfig -o /boot/grub/grub.cfg`. F12 at power-on always works too.
