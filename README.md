# CAOS — 气隙 CA 管理系统

CAOS 是一个可烧录到 x86_64 机器（SD 卡 / USB / 磁盘）的气隙证书授权系统。它由两大部分组成：

- `caos-ca`：使用 Rust 编写的命令行 CA 工具，提供根 CA / 中间 CA 初始化、终端证书签发、列表、吊销与完整性校验。最终产物是静态链接的 `x86_64-unknown-linux-musl` ELF。
- Buildroot 镜像：64 MiB FAT32 EFI System Partition（ESP）+ 只读 squashfs 根文件系统 + 预留的 LUKS2 数据分区；标准 GPT、纯 x86_64 UEFI（GRUB EFI）启动，不支持 Legacy BIOS/CSM。内核关闭整个网络栈，rootfs 不含网络客户端或远程登录服务。

> **验证范围：本镜像已在 QEMU/OVMF 中完成 UEFI 启动和 LUKS2 格式化/打开验证**，串口和图形 console 均到达 `caos login:`，`cryptsetup luksFormat`/`luksOpen` 成功；**尚未在真实目标硬件上启动**。第 8.5 节记录 QEMU 证据，第 9 节列出真机仍需确认的限制。

---

## 1. 项目结构

```
project/
├── caos-ca/                          # Rust 工程
│   ├── .cargo/config.toml            # musl target、crt-static、静态 ELF
│   ├── Cargo.toml / Cargo.lock
│   ├── build.rs                      # 编译期 Unix 时间戳（时钟检查用）
│   └── src/
│       ├── main.rs                   # 进程加固入口
│       ├── cli.rs                    # clap 子命令
│       ├── config.rs                 # /etc/caos-ca/config.toml
│       ├── ca.rs                     # 根/中间 CA 初始化、签发、吊销
│       ├── crypto.rs                 # Argon2id + ChaCha20-Poly1305 根密钥封装
│       ├── secure.rs                 # PR_SET_DUMPABLE、core dump、mlock 秘密缓冲区
│       ├── audit.rs                  # append-only JSONL SHA-256 哈希链
│       ├── store.rs                  # 数据目录布局、元数据、完整性清单
│       ├── verify.rs                 # 文件/证书链/审计日志校验
│       ├── util.rs, clock.rs, error.rs
│       └── ...
├── caos-buildroot/                   # 全部 Buildroot 定制（BR2_EXTERNAL）
│   ├── external.desc
│   ├── external.mk
│   ├── Config.in
│   ├── configs/caos_defconfig
│   ├── board/caos/
│   │   ├── linux.fragment            # 气隙内核配置片段
│   │   ├── busybox.fragment          # 关闭全部网络相关 BusyBox applet
│   │   ├── rootfs-overlay/           # /etc、init.d、只读配置
│   │   ├── grub-builtin.cfg          # 嵌入 EFI 的 ESP 查找与 grub.cfg 加载
│   │   ├── grub.cfg                  # ESP 上的 CAOS 启动菜单和内核命令行
│   │   ├── genimage.cfg              # 标准 GPT、ESP + 根分区 + 数据分区
│   │   ├── validate-image.py         # 独立解析 GPT/ESP 的镜像验收器
│   │   ├── post-build.sh
│   │   ├── post-fakeroot.sh          # 记录最终 root:root / caos:caos 属主
│   │   ├── post-image.sh             # FAT32 ESP、GRUB EFI、genimage GPT
│   │   ├── patches/musl/             # BR2_GLOBAL_PATCH_DIR：musl 补丁
│   │   └── users.txt                 # caos UID/GID 1000
├── build.sh                          # 一键构建（Rust → Buildroot → 验证）
├── README.md
└── output/                           # 所有构建输出（不在 Buildroot 源码树内）
    ├── dl/                           # Buildroot 下载缓存
    ├── build/                        # Buildroot 构建目录
    ├── images/                       # 最终镜像
    ├── rust-build.log
    ├── clippy.log
    ├── build.log                     # 完整 Buildroot 日志
    └── verification/                 # summary、GPT/ESP 校验、QEMU 串口与截图
```

Buildroot 浅克隆 `../buildroot-2026.08.1/` 未做修改。下载目录通过 `BR2_DL_DIR` 指向 `output/dl/`，输出通过 `O=output/` 指向项目内，因此不会写入 `buildroot-2026.08.1/output/`。

### 镜像布局

`output/images/sdcard.img` 使用**标准 GPT**，不再生成混合 MBR/GPT 启动布局。GPT 本身按规范在 LBA 0 写一个仅含 `0xEE` 保护项的保护性 MBR；它不是 BIOS 启动路径，前 440 字节没有引导代码、没有 active 分区，也不安装 SYSLINUX 或 BIOS MBR 引导代码。p1 的 GPT 类型是 EFI System Partition（`C12A7328-F81F-11D2-BA4B-00A0C93EC93B`），不是普通 FAT 基本数据分区。

| 分区 | GPT 名称 / 文件系统 | 大小 | 内容 |
|---|---|---|---|
| p1 | `CAOSBOOT`，FAT32 ESP | 64 MiB | `\EFI\BOOT\BOOTX64.EFI`、`\EFI\BOOT\grub.cfg`、`\zImage` |
| p2 | `CAOSROOT`，squashfs | 128 MiB | 只读根文件系统 |
| p3 | `CAOSDATA`，初始为空 | 128 MiB | **构建时留空**，首次启动手工 LUKS2 格式化 |

UEFI 固件通过可移动介质默认路径 `\EFI\BOOT\BOOTX64.EFI` 启动 GRUB；GRUB 用嵌入式脚本按 FAT 卷标 `CAOSBOOT` 找到 ESP，再执行 `/EFI/BOOT/grub.cfg`。内核仍在 ESP 根目录，命令行通过 GRUB 的 `linux` 命令传递：

```text
console=tty0 console=ttyS0,115200 root=PARTLABEL=CAOSROOT rootfstype=squashfs ro rootwait
```

p3 在镜像构建阶段不会运行 `luksFormat`。LUKS header 和 CA 私钥都不在 `sdcard.img` 中。`S10caos-data` 依靠 GPT 标签 `CAOSDATA` 定位它，这一首次启动流程没有改变。

---

## 2. 构建

### 2.1 依赖

构建机：x86_64 Linux；本项目实际验证环境为 24 核、约 14 GiB 内存。

基本依赖（Debian/Ubuntu 包名）：

```bash
sudo apt-get install build-essential git wget curl cpio unzip rsync bc file \
    python3 perl bison flex libncurses-dev libssl-dev musl-tools squashfs-tools
```

Rust 侧（本项目使用 1.99.1，MSRV 声明为 1.88）：

```bash
rustup toolchain install stable
rustup target add x86_64-unknown-linux-musl
```

`musl-gcc`（`musl-tools` 包）是必需的：`ring` 的 C/汇编代码必须用 musl C 工具链编译。`build.sh` 会检查 `rustup target`、`musl-gcc`、`unsquashfs`、`python3`、`file` 等前置条件；缺失时直接失败，不会伪造成功。

Buildroot 会自行构建 host 工具（host-genimage、host-mtools、host-dosfstools、host-grub2、target grub2 等），因此不需要手工安装这些工具。UEFI 启动链使用 Buildroot 2026.08.1 自带的 **GRUB 2.14 x86_64-efi** 包；配置中只选择 `BR2_TARGET_GRUB2_X86_64_EFI`，没有选择 `i386-pc` 或其他 BIOS 平台，也没有自定义 SYSLINUX 包。

### 2.2 网络要求

构建需要网络，至少能访问：

- `https://crates.io` / crates.io 索引，用于 Rust 依赖；
- Buildroot 源码镜像。本配置优先使用 `https://sources.buildroot.net`，失败时按 Buildroot 默认逻辑回退上游；
- 核源码、工具链、BusyBox、util-linux、cryptsetup 等包源码。

本工程已把下载缓存指向 `output/dl/`。若网络不可用，构建会在下载阶段失败；应修复网络后重试，而不是关闭检查或伪造产物。首次完整构建需要下载工具链、内核与用户态包，下载量约数百 MiB。

### 2.3 一键构建

```bash
cd project
./build.sh
```

如果构建机内存较小，可用 `JOBS=8 ./build.sh` 限制 Buildroot 并发；本项目在约 14 GiB 内存的主机上使用 `JOBS=8` 完成最终构建。脚本使用 `set -euo pipefail`，任一阶段失败立即退出。阶段如下：

