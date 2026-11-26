#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

init_isolated_env() {
    local name=$1
    local case_dir="$workdir/$name"
    mkdir -p "$case_dir/core/bin" "$case_dir/conf/.quan-meta" "$case_dir/log" "$case_dir/caddy" "$case_dir/bin" "$case_dir/sh/src"
    cp -R "$repo_root/src/." "$case_dir/sh/src/"
    touch "$case_dir/core/qrcode-dependency-checked" "$case_dir/core/bin/tls.cer" "$case_dir/core/bin/tls.key"
    printf '200\n' >"$case_dir/core/log-limit-mb"
    printf '{"log":{"level":"info"},"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$case_dir/core/config.json"

    cat >"$case_dir/core/bin/sing-box" <<'FAKE_CORE'
#!/usr/bin/env bash
case $1 in
version) printf 'sing-box version %s\n' "${FAKE_CORE_VER:-1.50.0}" ;;
check) exit 0 ;;
esac
exit 0
FAKE_CORE
    cat >"$case_dir/bin/apt-get" <<'FAKE_APT'
#!/usr/bin/env bash
exit 0
FAKE_APT
    cat >"$case_dir/bin/systemctl" <<'FAKE_SYS'
#!/usr/bin/env bash
if [[ $1 == show && $* == *caddy.service* ]]; then
    printf 'not-found\n'
    exit 0
fi
if [[ -n ${SERVICE_LOG:-} ]]; then
    printf '%s\n' "$*" >>"$SERVICE_LOG"
fi
if [[ $1 == is-active ]]; then
    [[ $2 == --quiet ]] && exit 0
    printf 'active\n'
    exit 0
fi
exit 0
FAKE_SYS
    cat >"$case_dir/bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
    chmod +x "$case_dir/core/bin/sing-box" "$case_dir/bin/apt-get" "$case_dir/bin/systemctl" "$case_dir/bin/sleep"
    printf '%s\n' "$case_dir"
}

load_case_core() {
    local case_dir=$1
    is_core_dir="$case_dir/core"
    is_conf_dir="$case_dir/conf"
    is_log_dir="$case_dir/log"
    is_sh_dir="$case_dir/sh"
    is_sh_bin="$case_dir/bin/sb"
    is_config_json="$case_dir/core/config.json"
    is_core_bin="$case_dir/core/bin/sing-box"
    is_caddy_dir="$case_dir/caddy"
    is_core_ver=${FAKE_CORE_VER:-1.50.0}
    is_sh_ver=1.50
    export PATH="$case_dir/bin:$PATH"
    source "$case_dir/sh/src/core.sh"
}
export -f load_case_core

run_node_menu_navigation_case() {
    local case_dir
    case_dir=$(init_isolated_env node-menu-nav)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(node-menu-nav): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
: >"$is_conf_dir/node.json"
info() { printf 'unexpected info call\n'; }

output=$(printf 'q\nQ\n99\n\n0\n5\n' | node_menu 2>&1)
for item in '1) 添加' '2) 修改' '3) 查看' '4) 删除' '0) 返回上级'; do
    grep -Fq "$item" <<<"$output" || fail "node menu shows '$item': $output"
done
[[ $output != *$'\n返回\n'* && $output != *'返回节点管理'* ]] || fail "node menu has no legacy return item: $output"
[[ $(grep -Fc '请选择节点操作' <<<"$output") == 5 ]] || fail "each invalid input redraws the complete node menu: $output"
[[ $(grep -Fc '输入无效' <<<"$output") == 4 ]] || fail "q, Q, 99, and Enter each produce one error: $output"
[[ $(grep -Fc '0) 返回上级' <<<"$output") == 5 ]] || fail "the return item is redrawn with every menu: $output"
[[ $output != *'unexpected info call'* ]] || fail 'invalid input or 0 must not run a node action'
CASE
}

run_main_menu_navigation_case() {
    local case_dir
    case_dir=$(init_isolated_env main-menu-nav)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(main-menu-nav): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"

output=$(printf '\n0\nq\n' | is_main_menu 2>&1) || fail 'q exits the main menu successfully'
[[ $(grep -Fc '已在主菜单' <<<"$output") == 2 ]] || fail "Enter and 0 both explain that the main menu has no parent: $output"
[[ $(grep -Fc 'q 退出' <<<"$output") == 3 ]] || fail "every main menu prompt names q as the exit command: $output"
[[ $(grep -Fc 'one-singbox script' <<<"$output") == 3 ]] || fail "Enter and 0 redraw the complete main menu: $output"
[[ $output != *'0) 返回上级'* ]] || fail "the main menu must not show a parent return item: $output"

output=$(printf 'Q\n' | is_main_menu 2>&1) || fail 'uppercase Q exits the main menu'
[[ $(grep -Fc 'one-singbox script' <<<"$output") == 1 ]] || fail "Q exits without another redraw: $output"
CASE
}

run_node_change_menu_return_case() {
    local case_dir
    case_dir=$(init_isolated_env node-change-return)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(node-change-return): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
info() { is_can_change=(0 1); }

output=$(printf '0\n' | change sample.json 2>&1); status=$?
[[ $status == 2 ]] || fail "0 returns from the node change menu: status=$status output=$output"
[[ $output == *'0) 返回上级'* ]] || fail "node change menu shows the shared return item: $output"
[[ $output == *'协议'* && $output == *'监听端口'* ]] || fail "node change choices remain visible in order: $output"
[[ $output != *'返回节点管理'* ]] || fail "node change menu has no legacy return item: $output"
CASE
}

