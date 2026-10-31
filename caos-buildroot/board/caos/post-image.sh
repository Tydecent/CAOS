#!/bin/bash
#
# Build the CAOS SD-card image.
#
# p1  CAOSBOOT  64 MiB FAT32, extlinux.conf + zImage + SYSLINUX/extlinux
# p2  CAOSROOT  squashfs read-only root filesystem
# p3  CAOSDATA  empty partition for a LUKS2 container created on first boot
#
# No root privilege is required: the FAT image is populated with mtools and
# SYSLINUX is installed with the unprivileged mtools-based installer.

set -euo pipefail

IMAGES_DIR="${1:?IMAGES_DIR argument required}"
BOARD_DIR="$(cd "$(dirname "$0")" && pwd)"

BOOT_IMG="$IMAGES_DIR/boot.vfat"
DISK_IMG="$IMAGES_DIR/sdcard.img"
ROOT_IMG="$IMAGES_DIR/rootfs.squashfs"
KERNEL_IMG="$IMAGES_DIR/bzImage"
EXTLINUX_SRC="$BOARD_DIR/extlinux.conf"
SYSLINUX_INSTALLER="${HOST_DIR:?HOST_DIR must be exported}/bin/caos-syslinux-installer"
MBR_BIN="$HOST_DIR/share/caos-syslinux/mbr.bin"

for required in "$ROOT_IMG" "$KERNEL_IMG" "$EXTLINUX_SRC" \
                "$SYSLINUX_INSTALLER" "$MBR_BIN"; do
    if [ ! -e "$required" ]; then
        echo "ERROR: required image input missing: $required" >&2
        exit 1
    fi
done

WORK_DIR="$BUILD_DIR/caos-image-work"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/boot/extlinux" "$WORK_DIR/genimage-root" "$WORK_DIR/genimage-tmp"
trap 'rm -rf "$WORK_DIR"' EXIT

install -m 0644 "$EXTLINUX_SRC" "$WORK_DIR/boot/extlinux/extlinux.conf"
install -m 0644 "$KERNEL_IMG" "$WORK_DIR/boot/zImage"

rm -f "$BOOT_IMG" "$DISK_IMG"

# Create the 64 MiB FAT32 boot partition with its volume label.
truncate -s 64M "$BOOT_IMG"
mkfs.vfat -F 32 -n CAOSBOOT "$BOOT_IMG" >/dev/null

# Populate it without mounting.  The extlinux.conf file lives in /extlinux and
# the kernel is at the FAT root.
mmd -i "$BOOT_IMG" ::/extlinux
mcopy -i "$BOOT_IMG" "$WORK_DIR/boot/extlinux/extlinux.conf" ::/extlinux/extlinux.conf
mcopy -i "$BOOT_IMG" "$WORK_DIR/boot/zImage" ::/zImage

# Install the SYSLINUX boot sector and ldlinux.sys/ldlinux.c32 into /extlinux.
# The installer talks through mtools and only needs write access to the image.
"$SYSLINUX_INSTALLER" --install --force --offset 0 --directory /extlinux "$BOOT_IMG"

# genimage writes the MBR/GPT hybrid table and the three partitions.
genimage \
    --rootpath "$WORK_DIR/genimage-root" \
    --tmppath "$WORK_DIR/genimage-tmp" \
    --inputpath "$IMAGES_DIR" \
    --outputpath "$IMAGES_DIR" \
    --config "$BOARD_DIR/genimage.cfg"

# genimage has written the partition table; place the 440-byte SYSLINUX MBR
# boot code in front of it without touching the partition table bytes.
dd if="$MBR_BIN" of="$DISK_IMG" bs=440 count=1 conv=notrunc status=none

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
echo "  boot.vfat size:        $(stat -c '%s' "$BOOT_IMG") bytes"
echo "  rootfs.squashfs size:  $(stat -c '%s' "$ROOT_IMG") bytes"
echo "  sdcard.img size:       $(stat -c '%s' "$DISK_IMG") bytes"
echo "  sdcard.img sha256:     $(sha256sum "$DISK_IMG" | cut -d' ' -f1)"
