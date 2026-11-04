#!/usr/bin/env bash
# commands/doctor.sh — 环境体检：工具链、Rust target、Buildroot 树、output 可写性。
# 用法: ./manage.sh doctor [--json] [--install]
#   --install   仅为缺失的 Rust target 执行 rustup target add（逐项确认，不装系统包）
# 退出码：有失败项 3，全部通过 0。

cmd_doctor_usage() {
    cat <<'EOF'
用法: ./manage.sh doctor [--json] [--install]

检查项：
  OS/架构、bash 版本、git/make/rustup/cargo/file/nproc/musl-gcc/
  unsquashfs/python3/flock/realpath（zip 为 package/release 专用，标 optional）
  Rust target x86_64-unknown-linux-musl 是否安装（默认只报告，--install 才安装）
  Buildroot 源码树存在且含 Makefile；BR2_EXTERNAL 树存在；output/ 可写

退出码: 全部通过 0；有失败项 3。
EOF
}

DOCTOR_CHECKS_JSON=()
DOCTOR_FAILED=0

_add_check() {
    # _add_check name status detail
    DOCTOR_CHECKS_JSON+=("$(printf '{"name": "%s", "status": "%s", "detail": "%s"}' \
        "$(json_escape "$1")" "$(json_escape "$2")" "$(json_escape "$3")")")
    case "$2" in
        fail)
            log "  [FAIL] $1: $3"
            DOCTOR_FAILED=$((DOCTOR_FAILED + 1))
            ;;
        warn) log "  [WARN] $1: $3" ;;
        *)    log "  [ OK ] $1: $3" ;;
    esac
}

_check_cmd() {
    # _check_cmd name required hint
    local name=$1 required=$2 hint=${3:-}
    if have_cmd "$name"; then
        _add_check "$name" ok "$(command -v "$name")"
    elif [ "$required" = "optional" ]; then
        _add_check "$name" warn "未安装（$hint）"
    else
        _add_check "$name" fail "未安装${hint:+；$hint}"
    fi
}

cmd_doctor() {
    local install=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)  cmd_doctor_usage; return 0 ;;
            --json)     OPT_JSON=1 ;;
            --install)  install=1 ;;
            *)          die 2 "doctor: 未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    local failed=0
    log "[CAOS] doctor：环境体检"

    # OS / 架构 / bash
    _add_check "os" ok "$(uname -s) / $(uname -m)"
    local bash_ver
    bash_ver="$(bash -c 'echo $BASH_VERSION')"
    if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
        _add_check "bash" ok "bash $bash_ver"
    else
        _add_check "bash" fail "bash 版本过旧: $bash_ver（需要 >= 4）"
    fi

    # 基础工具
    _check_cmd git required "git clone Buildroot / 读取仓库信息"
    _check_cmd make required "Buildroot 构建入口"
    _check_cmd rustup required "Rust 工具链管理"
    _check_cmd cargo required "构建 caos-ca"
    _check_cmd file required "静态链接 / PE32+ 校验"
    _check_cmd nproc required "默认并行度"
    _check_cmd musl-gcc required "编译 ring（x86_64-unknown-linux-musl）"
    _check_cmd unsquashfs required "rootfs 验收"
    _check_cmd python3 required "validate-image.py（GPT/ESP 校验）"
    _check_cmd flock required "output/.state/build.lock 构建锁"
    _check_cmd realpath required "路径规范化"
    _check_cmd zip optional "仅 package/release 压缩包需要（默认使用 tar.gz，可不装）"

    # Rust target（只报告；--install 才装，且逐项确认）
    if have_cmd rustup; then
        if rustup target list --installed 2>/dev/null | grep -qx "$RUST_TARGET"; then
            _add_check "rust-target" ok "$RUST_TARGET 已安装"
        else
            if [ "$install" -eq 1 ]; then
                if confirm "安装 Rust target $RUST_TARGET?"; then
                    if rustup target add "$RUST_TARGET"; then
                        _add_check "rust-target" ok "$RUST_TARGET 安装成功"
                    else
                        _add_check "rust-target" fail "rustup target add $RUST_TARGET 失败"
                    fi
                else
                    _add_check "rust-target" fail "$RUST_TARGET 未安装（用户取消安装）"
                fi
            else
                _add_check "rust-target" fail \
                    "$RUST_TARGET 未安装（运行 ./manage.sh doctor --install 或 rustup target add $RUST_TARGET）"
            fi
        fi
    fi

    # Buildroot 树
    if [ -d "$BUILDROOT_PATH" ] && [ -f "$BUILDROOT_PATH/Makefile" ]; then
        _add_check "buildroot-tree" ok "$BUILDROOT_PATH"
    elif [ -d "$BUILDROOT_PATH" ]; then
        _add_check "buildroot-tree" fail "$BUILDROOT_PATH 存在但不是 Buildroot 树（缺 Makefile）"
    else
        _add_check "buildroot-tree" fail \
            "Buildroot 源码树不存在: $BUILDROOT_PATH（先 git clone，或用 --buildroot 指定）"
    fi
    if [ -d "$BR2_EXTERNAL_DIR" ]; then
        _add_check "br2-external" ok "$BR2_EXTERNAL_DIR"
    else
        _add_check "br2-external" fail "BR2_EXTERNAL 树缺失: $BR2_EXTERNAL_DIR"
    fi

    # output 可写
    if mkdir -p "$OUTPUT_DIR" 2>/dev/null && [ -w "$OUTPUT_DIR" ]; then
        _add_check "output-writable" ok "$OUTPUT_DIR"
    else
        _add_check "output-writable" fail "输出目录不可写: $OUTPUT_DIR"
    fi

    # 汇总
    local failed=$DOCTOR_FAILED c

    if [ "$OPT_JSON" -eq 1 ]; then
        local ok=true
        [ "$failed" -eq 0 ] || ok=false
        {
            printf '{"ok": %s, "checks": [\n' "$ok"
            local i=0
            for c in "${DOCTOR_CHECKS_JSON[@]}"; do
                [ "$i" -gt 0 ] && printf ',\n'
                printf '%s' "$c"
                i=$((i + 1))
            done
            printf '\n]}\n'
        } > /tmp/.caos_doctor_json
        cat /tmp/.caos_doctor_json
        rm -f /tmp/.caos_doctor_json
    else
        if [ "$failed" -eq 0 ]; then
            log "[CAOS] doctor：全部通过"
        else
            log "[CAOS] doctor：$failed 项失败"
        fi
    fi

    [ "$failed" -eq 0 ] || exit 3
    return 0
}