run_outbound_selection_case() {
    local case_dir
    case_dir=$(init_isolated_env outbound-sel)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(outbound-sel): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
is_config_file=node.json
cat >"$is_conf_dir/.quan-meta/node.json.meta.json" <<'JSON'
{"outbound_mode":"SS 出站","outbound_proxy":{"name":"test-ss","config":{"type":"shadowsocks","server":"proxy.example","server_port":8388,"method":"aes-128-gcm","password":"secret"}}}
JSON
apply_node_outbound_mode() { printf 'applied:%s\n' "$2"; }

output=$(printf '0\n' | edit_node_outbound_mode 2>&1); status=$?
[[ $status == 2 ]] || fail "0 returns from outbound selection: status=$status output=$output"
[[ $output == *'0) 返回上级'* ]] || fail "outbound selection shows the shared return item: $output"
[[ $output == *'IPv6 优先'* && $output == *'Shadowsocks 出口'* && $output == *'VLESS 出口'* ]] || fail "outbound choices remain visible: $output"
[[ $output != *'applied:'* ]] || fail "0 must not apply an outbound mode: $output"

invalid_output=$(printf '99\n0\n' | edit_node_outbound_mode 2>&1); status=$?
[[ $status == 2 ]] || fail "invalid then 0 returns from outbound selection: status=$status output=$invalid_output"
[[ $(grep -Fc 'IPv6 优先' <<<"$invalid_output") == 2 ]] || fail "invalid input redraws the full outbound menu: $invalid_output"
[[ $(grep -Fc '0) 返回上级' <<<"$invalid_output") == 2 ]] || fail "invalid input redraws the return item: $invalid_output"
[[ $(grep -Fc '输入无效' <<<"$invalid_output") == 1 ]] || fail "invalid input prints one error per attempt: $invalid_output"

selected=$(printf '5\n\n' | edit_node_outbound_mode 2>&1); status=$?
[[ $status == 0 ]] || fail "outbound option 5 still applies: status=$status output=$selected"
[[ $selected == *'applied:SS 出站'* ]] || fail "outbound option 5 keeps its business mapping: $selected"
CASE
}

run_ss_method_selection_case() {
    local case_dir
    case_dir=$(init_isolated_env ss-method)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(ss-method): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"

ask() { fail 'numbered SS method selection must use menu_select parent'; }
info() {
    is_config_file=node.json
    net=ss
    is_protocol=ss
    ss_password=old-secret
    return 0
}
get() { printf 'generated-password'; }
get_uuid() { tmp_uuid=22222222-2222-4222-8222-222222222222; }
node_port_used() { return 1; }
create() { printf 'created:%s\n' "$ss_method"; }
meta_set() { :; }
is_random_ss_method=2022-blake3-aes-128-gcm

assert_ss_method_menu_redrawn() {
    local method output=$1 context=$2
    [[ $(grep -Fc '选择加密方式:' <<<"$output") == 2 ]] || fail "$context redraws the SS method prompt: $output"
    [[ $(grep -Fc '回车默认 2022-blake3-aes-128-gcm' <<<"$output") == 2 ]] || fail "$context keeps the SS method default visible: $output"
    for method in "${ss_method_list[@]}"; do
        [[ $(grep -Fc ") $method" <<<"$output") == 2 ]] || fail "$context redraws the complete SS method list: $output"
    done
}

(
    add() { printf 'changed:%s\n' "$is_new_method"; }
    return_output=$(unset ss_method; printf '0\n' | change node.json method 2>&1); status=$?
    [[ $status == 2 ]] || fail "0 returns from the SS method change selector: status=$status output=$return_output"
    [[ $return_output == *'0) 返回上级'* && $return_output == *'aes-128-gcm'* && $return_output == *'2022-blake3-chacha20-poly1305'* ]] || fail "SS method choices remain visible: $return_output"
    [[ $return_output != *'changed:'* ]] || fail "0 must not change the SS method: $return_output"

    empty_output=$(unset ss_method; printf '\n0\n' | change node.json method 2>&1); status=$?
    [[ $status == 2 ]] || fail "Enter is invalid and 0 returns from the SS method change selector: status=$status output=$empty_output"
    assert_ss_method_menu_redrawn "$empty_output" "empty Enter in change mode"
    [[ $(grep -Fc '输入无效' <<<"$empty_output") == 1 ]] || fail "empty Enter prints one SS method error: $empty_output"
    [[ $empty_output != *'changed:'* ]] || fail "empty Enter must not select the SS method default: $empty_output"

    selected_output=$(unset ss_method; printf '1\n' | change node.json method 2>&1); status=$?
    [[ $status == 0 && $selected_output == *'changed:aes-128-gcm'* ]] || fail "SS method numeric selection keeps its mapping: status=$status output=$selected_output"
) || exit 1

add_return=$(unset ss_method; is_main_start=1; port=32002; printf '0\n' | add shadowsocks 2>&1); status=$?
[[ $status == 2 ]] || fail "0 returns from the SS method add selector: status=$status output=$add_return"
[[ $add_return == *'0) 返回上级'* ]] || fail "SS add shows the shared return item: $add_return"
[[ $add_return != *'created:'* ]] || fail "0 must not create a Shadowsocks node: $add_return"

add_empty=$(unset ss_method; is_main_start=1; port=32002; ss_password=generated-password; printf '\n0\n' | add shadowsocks 2>&1); status=$?
[[ $status == 2 ]] || fail "Enter is invalid and 0 returns from the SS method add selector: status=$status output=$add_empty"
assert_ss_method_menu_redrawn "$add_empty" "empty Enter in add mode"
[[ $(grep -Fc '输入无效' <<<"$add_empty") == 1 ]] || fail "empty Enter prints one SS add method error: $add_empty"
[[ $add_empty != *'created:'* ]] || fail "empty Enter must not create an SS node with the default method: $add_empty"

quick_output=$(unset ss_method; is_main_start=; port=; ss_password=; printf '' | add shadowsocks 32003 secret aes-128-gcm 2>&1); status=$?
[[ $status == 0 && $quick_output == *'created:aes-128-gcm'* ]] || fail "SS quick arguments bypass the selector: status=$status output=$quick_output"
CASE
}

