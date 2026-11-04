#!/usr/bin/env bash
# commands/flash.sh — 原 flash.sh 的全部逻辑与安全检查，改为 CLI 传参。
# 用法: ./manage.sh flash DEVICE [--image PATH] [--keep|--erase] [--yes] [--dry-run]
#
# 安全检查（一项不可少）:
#   root 权限、整盘设备（TYPE=disk）、未挂载、镜像存在且 >= 193 MiB、
#   工具齐全、检测 CAOSDATA 后选择保留/擦除、输入设备路径二次确认。
# 非交互（非 TTY）模式必须显式指定 --keep 或 --erase 和 --yes。

source "$MANAGE_DIR/script/lib/flash.sh"

cmd_flash_usage() {
    cat <<'EOF'
用法: ./manage.sh flash DEVICE [--image PATH] [--keep|--erase] [--yes] [--dry-run]

参数:
  DEVICE       目标整盘设备（如 /dev/sdX；不能是分区）
  --image P    镜像路径（默认 <output>/images/sdcard.img）
  --keep       保留 CAOSDATA，只更新 CAOSBOOT/CAOSROOT
  --erase      重写整盘并清空 CAOSDATA
  --yes        跳过交互确认（非交互模式必填）
  --dry-run    只打印将执行的 dd 命令，不写入

示例:
  sudo ./manage.sh flash /dev/sdX
  sudo ./manage.sh flash /dev/sdX --image out.img --erase --yes
  ./manage.sh flash /dev/sdX --dry-run
EOF
}

cmd_flash() {
    local device_arg="" image_arg="" keep=0 erase=0 assume_yes=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) cmd_flash_usage; return 0 ;;
            --image)   [ "$#" -ge 2 ] || die 2 "flash: --image 需要路径参数"; image_arg=$2; shift ;;
            --image=*) image_arg=${1#*=} ;;
            --keep)    keep=1 ;;
            --erase)   erase=1 ;;
            --yes)     assume_yes=1 ;;
            --dry-run) FLASH_DRY_RUN=1 ;;
            *)         device_arg=$1 ;;
        esac
        shift
    done

    [ -n "$device_arg" ] || die 2 "用法: ./manage.sh flash DEVICE [--image PATH] [--keep|--erase] [--yes] [--dry-run]"
    if [ "$keep" -eq 1 ] && [ "$erase" -eq 1 ]; then
        die 2 "flash: --keep 与 --erase 互斥"
    fi

    # 烧录写的是块设备而非 output/，但按锁约定 flash 仍取排他锁
    acquire_lock exclusive

    # ---- 工具与身份 ----
    local tool
    for tool in lsblk blockdev dd stat readlink grep sync; do
        need "$tool" "烧录必需"
    done
    [ "$(id -u)" -eq 0 ] || die 1 "烧录需要 root 权限，例如: sudo ./manage.sh flash $device_arg --keep"

    # ---- 设备安全断言 ----
    local device
    device="$(resolve_device "$device_arg")"
    assert_disk_device "$device"
    assert_not_mounted "$device"

    # ---- 镜像 ----
    if [ -n "$image_arg" ]; then
        IMAGE_PATH="$(abspath "$image_arg")"
    else
        IMAGE_PATH="$SDCARD_IMAGE"
    fi
    [ -f "$IMAGE_PATH" ] || die 1 "镜像不存在: $IMAGE_PATH（可先运行 ./manage.sh build，或用 --image 指定）"
    local image_bytes min_bytes
    image_bytes="$(stat -c '%s' -- "$IMAGE_PATH")"
    min_bytes=$((193 * 1024 * 1024))
    [ "$image_bytes" -ge "$min_bytes" ] || die 1 "镜像小于预期分区布局（>= 193 MiB），拒绝烧录: $IMAGE_PATH"

    # ---- CAOSDATA 处理策略 ----
    local boot_part root_part data_part action
    boot_part="$(find_partition_by_label "$device" CAOSBOOT)"
    root_part="$(find_partition_by_label "$device" CAOSROOT)"
    data_part="$(find_partition_by_label "$device" CAOSDATA)"

    if [ -n "$data_part" ]; then
        log "[CAOS][flash] 检测到证书数据分区: $data_part"
        if [ "$keep" -eq 1 ]; then
            action=keep
        elif [ "$erase" -eq 1 ]; then
            action=erase
        elif [ "$FLASH_DRY_RUN" -eq 1 ]; then
            die 2 "dry-run 检测到 CAOSDATA，请指定 --keep 或 --erase 以确定写入范围"
        elif [ -t 0 ]; then
            log "[CAOS][flash] 选择：保留 CAOSDATA（只更新系统），或擦除（重写整盘并清空 CAOSDATA）。"
            local choice
            while true; do
                read -r -p '请输入 [保留(k)/擦除(e)/取消(q)]：' choice || die 1 "读取输入失败"
                case "$choice" in
                    保留|keep|K|k) action=keep; break ;;
                    擦除|erase|E|e) action=erase; break ;;
                    取消|cancel|Q|q) die 0 "已取消" ;;
                    *) log "[CAOS][flash] 请输入: 保留(k) / 擦除(e) / 取消(q)。" ;;
                esac
            done
        else
            die 2 "非交互模式必须指定 --keep 或 --erase 和 --yes"
        fi
    else
        log "[CAOS][flash] 未检测到 CAOSDATA 分区，将写入完整镜像。"
        action=erase
    fi

    # ---- 二次确认 ----
    log "[CAOS][flash] 目标设备: $device"
    log "[CAOS][flash] 镜像文件: $IMAGE_PATH ($image_bytes bytes)"
    log "[CAOS][flash] 模式:     $action"
    if [ "$FLASH_DRY_RUN" -eq 1 ]; then
        log "[CAOS][flash] [dry-run] 以下为将执行的写入命令:"
        if [ "$action" = "keep" ]; then
            flash_keep "$IMAGE_PATH" "$boot_part" "$root_part"
        else
            flash_erase "$IMAGE_PATH" "$device"
        fi
        log "[CAOS][flash] [dry-run] 未写入任何数据。"
        return 0
    fi
    if [ "$assume_yes" -ne 1 ]; then
        local confirmation
        if [ ! -t 0 ]; then
            die 2 "非交互模式必须指定 --keep 或 --erase 和 --yes"
        fi
        read -r -p "输入设备路径 $device 以确认：" confirmation || die 1 "读取确认输入失败"
        [ "$confirmation" = "$device" ] || die 1 "设备确认不匹配，已取消。"
    fi

    # ---- 写入 ----
    if [ "$action" = "keep" ]; then
        if [ -z "$boot_part" ] || [ -z "$root_part" ]; then
            die 1 "保留模式要求目标盘同时存在 CAOSBOOT 和 CAOSROOT 分区。"
        fi
        assert_min_size "$boot_part" $((64 * 1024 * 1024)) "CAOSBOOT 分区"
        assert_min_size "$root_part" $((128 * 1024 * 1024)) "CAOSROOT 分区"
        flash_keep "$IMAGE_PATH" "$boot_part" "$root_part"
    else
        [ "$(blockdev --getsize64 -- "$device")" -ge "$image_bytes" ] \
            || die 1 "目标盘容量小于镜像，拒绝烧录。"
        flash_erase "$IMAGE_PATH" "$device"
    fi

    sync
    log "[CAOS][flash] 烧录完成。安全弹出介质后再拔出。"
}
