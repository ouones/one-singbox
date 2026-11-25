#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
cleanup() {
    rm -rf "$workdir"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1"
    exit 1
}

run_case() {
    CORE_FILE="$repo_root/src/core.sh" bash <<'CASE'
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $1"
    exit 1
}

case_dir=$(mktemp -d)
cleanup() {
    rm -rf "$case_dir"
}
trap cleanup EXIT

source <(sed '/EUID != 0/d' "$CORE_FILE")

is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="/bin/true"
is_core_ver=1.14.0
is_dont_show_info=1
is_no_manage_msg=1
export ip=203.0.113.10 is_dont_get_ip=1

mkdir -p "$is_core_dir" "$is_conf_dir/.quan-meta"

real_jq=$(type -P jq)
[[ $real_jq ]] || fail "jq binary not found"
jq_wrap_dir="$case_dir/jq-wrap"
mkdir -p "$jq_wrap_dir"
jq_count_file="$case_dir/jq.calls"
cat >"$jq_wrap_dir/jq" <<JQWRAP
#!/usr/bin/env bash
echo 1 >>"$jq_count_file"
exec "$real_jq" "\$@"
JQWRAP
chmod +x "$jq_wrap_dir/jq"

# 1. Mixed multi-node semantic equivalence (block-cn on & off, whitelist array, custom rules, relay isolation, override_meta)
: >"$is_core_dir/.block-cn-enabled"
cat >"$is_core_dir/.cn-whitelist.json" <<'EOF'
[
  {
    "action": "route",
    "outbound": "direct",
    "domain": ["connectivitycheck.gstatic.com"]
  },
  {
    "action": "route",
    "outbound": "direct",
    "domain_suffix": ["download.windowsupdate.com"]
  }
]
EOF

cat >"$is_config_json" <<'EOF'
{
  "dns": {},
  "http_clients": [
    {"tag": "custom-client", "detour": "direct"},
    {"tag": "direct-client"}
  ],
  "route": {
    "default_domain_resolver": {"server": "custom-dns"},
    "final": "custom-final",
    "rule_set": [
      {"tag": "custom-rules", "type": "remote", "format": "binary", "url": "https://example.com/custom.srs"}
    ],
    "rules": [
      {"domain_suffix": ["youtube.com"], "action": "route", "outbound": "special-out"},
      {"inbound": ["node-direct.json", "unmanaged-in"], "action": "route", "outbound": "direct"},
      {"inbound": ["node-vless.json"], "domain": ["after-fallback.example"], "action": "route", "outbound": "direct"},
      {"action": "route", "outbound": "direct"}
    ]
  },
  "outbounds": [
    {"tag": "direct", "type": "direct"},
    {"tag": "special-out", "type": "direct"},
    {"tag": "block", "type": "block"}
  ]
}
EOF

# Direct V6优先
cat >"$is_conf_dir/node-direct.json" <<'EOF'
{"inbounds":[{"tag":"node-direct.json","type":"shadowsocks","listen":"::","listen_port":31001,"method":"aes-128-gcm","password":"p1"}]}
EOF
jq -n '{outbound_mode:"V6优先"}' >"$is_conf_dir/.quan-meta/node-direct.json.meta.json"

# Legacy node without metadata (must auto-initialize to V4优先)
cat >"$is_conf_dir/node-legacy.json" <<'EOF'
{"inbounds":[{"tag":"node-legacy.json","type":"shadowsocks","listen":"::","listen_port":31002,"method":"aes-128-gcm","password":"p2"}]}
EOF

# Legacy SS metadata with multi-inbound tags and IPv4 server (no domain_resolver added)
cat >"$is_conf_dir/node-ss-legacy.json" <<'EOF'
{"inbounds":[{"tag":"ss-in-a","type":"shadowsocks"},{"tag":"ss-in-b","type":"shadowsocks"}]}
EOF
jq -n '{outbound_mode:"SS 出站",outbound_ss_server:"198.51.100.10",outbound_ss_port:"8388",outbound_ss_method:"aes-128-gcm",outbound_ss_password:"secret",outbound_ss_name:"LegacySS"}' >"$is_conf_dir/.quan-meta/node-ss-legacy.json.meta.json"

