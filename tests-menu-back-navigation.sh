#!/usr/bin/env bash
# Regression coverage for issue #133: nested menus must step back one level at a
# time ("从哪来就回哪去") instead of jumping to the outermost menu.
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
core_file="$repo_root/src/core.sh"
dns_file="$repo_root/src/dns.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# 多节点修改：选择修改项按 0 回到选择节点，选择节点按 0 才回到节点管理。
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
is_core_bin=/bin/true
mkdir -p "$is_core_dir" "$is_conf_dir/.quan-meta"
for name in node-a node-b; do
    printf '{"inbounds":[{"tag":"%s.json","type":"shadowsocks","listen":"::","listen_port":30001,"method":"aes-128-gcm","password":"nodepassword"}],"outbounds":[{"tag":"direct","type":"direct"}]}\n' "$name" >"$is_conf_dir/$name.json"
    printf '{"outbound_mode":"V4优先"}\n' >"$is_conf_dir/.quan-meta/$name.json.meta.json"
done
net=ss
is_protocol=ss
ss_password=nodepassword
info() {
    get file || return $?
    is_can_change=(0 1 6 14)
    return 0
}
fail() { echo "FAIL(multi-node): $*" >&2; exit 1; }

output=$(printf '1\n0\n0\n' | change 2>&1); status=$?
[[ $status == 2 ]] || fail "选择节点再按 0 才退回节点管理: status=$status output=$output"
[[ $(grep -Fc '选择节点:' <<<"$output") == 2 ]] || fail "选择修改项按 0 应精确退回选择节点: $output"
[[ $(grep -Fc '请选择更改:' <<<"$output") == 1 ]] || fail "选择修改项按 0 不应再次弹出选择修改项: $output"

output=$(printf '1\n3\n0\n0\n0\n' | change 2>&1); status=$?
[[ $status == 2 ]] || fail "加密方式按 0 后退回选择修改项、再逐级退回: status=$status output=$output"
[[ $(grep -Fc '选择加密方式:' <<<"$output") == 1 ]] || fail "加密方式选择页应按 0 退回选择修改项: $output"
[[ $(grep -Fc '请选择更改:' <<<"$output") == 2 ]] || fail "加密方式按 0 应退回选择修改项: $output"
[[ $(grep -Fc '选择节点:' <<<"$output") == 2 ]] || fail "选择修改项按 0 应退回选择节点: $output"
[[ $output != *'已取消添加节点'* ]] || fail "修改流程不应出现添加节点的取消文案: $output"
CASE

# 单节点修改：没有选择节点页，选择修改项按 0 直接退回节点管理。
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
is_core_bin=/bin/true
mkdir -p "$is_core_dir" "$is_conf_dir/.quan-meta"
printf '{"inbounds":[{"tag":"node-a.json","type":"shadowsocks","listen":"::","listen_port":30001,"method":"aes-128-gcm","password":"nodepassword"}],"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_conf_dir/node-a.json"
net=ss
is_protocol=ss
info() {
    get file || return $?
    is_can_change=(0 1)
    return 0
}
fail() { echo "FAIL(single-node): $*" >&2; exit 1; }

output=$(printf '0\n' | change 2>&1); status=$?
[[ $status == 2 ]] || fail "单节点选择修改项按 0 应退回节点管理: status=$status output=$output"
[[ $output != *'选择节点:'* ]] || fail "单节点不应出现选择节点页: $output"
[[ $(grep -Fc '请选择更改:' <<<"$output") == 1 ]] || fail "单节点选择修改项按 0 后不应重画菜单: $output"
CASE

# 修改节点的协议/出口方式/Snell 模式选择页按 0 均退回选择修改项。
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
is_core_bin=/bin/true
mkdir -p "$is_core_dir" "$is_conf_dir/.quan-meta"
for name in node-a node-b; do
    printf '{"inbounds":[{"tag":"%s.json","type":"shadowsocks","listen":"::","listen_port":30001,"method":"aes-128-gcm","password":"nodepassword"}],"outbounds":[{"tag":"direct","type":"direct"}]}\n' "$name" >"$is_conf_dir/$name.json"
    printf '{"outbound_mode":"V4优先"}\n' >"$is_conf_dir/.quan-meta/$name.json.meta.json"
done
net=ss
is_protocol=ss
ss_password=nodepassword
info() {
    get file || return $?
    is_can_change=(0 1 6 14)
    return 0
}
fail() { echo "FAIL(sub-pages): $*" >&2; exit 1; }

# 协议：按 0 退回选择修改项，且不再出现「已取消添加节点」文案。
output=$(printf '1\n1\n0\n0\n0\n' | change 2>&1); status=$?
[[ $status == 2 ]] || fail "协议按 0 后退回选择修改项、再逐级退回: status=$status output=$output"
[[ $(grep -Fc '选择协议:' <<<"$output") == 1 ]] || fail "协议选择页应显示一次: $output"
[[ $(grep -Fc '请选择更改:' <<<"$output") == 2 ]] || fail "协议按 0 应退回选择修改项: $output"
[[ $output != *'已取消添加节点，返回节点管理菜单。'* ]] || fail "修改协议按 0 不应出现添加节点的取消文案: $output"

