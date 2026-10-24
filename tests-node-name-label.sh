#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)

workdir=$(mktemp -d)
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

source "$repo_root/core.sh"
manage() { :; }
mkdir -p "$workdir/bin"
cat >"$workdir/bin/sing-box" <<'FAKE_CORE'
#!/usr/bin/env bash
[[ $1 == check ]] || exit 0
config= conf_dir=
while [[ $# -gt 0 ]]; do
  case $1 in
    -c) config=$2; shift 2 ;;
    -C) conf_dir=$2; shift 2 ;;
    *) shift ;;
  esac
done
[[ -f $config && -d $conf_dir ]] || exit 1
jq -e . "$config" >/dev/null || exit 1
for file in "$conf_dir"/*.json; do
  [[ -f $file ]] || continue
  jq -e . "$file" >/dev/null || exit 1
done
FAKE_CORE
chmod +x "$workdir/bin/sing-box"
is_core_bin="$workdir/bin/sing-box"
systemctl() {
  case $1 in
    restart | is-active) return 0 ;;
    show) echo 1234 ;;
  esac
}
sleep() { :; }

is_conf_dir="$workdir/conf"
is_config_json="$workdir/config.json"
is_dont_auto_exit=1
export ip=203.0.113.10 is_dont_get_ip=1
mkdir -p "$is_conf_dir/.quan-meta"

cat > "$is_conf_dir/demo.json" <<'EOF'
{
  "inbounds": [
    {
      "tag": "demo.json",
      "type": "shadowsocks",
      "listen": "0.0.0.0",
      "listen_port": 12345,
      "method": "aes-128-gcm",
      "password": "pass123"
    }
  ],
  "outbounds": [
    {"type": "direct"},
    {"tag": "direct"}
  ]
}
EOF

is_config_file=demo.json

old_label=$(node_name_for_link "$is_config_file")
[[ "$old_label" == "demo" ]] || {
  echo "FAIL: baseline node label should be demo"
  echo "old_label=${old_label:-<empty>}"
  exit 1
}

change demo.json name NewLabel

[[ -f "$is_conf_dir/demo.json" ]] || {
  echo "FAIL: original json file missing after rename"
  exit 1
}
[[ ! -f "$is_conf_dir/NewLabel.json" ]] || {
  echo "FAIL: json filename was renamed, but should not be"
  exit 1
}

meta_file="$is_conf_dir/.quan-meta/demo.json.meta.json"
[[ -f "$meta_file" ]] || {
  echo "FAIL: node label metadata file not created"
  exit 1
}

jq -e '.node_name == "NewLabel"' "$meta_file" >/dev/null || {
  echo "FAIL: node label metadata value is incorrect"
  cat "$meta_file"
  exit 1
}

new_label=$(node_name_for_link "$is_config_file")
[[ "$new_label" == "NewLabel" ]] || {
  echo "FAIL: node_name_for_link should return NewLabel"
  echo "new_label=${new_label:-<empty>}"
  exit 1
}

grep -q 'is_node_name=$(node_name_for_link "${is_config_file:-$is_config_name}")' "$repo_root/core.sh" || {
  echo "FAIL: core.sh no longer wires URL node label with config fallback"
  exit 1
}

cat > "$is_conf_dir/VLESS-REALITY-12345.json" <<'EOF'
{
  "inbounds": [
    {
      "tag": "VLESS-REALITY-12345.json",
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": 12345,
      "users": [{"uuid": "11111111-1111-1111-1111-111111111111"}],
      "tls": {
        "server_name": "old.example.com",
        "reality": {"private_key": "abcdefghijklmnopqrstuvwxyz1234567890abcd"}
      }
    }
  ],
  "outbounds": [
    {"type": "direct"},
    {"tag": "public_key_abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"}
  ]
}
EOF

jq -n '{node_name:"MyNode",entry_addr:"edge.example.com",outbound_mode:"V4优先"}' > "$is_conf_dir/.quan-meta/VLESS-REALITY-12345.json.meta.json"
change VLESS-REALITY-12345.json sni new.example.com >/dev/null

sni_meta_file="$is_conf_dir/.quan-meta/VLESS-REALITY-12345.json.meta.json"
[[ -f "$sni_meta_file" ]] || {
  echo "FAIL: node label metadata missing after change sni"
  exit 1
}

jq -e '.node_name == "MyNode"' "$sni_meta_file" >/dev/null || {
  echo "FAIL: change sni should preserve custom node label"
  cat "$sni_meta_file"
  exit 1
}

jq -e '.entry_addr == "edge.example.com"' "$sni_meta_file" >/dev/null || {
  echo "FAIL: change sni should preserve custom entry address"
  cat "$sni_meta_file"
  exit 1
}

jq -e '.outbound_mode == "V4优先"' "$sni_meta_file" >/dev/null || {
  echo "FAIL: change sni should preserve outbound mode"
  cat "$sni_meta_file"
  exit 1
}

sni_label=$(node_name_for_link "VLESS-REALITY-12345.json")
[[ "$sni_label" == "MyNode" ]] || {
  echo "FAIL: node_name_for_link should keep MyNode after change sni"
  echo "sni_label=${sni_label:-<empty>}"
  exit 1
}

is_dont_show_info=1
info VLESS-REALITY-12345.json
[[ "$is_addr" == "edge.example.com" ]] || {
  echo "FAIL: link address should keep custom entry address after change sni"
  echo "is_addr=${is_addr:-<empty>}"
  exit 1
}

[[ "$is_url" == *"@edge.example.com:12345"* ]] || {
  echo "FAIL: URL should keep custom entry address after change sni"
  echo "$is_url"
  exit 1
}

change VLESS-REALITY-12345.json entry new-entry.example.com >/dev/null
[[ "$is_addr" == "new-entry.example.com" ]] || {
  echo "FAIL: change entry should refresh current link address immediately"
  echo "is_addr=${is_addr:-<empty>}"
  exit 1
}

[[ "$is_url" == *"@new-entry.example.com:12345"* ]] || {
  echo "FAIL: change entry should refresh current URL immediately"
  echo "$is_url"
  exit 1
}

cat > "$is_config_json" <<'EOF'
{
  "dns": {
    "servers": [
      {"tag": "dns", "type": "udp", "server": "1.1.1.1", "domain_resolver": "local"},
      {"tag": "local", "type": "local"}
    ]
  },
  "route": {"default_domain_resolver": "dns"},
  "outbounds": [{"tag": "direct", "type": "direct"}]
}
EOF

cat > "$is_conf_dir/node-b.json" <<'EOF'
{
  "inbounds": [
    {
      "tag": "node-b.json",
      "type": "shadowsocks",
      "listen": "0.0.0.0",
      "listen_port": 22345,
      "method": "aes-128-gcm",
      "password": "pass456"
    }
  ]
}
EOF

jq -n '{outbound_mode:"V6优先"}' > "$is_conf_dir/.quan-meta/node-b.json.meta.json"
sync_runtime_node_outbound_modes

jq -e '.outbounds[] | select(.tag == "direct_v4_pref" and .domain_resolver.server == "dns" and .domain_resolver.strategy == "prefer_ipv4")' "$is_config_json" >/dev/null || {
  echo "FAIL: V4 preferred direct outbound missing"
  jq . "$is_config_json"
  exit 1
}

jq -e '.outbounds[] | select(.tag == "direct_v6_pref" and .domain_resolver.server == "dns" and .domain_resolver.strategy == "prefer_ipv6")' "$is_config_json" >/dev/null || {
  echo "FAIL: V6 preferred direct outbound missing"
  jq . "$is_config_json"
  exit 1
}

jq -e '.route.rules[] | select((.inbound[0] == "VLESS-REALITY-12345.json") and .outbound == "direct_v4_pref")' "$is_config_json" >/dev/null || {
  echo "FAIL: V4 preferred route rule missing"
  jq . "$is_config_json"
  exit 1
}

jq -e '.route.rules[] | select((.inbound[0] == "node-b.json") and .outbound == "direct_v6_pref")' "$is_config_json" >/dev/null || {
  echo "FAIL: V6 preferred route rule missing"
  jq . "$is_config_json"
  exit 1
}

jq -e '.dns.strategy == null' "$is_config_json" >/dev/null || {
  echo "FAIL: global DNS strategy should not be used for per-node outbound mode"
  jq . "$is_config_json"
  exit 1
}

cat > "$is_config_json" <<'EOF'
{
  "dns": {},
  "route": {"default_domain_resolver": {"strategy": "prefer_ipv6"}},
  "outbounds": [{"tag": "direct", "type": "direct"}]
}
EOF

sync_runtime_node_outbound_modes

jq -e '(.route.default_domain_resolver // null) != ""' "$is_config_json" >/dev/null || {
  echo "FAIL: default_domain_resolver should not become an empty string"
  jq . "$is_config_json"
  exit 1
}

jq -e '(.route.default_domain_resolver // null | type) != "object"' "$is_config_json" >/dev/null || {
  echo "FAIL: default_domain_resolver should not remain an object without server"
  jq . "$is_config_json"
  exit 1
}

jq -e '.outbounds[] | select(.tag == "direct_v4_pref" and .domain_resolver.server == "local")' "$is_config_json" >/dev/null || {
  echo "FAIL: fallback local resolver should be used when old default_domain_resolver object has no server"
  jq . "$is_config_json"
  exit 1
}

ss_uri='ss://MjAyMi1ibGFrZTMtYWVzLTEyOC1nY206TnJMYkI1OGNJbzRhN2xLYWsxWUNvZz09@69.12.75.251:9969#美国 dedirock ss 落地'
parse_ss_uri_for_outbound "$ss_uri" || {
  echo "FAIL: parse_ss_uri_for_outbound should accept the sample ss uri"
  exit 1
}

[[ "$is_outbound_ss_method" == "2022-blake3-aes-128-gcm" ]] || {
  echo "FAIL: parsed ss method is incorrect"
  echo "$is_outbound_ss_method"
  exit 1
}

[[ "$is_outbound_ss_password" == "NrLbB58cIo4a7lKak1YCog==" ]] || {
  echo "FAIL: parsed ss password is incorrect"
  echo "$is_outbound_ss_password"
  exit 1
}

[[ "$is_outbound_ss_server" == "69.12.75.251" ]] || {
  echo "FAIL: parsed ss server is incorrect"
  echo "$is_outbound_ss_server"
  exit 1
}

[[ "$is_outbound_ss_port" == "9969" ]] || {
  echo "FAIL: parsed ss port is incorrect"
  echo "$is_outbound_ss_port"
  exit 1
}

[[ "$is_outbound_ss_name" == "美国 dedirock ss 落地" ]] || {
  echo "FAIL: parsed ss name is incorrect"
  echo "$is_outbound_ss_name"
  exit 1
}

jq -n '{outbound_mode:"V4优先"}' > "$is_conf_dir/.quan-meta/demo.json.meta.json"
current_display=$(current_outbound_mode_display "demo.json")
[[ "$current_display" == "V4优先" ]] || {
  echo "FAIL: current direct outbound mode display is incorrect"
  echo "$current_display"
  exit 1
}

cat > "$is_config_json" <<'EOF'
{
  "dns": {},
  "route": {"default_domain_resolver": "local"},
  "outbounds": [{"tag": "direct", "type": "direct"}]
}
EOF

cat > "$is_conf_dir/node-c.json" <<'EOF'
{
  "inbounds": [
    {
      "tag": "node-c.json",
      "type": "vless",
      "listen": "0.0.0.0",
      "listen_port": 32345,
      "users": [{"uuid": "22222222-2222-2222-2222-222222222222"}]
    }
  ]
}
EOF

jq -n '{outbound_mode:"SS 出站",outbound_ss_server:"69.12.75.251",outbound_ss_port:"9969",outbound_ss_method:"2022-blake3-aes-128-gcm",outbound_ss_password:"NrLbB58cIo4a7lKak1YCog==",outbound_ss_name:"美国 dedirock ss 落地"}' > "$is_conf_dir/.quan-meta/node-c.json.meta.json"
sync_runtime_node_outbound_modes

jq -e '.outbounds[] | select(.tag == "managed_node_ss_node-c_json" and .type == "shadowsocks" and .server == "69.12.75.251" and .server_port == 9969 and .method == "2022-blake3-aes-128-gcm" and .password == "NrLbB58cIo4a7lKak1YCog==")' "$is_config_json" >/dev/null || {
  echo "FAIL: managed shadowsocks outbound missing or incorrect"
  jq . "$is_config_json"
  exit 1
}

jq -e '.route.rules[] | select((.inbound[0] == "node-c.json") and .outbound == "managed_node_ss_node-c_json")' "$is_config_json" >/dev/null || {
  echo "FAIL: ss outbound route rule missing"
  jq . "$is_config_json"
  exit 1
}

jq -e '.route.rules[] | select((.inbound[0] == "demo.json") and .outbound == "direct_v4_pref")' "$is_config_json" >/dev/null || {
  echo "FAIL: direct outbound route rule should remain after adding ss outbound"
  jq . "$is_config_json"
  exit 1
}

current_display=$(current_outbound_mode_display "node-c.json")
[[ "$current_display" == "SS 出站 (美国 dedirock ss 落地)" ]] || {
  echo "FAIL: current ss outbound mode display should prefer node name"
  echo "$current_display"
  exit 1
}

jq -n '{outbound_mode:"SS 出站",outbound_ss_server:"69.12.75.251",outbound_ss_port:"9969",outbound_ss_method:"2022-blake3-aes-128-gcm",outbound_ss_password:"NrLbB58cIo4a7lKak1YCog=="}' > "$is_conf_dir/.quan-meta/node-c.json.meta.json"
current_display=$(current_outbound_mode_display "node-c.json")
[[ "$current_display" == "SS 出站 (69.12.75.251:9969)" ]] || {
  echo "FAIL: current ss outbound mode display should fall back to server:port"
  echo "$current_display"
  exit 1
}

jq -n '{outbound_mode:"仅V6"}' > "$is_conf_dir/.quan-meta/node-c.json.meta.json"
sync_runtime_node_outbound_modes

jq -e '.outbounds[] | select(.tag == "managed_node_ss_node-c_json")' "$is_config_json" >/dev/null && {
  echo "FAIL: managed ss outbound should be cleaned after switching back to direct"
  jq . "$is_config_json"
  exit 1
}

jq -e '.route.rules[] | select((.inbound[0] == "node-c.json") and .outbound == "direct_v6_only")' "$is_config_json" >/dev/null || {
  echo "FAIL: route rule should switch back to direct_v6_only"
  jq . "$is_config_json"
  exit 1
}

echo "PASS: node link metadata, URL display, and per-node outbound modes survive config changes, including SS outbound"