# VLESS node with domain server (must receive domain_resolver:{server:"custom-dns"})
cat >"$is_conf_dir/node-vless.json" <<'EOF'
{"inbounds":[{"tag":"node-vless.json","type":"vless","listen":"::","listen_port":31004,"users":[{"uuid":"11111111-1111-4111-8111-111111111111"}]}]}
EOF
jq -n '{outbound_mode:"VLESS 出站",outbound_proxy:{name:"VL",config:{type:"vless",server:"up.example.com",server_port:443,uuid:"11111111-1111-4111-8111-111111111111"}}}' >"$is_conf_dir/.quan-meta/node-vless.json.meta.json"

# Empty-inbound node without outbound_mode (must be ignored cleanly)
cat >"$is_conf_dir/node-empty-ignored.json" <<'EOF'
{"inbounds":[]}
EOF

# Relay and dynamic-port-link (must be excluded)
cat >"$is_conf_dir/relay-20001.json" <<'EOF'
{"inbounds":[{"tag":"relay-20001.json","type":"direct","listen":"::","listen_port":20001,"override_address":"198.51.100.99","override_port":20001}]}
EOF
cat >"$is_conf_dir/dynamic-port-12345-link.json" <<'EOF'
{"inbounds":[{"tag":"dynamic-port-12345-link.json","type":"vmess"}]}
EOF

# Override meta test
override_meta="$case_dir/override.meta.json"
jq -n '{outbound_mode:"仅V6"}' >"$override_meta"
render_runtime_node_outbound_modes "$is_config_json" "$case_dir/override-out.json" "node-legacy.json" "$override_meta" "$is_conf_dir" || fail "override render failed: $runtime_sync_error"
jq -e '.route.rules | any(.inbound == ["node-legacy.json"] and .outbound == "direct_v6_only")' "$case_dir/override-out.json" >/dev/null || fail "override_meta must switch node-legacy to direct_v6_only"

# Full sync with block-cn enabled
sync_runtime_node_outbound_modes "$is_config_json" "$is_config_json" "$is_conf_dir" 0 || fail "sync failed: $runtime_sync_error"

jq -e '.outbound_mode == "V4优先"' "$is_conf_dir/.quan-meta/node-legacy.json.meta.json" >/dev/null || fail "legacy node metadata must auto-initialize to V4优先"
jq -e '.route.final == "custom-final" and .route.default_domain_resolver == "custom-dns"' "$is_config_json" >/dev/null || fail "route.final and default_domain_resolver must be preserved/normalized"
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "legacy block outbound must be removed"
jq -e '.outbounds | any(.tag == "managed_node_ss_node-ss-legacy_json" and .server == "198.51.100.10" and (.domain_resolver | not))' "$is_config_json" >/dev/null || fail "IP-based SS outbound should not inject domain_resolver"
jq -e '.outbounds | any(.tag == "managed_node_vless_node-vless_json" and .server == "up.example.com" and .domain_resolver.server == "custom-dns")' "$is_config_json" >/dev/null || fail "domain-based VLESS outbound must inject domain_resolver"
jq -e '.http_clients | any(.tag == "custom-client") and any(.tag == "direct-client")' "$is_config_json" >/dev/null || fail "custom and managed http_clients must coexist"
jq -e '.route.rule_set | any(.tag == "custom-rules") and any(.tag == "geosite-cn") and any(.tag == "geoip-cn")' "$is_config_json" >/dev/null || fail "custom and managed rule_sets must coexist"
jq -e '([.route.rules[0].inbound[]] | sort) == ["node-direct.json","node-legacy.json","node-vless.json","ss-in-a","ss-in-b"]' "$is_config_json" >/dev/null || fail "sniff rule must include all managed inbound tags only"
jq -e '.route.rules | any(.inbound // [] | any(. == "relay-20001.json" or . == "dynamic-port-12345-link.json")) | not' "$is_config_json" >/dev/null || fail "relay and dynamic-port-link must never appear in route.rules"

