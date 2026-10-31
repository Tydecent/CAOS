#!/usr/bin/env bash
#
# CAOS one-shot build:
#   1. verify/install the Rust musl target
#   2. build the static caos-ca binary and install it into the rootfs overlay
#   3. configure and build the Buildroot image
#   4. validate the required artifacts and air-gap kernel setting
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
BUILDROOT_DIR="${BUILDROOT_DIR:-$PROJECT_DIR/../buildroot-2026.08.1}"
BR2_EXTERNAL_DIR="$PROJECT_DIR/caos-buildroot"
RUST_DIR="$PROJECT_DIR/caos-ca"
OUTPUT_DIR="$PROJECT_DIR/output"
DOWNLOAD_DIR="$OUTPUT_DIR/dl"
RUST_TARGET="x86_64-unknown-linux-musl"
RUST_BINARY="$RUST_DIR/target/$RUST_TARGET/release/caos-ca"
OVERLAY_BINARY="$BR2_EXTERNAL_DIR/board/caos/rootfs-overlay/usr/bin/caos-ca"
SDCARD_IMAGE="$OUTPUT_DIR/images/sdcard.img"
ROOTFS_IMAGE="$OUTPUT_DIR/images/rootfs.squashfs"
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

log_stage "Stage 3/5: building Buildroot image (this is the long stage)"
(
    cd "$BUILDROOT_DIR"
    BR2_DL_DIR="$DOWNLOAD_DIR" \
        make O="$OUTPUT_DIR" BR2_EXTERNAL="$BR2_EXTERNAL_DIR" -j"$(nproc)" \
        2>&1 | tee "$BUILD_LOG"
)

log_stage "Stage 4/5: final image checks"

[ -s "$SDCARD_IMAGE" ] || fail "$SDCARD_IMAGE was not generated"
[ -s "$ROOTFS_IMAGE" ] || fail "$ROOTFS_IMAGE was not generated"

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
# The kernel command line uses root=PARTLABEL=CAOSROOT.
grep -qx 'CONFIG_EFI_PARTITION=y' "$KERNEL_CONFIG" \
    || fail "$KERNEL_CONFIG does not contain CONFIG_EFI_PARTITION=y"
echo "[CAOS] kernel air-gap policy verified in $KERNEL_CONFIG"

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

mkdir -p "$OUTPUT_DIR/verification"
{
    echo "caos-ca file(1): $FILE_OUTPUT"
    echo
    echo "kernel config: $KERNEL_CONFIG"
    grep -E '^(# CONFIG_(NET|INET|IPV6|PACKET|MODULES) is not set|CONFIG_(STRICT_KERNEL_RWX|STRICT_MODULE_RWX|RANDOMIZE_BASE)=y)$' \
        "$KERNEL_CONFIG" || true
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
echo "[CAOS] No boot test was performed."
