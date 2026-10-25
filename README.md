# 介绍

最好用的 sing-box 一键安装脚本 & 管理脚本，支持主流代理协议节点搭建与原生高性能端口中转

# 特点

- 快速安装
- 无敌好用
- 零学习成本
- 自动化 TLS
- 简化所有流程
- 兼容 sing-box 命令
- 强大的快捷参数
- 支持所有常用协议
- 一键添加 VLESS-REALITY (默认)
- 一键添加 TUIC
- 一键添加 Trojan
- 一键添加 Hysteria2
- 一键添加 AnyTLS
- 一键添加 Snell v6 (默认, PSK 需 12-255 位, 支持 default/unshaped/unsafe-raw 运行模式, 向后兼容 v5, 支持双格式导出 sing-box URI 链接与 Surge 代理配置)
- 一键添加端口中转 (原生 direct 极速转发, 支持 TCP/UDP 双协议, 回车自动分配端口)
- 支持交互式主菜单与快捷命令行双模式管理 (直接运行 sing-box 即可操作)
- 一键添加 Shadowsocks 2022
- 一键添加 VMess-(TCP/HTTP/QUIC)
- 一键添加 VMess-(WS/H2/HTTPUpgrade)-TLS
- 一键添加 VLESS-(WS/H2/HTTPUpgrade)-TLS
- 一键添加 Trojan-(WS/H2/HTTPUpgrade)-TLS
- 一键启用 BBR
- 一键更改伪装网站
- 一键更改 (端口/UUID/密码/域名/路径/加密方式/SNI/PSK/运行模式/混淆等...)
- 还有更多...

# 设计理念

设计理念为：**高效率，超快速，极易用**

脚本基于作者的自身使用需求，以 **多配置同时运行** 为核心设计

并且专门优化了，添加、更改、查看、删除、这四项常用功能

你只需要一条命令即可完成 添加、更改、查看、删除、等操作

例如，添加一个配置仅需不到 1 秒！瞬间完成添加！其他操作亦是如此！

脚本的参数非常高效率并且超级易用，请掌握参数的使用

# 一键安装

```bash
bash <(wget -qO- -o- https://github.com/ouones/one-singbox/raw/main/install.sh)
```

# 文档

安装及使用：https://233boy.com/sing-box/sing-box-script/

# 帮助

日志大小限制：运行 `sing-box`，进入「9 其他」→「6 日志大小限制」。默认 200 MB，可输入正整数修改，回车保留当前值；设置在重启后保留。限制包括 `/var/log/sing-box/` 中的 `.log` 和轮转生成的 `.log.1` 文件总大小（1 MB = 1024 × 1024 字节）。

日志维护服务每 10 秒检查一次，超限后轮转并优先清理最旧记录，保留最近记录，同时留出一半容量供新日志写入；调低限制会立即检查。检查间隔内可能短暂超过上限。轮转采用复制后截断的方式，无需重启 sing-box，但复制与截断之间并发写入的少量记录可能丢失。

节点出站方式：运行 `sing-box c <节点配置名> outbound`，或在节点编辑菜单中选择“更改出站方式”。支持四种 IPv4／IPv6 直连方式、SS SIP002 `ss://` 分享链接（Base64／Base64URL 或百分号编码凭据，兼容既有 SS2022 Base64 链接及多密钥密码）和 VLESS TCP/raw、WebSocket、gRPC、HTTP/h2、HTTPUpgrade 与原生 QUIC 分享链接；WebSocket、gRPC、HTTP、HTTPUpgrade 支持 none/TLS/Reality。WebSocket 映射 path、Host 和 early data；gRPC 映射 serviceName，仅接受缺省或 `gun` 模式，非空 authority 仅在可识别的 sing-box 1.14.0 构建中与默认值完全相同时接受。`h2` 需要 TLS/Reality；QUIC 仅支持无额外加密的 sing-box 原生 TLS，不兼容其他内核的额外 QUIC 加密或 Reality 组合。HTTP host 按列表解析，HTTPUpgrade host 为单值。VLESS TLS 支持 `ech` 的 ECH CONFIGS PEM／静态 ECHConfigList Base64（空值启用 DNS 获取），Base64 会包装成 PEM；`pcs` 固定整张证书 SHA-256，接受逗号分隔的十六进制或 Base64 多值，需要 sing-box 1.15.0+，1.14.0 拒绝非空值；`vcn` 仅接受空值或与 SNI 相同的证书名。Vision 只用于 TCP/raw。SS 非空插件、非空 `spx`／`spiderX`、XHTTP、mKCP、VLESS Encryption、`mux`／`smux`、TCP `headerType=http` 伪装、未知连接参数及无法等价映射的组合会明确拒绝。选择同类型代理并直接回车可复用缓存；切回直连保留最近一次代理配置。修改节点名称会保留关联，端口或协议变更会迁移代理缓存与路由，删除节点会清除关联。展示名称或地址与端口，不回显凭据。配置会先完整校验，再同步重启并确认服务运行后才提示“配置已应用”；应用失败会恢复相关配置并尝试恢复服务。该状态不表示上游连通性已检测，代理故障时不会自动改走直连。