1. 检查/安装 `x86_64-unknown-linux-musl` target；
2. `cargo build --release --target x86_64-unknown-linux-musl`，检查 `file` 输出包含 `statically linked`，运行 `cargo clippy -- -D warnings`，将二进制安装到 overlay；
3. 执行 `make O=output BR2_EXTERNAL=caos-buildroot caos_defconfig`；
4. 执行完整 Buildroot 构建（大阶段，耗时最长）；
5. 验证标准 GPT/ESP 分区表、`\EFI\BOOT\BOOTX64.EFI` 默认启动路径、GRUB 命令行、内核 `CONFIG_NET`/GPT 设置、`rootfs.squashfs` 与镜像内文件，并打印产物大小。

预计耗时：在 24 核机器上，首次构建（含下载、工具链、内核、squashfs、镜像）通常需要 **约 15–40 分钟**，主要取决于网络、内存与 CPU。增量构建会快很多。本次保留 `output/dl` 下载缓存、清空其余构建输出后，以 `JOBS=8` 完整重跑；Buildroot 全部目标包、内核、GRUB EFI、squashfs、ESP 和 GPT 镜像均重新生成，从 20:15 到最终镜像完成约 **21 分钟**。实测数据见第 8 节。

产物：

```
output/images/bzImage                     # Buildroot 编译出的内核
output/images/efi-part/EFI/BOOT/bootx64.efi # Buildroot GRUB EFI 应用
output/images/boot.vfat                   # p1 的 FAT32 ESP
output/images/rootfs.squashfs             # p2 的只读根文件系统
output/images/sdcard.img                  # 完整可烧录 GPT 镜像
```

`boot.vfat` 由 `mkfs.vfat` + `mcopy` 生成，包含 `\EFI\BOOT\BOOTX64.EFI`、`\EFI\BOOT\grub.cfg` 和 `\zImage`；`sdcard.img` 由 `genimage` 以 `partition-table-type = "gpt"` 生成，`post-image.sh` **不再**写入 MBR 引导代码或安装 SYSLINUX。整个过程不需要 loop mount、mount 或 root 权限。镜像内 `/usr/bin/caos-ca` 由 Buildroot fakeroot 阶段记录为 `root:root 0755`；构建主机上的 overlay 源文件保留构建用户的属主，这是无 root 构建的正常行为，最终 squashfs 中已验证为 root。

### 2.4 内核版本选择

Buildroot 2026.08.1 的菜单中“最新版本”是 7.1，但它不是 LTS。本配置选用 Buildroot 同一 tag 内提供哈希与 header 系列的 **Linux 6.18 LTS，补丁版本 6.18.55**，不追新主线。内核配置以 `x86_64_defconfig` 为基础，再合并：

- `caos-buildroot/board/caos/linux.fragment`
- Buildroot 配置：`BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="6.18.55"`
- 验证文件：`output/build/linux-6.18.55/.config`

UEFI 启动选择基于 Buildroot 2026.08.1 实际提供的组件：其 `boot/grub2` 包提供 `BR2_TARGET_GRUB2_X86_64_EFI`，构建出 GRUB 2.14 的 `bootx64.efi`，并支持通过 `BR2_TARGET_GRUB2_BUILTIN_CONFIG_EFI` 嵌入初始脚本。本配置没有引入 EDK2、systemd-boot 或其他未验证的引导器。

EDK2 是固件/QEMU 镜像包，不是本机启动链的一部分；本镜像假定目标机已有 x86_64 UEFI 固件，直接由固件加载 ESP 上的 `BOOTX64.EFI`。

`CONFIG_NET=n` 不会导致本配置中的任何目标包编译失败。为满足气隙契约，仍主动去除了两类网络用户态内容：

- Buildroot 默认选中的 `ifupdown-scripts`（会安装 `/etc/init.d/S40network` 和 `/etc/network/interfaces`）：在 `caos_defconfig` 中显式 `# BR2_PACKAGE_IFUPDOWN_SCRIPTS is not set`；
- BusyBox 中的 `ip`、`ifconfig`、`ping`、`wget`、`nc`、`route`、`telnet`、`tftp`、DHCP/DNS 等 applet：通过 `board/caos/busybox.fragment` 关闭。

没有为了通过构建而重新启用网络，也没有因为 `CONFIG_NET=n` 删除其他必需的存储/CA 包。`post-build.sh` 还会在镜像层拒绝上述网络命令。

---

## 3. 烧录

> **警告：下面的 `of=` 设备名只是占位符。写错设备会不可恢复地摧毁该磁盘/系统盘上的数据。** 执行前用 `lsblk`、设备容量和 `dmesg` 三重确认目标设备。

镜像大小约 321 MiB。目标介质必须不小于镜像；更大的 SD 卡可以写入，镜像不会自动占满剩余空间。

```bash
# 先确认目标设备，例如 /dev/sdX 或 /dev/mmcblk0
lsblk -o NAME,SIZE,MODEL,TRAN

# 卸载目标设备上的所有分区（如已挂载）
sudo umount /dev/sdX* 2>/dev/null || true

# 写入；of= 必须替换为确认过的目标设备，不是分区，也不是系统盘
sudo dd if=output/images/sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress
sync
```

不要对 `/dev/sdX1` 这种分区写入整个磁盘镜像，也不要省略 `conv=fsync` 后立刻拔卡。写完后可以让内核重新读取分区表：

```bash
sudo blockdev --rereadpt /dev/sdX
```

镜像只支持 **x86_64 UEFI**。目标机需要关闭 Legacy/CSM（或设置为 UEFI-only），并从这张 GPT 介质的 ESP 启动。固件应能识别标准可移动介质路径 `\EFI\BOOT\BOOTX64.EFI`；不同厂商固件通常在启动菜单中显示为 `UEFI: <介质名>`，若默认启动顺序没有选中它，请在一次性 Boot Menu 中手工选择，或用固件设置把它加入启动顺序。镜像没有 BIOS、PXE 或网络启动路径。

> 当前 GRUB EFI 应用和内核都**没有做 UEFI Secure Boot 签名**。测试/部署时需在固件中关闭 Secure Boot，或后续自行完成签名与密钥管理；这属于已知限制，不是本镜像已实现的能力。

---

## 4. 首次启动

### 4.1 串口 / console

默认控制台：

- 串口：`ttyS0`，**115200 8N1**，无流控，vt100；
- 本地 console：`tty1`，通过内核 DRM/fbdev framebuffer console 显示（UEFI GOP framebuffer；没有本地显示时串口仍是主 console）。

Linux 主机上可使用：

```bash
# 例：USB 串口适配器
sudo picocom -b 115200 /dev/ttyUSB0
# 或
sudo screen /dev/ttyUSB0 115200
```

日志会同时输出到 tty0 和 ttyS0；登录提示在 ttyS0 与 tty1 各有一个 getty。内核命令行把 ttyS0 放在最后一个 `console=`，因此启动阶段的 `/dev/console`（包括 LUKS 口令提示）优先走串口；请在串口终端上输入首次解锁口令。登录后 tty1 也可操作。

### 4.2 首次启动时 CAOSDATA 是空的

p3 在镜像中是空分区。首次启动时 `/etc/init.d/S10caos-data` 会检测到没有 LUKS header，在 console 上打印类似信息并继续启动（不会自动格式化，避免误毁数据）：

```text
CAOS[data]: CAOSDATA at /dev/sda3 is not LUKS2-formatted yet.
CAOS[data]: The image intentionally ships an empty partition. ...
CAOS[data]:   cryptsetup luksFormat --type luks2 --label CAOSDATA /dev/sda3
CAOS[data]:   cryptsetup luksOpen /dev/sda3 caos-data
CAOS[data]:   mkfs.ext4 -L CAOS-DATA /dev/mapper/caos-data
CAOS[data]:   cryptsetup close caos-data
CAOS[data]:   reboot
```

先确认 p3 设备名（设备名依硬件为 `/dev/sda3`、`/dev/mmcblk0p3`、`/dev/nvme0n1p3` 等）：

```bash
# 已登录 root console 后
blkid -L CAOSDATA 2>/dev/null || true
blkid -t PARTLABEL=CAOSDATA -o device
lsblk
```

首次格式化（**会擦除 p3 全部内容**，先确认设备名）：

```bash
# 把 /dev/sdX3 替换成上面确认的 CAOSDATA 分区
cryptsetup luksFormat --type luks2 --label CAOSDATA /dev/sdX3
cryptsetup luksOpen /dev/sdX3 caos-data
dmsetup mknodes                     # 镜像无 udev；重建 /dev/mapper 便捷链接
mkfs.ext4 -L CAOS-DATA /dev/mapper/caos-data
cryptsetup close caos-data
reboot
```

重启后 S10 会提示输入 LUKS passphrase，打开映射器并挂载 `/mnt/ca-data`，然后执行：

```text
chown caos:caos /mnt/ca-data
chmod 0700 /mnt/ca-data
```

