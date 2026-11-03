#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${CAOS_IMAGE:-$SCRIPT_DIR/output/images/sdcard.img}"
DEVICE="${CAOS_DEVICE:-}"

fail() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

[[ -n "$DEVICE" ]] || fail '请通过 CAOS_DEVICE 指定目标整盘设备。'
[[ -f "$IMAGE" ]] || fail "镜像不存在：$IMAGE"
[[ "$EUID" -eq 0 ]] || fail '请以 root 身份运行，例如 sudo env CAOS_DEVICE=/dev/sdX ./flash.sh'

for command_name in lsblk blockdev dd stat readlink grep; do
    command -v "$command_name" >/dev/null || fail "缺少命令：$command_name"
done

DEVICE="$(readlink -f -- "$DEVICE")"
[[ -b "$DEVICE" ]] || fail "不是块设备：$DEVICE"
[[ "$(lsblk -dnro TYPE -- "$DEVICE")" == disk ]] || fail 'CAOS_DEVICE 必须是整盘设备，不能是分区。'

if lsblk -nrpo MOUNTPOINTS -- "$DEVICE" | grep -q '[^[:space:]]'; then
    fail "目标盘或其分区仍已挂载，请先卸载：$DEVICE"
fi

IMAGE_BYTES="$(stat -c '%s' -- "$IMAGE")"
MIN_IMAGE_BYTES=$((193 * 1024 * 1024))
(( IMAGE_BYTES >= MIN_IMAGE_BYTES )) || fail '镜像小于预期分区布局，拒绝烧录。'

partition_for_label() {
    lsblk -nrpo NAME,PARTLABEL -- "$DEVICE" \
        | awk -v label="$1" '$2 == label { print $1; exit }'
}

BOOT_PARTITION="$(partition_for_label CAOSBOOT)"
ROOT_PARTITION="$(partition_for_label CAOSROOT)"
DATA_PARTITION="$(partition_for_label CAOSDATA)"

if [[ -n "$DATA_PARTITION" ]]; then
    printf '检测到证书数据分区：%s\n' "$DATA_PARTITION"
    printf '选择：保留 CAOSDATA（只更新系统），或擦除（重写整盘并清空 CAOSDATA）。\n'
    while true; do
        read -r -p '请输入 [保留(k)/擦除(e)/取消(q)]：' choice
        case "$choice" in
            保留|keep|K|k) ACTION=keep; break ;;
            擦除|erase|E|e) ACTION=erase; break ;;
            取消|cancel|Q|q) exit 0 ;;
            *) printf '请输入“保留”、“擦除”或“取消”。\n' ;;
        esac
    done
else
    printf '未检测到 CAOSDATA 分区，将写入完整镜像。\n'
    ACTION=erase
fi

printf '目标设备：%s\n镜像文件：%s\n' "$DEVICE" "$IMAGE"
read -r -p "输入设备路径 $DEVICE 以确认：" confirmation
[[ "$confirmation" == "$DEVICE" ]] || fail '设备确认不匹配，已取消。'

if [[ "$ACTION" == keep ]]; then
    [[ -n "$BOOT_PARTITION" && -n "$ROOT_PARTITION" ]] \
        || fail '保留模式要求目标盘同时存在 CAOSBOOT 和 CAOSROOT 分区。'
    (( $(blockdev --getsize64 "$BOOT_PARTITION") >= 64 * 1024 * 1024 )) \
        || fail 'CAOSBOOT 分区小于 64 MiB。'
    (( $(blockdev --getsize64 "$ROOT_PARTITION") >= 128 * 1024 * 1024 )) \
        || fail 'CAOSROOT 分区小于 128 MiB。'

    printf '更新 CAOSBOOT...\n'
    dd if="$IMAGE" of="$BOOT_PARTITION" bs=1M skip=1 count=64 conv=fsync status=progress
    printf '更新 CAOSROOT...\n'
    dd if="$IMAGE" of="$ROOT_PARTITION" bs=1M skip=65 count=128 conv=fsync status=progress
else
    (( $(blockdev --getsize64 "$DEVICE") >= IMAGE_BYTES )) \
        || fail '目标盘容量小于镜像。'
    dd if="$IMAGE" of="$DEVICE" bs=4M conv=fsync status=progress
fi

sync
printf '烧录完成。安全弹出介质后再拔出。\n'