# 出口方式：按 0 退回选择修改项。
output=$(printf '1\n4\n0\n0\n0\n' | change 2>&1); status=$?
[[ $status == 2 ]] || fail "出口方式按 0 后退回选择修改项、再逐级退回: status=$status output=$output"
[[ $(grep -Fc '选择出口方式:' <<<"$output") == 1 ]] || fail "出口方式选择页应显示一次: $output"
[[ $(grep -Fc '请选择更改:' <<<"$output") == 2 ]] || fail "出口方式按 0 应退回选择修改项: $output"
CASE

# Snell 运行模式选择页按 0 退回选择修改项。
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
is_core_bin=/bin/true
mkdir -p "$is_core_dir" "$is_conf_dir/.quan-meta"
for name in node-a node-b; do
    printf '{"inbounds":[{"tag":"%s.json","type":"snell","listen":"::","listen_port":30002,"version":6,"psk":"generated-password"}],"outbounds":[{"tag":"direct","type":"direct"}]}\n' "$name" >"$is_conf_dir/$name.json"
done
net=snell
is_protocol=snell
is_reality=
info() {
    get file || return $?
    is_can_change=(20)
    return 0
}
fail() { echo "FAIL(snell-mode): $*" >&2; exit 1; }

output=$(printf '1\n1\n0\n0\n0\n' | change 2>&1); status=$?
[[ $status == 2 ]] || fail "Snell 运行模式按 0 后退回选择修改项、再逐级退回: status=$status output=$output"
[[ $(grep -Fc '选择 Snell v6 运行模式:' <<<"$output") == 1 ]] || fail "Snell 运行模式选择页应显示一次: $output"
[[ $(grep -Fc '请选择更改:' <<<"$output") == 2 ]] || fail "Snell 运行模式按 0 应退回选择修改项: $output"
CASE

# 添加 Shadowsocks：选择加密方式按 0 退回选择协议。
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
is_core_bin=/bin/true
mkdir -p "$is_core_dir" "$is_conf_dir/.quan-meta"
is_main_start=1
port=32002
fail() { echo "FAIL(add-ss): $*" >&2; exit 1; }

output=$(printf '8\n0\n8\n0\n0\n' | add 2>&1); status=$?
[[ $status == 2 ]] || fail "选择协议按 0 取消添加应退回节点管理: status=$status output=$output"
[[ $(grep -Fc '选择协议:' <<<"$output") == 3 ]] || fail "选择加密方式按 0 应退回选择协议: $output"
[[ $(grep -Fc '选择加密方式:' <<<"$output") == 2 ]] || fail "重新选择 Shadowsocks 后应再次显示加密方式: $output"
[[ $(grep -Fc '已取消添加节点，返回节点管理菜单。' <<<"$output") == 1 ]] || fail "选择协议按 0 才提示取消添加节点: $output"
[[ -z $(find "$is_conf_dir" -name '*.json' -print -quit) ]] || fail '取消添加不应写入节点配置'
CASE

# DNS 设置：取消自定义输入或取消系统影响确认均退回选择 DNS 列表。
CORE_FILE=$core_file dns_file=$dns_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
source "$dns_file"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
is_config_json=$case_dir/core/config.json
is_core_bin=/bin/true
is_core_ver=1.16.0
mkdir -p "$is_core_dir" "$is_conf_dir"
fail() { echo "FAIL(dns-back): $*" >&2; exit 1; }
reset_config() {
    printf '%s\n' '{"dns":{"servers":[{"tag":"old"}]},"route":{"default_domain_resolver":"old"},"outbounds":[{"tag":"direct","type":"direct"}]}' >"$is_config_json"
    config_before=$(cat "$is_config_json")
}

reset_config
output=$(printf '6\n' | dns_set 2>&1); status=$?
[[ $status == 1 ]] || fail "自定义输入取消后应退回选择 DNS 列表: status=$status output=$output"
[[ $(grep -Fc '请选择 DNS' <<<"$output") == 2 ]] || fail "自定义输入取消应回到选择 DNS: $output"
[[ $(grep -Fc '输入已结束，已取消当前操作。' <<<"$output") == 1 ]] || fail "取消自定义输入应提示一次: $output"
[[ $(cat "$is_config_json") == "$config_before" ]] || fail '取消自定义输入不应改写 DNS 配置'

reset_config
output=$(printf '1\nn\n0\n' | dns_set 2>&1); status=$?
[[ $status == 2 ]] || fail "系统影响确认取消后按 0 退回系统设置: status=$status output=$output"
[[ $(grep -Fc '请选择 DNS' <<<"$output") == 2 ]] || fail "系统影响确认选 N 后应回到选择 DNS: $output"
[[ $(grep -Fc '已取消。' <<<"$output") == 1 ]] || fail "系统影响确认取消应提示一次: $output"
[[ $(cat "$is_config_json") == "$config_before" ]] || fail '取消系统影响确认不应改写 DNS 配置'
CASE

echo 'PASS: nested menus step back one level at a time'
