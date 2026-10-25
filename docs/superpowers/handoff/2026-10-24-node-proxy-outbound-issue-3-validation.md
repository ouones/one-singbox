# 节点代理出站 #3 验证记录

日期：2026-10-24；分支：`codex/issue-3-ss-import`；基线：`b40b63496b99fd3ffc7d58abb384b805653c2560`

## 自动化验证

- `tests-node-proxy-outbound.sh`：通过。测试覆盖两份 core 的菜单导入、Base64URL 缺失 padding、百分号编码明文凭据、首次冒号切分、单次解码、`+` 保留、SS2022 双密钥不截断、名称／地址展示、非法输入的无副作用、SS 缓存复用和旧 `parse_ss_uri_for_outbound` 兼容入口。
- 回归通过：`tests-node-name-label.sh`、`tests-snell-support.sh`、`tests-relay-support.sh`、`tests-log-limit.sh`。
- `bash -n` 检查两份 core 与改动脚本；仅在 WSL 临时 LF 副本中运行，没有批量改仓库行尾。
- `git diff --check`：通过。

## 官方内核链路

官方 sing-box `v1.14.0`，Linux amd64、Go 1.26.7，revision `0b8995879f29a9b98ee027bc17b75e101445b238`。两次测试都使用产品 parser 生成的完整 normalized outbound；内核检查、TCP、UDP、远端域名请求和停上游后无直连回退均通过。

- 普通 SS：[`2026-10-24-node-proxy-outbound-issue-3-ss-native.json`](2026-10-24-node-proxy-outbound-issue-3-ss-native.json)
- SS2022 `2022-blake3-aes-128-gcm` 双密钥：[`2026-10-24-node-proxy-outbound-issue-3-ss2022-native.json`](2026-10-24-node-proxy-outbound-issue-3-ss2022-native.json)

SS2022 outbound 的 `password` 保留完整 `server_key:user_key`。受控回环上游按官方 [Shadowsocks 服务端与客户端示例](https://sing-box.sagernet.org/manual/proxy-protocol/shadowsocks/)配置服务端 `password=server_key`、`users[0].password=user_key`。原实验脚本把整个双密钥字符串放进服务端 `password`，官方内核因此拒绝启动；本次仅在 `/tmp` 临时副本修正了 fixture，未修改共享 native-lab。链路仍使用 parser 的完整 outbound 对象，测试期间只将其 `server` 与 `server_port` 替换为回环目标。

未连接生产或公开上游；真实链路证据限于本地受控 SS／SS2022 上游和上述代表算法。
