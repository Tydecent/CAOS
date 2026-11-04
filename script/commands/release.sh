#!/usr/bin/env bash
# commands/release.sh — package + RELEASE_NOTES.md 骨架 + （可选）打 git tag。
# 用法: ./manage.sh release [--tag vX.Y.Z] [--yes] [--out DIR] [--dry-run]
#   默认 --dry-run：只打印将执行的 git tag，不创建。
#   打 tag 必须 --tag 显式指定且 --yes；非 TTY 且无 --yes 直接拒绝。
#   不做 git push，不调用 GitHub API。

cmd_release_usage() {
    cat <<'EOF'
用法: ./manage.sh release [--tag vX.Y.Z] [--yes] [--out DIR] [--dry-run]

流程:
  1. 执行 package（镜像四件套 + SHA256SUMS + build-info → dist/）
  2. 在 --out 目录生成 RELEASE_NOTES.md 骨架
  3. 若指定 --tag：默认 dry-run 只打印 `git tag <tag>`；
     --tag + --yes 才真正创建本地 tag（不 push）

参数:
  --tag TAG  要打的 git tag
  --yes      确认执行（非交互模式必填）
  --out DIR  包输出目录（默认 dist/）
  --dry-run  只打印不执行（默认行为）
EOF
}

cmd_release() {
    local tag="" assume_yes=0 out_dir="$PROJECT_DIR/dist" dry_run=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) cmd_release_usage; return 0 ;;
            --tag)     [ "$#" -ge 2 ] || die 2 "release: --tag 需要参数"; tag=$2; shift ;;
            --tag=*)   tag=${1#*=} ;;
            --yes)     assume_yes=1 ;;
            --out)     [ "$#" -ge 2 ] || die 2 "release: --out 需要目录参数"; out_dir=$2; shift ;;
            --out=*)   out_dir=${1#*=} ;;
            --dry-run) dry_run=1 ;;
            *)         die 2 "release: 未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    # 1. 打包（沿用 package 的参数解析）
    # shellcheck source=script/commands/package.sh
    source "$MANAGE_DIR/script/commands/package.sh"
    if [ "$dry_run" -eq 1 ]; then
        cmd_package --out "$out_dir" --dry-run
    else
        cmd_package --out "$out_dir"
    fi

    # 2. RELEASE_NOTES.md 骨架
    out_dir="$(abspath "$out_dir")"
    local notes="$out_dir/RELEASE_NOTES.md"
    local version
    version="$(project_version)"
    if [ ! -f "$notes" ]; then
        if [ "$dry_run" -eq 1 ]; then
            log "[CAOS] [dry-run] 将生成: $notes"
        else
            mkdir -p "$out_dir"
            cat >"$notes" <<EOF
# CAOS $version Release Notes

## 变更摘要

- （待填写）

## 镜像

EOF
            local pkg_glob pkg_found=""
            for pkg_glob in "$out_dir"/caos-*.tar.gz; do
                [ -f "$pkg_glob" ] && { pkg_found="$(basename -- "$pkg_glob")"; break; }
            done
            cat >>"$notes" <<EOF
- 产物: ${pkg_found:-（见同目录 tar.gz）}
- 校验和: SHA256SUMS
- 构建信息: build-info.json

## 已知限制

- UEFI Secure Boot 未签名（需在固件中关闭）
- x86_64 UEFI only（无 BIOS/PXE 启动路径）

## 升级 / 烧录

    ./manage.sh flash /dev/sdX --keep   # 保留 CAOSDATA
    ./manage.sh flash /dev/sdX --erase  # 重写整盘
EOF
            log "[CAOS] 已生成: $notes"
        fi
    fi

    # 3. git tag
    if [ -z "$tag" ]; then
        log "[CAOS] 未指定 --tag，跳过打 tag。"
        return 0
    fi
    need git "打 tag"
    if [ "$dry_run" -eq 1 ]; then
        log "[CAOS] [dry-run] 将执行: git tag $tag"
        return 0
    fi
    if [ "$assume_yes" -ne 1 ]; then
        if [ ! -t 0 ]; then
            die 2 "非交互模式打 tag 必须显式传 --yes"
        fi
        confirm "创建 git tag $tag?"
    fi
    git tag "$tag"
    log "[CAOS] 已创建 tag: $tag（不 push；发布请自行 git push origin $tag）"
}
