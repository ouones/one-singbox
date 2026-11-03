# one-singbox 使用说明

本页说明节点、出站、中转及日常维护的具体操作。首次安装见 [README](../README.md#教程)，完整命令与别名请运行 `sb help`。

- [节点与分享](#节点与分享)
- [协议与 TLS](#协议与-tls)
- [443 SNI 前置](#443-sni-前置)
- [Snell](#snell)
- [节点出站](#节点出站)
- [端口中转](#端口中转)
- [服务与更新](#服务与更新)
- [二维码与分享](#二维码与分享)
- [日志与容量限制](#日志与容量限制)

以下操作使用 root 用户执行。命令中的 `节点名`、`本地端口` 等是占位说明，请换成实际值；节点配置名以创建结果或菜单中显示的名称为准。

## 节点与分享

运行 `sb` 进入首页，选择“节点管理”后可添加、修改、查看或删除节点。安装时已自动创建一个 VLESS-REALITY 节点，可先选择“查看节点信息”获取它的信息。

```bash
# 选择协议并按提示创建节点
sb add

# 选择已有节点查看详情，无需先知道配置名
sb info
```

知道配置名后，可直接操作：

```bash
sb info 节点名
sb c 节点名
sb url 节点名
sb qr 节点名
```

`sb c` 展示节点可修改的项目，例如端口、密码、UUID、域名、节点名称、入口地址及出站方式；具体项目随协议变化。入口地址用于分享信息，节点出站决定流量如何发出，两者用途不同。

面板删除节点时会显示节点名和配置文件，并要求确认。命令行删除使用 `sb del 节点名`；批量删除使用 `sb ddel 节点名1 节点名2`。**这两个命令会立即删除配置，不会再次确认。**

分享链接需要客户端支持对应的协议和参数组合；详情提示 `allowInsecure` 时，部分客户端需要手动调整相关选项。创建成功或服务运行中均不等于客户端已经可以连接，应同时检查服务器端口、防火墙、云安全组及客户端配置。

## 协议与 TLS

当前协议菜单提供以下配置入口；菜单中的具体组合和当前内核的校验结果决定配置是否可用，不代表任意协议、传输与 TLS 都能自由组合。

| 类别 | 菜单提供的配置 |
| --- | --- |
| VLESS | REALITY、HTTP2-REALITY，以及 WS / H2 / HTTPUpgrade 的 TLS 配置 |
| TUIC / Trojan / Hysteria2 | 各自的节点配置；Trojan 另有 WS / H2 / HTTPUpgrade 的 TLS 配置 |
| AnyTLS | 需要 sing-box 内核 1.12.0+ |
| Shadowsocks | 支持菜单中的 AEAD 与 Shadowsocks 2022 加密方式 |
| VMess | TCP、HTTP、QUIC，以及 WS / H2 / HTTPUpgrade 的 TLS 配置 |
| Snell | v6 / v5，创建前检查内核版本为 1.14.0+ |
| SOCKS | SOCKS 节点配置 |

对需要域名并使用 Caddy 自动配置 TLS 的节点，先将域名解析到服务器，再确保验证和服务使用的端口可达。REALITY、脚本生成的证书和 Caddy 自动 TLS 是不同的配置路径，请按所选协议的提示操作。`sb no-auto-tls` 是关闭自动 TLS 配置的进阶入口，参数见 `sb help`。

## 443 SNI 前置

443 SNI 前置让多个普通 VLESS-REALITY 节点共用公网 TCP 443，并由 Nginx 按用户指定的 Reality SNI 转发到 sing-box 的本机回环后端。该模式默认关闭；它不包含 VLESS-HTTP2-REALITY。

one-singbox 只检测 Nginx 并维护 Reality 映射。你需要自行安装、部署和升级 Nginx，并准备可被服务管理器识别的本机 Nginx 服务及所需 stream / `ssl_preread` 能力。缺少能力或配置结构不兼容时，工具会报告原因，不会安装软件或猜测改写配置。

网站配置仍由你维护。工具不管理网站内容、证书、HTTP server、location、upstream 或 HTTP 反向代理；首次接入时只添加带标记的加载点，并创建或复用适用的 stream 入口。遇到无法可靠识别的配置时会拒绝写入。

### 查看、检查与启用

```bash
sb frontend status [--json]
sb frontend check [--json]
sb frontend enable [node-ref ...]
```

也可以在首页选择“443 SNI 前置”。`status` 查看模式和绑定状态；`check` 检查正在运行的 Nginx 实例、所需能力与配置入口，不启用模式。首次启用必须纳管所有现有公网 TCP 443 节点；在交互菜单中选择全部节点，或在命令行传入所有节点文件名。若没有要纳管的旧节点，可启用空模式。迁移节点及新建 443 节点都必须符合普通 VLESS-REALITY 约束，并提供精确域名 SNI；不支持通配 SNI 或 `sni auto`。同一入口内不能重复使用相同 SNI。

启用模式后，节点 SNI、发布地址、端口或删除等受支持的操作会同步更新 Reality 映射。查看和分享信息继续使用公网地址与 443，不显示内部回环地址或后端端口。

### 停用与恢复

```bash
sb frontend disable
sb frontend recover
```

停用前必须先删除或移出所有受管绑定。停用只清理仍能确认属于 one-singbox 的 Reality 映射和入口；不会停止或卸载 Nginx，也不会删除网站或其他用户分流配置。移除最后一个绑定不会自动停用空模式。

节点与映射变更会检查候选 sing-box 和完整 Nginx 配置，再应用并重载。Nginx reload 作用于整个实例，可能同时使你另外编辑但尚未加载的网站配置生效。变更期间可能短暂断连。失败时工具会尝试恢复受管文件和服务；如果命令提示存在未完成事务，先运行 `sb frontend recover`，并按命令给出的恢复状态处理。

经 Nginx 转发的 sing-box 连接来源是本机回环地址；one-singbox 不透传原客户端 IP。配置检查通过、服务运行或本机回环连接成功，都不代表公网 DNS、防火墙、安全组和外部客户端连通性已经验证。

更多实际验证结果及未验证范围见[443 SNI 前置验证与支持状态](nginx-reality-frontend-support.md)。

## Snell

```bash
sb add snell
```

默认创建 Snell v6，自动生成 PSK，并使用 `default` 运行模式。也可以按 `sb add snell [port] [psk] [version]` 指定端口、PSK 和版本；方括号表示可选位置参数，不要原样输入。

| 配置 | 规则 |
| --- | --- |
| 内核版本 | 脚本要求可识别的 sing-box 1.14.0 或更高正式版本，并由内核校验实际配置 |
| Snell v6 | PSK 长度为 12–255 字符；支持 `default`、`unshaped`、`unsafe-raw` 模式 |
| Snell v5 | 支持 `none`、`http` 混淆模式 |
| 分享 | 详情与 `sb url 节点名` 同时提供 `snell://` URI 和 Surge 代理配置；客户端需支持对应版本与参数 |
| 二维码 | Snell 不生成二维码，`sb qr` 对 Snell 会给出提示 |

可通过节点编辑菜单调整参数，也可使用：

```bash
sb psk 节点名 auto
sb snell-version 节点名 6
sb mode 节点名 default
```

v5 混淆使用 `sb obfs 节点名 http` 或 `sb obfs 节点名 none`。切换版本时，脚本会调整对应的运行或混淆字段；从 v5 切到 v6 时，过短的 PSK 会重新生成。修改后请重新获取分享信息并同步客户端。

## 节点出站

为本机代理节点选择流量发出的方式，入口为“节点管理”→“修改节点”→“更改节点出站方式”，或：

```bash
sb c 节点名 outbound
```

可选择 `IPv6 优先`、`IPv4 优先`、`仅 IPv4`、`仅 IPv6` 四种直连方式，或粘贴 Shadowsocks / VLESS 分享链接配置代理出站。这是对已有本机节点的出站设置，不会将链接导入成新的本机服务端节点。

### 分享链接兼容范围

SS 支持 SIP002 `ss://` 链接的 Base64 / Base64URL 或百分号编码凭据，兼容既有 SS2022 Base64 链接及多密钥密码；非空插件参数不支持。

VLESS 支持的传输及主要约束如下：

| 传输 | 主要条件 |
| --- | --- |
| TCP / raw | 可配置对应安全参数；Vision 只用于 TCP / raw |
| WebSocket | 支持 none / TLS / Reality，映射 path、Host 和 early data |
| gRPC | 支持 none / TLS / Reality，映射 serviceName；mode 仅接受缺省或 `gun` |
| HTTP / h2 | 支持对应的 none / TLS / Reality 组合；`h2` 必须使用 TLS / Reality，host 按列表解析 |
| HTTPUpgrade | 支持 none / TLS / Reality，host 为单值 |
| 原生 QUIC | 仅支持无额外加密的 sing-box 原生 TLS，不支持 QUIC Reality 或其他内核的额外 QUIC 加密 |

额外参数限制：

- gRPC 非空 `authority` 仅在可识别的 sing-box 1.14.0 构建中与默认值完全相同时接受。
- TLS 的 `ech` 支持 ECH CONFIGS PEM 或静态 ECHConfigList Base64；Base64 会包装为 PEM，空值启用 DNS 获取。
- `pcs` 用于固定整张证书的 SHA-256，接受逗号分隔的十六进制或 Base64 多值。需要 sing-box 1.15.0+；1.14.0 拒绝非空值。
- `vcn` 仅接受空值或与 SNI 相同的证书名。
- 非空 `spx` / `spiderX`、XHTTP、mKCP、VLESS Encryption、`mux` / `smux`、TCP `headerType=http` 伪装、未知连接参数及无法等价映射的组合会明确拒绝。

### 缓存、应用与恢复

- 选择同类型代理并直接回车，可复用最近一次缓存；切回直连会保留最近一次代理配置。
- 修改节点名称会保留关联；更改端口或协议会迁移代理缓存与路由；删除节点会清除关联。
- 出站摘要展示名称或地址与端口，不回显凭据。
- 修改先进行完整配置校验，再同步重启并确认服务运行，之后才提示“配置已应用”。应用失败时恢复相关配置并尝试恢复服务。
- **“配置已应用”不表示已检测上游连通性。** 代理故障时不会自动改走直连。

## 端口中转

端口中转使用 sing-box 原生 `direct` 入站，将本地监听端口的 TCP/UDP 流量转发到固定远端地址和端口；也可以从首页“TCP/UDP 端口中转”操作。

**中转无内置认证。** 创建前请通过系统防火墙、云安全组或网络 ACL 限制访问来源。

```bash
# 按提示填写本地端口、远端地址与远端端口
sb relay add

# 列出已有中转
sb relay list

# 查看指定中转
sb relay info 本地端口
```

完整新增语法为 `sb relay add [local-port] [remote-addr] [remote-port]`。交互输入本地端口时，直接回车可自动分配；目标地址可以是 IPv4、IPv6 或域名。默认同时转发 TCP 和 UDP，请对应配置网络访问规则。

中转不生成分享链接或二维码。面板删除中转时会显示监听端口并要求确认。命令行使用 `sb relay delete 本地端口` 会立即删除配置，不会再次确认；如果删除后的完整配置校验失败，会恢复中转配置。

## 服务与更新

```bash
sb status
sb start
sb stop
sb restart
sb update sh
sb update core
```

首页每次显示时会通过 systemd 或 OpenRC 查询服务状态，以绿色“运行中”或红色停止 / 启动失败状态展示；查询失败时显示红色“状态读取失败”。`sb status` 可单独查询。状态只反映服务管理器结果，不代表外网连通性。

`sb update sh` 更新管理脚本，`sb update core` 更新内核。安装 Caddy 后可使用 `sb update caddy` 更新 Caddy。版本信息可通过 `sb version` 查看；如需调用内核，使用 `sb bin`，例如 `sb bin version`。

`sb import` 是导入本机 xray / v2ray 脚本配置的入口，不是任意客户端配置导入器。修复、重装等进阶命令见 `sb help`。

## 二维码与分享

除 Snell 外，创建成功和查看支持分享链接的本机节点时，会在链接后自动显示终端二维码。原始分享 URI 始终保留，可直接复制导入。

| 操作或情况 | 行为 |
| --- | --- |
| 普通节点详情，终端二维码显示成功 | 显示二维码，不额外显示浏览器二维码页链接 |
| 终端空间不足、尺寸不可读、缺少 `qrencode` 或生成失败 | 保留原始 URI，并附浏览器二维码页链接 |
| `sb qr 节点名` | 尝试显示终端二维码，并始终显示浏览器二维码页链接 |
| `sb url 节点名` | 显示分享信息，不生成二维码 |
| Snell | 显示 URI 与 Surge 配置，不生成二维码 |

### 依赖安装与重试

新安装在脚本部署后、首次节点详情显示前，会自动尝试补齐 `qrencode`。补装失败不影响主体安装或节点创建，终端会给出当前系统的手动安装命令。

主动更新脚本也会尝试补齐：首页“更新软件”→“更新 one-singbox 脚本”，或以下任一命令：

```bash
sb update sh
sb U
sb update.sh
```

即使脚本已是最新，或指定脚本版本与当前版本相同，也可主动更新重试。二维码补装失败不影响脚本更新。

旧版本更新脚本文件后，首次进入首页也会尝试补齐；失败不阻断首页，后续普通首页不再重试，可手动安装或再次主动更新恢复。

## 日志与容量限制

日志占用上限默认为 **200 MB**。运行 `sb`，进入“系统工具”→“设置日志占用上限”，输入大于 0 的整数；留空保留当前值。设置重启后仍保留。

首页显示“日志占用：当前值 MB / 上限值 MB”，每次显示首页重新统计 `/var/log/sing-box/` 第一层非符号链接普通 `.log` 和 `.log.1` 文件的实际字节数。这里 1 MB = 1024 × 1024 字节，当前值保留两位小数；没有日志时显示 `0.00`，读取失败时提示“暂不可用”。可从“系统工具”→“设置日志占用上限”修改上限。

日志维护服务每 **10 秒**检查一次，超限后轮转并优先清理最旧记录，保留最近记录，同时留出一半容量供新日志写入。调低限制会立即检查；检查间隔内可能短暂超过上限。

轮转采用复制后截断的方式，无需重启 sing-box；复制与截断之间并发写入的少量记录可能丢失。

```bash
# 跟随查看日志，Ctrl+C 退出
sb log
```