使用：`sing-box help`

```
sing-box script v1.0 by 233boy
Usage: sing-box [options]... [args]...

基本:
   v, version                                      显示当前版本
   ip                                              返回当前主机的 IP
   pbk                                             同等于 sing-box generate reality-keypair
   get-port                                        返回一个可用的端口
   ss2022                                          返回一个可用于 Shadowsocks 2022 的密码

一般:
   a, add [protocol] [args... | auto]              添加配置
   add snell [port] [psk] [version]                添加 Snell (默认 v6, 支持 v5, 需要 sing-box >= 1.14.0)
   c, change [name] [option] [args... | auto]      更改配置
   d, del [name]                                   删除配置**
   i, info [name]                                  查看配置
   qr [name]                                       二维码信息
   url [name]                                      URL 信息
   Snell 提供 sing-box URI 与 Surge 配置双格式导出 (不支持二维码)
   log                                             查看日志
更改:
   full [name] [...]                               更改多个参数
   id [name] [uuid | auto]                         更改 UUID
   host [name] [domain]                            更改域名
   port [name] [port | auto]                       更改端口
   path [name] [path | auto]                       更改路径
   passwd [name] [password | auto]                 更改密码
   key [name] [Private key | auto] [Public key]    更改密钥
   method [name] [method | auto]                   更改加密方式
   sni [name] [ ip | domain]                       更改 serverName
   new [name] [...]                                更改协议
   web [name] [domain]                             更改伪装网站
   psk [name] [psk | auto]                         更改 Snell PSK
   snell-version [name] [6 | 5 | auto]             更改 Snell 版本
   mode [name] [default | unshaped | unsafe-raw | auto] 更改 Snell 运行模式 (v6)
   obfs [name] [none | http | auto]                更改 Snell 混淆模式 (v5)

进阶:
   dns [...]                                       设置 DNS
   dd, ddel [name...]                              删除多个配置**
   fix [name]                                      修复一个配置
   fix-all                                         修复全部配置
   fix-caddyfile                                   修复 Caddyfile
   fix-config.json                                 修复 config.json
   import                                          导入 sing-box/v2ray 脚本配置

中转:
   relay add [local-port] [remote-addr] [remote-port]   添加中转 (sing-box 原生 direct, 支持 TCP/UDP)
   relay list                                           中转列表
   relay info [local-port]                              查看中转详情
   relay delete [local-port]                            删除中转
   中转管理亦可通过主菜单交互操作
   中转无内置认证，请务必使用防火墙或网络 ACL 限制来源
   中转不生成分享链接或二维码

管理:
   un, uninstall                                   卸载
   u, update [core | sh | caddy] [ver]             更新
   U, update.sh                                    更新脚本
   s, status                                       运行状态
   start, stop, restart [caddy]                    启动, 停止, 重启
   t, test                                         测试运行
   reinstall                                       重装脚本

测试:
   debug [name]                                    显示一些 debug 信息, 仅供参考
   gen [...]                                       同等于 add, 但只显示 JSON 内容, 不创建文件, 测试使用
   no-auto-tls [...]                               同等于 add, 但禁止自动配置 TLS, 可用于 *TLS 相关协议
其他:
   bbr                                             启用 BBR, 如果支持
   bin [...]                                       运行 sing-box 命令, 例如: sing-box bin help
   [...] [...]                                     兼容绝大多数的 sing-box 命令, 例如: sing-box generate uuid
   h, help                                         显示此帮助界面

谨慎使用 del, ddel, 此选项会直接删除配置; 无需确认
反馈问题) https://github.com/ouones/one-singbox/issues
文档(doc) https://233boy.com/sing-box/sing-box-script/
```
