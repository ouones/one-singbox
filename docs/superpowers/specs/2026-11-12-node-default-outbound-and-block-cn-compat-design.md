# Spec: 节点默认出站与屏蔽回国配置解耦及兼容性演进

## Problem Statement

在 one-singbox 中，当用户为节点配置了前置代理出站（如 Shadowsocks 或 VLESS），同时在服务端开启了“屏蔽回国流量”功能时，流量路由存在泄露与逻辑冲突：

1. **白名单流量绕过代理直连泄露**：海外基础设施白名单（Google 连通性检测、Apple/Microsoft 更新、OCSP 证书验证）规则被硬编码指向直连（`outbound: "direct"`）。对于配置了代理出口的节点，白名单流量会脱离节点代理链路，强制从 VPS 本机直连泄露。
2. **出站变更与屏蔽功能冲突**：在开启“屏蔽回国流量”的前提下，直接将节点出站方式由直连切换为代理出站（或从代理出站切回直连），旧出站规则、白名单规则和兜底规则无法原子迁移，导致规则残留或流量走向错误。
3. **入站作用域缺失波及中转流量**：嗅探（`action: "sniff"`）与中国路由阻断规则缺乏精准入站限定，导致 TCP/UDP 端口中转（Relay）业务以及非代理入站的正常流量面临被误嗅探引入延迟或被误阻断的风险。
4. **特殊分流时序倒错**：在未开启屏蔽回国流量时，受管代理出站规则被错误排在用户自定义规则之前，导致用户配置的特殊分流（例如 YouTube/Netflix 走向指定出口）失效。
5. **内核规范弃用警告**：依赖已被 sing-box 1.14+ 弃用的 `download_detour` 字段及遗留的 `type: "block"` 出站，存在后续内核升级失效风险。

## Solution

1. **节点默认出站语义清晰化**：
   - 彻底解耦“节点默认出站”与“服务器本机直连”。
   - 所有新建节点与历史老节点统一以“IPv4 优先”（优先 IPv4，无 IPv4 则自动回落至 IPv6）作为默认出站基准，无需新增额外的系统出站概念。
   - 节点的普通外网流量以及白名单放行流量均严格送往该节点指定的默认出站（无论是直连还是 SS/VLESS 代理出站）。

2. **节点独立规则块（Per-node Rule Block）架构**：
   - 将嗅探（`action: "sniff"`）限定在受管代理节点的入站名单内，常态化生效，确保中转（Relay）不受影响且域名分流稳定。
   - 用户自定义特殊分流紧随嗅探之后，享有最高优先级。
   - 为每个受管代理节点构建自包含规则块：`[节点白名单 -> 节点默认出站]` → `[中国及私网流量 -> action: "reject"]` → `[节点剩余流量 -> 节点默认出站]`。
   - 各节点规则块彼此隔离，单节点修改出站或删除时局部原子重写，互不干扰。

3. **内核现代化与健壮保障**：
   - 全面演进至 sing-box 1.14+ 规范：使用顶层 `http_clients` 取代 `download_detour`；淘汰 legacy `type: "block"` 出站，全面使用 `action: "reject"`。
   - 严格的原子校验与回滚机制：出站修改后先生成候选配置并执行内核 check，校验失败自动回滚配置与元数据，保障服务可用性。

## User Stories

1. As a VPS node administrator, I want my Shadowsocks-outbound node to route Google and Apple whitelist traffic through the node's Shadowsocks proxy, so that my VPS server IP is never directly exposed to those destinations.
2. As a VPS node administrator, I want my VLESS-outbound node to route foreign infrastructure whitelist traffic through the node's VLESS proxy, so that the proxy chain remains completely unified.
3. As a VPS node administrator, I want to change a node's outbound mode from direct to Shadowsocks while "Block China Traffic" is enabled, so that all associated routing rules migrate seamlessly without requiring me to disable and re-enable protection.
4. As a VPS node administrator, I want to change a node's outbound mode from Shadowsocks to VLESS without disabling "Block China Traffic", so that the old Shadowsocks outbound and its associated routing rules are cleanly removed and replaced.
5. As a VPS node administrator, I want to change a node's outbound mode from Shadowsocks back to direct connection without disabling "Block China Traffic", so that the node smoothly returns to direct routing without leaving stale proxy outbounds.
6. As a VPS node administrator, I want newly created nodes to automatically have an explicit "IPv4-preferred" default outbound, so that their traffic routing is deterministic from the moment they are created.
7. As an existing one-singbox user updating the tool, I want my existing nodes that were created in older versions to be automatically recognized as "IPv4-preferred" outbound, so that the upgrade is completely frictionless and breaks no traffic.
8. As a VPS node administrator who uses TCP/UDP port relay (Relay), I want relay traffic destined for Chinese or internal IPs to not be blocked by the "Block China Traffic" feature, so that my port forwarding services remain fully functional.
9. As a VPS node administrator who uses TCP/UDP port relay (Relay), I want raw TCP relay connections to bypass proxy traffic sniffing, so that my relay connections suffer no protocol detection delay or timeout.
10. As an advanced user who writes custom routing rules (e.g., YouTube -> macau proxy), I want my custom rules to always take precedence over node default outbounds even when "Block China Traffic" is disabled, so that my specific website routing always works.
11. As an advanced user who writes custom domain routing rules, I want domain sniffing to always be active on managed proxy inbounds, so that my domain-based rules work reliably whether "Block China Traffic" is turned on or off.
12. As a VPS node administrator with multiple proxy nodes, I want changing the outbound mode of Node A to not alter, corrupt, or duplicate the routing rules of Node B, so that multi-node configurations remain robust and independent.
13. As a VPS node administrator with multiple proxy nodes, I want deleting a node to cleanly remove its outbound object and its per-node routing rules, without leaving orphaned rules or affecting remaining nodes.
14. As a VPS node administrator, I want an invalid outbound configuration change to be automatically rolled back if configuration validation fails, so that my running proxy service never crashes or enters a failed state due to bad input.
15. As a VPS node administrator, I want the generated sing-box configuration to adhere strictly to sing-box 1.14+ specifications without deprecation warnings, so that future core updates will not unexpectedly break my deployment.
16. As a terminal user, I want the CLI output after changing a node's outbound mode to be clean, concise, and focused on the final active state, so that I am not overwhelmed with low-level internal process logs.