如果 `luksFormat` 已完成但还没有 ext4，S10 会提示执行 `mkfs.ext4`，仍然不会自动格式化。镜像使用 devtmpfs 而没有 udev，`cryptsetup` 打开映射后 S10 会调用 `dmsetup mknodes`；如果 `/dev/mapper/caos-data` 仍不存在，会按 sysfs 中的 dm 名称回退到 `/dev/dm-N`。格式化并重启后，**每次启动**都会在 getty 出现前要求输入 LUKS passphrase；这是有意设计，系统没有网络远程解锁路径。

**立即备份 LUKS header**（在任意可信主机上把 p3 设备/镜像接入后执行；不要和 CA 数据放在同一介质）：

```bash
cryptsetup luksHeaderBackup /dev/sdX3 \
  --header-backup-file caosdata-luks-header-$(date +%Y%m%d).img
chmod 0600 caosdata-luks-header-*.img
```

LUKS header 损坏或丢失时，单独的 passphrase 无法恢复数据。之后增加/删除 key slot 都会改变 header，应重新备份。不要把 header 备份与 LUKS passphrase 一起存放。

### 4.3 初始化 CA

镜像的 root 文件系统只读，CA 数据全部位于加密分区。root 登录后切换到专用的 `caos` 用户（该用户没有可直接登录的密码）：

```bash
su -s /bin/sh caos
caos-ca init
```

`init` 会交互式要求输入并确认根 CA 私钥口令（至少 12 个字符），然后：

1. 用 CSPRNG 生成根 CA 和中间 CA 的 P-256 密钥对；
2. 根 CA 自签名，中间 CA 由根 CA 签发；
3. 用 Argon2id（64 MiB、3 iterations、1 lane）派生密钥，ChaCha20-Poly1305 加密根私钥；
4. 将根私钥密文、中间 CA 证书/私钥、元数据与吊销列表写入 `/mnt/ca-data/db/`；
5. 创建 `/mnt/ca-data/audit/audit.jsonl` 并写入 genesis 之后的 `init` 记录。

成功后终端会打印根/中间序列号、证书和密钥路径。建议立刻执行：

```bash
caos-ca verify
```

#### 口令管理建议

- **LUKS passphrase 与根 CA 密钥口令必须不同。**
- 根 CA 口令使用高熵短语（建议 6 个以上随机词或 20+ 随机字符），只保存在离线位置（纸质密封、密码保险柜、离线密码管理器），不要写进数据分区、镜像、shell 历史或本仓库。
- 中间 CA 私钥只在已解锁的 LUKS2 数据分区中；设备关机后数据分区处于加密状态。
- 把 **加密后的 `root-ca.key.enc`、`root-ca.crt`、`intermediate-ca.crt` 和 LUKS header 备份**分别保存到离线介质。根私钥密文与口令分开保管。
- 本工具不做口令托管：忘记根 CA 口令 = 无法解开归档的根私钥；忘记 LUKS passphrase 且 header/密钥丢失 = CA 数据不可恢复。

---

## 5. 日常操作

所有日常命令都以 `caos` 用户执行：

```bash
# 从 root console
su -s /bin/sh caos

# 工具默认读取 /etc/caos-ca/config.toml
caos-ca --help
```

数据目录契约（固定）：

```
/mnt/ca-data/db/
├── root-ca.crt                     # 根 CA 证书
├── root-ca.key.enc                 # 根私钥（Argon2id + ChaCha20-Poly1305，0600）
├── intermediate-ca.crt             # 中间 CA 证书
├── intermediate-ca.key             # 中间私钥（LUKS2 内，0600，明文 PEM）
├── metadata.json                   # CA/签发记录（0600）
├── revoked.json                    # 吊销列表（0600）
├── integrity.json                  # CA 文件 SHA-256 完整性清单（0600）
└── issued/
    ├── <32-hex-serial>.crt
    └── <32-hex-serial>.key
/mnt/ca-data/audit/audit.jsonl      # append-only JSONL 审计日志（0600）
/etc/caos-ca/config.toml            # 只读配置（0444）
/run/caos-ca/                       # tmpfs：锁文件与启动校验日志
```

### 5.1 签发

```bash
caos-ca issue --cn server.example --san server.example --san 192.0.2.10
```

输出示例：

```text
Certificate issued.
  serial:       1d7f6fffa85b6370d3f51c16f95fbed2
  expires:      2027-10-31T06:19:12.516335279Z
  certificate:  /mnt/ca-data/db/issued/1d7f6fffa85b6370d3f51c16f95fbed2.crt
  private key:  /mnt/ca-data/db/issued/1d7f6fffa85b6370d3f51c16f95fbed2.key
```

- `--san` 可重复，支持 DNS 名称或 IP 地址；没有 `--san` 时只写 CN，没有 SAN 扩展。给现代 TLS 客户端使用时应显式提供 `--san`。
- 每次签发都生成新的 P-256 密钥对（中间 CA 只负责签名）。
- 终端证书有效期 365 天，且不会超过中间 CA 的到期时间。
- 序列号是 `ring::SystemRandom` 生成的 128-bit 随机正整数；拒绝自增、时间戳等可预测来源，并在签发前对全部已知序列号查重。
- 证书/私钥文件权限分别为 `0644`/`0600`。

### 5.2 列表

```bash
caos-ca list
```

```text
SERIAL                           COMMON NAME                              EXPIRES (UTC)              STATUS
1d7f6fffa85b6370d3f51c16f95fbed2 server.example                           2027-10-31T06:19:12.516335279Z active
308959eaff31ecf7493ca152e2eef708 client.example                           2027-10-31T06:19:12.517215087Z expired
```

状态取值：

- `active`：未吊销且当前时间未到期；
- `expired`：未吊销但已到期；
- `revoked`：在 `revoked.json` 中。

### 5.3 吊销

```bash
caos-ca revoke --serial 1d7f6fffa85b6370d3f51c16f95fbed2
```

输出：

```text
Certificate revoked.
  serial:      1d7f6fffa85b6370d3f51c16f95fbed2
  revoked at:  2026-10-31T06:19:15.571897253Z
```

- 序列号可带 `0x` 前缀或冒号，内部规范化为 32 位小写十六进制。
- 证书和私钥文件会保留以便审计；`revoked.json` 更新后 `list` 显示 `revoked`，再次吊销会报错。
- 本实现没有生成 X.509 CRL/PKCS#7，而是维护 JSON 吊销列表；这是本轮的明确范围限制。

### 5.4 校验

```bash
caos-ca verify
```

输出示例：

```text
Verification successful.
  system time:          2026-10-31T06:19:15.572862813Z
  root CA:              CN=CAOS Test CA Root CA, O=CAOS, OU=Air-Gapped Certificate Authority
  intermediate CA:      CN=CAOS Test CA Issuing CA, O=CAOS, OU=Air-Gapped Certificate Authority
  issued certificates:  2
  revoked certificates: 1
  audit entries:        4
  audit chain:          intact (audit file /mnt/ca-data/audit/audit.jsonl)
```

`verify` 实际检查：

- 系统时钟不早于二进制编译期时间，且不处于不合理的远期；
- `integrity.json` 中根/中间证书、根密钥密文、中间私钥、元数据、吊销列表的 SHA-256 和大小；
- 根证书自签名；中间证书由根证书签名；根/中间均为 CA；证书时间有效；
- 中间私钥与中间证书公钥匹配；
- 每个已签发证书的 SHA-256、序列号、由中间 CA 签名、未过期、私钥匹配、权限受限；
- 吊销列表只引用已签发序列号且无重复；
- 私有文件权限无 group/other 访问；
- 审计 JSONL 的 SHA-256 链、`time_source=system_clock`、时间戳有序且不在未来。

任何一步失败都会输出非零退出码，并在 `caos-ca: error:` 后给出具体原因。

---

## 6. 安全说明

### 6.1 关闭网络：`CONFIG_NET=n` 的验证

构建时 `build.sh` 会直接检查 `output/build/linux-6.18.55/.config`。也可以手工执行：

```bash
grep -n '^# CONFIG_NET is not set$' output/build/linux-6.18.55/.config
grep -n '^# CONFIG_MODULES is not set$' output/build/linux-6.18.55/.config
grep -n '^CONFIG_STRICT_KERNEL_RWX=y$' output/build/linux-6.18.55/.config
grep -n '^CONFIG_RANDOMIZE_BASE=y$' output/build/linux-6.18.55/.config
```

构建日志中也保留了 Kconfig merge 结果。运行中的系统还可以辅助检查：

```bash
# CONFIG_NET=n 时网络栈与外设不存在；以下命令预期没有正常网络设备
cat /proc/net/dev 2>/dev/null || echo "no /proc/net"
ls /sys/class/net 2>/dev/null || echo "no network class"
```

镜像根文件系统还包含以下防护：