run_snell_selection_case() {
    local case_dir
    case_dir=$(init_isolated_env snell-sel)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(snell-sel): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"

ask() { fail 'numbered Snell selection must use menu_select parent'; }
add() { printf 'added:mode=%s:obfs=%s\n' "$snell_mode" "$snell_obfs_mode"; }
info() {
    is_config_file=node.json
    net=snell
    is_protocol=snell
    snell_version=$SCENARIO_VERSION
    snell_psk=0123456789ab
    return 0
}

for spec in '19|6|unshaped|运行模式' '19|5|http|混淆模式' '20|5|http|混淆模式' '20|6|unsafe-raw|运行模式'; do
    IFS='|' read -r change_id version expected_label label <<<"$spec"
    SCENARIO_VERSION=$version
    if [[ $change_id == 19 ]]; then change_alias=obfs; else change_alias=mode; fi
    output=$(printf '0\n' | change node.json "$change_alias" 2>&1); status=$?
    [[ $status == 2 ]] || fail "Snell v$version $label 0 returns: status=$status output=$output"
    [[ $output == *'0) 返回上级'* && $output == *"$expected_label"* ]] || fail "Snell v$version $label choices remain visible: $output"
    [[ $output != *'added:'* ]] || fail "Snell v$version $label 0 must not update the node: $output"
    [[ $(grep -Fc '0) 返回上级' <<<"$output") == 1 ]] || fail "Snell v$version $label shows one shared return item: $output"
done

SCENARIO_VERSION=6
quick_output=$(change node.json mode default 2>&1); status=$?
[[ $status == 0 && $quick_output == *'added:mode=default:obfs='* ]] || fail "Snell mode shortcut bypasses the selector: status=$status output=$quick_output"
CASE
}

run_node_selector_return_case() {
    local case_dir
    case_dir=$(init_isolated_env node-sel-return)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(node-sel-return): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
: >"$is_conf_dir/node-a.json"
: >"$is_conf_dir/node-b.json"
cat >"$is_conf_dir/relay-10000.json" <<'JSON'
{"inbounds":[{"tag":"relay-10000.json","type":"direct","listen":"::","listen_port":10000,"override_address":"203.0.113.60","override_port":20060}]}
JSON

output=$(printf '0\n' | get file 2>&1); status=$?
[[ $status == 2 ]] || fail "0 returns from node selection: status=$status output=$output"
[[ $output == *'0) 返回上级'* ]] || fail "node selection shows the shared return item: $output"
[[ $output == *'node-a.json'* && $output == *'node-b.json'* ]] || fail "node selection keeps all node choices: $output"
[[ $output != *'relay-10000.json'* ]] || fail "node selection must exclude relay configs: $output"
[[ -z $is_config_file ]] || fail "0 must not select a node: $is_config_file"
CASE
}

run_empty_node_case() {
    local case_dir
    case_dir=$(init_isolated_env empty-node)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(empty-node): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
info() { printf 'unexpected info call\n'; }

output=$(printf '3\n\n0\n' | node_menu 2>&1)
[[ $output == *'暂无节点，请先添加'* ]] || fail "empty node state is explained: $output"
[[ $output != *'尚未添加任何节点'* ]] || fail "empty node state uses the concise prompt: $output"
for item in '1) 添加' '2) 修改' '3) 查看' '4) 删除' '0) 返回上级'; do
    grep -Fq "$item" <<<"$output" || fail "node menu shows $item: $output"
done
[[ $output != *$'\n返回\n'* ]] || fail "node menu has no legacy return item: $output"
[[ $output == *'按回车返回菜单'* ]] || fail "empty node state remains visible until return: $output"
[[ $output == *'unexpected info call'* ]] && fail 'empty node state must not enter node details'
[[ $(grep -o '请选择节点操作' <<<"$output" | wc -l) == 2 ]] || fail "empty state returns to node menu: $output"
CASE
}

run_empty_relay_case() {
    local case_dir
    case_dir=$(init_isolated_env empty-relay)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(empty-relay): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
is_main_start=1

output=$(printf '2\n\n0\n5\n' | relay_menu 2>&1)
[[ $output == *'暂无端口转发，请先添加'* ]] || fail "empty relay state is explained: $output"
for item in '1) 添加' '2) 查看' '3) 备注' '4) 删除'; do
    grep -Fq "$item" <<<"$output" || fail "relay menu missing item '$item': $output"
done
[[ $output != *'列表'* ]] || fail "relay menu should not split redundant list/view items: $output"
[[ $output == *'0) 返回上级'* ]] || fail "relay menu shows the shared return item: $output"
[[ $output == *'按回车返回菜单'* ]] || fail "empty relay state remains visible until return: $output"
[[ $(grep -o '请选择端口转发操作' <<<"$output" | wc -l) == 2 ]] || fail "empty state returns to relay menu: $output"
[[ -z $(find "$is_conf_dir" -type f -print -quit) ]] || fail 'empty relay listing must not change configuration'
CASE
}

