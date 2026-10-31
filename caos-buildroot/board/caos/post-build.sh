#!/bin/bash
#
# Buildroot post-build checks and final permissions for CAOS.
# Runs as the normal build user, before the filesystem image is packed.

set -euo pipefail

TARGET_DIR="${1:?TARGET_DIR argument required}"

echo "CAOS post-build: validating target root filesystem"

install -d -m 0755 "$TARGET_DIR/etc/caos-ca"
install -d -m 0755 "$TARGET_DIR/mnt/ca-data"
install -d -m 0755 "$TARGET_DIR/run"
install -d -m 0755 "$TARGET_DIR/var"

# Configuration is a read-only contract.
chmod 0444 "$TARGET_DIR/etc/caos-ca/config.toml"
chmod 0644 "$TARGET_DIR/etc/fstab"
chmod 0644 "$TARGET_DIR/etc/inittab"
chmod 0755 "$TARGET_DIR/etc/init.d/S10caos-data"
chmod 0755 "$TARGET_DIR/etc/init.d/S20caos-ca"

if [ ! -f "$TARGET_DIR/usr/bin/caos-ca" ]; then
    echo "ERROR: /usr/bin/caos-ca was not copied into the overlay." >&2
    echo "Run the Rust build stage of build.sh first." >&2
    exit 1
fi
chmod 0755 "$TARGET_DIR/usr/bin/caos-ca"

if command -v file >/dev/null 2>&1; then
    FILE_OUTPUT=$(file "$TARGET_DIR/usr/bin/caos-ca")
    if ! printf '%s\n' "$FILE_OUTPUT" | grep -q 'statically linked'; then
        echo "ERROR: /usr/bin/caos-ca is not statically linked." >&2
        echo "$FILE_OUTPUT" >&2
        exit 1
    fi
fi

grep -q '^ca_name = "CAOS"$' "$TARGET_DIR/etc/caos-ca/config.toml" || {
    echo "ERROR: unexpected ca_name in /etc/caos-ca/config.toml" >&2
    exit 1
}
grep -q '^data_dir = "/mnt/ca-data"$' "$TARGET_DIR/etc/caos-ca/config.toml" || {
    echo "ERROR: unexpected data_dir in /etc/caos-ca/config.toml" >&2
    exit 1
}

# The caos account and its home directory are created later, by Buildroot's
# mkusers step inside the fakeroot environment.  post-fakeroot.sh verifies the
# resulting UID/GID and ownership there.

# Buildroot's makedevs re-creates /etc/network/if-*.d from the generic device
# table during the fakeroot step, so those empty directories are removed in
# post-fakeroot.sh after makedevs has run.

# Enforce the air-gap policy at image level as well as in the kernel config.
# These names are the explicitly forbidden target packages and the BusyBox
# applets that would otherwise provide equivalent userland tools.
for forbidden in \
    ssh sshd curl wget \
    wpa_supplicant wpa_cli dhcpcd dhclient udhcpc udhcpd dhcpd \
    ip ifconfig route netstat nslookup \
    telnet tftp ftpget ftpput \
    ping ping6 traceroute traceroute6 \
    nc netcat; do
    MATCH=$(find "$TARGET_DIR" \( -type f -o -type l \) -name "$forbidden" -print -quit)
    if [ -n "$MATCH" ]; then
        echo "ERROR: forbidden network command present in image: $MATCH" >&2
        exit 1
    fi
done

# No service should be able to start a network daemon even if a future kernel
# accidentally re-enables CONFIG_NET.
if find "$TARGET_DIR/etc/init.d" -maxdepth 1 -type f \
    \( -name 'S*ssh*' -o -name 'S*network*' -o -name 'S*networking*' \
       -o -name 'S*wpa*' -o -name 'S*dhcp*' \) -print -quit | grep -q .; then
    echo "ERROR: network-related init script found in image" >&2
    exit 1
fi

echo "CAOS post-build: target validation complete"
