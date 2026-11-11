# Block CN Traffic and Whitelist Routing Design

**Status:** Approved design

**Target:** Add server-side blocking of traffic routed back to Mainland China with Google/Apple/MS infrastructure whitelist bypass and private IP SSRF protection in `one-singbox`.

## Goal

Provide a toggleable protection feature in one-singbox terminal management to block all traffic attempting to reach Mainland China IP addresses and domains from the VPS server node, avoiding dual-penetration risks, node IP blacklisting, and server resource abuse, while protecting VPS localhost/internal network from SSRF attacks and safeguarding essential foreign cloud infrastructure connectivity.

## Decisions Summary

1. **Menu & CLI Entry:**
   - Interactive entry in `system_tools_menu` ("系统设置").
   - Dynamic label: `屏蔽回国流量 (已启用)` / `屏蔽回国流量 (未启用)`.
   - Toggle behavior on selection without sub-dialogs.
   - CLI shortcut: `sb block-cn` (or `sing-box block-cn`).

2. **Blocking Mechanics:**
   - Outbound: Adds `{ "tag": "block", "type": "block" }` outbound for silent drops.
   - Rule-sets: Remote binary rule-sets `geosite-cn` and `geoip-cn` (`download_detour: "direct"`).
   - SSRF Protection: Adds `{ "ip_is_private": true, "outbound": "block" }` together under the same toggle.
   - Inbound Sniffing: Uses route action `{ "action": "sniff" }` for protocol sniffing in sing-box 1.13+. Automatically cleans and migrates legacy inbound sniffing fields (`sniff`, `sniff_override_destination`) from node configuration files.

3. **Whitelist Bypassing:**
   - Source: Audited whitelist JSONC from `https://raw.githubusercontent.com/ouones/quan/refs/heads/main/sing-box/cn-whitelist.jsonc`.
   - Download & Cache: Downloaded on first enable, cached locally at `/etc/sing-box/.cn-whitelist.json`. Re-downloaded when toggled from disabled to enabled.
   - Transformations: Strip comments, remove `inbound` constraint (applies globally), route to `direct`.

4. **Rule Evaluation Order (First-Match):**
   1. Route action sniffing (`action: "sniff"`)
   2. User-defined custom rules (`existing_rules`)
   3. Whitelist bypass rules (`domain` / `domain_suffix` -> `direct`)
   4. Private IP block (`ip_is_private: true` -> `block`)
   5. CN traffic block (`rule_set: ["geosite-cn", "geoip-cn"]` -> `block`)
   6. Managed node routes (`proxy_rules` + `direct_rules`)
   7. Default final (`final: "direct"`)

5. **State Persistence:**
   - Flag file: `/etc/sing-box/.block-cn-enabled`.
   - Automatic preservation during config rebuilds and node migrations.

6. **Repository Boundaries:**
   - Modifications must be reflected in both `src/core.sh` and root `core.sh`.