## Implementation Decisions

1. **统一基准节点出站模型**：
   - 节点出站方式限定在既有的 6 种明确类型中（IPv4 优先、IPv6 优先、仅 IPv4、仅 IPv6、SS 出口、VLESS 出口），不新增抽象的系统默认出站。
   - 所有新建节点及未记录出站方式的历史老节点，统一赋予“IPv4 优先”（`V4优先`）作为默认出站模式。底层对应 sing-box 原生 `prefer_ipv4` 策略（优先 IPv4，无 IPv4 则自动回落至 IPv6）。

2. **节点独立规则块（Per-node Rule Block）架构**：
   - 放弃全局功能分层混合的规则拼接方式。
   - 规则评估流首部为受管节点入站范围限定的路由嗅探规则（`action: "sniff", inbound: [所有受管节点]`）。
   - 紧接着保留用户在公共配置中手写的自定义特殊分流规则（`existing_rules`），赋予其高于默认出站的优先权。
   - 后续为每个受管代理节点按序生成独立的自包含规则块：
     1. 白名单放行规则：限定该节点 `inbound`，目标指向该节点的受管出站 tag。
     2. 中国及私网拦截规则（仅在开启屏蔽回国时）：限定该节点 `inbound`，动作采用 `action: "reject"`。
     3. 节点兜底路由规则：限定该节点 `inbound`，目标指向该节点的受管出站 tag。
   - 规则末尾保留面向非受管流量的全局兜底（`final: "direct"`）。

3. **Relay 端口中转与非代理流量的入站隔离**：
   - 嗅探规则与拦截规则显式声明 `inbound` 字段，严格限定在受管代理节点的 inbound tag 列表中，严禁生成无 inbound 限制的全局阻断规则。
   - 端口中转（`relay-*.json`）与未受管流量直接穿透至全局 fallback，彻底杜绝误伤。

4. **sing-box 1.14+ 规范演进**：
   - 阻断动作完全切换为路由动作 `action: "reject"`，移除配置中冗余的 `{tag: "block", type: "block"}` 出站对象。
   - 规则集下载废弃 `download_detour: "direct"`。在主配置顶层受管注入 `http_clients: [{tag: "direct-client", detour: "direct"}]`，`geosite-cn` 与 `geoip-cn` 规则集通过 `http_client: "direct-client"` 引用。
   - 彻底清理遗留的 legacy inbound sniff 字段。

5. **出站切换生命周期与原子防护**：
   - 当用户修改节点出站模式时，在内存与临时工作区中生成候选公共配置。
   - 执行 `sing-box check` 全面语法与连通性预检。预检失败时立刻放弃应用，保持磁盘已有元数据与配置完好，向用户报告错误。
   - 预检通过后，原子移动元数据与公共配置文件，热重载服务并验证运行状态；若服务启动异常触发快速回滚机制。

## Testing Decisions

- **良好测试的判定标准**：
  - 测试聚焦于外部行为与可观测状态（命令执行退出码、终端状态提示、生成的 JSON 配置结构、服务启停状态），完全不耦合内部实现细节。
  - 核心断言应直接检查 `config.json` 中各个节点入站对应的出站 tag 指向、规则排列顺序、以及中转端口是否受波及。
- **被测模块与测试 Seam**：
  - **唯一测试 Seam**：CLI 与运行时配置生成边界（以 `apply_node_outbound_mode`、`block_cn_*` 及 `render_runtime_node_outbound_modes` 为核心交互点）。
  - 在隔离的沙箱环境（临时配置目录、mock sing-box 二进制）中运行完整端到端命令调用。
- **现有测试先例（Prior Art）**：
  - 参考 `tests-block-cn.sh` 中的白名单同步、规则注入与隔离断言模式。
  - 参考 `tests-node-proxy-outbound.sh` 中的节点出站切换、受管 tag 生成及回滚校验模式。

## Out of Scope

- **单节点独立“屏蔽回国”开关**：本次改动保持服务端全局“屏蔽回国”开关，不引入单节点维度的开关 UI。
- **Web UI 或图形化管理**：本项目仅专注于终端交互菜单与 CLI。
- **终端交互式自定义分流规则编辑器**：用户自定义分流（如指定域名走某出口）仍通过在 `config.json` 中手写维护，本特性负责确保其优先级不被覆盖。

## Further Notes

- 本次变更严格兼容当前及后续版本的 sing-box 内核（1.14.x 及更高版本）。
- 需确保同步更新仓库根目录的 `core.sh` 与 `src/core.sh`，保证发布的一致性。
