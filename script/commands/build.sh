#!/usr/bin/env bash
# commands/build.sh — 原 build.sh 的 Stage 1-3/5：
#   Stage 1  Rust 静态二进制（--release --locked）+ 静态链接检查 + clippy + overlay
#   Stage 2  Buildroot caos_defconfig
#   Stage 3  Buildroot 全量构建（长阶段）
#   收尾     写 output/.state/{config.env,build-info.json} 与 stage stamps
# 默认不自动跑 verify；--verify 显式串行调用 verify。
# 用法: ./manage.sh build [--verify]

source "$MANAGE_DIR/script/lib/buildroot.sh"

cmd_build_usage() {
    cat <<'EOF'
用法: ./manage.sh build [--verify]

说明:
    全局选项（-o/-b/-d/-j/--clean/--skip-clippy/-v）可放在子命令前后，例如:
    ./manage.sh build -j 8 --buildroot /path/to/buildroot

参数:
  --verify   构建成功后串行执行 ./manage.sh verify
             （默认不自动验收；--skip-verify 为兼容保留，无实际效果）

前置条件（缺失即退出 3，不自动安装）:
  git/make/cargo/rustup/file/nproc/musl-gcc/unsquashfs/python3/flock
  Rust target x86_64-unknown-linux-musl 已安装
  Buildroot 源码树（--buildroot）与 BR2_EXTERNAL 树存在
EOF
}

build_preflight() {
    need git "克隆/识别 Buildroot 与仓库状态"
    need make "Buildroot 构建"
    need cargo "构建 caos-ca"
    need rustup "Rust target 管理"
    need file "静态链接与 PE32+ 校验"
    need nproc "并行度"
    need musl-gcc "编译 ring（x86_64-unknown-linux-musl）"
    need unsquashfs "rootfs 验收"
    need python3 "validate-image.py（GPT/ESP 校验）"
    [ -d "$BUILDROOT_PATH" ] || die 3 "Buildroot 源码树不存在: $BUILDROOT_PATH（用 --buildroot 指定）"
    [ -f "$BUILDROOT_PATH/Makefile" ] || die 3 "$BUILDROOT_PATH 不是 Buildroot 树（缺 Makefile）"
    [ -d "$BR2_EXTERNAL_DIR" ] || die 3 "BR2_EXTERNAL 树缺失: $BR2_EXTERNAL_DIR"
}

cmd_build() {
    local run_verify=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) cmd_build_usage; return 0 ;;
            --verify)  run_verify=1 ;;
            *)         die 2 "build: 未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    build_preflight
    mkdir -p "$OUTPUT_DIR" "$DOWNLOAD_DIR" "$(dirname -- "$OVERLAY_BINARY")"
    acquire_lock exclusive

    # --clean 在 preflight 之后、正式构建之前执行（路径安全校验在 wipe 内完成）
    if [ "$OPT_CLEAN" -eq 1 ]; then
        wipe_output_tree
        mkdir -p "$OUTPUT_DIR" "$DOWNLOAD_DIR" "$(dirname -- "$OVERLAY_BINARY")"
    fi

    log_stage "Stage 1/5: building static caos-ca"
    if ! rustup target list --installed 2>/dev/null | grep -qx "$RUST_TARGET"; then
        die 3 "Rust target $RUST_TARGET 未安装（rustup target add $RUST_TARGET，或先跑 ./manage.sh doctor --install）"
    fi
    log "[CAOS] Rust target present: $RUST_TARGET"
    (
        cd "$RUST_DIR" || exit
        cargo build --release --locked --target "$RUST_TARGET" 2>&1
    ) | tee "$OUTPUT_DIR/rust-build.log"
    [ -x "$RUST_BINARY" ] || die 1 "Rust 构建未产出 $RUST_BINARY"
    local file_output
    file_output="$(file "$RUST_BINARY")"
    case "$file_output" in
        *"statically linked"*|*"static-pie linked"*) ;;
        *) die 1 "caos-ca 不是静态链接: $file_output" ;;
    esac
    log "[CAOS] static binary: $file_output"

    if [ "$OPT_SKIP_CLIPPY" -eq 0 ]; then
        if cargo clippy --version >/dev/null 2>&1; then
            log "[CAOS] running cargo clippy -D warnings"
            (
                cd "$RUST_DIR" || exit
                cargo clippy --release --locked --target "$RUST_TARGET" -- -D warnings 2>&1
            ) | tee "$OUTPUT_DIR/clippy.log"
        else
            log "[CAOS] WARNING: cargo clippy 不可用，跳过 lint 阶段"
        fi
    else
        log "[CAOS] --skip-clippy: 跳过 clippy"
    fi

    install -D -m 0755 "$RUST_BINARY" "$OVERLAY_BINARY"
    log "[CAOS] installed overlay binary: $OVERLAY_BINARY"
    mark_stage rust

    log_stage "Stage 2/5: configuring Buildroot (O=$OUTPUT_DIR)"
    br_defconfig
    [ -f "$OUTPUT_DIR/.config" ] || die 1 "Buildroot 配置未生成（$OUTPUT_DIR/.config 不存在）"
    log "[CAOS] defconfig complete"
    mark_stage buildroot

    log_stage "Stage 3/5: building Buildroot image with -j$JOBS（长阶段）"
    br_make -j "$JOBS" 2>&1 | tee "$BUILD_LOG"

    # 收尾：状态与产物清点（原 Stage 5）
    write_config_env
    write_build_info
    log_stage "Stage 5/5: build artifacts"
    find "$OUTPUT_DIR/images" -maxdepth 1 -type f -printf '%f\t%s bytes\n' 2>/dev/null \
        | sort | while IFS=$'\t' read -r name size; do
            printf '  %-32s %s\n' "$name" "$size"
        done
    log "[CAOS] 构建信息: $STATE_DIR/build-info.json"
    log "[CAOS] 构建日志: $BUILD_LOG"
    log "[CAOS] 验收: ./manage.sh verify（或 build --verify 自动执行）"

    if [ "$run_verify" -eq 1 ]; then
        # shellcheck source=script/commands/verify.sh
        source "$MANAGE_DIR/script/commands/verify.sh"
        # shellcheck disable=SC2119
        cmd_verify
    fi
}