# Verify per-node block ordering for SS node (2 whitelist -> private reject -> cn reject -> default route)
jq -e '
    ([.route.rules[] | .outbound == "special-out"] | index(true)) as $custom1
    | ([.route.rules[] | .domain == ["after-fallback.example"]] | index(true)) as $custom2
    | ([.route.rules[] | .inbound == ["ss-in-a","ss-in-b"] and .domain == ["connectivitycheck.gstatic.com"] and .outbound == "managed_node_ss_node-ss-legacy_json"] | index(true)) as $wl1
    | ([.route.rules[] | .inbound == ["ss-in-a","ss-in-b"] and .domain_suffix == ["download.windowsupdate.com"] and .outbound == "managed_node_ss_node-ss-legacy_json"] | index(true)) as $wl2
    | ([.route.rules[] | .inbound == ["ss-in-a","ss-in-b"] and .ip_is_private == true and .action == "reject"] | index(true)) as $priv
    | ([.route.rules[] | .inbound == ["ss-in-a","ss-in-b"] and .rule_set == ["geosite-cn","geoip-cn"] and .action == "reject"] | index(true)) as $cn
    | ([.route.rules[] | .inbound == ["ss-in-a","ss-in-b"] and .outbound == "managed_node_ss_node-ss-legacy_json" and .domain == null and .domain_suffix == null and .ip_is_private == null and .rule_set == null] | index(true)) as $def
    | ([.route.rules[] | .inbound == ["node-direct.json","unmanaged-in"] and .outbound == "direct"] | index(true)) as $fb1
    | ([.route.rules[] | .inbound == null and .outbound == "direct"] | index(true)) as $fb2
    | ($custom1 < $custom2) and ($custom2 < $wl1) and ($wl1 < $wl2) and ($wl2 < $priv) and ($priv < $cn) and ($cn < $def) and ($def < $fb1) and ($fb1 < $fb2)
' "$is_config_json" >/dev/null || fail "per-node rule block ordering violated: $(jq -c '.route.rules' "$is_config_json")"

# Idempotency check
cp "$is_config_json" "$case_dir/config.synced"
sync_runtime_node_outbound_modes "$is_config_json" "$is_config_json" "$is_conf_dir" 0 || fail "idempotent re-sync failed"
cmp -s "$case_dir/config.synced" "$is_config_json" || fail "repeated sync must be idempotent"

# Disable block-cn and verify cleanup while preserving custom rules and sniffing
rm -f "$is_core_dir/.block-cn-enabled"
sync_runtime_node_outbound_modes "$is_config_json" "$is_config_json" "$is_conf_dir" 0 || fail "disable sync failed"
jq -e '.route.rules | any(.action == "reject" or (.domain // [] | any(. == "connectivitycheck.gstatic.com"))) | not' "$is_config_json" >/dev/null || fail "block-cn rules must be stripped when disabled"
jq -e '.route.rules | any(.action == "sniff")' "$is_config_json" >/dev/null || fail "always-on sniffing must remain when block-cn disabled"
jq -e '.http_clients | any(.tag == "direct-client") | not' "$is_config_json" >/dev/null || fail "managed direct-client must be removed when disabled"
jq -e '.http_clients | any(.tag == "custom-client")' "$is_config_json" >/dev/null || fail "custom http_client must remain when disabled"

# 2. Edge errors must fail accurately and never overwrite output
err_dir="$case_dir/err-conf"
mkdir -p "$err_dir/.quan-meta"
cp "$is_config_json" "$case_dir/config.err-before"
output_target="$case_dir/err-output.json"
cp "$is_config_json" "$output_target"

# 2a. Missing source config
if render_runtime_node_outbound_modes "$case_dir/missing.json" "$output_target" "" "" "$err_dir"; then
    fail "missing source_config must fail"
fi
[[ $runtime_sync_error == *"不存在"* ]] || fail "unexpected error for missing source: $runtime_sync_error"

# 2b. Invalid source config
printf '{broken' >"$case_dir/bad-source.json"
if render_runtime_node_outbound_modes "$case_dir/bad-source.json" "$output_target" "" "" "$err_dir"; then
    fail "invalid source_config must fail"
fi
[[ $runtime_sync_error == *"公共配置格式无效"* ]] || fail "unexpected error for invalid source: $runtime_sync_error"

# 2c. Invalid node JSON
printf '{broken' >"$err_dir/bad-node.json"
if render_runtime_node_outbound_modes "$is_config_json" "$output_target" "" "" "$err_dir"; then
    fail "invalid node json must fail"
fi
[[ $runtime_sync_error == *"无法读取节点入站 tag: bad-node.json"* ]] || fail "unexpected error for invalid node json: $runtime_sync_error"
cmp -s "$case_dir/config.err-before" "$output_target" || fail "error must not overwrite output"
rm -f "$err_dir/bad-node.json"

# 2d. Non-object metadata JSON
printf '{"inbounds":[{"tag":"n1.json","type":"shadowsocks"}]}\n' >"$err_dir/n1.json"
printf '[]\n' >"$err_dir/.quan-meta/n1.json.meta.json"
if render_runtime_node_outbound_modes "$is_config_json" "$output_target" "" "" "$err_dir"; then
    fail "non-object metadata must fail"
