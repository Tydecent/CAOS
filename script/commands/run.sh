#!/usr/bin/env bash
# commands/run.sh — 用 QEMU + OVMF 冒烟启动 sdcard.img。
# 本地可选命令，CI 不执行（见 script/README.md）。
# 用法: ./manage.sh run [--qemu PATH] [--ovmf PATH] [--memory SIZE] [--dry-run]

cmd_run_usage() {
    cat <<'EOF'
用法: ./manage.sh run [--qemu PATH] [--ovmf PATH] [--memory SIZE] [--dry-run]

参数:
  --qemu PATH    qemu-system-x86_64 路径（默认在 PATH 中查找）
  --ovmf PATH    OVMF 固件（默认搜索 /usr/share/OVMF 等常见位置）
  --memory SIZE  内存（默认 2G）
  --dry-run      只打印将执行的 QEMU 命令

说明: 需要安装 qemu-system-x86 与 ovmf（如 apt install qemu-system-x86 ovmf）。
      缺失时退出 3 并给出安装提示，不会自动安装。
      控制台走串口（GRUB/内核 console=ttyS0），退出 QEMU 用 Ctrl-a x。
EOF
}

_find_ovmf() {
    local candidate
    for candidate in \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/ovmf/OVMF.fd \
        /usr/share/qemu/OVMF_CODE.fd \
        /usr/share/qemu/edk2-x86_64-code.fd; do
        [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
    done
    return 1
}

cmd_run() {
    local qemu_bin="qemu-system-x86_64" ovmf="" memory="2G" dry_run=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) cmd_run_usage; return 0 ;;
            --qemu)    [ "$#" -ge 2 ] || die 2 "run: --qemu 需要路径参数"; qemu_bin=$2; shift ;;
            --qemu=*)  qemu_bin=${1#*=} ;;
            --ovmf)    [ "$#" -ge 2 ] || die 2 "run: --ovmf 需要路径参数"; ovmf=$2; shift ;;
            --ovmf=*)  ovmf=${1#*=} ;;
            --memory)  [ "$#" -ge 2 ] || die 2 "run: --memory 需要参数"; memory=$2; shift ;;
            --memory=*) memory=${1#*=} ;;
            --dry-run) dry_run=1 ;;
            *)         die 2 "run: 未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    [ -s "$SDCARD_IMAGE" ] || die 3 "$SDCARD_IMAGE 未生成，先运行 ./manage.sh build"

    if ! have_cmd "$qemu_bin"; then
        die 3 "未找到 $qemu_bin。请安装: sudo apt install qemu-system-x86（或用 --qemu 指定路径）"
    fi
    if [ -z "$ovmf" ]; then
        ovmf="$(_find_ovmf)" || die 3 "未找到 OVMF 固件。请安装: sudo apt install ovmf（或用 --ovmf 指定路径）"
    fi
    [ -f "$ovmf" ] || die 3 "OVMF 固件不存在: $ovmf"

    local accel=""
    [ -w /dev/kvm ] && accel="-enable-kvm -cpu host"

    local cmd_line
    cmd_line="$qemu_bin -machine q35 -m $memory $accel -bios $ovmf \
-drive file=$SDCARD_IMAGE,format=raw,if=virtio \
-net none -display none -serial mon:stdio"

    if [ "$dry_run" -eq 1 ]; then
        log "[CAOS] [dry-run] $cmd_line"
        return 0
    fi
    log "[CAOS] 启动 QEMU 冒烟（串口控制台，退出: Ctrl-a x）"
    # shellcheck disable=SC2086
    exec "$qemu_bin" -machine q35 -m "$memory" $accel -bios "$ovmf" \
        -drive "file=$SDCARD_IMAGE,format=raw,if=virtio" \
        -net none -display none -serial mon:stdio
}
