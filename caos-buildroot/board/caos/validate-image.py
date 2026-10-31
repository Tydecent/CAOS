#!/usr/bin/env python3
"""Validate the CAOS disk image's pure-GPT/UEFI-ESP contract.

Usage: validate-image.py <sdcard.img> <boot.vfat>

This intentionally checks the on-disk structures rather than trusting the
genimage configuration.  It rejects a hybrid MBR, BIOS boot code, a missing
GPT backup header, non-ESP CAOSBOOT, wrong partition names/sizes, legacy GPT
bootable attributes, a non-FAT32 ESP, or a data partition with contents.
"""

from __future__ import annotations

import struct
import sys
import uuid
import zlib
from pathlib import Path
from typing import NoReturn

SECTOR = 512
MIB = 1024 * 1024
ESP_GUID = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
LINUX_GUID = "0fc63daf-8483-4772-8e79-3d69d8477de4"


def fail(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def guid_str(raw: bytes) -> str:
    return str(uuid.UUID(bytes_le=raw))


def read_gpt_header(blob: bytes, lba: int, label: str) -> dict[str, object]:
    offset = lba * SECTOR
    header = blob[offset : offset + SECTOR]
    if len(header) != SECTOR:
        fail(f"{label} GPT header is outside the image")
    if header[:8] != b"EFI PART":
        fail(f"{label} GPT header signature is missing at LBA {lba}")

    revision = struct.unpack_from("<I", header, 8)[0]
    if revision != 0x00010000:
        fail(f"{label} GPT revision is not 1.0: 0x{revision:08x}")

    header_size = struct.unpack_from("<I", header, 12)[0]
    if not 92 <= header_size <= SECTOR:
        fail(f"{label} GPT header size is invalid: {header_size}")

    stored_crc = struct.unpack_from("<I", header, 16)[0]
    checked = bytearray(header[:header_size])
    checked[16:20] = b"\0\0\0\0"
    if (zlib.crc32(checked) & 0xFFFFFFFF) != stored_crc:
        fail(f"{label} GPT header CRC is invalid")

    current_lba, backup_lba, first_usable, last_usable = struct.unpack_from(
        "<QQQQ", header, 24
    )
    if current_lba != lba:
        fail(f"{label} GPT current LBA is {current_lba}, expected {lba}")
    if backup_lba >= len(blob) // SECTOR:
        fail(f"{label} GPT backup LBA is outside the image: {backup_lba}")

    entry_lba = struct.unpack_from("<Q", header, 72)[0]
    entry_count = struct.unpack_from("<I", header, 80)[0]
    entry_size = struct.unpack_from("<I", header, 84)[0]
    entry_crc = struct.unpack_from("<I", header, 88)[0]
    if entry_count == 0 or entry_size < 128 or entry_size % 8:
        fail(f"{label} GPT partition entry geometry is invalid")
    if entry_lba + (entry_count * entry_size + SECTOR - 1) // SECTOR > (
        len(blob) // SECTOR
    ):
        fail(f"{label} GPT partition entry array is outside the image")

    return {
        "label": label,
        "current_lba": current_lba,
        "backup_lba": backup_lba,
        "first_usable": first_usable,
        "last_usable": last_usable,
        "entry_lba": entry_lba,
        "entry_count": entry_count,
        "entry_size": entry_size,
        "entry_crc": entry_crc,
        "disk_guid": guid_str(header[56:72]),
    }


def read_partitions(blob: bytes, gpt: dict[str, object]) -> list[dict[str, object]]:
    offset = int(gpt["entry_lba"]) * SECTOR
    count = int(gpt["entry_count"])
    size = int(gpt["entry_size"])
    raw = blob[offset : offset + count * size]
    if (zlib.crc32(raw) & 0xFFFFFFFF) != int(gpt["entry_crc"]):
        fail("GPT partition entry array CRC is invalid")

    partitions: list[dict[str, object]] = []
    for index in range(count):
        entry = raw[index * size : (index + 1) * size]
        type_raw = entry[:16]
        if type_raw == b"\0" * 16:
            continue
        first_lba, last_lba = struct.unpack_from("<QQ", entry, 32)
        attributes = struct.unpack_from("<Q", entry, 48)[0]
        name = (
            entry[56:128]
            .decode("utf-16-le", errors="strict")
            .split("\0", 1)[0]
        )
        partitions.append(
            {
                "index": index + 1,
                "type": guid_str(type_raw),
                "unique": guid_str(entry[16:32]),
                "first_lba": first_lba,
                "last_lba": last_lba,
                "sectors": last_lba - first_lba + 1,
                "attributes": attributes,
                "name": name,
            }
        )
    return partitions


def validate_mbr(blob: bytes) -> None:
    mbr = blob[:SECTOR]
    if len(mbr) != SECTOR:
        fail("image is too small to contain an MBR")
    if mbr[510:512] != b"\x55\xaa":
        fail("MBR boot signature is missing")
    if mbr[:440] != b"\0" * 440:
        fail("non-zero BIOS MBR boot code found in the first 440 bytes")

    entries = []
    for index in range(4):
        entry = mbr[446 + index * 16 : 446 + (index + 1) * 16]
        if entry != b"\0" * 16:
            entries.append(entry)
    if len(entries) != 1:
        fail(f"expected one protective MBR entry, found {len(entries)}")
    entry = entries[0]
    if entry[0] != 0:
        fail("protective MBR marks a partition active (0x80)")
    if entry[4] != 0xEE:
        fail(f"MBR is not a protective GPT MBR (type 0x{entry[4]:02x})")
    start_lba = struct.unpack_from("<I", entry, 8)[0]
    sectors = struct.unpack_from("<I", entry, 12)[0]
    if start_lba != 1 or sectors == 0:
        fail("protective MBR entry does not start at LBA 1")


