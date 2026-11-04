#!/usr/bin/env bash
# config.sh — 全局 CLI 解析、默认值、路径派生、config.env 读写。
# 所有用户可配置项只通过 CLI 传参；不读取任何用户接口级环境变量
# （Buildroot 自身的 BR2_DL_DIR 等仅在调用子进程时传递）。

# 变量在本文件声明、由其他 source 的文件使用，shellcheck 误报 unused
# shellcheck disable=SC2034

MANAGE_COMMANDS="doctor build verify package clean flash run version release"

# 全局选项状态（manage.sh 层解析）
OPT_VERBOSE=0
OPT_JSON=0
OPT_CLEAN=0
OPT_SKIP_CLIPPY=0
OPT_SKIP_VERIFY=0
PARSED_ARGS=()

# 用户可配置路径（resolve_config 后均为绝对路径）
OUTPUT_DIR=""
BUILDROOT_PATH=""
DOWNLOAD_DIR=""
JOBS=""

# 派生路径（init_derived_paths 填充）
BR2_EXTERNAL_DIR=""
RUST_DIR=""
RUST_TARGET=""
RUST_BINARY=""
OVERLAY_BINARY=""
VALIDATOR=""
SDCARD_IMAGE=""
BOOT_IMAGE=""
ROOTFS_IMAGE=""
EFI_IMAGE=""
BZIMAGE=""
HOST_MCOPY=""
HOST_MDIR=""
HOST_GRUB_SCRIPT_CHECK=""
BUILD_LOG=""
STATE_DIR=""
# ESP 在 GPT 中的扇区偏移/数量（与 genimage.cfg 的 1 MiB 对齐 64 MiB ESP 耦合；
# verify 会优先从 validate-image.py 的输出动态读取，这里仅作回退值）
ESP_SKIP_SECTORS=2048
ESP_COUNT_SECTORS=131072

# 解析全局选项。支持 --opt=val、--opt val、-j8、-j 8；可放在子命令前后。
# 子命令专属选项保留在 PARSED_ARGS 中交给子命令，-- 后内容不再解析。
parse_global_args() {
    PARSED_ARGS=()
    local command_seen=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                if [ "$command_seen" -eq 1 ]; then
                    PARSED_ARGS+=("$1")
                else
                    top_usage
                    exit 0
                fi
                ;;
            -v|--verbose)   OPT_VERBOSE=1 ;;
            --json)         OPT_JSON=1 ;;
            --clean)        OPT_CLEAN=1 ;;
            --skip-clippy)  OPT_SKIP_CLIPPY=1 ;;
            --skip-verify)  OPT_SKIP_VERIFY=1 ;;
            -o|--output)
                [ "$#" -ge 2 ] || die 2 "选项 $1 需要一个目录参数"
                OUTPUT_DIR=$2
                shift
                ;;
            --output=*)         OUTPUT_DIR=${1#*=} ;;
            -b|--buildroot)
                [ "$#" -ge 2 ] || die 2 "选项 $1 需要一个目录参数"
                BUILDROOT_PATH=$2
                shift
                ;;
            --buildroot=*)      BUILDROOT_PATH=${1#*=} ;;
            -d|--download-dir)
                [ "$#" -ge 2 ] || die 2 "选项 $1 需要一个目录参数"
                DOWNLOAD_DIR=$2
                shift
                ;;
            --download-dir=*)   DOWNLOAD_DIR=${1#*=} ;;
            -j[0-9]*)           JOBS=${1#-j} ;;
            -j|--jobs)
                [ "$#" -ge 2 ] || die 2 "选项 $1 需要一个数字参数"
                JOBS=$2
                shift
                ;;
            --jobs=*)           JOBS=${1#*=} ;;
            --)
                shift
                PARSED_ARGS+=("$@")
                return 0
                ;;
            -*)
                if [ "$command_seen" -eq 1 ]; then
                    PARSED_ARGS+=("$1")
                else
                    die 2 "未知全局选项: $1（运行 ./manage.sh --help 查看用法）"
                fi
                ;;
            *)
                command_seen=1
                PARSED_ARGS+=("$1")
                ;;
        esac
        shift
    done
    return 0
}

# 把 CLI 值落实为绝对路径并做安全校验
resolve_config() {
    [ -n "$OUTPUT_DIR" ]     || OUTPUT_DIR="$PROJECT_DIR/output"
    [ -n "$BUILDROOT_PATH" ] || BUILDROOT_PATH="$PROJECT_DIR/../buildroot-2026.08.1"
    if [ -z "$JOBS" ]; then
        JOBS="$(nproc 2>/dev/null || printf '1')"
    fi
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die 2 "-j/--jobs 必须是正整数: $JOBS"

    OUTPUT_DIR="$(abspath "$OUTPUT_DIR")"
    BUILDROOT_PATH="$(abspath "$BUILDROOT_PATH")"
    if [ -n "$DOWNLOAD_DIR" ]; then
        DOWNLOAD_DIR="$(abspath "$DOWNLOAD_DIR")"
    else
        DOWNLOAD_DIR="$OUTPUT_DIR/dl"
    fi

    if [ "$OUTPUT_DIR" = "/" ]; then
        die 3 "输出目录不能为 /（-o/--output）"
    fi
    if [ "$OUTPUT_DIR" = "$HOME" ]; then
        die 3 "输出目录不能为 \$HOME: $OUTPUT_DIR"
    fi
    ensure_safe_output_dir
}

