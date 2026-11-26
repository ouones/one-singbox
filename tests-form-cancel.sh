#!/usr/bin/env bash
# Regression coverage for issue #132: every manual form page names its cancel
# commands, and cancelling never rewrites configuration or restarts sing-box.
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
core_file="$repo_root/src/core.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Form pages offer a cancel token, and cancelling a value form writes nothing.
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
is_core_bin=/bin/true
is_dont_get_ip=1
mkdir -p "$is_core_dir" "$is_conf_dir/.quan-meta"
cat >"$is_conf_dir/node.json" <<'JSON'
{"inbounds":[{"type":"shadowsocks","listen":"::","listen_port":32003,"method":"aes-128-gcm","password":"secret"}],"outbounds":[{"tag":"direct","type":"direct"}]}
JSON
jq -n '{node_name:"KeepMe",entry_addr:"edge.example.com"}' >"$is_conf_dir/.quan-meta/node.json.meta.json"
cp "$is_conf_dir/node.json" "$case_dir/config.before"
cp "$is_conf_dir/.quan-meta/node.json.meta.json" "$case_dir/meta.before"
info() { is_config_file=node.json; }
manage_restart_checked() { printf 'RESTARTED\n'; }
meta_set() { printf 'META_SET:%s\n' "$*"; }
sync_entry_addr_config() { printf '%s' "$2" >"$case_dir/synced-entry"; printf '%s' "$2"; }
fail() { echo "FAIL($CORE_FILE): $*"; exit 1; }
port_tip='提示：输入 0 或 q 取消当前操作'
cancelled='已取消当前操作，未改动任何配置。'

output=$(printf '0\n' | change node.json port 2>&1); status=$?
[[ $status != 0 ]] || fail "cancelling the port form must not report success: $output"
[[ $output == *"$port_tip"* ]] || fail "port form does not explain how to cancel: $output"
[[ $output == *"$cancelled"* ]] || fail "port form cancel is not reported: $output"
[[ $output != *'RESTARTED'* ]] || fail "port form cancel restarted the service: $output"
cmp -s "$case_dir/config.before" "$is_conf_dir/node.json" || fail "port form cancel rewrote the node config"
cmp -s "$case_dir/meta.before" "$is_conf_dir/.quan-meta/node.json.meta.json" || fail "port form cancel rewrote node metadata"

output=$(printf 'q\n' | change node.json port 2>&1); status=$?
[[ $status != 0 && $output == *"$cancelled"* ]] || fail "q does not cancel the port form: $output"
cmp -s "$case_dir/config.before" "$is_conf_dir/node.json" || fail "q in the port form rewrote the node config"

output=$(printf 'q\n' | change node.json name 2>&1); status=$?
[[ $status != 0 && $output == *"$cancelled"* ]] || fail "node rename form does not cancel on q: $output"
[[ $output != *'META_SET:'* ]] || fail "node rename cancel still wrote node metadata: $output"

# Node name pages keep 0 as a literal name and spell that out in the hint.
output=$(printf '0\n' | change node.json name 2>&1); status=$?
[[ $status == 0 && $output == *'META_SET:node.json node_name 0'* ]] || fail "node rename keeps 0 as a literal name: $output"
[[ $output == *'本页输入 0 会直接作为名称保存'* ]] || fail "node rename page does not explain that 0 is a name: $output"

# Site address: Enter / 0 / q cancel instead of silently resetting to the public IP.
for input in '' '0' 'q'; do
    rm -f "$case_dir/synced-entry"
    output=$(printf '%s\n' "$input" | change node.json entry 2>&1); status=$?
    [[ $status != 0 ]] || fail "site address cancel must not report success (input '$input'): $output"
    [[ $output == *"$port_tip"* ]] || fail "site address form does not explain how to cancel: $output"
    [[ $output == *'已取消，分享地址保持不变。'* ]] || fail "site address cancel is not reported (input '$input'): $output"
    [[ ! -e $case_dir/synced-entry ]] || fail "site address cancel still rewrote the entry address (input '$input')"
    cmp -s "$case_dir/config.before" "$is_conf_dir/node.json" || fail "site address cancel rewrote the node config (input '$input')"
    cmp -s "$case_dir/meta.before" "$is_conf_dir/.quan-meta/node.json.meta.json" || fail "site address cancel rewrote node metadata (input '$input')"
