# 节点代理出站 #6 验证记录

日期：2026-10-24
分支：`codex/issue-6-http-quic`

## 解析与集成

- `tests-node-proxy-outbound.sh`：HTTP/h2、HTTPUpgrade、QUIC 场景通过；同时覆盖两份 core 的菜单导入、缓存、运行时出站、节点路由、重启次数，以及完整候选检查失败和 QUIC+Reality 拒绝时保留原元数据和公共配置。
- HTTP `host` 按逗号拆分为原生列表；HTTPUpgrade `host` 保持单值，逗号列表明确拒绝，不截取其中一项。两者的 `path` 缺省为 `/`，空路径和其他传输上的无意义参数拒绝。
- `h2` 映射到原生 HTTP 且必须使用 TLS／Reality。HTTP 支持明文、TLS、Reality；HTTPUpgrade 支持 none、TLS、Reality。QUIC 只接受 TLS、`quicSecurity` 缺省／`none` 和空 `key`；拒绝无 TLS、Reality、额外加密/key。TCP `headerType=http` 伪装明确拒绝。
- 菜单和同步仍使用现有代理缓存、路由、完整候选检查及重启恢复路径；本票未改事务逻辑。

## 真实内核验证

内核：官方 sing-box v1.14.0，linux/amd64，Go 1.26.7，revision `0b8995879f29a9b98ee027bc17b75e101445b238`，包含 `with_quic`、`with_utls`、`with_gvisor`。

从产品 parser 导出的 9 个 normalized outbound 对象（h2 TLS／Reality、HTTP none／TLS／Reality、HTTPUpgrade none／TLS／Reality、QUIC TLS）均通过完整临时配置 `check-outbound`。实际 parser 对象链路复验：

- HTTP 明文：server/client check、TCP、UDP、远端域名和停止上游后的无回退均通过。
- HTTP+Reality、HTTPUpgrade+Reality、QUIC+TLS：上述 server/client check、TCP、UDP、远端域名与无回退均通过。

parser 对象和匹配的临时 Reality keypair 仅在 WSL `/tmp` 使用；native-lab helper 也只在 `/tmp` 临时副本中扩展支持这些对象，未改共享 scratch helper。以上链路仅证明 loopback 受控夹具，不代表公开上游可达。QUIC+Reality 沿用已有 native-lab 证据：内核 `check` 会接受，但运行时失败并报 `unsupported usage for reality`，所以产品 parser 必须拒绝该组合。
