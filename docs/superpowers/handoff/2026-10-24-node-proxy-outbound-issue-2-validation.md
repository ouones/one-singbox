# 节点代理出站 #2 验证记录

日期：2026-10-24
分支：`codex/issue-2-safe-apply`

## 自动化测试

- 在 WSL Ubuntu root 中，把 `core.sh`、`src/core.sh`、`src/dns.sh`、`src/help.sh` 和测试脚本复制到一次性目录，仅对副本去除 CR 字符后运行 `bash -n`。原工作区行尾未批量转换。
- `tests-node-proxy-outbound.sh`：通过。覆盖真实 `change <node>.json outbound` 入口、四种直连、`outbound-mode` 和非 Snell `mode` 兼容入口、SS2022 多密钥、IPv6/百分号解析、旧 SS 元数据迁移、损坏活跃缓存保留路由、多节点相同/不同上游、入站 tag、幂等、tag 冲突、检查/保存/重启/恢复失败以及公共配置原先缺失。
- 回归通过：`tests-node-name-label.sh`、`tests-snell-support.sh`、`tests-relay-support.sh`、`tests-log-limit.sh`。
- 红灯记录：菜单矩阵首次暴露受管直连路由被 broad direct 遮蔽；修复后路由位于保留的 `resolve`/`hijack-dns` 规则之后、broad direct 之前。代理路由仍置于所有既有路由之前。随后完整测试矩阵通过。

复跑时在 worktree 建临时副本，复制上述文件，执行 `find <临时目录> -type f -name '*.sh' -exec sed -i 's/\r$//' {} +`，再运行四项回归和 `bash tests-node-proxy-outbound.sh`。不要对仓库全树改行尾。

## 真实内核与 SS 流量

- 官方 sing-box `v1.14.0`，linux/amd64，Go 1.26.7，构建 tags 含 `with_quic`、`with_utls`、`with_gvisor`，revision `0b8995879f29a9b98ee027bc17b75e101445b238`。
- 使用本票 `parse_proxy_uri` 生成的 SS outbound，完整候选配置 `check -c <candidate> -C <nodes>` 通过；IPv4 与 IPv6 上游配置均通过真实内核检查。IPv6 字面地址不生成 `domain_resolver`。
- normalized SS 对象真实链路通过：TCP、UDP、远端域名到达受控上游、停止上游后不回退直连。结果：`D:\ai\one-singbox\.scratch\node-proxy-outbound\native-lab\results\selftest-20261024T102812Z.json`。
- 该链路的复跑输入应由本票 parser 生成，再传给 `native_lab.py selftest --kernel <v1.14.0> --case ss --outbound-json <临时 JSON>`；实验只改写 server/port 到本机回环，保留 parser 对象的 method、password 和其他字段。

## 服务级验收

- systemd：真实菜单、完整内核检查和 transient unit 的正常应用、首个重启失败后恢复成功、恢复重启失败均通过。结果：`D:\ai\one-singbox\.scratch\node-proxy-outbound\systemd-lab\results\systemd-lab-20261024T102205Z.md`。唯一临时 unit 已停止并清理。
- OpenRC：Alpine 3.24.3 / OpenRC 0.63.2，官方 sing-box 1.14.0 musl 构建。真实 `rc-service` 菜单应用、恢复成功、恢复失败均通过；配置文件逐字节恢复，服务状态符合预期。结果：`D:\ai\one-singbox\.scratch\node-proxy-outbound\openrc-lab\RESULTS.md` 与 `candidate-openrc-acceptance-results.txt`。测试只操作临时 rootfs/network namespace。
- 两项服务实验运行在最终 IPv6 专项修正之前；之后只调整 IPv6 字面地址校验及其 resolver 分类，没有改变保存、重启或恢复函数。当前快照已重跑完整 Bash 菜单矩阵及 v1.14.0 IPv4/IPv6 完整配置检查。

## 未测范围

- 菜单服务实验使用合成 SS URI，不联系公开/生产上游；受控本地 SS 流量实验验证了 parser 对象的实际 TCP/UDP/域名与断线行为。
- 本票不覆盖节点改名、端口/协议迁移、删除等复杂生命周期（#8），也不覆盖 VLESS 导入及后续扩展协议票。