done

output=$(change node.json entry 0 2>&1); status=$?
[[ $status != 0 && ! -e $case_dir/synced-entry ]] || fail "a literal 0 argument must not reset the site address: $output"

# Reusing the public IP stays available, but only as an explicit command.
output=$(change node.json entry auto 2>&1); status=$?
[[ $status == 0 ]] || fail "entry auto no longer resets the site address: $output"
[[ -f $case_dir/synced-entry && ! -s $case_dir/synced-entry ]] || fail "entry auto must reset the entry address to the public IP: $output"
[[ $output == *'已更新入口地址为'* ]] || fail "entry auto does not report the new site address: $output"
CASE

# Custom DNS cancel never rewrites the runtime DNS configuration.
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
is_config_json=$case_dir/core/config.json
is_core_ver=1.50.0
is_core_bin=/bin/true
mkdir -p "$is_core_dir" "$is_conf_dir"
printf '{"dns":{},"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_config_json"
cp "$is_config_json" "$case_dir/config.before"
load dns.sh
fail() { echo "FAIL($CORE_FILE): $*"; exit 1; }

output=$(printf '6\n0\n' | dns_set 2>&1); status=$?
[[ $status != 0 ]] || fail "custom DNS cancel must not report success: $output"
[[ $output == *'提示：输入 0 或 q 取消当前操作'* ]] || fail "custom DNS form does not explain how to cancel: $output"
[[ $output == *'已取消当前操作，未改动任何配置。'* ]] || fail "custom DNS cancel is not reported: $output"
[[ $output != *'系统影响确认'* ]] || fail "custom DNS cancel still asked for a restart confirmation: $output"
cmp -s "$case_dir/config.before" "$is_config_json" || fail "custom DNS cancel rewrote the runtime config"
CASE

# A malformed or missing proxy link is re-prompted; 0/q return to the mode list.
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_conf_dir=$case_dir/conf
mkdir -p "$is_conf_dir/.quan-meta"
is_config_file=node.json
apply_node_outbound_mode() { printf 'APPLIED:%s\n' "$2"; }
msg_outbound_mode_display() { printf 'DISPLAY:%s\n' "$1"; }
fail() { echo "FAIL($CORE_FILE): $*"; exit 1; }
ss_uri="ss://$(printf '%s' 'aes-128-gcm:secret' | base64 | tr -d '\n')@127.0.0.1:8388#Upstream"

output=$(printf '5\nnot-a-link\n%s\n' "$ss_uri" | edit_node_outbound_mode 2>&1); status=$?
[[ $status == 0 ]] || fail "a corrected proxy link must still apply: $output"
[[ $output == *'可重新粘贴 Shadowsocks 分享链接'* ]] || fail "malformed link does not allow a retry: $output"
[[ $output == *'APPLIED:SS 出站'* ]] || fail "retried proxy link was not applied: $output"

output=$(printf '5\n\n%s\n' "$ss_uri" | edit_node_outbound_mode 2>&1); status=$?
[[ $status == 0 ]] || fail "first-time proxy setup must retry after an empty reply: $output"
[[ $output == *'没有可复用的 Shadowsocks 配置'* ]] || fail "empty first-time link does not explain the missing cache: $output"
[[ $(grep -Fc '请输入 Shadowsocks 分享链接' <<<"$output") -ge 2 ]] || fail "empty first-time link does not allow a retry: $output"
[[ $output == *'APPLIED:SS 出站'* ]] || fail "link entered after an empty reply was not applied: $output"

for cancel_key in 0 q; do
    output=$(printf '5\n%s\n0\n' "$cancel_key" | edit_node_outbound_mode 2>&1); status=$?
    [[ $status == 2 ]] || fail "proxy link cancel ($cancel_key) must return to the mode list: $output"
    [[ $output == *'已返回选择出口方式。'* ]] || fail "proxy link cancel ($cancel_key) is not reported: $output"
    [[ $(grep -Fc '选择出口方式:' <<<"$output") -ge 2 ]] || fail "proxy link cancel ($cancel_key) does not repaint the mode list: $output"
    [[ $output != *'APPLIED:'* ]] || fail "proxy link cancel ($cancel_key) still applied an exit mode: $output"