fi
[[ $runtime_sync_error == *"节点元数据格式无效: n1.json"* ]] || fail "unexpected error for non-object metadata: $runtime_sync_error"
cmp -s "$case_dir/config.err-before" "$output_target" || fail "metadata error must not overwrite output"

# 2e. Empty inbound tags with explicit outbound_mode
printf '{"inbounds":[]}\n' >"$err_dir/n1.json"
printf '{"outbound_mode":"V4优先"}\n' >"$err_dir/.quan-meta/n1.json.meta.json"
if render_runtime_node_outbound_modes "$is_config_json" "$output_target" "" "" "$err_dir"; then
    fail "empty inbound tags with outbound_mode must fail"
fi
[[ $runtime_sync_error == *"节点没有可路由的入站 tag: n1.json"* ]] || fail "unexpected error for empty inbound tags: $runtime_sync_error"

# 2f. Invalid proxy config
printf '{"inbounds":[{"tag":"n1.json","type":"shadowsocks"}]}\n' >"$err_dir/n1.json"
printf '{"outbound_mode":"VLESS 出站","outbound_proxy":{"name":"x","config":{"type":"vless","server":"1.2.3.4","server_port":443,"uuid":""}}}\n' >"$err_dir/.quan-meta/n1.json.meta.json"
if render_runtime_node_outbound_modes "$is_config_json" "$output_target" "" "" "$err_dir"; then
    fail "invalid proxy config must fail"
fi
[[ $runtime_sync_error == *"节点代理配置无效: n1.json"* ]] || fail "unexpected error for invalid proxy config: $runtime_sync_error"

# 2g. Protocol mismatch
printf '{"outbound_mode":"SS 出站","outbound_proxy":{"name":"x","config":{"type":"vless","server":"1.2.3.4","server_port":443,"uuid":"11111111-1111-4111-8111-111111111111"}}}\n' >"$err_dir/.quan-meta/n1.json.meta.json"
if render_runtime_node_outbound_modes "$is_config_json" "$output_target" "" "" "$err_dir"; then
    fail "protocol mismatch must fail"
fi
[[ $runtime_sync_error == *"节点代理协议与出站方式不一致: n1.json"* ]] || fail "unexpected error for protocol mismatch: $runtime_sync_error"

# 2h. Tag collision
rm -f "$err_dir/n1.json" "$err_dir/.quan-meta/n1.json.meta.json"
for cfg in node@x.json node_x.json; do
    printf '{"inbounds":[{"tag":"%s","type":"shadowsocks"}]}\n' "$cfg" >"$err_dir/$cfg"
    printf '{"outbound_mode":"SS 出站","outbound_proxy":{"name":"c","config":{"type":"shadowsocks","server":"127.0.0.1","server_port":8388,"method":"aes-128-gcm","password":"secret"}}}\n' >"$err_dir/.quan-meta/$cfg.meta.json"
done
if render_runtime_node_outbound_modes "$is_config_json" "$output_target" "" "" "$err_dir"; then
    fail "tag collision must fail"
fi
[[ $runtime_sync_error == *"受管出站 tag 冲突:"* ]] || fail "unexpected error for tag collision: $runtime_sync_error"
cmp -s "$case_dir/config.err-before" "$output_target" || fail "tag collision must not overwrite output"

# 3. Linear O(1)-jq scale & sub-second benchmark (10 vs 50 mixed nodes + block-cn + whitelist + relay)
scale10_dir="$case_dir/scale-conf-10"
scale_dir="$case_dir/scale-conf"
mkdir -p "$scale10_dir/.quan-meta" "$scale_dir/.quan-meta"
: >"$is_core_dir/.block-cn-enabled"

