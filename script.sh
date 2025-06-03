#!/bin/bash

# Конфигурация
DISK="/dev/sda"
HOSTNAME="arch-pc"
USERNAME="user"
TIMEZONE="Europe/Moscow"
EFI_SIZE="512M"
SWAP_SIZE="4G"  # Добавлен swap для экономии RAM
ROOT_SIZE="100%"
KERNEL="linux"

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root!" >&2
    exit 1
fi

# Проверка диска
if [ ! -e "$DISK" ]; then
    echo -e "\033[1;31m[ERROR] Disk $DISK not found!\033[0m"
    lsblk
    exit 1
fi

# Проверка свободного места (минимум 8GB)
AVAILABLE_SPACE=$(df -BG /mnt 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')
if [ "$AVAILABLE_SPACE" -lt 8 ]; then
    echo -e "\033[1;31m[ERROR] Need at least 8GB free space! Available: ${AVAILABLE_SPACE}G\033[0m"
    exit 1
fi

# Часть 1: Разметка диска с SWAP
echo -e "\n\033[1;32m[1] Partitioning disk ($DISK)\033[0m"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart primary fat32 1MiB "$EFI_SIZE"
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary linux-swap "$EFI_SIZE" "$SWAP_SIZE"
parted -s "$DISK" mkpart primary ext4 "$SWAP_SIZE" "$ROOT_SIZE"

# Форматирование
echo -e "\n\033[1;32m[2] Formatting partitions\033[0m"
mkfs.vfat -F32 "${DISK}p1"
mkswap "${DISK}p2"
mkfs.ext4 -F "${DISK}p3"

# Монтирование
mount "${DISK}p3" /mnt
mkdir -p /mnt/boot/efi
mount "${DISK}p1" /mnt/boot/efi
swapon "${DISK}p2"

# Часть 2: Установка базовой системы (минимум пакетов)
echo -e "\n\033[1;32m[3] Installing essential packages\033[0m"
pacman -Sy --noconfirm archlinux-keyring
pacstrap /mnt base linux linux-firmware linux-headers \
          grub efibootmgr networkmanager nano \
          git sudo bash-completion

# Генерация fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Часть 3: Настройка системы
arch-chroot /mnt /bin/bash <<EOF
# Настройка времени и локали
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# Сеть
echo "$HOSTNAME" > /etc/hostname
echo -e "127.0.0.1 localhost\n::1 localhost" >> /etc/hosts
systemctl enable NetworkManager

# Пользователь
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo -e "root:root\n$USERNAME:$USERNAME" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# Загрузчик
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Освобождаем место
pacman -Scc --noconfirm
rm -rf /var/cache/pacman/pkg/*
EOF

# Часть 4: Установка графической среды (после освобождения места)
arch-chroot /mnt /bin/bash <<'EOF'
# Установка yay
sudo -u $USERNAME git clone https://aur.archlinux.org/yay-bin.git /home/$USERNAME/yay-bin
cd /home/$USERNAME/yay-bin
sudo -u $USERNAME makepkg -si --noconfirm

# Основные пакеты Hyprland
sudo -u $USERNAME yay -S --noconfirm --needed \
    hyprland xdg-desktop-portal-hyprland \
    kitty swaybg swaylock \
    pipewire wireplumber pipewire-pulse \
    noto-fonts ttf-ubuntu-font-family

# Дополнительные компоненты (по мере необходимости)
sudo -u $USERNAME yay -S --noconfirm --needed \
    waybar rofi thunar \
    network-manager-applet \
    brightnessctl

# SDDM
pacman -S --noconfirm sddm
systemctl enable sddm

# Базовая конфигурация Hyprland
sudo -u $USERNAME mkdir -p /home/$USERNAME/.config/hypr
curl -sL https://raw.githubusercontent.com/hyprwm/Hyprland/main/example/hyprland.conf \
     -o /home/$USERNAME/.config/hypr/hyprland.conf

# Обои
sudo -u $USERNAME curl -o /home/$USERNAME/wallpaper.jpg \
    https://raw.githubusercontent.com/linuxdotexe/nordic-wallpapers/master/wallpapers/nordic-wallpaper.png

# Права
chown -R $USERNAME:$USERNAME /home/$USERNAME
EOF

# Завершение
echo -e "\n\033[1;32m[!] Installation successful!\033[0m"
echo "Disk usage:"
df -h /mnt
echo -e "\nReboot commands:"
echo "umount -R /mnt"
echo "swapoff ${DISK}p2"
echo "reboot"
