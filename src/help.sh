show_help() {
    case $1 in
    api | x25519 | tls | run | uuid | version)
        $is_core_bin help $1 ${@:2}
        ;;
    *)
        [[ $1 ]] && warn "未知选项 '$1'"
        msg "$is_script_name script $is_sh_ver by $author"
        msg "Usage: $is_core [options]... [args]... "
        msg
        help_info=(
            "基本:"
            "   v, version                                      显示当前版本"
            "   ip                                              返回当前主机的 IP"
            "   pbk                                             同等于 $is_core generate reality-keypair"
            "   get-port                                        返回一个可用的端口"
            "   ss2022                                          返回一个可用于 Shadowsocks 2022 的密码\n"
            "一般:"
            "   a, add [protocol] [args... | auto]              添加节点"
            "   add snell [port] [psk] [version]                添加 Snell (默认 v6, 支持 v5, 需要 sing-box >= 1.14.0)"
            "   c, change [name] [option] [args... | auto]      修改节点"
            "   d, del [name]                                   删除节点**"
            "   i, info [name]                                  查看节点信息"
            "   qr [name]                                       二维码信息"
            "   url [name]                                      URL 信息"
            "   Snell 提供 sing-box URI 与 Surge 配置双格式导出 (不支持二维码)"
            "   log                                             查看日志"
            "节点出站:"
            "   为已有节点选择直连或代理出站；不会导入新节点。"
            "   支持 IPv4/IPv6 直连、Shadowsocks 和 VLESS。"
            "   兼容范围与参数限制见: https://github.com/ouones/one-singbox/blob/main/docs/usage.md#节点出站"
            "   配置应用成功表示服务已重启，不代表代理上游连通性已测试。\n"
            # "   logerr                                          查看错误日志\n"
            "更改:"
            # "   dp, dynamicport [name] [start | auto] [end]     更改动态端口"
            "   full [name] [...]                               更改多个参数"
            "   id [name] [uuid | auto]                         更改 UUID"
            "   host [name] [domain]                            更改域名"
            "   port [name] [port | auto]                       更改端口"
            "   path [name] [path | auto]                       更改路径"
            "   passwd [name] [password | auto]                 更改密码"
            "   key [name] [Private key | auto] [Public key]    更改密钥"
            # "   type [name] [type | auto]                       更改伪装类型"
            "   method [name] [method | auto]                   更改加密方式"
            "   sni [name] [ip | domain]                        更改 SNI 域名"
            # "   seed [name] [seed | auto]                       更改 mKCP seed"
            "   new [name] [...]                                更改协议"
            "   web [name] [domain]                             更改反向代理目标域名"
            "   psk [name] [psk | auto]                         更改 Snell PSK"
            "   snell-version [name] [6 | 5 | auto]             更改 Snell 版本"
            "   mode [name] [default | unshaped | unsafe-raw | auto] 更改 Snell 运行模式 (v6)"
            "   obfs [name] [none | http | auto]                更改 Snell 混淆模式 (v5)\n"
            "进阶:"
            "   dns [...]                                       设置 DNS"
            "   dd, ddel [name...]                              删除多个配置**"
            "   fix [name]                                      修复一个配置"
            "   fix-all                                         修复全部配置"
            "   fix-caddyfile                                   修复 Caddyfile"
            "   fix-config.json                                 修复 config.json"
            "   import                                          导入 xray/v2ray 脚本配置\n"
            "中转:"
            "   relay add [local-port] [remote-addr] [remote-port]   添加中转 (sing-box 原生 direct, 支持 TCP/UDP)"
            "   relay list                                           中转列表"
            "   relay info [local-port]                              查看中转详情"
            "   relay delete [local-port]                            删除中转"
            "   也可从首页“TCP/UDP 端口中转”菜单操作"
            "   中转无内置认证，请务必使用防火墙或网络 ACL 限制来源"
            "   命令行 relay delete 指定端口后会立即删除；面板操作会先确认"
            "   中转不生成分享链接或二维码\n"
            "管理:"
            "   un, uninstall                                   卸载"
            "   u, update [core | sh | caddy] [ver]             更新"
            "   U, update.sh                                    更新脚本"
            "   s, status                                       运行状态"
            "   start, stop, restart [caddy]                    启动, 停止, 重启"
            "   reinstall                                       重装脚本\n"
            "测试:"
            # "   client, genc [name]                             显示用于客户端 JSON, 仅供参考"
            "   debug [name]                                    显示一些 debug 信息, 仅供参考"
            "   gen [...]                                       同等于 add, 但只显示 JSON 内容, 不创建文件, 测试使用"
            "   no-auto-tls [...]                               同等于 add, 但禁止自动配置 TLS, 可用于 *TLS 相关协议"
            # "   xapi [...]                                      同等于 $is_core api, 但 API 后端使用当前运行的 $is_core_name 服务\n"
            "其他:"
            "   bbr                                             启用 BBR, 如果支持"
            "   bin [...]                                       运行 $is_core_name 命令, 例如: $is_core bin help"
            "   [...] [...]                                     兼容绝大多数的 $is_core_name 命令, 例如: $is_core_name generate uuid"
            "   h, help                                         显示此帮助界面\n"
        )
        for v in "${help_info[@]}"; do
            msg "$v"
        done
        msg "命令行 del 和 ddel 会立即删除节点，无需再次确认；从交互菜单删除时会先确认。"
        msg "问题反馈: $(msg_ul https://github.com/${is_sh_repo}/issues)"
        ;;

    esac
}

about() {
    ####### 要点13脸吗只会改我链接的小人 #######
    unset c n m s b
    msg
    msg "one-singbox 脚本版本: $is_sh_ver"
    msg "sing-box 内核版本: $is_core_ver"
    [[ $is_caddy ]] && msg "Caddy 版本: $is_caddy_ver"
    msg "项目源码: $(msg_ul https://github.com/${is_sh_repo})"
    msg "问题反馈: $(msg_ul https://github.com/${is_sh_repo}/issues)"
    msg "sing-box 文档: $(msg_ul https://sing-box.sagernet.org/)"
    msg "sing-box 内核源码: $(msg_ul https://github.com/${is_core_repo})"
    msg
    ####### 要点13脸吗只会改我链接的小人 #######
}
