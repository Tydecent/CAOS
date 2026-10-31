#!/bin/bash
#
# Runs inside Buildroot's fakeroot environment.  This is where ownership can
# be recorded in the squashfs image even though the build itself is executed
# by an unprivileged user.

set -euo pipefail

TARGET_DIR="${1:?TARGET_DIR argument required}"

# mkusers and makedevs have already run at this point, so the fixed identity
# can be checked and the generic empty network directories can be removed
# without them being re-created again.
if ! grep -q '^caos:x:1000:1000:' "$TARGET_DIR/etc/passwd"; then
    echo "ERROR: caos user with UID/GID 1000 is missing from /etc/passwd" >&2
    exit 1
fi
if ! grep -q '^caos:x:1000:' "$TARGET_DIR/etc/group"; then
    echo "ERROR: caos group with GID 1000 is missing from /etc/group" >&2
    exit 1
fi

# The executable shipped in the image is owned by root and mode 0755.
chown 0:0 "$TARGET_DIR/usr/bin/caos-ca"
chmod 0755 "$TARGET_DIR/usr/bin/caos-ca"

# No network configuration or network service is shipped in this image.
rm -rf "$TARGET_DIR/etc/network"

# Read-only configuration belongs to root.
chown 0:0 "$TARGET_DIR/etc/caos-ca/config.toml"
chmod 0444 "$TARGET_DIR/etc/caos-ca/config.toml"

# The caos account owns only its intended data mount point and runtime area.
chown 0:0 "$TARGET_DIR/mnt"
chown 1000:1000 "$TARGET_DIR/mnt/ca-data"
chmod 0700 "$TARGET_DIR/mnt/ca-data"
chown root:root "$TARGET_DIR/run"
chmod 0755 "$TARGET_DIR/run"

# /etc/shadow and audit state must not be group/world-accessible.
chown 0:0 "$TARGET_DIR/etc/shadow"
chmod 0600 "$TARGET_DIR/etc/shadow"
