# 合并前发布硬门禁记录 — v1.58（2026-11-20）

对应工单：#104（父 spec #98）。

## 验收测试包

| 项目 | 值 |
|---|---|
| 构建方式 | GitHub Actions `release.yml` 的 `build-test-package` job，只构建一次 |
| Workflow run | `44729407983`（分支 `delivery/issue-97`，提交 `8ae5405`） |
| 内部产物 | `release-test-package` artifact |
| 资产名 | `code.tar.gz` |
| 大小 | 3,062,092 字节 |
| SHA-256 | `b4d087f84816a4f8cec7b11a5da2905d61819094bcf2019c5661a6e7d33f1e3c` |
| 包内布局 | 包含 `src/core.sh`；不包含根 `core.sh` |

全新安装、`install.sh -l`、v1.56 升级、v1.57 升级与运行冒烟全部核对并使用上述同一个文件与摘要。

## 隔离环境

- 宿主机：腾讯云 VPS `43.167.6.172`（Debian 13，Docker 29.9.3）。
- 每个用例使用独立容器：`one-singbox-test:debian13`，`--cpus 1 --memory 768m --memory-swap 768m --pids-limit 512 --network bridge`；未使用 host 网络、未使用特权模式、未挂载宿主机目录、未发布任何端口。
- 测试所需项目副本、Release 包、旧版本包、真实 sing-box 二进制和临时配置只放在容器内 `/work`、`/cache` 与临时根目录。
- 宿主机线上服务只读核验：测试前后 `sing-box` 均为 `active/running`（MainPID 727，启动时间 2026-11-19 01:13:39 CST），`nginx` 均为 `active/running`（MainPID 744，启动时间 2026-11-19 01:13:40 CST），未发生变化。

## 验收用例

| 用例 | 结果 | 关键证据 |
|---|---|---|
| 全新安装（测试包，非本地目录） | PASS | `sb` / `sing-box` 入口可用，脚本版本 v1.58；`src/core.sh` 存在、根 `core.sh` 不存在 |
| 历史根 `core.sh` 清理成功 | PASS | 显式创建后执行 `sb version`，文件被删除且无警告 |
| 历史根 `core.sh` 不存在 | PASS | 全新安装无根副本，入口无清理警告 |
| 清理失败模拟 | PASS | 历史 `core.sh` 为非空目录时入口 rc=0、输出含路径与残留/手动删除警告、无 `配置迁移失败`、sing-box PID 不变、配置与节点文件不变、未触发核心服务 restart/reload |
| `install.sh -l` 本地安装 | PASS | 从交付树副本完成安装，入口与脚本版本 v1.58 正常，配置检查通过 |
| v1.56 → v1.58 升级 | PASS | 旧安装含根 `core.sh`；更新后版本 v1.58，根 `core.sh` 被清理；再次创建后第一次 `sb` 命令再次清理；节点 JSON 哈希不变，配置检查通过 |
| v1.57 → v1.58 升级 | PASS | 同上；升级后在隔离环境内真实启动 sing-box 并完成代理流量冒烟 |
| 真实 sing-box 配置检查 | PASS | 全新安装、v1.56 升级、v1.57 升级均执行 `sing-box check` 通过 |
| 真实代理流量冒烟 | PASS | 全新安装及 v1.57 升级后，以本地 VLESS-REALITY 客户端经 SOCKS 访问本地 HTTP 目标，返回 `gate-smoke-ok` |
| 测试结束清理 | PASS | 无遗留 `osb-gate-*` 容器；临时目录与临时端口已移除；宿主机线上服务状态未变化 |

## 结论

**PASS — 硬门禁通过。** 未出现“外部网络故障导致验证未完成”的情况，测试包摘要与所有验收用例一致，允许进入合并与正式发布流程；正式发布必须复用本文档记录的同一个 `code.tar.gz` 与 SHA-256。