run_relay_add_copy_case() {
    local case_dir
    case_dir=$(init_isolated_env relay-add-copy)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(relay-add-copy): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
node_port_used() { return 1; }
get_port() { tmp_port=12000; }
is_main_start=1

output=$(printf '1\n\n203.0.113.50\n20050\n\n\n0\n5\n' | relay_menu 2>&1)
[[ $output == *'输入监听端口'* && $output == *'回车自动分配'* ]] || fail "add explains the auto-assigned listener port: $output"
[[ $output == *'输入目标地址'* && $output == *'输入目标端口'* ]] || fail "add labels both target inputs: $output"
[[ $output == *'自动分配本地端口: 12000'* ]] || fail "Enter still selects and reports the automatic listener port: $output"
jq -e '.inbounds[0].listen_port == 12000 and .inbounds[0].override_address == "203.0.113.50" and .inbounds[0].override_port == 20050' "$is_conf_dir/relay-12000.json" >/dev/null || fail 'add keeps listener port, target address, and target port mapped to their existing fields'
CASE
}

run_relay_view_copy_case() {
    local case_dir
    case_dir=$(init_isolated_env relay-view-copy)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(relay-view-copy): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
cat >"$is_conf_dir/relay-10000.json" <<'JSON'
{"inbounds":[{"listen_port":10000,"override_address":"203.0.113.60","override_port":20060}]}
JSON
is_main_start=1
is_port_used() { [[ $1 == 10000 ]] && printf '10000\n'; }

output=$(printf '2\n\n0\n5\n' | relay_menu 2>&1)
[[ $output == *'监听端口 10000 -> 目标 203.0.113.60:20060 (TCP/UDP)'* ]] || fail "view displays the relay list directly: $output"
[[ $output != *'输入要查看的监听端口'* ]] || fail "menu view must not re-prompt for listener port: $output"
[[ $output != *'无法使用'* ]] || fail "menu view must not reject listening relay port: $output"

info_out=$(printf '1\n' | relay_info 2>&1); status=$?
[[ $status == 0 ]] || fail "interactive relay_info selection failed: status=$status output=$info_out"
[[ $info_out == *'0) 返回上级'* ]] || fail "interactive relay_info must offer return/exit option: $info_out"
[[ $info_out == *'监听端口: 10000'* && $info_out == *'目标地址: 203.0.113.60'* && $info_out == *'目标端口: 20060'* ]] || fail "interactive relay_info displays selected relay details: $info_out"
[[ $info_out != *'无法使用'* ]] || fail "interactive relay_info must not check port_used on listening relay: $info_out"

cancel_out=$(printf '0\n' | relay_info 2>&1); status=$?
[[ $status == 0 ]] || fail "interactive relay_info return option failed: status=$status output=$cancel_out"
[[ $cancel_out != *'端口转发配置信息'* ]] || fail "returning from interactive relay_info must not display details: $cancel_out"
CASE
}

run_relay_delete_cancel_case() {
    local case_dir
    case_dir=$(init_isolated_env relay-del-cancel)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(relay-del-cancel): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
cat >"$is_conf_dir/relay-10000.json" <<'JSON'
{"inbounds":[{"listen_port":10000,"override_address":"203.0.113.60","override_port":20060}]}
JSON
is_main_start=1

output=$(printf '4\n10000\nn\n\n0\n5\n' | relay_menu 2>&1)
[[ $output == *'输入要删除的监听端口'* ]] || fail "delete requests the listener port by name: $output"
[[ $output == *'监听端口 10000'* && $output == *'转发'* && $output == *'[y/N]'* ]] || fail "confirmation identifies the forwarding rule and preserves its yes/no prompt: $output"
[[ $output == *'已取消删除端口转发'* ]] || fail "cancel is reported without deleting the relay: $output"
[[ -f "$is_conf_dir/relay-10000.json" ]] || fail 'canceling deletion preserves the relay configuration'

output=$(printf '4\n10000\ny\n\n0\n5\n' | relay_menu 2>&1)
[[ $output == *'将删除监听端口 10000 → 203.0.113.60:20060 的端口转发'* && $output == *'删除范围包括配置文件'* && $output == *'不影响其他端口转发'* && $output == *'重启 sing-box'* ]] || fail "confirmed deletion explains the forwarding target and scope: $output"
[[ $output == *'已删除端口转发配置: relay-10000.json'* ]] || fail "confirming deletion removes the selected forwarding rule: $output"
[[ ! -f "$is_conf_dir/relay-10000.json" ]] || fail 'confirmed deletion removes only the selected relay configuration'
CASE
}

run_service_result_case() {
    local case_dir
    case_dir=$(init_isolated_env service-result)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(service-result): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"

output=$(printf '2\n\n0\n6\n' | service_menu 2>&1)
[[ $output == *'启动服务成功'* ]] || fail "service result is displayed: $output"
[[ $output == *'按回车返回菜单'* ]] || fail "service result stays readable before the next menu: $output"
[[ $(grep -o '请选择服务操作' <<<"$output" | wc -l) == 2 ]] || fail "service action returns to its menu: $output"
CASE
}

