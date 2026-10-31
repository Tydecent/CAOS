#!/usr/bin/env bash
#
# CAOS one-shot build:
#   1. verify/install the Rust musl target
#   2. build the static caos-ca binary and install it into the rootfs overlay
#   3. configure and build the Buildroot UEFI/GPT image
#   4. validate the UEFI ESP, standard GPT layout and air-gap kernel policy
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
BUILDROOT_DIR="${BUILDROOT_DIR:-$PROJECT_DIR/../buildroot-2026.08.1}"
BR2_EXTERNAL_DIR="$PROJECT_DIR/caos-buildroot"
RUST_DIR="$PROJECT_DIR/caos-ca"
OUTPUT_DIR="$PROJECT_DIR/output"
DOWNLOAD_DIR="$OUTPUT_DIR/dl"
JOBS="${JOBS:-$(nproc)}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: JOBS must be a positive integer" >&2; exit 1; }
RUST_TARGET="x86_64-unknown-linux-musl"
RUST_BINARY="$RUST_DIR/target/$RUST_TARGET/release/caos-ca"
OVERLAY_BINARY="$BR2_EXTERNAL_DIR/board/caos/rootfs-overlay/usr/bin/caos-ca"
SDCARD_IMAGE="$OUTPUT_DIR/images/sdcard.img"
BOOT_IMAGE="$OUTPUT_DIR/images/boot.vfat"
ROOTFS_IMAGE="$OUTPUT_DIR/images/rootfs.squashfs"
EFI_IMAGE="$OUTPUT_DIR/images/efi-part/EFI/BOOT/bootx64.efi"
HOST_MCOPY="$OUTPUT_DIR/host/bin/mcopy"
HOST_MDIR="$OUTPUT_DIR/host/bin/mdir"
HOST_GRUB_SCRIPT_CHECK="$OUTPUT_DIR/host/bin/grub-script-check"
VALIDATOR="$BR2_EXTERNAL_DIR/board/caos/validate-image.py"
BUILD_LOG="$OUTPUT_DIR/build.log"

log_stage() {
    printf '\n[CAOS] %s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

log_stage "Stage 0/5: preflight checks"
[ -d "$BUILDROOT_DIR" ] || fail "Buildroot tree not found at $BUILDROOT_DIR"
[ -f "$BUILDROOT_DIR/Makefile" ] || fail "$BUILDROOT_DIR is not a Buildroot tree"
[ -d "$BR2_EXTERNAL_DIR" ] || fail "BR2_EXTERNAL tree missing at $BR2_EXTERNAL_DIR"
command -v rustup >/dev/null 2>&1 || fail "rustup is not installed"
command -v cargo >/dev/null 2>&1 || fail "cargo is not installed"
command -v file >/dev/null 2>&1 || fail "file(1) is required for static-link validation"
command -v make >/dev/null 2>&1 || fail "GNU make is required"
command -v nproc >/dev/null 2>&1 || fail "nproc is required"
command -v musl-gcc >/dev/null 2>&1 || fail "musl-gcc is required to build ring for x86_64-unknown-linux-musl"
command -v unsquashfs >/dev/null 2>&1 || fail "unsquashfs is required for rootfs validation"
command -v python3 >/dev/null 2>&1 || fail "python3 is required to validate the GPT/ESP image layout"

if ! rustup target list --installed | grep -qx "$RUST_TARGET"; then
    log_stage "Installing Rust target $RUST_TARGET"
    rustup target add "$RUST_TARGET"
fi
rustup target list --installed | grep -qx "$RUST_TARGET" \
    || fail "Rust target $RUST_TARGET is still not installed"
echo "[CAOS] Rust target present: $RUST_TARGET"

mkdir -p "$OUTPUT_DIR" "$DOWNLOAD_DIR" "$(dirname "$OVERLAY_BINARY")"

log_stage "Stage 1/5: building static caos-ca"
(
    cd "$RUST_DIR"
    cargo build --release --target "$RUST_TARGET" 2>&1 | tee "$OUTPUT_DIR/rust-build.log"
)
[ -x "$RUST_BINARY" ] || fail "Rust build did not produce $RUST_BINARY"
FILE_OUTPUT="$(file "$RUST_BINARY")"
case "$FILE_OUTPUT" in
    *"statically linked"*) ;;
    *) fail "caos-ca is not statically linked: $FILE_OUTPUT" ;;
esac
echo "[CAOS] static binary: $FILE_OUTPUT"

if cargo clippy --version >/dev/null 2>&1; then
    echo "[CAOS] running cargo clippy -D warnings"
    (
        cd "$RUST_DIR"
        cargo clippy --target "$RUST_TARGET" -- -D warnings 2>&1 | tee "$OUTPUT_DIR/clippy.log"
    )
