# Issue #8 节点生命周期验证记录

- 分支：`codex/issue-8-node-lifecycle`
- 基线：`83c207f30535dd838f75afa5bf7a33e58a8c01bb`
- 验证日期：2026-10-24
- NAS 上执行的产品 core 为本分支 `core.sh` 的 LF 临时副本，SHA-256：`fa99f882e2143939d0bbc46755566983fe0a9fc734a7286c7262d3239842133a`。

## 代码与回归检查

- `bash -n`：根 `core.sh`、`src/core.sh`、`src/dns.sh`、`src/help.sh` 和四项既有测试及本票测试均通过；在 NAS 临时副本执行。
- 本票完整代理生命周期矩阵以及 `tests-node-name-label.sh`、`tests-snell-support.sh`、`tests-relay-support.sh`、`tests-log-limit.sh` 曾在 Linux 规则切换前通过一次性 LF 副本运行。relay harness 为确认式 systemd 重启增加了隔离替身。
- NAS 上最终完整矩阵未由本任务重复运行：首三个根 core 场景 `happy`、`parser-ss2022`、`ss-import-encoding` 通过，随后在 `ss-import-invalid` 继续处理时按集成协调停止，避免与并行代理争用 NAS。merger 负责最终整套回归。
- 两份 core 的 `render_runtime_node_outbound_modes`、`sync_runtime_node_outbound_modes`、确认式重启和生命周期 helper、`create`、`del` 函数体逐一比对一致。
- `git diff --check` 通过。

## NAS systemd 真实服务

通过 `ssh nas` 在 Debian 12 上使用官方 sing-box 1.14.0（musl 构建）及唯一命名的 `systemd-run --collect` transient unit。设置 `StartLimitIntervalSec=0`，避免快速隔离场景触发 systemd 默认启动限流。测试节点仅监听 `127.0.0.1`，上游使用合成 SS 链接且未建立连接。

- 菜单导入 SS：完整 `sing-box check` 通过，产品等待确认服务重启后成功返回。
- 端口迁移：节点文件与 metadata 移至新文件名；完整 SS cache、managed outbound 和 route 均改绑新 inbound tag；真实服务保持 active。
- 删除节点：受管 metadata、outbound、route 清除；无关 custom outbound 保留；真实服务重启并保持 active。
- 迁移 restart 故障注入：第一次只对该私有 unit 返回错误；原节点、metadata、公共配置逐字节恢复，候选文件移除，恢复重启成功且服务 active。
- 清理检查：transient unit 为 `not-found`，无 fragment，MainPID 为 0；临时目录已删除。

## NAS OpenRC 真实服务

NAS 宿主没有 `rc-service`，未向宿主安装依赖。复用已有 fixture，在 NAS 私有 mount/PID/network namespace 内建立 Alpine 3.24.3 临时 rootfs，使用 OpenRC 0.63.2 和官方 sing-box 1.14.0。

- SS 菜单导入通过，真实完整配置检查与 OpenRC 服务状态检查通过。
- 端口迁移通过，服务启动计数为 2；迁移时首次 start 失败、恢复 start 成功通过，计数为 3，节点、metadata 和公共配置逐字节恢复。
- 既有 apply 首次 restart 失败后恢复成功、apply 与恢复均失败的两项场景通过。
- fixture 输出 `No permission to apply cgroup settings`；真实 `rc-service` 状态、启动次数和文件断言均通过。临时 rootfs 已清理，NAS 宿主服务和软件包状态未更改。

## 未覆盖范围

- 未验证真实上游连通性、实际代理出站流量或出口地址；SS 上游为未连接的合成目标。
- 未在真实服务中执行 VLESS、DNS 更新和 Caddy TLS 生命周期；这些路径由隔离集成测试覆盖，其中 DNS 同步失败断言验证不会覆盖公共配置或重启。
- NAS 上完整矩阵留给 merger 统一执行，不能把上述前三个场景记为整套矩阵通过。