# 输出目录不得指向项目源码目录（--clean/--dry-run 清理时尤其危险）
ensure_safe_output_dir() {
    if [ "$OUTPUT_DIR" = "$PROJECT_DIR" ]; then
        die 3 "输出目录不能是项目根目录: $OUTPUT_DIR"
    fi
    local d
    for d in caos-ca caos-buildroot script .github; do
        if [ "$OUTPUT_DIR" = "$PROJECT_DIR/$d" ]; then
            die 3 "输出目录不能指向源码目录: $OUTPUT_DIR"
        fi
        case "$OUTPUT_DIR" in
            "$PROJECT_DIR/$d"/*)
                die 3 "输出目录不能位于源码目录 $PROJECT_DIR/$d 内: $OUTPUT_DIR"
                ;;
        esac
    done
    return 0
}

# 从 OUTPUT_DIR 派生所有构建产物路径与工具路径
init_derived_paths() {
    BR2_EXTERNAL_DIR="$PROJECT_DIR/caos-buildroot"
    RUST_DIR="$PROJECT_DIR/caos-ca"
    RUST_TARGET="x86_64-unknown-linux-musl"
    RUST_BINARY="$RUST_DIR/target/$RUST_TARGET/release/caos-ca"
    OVERLAY_BINARY="$BR2_EXTERNAL_DIR/board/caos/rootfs-overlay/usr/bin/caos-ca"
    VALIDATOR="$BR2_EXTERNAL_DIR/board/caos/validate-image.py"

    SDCARD_IMAGE="$OUTPUT_DIR/images/sdcard.img"
    BOOT_IMAGE="$OUTPUT_DIR/images/boot.vfat"
    ROOTFS_IMAGE="$OUTPUT_DIR/images/rootfs.squashfs"
    EFI_IMAGE="$OUTPUT_DIR/images/efi-part/EFI/BOOT/bootx64.efi"
    BZIMAGE="$OUTPUT_DIR/images/bzImage"
    HOST_MCOPY="$OUTPUT_DIR/host/bin/mcopy"
    HOST_MDIR="$OUTPUT_DIR/host/bin/mdir"
    HOST_GRUB_SCRIPT_CHECK="$OUTPUT_DIR/host/bin/grub-script-check"
    BUILD_LOG="$OUTPUT_DIR/build.log"
    STATE_DIR="$OUTPUT_DIR/.state"
}

print_config() {
    log "[CAOS] 生效配置:"
    log "  PROJECT_DIR        = $PROJECT_DIR"
    log "  OUTPUT_DIR         = $OUTPUT_DIR"
    log "  DOWNLOAD_DIR       = $DOWNLOAD_DIR"
    log "  BUILDROOT_PATH     = $BUILDROOT_PATH"
    log "  BR2_EXTERNAL_DIR   = $BR2_EXTERNAL_DIR"
    log "  RUST_DIR           = $RUST_DIR"
    log "  RUST_TARGET        = $RUST_TARGET"
    log "  JOBS               = $JOBS"
    log "  clean              = $OPT_CLEAN"
    log "  skip-clippy        = $OPT_SKIP_CLIPPY"
}

# ---------- config.env（output/.state/config.env，KEY='value'，可 source） ----------

# 单值加单引号（内部单引号转义为 '\''）
_env_quote() {
    local s=$1
    printf "'%s'" "${s//\'/\'\\\'\'}"
}

# 构建成功后落盘当前配置，供 verify/package 等只读命令恢复路径
write_config_env() {
    mkdir -p "$STATE_DIR"
    {
        printf '# 由 manage.sh build 自动生成，请勿手工编辑\n'
        _write_kv PROJECT_DIR "$PROJECT_DIR"
        _write_kv OUTPUT_DIR "$OUTPUT_DIR"
        _write_kv DOWNLOAD_DIR "$DOWNLOAD_DIR"
        _write_kv BUILDROOT_PATH "$BUILDROOT_PATH"
        _write_kv BR2_EXTERNAL_DIR "$BR2_EXTERNAL_DIR"
        _write_kv RUST_DIR "$RUST_DIR"
        _write_kv RUST_TARGET "$RUST_TARGET"
        _write_kv JOBS "$JOBS"
        _write_kv SDCARD_IMAGE "$SDCARD_IMAGE"
        _write_kv BOOT_IMAGE "$BOOT_IMAGE"
        _write_kv ROOTFS_IMAGE "$ROOTFS_IMAGE"
        _write_kv EFI_IMAGE "$EFI_IMAGE"
        _write_kv BZIMAGE "$BZIMAGE"
        _write_kv BUILD_LOG "$BUILD_LOG"
        _write_kv ESP_SKIP_SECTORS "$ESP_SKIP_SECTORS"
        _write_kv ESP_COUNT_SECTORS "$ESP_COUNT_SECTORS"
    } >"$STATE_DIR/config.env"
}

_write_kv() {
    printf '%s=%s\n' "$1" "$(_env_quote "$2")"
}

# 恢复构建时配置：set -a 先导出再 source，避免部分变量漏导出
load_config_env() {
    local env_file="${STATE_DIR:-$OUTPUT_DIR/.state}/config.env"
    [ -f "$env_file" ] || return 1
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
    return 0
}
