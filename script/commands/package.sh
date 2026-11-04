#!/usr/bin/env bash
# commands/package.sh — 打包镜像四件套 + SHA256SUMS + build-info + 验收摘要。
# 用法: ./manage.sh package [--out DIR] [--dry-run]
# 依赖 build 的产物与 output/.state/{build-info.json,config.env}。

cmd_package_usage() {
    cat <<'EOF'
用法: ./manage.sh package [--out DIR] [--dry-run]

参数:
  --out DIR   输出目录（默认 dist/）
  --dry-run   只打印将生成的文件，不实际打包

产物: <out>/caos-<version>-<os>-<arch>.tar.gz
  images/{sdcard.img,boot.vfat,rootfs.squashfs,bzImage}
  SHA256SUMS、build-info.json、verification/summary.txt
同时把 SHA256SUMS 写到 <out>/ 下，便于单独上传。
EOF
}

cmd_package() {
    local out_dir="$PROJECT_DIR/dist" dry_run=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)  cmd_package_usage; return 0 ;;
            --out)      [ "$#" -ge 2 ] || die 2 "package: --out 需要目录参数"; out_dir=$2; shift ;;
            --out=*)    out_dir=${1#*=} ;;
            --dry-run)  dry_run=1 ;;
            *)          die 2 "package: 未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    # 构建时配置
    load_config_env || true
    refresh_state_dir
    [ -f "$STATE_DIR/build-info.json" ] || die 3 "缺少 $STATE_DIR/build-info.json，先运行 ./manage.sh build"

    need sha256sum "生成 SHA256SUMS"
    need tar "打包"

    local images=(sdcard.img boot.vfat rootfs.squashfs bzImage) img missing=0
    for img in "${images[@]}"; do
        [ -s "$OUTPUT_DIR/images/$img" ] || { log "[CAOS] 缺少镜像: output/images/$img"; missing=1; }
    done
    [ "$missing" -eq 0 ] || die 3 "镜像四件套不完整，先运行 ./manage.sh build"

    local version os arch pkg_name pkg_path staging
    version="$({ sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$STATE_DIR/build-info.json" || true; } | head -1)"
    [ -n "$version" ] || version="$(project_version)"
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    pkg_name="caos-${version}-${os}-${arch}.tar.gz"
    pkg_path="$(abspath "$out_dir")/$pkg_name"
    staging="$(abspath "$out_dir")/.staging-$pkg_name"

    if [ "$dry_run" -eq 1 ]; then
        log "[CAOS] [dry-run] 将生成: $pkg_path"
        for img in "${images[@]}"; do
            log "[CAOS] [dry-run]   images/$img ($(stat -c '%s' "$OUTPUT_DIR/images/$img") bytes)"
        done
        log "[CAOS] [dry-run]   SHA256SUMS"
        log "[CAOS] [dry-run]   build-info.json"
        log "[CAOS] [dry-run]   verification/summary.txt"
        return 0
    fi

    acquire_lock shared
    mkdir -p "$staging/images" "$staging/verification" "$out_dir"

    for img in "${images[@]}"; do
        cp -- "$OUTPUT_DIR/images/$img" "$staging/images/$img"
    done
    cp -- "$STATE_DIR/build-info.json" "$staging/build-info.json"
    if [ -f "$OUTPUT_DIR/verification/summary.txt" ]; then
        cp -- "$OUTPUT_DIR/verification/summary.txt" "$staging/verification/summary.txt"
    else
        log "[CAOS] WARNING: verification/summary.txt 缺失（尚未跑 ./manage.sh verify），包内将不含验收摘要"
    fi

    (cd -- "$staging" && sha256sum images/sdcard.img images/boot.vfat images/rootfs.squashfs images/bzImage >SHA256SUMS)
    cp -- "$staging/SHA256SUMS" "$out_dir/SHA256SUMS"

    tar -czf "$pkg_path" -C "$staging" .
    rm -rf -- "$staging"

    log "[CAOS] 打包完成: $pkg_path"
    log "[CAOS] 校验和:   $out_dir/SHA256SUMS"
}