- 内核 `CONFIG_NET`、`CONFIG_INET`、`CONFIG_IPV6`、`CONFIG_PACKET` 全部关闭；
- 不含 OpenSSH、curl、wget、iproute2、net-tools、WPA supplicant、DHCP 包；
- `busybox.fragment` 关闭 `ip`、`ifconfig`、`ping`、`wget`、`nc`、`route`、`telnet`、`tftp`、DHCP、DNS 查询等网络 applet；
- `post-build.sh` 在打包前再次查找这些命令，发现即失败。

#### 副作用：内核没有 `socket(2)` 时 `su` 会失败

`CONFIG_NET=n` 不只是“没有网卡”：`net/socket.c` 整个不参与编译，`socket`/`connect`/`socketpair` 等系统调用在 `kernel/sys_ni.c` 中被登记为 `COND_SYSCALL`，统一返回 `ENOSYS`。

musl 的 `getgrouplist()` 会先通过 AF_UNIX socket 询问 nscd，失败时才回退到 `/etc/group`。musl 1.2.6 的 `__nscd_query()` 只把 `EAFNOSUPPORT` 当作“没有 nscd”，于是 `ENOSYS` 被当成硬错误：`getgrouplist()` 返回 -1 且 `errno=ENOSYS`，`initgroups()` 随之失败，BusyBox `su` 在 `change_identity()` 里报错：

```text
su: can't set groups: Function not implemented
```

它的连带影响不止 `su`：`id caos` 也会打印一串错误的组，`S20caos-ca` 的启动前 `caos-ca verify` 也会失败。这与 `/etc/group` 是否完整无关（镜像里的 `caos:x:1000:` 一直是对的）。

修复方式是给 musl 打一个最小补丁，让 `ENOSYS` 与 `EAFNOSUPPORT` 等价处理：

```text
board/caos/patches/musl/0001-nscd_query-treat-ENOSYS-as-no-nscd.patch
-       if (errno == EAFNOSUPPORT) {
+       if (errno == EAFNOSUPPORT || errno == ENOSYS) {
```

补丁目录通过 `BR2_GLOBAL_PATCH_DIR` 挂到 Buildroot（只在外部树里，不改 Buildroot 源码），`build.sh` 会检查最终参与构建的 musl 源码确实带有这一行。

### 6.2 CA 文件完整性

`init`/`issue`/`revoke` 后，`integrity.json` 记录静态 CA 文件的哈希；`verify` 会重新计算并与清单比较。此外 `verify` 会用成熟 crate（`x509-parser` + `ring`）验证 X.509 证书链、证书与私钥匹配，以及已签发证书的哈希/序列号/签名。

完整性清单本身没有用根密钥签名（根密钥需要口令，不应在每次只读校验时解锁）。它的安全边界是：检测意外损坏和普通篡改；如果攻击者拥有 `/mnt/ca-data` 的写权限，可以同时改写文件和清单。审计哈希链同样需要外部锚点才能防止“删除整个尾部后重新构造前缀”。生产环境应定期把 `verify` 输出与审计日志尾部哈希带到离线记账/见证系统中。

### 6.3 私钥保护

- 根 CA 私钥只在 `init` 期间存在，落盘前用 Argon2id + ChaCha20-Poly1305 封装，文件 `0600`。
- 中间 CA 私钥、终端私钥位于 LUKS2 保护的 ext4 中，文件 `0600`，所在目录 `0700`。
- 程序启动时：
  - `prctl(PR_SET_DUMPABLE, 0)`；
  - 将 `RLIMIT_CORE` soft/hard 设为 0；
  - `umask 077`。
- 程序持有私钥 PEM 的秘密缓冲区通过 `mlock(2)` 防止换出，`Drop` 时先 `zeroize` 再 `munlock`；`rcgen::KeyPair` 使用其 `zeroize` feature 并在 `Zeroizing` 中管理。
- 根 CA 口令、Argon2 派生密钥使用 `zeroize::Zeroizing`。
- 程序不使用 `unwrap()`/`expect()` 处理用户输入、文件 IO 或密码学错误（单元测试代码除外）。

### 6.4 审计日志

格式为每行一个 JSON 对象，包含：

```json
{"prev_hash":"...64 hex...","hash":"...64 hex...","timestamp":"RFC3339","action":"init|issue|revoke","serial":"...","subject":"...","time_source":"system_clock"}
```

哈希输入是固定字段顺序的紧凑 JSON：

```text
prev_hash, timestamp, action, serial, subject, time_source
```

对 UTF-8 字节做 SHA-256 得到 `hash`。首条记录的 `prev_hash` 是 64 个 `0`。审计文件以 `O_APPEND` 打开，程序从不截断或重写它；每次写入后 `fsync`。写入前会重新校验整条链，链损坏时拒绝追加。

`caos-ca verify` 是官方校验方式。为了独立复核（例如把日志复制到工作站后），可以用等价的 Python 代码重新计算链；注意 `json.dumps` 必须使用紧凑分隔符和 UTF-8，不转义非 ASCII：

```python
import hashlib, json, sys

path = sys.argv[1]
prev = "0" * 64
with open(path, "r", encoding="utf-8") as f:
    for n, line in enumerate(f, 1):
        rec = json.loads(line)
        assert rec["prev_hash"] == prev, f"line {n}: prev_hash"
        assert rec["time_source"] == "system_clock", f"line {n}: time_source"
        payload = {
            "prev_hash": rec["prev_hash"],
            "timestamp": rec["timestamp"],
            "action": rec["action"],
            "serial": rec["serial"],
            "subject": rec["subject"],
            "time_source": rec["time_source"],
        }
        blob = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
        assert hashlib.sha256(blob).hexdigest() == rec["hash"], f"line {n}: hash"
        prev = rec["hash"]
print(f"OK: {n} audit records, tip={prev}")
```

需要长期可信地保存审计证据时，应定期把 `tip` 和 `verify` 结果抄录到独立的离线记录介质。

### 6.5 其他运行期加固

- 内核 `CONFIG_STRICT_KERNEL_RWX=y`、`CONFIG_RANDOMIZE_BASE=y`、`CONFIG_STACKPROTECTOR_STRONG=y`、`CONFIG_HARDENED_USERCOPY=y`；
- 根文件系统 squashfs 只读，fstab 中 `CAOSROOT` 以 `ro` 声明；不执行 rootfs 的 rw remount；
- CA 工具以 `caos` 用户运行，不使用 root；
- 控制台 root 账号的访问安全见“已知限制”。

---

## 7. Buildroot 定制要点

- `BR2_EXTERNAL=caos-buildroot`；Buildroot 源码树零修改。
- `BusyBox init`，不使用 systemd/openrc。
- 只读根文件系统；`/run`、`/tmp`、`/dev/shm` 使用 tmpfs。
- `caos` 用户：UID 1000、GID 1000、home `/mnt/ca-data`、shell `/bin/sh`，密码字段为 `*`（禁止直接登录），通过 `su` 从 root 切换。
- 启动脚本：
  - `S10caos-data`：定位 LUKS2 分区、交互解锁、挂载 ext4、`chown caos:caos`、console 引导首次格式化；
  - `S20caos-ca`：创建 `/run/caos-ca`，以 `caos` 用户执行启动前 `caos-ca verify`；未初始化或数据未挂载时只打印指引，不阻塞启动。
- 没有实现常驻 daemon。`caos-ca` 是手动 CLI；`S20caos-ca` 的职责就是“启动前校验并退出”，与需求中的可选路径一致。
- `genimage.cfg` 只生成标准 GPT（`partition-table-type = "gpt"`），p1 类型为 EFI System Partition；GPT 名称提供 `CAOSROOT`/`CAOSDATA` 定位依据。保护性 MBR 由 GPT 规范要求，只有 `0xEE` 项，没有引导代码或 active 标志。
- UEFI 启动链：Buildroot 的 GRUB 2.14 `x86_64-efi` 应用 → `\EFI\BOOT\BOOTX64.EFI`；嵌入脚本按 FAT 卷标 `CAOSBOOT` 找到 ESP 并执行 `\EFI\BOOT\grub.cfg`；菜单项用 `linux /zImage ...` 传递完整命令行。`post-image.sh` 只创建 FAT32 ESP 并调用 `genimage`，不写 BIOS MBR 引导代码、不安装 SYSLINUX；genimage 按 GPT 规范生成保护性 MBR。
- `board/caos/validate-image.py` 独立解析 GPT 头、主/备份分区数组、保护性 MBR、ESP FAT 标签和 CAOSDATA 空白状态，`build.sh` 在 Stage 4 调用它。
- `BR2_GLOBAL_PATCH_DIR=board/caos/patches`：目前只有一个 musl 补丁（`nscd_query.c` 把 `ENOSYS` 也当作“没有 nscd”），用于让 `su`/`initgroups()` 在 `CONFIG_NET=n`（没有 `socket(2)`）的内核上工作。补丁仍留在外部树内，Buildroot 源码树依旧零修改。

