# 环境管理（二开）开发说明

需求来源：`laitekin/proxmox-dev` 仓库 `docs/requirements.md`。本文记录 `pve-manager` 中已经实现的部分、接口和后续计划。

> 状态：代码已提交，未在真实 PVE 节点上安装/运行验证。Perl 业务逻辑有单元测试；API 模块只做了加载和 JSON Schema 校验；网页只做了语法检查。

## 第 1 阶段：环境操作闭环（已实现，待上机验收）

### 数据模型

环境记录保存在 pmxcfs：`/etc/pve/env-manager/environments.json`，全集群共享，宿主重启后仍在。写操作统一经过 `PVE::EnvManager::lock_db()`（`cfs_lock_domain('env-manager')`），保证多个请求并发时不会超出配额。

| 字段 | 说明 |
| --- | --- |
| `id` | 环境 ID，`env-xxxxxxxx`，与 VMID 分开 |
| `vmid` / `node` | 对应的 QEMU VM 和所在节点（列表中以实时位置为准） |
| `template` / `os` | 来源模板和系统类型（windows / linux / ...） |
| `name` / `description` / `owner` | 名称、备注、归属用户 |
| `state` | `creating` / `ready` / `error` / `deleting` |
| `error` / `task` | 最近一次错误和任务 UPID |
| `request-id` | 创建请求的幂等键，重试不会重复创建 |

列表接口再合并实时状态，给出 `status`（running/stopped/absent）和 `health`：

- `ok`：记录与 VM 一致。
- `missing`：记录在，但 VM 已不存在（被人在 PVE 里删掉），需要处理。
- `creating` / `deleting` / `error`：任务进行中或失败。
- 创建/删除任务的进程意外终止（如宿主重启），下一次查询列表时会自动纠正为 `error` 或 `ready`，不会永久卡住配额。

### 准入与配额

`/cluster/environments/options`：

| 选项 | 作用 |
| --- | --- |
| `max-envs` | 已保存环境总数上限（创建失败且没有 VM 的记录不占名额） |
| `max-running` | 同时运行上限；启动前在锁内预留名额，并行启动也不会超限；预留 10 分钟后过期 |
| `max-creating` | 同时创建数上限 |

`0` 表示不限。

### API（`/api2/json/cluster/environments`）

| 方法 | 路径 | 说明 | 权限 |
| --- | --- | --- | --- |
| GET | `envs` | 环境列表 + 实时状态/资源 | 按 VM.Audit / 归属过滤；Sys.Audit 看全部 |
| POST | `envs` | 从模板创建（`template`、`name`、`count`、`cores`、`memory`、`target`、`storage`、`full`、`start`、`request-id`） | `/vms` 上 VM.Allocate，以及克隆所需权限 |
| GET/PUT | `envs/{id}` | 详情 / 修改名称、备注、归属 | VM.Audit / VM.Config.Options；改归属需 Permissions.Modify |
| DELETE | `envs/{id}` | 停机并销毁 VM 后删除记录；`keep-vm=1` 只取消托管 | VM.Allocate |
| POST | `action` | 批量 `start`/`shutdown`/`stop`/`reboot`，任务日志里逐项给出结果 | 每个 VM 的 VM.PowerMgmt |
| POST | `adopt` | 把已有 VM 纳入管理 | VM.Allocate |
| GET | `templates` | 可用模板（有 VM.Clone 权限的 QEMU 模板） | — |
| GET/PUT | `options` | 配额 | 修改需 `/` 上 Sys.Modify |

克隆、改配置、启停、销毁都通过本地 API 客户端以**调用者自己的凭据**转发给 qemu-server 现有接口，PVE 原有权限检查、锁和任务日志全部保留，没有绕过。

### 网页

数据中心 → **Environments**：

- 列表：名称、健康、状态、VMID、节点、系统、CPU、内存、运行时间、归属；5 秒自动刷新。
- 多选批量启动/关机/停止/重启；单选打开控制台（复用 PVE noVNC/SPICE）、跳转到 VM、编辑、查看任务、删除或取消托管。
- 创建向导：选模板、名称、数量、CPU/内存、目标节点、完整/链接克隆、存储、创建后启动；窗口自带幂等键。
- 「Add existing VM」纳管已有 VM，「Limits」设置配额。

快照、备份、恢复、硬件配置继续使用 PVE 原有 VM 页面（双击环境跳转）。

### 代码位置

| 文件 | 作用 |
| --- | --- |
| `PVE/EnvManager.pm` | 数据库读写、配额/准入、状态合并（无 PVE 运行依赖，可单测） |
| `PVE/API2/Cluster/Environments.pm` | REST API 与后台任务 |
| `www/manager6/dc/Environments.js` | 环境列表页 |
| `www/manager6/window/EnvironmentCreate.js` | 创建/编辑/配额/纳管窗口 |
| `test/env_manager_test.pl` | 单元测试（`make -C test test-env-manager`） |

## 上机验收清单（第 1 阶段）

在与源码版本匹配的 PVE 测试节点上：

1. 构建安装 `pve-manager` 包，`systemctl restart pveproxy pvedaemon`。
2. 准备 Linux 和 Windows 模板各一（装好 qemu-guest-agent / VirtIO 驱动后「转换为模板」）。
3. 网页创建 1 个和 `count=3` 的环境，确认 VMID 不冲突、任务日志逐项成功。
4. 断网/重复提交同一创建窗口，确认不会重复创建。
5. 设置 `max-running=2` 后批量启动 3 个，确认第 3 个被拒绝并在日志中说明。
6. 创建中重启 `pvedaemon` 或宿主，确认记录最终变为 `error` 或 `ready`。
7. 在 PVE 原生界面删除某 VM，确认环境显示 `VM missing`。
8. 普通用户只授予部分 VM 权限，确认只能看到/操作授权环境。

## 后续阶段

- **第 2 阶段：代理与网络**——代理池、长期绑定、健康巡检、出口 IP 记录；客体外强制出站（每环境独立网桥/网关 + nftables 默认拒绝，代理故障即阻断，覆盖 DNS/UDP/IPv6）；环境间及宿主管理面隔离。
- **第 3 阶段：资源与管理**——带宽/IO 限制、启动排队（目前是超限直接拒绝）、操作审计、按用户配额、备份恢复后核对绑定。
- **第 4 阶段**：macOS、多节点调度、应用模板。

## 待确认条件（影响第 2 阶段设计）

- 代理供应商、协议（HTTP/SOCKS5）、是否支持 UDP、是否有静态/粘性出口及租约。
- 出站网关放在宿主（nftables + 透明代理进程）还是独立网关 VM。
- 服务器规格、目标 PVE 版本、并发规模和使用人数。
