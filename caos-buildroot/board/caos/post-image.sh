#!/bin/bash
#
# Build the CAOS SD-card image for pure x86_64 UEFI boot.
#
# p1  CAOSBOOT  64 MiB FAT32 EFI System Partition:
#                 \EFI\BOOT\BOOTX64.EFI, \EFI\BOOT\grub.cfg and \zImage
# p2  CAOSROOT  squashfs read-only root filesystem
# p3  CAOSDATA  empty partition for a LUKS2 container created on first boot
#
# No root privilege is required.  The ESP is populated with mtools without
# mounting it; genimage writes a standard GPT (with only its protective MBR)
# and no BIOS boot code is installed anywhere.

set -euo pipefail

IMAGES_DIR="${1:?IMAGES_DIR argument required}"
BOARD_DIR="$(cd "$(dirname "$0")" && pwd)"

BOOT_IMG="$IMAGES_DIR/boot.vfat"
DISK_IMG="$IMAGES_DIR/sdcard.img"
ROOT_IMG="$IMAGES_DIR/rootfs.squashfs"
KERNEL_IMG="$IMAGES_DIR/bzImage"
GRUB_EFI="$IMAGES_DIR/efi-part/EFI/BOOT/bootx64.efi"
GRUB_CFG="$BOARD_DIR/grub.cfg"

for required in "$ROOT_IMG" "$KERNEL_IMG" "$GRUB_EFI" "$GRUB_CFG"; do
    if [ ! -e "$required" ]; then
        echo "ERROR: required image input missing: $required" >&2
        exit 1
    fi
done

# Keep the Buildroot efi-part tree usable as a standalone ESP staging tree:
# replace its generic grub.cfg with the CAOS menu before the FAT image is made.
install -m 0644 "$GRUB_CFG" "$IMAGES_DIR/efi-part/EFI/BOOT/grub.cfg"

WORK_DIR="${BUILD_DIR:?BUILD_DIR must be exported}/caos-image-work"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/genimage-root" "$WORK_DIR/genimage-tmp"
trap 'rm -rf "$WORK_DIR"' EXIT

rm -f "$BOOT_IMG" "$DISK_IMG"

# Create the 64 MiB FAT32 EFI System Partition.  The volume label is also the
# handle used by the embedded GRUB script to locate the ESP on any disk number.
truncate -s 64M "$BOOT_IMG"
mkfs.vfat -F 32 -n CAOSBOOT "$BOOT_IMG" >/dev/null

# Populate the ESP without mounting.  UEFI removable-media boot uses the fixed
# path \EFI\BOOT\BOOTX64.EFI; GRUB loads the adjacent grub.cfg, which then boots
# the kernel from the FAT root.
mmd -i "$BOOT_IMG" ::/EFI
mmd -i "$BOOT_IMG" ::/EFI/BOOT
mcopy -i "$BOOT_IMG" "$GRUB_EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$BOOT_IMG" "$GRUB_CFG" ::/EFI/BOOT/grub.cfg
mcopy -i "$BOOT_IMG" "$KERNEL_IMG" ::/zImage

# genimage writes a pure GPT image.  Genimage's protective MBR is not a BIOS
# boot path and must not be confused with the previous hybrid MBR/GPT layout.
genimage \
    --rootpath "$WORK_DIR/genimage-root" \
    --tmppath "$WORK_DIR/genimage-tmp" \
    --inputpath "$IMAGES_DIR" \
    --outputpath "$IMAGES_DIR" \
    --config "$BOARD_DIR/genimage.cfg"

sync

if [ ! -s "$DISK_IMG" ]; then
    echo "ERROR: sdcard.img was not generated" >&2
    exit 1
fi
if [ ! -s "$ROOT_IMG" ]; then
    echo "ERROR: rootfs.squashfs is empty" >&2
    exit 1
fi

echo "CAOS post-image: generated $DISK_IMG"
echo "  boot scheme:           x86_64 UEFI (GRUB EFI + GPT/ESP)"
echo "  boot.vfat size:        $(stat -c '%s' "$BOOT_IMG") bytes"
echo "  rootfs.squashfs size:  $(stat -c '%s' "$ROOT_IMG") bytes"
echo "  sdcard.img size:       $(stat -c '%s' "$DISK_IMG") bytes"
echo "  sdcard.img sha256:     $(sha256sum "$DISK_IMG" | cut -d' ' -f1)"
