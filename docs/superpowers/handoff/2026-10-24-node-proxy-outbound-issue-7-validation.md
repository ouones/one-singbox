# 节点代理出站 #7 验证记录

日期：2026-10-24
分支：`codex/issue-7`

## 解析与菜单集成

- `tests-node-proxy-outbound.sh` 的 `vless-menu` 场景分别针对根目录 `core.sh` 与 `src/core.sh` 运行通过。覆盖 ECH Base64／PEM／显式空值、控制字符边界、pcs 整张证书摘要和版本门槛、vcn 等价校验名，以及无映射扩展拒绝；菜单断言检查 ECH 和 pcs 写入缓存与运行时配置，并验证失败时保留现状且不重启。
- 两份 core 的 VLESS parser 代码块逐字一致。修改后的 `core.sh`、`src/core.sh`、`src/help.sh` 与 `tests-node-proxy-outbound.sh` 通过 `bash -n`；`git diff --check` 通过。

## 真实内核验证

- 截至本提交，尚未完成真实产品 parser 对象的完整 `check` 或 ECH／pcs 正负连接；本记录不将替身菜单测试当成协议互通证据。独立 native-lab 验收正在进行，结果将在后续文档提交补充。
- 本地可用的 1.15.0 对照仅为 `v1.15.0-alpha.13`；未验收正式版。空 `ech` 的 DNS HTTPS 获取行为也尚未实测。

