#!/usr/bin/env bash
# Lenovo Legion Slim 7 (Ryzen 7 5800H + RTX 3060) hardware setup.
# Run AFTER bootstrap.sh, as your normal user, then reboot. Safe to re-run.
#
# What it does:
#   - AMD microcode + AMD iGPU drivers (the iGPU drives the desktop, saves battery)
#   - NVIDIA open driver for the RTX 3060 (Ampere), used on demand with `prime-run`
#   - NVIDIA suspend/resume services so sleep doesn't break the dGPU
#   - power-profiles-daemon (caelestia's power-mode toggle), brightnessctl
#   - suspend on lid close, ignore lid when docked to external power + monitor
#   - Windows dual-boot: GRUB + os-prober so Windows shows in the boot menu,
#     and the hardware clock in local time so Windows' clock doesn't jump
set -euo pipefail
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
[ "$(id -u)" -ne 0 ] || { echo "Run as your normal user, not root."; exit 1; }
sudo -v

step "CPU microcode + AMD graphics + NVIDIA RTX 3060"
sudo pacman -S --needed --noconfirm \
    amd-ucode \
    mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver \
    nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings nvidia-prime \
    power-profiles-daemon brightnessctl

step "NVIDIA kernel modesetting + suspend services"
sudo install -Dm644 /dev/stdin /etc/modprobe.d/nvidia.conf <<'CONF'
options nvidia_drm modeset=1 fbdev=1
# Let the RTX 3060 power fully off when nothing is using it (battery life).
options nvidia NVreg_DynamicPowerManagement=0x02
CONF
sudo systemctl enable nvidia-suspend nvidia-hibernate nvidia-resume
sudo systemctl enable --now power-profiles-daemon

step "Lid: suspend on close (but not when on AC with an external monitor)"
sudo install -Dm644 /dev/stdin /etc/systemd/logind.conf.d/10-lid.conf <<'CONF'
[Login]
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=suspend
HandleLidSwitchDocked=ignore
CONF

step "Dual boot with Windows"
# Windows keeps the hardware clock in local time; match it.
sudo timedatectl set-local-rtc 1 --adjust-system-clock
if [ -f /etc/default/grub ]; then
    sudo pacman -S --needed --noconfirm os-prober ntfs-3g
    sudo sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
    grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub \
        || echo 'GRUB_DISABLE_OS_PROBER=false' | sudo tee -a /etc/default/grub >/dev/null
    sudo grub-mkconfig -o /boot/grub/grub.cfg
else
    echo "No GRUB found -- pick Windows from the F12 boot menu, or see LEGION.md."
fi

step "Rebuild initramfs"
sudo mkinitcpio -P

cat <<'MSG'

Done. Reboot now. After logging in:
  - Desktop runs on the AMD iGPU. Run something on the RTX 3060 with:
        prime-run <command>
    Steam games: Properties -> Launch Options:  prime-run %command%
  - Check the dGPU sleeps when idle:  cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status
    ("suspended" = good)
  - Optional Legion extras (battery conservation mode, fan curves, power modes):
        paru -S lenovolegionlinux-git lenovolegionlinux-dkms-git
MSG
