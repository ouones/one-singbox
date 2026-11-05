#!/usr/bin/env bash
set -o pipefail
repo_root=$(cd "$(dirname "$0")" && pwd)

for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
    CORE_FILE=$core_file bash <<'CASE' || exit 1
source <(sed '/EUID != 0/d' "$CORE_FILE")
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
mkdir -p "$is_core_dir" "$is_conf_dir"
is_main_start=1
is_random_ss_method=aes-128-gcm
get_port() { tmp_port=32000; }
get_uuid() { tmp_uuid=22222222-2222-4222-8222-222222222222; }
get() { :; }
node_port_used() { return 1; }
create() { :; }
info() { :; }
meta_set() { :; }
fail() { echo "FAIL($CORE_FILE): $*"; exit 1; }

node_menu >"$case_dir/tls-output" 2>&1 <<'INPUT'
1
10
example.com
tls-node

5
INPUT
tls_output=$(cat "$case_dir/tls-output")
[[ $tls_output == *'选择协议:'* ]] || fail "protocol choice uses the short prompt: $tls_output"
[[ $tls_output == *'请输入域名 (需解析到本机公网 IP):'* ]] || fail "TLS add explains the domain requirement: $tls_output"
[[ $tls_output == *'请输入节点名称 (回车自动生成 8 位名称):'* ]] || fail "node name explains automatic generation: $tls_output"

node_menu >"$case_dir/socks-output" 2>&1 <<'INPUT'
1
21
32001
alice

socks-node

5
INPUT
socks_output=$(cat "$case_dir/socks-output")
[[ $socks_output == *'请输入监听端口 (1-65535，回车自动分配 32000):'* ]] || fail "SOCKS add explains automatic port assignment: $socks_output"
[[ $socks_output == *'请输入用户名:'* ]] || fail "SOCKS add uses the concise username prompt: $socks_output"
[[ $socks_output == *'请输入密码 (回车自动生成；输入不显示):'* ]] || fail "SOCKS add explains generated passwords: $socks_output"

node_menu >"$case_dir/ss-output" 2>&1 <<'INPUT'
1
8
32002


ss-node

5
INPUT
ss_output=$(cat "$case_dir/ss-output")
[[ $ss_output == *'选择加密方式:'* ]] || fail "Shadowsocks add uses the concise method prompt: $ss_output"
[[ $ss_output == *'请输入监听端口 (1-65535，回车自动分配 32000):'* ]] || fail "Shadowsocks add explains automatic port assignment: $ss_output"
[[ $ss_output == *'请输入密码 (回车自动生成；输入不显示):'* ]] || fail "Shadowsocks add explains generated passwords: $ss_output"

is_can_change=({0..20})
ask set_change_list <<<15 >"$case_dir/change-output" 2>&1
change_output=$(cat "$case_dir/change-output")
for item in 协议 监听端口 域名 路径 密码 UUID 加密方式 目标地址 目标端口 密钥 SNI 反向代理域名 用户名 节点名称 出口方式 分享地址 查看分享链接 PSK 'Snell 版本' 混淆模式 运行模式; do
    [[ $change_output == *"$item"* ]] || fail "change menu shows $item: $change_output"
done
[[ $change_output == *'选择: 出口方式'* ]] || fail "change choice remains mapped to outbound mode: $change_output"
[[ ${is_can_change[$REPLY - 1]} == 14 ]] || fail "outbound mode keeps its existing selection index: $REPLY"

ask set_outbound_mode <<<5 >"$case_dir/outbound-output" 2>&1
outbound_output=$(cat "$case_dir/outbound-output")
[[ $outbound_output == *'Shadowsocks 出口'* && $outbound_output == *'VLESS 出口'* ]] || fail "proxy choices are labeled as exits: $outbound_output"
[[ $outbound_output == *'选择出口方式:'* ]] || fail "outbound prompt uses exit terminology: $outbound_output"
[[ $outbound_output == *'选择: Shadowsocks 出口'* ]] || fail "selected proxy exit uses its visible label: $outbound_output"
[[ $is_outbound_mode == 'SS 出站' ]] || fail "Shadowsocks option keeps its existing configuration value: $is_outbound_mode"
CASE
done

