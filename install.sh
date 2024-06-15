#!/bin/bash

set -e
trap 'echo "An error occurred. Exiting..."; exit 1;' ERR
trap 'echo "Script interrupted. Exiting..."; exit 1;' SIGINT

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit 1
fi

# Prompt for user inputs
while true; do
  read -p "Enter the disk to install Arch Linux on (e.g., /dev/sda): " DISK
  if [ ! -b "${DISK}" ]; then
    echo "The specified disk ${DISK} does not exist. Please try again."
  else
    break
  fi
done

read -p "Enter the hostname for this installation: " HOSTNAME
read -p "Enter the locale (e.g., en_US.UTF-8): " LOCALE
read -p "Enter the timezone (e.g., America/Argentina/Buenos_Aires): " TIMEZONE
read -p "Enter username for the new user: " USER_NAME

# Prompt for passwords
while true; do
  read -s -p "Enter password for ${USER_NAME}: " USER_PASSWORD
  echo
  read -s -p "Confirm password: " USER_PASSWORD_CONFIRM
  echo
  if [ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]; then
    echo "Passwords do not match. Please try again."
  else
    break
  fi
done

# Ensure the disk is correct
echo "WARNING: The selected disk is ${DISK}. This will delete all data on this disk."
read -p "Are you sure you want to continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Operation cancelled."
  exit 1
fi

# Update system clock
timedatectl set-ntp true

# Configure the fastest mirrors
pacman -Sy --noconfirm reflector rsync
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
reflector --country Brazil --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syy

# Partition the disk
EFI_PARTITION="${DISK}1"
ROOT_PARTITION="${DISK}2"

wipefs -a "${DISK}"
sgdisk -o "${DISK}"
sgdisk -n 1:0:+512M -t 1:ef00 "${DISK}"   # EFI partition
sgdisk -n 2:0:0 -t 2:8300 "${DISK}"       # Linux filesystem

# Setup encryption with LUKS and TPM
echo -n "${USER_PASSWORD}" | cryptsetup -y --use-random luksFormat "${ROOT_PARTITION}"
echo -n "${USER_PASSWORD}" | cryptsetup open --type luks "${ROOT_PARTITION}" cryptroot

# Format the filesystems
mkfs.vfat -F32 "${EFI_PARTITION}"
mkfs.btrfs /dev/mapper/cryptroot

# Create Btrfs subvolumes
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
umount /mnt

# Mount the filesystems
mount -o noatime,compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{boot,home,var,.snapshots}

mount -o noatime,compress=zstd,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o noatime,compress=zstd,subvol=@var /dev/mapper/cryptroot /mnt/var
mount -o noatime,compress=zstd,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount "${EFI_PARTITION}" /mnt/boot

# Install essential packages
pacstrap /mnt base linux linux-lts linux-firmware util-linux sudo btrfs-progs intel-ucode intel-media-driver nvidia nvidia-lts nvidia-utils nvidia-settings tpm2-tools clevis lvm2 grub grub-efi-x86_64 efibootmgr zram-generator

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Change root into the new system
arch-chroot /mnt /bin/bash <<EOF

# Set the timezone
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# Set the locale
echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Set the hostname
echo "${HOSTNAME}" > /etc/hostname

# Configure hosts file
cat <<EOT > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOT

# Initramfs
cat <<EOT > /etc/mkinitcpio.conf
MODULES=(btrfs tpm)
BINARIES=()
FILES=()
HOOKS=(base udev autodetect modconf block encrypt filesystems)
EOT

mkinitcpio -P

# Create a new user and set the password
useradd -m -G wheel -s /bin/bash ${USER_NAME}
echo "${USER_NAME}:${USER_PASSWORD}" | chpasswd

# Give the new user sudo privileges
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Install additional packages
pacman -S --noconfirm networkmanager network-manager-applet dialog wpa_supplicant mtools dosfstools reflector base-devel linux-headers avahi xdg-user-dirs xdg-utils gvfs gvfs-smb nfs-utils inetutils dnsutils bluez bluez-utils alsa-utils pipewire pipewire-alsa pipewire-pulse pipewire-jack bash-completion openssh timeshift rsync acpi acpi_call tlp dnsmasq ipset ufw flatpak sof-firmware nss-mdns acpid os-prober ntfs-3g wget git gcc neovim btop hyprland xdg-desktop-portal xdg-desktop-portal-hyprland kitty polkit-kde-agent qt5-wayland qt6-wayland rofi-wayland firefox vlc obs-studio grim slurp obsidian

# Enable services
systemctl enable NetworkManager bluetooth systemd-timesyncd avahi-daemon tlp reflector.timer fstrim.timer ufw acpid

# Configure ZRAM
cat <<EOT > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
EOT

# Install GRUB
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# TPM2 automatic unlock
echo "Adding TPM2 unlock key to LUKS..."
echo -n "${USER_PASSWORD}" | clevis luks bind -d /dev/disk/by-uuid/$(blkid -s UUID -o value "${ROOT_PARTITION}") tpm2 '{"pcr_ids":"7"}'

# Lock the root account
passwd -l root

EOF

# Unmount filesystems
umount -R /mnt

# Close cryptroot
cryptsetup close cryptroot

# Sync and reboot
echo "Installation complete. The system will reboot in 5 seconds."
sleep 5
sync
reboot
