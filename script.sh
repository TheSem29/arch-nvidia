#!/bin/bash

# Конфигурация (измените под свои нужды)
DISK="/dev/nvme0n1"
HOSTNAME="arch-pc"
USERNAME="user"
TIMEZONE="Europe/Moscow"
EFI_SIZE="512M"
ROOT_SIZE="100%"
KERNEL="linux"

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен запускаться с правами root!" >&2
    exit 1
fi

# Проверка наличия NVMe диска
if [ ! -e "$DISK" ]; then
    echo -e "\033[1;31m[ОШИБКА] Диск $DISK не найден!\033[0m"
    echo "Доступные диски:"
    lsblk -d -o NAME,SIZE,MODEL | grep -E 'nvme|sd[a-z]'
    exit 1
fi

# Часть 1: Разметка диска
echo -e "\n\033[1;32m[1] Разметка диска ($DISK)\033[0m"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary fat32 1MiB "$EFI_SIZE"
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary ext4 "$EFI_SIZE" "$ROOT_SIZE"

# Форматирование
echo -e "\n\033[1;32m[2] Форматирование разделов\033[0m"
mkfs.vfat -F32 "${DISK}p1"
mkfs.ext4 -F "${DISK}p2"

# Монтирование
mount "${DISK}p2" /mnt
mkdir -p /mnt/boot/efi
mount "${DISK}p1" /mnt/boot/efi

# Часть 2: Установка базовой системы
echo -e "\n\033[1;32m[3] Установка базовых пакетов\033[0m"
pacman -Sy --noconfirm archlinux-keyring
pacstrap /mnt base base-devel "$KERNEL" "$KERNEL-headers" linux-firmware \
          nano vim bash-completion grub efibootmgr networkmanager \
          git reflector sudo

# Оптимизация зеркал
arch-chroot /mnt reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# Генерация fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Часть 3: Настройка системы в chroot
arch-chroot /mnt /bin/bash <<'EOF'
# Настройка времени и локали
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
sed -i 's/#ru_RU.UTF-8/ru_RU.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "KEYMAP=ru" > /etc/vconsole.conf
echo "FONT=cyr-sun16" >> /etc/vconsole.conf

# Настройка сети
echo "$HOSTNAME" > /etc/hostname
echo -e "127.0.0.1 localhost\n::1 localhost\n127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts
systemctl enable NetworkManager

# Пользователь и пароли
echo "root:root" | chpasswd
useradd -m -G wheel,audio,video,storage -s /bin/bash "$USERNAME"
echo "$USERNAME:$USERNAME" | chpasswd
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Загрузчик
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT=""/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Драйверы NVIDIA (если нужно)
if lspci | grep -i nvidia; then
    pacman -S --noconfirm nvidia nvidia-utils nvidia-settings opencl-nvidia
    sed -i 's/MODULES=()/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
    echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia.conf
    echo -e "WLR_NO_HARDWARE_CURSORS=1\nWLR_RENDERER=vulkan\nLIBVA_DRIVER_NAME=nvidia\nGBM_BACKEND=nvidia-drm\n__GLX_VENDOR_LIBRARY_NAME=nvidia" >> /etc/environment
    mkinitcpio -P
fi

# Установка yay от имени пользователя
sudo -u $USERNAME bash <<'USEREOF'
git clone https://aur.archlinux.org/yay-bin.git ~/yay-bin
cd ~/yay-bin && makepkg -si --noconfirm
USEREOF

# Установка Hyprland и компонентов
sudo -u $USERNAME yay -S --noconfirm hyprland xdg-desktop-portal-hyprland waybar \
    rofi kitty thunar file-roller qt5-wayland qt6-wayland \
    sddm network-manager-applet pipewire wireplumber pipewire-audio \
    pipewire-alsa pipewire-pulse noto-fonts-cjk noto-fonts-emoji \
    ttf-hack ttf-fira-code swaybg wl-clipboard xf86-input-libinput \
    brightnessctl

# Настройка SDDM
systemctl enable sddm

# Конфигурация Hyprland
if [ -f "/usr/share/hyprland/examples/hyprland.conf" ]; then
    sudo -u $USERNAME mkdir -p /home/$USERNAME/.config/hypr
    cp /usr/share/hyprland/examples/hyprland.conf /home/$USERNAME/.config/hypr/
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.config
else
    echo "ERROR: Hyprland не установлен корректно!" >&2
    exit 1
fi

# Загрузка обоев
sudo -u $USERNAME curl -o /home/$USERNAME/wallpaper.jpg \
    https://raw.githubusercontent.com/linuxdotexe/nordic-wallpapers/master/wallpapers/nordic-wallpaper.png

# Фикс прав
chown -R $USERNAME:$USERNAME /home/$USERNAME
EOF

# Завершение
echo -e "\n\033[1;32m[!] Установка завершена!\033[0m"
echo -e "Выполните команды для перезагрузки:"
echo "umount -R /mnt"
echo "reboot"
