#!/usr/bin/env bash
# state.sh — output/.state/ 读写、flock 排他/共享锁、build-info、stage stamp。
# 只提供无状态机制；业务语义（何时打 stamp、stamp 含义）在 commands/ 里。

# 确保 .state 目录存在并返回其路径
state_dir() {
    STATE_DIR="${STATE_DIR:-$OUTPUT_DIR/.state}"
    mkdir -p "$STATE_DIR/stages"
    printf '%s' "$STATE_DIR"
}

# load_config_env 恢复 OUTPUT_DIR 后调用：让 .state 跟随恢复出的输出目录
refresh_state_dir() {
    STATE_DIR="$OUTPUT_DIR/.state"
}

# acquire_lock exclusive|shared —— 用 fd 9 持有 output/.state/build.lock
#   build / clean / flash 用 exclusive；verify / package / version 用 shared。
#   非阻塞：拿不到锁立即报错，避免静默排队。
acquire_lock() {
    local mode=${1:-exclusive}
    state_dir >/dev/null
    need flock "用于 output/.state/build.lock 构建锁"
    exec 9>"$STATE_DIR/build.lock"
    case "$mode" in
        exclusive)
            flock -n 9 || die 1 "另一个构建/清理正在运行（无法获取排他锁: $STATE_DIR/build.lock）"
            ;;
        shared)
            flock -s -n 9 || die 1 "无法获取共享锁，可能有构建/清理正在进行: $STATE_DIR/build.lock"
            ;;
        *)
            die 2 "acquire_lock: 未知锁模式 '$mode'（exclusive|shared）"
            ;;
    esac
}

# 构建输入指纹：Cargo.lock + git HEAD + 关键配置文件，sha256。
# 用途：stage stamp 与 verify.done 的"输入未变"判定，仅加速，不作正确性依据。
input_hash() {
    {
        cat "$RUST_DIR/Cargo.lock" 2>/dev/null || true
        git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || true
        cat "$BR2_EXTERNAL_DIR/configs/caos_defconfig" 2>/dev/null || true
        cat "$BR2_EXTERNAL_DIR/board/caos/linux.fragment" 2>/dev/null || true
        cat "$BR2_EXTERNAL_DIR/board/caos/busybox.fragment" 2>/dev/null || true
        cat "$BR2_EXTERNAL_DIR/board/caos/grub.cfg" 2>/dev/null || true
        cat "$BR2_EXTERNAL_DIR/board/caos/genimage.cfg" 2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

mark_stage() {
    local name=$1 tmp
    state_dir >/dev/null
    tmp="$STATE_DIR/stages/$name.done.tmp"
    input_hash >"$tmp"
    mv -f "$tmp" "$STATE_DIR/stages/$name.done"
}

# stamp 存在且输入 hash 一致才算完成
stage_done() {
    local name=$1 f
    f="$STATE_DIR/stages/$name.done"
    [ -f "$f" ] || return 1
    [ "$(cat "$f" 2>/dev/null)" = "$(input_hash)" ]
}

clear_stages() {
    state_dir >/dev/null
    rm -f -- "$STATE_DIR"/stages/*.done 2>/dev/null || true
}

# wipe_output_tree —— （--clean 用）整目录清空输出树。先做路径安全校验再 rm -rf。
wipe_output_tree() {
    ensure_safe_output_dir
    if [ "$OUTPUT_DIR" = "/" ] || [ "$OUTPUT_DIR" = "$HOME" ] || [ "$OUTPUT_DIR" = "$PROJECT_DIR" ]; then
        die 3 "拒绝清空危险路径: $OUTPUT_DIR"
    fi
    log "[CAOS] --clean: 清空输出目录 $OUTPUT_DIR"
    rm -rf -- "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
}

# 读取 caos-ca 的 crate 版本（Cargo.toml 首个 version=）
project_version() {
    local all
    all="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$RUST_DIR/Cargo.toml" 2>/dev/null || true)"
    printf '%s' "${all%%$'\n'*}"
}

_git_commit()    { git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || printf 'unknown'; }
_git_branch()    { git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown'; }
_git_describe()  { git -C "$PROJECT_DIR" describe --always --tags --dirty 2>/dev/null || printf 'unknown'; }
_git_dirty() {
    [ -n "$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | head -1)" ] && printf 'true' || printf 'false'
}

_buildroot_version() {
    [ -f "$BUILDROOT_PATH/Makefile" ] || { printf ''; return 0; }
    { sed -n 's/^BR2_VERSION *= *//p' "$BUILDROOT_PATH/Makefile" 2>/dev/null \
        | tr -d '"' | head -1; } || true
}

# write_build_info —— 落盘 output/.state/build-info.json
write_build_info() {
    state_dir >/dev/null
    local ts make_all make_v
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    make_all="$(make -v 2>/dev/null || true)"
    make_v="${make_all%%$'\n'*}"
    [ -n "$make_v" ] || make_v=unknown
    {
        printf '{\n'
        printf '  "version": "%s",\n' "$(json_escape "$(project_version)")"
        printf '  "git_describe": "%s",\n' "$(json_escape "$(_git_describe)")"
        printf '  "commit": "%s",\n' "$(json_escape "$(_git_commit)")"
        printf '  "branch": "%s",\n' "$(json_escape "$(_git_branch)")"
        printf '  "dirty": %s,\n' "$(_git_dirty)"
        printf '  "rustc": "%s",\n' "$(json_escape "$(rustc -V 2>/dev/null || printf 'unknown')")"
        printf '  "cargo": "%s",\n' "$(json_escape "$(cargo -V 2>/dev/null || printf 'unknown')")"
        printf '  "make": "%s",\n' "$(json_escape "$make_v")"
        printf '  "buildroot_version": "%s",\n' "$(json_escape "$(_buildroot_version)")"
        printf '  "jobs": "%s",\n' "$(json_escape "$JOBS")"
        printf '  "timestamp": "%s",\n' "$(json_escape "$ts")"
        printf '  "paths": {\n'
        printf '    "output_dir": "%s",\n' "$(json_escape "$OUTPUT_DIR")"
        printf '    "download_dir": "%s",\n' "$(json_escape "$DOWNLOAD_DIR")"
        printf '    "buildroot": "%s",\n' "$(json_escape "$BUILDROOT_PATH")"
        printf '    "br2_external": "%s"\n' "$(json_escape "$BR2_EXTERNAL_DIR")"
        printf '  }\n'
        printf '}\n'
    } >"$STATE_DIR/build-info.json"
}

read_build_info() {
    local f="$STATE_DIR/build-info.json"
    [ -f "$f" ] || die 3 "缺少 $f（先运行 ./manage.sh build）"
    cat "$f"
}
