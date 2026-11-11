# one-singbox 术语

本项目对外文档使用的名称与术语。

## Language

**one-singbox**：
由 ouones 维护的 sing-box 安装与终端管理工具，提供交互式菜单和快捷命令，脚本名为 one-singbox。
_Avoid_：将项目称为 sing-box 内核，或使用容易被理解为 Web 后台的“管理面板”作为主要定位。

**sing-box 内核**：
由管理工具安装和管理的 sing-box 程序，与 one-singbox 管理脚本区分。

**sb**：
one-singbox 的快捷命令入口，也是 README 操作示例优先采用的命令名。安装脚本将 `/usr/local/bin/sb` 和 `/usr/local/bin/sing-box` 链接到同一管理脚本入口。

**屏蔽回国流量 (block-cn)**：
在 sing-box 服务端拦截中国大陆域名与 IP（基于 geosite-cn / geoip-cn 规则集）及私网 IP（防 SSRF）的安全路由特性。
_Avoid_：国内分流、回国直连、国内黑名单

**回国白名单 (cn-whitelist)**：
在服务端屏蔽回国流量前优先放行的海外基础设施域名清单，避免因公共 CDN 或解析误标记阻断正常连通性检测与证书/更新校验。
_Avoid_：节点白名单、用户白名单
