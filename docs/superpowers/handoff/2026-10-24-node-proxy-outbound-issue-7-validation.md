# 节点代理出站 #7 验证记录

日期：2026-10-24
分支：`codex/issue-7`

## 解析与菜单集成

- `tests-node-proxy-outbound.sh` 的 `vless-menu` 场景分别针对根目录 `core.sh` 与 `src/core.sh` 运行通过。覆盖 ECH Base64／PEM／显式空值、控制字符边界、pcs 整张证书摘要和版本门槛、vcn 等价校验名，以及无映射扩展拒绝；菜单断言检查 ECH 和 pcs 写入缓存与运行时配置，并验证失败时保留现状且不重启。
- 两份 core 的 VLESS parser 代码块逐字一致。修改后的 `core.sh`、`src/core.sh`、`src/help.sh` 与 `tests-node-proxy-outbound.sh` 通过 `bash -n`；`git diff --check` 通过。

## 真实内核验证

- NAS 上 Debian 12、Linux/amd64 的官方 sing-box v1.14.0（Go 1.26.7，revision `0b8995879f29a9b98ee027bc17b75e101445b238`）与官方 `v1.15.0-alpha.13`（Go 1.26.10，revision `824dbcfb4dd0a95921840b1737b950cde590241e`）均执行了从两份产品 parser 导出的实际对象。两份 core 的 ECH Base64／PEM 与 pcs 对象一致；v1.14.0 ECH、默认 TLS 和空 ECH，及 alpha.13 ECH／pcs 的完整配置检查通过；v1.14.0 的非空 pcs 因不支持字段被拒绝。
- v1.14.0 对实际静态 ECH 对象完成 TCP、UDP、远端域名、断开上游后无直连回退验证，全部通过；替换为另一份有效 ECH 配置后，TLS 握手按预期拒绝。显式空 `ech` 对象触发了 loopback DNS 夹具的 HTTPS/SVCB 查询，并完成 TCP／UDP／远端域名和 no-fallback 验证。
- 默认 TLS 校验用例拒绝了不受信任证书；在隔离验证进程显式信任该测试证书后连接通过。alpha.13 的实际 pcs 对象在正确整张证书 SHA-256 pin 下连接通过，换为错误 pin 后连接被拒绝。
- native-lab 原始报告及 parser JSON 保存在本地 `.scratch/issue7-native-support/results/`。全部链路限于 loopback 测试夹具；不代表公开上游可达。可用的 1.15 对照仅为 alpha.13，未验收正式 1.15.0 版。