---

## 8. 构建验证

本节记录本机实际执行结果。所有验证均基于**已构建产物**，不是“应该可以”。

### 8.1 环境与构建状态

- Buildroot：tag `2026.08.1`，浅克隆，commit `7fdeadb3`；构建后 Buildroot 源码树 `git status --short --untracked-files=all` 为空，且没有 `buildroot-2026.08.1/output/` 或非空 `dl/`。
- Rust：`rustc 1.99.1`，target `x86_64-unknown-linux-musl`；Cargo MSRV 声明为 1.88。
- 内核：Linux 6.18.55（Buildroot 2026.08.1 自带的 6.18 LTS header/hash 系列）。
- 构建机：x86_64 Linux，24 核、约 14 GiB 内存；所有下载通过 `BR2_DL_DIR=output/dl` 缓存。

构建流程实际执行情况：

- 首次迁移构建清空 `output/build`、`output/host`、`output/images`、`output/.config` 等全部构建状态（保留 `output/dl` 下载缓存），清理 Rust target 后，以 `JOBS=8 ./build.sh` 重新构建；Stage 5 于 `20:36` 成功。
- 修复 UEFI framebuffer console 时，在 `linux.fragment` 增加 `DRM_FBDEV_EMULATION`/`simpledrm`/`fbcon` 后，以 `JOBS=8 ./build.sh` 增量重建；内核和镜像于 `20:49` 重新生成，Rust/工具链/GRUB 复用已构建结果。
- 修复 LUKS2 初始化时，在 `caos_defconfig` 增加 `BR2_PACKAGE_LIBGCRYPT=y` 并清理重建 `cryptsetup`；`09:51` 重新生成 rootfs 和 `sdcard.img`。
- 针对 ASUS 兼容性关闭 `SOUND`、`INTEL_MEI`、`DRM_I915` 后，`10:01` 重新生成内核和镜像；内核从 10,343,424 字节降到 8,311,808 字节。
- 修复 `su: can't set groups` 时，新增 `BR2_GLOBAL_PATCH_DIR` + musl 补丁（见 6.1 与 8.7）。因为改的是 libc，必须重建工具链：清空 `output/build`、`output/host`、`output/target`、`output/images`、`output/.config` 等（保留 `output/dl`），`14:01` 以 `JOBS=8 ./build.sh` 完整重跑，Stage 5 成功。
- 五次构建的 Buildroot 源码树在构建后 `git status --short --untracked-files=all` 均为空，没有生成 `buildroot-2026.08.1/output/`。
- `output/build.log` 的错误扫描：

```text
$ grep -E '^ERROR:|^make(\[[0-9]+\])?: \*\*\*|No space left on device' output/build.log
（无输出）
```

### 8.2 Rust 验收

`cargo build --release --target x86_64-unknown-linux-musl`：成功。

`file target/x86_64-unknown-linux-musl/release/caos-ca`：

```text
ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked, BuildID[sha1]=d79bb0af1ab01088497244f95da6f59c83bc5b22, stripped
```

- SHA-256：`179076486b65e09d647e9bece28eecf298e0e47dee2d74e00fd9ec351f03ea75`
- 大小：`2,183,696` bytes（约 2.08 MiB）
- 权限/属主（最终 squashfs 内）：`root:root`、`0755`
- 从 `rootfs.squashfs` 提取出的二进制 SHA-256 与 overlay 中完全一致。

`cargo clippy -- -D warnings`：通过。
`cargo fmt -- --check`：通过。
`cargo test --release --target x86_64-unknown-linux-musl`：通过，11 个单元测试全部成功（包含审计链篡改检测、根密钥封装 round-trip、mlock 缓冲区、序列号规范化和配置校验）。

### 8.3 内核、网络关闭与 GPT 验证

最终内核配置文件为 `output/build/linux-6.18.55/.config`。实测 grep 结果：

```text
$ grep -nE '^(# CONFIG_(NET|INET|IPV6|PACKET|MODULES|MSDOS_PARTITION) is not set|CONFIG_(PARTITION_ADVANCED|STRICT_KERNEL_RWX|RANDOMIZE_BASE|EFI_PARTITION|DM_CRYPT|SQUASHFS_XZ)=y)' \
    output/build/linux-6.18.55/.config
472:CONFIG_RANDOMIZE_BASE=y
853:CONFIG_STRICT_KERNEL_RWX=y
894:# CONFIG_MODULES is not set
915:CONFIG_PARTITION_ADVANCED=y
922:# CONFIG_MSDOS_PARTITION is not set
928:CONFIG_EFI_PARTITION=y
1073:# CONFIG_NET is not set
1562:CONFIG_DM_CRYPT=y
3581:CONFIG_SQUASHFS_XZ=y

$ grep -cE '^CONFIG_(NET|INET|IPV6|PACKET)=' output/build/linux-6.18.55/.config
0

$ grep -nE '^(CONFIG_(DRM_FBDEV_EMULATION|DRM_SIMPLEDRM|SYSFB_SIMPLEFB|FRAMEBUFFER_CONSOLE|FRAMEBUFFER_CONSOLE_DETECT_PRIMARY)=y|# CONFIG_FB is not set)' \
    output/build/linux-6.18.55/.config
1236:CONFIG_SYSFB_SIMPLEFB=y
2458:CONFIG_DRM_FBDEV_EMULATION=y
2472:CONFIG_DRM_SIMPLEDRM=y
2527:# CONFIG_FB is not set
2568:CONFIG_FRAMEBUFFER_CONSOLE=y
2570:CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY=y
```

说明：

- `linux.fragment` 中保留全部网络与硬化强制行，包括 `# CONFIG_INET is not set`、`# CONFIG_IPV6 is not set`、`# CONFIG_PACKET is not set`、`CONFIG_STRICT_MODULE_RWX=y` 和 `# CONFIG_MODULES is not set`；并新增 `CONFIG_PARTITION_ADVANCED=y` + `# CONFIG_MSDOS_PARTITION is not set`。`PARTITION_ADVANCED` 只是让默认强制的 DOS/MBR 解析器变为可关闭；其他非 GPT 解析器均保持关闭。
- 当 `CONFIG_NET=n` 后，Kconfig 会隐藏 `INET`/`IPV6`/`PACKET` 这些依赖项，因此最终 `.config` 中没有它们的行；这是 Kconfig 的正常行为，fragment 中的强制声明已经生效为“网络栈整体不存在”。
- `CONFIG_MODULES=n` 时 `STRICT_MODULE_RWX` 符号本身被隐藏，最终 `.config` 仅保留 `CONFIG_ARCH_HAS_STRICT_MODULE_RWX=y`；需求强制片段中已经包含 `CONFIG_STRICT_MODULE_RWX=y`。
- 最终 `.config` 中网络启用符号数量为 0。
- 显示控制台不再依赖传统 VGA 文本模式。UEFI 只提供 GOP framebuffer，因此启用 `CONFIG_DRM_FBDEV_EMULATION=y`、`CONFIG_DRM_SIMPLEDRM=y`、`CONFIG_SYSFB_SIMPLEFB=y`、`CONFIG_FRAMEBUFFER_CONSOLE=y` 和 `CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY=y`；`CONFIG_FB` 仍为 `n`，由 DRM fbdev 提供 `fb0`/`fbcon`。
- **LUKS2 不能使用 cryptsetup 的 kernel crypto backend。** `CONFIG_NET=n` 后，`CRYPTO_USER_API_HASH`/`CRYPTO_USER_API_SKCIPHER` 等 AF_ALG 接口被隐藏，`cryptsetup` 初始化 kernel backend 时 `socket(AF_ALG)` 失败，表现为 `Cannot initialize crypto backend` / `Failed to set pbkdf parameters`。因此 defconfig 增加 `BR2_PACKAGE_LIBGCRYPT=y`，Buildroot 的 cryptsetup 配置为 `--with-crypto_backend=gcrypt`，Argon2 仍由 `libargon2` 提供；内核侧 `CONFIG_DM_CRYPT=y`、`CONFIG_CRYPTO_AES=y`、`CONFIG_CRYPTO_XTS=y` 负责挂载后的 dm-crypt 数据路径。`build.sh` 同时检查这三个内核选项和 cryptsetup 的 gcrypt 配置，防止回退到需要 AF_ALG 的 kernel backend。
- `CONFIG_EFI_PARTITION=y` 保证 `root=PARTLABEL=CAOSROOT` 能从标准 GPT 解析分区名；最终 `.config` 中 **只有** `CONFIG_EFI_PARTITION=y`，`# CONFIG_MSDOS_PARTITION is not set`，镜像不依赖 DOS/MBR 分区解析器。
- 内核由 GRUB 的 `linux` 命令通过 Linux boot protocol 装载，不需要把 `bzImage` 当作 EFI 可执行文件直接启动；`CONFIG_EFI`/`CONFIG_EFI_STUB` 是 x86_64 defconfig 的既有设置，不是本启动链的额外依赖。