else
    echo "[CAOS] WARNING: cargo clippy is unavailable; skipping lint stage"
fi

install -D -m 0755 "$RUST_BINARY" "$OVERLAY_BINARY"
echo "[CAOS] installed overlay binary: $OVERLAY_BINARY"

log_stage "Stage 2/5: configuring Buildroot (O=$OUTPUT_DIR)"
(
    cd "$BUILDROOT_DIR"
    BR2_DL_DIR="$DOWNLOAD_DIR" \
        make O="$OUTPUT_DIR" BR2_EXTERNAL="$BR2_EXTERNAL_DIR" caos_defconfig
)
if [ ! -f "$OUTPUT_DIR/.config" ]; then
    fail "Buildroot configuration was not created"
fi
echo "[CAOS] defconfig complete"

log_stage "Stage 3/5: building Buildroot image with -j$JOBS (this is the long stage)"
(
    cd "$BUILDROOT_DIR"
    BR2_DL_DIR="$DOWNLOAD_DIR" \
        make O="$OUTPUT_DIR" BR2_EXTERNAL="$BR2_EXTERNAL_DIR" -j"$JOBS" \
        2>&1 | tee "$BUILD_LOG"
)

log_stage "Stage 4/5: final image checks"

[ -s "$SDCARD_IMAGE" ] || fail "$SDCARD_IMAGE was not generated"
[ -s "$BOOT_IMAGE" ] || fail "$BOOT_IMAGE was not generated"
[ -s "$ROOTFS_IMAGE" ] || fail "$ROOTFS_IMAGE was not generated"
[ -s "$EFI_IMAGE" ] || fail "GRUB EFI application was not generated: $EFI_IMAGE"
[ -x "$HOST_MCOPY" ] || fail "host mcopy is missing: $HOST_MCOPY"
[ -x "$HOST_MDIR" ] || fail "host mdir is missing: $HOST_MDIR"
[ -x "$HOST_GRUB_SCRIPT_CHECK" ] || fail "host grub-script-check is missing: $HOST_GRUB_SCRIPT_CHECK"
[ -x "$VALIDATOR" ] || fail "image layout validator is missing: $VALIDATOR"

"$HOST_GRUB_SCRIPT_CHECK" "$BR2_EXTERNAL_DIR/board/caos/grub-builtin.cfg"
"$HOST_GRUB_SCRIPT_CHECK" "$BR2_EXTERNAL_DIR/board/caos/grub.cfg"
echo "[CAOS] GRUB embedded and ESP scripts parse successfully"

mkdir -p "$OUTPUT_DIR/verification"
python3 "$VALIDATOR" "$SDCARD_IMAGE" "$BOOT_IMAGE" \
    | tee "$OUTPUT_DIR/verification/image-layout.txt"

EFI_FILE_OUTPUT="$(file "$EFI_IMAGE")"
printf '%s\n' "$EFI_FILE_OUTPUT" | grep -q 'PE32+ executable' \
    || fail "GRUB EFI application is not a PE32+ executable: $EFI_FILE_OUTPUT"
printf '%s\n' "$EFI_FILE_OUTPUT" | grep -qi 'EFI.*application' \
    || fail "GRUB EFI application is not identified as an EFI application: $EFI_FILE_OUTPUT"
# The embedded script must locate the ESP by label and chain-load grub.cfg.
grep -aFq 'search --no-floppy --label CAOSBOOT --set=root' "$EFI_IMAGE" \
    || fail "BOOTX64.EFI does not embed the CAOS ESP search script"
grep -aFq 'configfile ($root)/EFI/BOOT/grub.cfg' "$EFI_IMAGE" \
    || fail "BOOTX64.EFI does not embed the grub.cfg loader"
cmp -s "$OUTPUT_DIR/images/efi-part/EFI/BOOT/grub.cfg" \
    "$BR2_EXTERNAL_DIR/board/caos/grub.cfg" \
    || fail "output efi-part/EFI/BOOT/grub.cfg is not the CAOS boot menu"

ESP_CHECK_DIR="$OUTPUT_DIR/verification/esp"
rm -rf "$ESP_CHECK_DIR"
mkdir -p "$ESP_CHECK_DIR"
# Validate the actual ESP embedded in the final image, not just the standalone
# boot.vfat that is used as a convenience input during image assembly.
dd if="$SDCARD_IMAGE" of="$ESP_CHECK_DIR/disk-esp.raw" bs=512 skip=2048 count=131072 status=none
cmp -s "$ESP_CHECK_DIR/disk-esp.raw" "$BOOT_IMAGE" \
    || fail "CAOSBOOT partition in sdcard.img does not match boot.vfat"

