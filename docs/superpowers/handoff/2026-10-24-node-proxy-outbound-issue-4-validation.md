# 节点代理出站 #4 验证记录

日期：2026-10-24
分支：`codex/issue-4-vless-base`

## 菜单与自动化测试

- `tests-node-proxy-outbound.sh`：通过，覆盖根目录 `core.sh` 与 `src/core.sh`。VLESS 用例检查 TCP/raw 默认映射、UUID／地址／端口、none/TLS/Reality、Vision、SNI／ALPN／uTLS、证书校验布尔别名、Reality 公钥和 short ID、packet encoding、百分号解码、未知参数拒绝、失败时保留原配置、名称展示、缓存复用、切回直连、SS↔VLESS 替换和非 Snell `mode` 兼容入口。
- 四项既有回归通过：`tests-node-name-label.sh`、`tests-snell-support.sh`、`tests-relay-support.sh`、`tests-log-limit.sh`。
- 在 WSL Ubuntu root 中，将所需脚本复制到一次性 `/tmp` 目录，只对副本去除 CR 字符后运行全部 `bash -n` 和上述测试。原仓库行尾未修改。
- `git diff --check`：通过。

## sing-box 1.14.0 实际内核验证

使用本票 `parse_proxy_uri vless` 的实际输出（`outbound_proxy_config_json`，不含 `{name,config}` 外壳、tag 或 detour）运行 native-lab。内核为官方 sing-box v1.14.0，linux/amd64、Go 1.26.7，构建 tags 含 `with_quic`、`with_utls`、`with_gvisor`，revision `0b8995879f29a9b98ee027bc17b75e101445b238`。

- TCP/none，包含显式 `packet_encoding: ""`：完整 client/server check、TCP、UDP、远端域名和停止上游后的 no-fallback 均通过。证据：`selftest-20261024T104744Z.json`。
- TCP/none + `packetaddr`：完整 check、TCP、UDP、远端域名和 no-fallback 均通过。证据：`selftest-20261024T104747Z.json`。
- TCP/TLS，默认校验证书：完整 check 和流量用例通过；自签证书默认连接被拒，显式跳过证书校验后连接通过。证据：`selftest-20261024T104751Z.json`。
- TCP/TLS，parser 输出包含 Firefox uTLS、ALPN、`xudp` 和显式 insecure：完整 check、TCP、UDP、远端域名和 no-fallback 均通过；证书默认拒绝／显式跳过通过。证据：`selftest-20261024T104756Z.json`。
- TCP/TLS + Vision：从实际 parser 输出生成对象后运行 `check-outbound`，完整临时配置检查通过。当前链路夹具的 `tcp-tls` 用例不模拟 VLESS flow，因此没有将此项记作流量互通验收。
- TCP/Reality + Vision：使用内核临时生成并匹配的 Reality keypair；完整 check、TCP、UDP、远端域名和 no-fallback 均通过。错误公钥仍被拒绝，即使链接设置了 insecure。证据：`selftest-20261024T104800Z.json`。

报告位置：`D:\ai\one-singbox\.scratch\node-proxy-outbound\native-lab\results\`。报告不保存 UUID、密钥、分享链接或完整出站对象；临时 keypair、证书和 parser JSON 均留在 WSL `/tmp` 并随验证脚本清理。

## 范围说明

- 当前 parser 只接受 VLESS TCP/raw；WS、gRPC、HTTP、HTTPUpgrade、QUIC 和其他未知连接参数明确拒绝，供后续协议任务扩展。
- 服务重启／恢复矩阵复用 #2 已验收结果；本票只增加 VLESS 解析与菜单分支，没有改 systemd/OpenRC 管理路径，因此未重跑服务矩阵。
- 受控链路只使用本机 loopback 上游；不代表公开上游可达，也不把配置已应用描述成上游连接正常。