#### ASUS 启动兼容性

ASUS 机器最初停在 `Booting ...`，使用带 `nomodeset` 的兼容入口后能进入内核，但出现大量 `snd_hda_intel` 超时、`mei_me` 反复复位，以及 xHCI 的 `Error while assigning device slot ID: Command Aborted`。为此做了两项定向裁剪：

- 内核关闭 `CONFIG_SOUND`、`CONFIG_INTEL_MEI`、`CONFIG_DRM_I915`。本地显示继续由 `simpledrm` + fbcon 提供；CA 设备不需要音频、ME 或 3D/GPU 驱动。内核因此从约 10.3 MiB 降到 8.31 MiB。
- GRUB 的兼容入口不再堆叠 `acpi_osi=`、`pcie_aspm=off`、`pci=noaer` 等参数，最后停在 `earlycon=efifb keep_bootcon noapic nomodeset`（见 `board/caos/grub.cfg` 与提交 `12222ed`）。需要清醒认识的是：`noapic` 会破坏现代 xHCI/MSI 环境，`nomodeset` 会让 framebuffer console 失效，因此这个入口只是最后手段，默认入口不应带它们；在 ASUS 上的定向适配到此为止，不再继续添加参数。

如果 ASUS 上仍出现 xHCI slot/port 错误，这不是再禁用某个驱动能解决的：`USB_XHCI_HCD` 和 `USB_STORAGE` 是 rootfs 所在 U 盘的必经路径。应优先换到后置 USB 2.0 端口（避免前面板 hub/USB-C 转接）、更新或重置 BIOS，再观察是否仍出现 `Max number of devices this xHCI host supports is 64`。

目标 rootfs 额外验证无网络用户态：

- `.config` 中 OpenSSH、curl、wget、iproute2、net-tools、wpa_supplicant、DHCP、ifupdown-scripts 全部未选中；
- 镜像中不存在 `ssh`/`sshd`、`curl`、`wget`、`ip`、`ifconfig`、`route`、`ping`、`telnet`、`tftp`、`udhcpc`/`udhcpd`、`wpa_supplicant`、`dhcpcd`/`dhclient`、`nc`、`nslookup` 等命令；
- `/etc/network` 和 `/etc/init.d/S40network` 不存在（Buildroot 的 ifupdown-scripts 在 defconfig 中主动关闭，空 skeleton 目录也在 fakeroot 阶段清除）；
- `post-build.sh` 的禁止命令扫描与网络 init 脚本扫描均通过。

### 8.4 镜像与文件系统验收

构建产物（最终实际大小）：

```text
$ ls -l output/images
-rw-r--r-- 1 ...  67108864 Nov  2 14:01 boot.vfat
-rw-r--r-- 1 ...   8311808 Nov  2 14:01 bzImage
drwxr-xr-x 3 ...      4096 Nov  2 13:58 efi-part
-rw-r--r-- 1 ...   7331840 Nov  2 14:01 rootfs.squashfs
-rw-r--r-- 1 ... 336613376 Nov  2 14:01 sdcard.img

$ ls -l output/images/efi-part/EFI/BOOT
-rw-r--r-- 1 ... 675840 Nov  2 13:58 bootx64.efi
-rw-r--r-- 1 ...    632 Nov  2 14:01 grub.cfg
```

SHA-256：

```text
ca5e445f1d8ed734c927b563c71adec58743c7440d5b75600b8d38488d73346f  output/images/sdcard.img
d309eeb3cf4d066cb5d1a9acfea0bec1c4e183d63fb6e7714f4b8b32c1912b42  output/images/boot.vfat
1fe789f4fc258dee4b162ba24dabcbffd04a8c22d600fca4449ebd98dd060cb3  output/images/rootfs.squashfs
18a9244bc1652d02072a92e5c9ed866a1843c45df1e58695b13864ff1594b442  output/images/bzImage
109808670e8d795f627b6c2efda8172e99671ad62c4a496a2d589403cf987cf2  output/images/efi-part/EFI/BOOT/bootx64.efi
179076486b65e09d647e9bece28eecf298e0e47dee2d74e00fd9ec351f03ea75  caos-buildroot/board/caos/rootfs-overlay/usr/bin/caos-ca
```

UEFI/GPT 验收：

1. **标准 GPT，不是 hybrid。** `sfdisk --json` 返回 `"label": "gpt"`；p1 type 为 `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`（ESP），p2/p3 为 Linux filesystem。
2. **没有 BIOS 引导代码。** 受保护 MBR 的前 440 字节全为 `00`，4 个 MBR 表项中只有一个 `status=0x00, type=0xee` 的保护项，没有 `0x80` active 标志；boot signature 为 `55aa`。
3. **ESP 是 FAT32 且路径正确。** 卷标 `CAOSBOOT`，64 MiB；FAT 内文件为：

```text
::/EFI/
::/zImage
::/EFI/BOOT/
::/EFI/BOOT/BOOTX64.EFI
::/EFI/BOOT/grub.cfg
```

4. **GRUB EFI 应用正确。** Buildroot 只选择 `BR2_TARGET_GRUB2_X86_64_EFI=y`，`BR2_TARGET_GRUB2_I386_PC` 未选中；`file` 返回 `PE32+ executable for EFI (application), x86-64`，`objdump -p` 的 `Subsystem` 为 `EFI application`。`BOOTX64.EFI` 内嵌脚本包含：

```text
search --no-floppy --label CAOSBOOT --set=root
set prefix=($root)/EFI/BOOT
configfile ($root)/EFI/BOOT/grub.cfg
```

5. **ESP 上的启动菜单传参完整。** 当前 `grub.cfg` 有默认 `CAOS` 和兼容入口 `CAOS - Compatible` 两项，`timeout=5`；默认入口的命令行为：

```text
linux /zImage console=tty0 console=ttyS0,115200 root=PARTLABEL=CAOSROOT rootfstype=squashfs ro rootwait
```

   两个入口都保留 `root=PARTLABEL=CAOSROOT rootfstype=squashfs ro rootwait`；兼容入口额外使用 `earlycon=efifb keep_bootcon noapic nomodeset`，是最后手段而不是推荐方案（见 8.3 的 ASUS 说明）。

6. **GPT/ESP 校验器通过。** `caos-buildroot/board/caos/validate-image.py` 实测输出：

```text
image:        output/images/sdcard.img (336613376 bytes)
table:        GPT (standard protective MBR, no BIOS boot code)
partition 1: CAOSBOOT type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b start=2048 sectors=131072 (64 MiB)
partition 2: CAOSROOT type=0fc63daf-8483-4772-8e79-3d69d8477de4 start=133120 sectors=262144 (128 MiB)
partition 3: CAOSDATA type=0fc63daf-8483-4772-8e79-3d69d8477de4 start=395264 sectors=262144 (128 MiB)
ESP:          FAT32 label CAOSBOOT, 64 MiB
rootfs:       squashfs superblock present
CAOSDATA:     all zero, no LUKS header
```

   另以 `sgdisk -v` 验证返回 `No problems found`，`sfdisk --verify` 返回无错误；`file -s output/images/boot.vfat` 显示 FAT32、卷标 `CAOSBOOT`、OEM-ID `mkfs.fat`（不是 SYSLINUX）。

7. **p3 仍为空。** `CAOSDATA` 的 `134,217,728` 字节全部为 0，无 LUKS magic、无文件系统，保留首次启动手工 `luksFormat` 的契约。
8. **GRUB 脚本语法通过。** `grub-script-check` 分别检查 `grub-builtin.cfg` 与 `grub.cfg`，均无输出、退出码 0。
9. **没有残留 SYSLINUX。** ESP 中不存在 `extlinux`、`ldlinux.sys` 或 `ldlinux.c32`；Buildroot `.config` 中 `BR2_TARGET_SYSLINUX`、`BR2_TARGET_GRUB2_I386_PC` 均未选中。

squashfs 内容确认：

```text
$ unsquashfs -l output/images/rootfs.squashfs | grep '/usr/bin/caos-ca$'
squashfs-root/usr/bin/caos-ca

$ unsquashfs -lln output/images/rootfs.squashfs | grep -E 'caos-ca|config.toml|mnt/ca-data'
-r--r--r-- 0/0              245 ... squashfs-root/etc/caos-ca/config.toml
drwx------ 1000/1000          3 ... squashfs-root/mnt/ca-data
-rwxr-xr-x 0/0          2183696 ... squashfs-root/usr/bin/caos-ca
```

