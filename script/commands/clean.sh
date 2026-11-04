#!/usr/bin/env bash
# commands/clean.sh — 清理构建状态。默认保留 output/dl 下载缓存。
# 用法: ./manage.sh clean [--all] [--dry-run]

cmd_clean_usage() {
    cat <<'EOF'
用法: ./manage.sh clean [--all] [--dry-run]

参数:
  --all      连同 output/dl 下载缓存（与 .state）一起清
  --dry-run  只打印将删除的路径与大小，不删除

默认清理: output/{images,build,host,target,verification} 与 output/.state/stages
路径安全: 拒绝 /、$HOME、项目根目录及源码子目录（-o/--output 指定输出目录）
EOF
}

_clean_targets=(images build host target verification)

cmd_clean() {
    local all=0 dry_run=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) cmd_clean_usage; return 0 ;;
            --all)     all=1 ;;
            --dry-run) dry_run=1 ;;
            *)         die 2 "clean: 未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    # 路径安全：OUTPUT_DIR 在 resolve_config 中已拒绝 /、$HOME、PROJECT_DIR、源码目录
    ensure_safe_output_dir
    if [ "$OUTPUT_DIR" = "/" ] || [ "$OUTPUT_DIR" = "$HOME" ] || [ "$OUTPUT_DIR" = "$PROJECT_DIR" ]; then
        die 3 "clean: 拒绝清理危险路径: $OUTPUT_DIR"
    fi

    need du "统计待清理大小（--dry-run）"

    local targets=()
    local t
    for t in "${_clean_targets[@]}"; do
        targets+=("$OUTPUT_DIR/$t")
    done
    targets+=("$OUTPUT_DIR/.config")
    if [ "$all" -eq 1 ]; then
        targets+=("$OUTPUT_DIR/dl" "$OUTPUT_DIR/.state")
    else
        targets+=("$OUTPUT_DIR/.state/stages")
    fi

    acquire_lock exclusive

    local path size
    if [ "$dry_run" -eq 1 ]; then
        log "[CAOS] [dry-run] 将删除以下路径（共 $({ du -sch "${targets[@]}" 2>/dev/null || true; } | tail -1 | cut -f1) ）:"
        for path in "${targets[@]}"; do
            if [ -e "$path" ]; then
                size="$({ du -sh -- "$path" 2>/dev/null || true; } | cut -f1)"
                log "[CAOS] [dry-run]   $path  ($size)"
            fi
        done
        log "[CAOS] [dry-run] 未删除任何文件。"
        return 0
    fi

    for path in "${targets[@]}"; do
        if [ -e "$path" ]; then
            log "[CAOS] 清理: $path"
            rm -rf -- "$path"
        fi
    done
    if [ "$all" -eq 1 ]; then
        log "[CAOS] 清理完成（--all，含下载缓存与状态目录）。"
    else
        log "[CAOS] 清理完成（保留 $OUTPUT_DIR/dl 下载缓存）。"
    fi
}