def validate_vfat(path: Path) -> None:
    data = path.read_bytes()
    if len(data) < SECTOR:
        fail(f"ESP is too small: {path}")
    if data[510:512] != b"\x55\xaa":
        fail("ESP FAT boot sector signature is missing")
    if struct.unpack_from("<H", data, 11)[0] != SECTOR:
        fail("ESP does not use 512-byte FAT sectors")
    if struct.unpack_from("<H", data, 17)[0] != 0:
        fail("ESP is not FAT32 (non-zero FAT12/16 root entry count)")
    if data[82:90] != b"FAT32   ":
        fail(f"ESP filesystem type is not FAT32: {data[82:90]!r}")
    label = data[71:82].decode("ascii", errors="strict").rstrip(" \0")
    if label != "CAOSBOOT":
        fail(f"ESP FAT label is {label!r}, expected 'CAOSBOOT'")
    if len(data) != 64 * MIB:
        fail(f"ESP image is {len(data)} bytes, expected {64 * MIB}")


def main() -> None:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <sdcard.img> <boot.vfat>", file=sys.stderr)
        raise SystemExit(2)

    image_path = Path(sys.argv[1])
    vfat_path = Path(sys.argv[2])
    if not image_path.is_file():
        fail(f"image not found: {image_path}")
    if not vfat_path.is_file():
        fail(f"ESP image not found: {vfat_path}")

    blob = image_path.read_bytes()
    if len(blob) < 3 * MIB:
        fail("disk image is implausibly small")

    validate_mbr(blob)

    primary = read_gpt_header(blob, 1, "primary")
    backup = read_gpt_header(blob, int(primary["backup_lba"]), "backup")
    if int(backup["backup_lba"]) != 1:
        fail("GPT backup header does not point back to LBA 1")
    if primary["disk_guid"] != backup["disk_guid"]:
        fail("GPT primary and backup disk GUIDs differ")

    partitions = read_partitions(blob, primary)
    backup_partitions = read_partitions(blob, backup)
    if partitions != backup_partitions:
        fail("GPT primary and backup partition arrays differ")
    if len(partitions) != 3:
        fail(f"expected exactly 3 GPT partitions, found {len(partitions)}")

    expected = [
        ("CAOSBOOT", ESP_GUID, 64 * MIB),
        ("CAOSROOT", LINUX_GUID, 128 * MIB),
        ("CAOSDATA", LINUX_GUID, 128 * MIB),
    ]
    for part, (name, type_guid, size) in zip(partitions, expected):
        if part["name"] != name:
            fail(f"partition {part['index']} is named {part['name']!r}, expected {name!r}")
        if part["type"] != type_guid:
            fail(f"{name} has GPT type {part['type']}, expected {type_guid}")
        if part["sectors"] * SECTOR != size:
            fail(
                f"{name} has size {part['sectors'] * SECTOR} bytes, "
                f"expected {size}"
            )
        if int(part["first_lba"]) % 2048 != 0:
            fail(f"{name} is not aligned to 1 MiB")
        if not (
            int(primary["first_usable"]) <= int(part["first_lba"])
            <= int(part["last_lba"])
            <= int(primary["last_usable"])
        ):
            fail(f"{name} lies outside the GPT usable range")

    boot, rootfs, data = partitions
    if boot["attributes"] != 0:
        fail(f"CAOSBOOT has legacy GPT attributes set: 0x{int(boot['attributes']):x}")

    rootfs_offset = int(rootfs["first_lba"]) * SECTOR
    if blob[rootfs_offset : rootfs_offset + 4] != b"hsqs":
        fail("CAOSROOT does not start with a squashfs superblock")

    data_offset = int(data["first_lba"]) * SECTOR
    data_end = data_offset + int(data["sectors"]) * SECTOR
    chunk = 4 * MIB
    for offset in range(data_offset, data_end, chunk):
        if blob[offset : min(offset + chunk, data_end)].strip(b"\0"):
            fail("CAOSDATA is not blank; it must ship unformatted for first-boot LUKS2")

    validate_vfat(vfat_path)

    print(f"image:        {image_path} ({len(blob)} bytes)")
    print("table:        GPT (standard protective MBR, no BIOS boot code)")
    print(f"disk GUID:    {primary['disk_guid']}")
    for part, (name, type_guid, size) in zip(partitions, expected):
        print(
            f"partition {part['index']}: {name:<8} type={type_guid} "
            f"start={int(part['first_lba'])} sectors={int(part['sectors'])} "
            f"({size // MIB} MiB)"
        )
    print("ESP:          FAT32 label CAOSBOOT, 64 MiB")
    print("rootfs:       squashfs superblock present")
    print("CAOSDATA:     all zero, no LUKS header")


if __name__ == "__main__":
    main()
