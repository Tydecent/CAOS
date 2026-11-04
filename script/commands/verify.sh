#!/usr/bin/env bash
# commands/verify.sh — 原 build.sh Stage 4 的全部验收检查，只读 output/，不触发构建。
# 用法: ./manage.sh verify [--json]
# 退出码: 全部通过 0；有检查失败 1；缺产物/缺工具 3。
#
# 启动时若 output/.state/config.env 存在则恢复构建时的路径配置，
# 否则使用当前 CLI 全局参数。

source "$MANAGE_DIR/script/lib/verify.sh"

cmd_verify_usage() {
    cat <<'EOF'
用法: ./manage.sh verify [--json]

只读验收（不构建）：
  sdcard.img / boot.vfat / rootfs.squashfs / bootx64.efi 存在
  grub-script-check 通过；validate-image.py GPT/ESP 布局校验
  EFI 为 PE32+ 且内嵌 CAOSBOOT 查找与 grub.cfg 加载脚本
  sdcard.img 内 ESP 与 boot.vfat 一致；BOOTX64.EFI/zImage 与构建产物一致
  ESP grub.cfg 含完整内核命令行；无 extlinux/syslinux/mbr 残留
  内核 .config：CONFIG_NET/MODULES 关闭、STRICT_KERNEL_RWX、RANDOMIZE_BASE、
    GPT-only 分区、dm-crypt/AES-XTS、fbcon、禁 SOUND/MEI/I915
  cryptsetup gcrypt 后端；musl nscd ENOSYS 补丁生效
  squashfs 内 caos-ca/config.toml/init 脚本存在且权限属主正确
  rootfs 无网络命令（sshd/curl/wget/wpa_supplicant/ip/ifconfig/udhcpc/route）

缺关键产物时退出 3 并提示先运行 ./manage.sh build。
EOF
}