for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
    CORE_FILE=$core_file bash <<'CASE' || exit 1
source <(sed '/EUID != 0/d' "$CORE_FILE")
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_conf_dir=$case_dir/conf
mkdir -p "$is_conf_dir/.quan-meta"
is_config_file=node.json
cat >"$is_conf_dir/.quan-meta/$is_config_file.meta.json" <<'JSON'
{"outbound_mode":"SS 出站","outbound_proxy":{"name":"test-ss","config":{"type":"shadowsocks","server":"proxy.example","server_port":8388,"method":"aes-128-gcm","password":"secret"}}}
JSON
apply_node_outbound_mode() { :; }
msg_outbound_mode_display() { :; }
fail() { echo "FAIL($CORE_FILE): $*"; exit 1; }

edit_node_outbound_mode >"$case_dir/ss-match" 2>&1 <<'INPUT'
5

INPUT
ss_output=$(cat "$case_dir/ss-match")
[[ $ss_output == *'回车保留当前配置'* ]] || fail "same-type Shadowsocks reuse is explained: $ss_output"
[[ $ss_output != *'留空复用当前配置'* ]] || fail "reuse prompt refers to pressing Enter: $ss_output"

cat >"$is_conf_dir/.quan-meta/$is_config_file.meta.json" <<'JSON'
{"outbound_mode":"VLESS 出站","outbound_proxy":{"name":"test-vless","config":{"type":"vless","server":"proxy.example","server_port":443,"uuid":"11111111-1111-4111-8111-111111111111"}}}
JSON
edit_node_outbound_mode >"$case_dir/vless-match" 2>&1 <<'INPUT'
6

INPUT
vless_output=$(cat "$case_dir/vless-match")
[[ $vless_output == *'回车保留当前配置'* ]] || fail "same-type VLESS reuse is explained: $vless_output"

cat >"$is_conf_dir/.quan-meta/$is_config_file.meta.json" <<'JSON'
{"outbound_mode":"SS 出站","outbound_proxy":{"name":"test-ss","config":{"type":"shadowsocks","server":"proxy.example","server_port":8388,"method":"aes-128-gcm","password":"secret"}}}
JSON
(edit_node_outbound_mode >"$case_dir/vless-no-reuse" 2>&1 <<'INPUT'
6

INPUT
) || :
mismatch_output=$(cat "$case_dir/vless-no-reuse")
[[ $mismatch_output != *'回车保留当前配置'* ]] || fail "different proxy types do not offer reuse: $mismatch_output"
CASE
done

for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
    CORE_FILE=$core_file bash <<'CASE' || exit 1
source <(sed '/EUID != 0/d' "$CORE_FILE")
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
is_config_json=$case_dir/config.json
is_core_bin=/bin/true
is_main_start=1
is_dont_get_ip=1
ip=203.0.113.10
mkdir -p "$is_core_dir" "$is_conf_dir"
cat >"$is_conf_dir/node.json" <<'JSON'
{"inbounds":[{"type":"shadowsocks","listen":"::","listen_port":32003,"method":"aes-128-gcm","password":"old-secret"}],"outbounds":[{"tag":"direct","type":"direct"}]}
JSON
get_ip() { :; }
add() { :; }
render_qrcode() { :; }
fail() { echo "FAIL($CORE_FILE): $*"; exit 1; }

node_menu >"$case_dir/change-output" 2>&1 <<'INPUT'
2
3
new-secret

5
INPUT
change_output=$(cat "$case_dir/change-output")
[[ $change_output == *'选择: 密码'* ]] || fail "password is selectable from the modify menu: $change_output"
[[ $change_output == *'请输入新密码 (输入不显示):'* ]] || fail "password modification asks for its new value: $change_output"
[[ $change_output != *'new-secret'* ]] || fail "modified password input stays hidden: $change_output"
CASE
done

echo "PASS: node menu copy prompts"
