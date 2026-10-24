# 节点代理出站 #5 验证记录

日期：2026-10-24  
分支：`codex/issue-5-ws-grpc`  
基线：`83c207f30535dd838f75afa5bf7a33e58a8c01bb`

## TDD 与定向测试

- 先加入 WS parser 用例时，旧实现因 `VLESS WS without TLS should parse` 失败；实现后该用例转绿。
- NAS 的 `vless-menu` 定向场景中，根目录 `core.sh` 完成且无断言失败。`src/core.sh` 生成了 WS/gRPC none、TLS、Reality 六个 parser 对象；600 秒切片在后续菜单断言完成前超时，因此不记作 `src/core.sh` 菜单场景通过。
- 两份核心导出的六个 parser 对象一致；v1.14.0 对两份核心的 12 个完整 outbound 配置检查均通过。
- 本轮启动后追加的三条拒绝断言（未知 VLESS 参数、gRPC 的 `ed`、WS 的 `authority`）不在该 NAS 切片内；四项既有回归也未在本次 NAS 切片重跑。交由最终集成全回归覆盖。
- 当前完整 `tests-node-proxy-outbound.sh` 的 LF 临时副本通过 NAS `bash -n`；`git diff --check` 通过。两份核心的 WS/gRPC parser 区块在换行规范化后逐字一致，其他既有整文件差异未改动。仓库 Bash 文件仍为 CRLF。

## sing-box 与真实链路

- 内核：官方 sing-box v1.14.0，Debian 12，linux/amd64，Go 1.26.7；revision `0b8995879f29a9b98ee027bc17b75e101445b238`。构建含 `with_gvisor`、`with_quic`、`with_utls`，不含 `with_grpc`，所以实测的是 lite gRPC 构建。
- 12 个 parser 对象完整检查通过；以原始 core parser 对象分别完成 WS/gRPC none、TLS、Reality loopback TCP、UDP、远端域名与停止上游后的 no-fallback 检查，六种组合全部通过。Reality 使用与 parser 公钥匹配的临时 keypair。
- WS query 用例保留客户端原始路径，例如 `/socket?token=a%26b`。夹具只调整服务端：服务端 `transport.path` 对应解码后的 `request.URL.Path`（`/socket?token=a&b`）；在客户端未声明 header 且路径含 query 时，夹具给服务端设置 `Sec-WebSocket-Protocol`，避免 v1.14.0 空 early-data header 分支再比较 escaped `RequestURI`。TLS early-data 用例已有 `x-early-data`，不需要该补值。客户端 parser 对象与产品实现均未修改。
- 远端域名用例在隔离的服务端配置中增加 sing-box hosts DNS：`localhost -> 127.0.0.1`，并保留 `localhost -> direct` 路由。客户端仍向代理提交域名；echo 和远端 VLESS inbound 记录验证了该请求经代理到达 loopback 目标。未修改 NAS hosts 或系统 DNS。
- native 报告：`/tmp/one-singbox-issue5-1eiCkM/results/issue5-native-only-20261024T143637Z/`。最终回归环境将把报告复制到主 scratch。

WebSocket 路径处理依据：[v1.14.0 client](https://github.com/SagerNet/sing-box/blob/v1.14.0/transport/v2raywebsocket/client.go)、[v1.14.0 server](https://github.com/SagerNet/sing-box/blob/v1.14.0/transport/v2raywebsocket/server.go)。hosts DNS 配置字段依据：[v1.14.0 DNS options](https://github.com/SagerNet/sing-box/blob/v1.14.0/option/dns.go)。

## 限制

- 本次可用真实二进制为 lite gRPC 构建；完整 `with_grpc` authority 默认值与未知版本拒绝由 parser 单元用例按版本／tag 输出覆盖，未用完整构建实测。
- 该 NAS 定向切片不是完整回归。最终集成需重跑完成版 `tests-node-proxy-outbound.sh` 与四项既有回归。
- 所有链路都使用 loopback 夹具；不代表公开上游可达。