cmd_verify() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) cmd_verify_usage; return 0 ;;
            --json)    OPT_JSON=1 ;;
            *)         die 2 "verify: 未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    # 恢复构建时配置（存在则覆盖当前 CLI 解析出的路径）
    load_config_env || true
    refresh_state_dir

    # ---- 前置产物（缺失 → 3，提示先 build）----
    [ -s "$SDCARD_IMAGE" ]  || die 3 "$SDCARD_IMAGE 未生成，先运行 ./manage.sh build"
    [ -s "$BOOT_IMAGE" ]    || die 3 "$BOOT_IMAGE 未生成，先运行 ./manage.sh build"
    [ -s "$ROOTFS_IMAGE" ]  || die 3 "$ROOTFS_IMAGE 未生成，先运行 ./manage.sh build"
    [ -s "$EFI_IMAGE" ]     || die 3 "$EFI_IMAGE 未生成，先运行 ./manage.sh build"

    need python3 "validate-image.py（GPT/ESP 校验）"
    need unsquashfs "rootfs 验收"
    need file "PE32+ / 静态链接校验"
    need grep "配置检查"
    need cmp "产物一致性比对"

    [ -x "$HOST_MCOPY" ]    || die 3 "host mcopy 缺失: $HOST_MCOPY，先运行 ./manage.sh build"
    [ -x "$HOST_MDIR" ]     || die 3 "host mdir 缺失: $HOST_MDIR，先运行 ./manage.sh build"
    [ -x "$HOST_GRUB_SCRIPT_CHECK" ] || die 3 "host grub-script-check 缺失: $HOST_GRUB_SCRIPT_CHECK，先运行 ./manage.sh build"
    [ -f "$VALIDATOR" ]     || die 3 "镜像布局校验器缺失: $VALIDATOR（Python 脚本无需可执行位）"

    acquire_lock shared
    verify_reset

    mkdir -p "$OUTPUT_DIR/verification"
    local esp_check_dir="$OUTPUT_DIR/verification/esp"
    rm -rf -- "$esp_check_dir"
    mkdir -p "$esp_check_dir"

    # ---- 1. GRUB 脚本语法 ----
    if "$HOST_GRUB_SCRIPT_CHECK" "$BR2_EXTERNAL_DIR/board/caos/grub-builtin.cfg" \
        && "$HOST_GRUB_SCRIPT_CHECK" "$BR2_EXTERNAL_DIR/board/caos/grub.cfg"; then
        check_pass "GRUB embedded 与 ESP 脚本解析通过"
    else
        fail_check "GRUB embedded/ESP 脚本解析失败"
    fi

    # ---- 2. validate-image.py GPT/ESP 布局 ----
    local layout_txt="$OUTPUT_DIR/verification/image-layout.txt"
    if python3 "$VALIDATOR" "$SDCARD_IMAGE" "$BOOT_IMAGE" | tee "$layout_txt"; then
        check_pass "validate-image.py GPT/ESP 布局校验通过"
    else
        fail_check "validate-image.py GPT/ESP 布局校验失败（详见 $layout_txt）"
    fi

    # ---- 3. EFI 应用 ----
    local efi_file_output
    efi_file_output="$(file "$EFI_IMAGE")"
    printf '%s\n' "$efi_file_output" | grep -q 'PE32+ executable' \
        || fail_check "GRUB EFI 不是 PE32+ 可执行文件: $efi_file_output"
    printf '%s\n' "$efi_file_output" | grep -qi 'EFI.*application' \
        || fail_check "GRUB EFI 未被识别为 EFI application: $efi_file_output"
    # 嵌入脚本必须按标签定位 ESP 并链式加载 grub.cfg
    grep -aFq 'search --no-floppy --label CAOSBOOT --set=root' "$EFI_IMAGE" \
        || fail_check "BOOTX64.EFI 未内嵌 CAOS ESP search 脚本"
    # shellcheck disable=SC2016  # ($root) 是 GRUB 脚本字面量，不能展开
    grep -aFq 'configfile ($root)/EFI/BOOT/grub.cfg' "$EFI_IMAGE" \
        || fail_check "BOOTX64.EFI 未内嵌 grub.cfg 加载器"
    cmp -s "$OUTPUT_DIR/images/efi-part/EFI/BOOT/grub.cfg" \
        "$BR2_EXTERNAL_DIR/board/caos/grub.cfg" \
        || fail_check "efi-part/EFI/BOOT/grub.cfg 不是 CAOS 启动菜单"

    # ---- 4. 校验最终镜像内的 ESP（而非仅独立的 boot.vfat）----
    # ESP 偏移/大小与 GPT 布局（genimage.cfg：1 MiB 对齐、64 MiB ESP）耦合。
    # 优先从 validate-image.py 输出动态读取 start/sectors，失败则回退到
    # ESP_SKIP_SECTORS=2048 / ESP_COUNT_SECTORS=131072。
    local esp_skip="$ESP_SKIP_SECTORS" esp_count="$ESP_COUNT_SECTORS"
    if [ -s "$layout_txt" ] \
        && grep -Eq 'partition .* CAOSBOOT .* start=[0-9]+ sectors=[0-9]+' "$layout_txt"; then
        esp_skip="$({ sed -n 's/.* CAOSBOOT .* start=\([0-9]\+\) sectors=\([0-9]\+\).*/\1/p' "$layout_txt" || true; } | head -1)"
        esp_count="$({ sed -n 's/.* CAOSBOOT .* start=\([0-9]\+\) sectors=\([0-9]\+\).*/\2/p' "$layout_txt" || true; } | head -1)"
        check_pass "ESP 偏移动态读取: start=$esp_skip sectors=$esp_count"
    else
        log "[CAOS][verify] NOTE: 无法从 validator 输出解析 ESP 偏移，回退到固定值 ($esp_skip/$esp_count)"
    fi
    local esp_ok=0
    if dd if="$SDCARD_IMAGE" of="$esp_check_dir/disk-esp.raw" bs=512 \
            skip="$esp_skip" count="$esp_count" status=none; then
        if cmp -s "$esp_check_dir/disk-esp.raw" "$BOOT_IMAGE"; then
            check_pass "sdcard.img 内 CAOSBOOT 分区与 boot.vfat 一致"
        else
            fail_check "sdcard.img 内 CAOSBOOT 分区与 boot.vfat 不一致"
        fi
    else
        fail_check "从 sdcard.img 提取 ESP 失败 (skip=$esp_skip count=$esp_count)"
        esp_ok=1
    fi

    # ---- 5. ESP 内容与构建产物一致性 ----
    if [ "$esp_ok" -eq 0 ]; then
        if "$HOST_MCOPY" -i "$BOOT_IMAGE" ::/EFI/BOOT/BOOTX64.EFI "$esp_check_dir/BOOTX64.EFI" >/dev/null 2>&1 \
            && "$HOST_MCOPY" -i "$BOOT_IMAGE" ::/EFI/BOOT/grub.cfg "$esp_check_dir/grub.cfg" >/dev/null 2>&1 \
            && "$HOST_MCOPY" -i "$BOOT_IMAGE" ::/zImage "$esp_check_dir/zImage" >/dev/null 2>&1; then
            cmp -s "$esp_check_dir/BOOTX64.EFI" "$EFI_IMAGE" \
                || fail_check "ESP 内 BOOTX64.EFI 与 Buildroot GRUB EFI 镜像不一致"
            cmp -s "$esp_check_dir/zImage" "$BZIMAGE" \
                || fail_check "ESP 内 zImage 与 output/images/bzImage 不一致"
            check_pass "ESP 内 BOOTX64.EFI/zImage 与构建产物比对完成"
        else
            fail_check "从 ESP 提取 BOOTX64.EFI/grub.cfg/zImage 失败"
        fi

        # ESP grub.cfg 必须含完整内核命令行，且与源一致
        local grub_append='linux /zImage console=tty0 console=ttyS0,115200 root=PARTLABEL=CAOSROOT rootfstype=squashfs ro rootwait'
        grep -Fq "$grub_append" "$esp_check_dir/grub.cfg" \
            || fail_check "ESP grub.cfg 缺少要求的 CAOS 内核命令行"
        cmp -s "$esp_check_dir/grub.cfg" "$BR2_EXTERNAL_DIR/board/caos/grub.cfg" \
            || fail_check "ESP grub.cfg 不是 CAOS 启动菜单"
    fi

    # ---- 6. ESP 目录列表：纯 GPT/UEFI，无 BIOS 残留 ----
    local esp_files="$OUTPUT_DIR/verification/esp-files.txt"
    if "$HOST_MDIR" -i "$BOOT_IMAGE" -b -/ :: >"$esp_files" 2>/dev/null; then
        if grep -Eiq '(^|/)(extlinux|ldlinux[^/]*|syslinux[^/]*|mbr[^/]*)(/|$)' "$esp_files"; then
            fail_check "UEFI ESP 上发现 legacy BIOS/SYSLINUX 残留"
        else
            check_pass "ESP 无 extlinux/syslinux/mbr 残留"
        fi
        # UEFI 可移动介质默认路径，内核与启动菜单相邻
        verify_esp_listing "$esp_files" "UEFI 默认启动路径" \
            /EFI/BOOT/BOOTX64.EFI /EFI/BOOT/grub.cfg /zImage || true
    else
        fail_check "mdir 列举 ESP 失败"
    fi

    # ---- 7. 内核 .config 策略（气隙 / GPT-only / fbcon / 裁剪驱动）----
    local kernel_configs=() kernel_config
    while IFS= read -r -d '' config; do
        kernel_configs+=("$config")
    done < <(find "$OUTPUT_DIR/build" -maxdepth 2 -type f -path '*/linux-*/.config' -print0 2>/dev/null || true)
    if [ "${#kernel_configs[@]}" -eq 0 ]; then
        fail_check "未找到 output/build/linux-*/.config"
    else
        kernel_config="${kernel_configs[0]}"
        log "[CAOS][verify] 内核配置: $kernel_config"
        # 气隙策略：无网络、无模块
        verify_kernel_option "$kernel_config" '# CONFIG_NET is not set' || true
        verify_kernel_option "$kernel_config" '# CONFIG_MODULES is not set' || true
        verify_kernel_option "$kernel_config" 'CONFIG_STRICT_KERNEL_RWX=y' || true
        verify_kernel_option "$kernel_config" 'CONFIG_RANDOMIZE_BASE=y' || true
        # 内核命令行使用 root=PARTLABEL=CAOSROOT，盘是 GPT-only
        verify_kernel_option "$kernel_config" 'CONFIG_EFI_PARTITION=y' || true
        verify_kernel_option "$kernel_config" '# CONFIG_MSDOS_PARTITION is not set' || true
        # dm-crypt/AES-XTS：cryptsetup 打开后挂载 CAOSDATA 的数据路径
        local option
        for option in CONFIG_DM_CRYPT=y CONFIG_CRYPTO_AES=y CONFIG_CRYPTO_XTS=y; do
            verify_kernel_option "$kernel_config" "$option" || true
        done
        # UEFI 提供 GOP framebuffer 而非 VGA text mode；没有 fbcon 屏幕会停在 GRUB 最后一行
        for option in \
            CONFIG_DRM_FBDEV_EMULATION=y \
            CONFIG_DRM_SIMPLEDRM=y \
            CONFIG_SYSFB_SIMPLEFB=y \
            CONFIG_FRAMEBUFFER_CONSOLE=y \
            CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY=y; do
            verify_kernel_option "$kernel_config" "$option" || true
        done
        # 家电类/易引发固件复位风暴的驱动禁用
        for option in \
            '# CONFIG_SOUND is not set' \
            '# CONFIG_INTEL_MEI is not set' \
            '# CONFIG_DRM_I915 is not set'; do
            verify_kernel_option "$kernel_config" "$option" || true
        done
    fi

    # ---- 8. cryptsetup gcrypt 后端 ----
    # "kernel" 后端依赖 AF_ALG，CONFIG_NET=n 下不存在，luksFormat 会失败
    local cryptsetup_log
    cryptsetup_log="$(find "$OUTPUT_DIR/build" -maxdepth 2 -type f \
        -path '*/cryptsetup-*/config.log' -print -quit 2>/dev/null || true)"
    if [ -n "$cryptsetup_log" ]; then
        grep -q -- '--with-crypto_backend=gcrypt' "$cryptsetup_log" \
            || fail_check "cryptsetup 未配置 gcrypt 后端: $cryptsetup_log"
        if grep -q -- '--with-crypto_backend=kernel' "$cryptsetup_log"; then
            fail_check "cryptsetup 仍使用 kernel 后端（需要 AF_ALG/NET）: $cryptsetup_log" || true
        fi
        check_pass "cryptsetup 用户态 gcrypt 后端已确认"
    else
        fail_check "未找到 cryptsetup config.log（$OUTPUT_DIR/build 下）"
    fi

    # ---- 9. musl nscd ENOSYS 补丁 ----
    # CONFIG_NET=n 移除了全部 socket 系统调用（返回 ENOSYS）；原生 musl 只容忍
    # EAFNOSUPPORT，导致 initgroups()/su caos 失败。BR2_GLOBAL_PATCH_DIR 补丁
    # 必须体现在实际参与构建的 musl 源码中。
    local musl_nscd
    musl_nscd="$(find "$OUTPUT_DIR/build" -maxdepth 6 -type f \
        -path '*/musl-*/src/passwd/nscd_query.c' -print -quit 2>/dev/null || true)"
    if [ -n "$musl_nscd" ]; then
        grep -q 'EAFNOSUPPORT || errno == ENOSYS' "$musl_nscd" \
            || fail_check "musl 未把缺失的 socket 系统调用当作 'no nscd': $musl_nscd"
        check_pass "musl getgrouplist()/initgroups() 无 socket 补丁生效"
    else
        fail_check "未找到 musl src/passwd/nscd_query.c（$OUTPUT_DIR/build 下）"
    fi

    # ---- 10. rootfs.squashfs 内容与权限 ----
    # 两个列表：-l 仅路径（存在性/黑名单检查）；-lln 含属主/权限列（权限检查）。
    local unsquash_list="$OUTPUT_DIR/unsquashfs-list.txt"
    local unsquash_lln_list="$OUTPUT_DIR/unsquashfs-lln-list.txt"
    if unsquashfs -l "$ROOTFS_IMAGE" >"$unsquash_list" 2>/dev/null; then
        if unsquashfs -lln "$ROOTFS_IMAGE" >"$unsquash_lln_list" 2>/dev/null; then
            verify_squashfs_perms "$unsquash_lln_list" "squashfs-root/usr/bin/caos-ca" \
                "-rwxr-xr-x 0/0" "镜像内 caos-ca 应为 root:root 0755" || true
            verify_squashfs_perms "$unsquash_lln_list" "squashfs-root/mnt/ca-data" \
                "drwx------ 1000/1000" "镜像内 /mnt/ca-data 应为 caos:caos 0700" || true
            verify_squashfs_perms "$unsquash_lln_list" "squashfs-root/etc/caos-ca/config.toml" \
                "-r--r--r-- 0/0" "镜像内 config.toml 应为 root:root 0444" || true
        else
            fail_check "unsquashfs -lln 解析 $ROOTFS_IMAGE 失败（权限/属主检查跳过）"
        fi
        grep -q '^squashfs-root/usr/bin/caos-ca$' "$unsquash_list" \
            || fail_check "rootfs.squashfs 缺少 /usr/bin/caos-ca"
        grep -q '^squashfs-root/etc/caos-ca/config.toml$' "$unsquash_list" \
            || fail_check "rootfs.squashfs 缺少 /etc/caos-ca/config.toml"
        grep -q '^squashfs-root/etc/init.d/S10caos-data$' "$unsquash_list" \
            || fail_check "rootfs.squashfs 缺少 S10caos-data"
        grep -q '^squashfs-root/etc/init.d/S20caos-ca$' "$unsquash_list" \
            || fail_check "rootfs.squashfs 缺少 S20caos-ca"
        check_pass "rootfs overlay 内容存在性检查完成"
    else
        fail_check "unsquashfs -l 解析 $ROOTFS_IMAGE 失败"
    fi

    # ---- 11. 禁止网络命令 ----
    local forbidden
    for forbidden in sshd curl wget wpa_supplicant ip ifconfig udhcpc route; do
        if grep -Eq "(^|/)${forbidden}\$" "$unsquash_list" 2>/dev/null; then
            fail_check "rootfs 内存在被禁止的网络命令: $forbidden"
        fi
    done
    check_pass "rootfs 网络命令黑名单扫描完成"

    # ---- 12. 汇总 ----
    if ! verify_summary_ok; then
        if [ "$OPT_JSON" -eq 1 ]; then
            {
                printf '{"ok": false, "failures": [\n'
                local i=0 f
                for f in "${VERIFY_FAILURE_LIST[@]}"; do
                    [ "$i" -gt 0 ] && printf ',\n'
                    printf '  "%s"' "$(json_escape "$f")"
                    i=$((i + 1))
                done
                printf '\n]}\n'
            } > /tmp/.caos_verify_json
            cat /tmp/.caos_verify_json
            rm -f /tmp/.caos_verify_json
        else
            log "[CAOS] 验收失败：$VERIFY_FAILURES 项"
        fi
        exit 1
    fi

    mark_stage verify

    # ---- 汇总报告（原 Stage 5 摘要）----
    {
        echo "boot scheme: UEFI only (GRUB 2 x86_64-efi, standard GPT, ESP CAOSBOOT)"
        echo "GRUB EFI file(1): $efi_file_output"
        echo
        echo "kernel config: ${kernel_config:-unknown}"
        grep -E '^(# CONFIG_(NET|INET|IPV6|PACKET|MODULES|MSDOS_PARTITION) is not set|CONFIG_(STRICT_KERNEL_RWX|STRICT_MODULE_RWX|RANDOMIZE_BASE|EFI_PARTITION|DM_CRYPT|CRYPTO_AES|CRYPTO_XTS|DRM_FBDEV_EMULATION|DRM_SIMPLEDRM|SYSFB_SIMPLEFB|FRAMEBUFFER_CONSOLE|FRAMEBUFFER_CONSOLE_DETECT_PRIMARY)=y)$' \
            "$kernel_config" 2>/dev/null || true
        echo "cryptsetup crypto backend: gcrypt (userspace; AF_ALG is unavailable with CONFIG_NET=n)"
        echo
        echo "GPT/ESP layout validation:"
        cat "$layout_txt"
        echo
        echo "ESP directory listing:"
        cat "$esp_files"
        echo
        echo "ESP grub.cfg:"
        cat "$esp_check_dir/grub.cfg" 2>/dev/null || true
        echo
        echo "rootfs.squashfs caos-ca listing:"
        unsquashfs -ll "$ROOTFS_IMAGE" 2>/dev/null | grep -E '/usr/bin/caos-ca$' || true
        echo
        echo "images:"
        ls -lh "$OUTPUT_DIR/images"
    } >"$OUTPUT_DIR/verification/summary.txt"

    if [ "$OPT_JSON" -eq 1 ]; then
        printf '{"ok": true, "failures": []}\n'
    else
        log "[CAOS] 验收摘要: $OUTPUT_DIR/verification/summary.txt"
        log "[CAOS] 验收全部通过；UEFI 启动验证请另行使用 QEMU（./manage.sh run）或真实硬件。"
    fi
}
