# 0001: 服务端屏蔽回国流量与白名单防护路由机制

采用基于 `geosite-cn` + `geoip-cn` 规则集的静默丢弃（`type: "block"` outbound）方案，并在拦截规则前置放行已审计的海外基础设施白名单，同时一并启用私网 IP（`ip_is_private`）阻断以防护 SSRF。

## Context

海外 VPS 节点若向中国大陆域名/IP 回连，可能导致双向穿透风险、VPS 被定向扫描或封锁、以及不必要的长链路带宽消耗。同时，客户端由于本地污染或 CDN 解析可能误将 Google 连通性检测（Generate 204）、Apple/Microsoft 系统更新或 OCSP 证书校验目标送往节点，直接全部阻断会引发广泛客户端故障。

## Considered Options

- **动作选择**：`action: "reject"` vs `{type: "block"}`
  - 选择 `block`：静默丢弃，避免主动发送 RST/ICMP 响应导致服务器探测特征暴露。
- **规则集加载**：`local` 本地 .srs vs `remote` 远程规则集
  - 选择 `remote`：由 sing-box 自动下载与缓存更新，搭配本地缓存的白名单文件实现极简运维。
- **范围与开关**：按节点独立控制 vs 全局成套防护（合并私网阻断）
  - 选择全局成套防护：作为安全基线，开启时自动确保所有入站启用流量嗅探（sniffing），并同时堵死 SSRF 私网探测。
