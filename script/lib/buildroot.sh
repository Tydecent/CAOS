#!/usr/bin/env bash
# buildroot.sh — Buildroot 调用封装。只封装命令行形态，不含构建策略。

# br_make TARGET... —— 等价于:
#   cd "$BUILDROOT_PATH" && BR2_DL_DIR="$DOWNLOAD_DIR" \
#       make O="$OUTPUT_DIR" BR2_EXTERNAL="$BR2_EXTERNAL_DIR" TARGET...
# （BR2_DL_DIR 是 Buildroot 子进程环境变量，允许通过环境传递）
br_make() {
    (
        cd "$BUILDROOT_PATH" || exit 1
        BR2_DL_DIR="$DOWNLOAD_DIR" \
            make O="$OUTPUT_DIR" BR2_EXTERNAL="$BR2_EXTERNAL_DIR" "$@"
    )
}

br_defconfig() {
    br_make caos_defconfig
}
