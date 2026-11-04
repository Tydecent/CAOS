#!/usr/bin/env bash
# common.sh — 无状态通用辅助：日志、报错、工具探测、路径、确认、JSON 转义。
# 本文件不得包含任何项目业务判断（那属于 commands/ 或 validate-image.py）。

# 统一 ERR trap：打印失败位置与命令后按原退出码退出。
# 需要 set -E 使 ERR trap 传播进函数与子 shell（manage.sh 已设置）。
_on_err() {
    local code=$?
    printf '[CAOS] ERROR: 命令失败 (exit %s) 于 %s:%s: %s\n' \
        "$code" "${BASH_SOURCE[1]:-?}" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND}" >&2
    exit "$code"
}
trap '_on_err' ERR

# die [退出码] 消息...—— 默认退出 1
die() {
    local code=1
    if [ "$#" -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
        code=$1
        shift
    fi
    printf '[CAOS] ERROR: %s\n' "$*" >&2
    exit "$code"
}

# 面向用户的普通日志。--json 模式下转 stderr，保证 stdout 只有机器可读输出。
log() {
    if [ "${OPT_JSON:-0}" -eq 1 ]; then
        printf '%s\n' "$*" >&2
    else
        printf '%s\n' "$*"
    fi
}

log_stage() {
    log ""
    log "[CAOS] $*"
}

# need CMD [提示]—— 缺少命令时退出 3（前置条件不满足）
need() {
    local cmd_name=$1 hint=${2:-}
    if ! command -v "$cmd_name" >/dev/null 2>&1; then
        local msg="缺少命令: $cmd_name"
        [ -n "$hint" ] && msg="$msg（$hint）"
        die 3 "$msg"
    fi
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# abspath PATH —— realpath -m 转绝对路径（不要求已存在）
abspath() {
    local p=$1
    realpath -m -- "$p"
}

# confirm PROMPT —— 返回 0 表示用户确认；非 TTY 直接失败并提示传 --yes
confirm() {
    local prompt=$1 reply
    if [ ! -t 0 ]; then
        die 2 "非交互模式无法确认：$prompt（请显式传 --yes）"
    fi
    read -r -p "$prompt [y/N] " reply || die 1 "读取确认输入失败"
    [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" || "$reply" == "YES" ]]
}

require_file() {
    [ -f "$1" ] || die 3 "缺少文件: $1"
}

require_dir() {
    [ -d "$1" ] || die 3 "缺少目录: $1"
}

# json_escape STRING —— 转义 JSON 字符串中的反斜杠、引号与控制字符（不含外层引号）
json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

# 顶层用法（全局选项 + 子命令列表）
top_usage() {
    cat <<'EOF'
用法: ./manage.sh [全局选项] <子命令> [参数...]

子命令:
  doctor    环境体检（工具、Rust target、Buildroot 树、output 可写性）
  build     构建 Rust 静态二进制 + Buildroot 镜像（原 Stage 1-3/5）
  verify    只读验收：GPT/ESP/内核策略/rootfs（原 Stage 4，不触发构建）
  package   打包镜像四件套 + SHA256SUMS + build-info 到 dist/
  clean     清理构建状态（默认保留 dl/ 下载缓存；--all 连缓存一起清）
  flash     把 sdcard.img 烧录到整盘设备（保留/擦除 CAOSDATA，二次确认）
  run       用 QEMU + OVMF 冒烟启动 sdcard.img（本地可选，CI 不执行）
  version   打印项目版本、git 信息与工具链版本
  release   package + 生成 RELEASE_NOTES.md 骨架 + （可选）打 git tag

全局选项:
  -o, --output DIR        输出目录（Buildroot O=），默认 $PROJECT_DIR/output
  -b, --buildroot DIR     Buildroot 源码树，默认 $PROJECT_DIR/../buildroot-2026.08.1
  -d, --download-dir DIR  下载缓存目录，默认 <output>/dl
  -j, --jobs N            构建并行度，默认 nproc
      --clean             （build）构建前清空整个输出目录
      --skip-clippy       （build）跳过 cargo clippy
      --skip-verify       （build）兼容保留；build 默认已不自动跑 verify
  -v, --verbose           打印生效配置
      --json              机器可读输出（doctor/verify/version）
  -h, --help              显示本帮助
  --                      之后的内容不再按全局选项解析

示例:
  ./manage.sh doctor --json
  ./manage.sh build -j 8 --buildroot /path/to/buildroot
  ./manage.sh verify
  ./manage.sh flash /dev/sdX --keep --yes --dry-run

退出码: 0 成功 | 1 运行失败 | 2 用法错误 | 3 前置条件不满足
EOF
}