run_narrow_terminal_case() {
    local case_dir
    case_dir=$(init_isolated_env narrow-term)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(narrow-term): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
service_action_result() { printf '启动服务结果：当前状态已确认。\n'; }

export COLUMNS=20
output=$(printf '2\n\n0\n6\n' | service_menu 2>&1)
[[ $output == *'启动服务结果：当前状态已确认。'* ]] || fail "service result stays complete: $output"
pause_width=$(grep -F '按回车返回菜单。' <<<"$output" | wc -L)
[[ $pause_width =~ ^[0-9]+$ && $pause_width -le 20 ]] || fail "pause guidance fits a 20-column terminal (width $pause_width)"
CASE
}

run_kernel_management_copy_case() {
    local case_dir
    case_dir=$(init_isolated_env kernel-copy)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(kernel-copy): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"

action_file=$CASE_DIR/actions
core_status_read() { is_core_ver=1.50; is_core_status=运行中; is_caddy_status=已停止; is_caddy_ver=2.10; }
service_action_result() { printf '%s\n' "$1" >>"$action_file"; printf '%s 服务结果\n' "$1"; }
log_set() { printf 'log\n' >>"$action_file"; }
load() { [[ $1 == log.sh ]] && return 0; }

is_caddy=1
output=$(printf '1\n\n2\n\n3\ny\n\n4\ny\n\n5\n\n0\n6\n' | service_menu 2>&1)
for item in '1) 状态' '2) 启动' '3) 停止' '4) 重启' '5) 日志'; do
    grep -Fq "$item" <<<"$output" || fail "kernel menu missing '$item': $output"
done
[[ $output == *'sing-box 内核：运行中 (版本 1.50)'* && $output == *'Caddy：已停止 (版本 2.10)'* ]] || fail "status identifies sing-box kernel and Caddy: $output"
[[ $(cat "$action_file") == $'start\nstop\nrestart\nlog' ]] || fail "kernel menu choices retain their actions: $(cat "$action_file")"

is_caddy=
output=$(printf '1\n\n0\n6\n' | service_menu 2>&1)
[[ $output == *'sing-box 内核：运行中 (版本 1.50)'* ]] || fail "status keeps the kernel when Caddy is absent: $output"
[[ $output != *'Caddy：'* ]] || fail "status hides Caddy when it is not installed: $output"
CASE
}

run_update_copy_case() {
    local case_dir
    case_dir=$(init_isolated_env update-copy)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(update-copy): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
update_file=$CASE_DIR/updates
update() { printf '%s\n' "$*" >>"$update_file"; }

is_caddy=1
output=$(printf '1\ny\n\n2\ny\n\n3\ny\n\n0\n4\n' | update_menu 2>&1)
for item in '1) 更新 sing-box 内核' '2) 更新脚本' '3) 更新 Caddy'; do
    grep -Fq "$item" <<<"$output" || fail "update menu missing '$item': $output"
done
[[ $(cat "$update_file") == $'1\n2\ncaddy' ]] || fail "installed update choices keep their targets: $(cat "$update_file")"
[[ $output == *'更新脚本'* ]] || fail "update menu text is visible: $output"

: >"$update_file"
is_caddy=
output=$(printf '1\ny\n\n2\ny\n\n0\n3\n' | update_menu 2>&1)
grep -Fq '1) 更新 sing-box 内核' <<<"$output" || fail "update menu missing core choice: $output"
grep -Fq '2) 更新脚本' <<<"$output" || fail "update menu missing script choice: $output"
[[ $output != *'更新 Caddy'* ]] || fail "update menu hides Caddy when not installed: $output"
[[ $(cat "$update_file") == $'1\n2' ]] || fail "without Caddy, update choices still target core and script: $(cat "$update_file")"
CASE
}

run_home_return_case() {
    local menu_choice=${1:-1}
    local case_dir
    case_dir=$(init_isolated_env "home-return-$menu_choice")
    CASE_DIR="$case_dir" MENU_CHOICE="$menu_choice" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(home-return-$MENU_CHOICE): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"

[[ ${mainmenu[4]} == '系统设置' ]] || fail "home system settings label is clear: ${mainmenu[4]}"
[[ ${mainmenu[5]} == '帮助反馈' ]] || fail "home help label is clear: ${mainmenu[5]}"
[[ ${mainmenu[6]} == '关于' ]] || fail "home about label is clear: ${mainmenu[6]}"
[[ ${mainmenu[7]} == '卸载' ]] || fail "home uninstall label is clear: ${mainmenu[7]}"

case $MENU_CHOICE in
1) input=$'1\n0\nq\n' ;;
2) input=$'2\n0\nq\n' ;;
3) input=$'3\n0\nq\n' ;;
4) input=$'4\n0\nq\n' ;;
5) input=$'5\n0\nq\n' ;;
6) input=$'1\n\n0\nq\n' ;;
esac
output=$(printf '%s' "$input" | is_main_menu 2>&1)
[[ ${mainmenu[2]} == '内核管理' && ${mainmenu[3]} == '更新' ]] || fail "home labels distinguish kernel management and updates: ${mainmenu[*]}"
[[ ${mainmenu[1]} == '端口转发' ]] || fail "home labels relay management as port forwarding: ${mainmenu[1]}"
if [[ $MENU_CHOICE == 2 ]]; then
    [[ $output == *'请选择端口转发操作'* ]] || fail "home choice 2 still opens relay management: $output"
