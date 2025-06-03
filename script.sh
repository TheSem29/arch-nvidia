#!/bin/bash

# Configuration
DISK="/dev/sda"  # Для VirtualBox используем /dev/sda
HOSTNAME="arch-vbox"
USERNAME="user"
TIMEZONE="Europe/Moscow"
EFI_SIZE="512M"
ROOT_SIZE="100%"
KERNEL="linux"

# Root check
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root!" >&2
    exit 1
fi

# Part 1: Disk partitioning
echo -e "\n\033[1;32m[1] Partitioning disk ($DISK)\033[0m"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary fat32 1MiB "$EFI_SIZE"
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary ext4 "$EFI_SIZE" "$ROOT_SIZE"

# Formatting
echo -e "\n\033[1;32m[2] Formatting partitions\033[0m"
mkfs.vfat -F32 "${DISK}1"
mkfs.ext4 -F "${DISK}2"

# Mounting
mount "${DISK}2" /mnt
mkdir -p /mnt/boot/efi
mount "${DISK}1" /mnt/boot/efi

# Part 2: Base system installation
echo -e "\n\033[1;32m[3] Installing base packages\033[0m"
pacman -Sy --noconfirm archlinux-keyring
pacstrap /mnt base base-devel "$KERNEL" "$KERNEL-headers" linux-firmware \
          nano bash-completion grub efibootmgr networkmanager \
          git reflector

# Mirror optimization
arch-chroot /mnt reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Part 3: System configuration in chroot
arch-chroot /mnt /bin/bash <<EOF
# Timezone and locale
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
sed -i 's/#ru_RU.UTF-8/ru_RU.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "KEYMAP=ru" > /etc/vconsole.conf
echo "FONT=cyr-sun16" >> /etc/vconsole.conf

# Network configuration
echo "$HOSTNAME" > /etc/hostname
echo -e "127.0.0.1 localhost\n::1 localhost\n127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts
systemctl enable NetworkManager

# Users and passwords
echo "root:root" | chpasswd
useradd -m -G wheel,audio,video,storage -s /bin/bash "$USERNAME"
echo "$USERNAME:$USERNAME" | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Bootloader
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT=""/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# VirtualBox Guest Additions (вместо NVIDIA)
pacman -S --noconfirm virtualbox-guest-utils mesa
systemctl enable vboxservice

# Hyprland environment
sudo -u $USERNAME git clone https://aur.archlinux.org/yay-bin.git /home/$USERNAME/yay-bin
cd /home/$USERNAME/yay-bin && sudo -u $USERNAME makepkg -si --noconfirm
sudo -u $USERNAME yay -S --noconfirm hyprland xdg-desktop-portal-hyprland waybar \
    rofi kitty thunar file-roller qt5-wayland qt6-wayland \
    sddm network-manager-applet pipewire wireplumber pipewire-audio \
    pipewire-alsa pipewire-pulse noto-fonts-cjk noto-fonts-emoji ttf-hack \
    swaybg wl-clipboard xf86-input-libinput brightnessctl

# SDDM and config setup
systemctl enable sddm
sudo -u $USERNAME mkdir -p /home/$USERNAME/.config/hypr
cp /usr/share/hyprland/examples/hyprland.conf /home/$USERNAME/.config/hypr/
chown -R $USERNAME:$USERNAME /home/$USERNAME/.config

# Basic Hyprland configuration for VirtualBox
cat > /home/$USERNAME/.config/hypr/hyprland.conf <<'HYPRCONF'
exec-once = waybar
exec-once = swaybg -i ~/wallpaper.jpg
exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec-once = systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP

# Используем программный рендеринг для VirtualBox
env = WLR_RENDERER,pixman

monitor=,highres,auto,1

input {
    kb_layout = us,ru
    kb_options = grp:alt_shift_toggle
    follow_mouse = 1
    touchpad {
        natural_scroll = yes
    }
}

general {
    sensitivity = 1.0
    main_mod = SUPER
}

decoration {
    rounding = 5
    blur = no # Отключаем размытие для производительности
}

animations {
    enabled = no # Отключаем анимации для VirtualBox
}

dwindle {
    pseudotile = yes
    preserve_split = yes
}

master {
    new_is_master = true
}

bind = SUPER, RETURN, exec, kitty
bind = SUPER, Q, killactive,
bind = SUPER, E, exec, thunar
bind = SUPER, V, togglefloating,
bind = SUPER, R, exec, rofi -show drun

bind = SUPER, left, movefocus, l
bind = SUPER, right, movefocus, r
bind = SUPER, up, movefocus, u
bind = SUPER, down, movefocus, d

bind = SUPER, 1, workspace, 1
bind = SUPER, 2, workspace, 2
bind = SUPER, 3, workspace, 3
bind = SUPER, 4, workspace, 4

bind = SUPER SHIFT, 1, movetoworkspace, 1
bind = SUPER SHIFT, 2, movetoworkspace, 2
bind = SUPER SHIFT, 3, movetoworkspace, 3
bind = SUPER SHIFT, 4, movetoworkspace, 4

bind = , XF86AudioRaiseVolume, exec, pactl set-sink-volume @DEFAULT_SINK@ +5%
bind = , XF86AudioLowerVolume, exec, pactl set-sink-volume @DEFAULT_SINK@ -5%
bind = , XF86AudioMute, exec, pactl set-sink-mute @DEFAULT_SINK@ toggle
HYPRCONF

# Download wallpaper
sudo -u $USERNAME curl -o /home/$USERNAME/wallpaper.jpg https://raw.githubusercontent.com/linuxdotexe/nordic-wallpapers/master/wallpapers/nordic-wallpaper.png

# Fix permissions
chown -R $USERNAME:$USERNAME /home/$USERNAME
EOF

# Completion
echo -e "\n\033[1;32m[!] Installation completed!\033[0m"
echo -e "Run these commands to reboot:"
echo "umount -R /mnt"
echo "reboot"
