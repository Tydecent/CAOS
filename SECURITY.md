# 安全策略（Security Policy）

本项目：**CAOS** —— 气隙（air-gapped）证书颁发机构操作系统，由 Buildroot 定制嵌入式 Linux 镜像与 Rust 静态编译的 CA 管理工具 `caos-ca` 组成。

维护者高度重视安全问题。请通过本文档描述的渠道负责任地报告漏洞，**请勿在公开 Issue、Discussion 或社交平台披露未协调的漏洞细节。**

## 支持的版本（Supported Versions）

| 版本 | 分支 | 支持状态 |
|  |  |  |
| 开发版 | `main` | ✅ 支持并接收安全修复 |
| 历史提交 / 其他分支 | — | ❌ 不支持，请更新到 master |

项目尚未发布稳定版本标签，安全修复仅针对 `main` 最新提交进行。请始终使用 CI 构建或自行从当前源码构建的二进制。

## 报告漏洞（Reporting a Vulnerability）

**首选渠道：GitHub 私有漏洞报告（Private Vulnerability Reporting）**

1. 打开 [GitHub Report a vulnerability](https://github.com/Tydecent/CAOS/security/advisories/new)
2. 该渠道端到端保密，无需额外加密通信。

报告时请尽量包含：

- 受影响组件与提交哈希（`caos-ca --version` 可输出版本、提交与构建时间）；
- 漏洞类型与影响评估（例如：密钥材料泄露 / 证书伪造 / 审计链失效 / 拒绝服务）；
- 详细复现步骤，能提供最小化 PoC 更佳；
- 前提条件（是否需要 LUKS 分区已解锁、是否需要物理接触、是否需要 root 等）；
- 修复建议（如有）。

**响应时限**（工作日）：

| 阶段 | 目标时间 |
|  |  |
| 确认收到报告 | 3 个工作日内 |
| 完成评估并给出严重性分级 | 7 天内 |
| 严重（Critical）问题发布修复 | 30 天内 |
| 其他问题发布修复 | 与下个版本一同发布 |

中英文报告均可接受。

除此之外，我们也通过以下邮箱地址接受报告：
```
Smart100430@163.com
```

## 范围（Scope）

### 收录范围（In Scope）

- `caos-ca/` —— Rust 工具全部源码：根密钥加密信封格式、审计哈希链、完整性清单逻辑、文件权限与路径检查、CLI 参数处理、`build.rs` 构建元数据；
- `caos-buildroot/` —— 外部构建树：defconfig、board 脚本（`S10caos-data`、`S20caos-ca`、`post-*.sh`）、genimage/GRUB 配置、rootfs overlay；
- `script/` 与 `manage.sh` —— 构建与发布工具链；
- `.github/workflows/` —— CI 工作流及构建产物的完整性。

### 不收录范围（Out of Scope）

- **上游依赖**（Buildroot、Linux 内核、musl、BusyBox、ring、rcgen、cryptsetup 等）：请先向上游报告；如 CAOS 的特定用法放大了上游问题，欢迎附上游链接告知；
- **前提性供应链攻击**：攻击者已控制构建主机、CI 或二进制分发渠道的场景；
- **违反文档化物理安全假设的纯物理攻击**：项目威胁模型假设设备处于受控物理环境。若发现可绕过文档化防护的物理攻击路径（如未解锁状态下恢复数据），仍欢迎报告；
- **在通用多用户 Linux 上运行 `caos-ca`**：该工具为单用途气隙设备设计，非多用户环境下的权限边界问题不在此范围；
- 针对不属于报告者的任何生产 CA 实例的测试。

## 严重性分级参考（Severity Guidelines）

评估基于项目文档化前提：只读 squashfs 根、LUKS2 加密数据分区、非特权 `caos` 用户、进程加固（`PR_SET_DUMPABLE=0` 等）、设备物理隔离与网络气隙。

| 级别 | 典型情形 |
|--|--|
| 严重（Critical） | 无需物理介入即可获取根/中间私钥；无需 LUKS 口令即可伪造证书；镜像或构建产物中的远程代码执行 |
| 高（High） | 绕过完整性清单或审计链检测；本地提权至 root；加密信封格式缺陷导致口令离线爆破显著加速 |
| 中（Medium） | 需要 LUKS 已解锁状态的信息泄露；导致 CA 数据损坏或不可用且无审计痕迹的缺陷；文件权限/加固检查可被绕过 |
| 低（Low） | 加固缺口、日志中的敏感信息残留、默认值与文档问题 |

## 协调披露（Coordinated Disclosure）
- 默认 **60 天**协调披露期，自报告确认之日起计算，双方可协商延长；
- 修复发布后，将根据需要发布 GitHub Security Advisory（GHSA）并申请 CVE 编号；
- 修复公告中会致谢报告者，如需匿名请注明；
- 请在披露期结束前不要公开技术细节。

## 研究者安全港（Safe Harbor）
- 请仅在**自有硬件或虚拟机**中测试，使用自签发测试数据；
- 不得访问、测试、停机或影响任何不属于你的 CA 实例或第三方设备；
- 善意、合规的研究行为不会被执行方追究；请遵守所在地法律。

## 加密通信（可选）

对于敏感报告，我们建议使用PGP加密。公钥指纹：

```
051B A444 CA11 EC36 27DA 3C1E 012D CA8A B54E 5039
```

公钥下载：
- keys.openpgp.org: https://keys.openpgp.org/search?q=051BA444CA11EC3627DA3C1E012DCA8AB54E5039