fi
[[ $output != *'443 SNI 前置'* ]] || fail "home must not offer Nginx frontend management: $output"
[[ $output == *'q 退出'* ]] || fail "home clearly explains that q exits: $output"
[[ $output != *'回车退出'* ]] || fail "home no longer exits on Enter: $output"
[[ $(grep -o 'one-singbox script' <<<"$output" | wc -l) == 2 ]] || fail "returning from a child menu goes back to home: $output"
if [[ $MENU_CHOICE == 6 ]]; then
    [[ $output == *'输入无效'* ]] || fail "blank input in a child menu is not exit: $output"
fi
CASE
}

run_system_settings_case() {
    local case_dir
    case_dir=$(init_isolated_env sys-settings)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(sys-settings): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"

load() {
    case $1 in
    bbr.sh) _try_enable_bbr() { printf '已执行：启用 BBR\n'; } ;;
    dns.sh) dns_set() { printf '已执行：DNS\n'; } ;;
    *) . "$is_sh_dir/src/$1" ;;
    esac
}
log_limit_set() { printf '已执行：日志上限\n'; }
block_cn_menu_toggle() { printf '已执行：屏蔽回国流量\n'; }
get() { printf '已执行：重装脚本\n'; }

output=$(printf '1\ny\n\n2\n\n3\n\n4\ny\n\n5\n\n0\n6\n' | system_tools_menu 2>&1)
for label in '启用 BBR' 'DNS' '日志上限' '屏蔽回国流量' '重装脚本'; do
    [[ $output == *"$label"* ]] || fail "system settings show '$label': $output"
done
[[ $output != *$'\n返回\n'* ]] || fail "system settings have no legacy return item: $output"
[[ $output == *'0) 返回上级'* ]] || fail "system settings show the shared return item: $output"
[[ $output == *'请选择系统设置'* ]] || fail "system settings prompt uses its menu name: $output"
for result in '已执行：启用 BBR' '已执行：DNS' '已执行：日志上限' '已执行：屏蔽回国流量' '已执行：重装脚本'; do
    [[ $output == *"$result"* ]] || fail "system setting choices keep the visible action '$result': $output"
done
CASE
}

run_dns_display_mapping_case() {
    local case_dir
    case_dir=$(init_isolated_env dns-mapping)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(dns-mapping): $*" >&2; exit 1; }
export SERVICE_LOG="$CASE_DIR/service.log"
load_case_core "$CASE_DIR"
load dns.sh
is_core_ver=1.16.0

printf '%s\n' '{"dns":{"servers":[{"tag":"old"}]},"route":{"default_domain_resolver":"old"},"outbounds":[{"tag":"direct","type":"direct"}]}' >"$is_config_json"
output=$(printf '6\nh3://dns.google/dns-query\ny\n' | dns_set 2>&1)
for address in 1.1.1.1 8.8.8.8 h3://dns.google/dns-query h3://cloudflare-dns.com/dns-query h3://family.cloudflare-dns.com/dns-query; do
    [[ $output == *"$address"* ]] || fail "DNS menu retains service address '$address': $output"
done
[[ $output == *'自定义'* ]] || fail "DNS menu names custom DNS in Chinese: $output"
[[ $output != *') set'* && $output != *') none'* ]] || fail "DNS menu hides internal option names: $output"
jq -e '.dns.servers[0].type == "h3" and .dns.servers[0].server == "dns.google" and .route.default_domain_resolver == "dns"' "$is_config_json" >/dev/null || fail 'custom DNS selection still applies the entered address'
[[ $output != *'已更新 DNS 为: none'* ]] || fail "custom DNS success output does not expose an internal option name: $output"

printf '%s\n' '{"dns":{"servers":[{"tag":"old"}]},"route":{"default_domain_resolver":"old"},"outbounds":[{"tag":"direct","type":"direct"}]}' >"$is_config_json"
output=$(printf '7\ny\n' | dns_set 2>&1)
[[ $output == *'不设置'* ]] || fail "DNS menu names the disabled option in Chinese: $output"
[[ $output != *') set'* && $output != *') none'* ]] || fail "DNS menu hides internal option names: $output"
jq -e '.dns == {} and (.route | has("default_domain_resolver") | not)' "$is_config_json" >/dev/null || fail 'no-DNS selection still removes DNS configuration'
[[ $output == *'已更新 DNS 为: '*'不设置'* ]] || fail "no-DNS result uses the display name: $output"

printf '%s\n' '{"dns":{"servers":[{"tag":"old"}]},"route":{"default_domain_resolver":"old"},"outbounds":[{"tag":"direct","type":"direct"}]}' >"$is_config_json"
output=$(dns_set none 2>&1)
[[ $output == *'已更新 DNS 为: '*'none'* ]] || fail "CLI DNS success output keeps the argument value: $output"
[[ $output != *'已更新 DNS 为: '*'不设置'* ]] || fail "CLI DNS success output does not use interactive display copy: $output"

printf '%s\n' '{"dns":{"servers":[{"tag":"keep"}]},"route":{"default_domain_resolver":"keep"},"outbounds":[{"tag":"direct","type":"direct"}]}' >"$is_config_json"
: >"$SERVICE_LOG"
config_before=$(cat "$is_config_json")
output=$(printf '0\n7\n' | dns_set 2>&1); status=$?
[[ $status == 2 ]] || fail "0 returns from the DNS menu: status=$status output=$output"
[[ $output == *'0) 返回上级'* ]] || fail "DNS menu shows the shared return item: $output"
[[ $(cat "$is_config_json") == "$config_before" ]] || fail '0 must not modify DNS configuration'
[[ ! -s $SERVICE_LOG ]] || fail '0 must not restart services'
CASE
}

