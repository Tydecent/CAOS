#!/usr/bin/env bash
#
# manage.sh — CAOS 项目管理唯一入口。
# 只做三件事：加载库、解析全局参数、分发子命令。业务逻辑全部在 script/ 下。
#
# 退出码约定：0 成功；1 运行失败；2 用法错误；3 前置条件不满足（缺工具/缺产物）。
set -Eeuo pipefail
IFS=$'\n\t'

MANAGE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export PROJECT_DIR="$MANAGE_DIR"

# shellcheck source=script/lib/common.sh
source "$MANAGE_DIR/script/lib/common.sh"
# shellcheck source=script/lib/config.sh
source "$MANAGE_DIR/script/lib/config.sh"
# shellcheck source=script/lib/state.sh
source "$MANAGE_DIR/script/lib/state.sh"

main() {
    parse_global_args "$@"

    local cmd="${PARSED_ARGS[0]:-}"
    if [ -z "$cmd" ]; then
        top_usage >&2
        exit 2
    fi

    local cmd_file="$MANAGE_DIR/script/commands/$cmd.sh"
    if [ ! -f "$cmd_file" ]; then
        printf '[CAOS] ERROR: 未知子命令: %s\n' "$cmd" >&2
        printf '可用子命令: %s\n' "$MANAGE_COMMANDS" >&2
        printf '运行 ./manage.sh --help 查看用法。\n' >&2
        exit 2
    fi

    # 统一路径解析与派生（命令各自的参数由其自行解析）
    resolve_config
    init_derived_paths
    if [ "$OPT_VERBOSE" -eq 1 ]; then
        print_config
    fi

    # shellcheck source=script/commands/build.sh
    source "$cmd_file"
    local fn="cmd_$cmd"
    if ! declare -F "$fn" >/dev/null 2>&1; then
        die 2 "子命令文件缺少入口函数 cmd_$cmd: $cmd_file"
    fi
    "$fn" "${PARSED_ARGS[@]:1}"
}

main "$@"
