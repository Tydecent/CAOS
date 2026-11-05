#!/usr/bin/env bash
# flash.sh — 可复用的烧录原语：设备识别/安全断言/按标签找分区/写入。
# 交互流程（保留/擦除选择、二次确认）在 commands/flash.sh；本文件只放机制。

# FLASH_DRY_RUN=1 时所有写入只打印命令，不执行
FLASH_DRY_RUN="${FLASH_DRY_RUN:-0}"

_dd_run() {
    if [ "$FLASH_DRY_RUN" -eq 1 ]; then
        log "[CAOS][flash] [dry-run] dd $*"
        return 0
    fi
    dd "$@"
}

# resolve_device DEV —— 规范化为真实路径并断言是块设备
resolve_device() {
    local dev
    dev="$(readlink -f -- "$1")" || die 1 "无法解析设备路径: $1"
    [ -b "$dev" ] || die 1 "不是块设备: $dev"
    printf '%s' "$dev"
}

# assert_disk_device DEV —— 必须是整盘（TYPE=disk），不能是分区
assert_disk_device() {
    local dev=$1 dtype
    dtype="$(lsblk -dnro TYPE -- "$dev")"
    [ "$dtype" = "disk" ] || die 1 "必须是整盘设备（TYPE=disk），不能是分区: $dev"
}

# assert_not_mounted DEV —— 整盘及其任一分区均不得处于挂载状态
assert_not_mounted() {
    local dev=$1
    if lsblk -nrpo MOUNTPOINTS -- "$dev" | grep -q '[^[:space:]]'; then
        die 1 "目标盘或其分区仍已挂载，请先卸载: $dev"
    fi
}

# find_partition_by_label DEV LABEL —— 按分区标签返回设备路径，找不到输出空
find_partition_by_label() {
    local dev=$1 label=$2
    lsblk -nrpo NAME,PARTLABEL -- "$dev" \
        | awk -v label="$label" '$2 == label { print $1; exit }'
}

# assert_min_size NODE BYTES DESC
assert_min_size() {
    local node=$1 min_bytes=$2 desc=$3
    need blockdev
    [ "$(blockdev --getsize64 "$node")" -ge "$min_bytes" ] \
        || die 1 "$desc 小于预期大小（$(numfmt --to=iec -- "$min_bytes" 2>/dev/null || printf '%s 字节' "$min_bytes")）: $node"
}

# flash_keep IMAGE BOOT_PART ROOT_PART —— 保留模式：只重写 ESP 与 rootfs。
# 偏移与原 flash.sh 保持一致：ESP 从镜像 1 MiB 处起 64 MiB，rootfs 从 65 MiB 处起 128 MiB
# （与 genimage.cfg 的 GPT 布局耦合）。
flash_keep() {
    local image=$1 boot_part=$2 root_part=$3
    log "[CAOS][flash] 更新 CAOSBOOT..."
    _dd_run "if=$image" "of=$boot_part" bs=1M skip=1 count=64 conv=fsync status=progress
    log "[CAOS][flash] 更新 CAOSROOT..."
    _dd_run "if=$image" "of=$root_part" bs=1M skip=65 count=128 conv=fsync status=progress
}

# flash_erase IMAGE DEVICE —— 擦除模式：整盘重写
flash_erase() {
    local image=$1 device=$2
    _dd_run "if=$image" "of=$device" bs=4M conv=fsync status=progress
}
