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
在服务端屏蔽回国流量前优先放行的海外基础设施域名清单，避免因公共 CDN 或解析误标记阻断正常连通性检测与证书/更新校验。白名单放行流量遵循各节点的默认出站方式，而非强制本机直连。
_Avoid_：节点白名单、用户白名单

**节点默认出站 (node-default-outbound)**：
每个节点承载普通外网流量以及白名单放行流量的基准出站方式。默认采用 IPv4 优先（无 IPv4 时自动使用 IPv6），用户亦可显式调整为 IPv6 优先、仅 IPv4/IPv6 或代理出站（SS/VLESS）。
_Avoid_：兜底路由、全局出站、系统默认直连

**节点独立规则块 (per-node-rule-block)**：
在 sing-box 路由规则中，为单个代理节点构建的自包含路由逻辑闭环，按序包含：该节点的白名单放行、该节点的中国及私网流量阻断、以及该节点的默认出站兜底。各节点规则块彼此隔离，修改或删除时互不影响。
_Avoid_：全局分层规则、混合路由表