run_interactive_help_case() {
    local case_dir
    case_dir=$(init_isolated_env interactive-help)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(interactive-help): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"

output=$(printf '6\n\nq\n' | is_main_menu 2>&1)
[[ $output == *'命令行帮助'* ]] || fail "interactive help identifies itself as command-line help: $output"
[[ $output == *'Usage: sing-box [options]'* ]] || fail "interactive help still shows command usage: $output"
CASE
}

run_uninstall_copy_case() {
    local case_dir
    case_dir=$(init_isolated_env uninstall-copy)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(uninstall-copy): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
confirm_exact_yes() {
    confirmation=$1
    printf '%s [仅输入 YES 确认]: ' "$1"
    return 1
}

run_case() {
    local caddy=$1 choice=$2 expected_label=$3
    is_caddy=$caddy
    confirmation=
    if [[ $caddy ]]; then
        output=$(printf '%s\n' "$choice" | uninstall 2>&1)
    else
        output=$(uninstall </dev/null 2>&1)
    fi
    if [[ $caddy ]]; then
        [[ $output == *'卸载内核和脚本'* ]] || fail "uninstall choice explains core and script: $output"
        [[ $output == *'全部卸载'* ]] || fail "uninstall choice explains full removal: $output"
        [[ $output != *'仅卸载 sing-box 和 one-singbox'* && $output != *'卸载 sing-box、one-singbox 和 Caddy'* ]] || fail "uninstall choices use concise labels: $output"
    else
        [[ $output != *'全部卸载'* ]] || fail "full uninstall is only shown when Caddy exists: $output"
    fi
    [[ $output == *"$expected_label"* ]] || fail "selected uninstall confirms '$expected_label': $output"
    [[ $output == *'已取消卸载。'* ]] || fail "declining uninstall cancels before changes: $output"
}

run_case 1 1 'one-singbox 程序、脚本和快捷命令'
[[ $output == *'Caddy 服务、程序及 /etc/caddy 安装和配置目录保留，不删除'* ]] || fail "core-and-script uninstall explains that Caddy is preserved: $output"
run_case 1 2 'Caddy'
[[ $output == *'Caddy 服务'* ]] || fail "full uninstall confirms Caddy service removal: $output"
[[ $output == *'/etc/caddy'* ]] || fail "full uninstall confirms the Caddy directory scope: $output"
run_case '' '' 'one-singbox 程序、脚本和快捷命令'
CASE
}

run_caddy_uninstall_selection_case() {
    local case_dir
    case_dir=$(init_isolated_env caddy-uninstall)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(caddy-uninstall): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
ask() { fail 'numbered Caddy uninstall scope must use menu_select parent'; }
confirm_exact_yes() { fail '0 must not continue to uninstall confirmation'; }
manage() { fail '0 must not change services'; }
log_limit_remove() { fail '0 must not remove logs'; }
is_caddy=1

output=$(printf '0\n' | uninstall 2>&1); status=$?
[[ $status == 2 ]] || fail "0 returns from Caddy uninstall scope: status=$status output=$output"
[[ $output == *'0) 返回上级'* ]] || fail "Caddy uninstall scope shows the shared return item: $output"
[[ $output == *'1) 卸载内核和脚本'* && $output == *'2) 全部卸载'* ]] || fail "Caddy uninstall scope keeps business numbering: $output"
CASE
}

run_log_limit_prompt_case() {
    local case_dir
    case_dir=$(init_isolated_env log-limit-prompt)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(log-limit-prompt): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
load log.sh
printf '125\n' >"$is_core_dir/log-limit-mb"
log_limit_service() { fail 'pressing Enter must not restart the log service'; }
limit_before=$(log_limit_read)
prompt_output=$(log_limit_set <<<'' 2>&1)
[[ $prompt_output == *'输入日志上限'* && $prompt_output == *'单位 MB'* && $prompt_output == *'回车保留当前值'* ]] || fail "log limit prompt explains the value, units, and Enter behavior: $prompt_output"
[[ $(log_limit_read) == "$limit_before" ]] || fail 'pressing Enter preserves the configured limit'
CASE
}

run_child_back_case() {
    local case_dir
    case_dir=$(init_isolated_env child-back)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(child-back): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
is_main_menu() { main_calls=$((main_calls + 1)); }
update() { update_calls=$((update_calls + 1)); }

main_calls=0
update_calls=0
update_menu <<<"0" >/dev/null 2>&1
[[ $main_calls == 0 ]] || fail 'update menu back must return to its caller'
[[ $update_calls == 0 ]] || fail 'returning from update menu must not update anything'

system_tools_menu <<<"0" >/dev/null 2>&1
[[ $main_calls == 0 ]] || fail 'system tools back must return to its caller'
CASE
}