build_mixed_nodes() {
    local target_dir=$1 count=$2 i m
    for ((i = 1; i <= count; i++)); do
        m=$((i % 4))
        if ((m == 0)); then
            cat >"$target_dir/node-$i.json" <<EOF
{"inbounds":[{"tag":"node-$i.json","type":"shadowsocks","listen":"::","listen_port":$((32000+i)),"method":"aes-128-gcm","password":"pwd"}]}
EOF
            jq -n '{outbound_mode:"V4优先"}' >"$target_dir/.quan-meta/node-$i.json.meta.json"
        elif ((m == 1)); then
            cat >"$target_dir/node-$i.json" <<EOF
{"inbounds":[{"tag":"node-$i.json","type":"shadowsocks","listen":"::","listen_port":$((32000+i)),"method":"aes-128-gcm","password":"pwd"}]}
EOF
            jq -n --arg n "SS-$i" --arg ip "198.51.100.$((i%250+1))" '{outbound_mode:"SS 出站",outbound_proxy:{name:$n,config:{type:"shadowsocks",server:$ip,server_port:8388,method:"aes-128-gcm",password:"secret"}}}' >"$target_dir/.quan-meta/node-$i.json.meta.json"
        elif ((m == 2)); then
            cat >"$target_dir/node-$i.json" <<EOF
{"inbounds":[{"tag":"node-$i.json","type":"vless","listen":"::","listen_port":$((32000+i)),"users":[{"uuid":"11111111-1111-4111-8111-111111111111"}]}]}
EOF
            jq -n --arg n "VL-$i" --arg host "up-$i.example.com" '{outbound_mode:"VLESS 出站",outbound_proxy:{name:$n,config:{type:"vless",server:$host,server_port:443,uuid:"11111111-1111-4111-8111-111111111111"}}}' >"$target_dir/.quan-meta/node-$i.json.meta.json"
        else
            cat >"$target_dir/node-$i.json" <<EOF
{"inbounds":[{"tag":"node-$i.json","type":"shadowsocks","listen":"::","listen_port":$((32000+i)),"method":"aes-128-gcm","password":"pwd"}]}
EOF
        fi
    done
    cat >"$target_dir/relay-29999.json" <<'EOF'
{"inbounds":[{"tag":"relay-29999.json","type":"direct","listen":"::","listen_port":29999,"override_address":"203.0.113.10","override_port":29999}]}
EOF
}

build_mixed_nodes "$scale10_dir" 10
build_mixed_nodes "$scale_dir" 50

: >"$jq_count_file"
PATH="$jq_wrap_dir:$PATH" render_runtime_node_outbound_modes "$is_config_json" "$case_dir/scale10-out.json" "" "" "$scale10_dir" || fail "10-node render failed: $runtime_sync_error"
render10_jq_calls=$(wc -l <"$jq_count_file")

: >"$jq_count_file"
t0=$(date +%s%N)
PATH="$jq_wrap_dir:$PATH" render_runtime_node_outbound_modes "$is_config_json" "$case_dir/scale-out.json" "" "" "$scale_dir" || fail "50-node render failed: $runtime_sync_error"
t1=$(date +%s%N)
render_ms=$(( (t1 - t0) / 1000000 ))
render_jq_calls=$(wc -l <"$jq_count_file")
echo "10-node jq_calls=${render10_jq_calls}; 50-node render: ${render_ms}ms, jq_calls=${render_jq_calls}"
(( render_jq_calls == render10_jq_calls )) || fail "jq subprocess count should stay constant between 10 ($render10_jq_calls) and 50 ($render_jq_calls) nodes"
(( render_jq_calls <= 8 )) || fail "50-node render spawned $render_jq_calls jq subprocesses (expected <= 8)"
(( render_ms < 500 )) || fail "50-node render took ${render_ms}ms (expected < 500ms)"

# Verify 50-node rendered output completeness
jq -e '([.route.rules[0].inbound[]] | length) == 50' "$case_dir/scale-out.json" >/dev/null || fail "50-node sniff rule must cover all 50 managed inbounds"
jq -e '.route.rules | any(.inbound // [] | any(. == "relay-29999.json")) | not' "$case_dir/scale-out.json" >/dev/null || fail "50-node render must exclude relay"

# Verify sync_runtime_node_outbound_modes initializes legacy nodes and stays fast on steady state
sync_runtime_node_outbound_modes "$is_config_json" "$case_dir/scale-synced.json" "$scale_dir" 0 || fail "50-node initial sync failed: $runtime_sync_error"
: >"$jq_count_file"
t0=$(date +%s%N)
PATH="$jq_wrap_dir:$PATH" sync_runtime_node_outbound_modes "$is_config_json" "$case_dir/scale-synced.json" "$scale_dir" 0 || fail "50-node steady sync failed: $runtime_sync_error"
t1=$(date +%s%N)
sync_ms=$(( (t1 - t0) / 1000000 ))
sync_jq_calls=$(wc -l <"$jq_count_file")
echo "50-node steady sync: ${sync_ms}ms, jq_calls=${sync_jq_calls}"
(( sync_jq_calls <= 12 )) || fail "50-node steady sync spawned $sync_jq_calls jq subprocesses (expected <= 12)"
(( sync_ms < 500 )) || fail "50-node steady sync took ${sync_ms}ms (expected < 500ms)"
CASE
}

run_case || exit 1
echo "PASS: runtime node outbound render scale & semantics"