（`1000/1000` 即目标系统内的 `caos:caos`；unsquashfs 在宿主机上可能把 1000 显示为宿主用户名。`root:root` 的 0755 二进制通过 `post-fakeroot.sh` 显式记录。）

squashfs 中同时确认存在：`/usr/bin/caos-ca`（root:root 0755）、`/etc/caos-ca/config.toml`（root:root 0444）、`/etc/fstab`、`/etc/inittab`、`S10caos-data`、`S20caos-ca`、`blkid`、`findfs`、`mount`、`cryptsetup`、`dmsetup`、`mkfs.ext4`。`/etc/shadow` 为 root:root 0600；`caos` 用户和组为 1000:1000。从 squashfs 提取的 `caos-ca` SHA-256 与 overlay 完全一致。

> 8.4 是镜像结构、分区表、ESP 内容和脚本语法的静态验收，不是 UEFI 固件实际启动验收。

### 8.5 QEMU UEFI 启动验证

使用宿主机 QEMU 10.2.1 + OVMF（edk2 `2025.11-3ubuntu7.3`）对最终 `sdcard.img` 做了多次纯 UEFI 启动（每次都在 qcow2 覆盖层上，不写回 `output/images/sdcard.img`）：

1. 将镜像作为 `qemu-xhci` 下的 `usb-storage` 设备，串口输出到文件，确认内核、USB 枚举、`PARTLABEL=CAOSROOT` 根挂载和 init 全流程；
2. 仅保留图形 framebuffer，确认本地屏幕能显示内核日志和 `caos login:`；再用 QEMU monitor 的 `sendkey` 从本地 console 输入 `root`，成功进入 root shell，证明 `tty1`/键盘输入链路也正常；
3. 以 `/etc/hostname` 作为测试 key-file 执行 LUKS2 格式化、打开、`mkfs.ext4`、读写挂载、卸载和关闭。

关键日志：

```text
[    1.273700] [drm] Initialized simpledrm 1.0.0 for simple-framebuffer.0 on minor 0
[    1.303677] Console: switching to colour frame buffer device 160x50
[    1.309590] simple-framebuffer simple-framebuffer.0: [drm] fb0: simpledrmdrmfb frame buffer device
[    2.647438] VFS: Mounted root (squashfs filesystem) readonly on device 8:2.
caos login:
```

LUKS2 实测（QEMU 临时快照）：

```text
# cryptsetup luksFormat --type luks2 --label CAOSDATA --batch-mode --key-file /etc/hostname /dev/sda3
# cryptsetup luksOpen --key-file /etc/hostname /dev/sda3 caos-data
# cryptsetup status caos-data
/dev/mapper/caos-data is active.
  type:    LUKS2
  cipher:  aes-xts-plain64
  keysize: 512 [bits]
  key location: keyring
  device:  /dev/sda3
  sector size:  512 [bytes]
  offset:  32768 [512-byte units] (16777216 [bytes])
  size:    229376 [512-byte units] (117440512 [bytes])
  mode:    read/write
# cryptsetup isLuks /dev/sda3; echo isLuks_rc=$?
isLuks_rc=0
# mkfs.ext4 -L CAOS-DATA -F /dev/mapper/caos-data
Creating filesystem with 114688 1k blocks and 28672 inodes
# mount /dev/mapper/caos-data /mnt/ca-data
EXT4-fs (dm-0): mounted filesystem ... r/w with ordered data mode.
# df -h /mnt/ca-data
/dev/mapper/caos-data    99.5M  46.0K  91.6M   0% /mnt/ca-data
# umount /mnt/ca-data
# cryptsetup close caos-data; echo close_rc=$?
close_rc=0
```

完整 LUKS2 会话日志：[luks2-test.log](output/verification/luks2-test.log)。`luksFormat` 不再出现 `Cannot initialize crypto backend` 或 `Failed to set pbkdf parameters`，并完成 `mkfs.ext4`、读写挂载和卸载。

图形 console 截图（QEMU monitor `screendump`，1280x800）：

![QEMU UEFI 启动后的本地 framebuffer console](output/verification/uefi-console-login.png)

本地键盘登录后的 root shell：[uefi-console-root-shell.png](output/verification/uefi-console-root-shell.png)。

完整串口日志保存在 [luks2-test.log](output/verification/luks2-test.log)（包含本次启动和 LUKS2 会话）。QEMU 验证覆盖 UEFI 固件→GRUB→内核→init→login，以及 `cryptsetup` 的 LUKS2 格式化/打开，但**不能替代目标机的 USB 控制器、GPU/固件和 Secure Boot 兼容性测试**。

### 8.6 功能自测（宿主开发配置）

使用临时配置文件和临时数据目录，对**从最终镜像 squashfs 提取的同一个静态二进制**执行了完整流程：

- `init`：成功生成根/中间 CA、加密根私钥、初始审计记录（根序列号 `4ddcaae23908e256fa47781819a7dd14`，中间序列号 `fa63c713f23575e15d42411bb581e37e`）；
- `issue --cn final-uefi.example --san final-uefi.example --san 192.0.2.55`：成功签发带 DNS+IP SAN 的终端证书，序列号 `118912ef5cde950910a3eb2d1cd10ca8`，到期 `2027-10-31T12:37:15.649172511Z`；`openssl verify -CAfile root-ca.crt -untrusted intermediate-ca.crt leaf.crt` 返回 `OK`；
- `list`：依次正确显示 `active` 和 `revoked`；
- `revoke --serial 118912ef5cde950910a3eb2d1cd10ca8`：更新吊销列表并追加审计；重复吊销以 `certificate ... is already revoked` 失败；
- `verify`：正常时通过；吊销后再次通过，输出 `issued certificates: 1`、`revoked certificates: 1`、`audit entries: 3`、`audit chain: intact`；
- 独立 Python 实现按 `prev_hash,timestamp,action,serial,subject,time_source` 的紧凑 JSON 重算 SHA-256，验证 3 条审计记录，链尾 `de2f1b4affc6b24e73e2e2ebe67d2d98bf56135936d13223d0de98f0b3f8a1a6`；
- 中间 CA 私钥与证书公钥哈希一致；`root-ca.key.enc` 中不含明文 `PRIVATE KEY` 字符串。

这些是命令行功能自测；QEMU 启动链验证见 8.5，真机尚未验证。

### 8.7 `su`/`initgroups` 修复验证（QEMU）

在修复前，对最终镜像做 QEMU UEFI 启动、以 root 登录后实测：

```text
# id caos
uid=1000(caos) gid=1000(caos) groups=1000(caos),0(root),0(root),... （共 64 项，全是 0）
# su -s /bin/sh caos -c 'id'; echo RC=$?
su: can't set groups: Function not implemented
RC=1
# ls /proc/sys/net
ls: /proc/sys/net: No such file or directory
```

`id caos` 打印 64 个错误组是同一根因的第二个症状：`getgrouplist()` 失败后 BusyBox 忽略返回值、直接打印未初始化的组数组。这也确认 `/etc/group` 内容是正确的（`caos:x:1000:`），问题不在账户文件。

加上 musl 补丁并完整重建后，同样的 QEMU 启动与操作：

```text
# id caos; echo ID_RC=$?
uid=1000(caos) gid=1000(caos) groups=1000(caos)
ID_RC=0
# su -s /bin/sh caos -c 'id'; echo SU_C_RC=$?
uid=1000(caos) gid=1000(caos) groups=1000(caos)
SU_C_RC=0
# su -s /bin/sh caos -c 'caos-ca --version'; echo SU_VER_RC=$?
caos-ca 0.1.0
SU_VER_RC=0
# su -s /bin/sh caos -c 'echo HOME=$HOME; id -u; id -g'; echo SU_ENV_RC=$?
HOME=/mnt/ca-data
1000
1000
SU_ENV_RC=0
# echo exit | su -s /bin/sh caos; echo SU_INTERACTIVE_RC=$?
SU_INTERACTIVE_RC=0
```

即：补充组集合、HOME、uid/gid 切换都正确，`-c` 单命令形式与交互 shell 形式都可用，`S20caos-ca` 的 `su ... -c "caos-ca verify"` 也不再因 `su` 失败而误报完整性校验失败。完整串口记录见 [su-fix.log](output/verification/su-fix.log)。

构建期守卫在 `build.sh` Stage 4：

```text
[CAOS] musl getgrouplist()/initgroups() work without socket syscalls (.../musl-1.2.6/src/passwd/nscd_query.c)
```


## 9. 已知限制