run_protocol_cancel_case() {
    local case_dir
    case_dir=$(init_isolated_env proto-cancel)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(proto-cancel): $*" >&2; exit 1; }
export SERVICE_LOG="$CASE_DIR/service.log"
: >"$SERVICE_LOG"
load_case_core "$CASE_DIR"
is_main_start=1
port=23456
host=203.0.113.10
uuid=123e4567-e89b-12d3-a456-426614174000
node_port_used() { return 1; }
get_snell_psk() { printf '0123456789ab'; }
validate_snell() { return 0; }
create() { is_config_name=zero-node.json; }
info() { :; }

expected_protocols=(TUIC Trojan Hysteria2 VMess-WS VMess-TCP VMess-HTTP VMess-QUIC Shadowsocks VMess-H2-TLS VMess-WS-TLS VLESS-H2-TLS VLESS-WS-TLS Trojan-H2-TLS Trojan-WS-TLS VMess-HTTPUpgrade-TLS VLESS-HTTPUpgrade-TLS Trojan-HTTPUpgrade-TLS VLESS-REALITY VLESS-HTTP2-REALITY AnyTLS Socks Snell)
[[ ${protocol_list[*]} == "${expected_protocols[*]}" ]] || fail "existing protocol order changed: ${protocol_list[*]}"

cancel_choice=$((${#protocol_list[@]} + 1))
output=$(printf '0\n%s\n1\nsample-node\n' "$cancel_choice" | add 2>&1); status=$?
[[ $status == 2 ]] || fail "0 returns from protocol selection: status=$status output=$output"
[[ $output == *'0) 返回上级'* ]] || fail "protocol list shows the shared return item: $output"
[[ $output != *$'\n返回节点管理\n'* ]] || fail "protocol list has no legacy return item: $output"
[[ $output == *'已取消添加节点'* ]] || fail "canceling protocol selection returns without adding: $output"
[[ -z $(find "$is_conf_dir" -maxdepth 1 -type f -print -quit) ]] || fail 'canceling protocol selection must not change configuration'
[[ ! -s $SERVICE_LOG ]] || fail 'canceling protocol selection must not change services'

output=$(printf '22\n0\n\n' | add 2>&1) || fail "node name 0 must be accepted: $output"
[[ $(jq -r '.node_name' "$is_conf_dir/.quan-meta/zero-node.json.meta.json") == '0' ]] || fail "node name 0 must be stored verbatim"
CASE
}

run_cli_relay_list_case() {
    local case_dir
    case_dir=$(init_isolated_env cli-relay-list)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(cli-relay-list): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
output=$(main relay list 2>&1) || fail "relay list CLI succeeds: $output"
[[ $output == *'当前未配置任何端口转发'* ]] || fail "relay list CLI keeps its output: $output"
[[ $output != *'按回车返回'* ]] || fail 'noninteractive relay list must not pause'
CASE
}

run_cli_add_case() {
    local case_dir
    case_dir=$(init_isolated_env cli-add)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(cli-add): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
ask() { ask_calls=$((ask_calls + 1)); }
add() { add_args="$*"; }
ask_calls=0
add_args=

main add reality 443 sample-uuid example.com
[[ $add_args == 'reality 443 sample-uuid example.com' ]] || fail "noninteractive add arguments are preserved: $add_args"
[[ $ask_calls == 0 ]] || fail 'noninteractive add must not ask for a protocol choice'
CASE
}

run_log_exit_prompt_case() {
    local case_dir
    case_dir=$(init_isolated_env log-exit-prompt)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(log-exit-prompt): $*" >&2; exit 1; }
cat >"$CASE_DIR/bin/tail" <<'FAKE_TAIL'
#!/usr/bin/env bash
printf 'log stream started\n'
FAKE_TAIL
chmod +x "$CASE_DIR/bin/tail"
load_case_core "$CASE_DIR"
touch "$is_log_dir/access.log"

output=$(main log 2>&1)
[[ $output == *'按 '*'Ctrl+C'*'退出'* ]] || fail "log exit prompt names the Ctrl+C shortcut: $output"
[[ $output == *'log stream started'* ]] || fail "log streaming remains active after the prompt: $output"
CASE
}

run_log_missing_cli_case() {
    local case_dir
    case_dir=$(init_isolated_env log-missing-cli)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(log-missing-cli): $*" >&2; exit 1; }
load_case_core "$CASE_DIR"
is_terminal_log_view=

output=$(main log 2>&1)
status=$?
[[ $status != 0 ]] || fail 'missing log must fail in CLI mode'
[[ $output == *'无法找到 log 文件'* ]] || fail "missing log failure is visible: $output"
[[ $output != *'按回车返回'* ]] || fail 'missing log CLI failure must not pause'
CASE
}

run_node_menu_navigation_case
run_main_menu_navigation_case
run_node_change_menu_return_case
run_node_selector_return_case
run_outbound_selection_case
run_ss_method_selection_case
run_snell_selection_case
run_empty_node_case
run_empty_relay_case
run_relay_add_copy_case
run_relay_view_copy_case
run_relay_delete_cancel_case
run_service_result_case
run_narrow_terminal_case
run_kernel_management_copy_case
run_update_copy_case
for choice in 1 2 3 4 5 6; do
    run_home_return_case "$choice"
done
run_system_settings_case
run_dns_display_mapping_case
run_interactive_help_case
run_uninstall_copy_case
run_caddy_uninstall_selection_case
run_child_back_case
run_protocol_cancel_case
run_cli_relay_list_case
run_cli_add_case
help_output=$(bash -c 'msg() { printf "%b\n" "$*"; }; msg_ul() { printf "%s" "$*"; }; source "$1"; show_help' _ "$repo_root/src/help.sh") || fail 'help output failed'
[[ $help_output == *'节点出站'* ]] || fail 'help output is missing'
[[ $help_output != *frontend* && $help_output != *'443 SNI 前置'* ]] || fail 'help must not offer frontend management'
run_log_limit_prompt_case
run_log_exit_prompt_case
run_log_missing_cli_case

echo 'PASS: terminal menu navigation, labels, DNS mapping, uninstall, and log prompts'
