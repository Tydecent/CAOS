#!/usr/bin/env bash
# verify.sh — 可复用的验收检查原语（失败计数器 + 常见检查封装）。
# 项目策略（如"内核必须 CONFIG_NET=n"）在 commands/verify.sh 中组合这些原语。

VERIFY_FAILURES=0
VERIFY_FAILURE_LIST=()

verify_reset() {
    VERIFY_FAILURES=0
    VERIFY_FAILURE_LIST=()
}

# fail_check 描述 —— 记录一次失败。返回 0：调用方无需防备 set -e，
# 流程继续执行完所有检查，最后由 verify_summary_ok 统一判定。
fail_check() {
    VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
    VERIFY_FAILURE_LIST+=("$1")
    log "[CAOS][verify] FAIL: $1"
    return 0
}

check_pass() {
    log "[CAOS][verify] PASS: $1"
}

# verify_file_exists PATH 描述 —— 存在且非空
verify_file_exists() {
    if [ -s "$1" ]; then
        check_pass "$2: $1"
        return 0
    fi
    fail_check "$2 缺失或为空: $1"
}

# verify_kernel_option CONFIG_FILE LINE —— LINE 是完整配置行，
# 如 'CONFIG_X=y' 或 '# CONFIG_X is not set'
verify_kernel_option() {
    local config=$1 line=$2
    if grep -qx "$line" "$config"; then
        check_pass "$config 包含 $line"
        return 0
    fi
    fail_check "$config 缺少 $line"
}

# verify_squashfs_perms LLN_LIST_FILE PATH EXPECTED_PREFIX 描述
# LLN_LIST_FILE 必须来自 `unsquashfs -lln`（含属主/权限列，形如 "-rwxr-xr-x 0/0"）；
# `unsquashfs -l` 的输出只有路径，不能用于本检查。
verify_squashfs_perms() {
    local list_file=$1 path=$2 expected=$3 desc=$4 line
    line="$(grep " $path\$" "$list_file" 2>/dev/null || true)"
    if [ -z "$line" ]; then
        fail_check "squashfs 列表中找不到 $path（检查项: $desc；列表: $list_file）"
        return 0
    fi
    case "$line" in
        "$expected "*)
            check_pass "$desc: $path 为 $expected"
            return 0
            ;;
        *)
            fail_check "$desc: $path 权限/属主不符，期望 $expected，实际: $line"
            return 0
            ;;
    esac
}

# verify_esp_listing LIST_FILE REQUIRED_PATH... —— ESP 目录列表必须包含全部路径
verify_esp_listing() {
    local list_file=$1 desc=$2
    shift 2
    local p ok=0
    for p in "$@"; do
        if grep -q "^::$p\$" "$list_file"; then
            check_pass "$desc: ESP 含 $p"
        else
            fail_check "$desc: ESP 缺少 $p"
            ok=1
        fi
    done
    return "$ok"
}

# 汇总：有失败返回 1（调用方决定退出码与 JSON 输出）
verify_summary_ok() {
    [ "$VERIFY_FAILURES" -eq 0 ]
}