done
CASE

# A busy 80/443 port asks [y/N] before installing Caddy; Enter is a cancel.
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
is_core_bin=/bin/true
is_main_start=1
is_core_ver=1.50.0
mkdir -p "$is_core_dir" "$is_conf_dir"
node_port_used() { printf '%s\n' "$1"; }
get_port() { tmp_port=$((40000 + RANDOM % 1000)); }
get() { case $1 in install-caddy) printf 'CADDY_INSTALLED\n' ;; esac; }
info() { :; }
fail() { echo "FAIL($CORE_FILE): $*"; exit 1; }

output=$(printf '\n' | add vless-ws-tls 2>&1); status=$?
[[ $status != 0 ]] || fail "Enter at the Caddy prompt must not continue the add: $output"
[[ $output == *'确认使用非标准端口安装 Caddy [y/N]:'* ]] || fail "Caddy prompt is not a default-cancel confirmation: $output"
[[ $output == *'已取消安装 Caddy'* ]] || fail "Caddy cancel is not reported: $output"
[[ $output != *'CADDY_INSTALLED'* ]] || fail "Enter at the Caddy prompt still installed Caddy: $output"
[[ $output != *'输入域名'* ]] || fail "cancelled add still asked for the node domain: $output"
[[ -z $(find "$is_conf_dir" -maxdepth 1 -name '*.json' -print -quit) ]] || fail "cancelled add wrote a node config"

output=$(printf 'y\n' | add vless-ws-tls 2>&1)
[[ $output == *'确认使用非标准端口安装 Caddy [y/N]:'* && $output == *'输入域名'* ]] || fail "y must continue the non-standard port install: $output"
[[ $output != *'已取消安装 Caddy'* ]] || fail "y was treated as a cancel: $output"
CASE

# Inside a menu session a form cancel returns to the parent menu, not the patch.
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
is_core_bin=/bin/true
is_main_start=1
mkdir -p "$is_core_dir" "$is_conf_dir"
get_port() { tmp_port=12000; }
node_port_used() { return 1; }
fail() { echo "FAIL($CORE_FILE): $*"; exit 1; }

output=$(printf '1\n0\n' | relay_menu 2>&1)
[[ $output == *'提示：输入 0 或 q 取消当前操作'* ]] || fail "relay port form does not explain how to cancel: $output"
[[ $output == *'已取消当前操作'* ]] || fail "menu session does not report the form cancel: $output"
[[ $output == *'按回车返回菜单。'* ]] || fail "menu session does not return to the parent menu after a cancel: $output"
[[ -z $(find "$is_conf_dir" -maxdepth 1 -name '*.json' -print -quit) ]] || fail "cancelled relay add wrote a forwarding rule"
CASE

# The node name page keeps 0 as a literal name and says so in its cancel hint.
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
is_core_bin=/bin/true
is_main_start=1
is_core_ver=1.14.4
port=23456
host=203.0.113.10
uuid=123e4567-e89b-12d3-a456-426614174000
mkdir -p "$is_core_dir" "$is_conf_dir"
node_port_used() { return 1; }
create() { is_config_name=zero-node.json; }
info() { :; }
meta_set() { printf '%s|%s|%s\n' "$1" "$2" "$3"; }
fail() { echo "FAIL($CORE_FILE): $*"; exit 1; }

output=$(printf '22\n0\n\n' | add 2>&1); status=$?
[[ $status == 0 ]] || fail "node name 0 must stay a valid name: $output"
[[ $output == *'本页输入 0 会直接作为名称保存'* ]] || fail "node name page does not explain that 0 is a name: $output"
[[ $output == *'|node_name|0'* ]] || fail "node name 0 must be stored verbatim: $output"

output=$(printf '22\nq\n' | add 2>&1); status=$?
[[ $status != 0 ]] || fail "q must cancel the node name page: $output"
[[ $output == *'已取消添加节点。'* ]] || fail "node name cancel is not reported: $output"
[[ $output != *'|node_name|'* ]] || fail "cancelled node name form still wrote metadata: $output"
CASE

echo 'PASS: form cancel hints, config-safe cancels, proxy link retry, Caddy default cancel'