1. **未做真机启动测试。** 已在 QEMU/OVMF 中验证 UEFI→GRUB→内核→init→login、本地 framebuffer console，以及 LUKS2 `luksFormat`/`luksOpen`/`close`（见 8.5）；但尚未在真实目标硬件上验证 USB 控制器、GPU/固件差异和长时间运行。首次真机启动仍需按第 4 节执行。
2. **p3 必须首次手工格式化。** 镜像构建阶段和 `S10caos-data` 都不会自动调用 `luksFormat`。如果不做这一步，系统仍可启动，但没有 CA 数据分区可用。
3. **仅支持 x86_64 UEFI，无 Legacy/CSM 回退。** 目标固件必须从 GPT ESP 启动；本镜像不包含 BIOS 引导代码、SYSLINUX/extlinux 或 hybrid MBR 启动项。UEFI Secure Boot 也没有配置签名，测试/部署时需要在固件中关闭 Secure Boot，或自行完成 GRUB 与内核的签名及密钥管理。部分固件若不自动使用可移动介质默认路径，需要在一次性启动菜单中手工选择 `UEFI: <介质名>`。
4. **Console root 密码默认空。** 这是 Buildroot 默认行为。由于根文件系统只读，运行时 `passwd` 不能持久保存；生产镜像应在构建时通过 `BR2_TARGET_GENERIC_ROOT_PASSWD` 设置 root hash，或限制物理接触并用机柜锁/受控维护流程。当前镜像的 `/etc/motd` 和 `S20caos-ca` 会打印警告。
5. **没有常驻服务。** 不提供远程/网络接口；证书操作需要在物理 console 上手动执行。这是气隙设计，但也意味着没有 API/自动化。
6. **吊销列表是 JSON，不是 X.509 CRL。** 消费方不能直接把 `revoked.json` 当作 PKIX CRL 使用；需要配套的离线分发/集成工具。
7. **根私钥解密工具未暴露到 CLI。** 根私钥在 `init` 之后保持加密归档；日常签发只使用中间 CA。若需要根 CA 离线签发/恢复，需要另外实现受控的解封与签名流程。
8. **审计链和完整性清单没有外部锚点。** 拥有数据分区写权限的攻击者可以同时重构链/清单；需要将审计 tip 和校验摘要定期带到独立可信介质。
9. **无网络意味着无法在线发布 CRL/OCSP。** 证书/吊销状态的分发必须采用离线流程。
10. **物理攻击面。** 没有 TPM、Secure Boot、机箱防拆或内存加密；LUKS 只保护关机状态的数据分区，解锁后 root 用户可访问中间 CA 私钥。
11. **Root 私钥存档格式为本项目自定义的加密封装。** 要恢复根私钥必须实现对应解封逻辑或用同样参数自行解密；当前 CLI 没有提供命令。
12. **没有做过性能/并发压力测试。** 审计追加前会全量校验链，超大日志下签发/吊销会变慢。
13. **初始化/签发/吊销不是跨文件事务。** 如果磁盘写满、断电或权限错误发生在多文件更新之间，可能留下部分已写文件或清单/审计不一致；`verify` 会检测出来，但恢复通常需要人工清理/恢复备份。生产部署应把数据分区放在可靠的存储上并使用 LUKS header 与数据库备份。

---

## 10. 后续加固建议（未实现）

- **AppArmor/SELinux profile**：把 `caos-ca` 限制为只读 `/etc/caos-ca`、读写 `/mnt/ca-data/db` 与 audit、读写 `/run/caos-ca`，封堵库加载与任意路径访问。
- **HSM / PKCS#11**：把根 CA 和中间 CA 私钥移入 HSM，私钥永不出硬件；Rust 侧改用 PKCS#11 签名后端，并保留同样的审计哈希链。
- **双人控制**：签发/吊销需要两名操作员各自输入因子（例如 LUKS key slot + HSM PIN + 审批口令），或使用离线审批清单和二次签名。
- **可验证审计锚定**：定期把 `audit.jsonl` 的链尾哈希签名后写入独立 WORM 介质或纸质日志；实现 append-only 远程见证（在气隙场景中可用物理搬运的签名介质）。
- **启动完整性**：UEFI Secure Boot + TPM measured boot，确保只启动已签名内核/initramfs；把 LUKS 解锁绑定 TPM PCR。
- **Root console 收紧**：移除空口令 root shell，使用只允许维护模式的签名 initramfs 或物理钥匙开关；把 root 密码 hash 固化到镜像并在受控构建时注入。
- **离线 CRL/OCSP 分发**：生成并签名 X.509 CRL，提供离线介质复制与消费方校验工具。
- **密钥生命周期自动化**：中间 CA 轮换、证书到期提醒、LUKS key slot 轮换和 header 备份核验。
- **可复现构建与供应链**：固定 Cargo.lock、Buildroot tag、源码哈希、SBOM、签名镜像与构建环境证明。
- **更严格的时钟**：加入离线 RTC 漂移审计、启动时人工确认时间、防回拨策略；目前依赖固件 RTC 和编译期下限。

---

## 附录 A：配置文件

`/etc/caos-ca/config.toml`（镜像中 `0444`）：

```toml
ca_name = "CAOS"
data_dir = "/mnt/ca-data"
runtime_dir = "/run/caos-ca"
```

`runtime_dir` 可省略，默认即 `/run/caos-ca`。配置由 `caos-ca --config <path>` 覆盖（开发/测试用），生产默认路径固定为 `/etc/caos-ca/config.toml`。

## 附录 B：启动命令与故障排查

| 现象 | 检查 |
|---|---|
| 无法从 SD 卡启动 | 确认固件为 UEFI-only、已关闭 CSM/Secure Boot；确认 `dd` 写的是整盘而不是分区；在 Boot Menu 选择 `UEFI: <介质名>`；检查 p1 是否为 EFI System Partition 且包含 `\EFI\BOOT\BOOTX64.EFI` |
| 固件报 Secure Boot violation | 本镜像未签名；关闭 Secure Boot，或自行签名 GRUB/内核并管理密钥 |
| GRUB 找不到 `CAOSBOOT` 或 `grub.cfg` | 重新写盘；用 `validate-image.py` 检查 p1 类型、FAT32 卷标与 `\EFI\BOOT\grub.cfg` 是否存在 |
| 屏幕停在 `Booting ...`，但 U 盘灯已灭 | 先接串口：若串口已到 `caos login:`，说明系统已启动，缺的是本地 framebuffer console；确认内核含 8.3 的 DRM/fbcon 选项。若串口停在 `Waiting for root device`，检查 USB 控制器/端口/存储设备 |
| `cryptsetup` 报 `Cannot initialize crypto backend` / `Failed to set pbkdf parameters` | 说明 cryptsetup 用了 kernel/AF_ALG 后端，但 `CONFIG_NET=n` 下 AF_ALG 不存在；确认 `BR2_PACKAGE_LIBGCRYPT=y` 且 cryptsetup 配置为 `--with-crypto_backend=gcrypt`（见 8.3），再重建 |
| ASUS 上出现 `xhci_hcd ... Error while assigning device slot ID` / `Max number of devices this xHCI host supports is 64` | 不要禁用 xHCI/USB_STORAGE（根文件系统在 U 盘）；换后置 USB 2.0 端口、绕开前面板 hub/USB-C 转接，更新或重置 BIOS，并确认没有使用 `noapic` |
| 串口无输出 | 115200 8N1；确认 `console=ttyS0,115200` 生效；检查 ttyS0 电平/适配器 |
| 启动后没有 `/mnt/ca-data` | 查看 `S10caos-data` console 输出；确认 p3 已 LUKS2 格式化并 ext4 |
| `caos-ca` 报时钟错误 | RTC 时间早于二进制构建时间；在固件设置或 console 设置正确时间后重试 |
| `su -s /bin/sh caos` 报 `su: can't set groups: Function not implemented` | `CONFIG_NET=n` 让 `socket(2)` 返回 `ENOSYS`，而 musl 的 `getgrouplist()` 只容忍 `EAFNOSUPPORT`。确认 `BR2_GLOBAL_PATCH_DIR` 生效、`output/build/musl-*/src/passwd/nscd_query.c` 含 `|| errno == ENOSYS`（见 6.1），然后重建 |
| `id caos` 打印一长串错误/重复的组 ID | 同上：`getgrouplist()` 失败后 BusyBox 会打印未初始化的组数组，这个现象随 musl 补丁一起消失 |
| `caos-ca verify` 失败 | 先读具体错误；检查 CA 数据、审计链、证书/私钥权限和系统时间；不要继续签发直到修复 |
| `caos-ca` 报 `mlock` 失败 | 当前 `RLIMIT_MEMLOCK` 太小；在 init/服务环境提高 `ulimit -l`（建议至少 64 KiB） |

## 附录 C：许可

- `caos-ca`：MIT OR Apache-2.0。
- 集成树中的脚本与配置：随项目交付；Buildroot、GRUB、BusyBox、util-linux、cryptsetup 等第三方组件遵循各自上游许可。本工程不修改 Buildroot 源码树。
