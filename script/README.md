# script/ — manage.sh 的实现层

`manage.sh` 是唯一入口，只做参数解析、库加载与子命令分发；全部实现在本目录：

```text
script/
├── lib/
│   ├── common.sh      # die/log/log_stage/need/abspath/confirm/require_*/json_escape/ERR trap/用法
│   ├── config.sh      # 全局 CLI 解析、默认值、路径派生、config.env 读写
│   ├── state.sh       # output/.state/ 读写、flock 锁、build-info.json、stage stamps、input_hash
│   ├── buildroot.sh   # br_make()/br_defconfig() —— Buildroot 调用封装
│   ├── verify.sh      # 验收原语：失败计数器、文件/内核配置/squashfs 权限/ESP 列表检查
│   └── flash.sh       # 烧录原语：resolve_device/assert_disk_device/assert_not_mounted/
│                      # find_partition_by_label/flash_keep/flash_erase（FLASH_DRY_RUN 支持）
└── commands/
    ├── doctor.sh       # 环境体检（工具、Rust target、Buildroot 树、output 可写）
    ├── build.sh        # Stage 1-3/5：Rust 静态二进制 → defconfig → 全量构建 → 状态落盘
    ├── verify.sh       # Stage 4：GPT/ESP/内核策略/rootfs 全量验收（只读）
    ├── package.sh      # dist/ 打包（镜像四件套 + SHA256SUMS + build-info）
    ├── clean.sh        # 清理构建状态（默认保留 dl/）
    ├── flash.sh        # 烧录（整盘断言、CAOSDATA 保留/擦除、二次确认、--dry-run）
    ├── run.sh          # QEMU + OVMF 冒烟（本地可选，CI 不执行）
    ├── version.sh      # 版本与工具链信息
    └── release.sh      # package + RELEASE_NOTES.md + git tag（默认 dry-run）
```

## 命令速查

| 命令 | 作用 | 锁 | 常用参数 |
|---|---|---|---|
| `doctor` | 环境体检 | 无 | `--json`、`--install`（仅装 Rust target） |
| `build` | Rust + Buildroot 构建 | 排他 | `--verify`；全局 `-j/-b/-o/-d/--clean/--skip-clippy` |
| `verify` | 验收（只读） | 共享 | `--json` |
| `package` | 打包 dist/ | 共享 | `--out DIR`、`--dry-run` |
| `clean` | 清理构建状态 | 排他 | `--all`、`--dry-run` |
| `flash` | 烧录整盘 | 排他 | `--image/--keep/--erase/--yes/--dry-run`（需 root） |
| `run` | QEMU 冒烟 | 无 | `--qemu/--ovmf/--memory/--dry-run`（本地可选） |
| `version` | 版本信息 | 共享 | `--json` |
| `release` | package + notes + tag | — | `--tag/--yes/--out/--dry-run`（默认 dry-run） |

全局参数（一律 CLI，不读 `JOBS`/`CAOS_*` 等环境变量）：

```bash
./manage.sh [全局参数] <子命令> [全局参数] [子命令参数...]
```

## 状态目录 output/.state/

```text
output/.state/
├── config.env        # KEY='value'，构建成功后落盘；verify/package 启动时 source 恢复路径
├── build-info.json   # version/commit/branch/dirty/工具链/时间/JOBS/路径
├── build.lock        # flock 锁文件（build/clean/flash 排他，verify/package/version 共享）
└── stages/
    ├── rust.done     # 内容为 input_hash（Cargo.lock + git HEAD + 关键配置 的 sha256）
    ├── buildroot.done
    └── verify.done   # hash 不匹配视为未完成——stamp 只用于加速，不用于正确性
```

## 退出码约定

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 运行失败（构建失败、烧录断言失败、验收有失败项） |
| 2 | 用法错误（未知子命令/参数、非交互缺少 `--yes`） |
| 3 | 前置条件不满足（缺工具、缺产物、危险路径） |

## 如何新增子命令

1. 新建 `script/commands/<name>.sh`，实现入口函数 `cmd_<name> "$@"`（入口函数名与文件名一致）；
2. 参数自解析，复用 `lib/common.sh` 的 `die/need/confirm`，不得重定义全局路径语义；
3. 在 `script/lib/config.sh` 的 `MANAGE_COMMANDS` 中注册命令名；
4. 需要全局路径变量时直接使用 `config.sh` 派生的 `OUTPUT_DIR/SDCARD_IMAGE/...`；
5. 写操作拿 `acquire_lock exclusive`，只读拿 `shared`；遵循退出码约定；
6. 在本 README 命令速查表与顶层 `top_usage()` 中补充说明。

## 分层约束

- `manage.sh`：零业务逻辑，只分发；
- `lib/`：无状态工具与封装，禁止写项目策略（如"内核必须 `CONFIG_NET=n`"——那属于
  `commands/verify.sh` 或 `validate-image.py`）；
- `commands/`：业务流程与策略，参数自解析。
