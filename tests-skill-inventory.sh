#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
script="$repo_root/skills/devops/singbox-noninteractive-operations/scripts/singbox_inventory.sh"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
conf_dir="$workdir/conf"
log_file="$workdir/access.log"
mkdir -p "$conf_dir/.quan-meta"

cat >"$conf_dir/VLESS-REALITY-443.json" <<'EOF'
{
  "inbounds": [{
    "type": "vless",
    "listen": "::",
    "listen_port": 443,
    "transport": {"type": "tcp"},
    "tls": {"server_name": "edge.example.com", "reality": {"enabled": true}},
    "users": [{"uuid": "11111111-1111-1111-1111-111111111111"}]
  }]
}
EOF
printf '{"node_name":"香港主节点"}\n' >"$conf_dir/.quan-meta/VLESS-REALITY-443.json.meta.json"

cat >"$conf_dir/relay-10000.json" <<'EOF'
{
  "inbounds": [{
    "type": "direct",
    "listen": "::",
    "listen_port": 10000,
    "override_address": "203.0.113.10",
    "override_port": 443
  }]
}
EOF

printf '%s\n' 'INFO old' 'WARN keep' 'ERROR newest' >"$log_file"

bash -n "$script"
nodes=$($script nodes "$conf_dir")
[[ "$nodes" == *'代理节点（共 1 个）'* ]] || { printf 'FAIL: node count\n%s\n' "$nodes"; exit 1; }
[[ "$nodes" == *'香港主节点'* ]] || { printf 'FAIL: custom node name\n%s\n' "$nodes"; exit 1; }
[[ "$nodes" == *'协议：vless'* ]] || { printf 'FAIL: node protocol\n%s\n' "$nodes"; exit 1; }
[[ "$nodes" == *'安全：REALITY'* ]] || { printf 'FAIL: node security\n%s\n' "$nodes"; exit 1; }
[[ "$nodes" != *'11111111-1111-1111-1111-111111111111'* ]] || { printf 'FAIL: UUID leaked\n%s\n' "$nodes"; exit 1; }

relays=$($script relays "$conf_dir")
[[ "$relays" == *'中转列表（共 1 个）'* ]] || { printf 'FAIL: relay count\n%s\n' "$relays"; exit 1; }
[[ "$relays" == *'10000 -> 203.0.113.10:443'* ]] || { printf 'FAIL: relay summary\n%s\n' "$relays"; exit 1; }

logs=$($script logs 2 ERROR "$log_file")
[[ "$logs" == 'ERROR newest' ]] || { printf 'FAIL: bounded log filter\n%s\n' "$logs"; exit 1; }

printf 'OK: singbox inventory helper\n'