"$HOST_MCOPY" -i "$BOOT_IMAGE" ::/EFI/BOOT/BOOTX64.EFI "$ESP_CHECK_DIR/BOOTX64.EFI" >/dev/null
"$HOST_MCOPY" -i "$BOOT_IMAGE" ::/EFI/BOOT/grub.cfg "$ESP_CHECK_DIR/grub.cfg" >/dev/null
"$HOST_MCOPY" -i "$BOOT_IMAGE" ::/zImage "$ESP_CHECK_DIR/zImage" >/dev/null
cmp -s "$ESP_CHECK_DIR/BOOTX64.EFI" "$EFI_IMAGE" \
    || fail "ESP BOOTX64.EFI does not match the Buildroot GRUB EFI image"
cmp -s "$ESP_CHECK_DIR/zImage" "$OUTPUT_DIR/images/bzImage" \
    || fail "ESP zImage does not match output/images/bzImage"

GRUB_APPEND='linux /zImage console=tty0 console=ttyS0,115200 root=PARTLABEL=CAOSROOT rootfstype=squashfs ro rootwait'
grep -Fq "$GRUB_APPEND" "$ESP_CHECK_DIR/grub.cfg" \
    || fail "ESP grub.cfg does not contain the required CAOS kernel command line"
cmp -s "$ESP_CHECK_DIR/grub.cfg" "$BR2_EXTERNAL_DIR/board/caos/grub.cfg" \
    || fail "ESP grub.cfg is not the CAOS boot menu"

"$HOST_MDIR" -i "$BOOT_IMAGE" -b -/ :: >"$OUTPUT_DIR/verification/esp-files.txt"
if grep -Eiq '(^|/)(extlinux|ldlinux[^/]*|syslinux[^/]*|mbr[^/]*)(/|$)' "$OUTPUT_DIR/verification/esp-files.txt"; then
    fail "legacy BIOS/SYSLINUX artifacts found on the UEFI ESP"
fi
# UEFI removable-media default path, with the kernel and boot menu adjacent.
grep -q '^::/EFI/BOOT/BOOTX64\.EFI$' "$OUTPUT_DIR/verification/esp-files.txt" \
    || fail "UEFI default boot file is not at ::/EFI/BOOT/BOOTX64.EFI"
grep -q '^::/EFI/BOOT/grub\.cfg$' "$OUTPUT_DIR/verification/esp-files.txt" \
    || fail "GRUB config is not at ::/EFI/BOOT/grub.cfg"
grep -q '^::/zImage$' "$OUTPUT_DIR/verification/esp-files.txt" \
    || fail "kernel is not at ::/zImage"
echo "[CAOS] pure-GPT ESP and UEFI default boot path verified"

KERNEL_CONFIGS=()
while IFS= read -r -d '' config; do
    KERNEL_CONFIGS+=("$config")
done < <(find "$OUTPUT_DIR/build" -maxdepth 2 -type f -path '*/linux-*/.config' -print0)
if [ "${#KERNEL_CONFIGS[@]}" -eq 0 ]; then
    fail "no output/build/linux-*/.config found"
fi
KERNEL_CONFIG="${KERNEL_CONFIGS[0]}"
grep -qx '# CONFIG_NET is not set' "$KERNEL_CONFIG" \
    || fail "$KERNEL_CONFIG does not contain '# CONFIG_NET is not set'"
grep -qx '# CONFIG_MODULES is not set' "$KERNEL_CONFIG" \
    || fail "$KERNEL_CONFIG does not contain '# CONFIG_MODULES is not set'"
grep -qx 'CONFIG_STRICT_KERNEL_RWX=y' "$KERNEL_CONFIG" \
    || fail "$KERNEL_CONFIG does not contain CONFIG_STRICT_KERNEL_RWX=y"
grep -qx 'CONFIG_RANDOMIZE_BASE=y' "$KERNEL_CONFIG" \
    || fail "$KERNEL_CONFIG does not contain CONFIG_RANDOMIZE_BASE=y"
# The kernel command line uses root=PARTLABEL=CAOSROOT on a GPT-only disk.
grep -qx 'CONFIG_EFI_PARTITION=y' "$KERNEL_CONFIG" \
    || fail "$KERNEL_CONFIG does not contain CONFIG_EFI_PARTITION=y"
grep -qx '# CONFIG_MSDOS_PARTITION is not set' "$KERNEL_CONFIG" \
    || fail "$KERNEL_CONFIG does not contain '# CONFIG_MSDOS_PARTITION is not set'"
echo "[CAOS] kernel air-gap and GPT-only policy verified in $KERNEL_CONFIG"

UNSQUASH_LIST="$OUTPUT_DIR/unsquashfs-list.txt"
unsquashfs -l "$ROOTFS_IMAGE" >"$UNSQUASH_LIST"
grep -q '^squashfs-root/usr/bin/caos-ca$' "$UNSQUASH_LIST" \
    || fail "/usr/bin/caos-ca is missing from rootfs.squashfs"
grep -q '^squashfs-root/etc/caos-ca/config.toml$' "$UNSQUASH_LIST" \
    || fail "/etc/caos-ca/config.toml is missing from rootfs.squashfs"
grep -q '^squashfs-root/etc/init.d/S10caos-data$' "$UNSQUASH_LIST" \
    || fail "S10caos-data is missing from rootfs.squashfs"
grep -q '^squashfs-root/etc/init.d/S20caos-ca$' "$UNSQUASH_LIST" \
    || fail "S20caos-ca is missing from rootfs.squashfs"
CAOS_BIN_LINE=$(unsquashfs -lln "$ROOTFS_IMAGE" | grep ' squashfs-root/usr/bin/caos-ca$' || true)
case "$CAOS_BIN_LINE" in
    "-rwxr-xr-x 0/0 "*)
        ;;
    *)
        fail "image caos-ca is not root:root mode 0755: $CAOS_BIN_LINE"
        ;;
esac
CAOS_DATA_LINE=$(unsquashfs -lln "$ROOTFS_IMAGE" | grep ' squashfs-root/mnt/ca-data$' || true)
case "$CAOS_DATA_LINE" in
    "drwx------ 1000/1000 "*)
        ;;
    *)
        fail "image /mnt/ca-data is not caos:caos (1000:1000) mode 0700: $CAOS_DATA_LINE"
        ;;
esac
CAOS_CONFIG_LINE=$(unsquashfs -lln "$ROOTFS_IMAGE" | grep ' squashfs-root/etc/caos-ca/config.toml$' || true)
case "$CAOS_CONFIG_LINE" in
    "-r--r--r-- 0/0 "*)
        ;;
    *)
        fail "image config.toml is not root:root mode 0444: $CAOS_CONFIG_LINE"
        ;;
esac
echo "[CAOS] rootfs overlay checks passed"

for forbidden in sshd curl wget wpa_supplicant ip ifconfig udhcpc route; do
    if grep -Eq "(^|/)${forbidden}$" "$UNSQUASH_LIST"; then
        fail "forbidden network command present in rootfs: $forbidden"
    fi
done
echo "[CAOS] no forbidden network commands in rootfs"

{
    echo "boot scheme: UEFI only (GRUB 2 x86_64-efi, standard GPT, ESP CAOSBOOT)"
    echo "GRUB EFI file(1): $EFI_FILE_OUTPUT"
    echo
    echo "caos-ca file(1): $FILE_OUTPUT"
    echo
    echo "kernel config: $KERNEL_CONFIG"
    grep -E '^(# CONFIG_(NET|INET|IPV6|PACKET|MODULES|MSDOS_PARTITION) is not set|CONFIG_(STRICT_KERNEL_RWX|STRICT_MODULE_RWX|RANDOMIZE_BASE|EFI_PARTITION)=y)$' \
        "$KERNEL_CONFIG" || true
    echo
    echo "GPT/ESP layout validation:"
    cat "$OUTPUT_DIR/verification/image-layout.txt"
    echo
    echo "ESP directory listing:"
    cat "$OUTPUT_DIR/verification/esp-files.txt"
    echo
    echo "ESP grub.cfg:"
    cat "$ESP_CHECK_DIR/grub.cfg"
    echo
    echo "rootfs.squashfs caos-ca listing:"
    unsquashfs -ll "$ROOTFS_IMAGE" | grep -E '/usr/bin/caos-ca$' || true
    echo
    echo "images:"
    ls -lh "$OUTPUT_DIR/images"
} >"$OUTPUT_DIR/verification/summary.txt"

log_stage "Stage 5/5: build artifacts"
find "$OUTPUT_DIR/images" -maxdepth 1 -type f -printf '%f\t%s bytes\n' | sort | while IFS=$'\t' read -r name size; do
    printf '  %-32s %s\n' "$name" "$size"
done
echo
echo "[CAOS] artifact verification summary: $OUTPUT_DIR/verification/summary.txt"
echo "[CAOS] Buildroot log: $BUILD_LOG"
echo "[CAOS] sdcard image ready: $SDCARD_IMAGE"
echo "[CAOS] No UEFI boot test was performed; image contents were validated statically."
