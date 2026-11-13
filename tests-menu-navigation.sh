#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)

fail() {
    echo "FAIL: $*"
    exit 1
}

run_node_menu_navigation_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^node_menu_has_nodes() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^node_menu_empty_state() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^node_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
info() { printf 'unexpected info call\n'; }
node_menu_empty_state() { return 1; }

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_conf_dir=$case_dir/conf
mkdir -p "$is_conf_dir"

output=$(printf 'q\nQ\n99\n\n0\n5\n' | node_menu 2>&1)
for item in 添加 修改 查看 删除 '0) 返回上级'; do
    grep -Fxq "$item" <<<"$output" || fail "node menu shows '$item': $output"
done
[[ $output != *$'\n返回\n'* && $output != *'返回节点管理'* ]] || fail "node menu has no legacy return item: $output"
[[ $(grep -Fc '请选择节点操作' <<<"$output") == 5 ]] || fail "each invalid input redraws the complete node menu: $output"
[[ $(grep -Fc '输入无效' <<<"$output") == 4 ]] || fail "q, Q, 99, and Enter each produce one error: $output"
[[ $(grep -Fc '0) 返回上级' <<<"$output") == 5 ]] || fail "the return item is redrawn with every menu: $output"
[[ $output != *'unexpected info call'* ]] || fail 'invalid input or 0 must not run a node action'
CASE
}

run_main_menu_navigation_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^mainmenu=(/,/^)/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^is_main_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
msg_ul() { printf '%s' "$1"; }
show_list() { printf '%s\n' "$@"; }
qrcode_dependency_checked() { return 0; }
core_status_read() { is_core_ver=1.50; is_core_status=运行中; }
log_limit_read() { printf '200'; }
log_usage_read() { printf '0'; }
load() { :; }
is_script_name=one-singbox
is_sh_ver=1.50
author=ouones
is_core_name=sing-box
is_core_ver=1.50
is_core_status=运行中

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
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^change_labels=(/,/^)/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^change() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
_green() { printf '%s' "$*"; }
info() { :; }
is_can_change=(0 1)

output=$(printf '0\n' | change sample.json); status=$?
[[ $status == 2 ]] || fail "0 returns from the node change menu: status=$status output=$output"
[[ $output == *'0) 返回上级'* ]] || fail "node change menu shows the shared return item: $output"
[[ $output == *'协议'* && $output == *'监听端口'* ]] || fail "node change choices remain visible in order: $output"
[[ $output != *'返回节点管理'* ]] || fail "node change menu has no legacy return item: $output"
CASE
}

run_node_selector_return_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^get() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_conf_dir=$case_dir/conf
mkdir -p "$is_conf_dir"
: >"$is_conf_dir/node-a.json"
: >"$is_conf_dir/node-b.json"

output=$(printf '0\n' | get file); status=$?
[[ $status == 2 ]] || fail "0 returns from node selection: status=$status output=$output"
[[ $output == *'0) 返回上级'* ]] || fail "node selection shows the shared return item: $output"
[[ $output == *'node-a.json'* && $output == *'node-b.json'* ]] || fail "node selection keeps all node choices: $output"
[[ -z $is_config_file ]] || fail "0 must not select a node: $is_config_file"
CASE
}

run_empty_node_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^node_menu_has_nodes() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^node_menu_empty_state() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^node_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
info() { printf 'unexpected info call\n'; }

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_conf_dir=$case_dir/conf
mkdir -p "$is_conf_dir"

output=$(printf '3\n\n0\n' | node_menu)
[[ $output == *'暂无节点，请先添加'* ]] || fail "empty node state is explained: $output"
[[ $output != *'尚未添加任何节点'* ]] || fail "empty node state uses the concise prompt: $output"
for item in 添加 修改 查看 删除 '0) 返回上级'; do
    grep -Fxq "$item" <<<"$output" || fail "node menu shows $item: $output"
done
[[ $output != *$'\n返回\n'* ]] || fail "node menu has no legacy return item: $output"
[[ $output == *'按回车返回菜单'* ]] || fail "empty node state remains visible until return: $output"
[[ $output == *'unexpected info call'* ]] && fail 'empty node state must not enter node details'
[[ $(grep -o '请选择节点操作' <<<"$output" | wc -l) == 2 ]] || fail "empty state returns to node menu: $output"
CASE
}

run_empty_relay_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_list() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu_has_entries() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu_empty_state() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@" >"$menu_file"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
menu_file=$case_dir/menu
is_conf_dir=$case_dir/conf
mkdir -p "$is_conf_dir"
is_main_start=1

output=$(printf '2\n\n0\n5\n' | relay_menu)
[[ $output == *'暂无转发，请先添加'* ]] || fail "empty relay state is explained: $output"
[[ $(cat "$menu_file") == $'添加\n列表\n查看\n删除' ]] || fail "relay menu uses concise action labels in order: $(cat "$menu_file")"
[[ $output == *'0) 返回上级'* ]] || fail "relay menu shows the shared return item: $output"
[[ $output == *'按回车返回菜单'* ]] || fail "empty relay state remains visible until return: $output"
[[ $(grep -o '请选择端口中转操作' <<<"$output" | wc -l) == 2 ]] || fail "empty state returns to relay menu: $output"
[[ -z $(find "$is_conf_dir" -type f -print -quit) ]] || fail 'empty relay listing must not change configuration'
CASE
}

run_relay_add_copy_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_add() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_info_show() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() {
    case $1 in
        number) [[ $2 =~ ^[1-9][0-9]*$ ]] && printf '1' ;;
        port) [[ $2 =~ ^[0-9]+$ && $2 -ge 1 && $2 -le 65535 ]] && printf '1' ;;
        port_used) return 1 ;;
    esac
}
node_port_used() { return 1; }
get_port() { tmp_port=12000; }
config_port_used() { return 1; }
shared_config_lock() { return 0; }
shared_config_unlock() { :; }
manage() { :; }
relay_warn_security() { :; }
_green() { printf '%s' "$*"; }

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_conf_dir=$case_dir/conf
mkdir -p "$is_conf_dir"
is_core_bin=/bin/true
is_main_start=1

output=$(printf '1\n\n203.0.113.50\n20050\n\n0\n5\n' | relay_menu)
[[ $output == *'输入监听端口'* && $output == *'回车自动分配'* ]] || fail "add explains the auto-assigned listener port: $output"
[[ $output == *'输入目标地址'* && $output == *'输入目标端口'* ]] || fail "add labels both target inputs: $output"
[[ $output == *'自动分配本地端口: 12000'* ]] || fail "Enter still selects and reports the automatic listener port: $output"
jq -e '.inbounds[0].listen_port == 12000 and .inbounds[0].override_address == "203.0.113.50" and .inbounds[0].override_port == 20050' "$is_conf_dir/relay-12000.json" >/dev/null || fail 'add keeps listener port, target address, and target port mapped to their existing fields'
CASE
}

run_relay_view_copy_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_info_show() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_info() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_list() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu_has_entries() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu_empty_state() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() {
    case $1 in
        number) [[ $2 =~ ^[1-9][0-9]*$ ]] && printf '1' ;;
        port) [[ $2 =~ ^[0-9]+$ && $2 -ge 1 && $2 -le 65535 ]] && printf '1' ;;
    esac
}
node_port_used() { return 1; }
relay_warn_security() { :; }

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_conf_dir=$case_dir/conf
mkdir -p "$is_conf_dir"
cat >"$is_conf_dir/relay-10000.json" <<'JSON'
{"inbounds":[{"listen_port":10000,"override_address":"203.0.113.60","override_port":20060}]}
JSON
is_main_start=1

output=$(printf '3\n10000\n\n0\n5\n' | relay_menu)
[[ $output == *'输入要查看的监听端口'* ]] || fail "view requests the listener port by name: $output"
[[ $output == *'监听端口: 10000'* && $output == *'目标地址: 203.0.113.60'* && $output == *'目标端口: 20060'* ]] || fail "view maps the entered listener port to its existing relay: $output"
CASE
}

run_relay_delete_cancel_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^confirm_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_delete() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_list() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu_has_entries() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu_empty_state() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() {
    case $1 in
        number) [[ $2 =~ ^[1-9][0-9]*$ ]] && printf '1' ;;
        port) [[ $2 =~ ^[0-9]+$ && $2 -ge 1 && $2 -le 65535 ]] && printf '1' ;;
    esac
}
node_port_used() { return 1; }
relay_warn_security() { :; }
shared_config_lock() { return 0; }
shared_config_unlock() { :; }
manage() { :; }
_green() { printf '%s' "$*"; }

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_conf_dir=$case_dir/conf
mkdir -p "$is_conf_dir"
cat >"$is_conf_dir/relay-10000.json" <<'JSON'
{"inbounds":[{"listen_port":10000,"override_address":"203.0.113.60","override_port":20060}]}
JSON
is_main_start=1

output=$(printf '4\n10000\nn\n\n0\n5\n' | relay_menu)
[[ $output == *'输入要删除的监听端口'* ]] || fail "delete requests the listener port by name: $output"
[[ $output == *'监听端口 10000'* && $output == *'转发'* && $output == *'[y/N]'* ]] || fail "confirmation identifies the forwarding rule and preserves its yes/no prompt: $output"
[[ $output == *'已取消删除转发'* ]] || fail "cancel is reported without deleting the relay: $output"
[[ -f "$is_conf_dir/relay-10000.json" ]] || fail 'canceling deletion preserves the relay configuration'

output=$(printf '4\n10000\ny\n\n0\n5\n' | relay_menu)
[[ $output == *'将删除监听端口 10000 的转发配置。确认删除 [y/N]'* ]] || fail "confirmed deletion retains the original yes/no confirmation: $output"
[[ $output == *'已删除中转配置: relay-10000.json'* ]] || fail "confirming deletion removes the selected forwarding rule: $output"
[[ ! -f "$is_conf_dir/relay-10000.json" ]] || fail 'confirmed deletion removes only the selected relay configuration'
CASE
}

run_service_result_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^service_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
service_action_result() { printf '%s\n' "${1}服务成功：运行状态已确认。"; }

output=$(printf '2\n\n0\n6\n' | service_menu)
[[ $output == *'start服务成功'* ]] || fail "service result is displayed: $output"
[[ $output == *'按回车返回菜单'* ]] || fail "service result stays readable before the next menu: $output"
[[ $(grep -o '请选择服务操作' <<<"$output" | wc -l) == 2 ]] || fail "service action returns to its menu: $output"
CASE
}

run_narrow_terminal_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^service_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { :; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
service_action_result() { printf '启动服务结果：当前状态已确认。\n'; }

export COLUMNS=20
output=$(printf '2\n\n0\n6\n' | service_menu)
[[ $output == *'启动服务结果：当前状态已确认。'* ]] || fail "service result stays complete: $output"
pause_width=$(grep -F '按回车返回菜单。' <<<"$output" | wc -L)
[[ $pause_width =~ ^[0-9]+$ && $pause_width -le $COLUMNS ]] || fail "pause guidance fits a ${COLUMNS}-column terminal (width $pause_width)"
CASE
}

run_kernel_management_copy_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^service_menu() {/,/^}/p' "$CORE_FILE")

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
menu_file=$case_dir/menu
action_file=$case_dir/actions

show_list() {
    [[ -s $menu_file ]] || printf '%s\n' "${is_tmp_list[@]}" >"$menu_file"
    printf '%s\n' "${is_tmp_list[@]}"
}
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
menu_pause() { IFS= read -r _pause || :; }
msg() { printf '%b\n' "$*"; }
core_status_read() { is_core_ver=1.50; is_core_status=运行中; is_caddy_status=已停止; is_caddy_ver=2.10; }
service_action_result() { printf '%s\n' "$1" >>"$action_file"; printf '%s 服务结果\n' "$1"; }
log_set() { printf 'log\n' >>"$action_file"; }
load() { [[ $1 == log.sh ]]; }

is_caddy=1
output=$(printf '1\n\n2\n\n3\n\n4\n\n5\n\n0\n6\n' | service_menu)
[[ $(cat "$menu_file") == $'状态\n启动\n停止\n重启\n日志' ]] || fail "kernel menu uses the requested labels in order: $(cat "$menu_file")"
[[ $output == *'sing-box 内核：运行中 (版本 1.50)'* && $output == *'Caddy：已停止 (版本 2.10)'* ]] || fail "status identifies sing-box kernel and Caddy: $output"
[[ $(cat "$action_file") == $'start\nstop\nrestart\nlog' ]] || fail "kernel menu choices retain their actions: $(cat "$action_file")"

: >"$menu_file"
is_caddy=
output=$(printf '1\n\n0\n6\n' | service_menu)
[[ $output == *'sing-box 内核：运行中 (版本 1.50)'* ]] || fail "status keeps the kernel when Caddy is absent: $output"
[[ $output != *'Caddy：'* ]] || fail "status hides Caddy when it is not installed: $output"
CASE
}

run_update_copy_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^update_menu() {/,/^}/p' "$CORE_FILE")

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
menu_file=$case_dir/menu
update_file=$case_dir/updates

show_list() {
    [[ -s $menu_file ]] || printf '%s\n' "${is_tmp_list[@]}" >"$menu_file"
    printf '%s\n' "${is_tmp_list[@]}"
}
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
menu_pause() { IFS= read -r _pause || :; }
msg() { printf '%b\n' "$*"; }
update() { printf '%s\n' "$*" >>"$update_file"; }

is_caddy=1
output=$(printf '1\n\n2\n\n3\n\n0\n4\n' | update_menu)
[[ $(cat "$menu_file") == $'更新 sing-box 内核\n更新脚本\n更新 Caddy' ]] || fail "update menu includes Caddy in the requested order: $(cat "$menu_file")"
[[ $(cat "$update_file") == $'1\n2\ncaddy' ]] || fail "installed update choices keep their targets: $(cat "$update_file")"
[[ $output == *'更新脚本'* ]] || fail "update menu text is visible: $output"

: >"$menu_file"
: >"$update_file"
is_caddy=
output=$(printf '1\n\n2\n\n0\n3\n' | update_menu)
[[ $(cat "$menu_file") == $'更新 sing-box 内核\n更新脚本' ]] || fail "update menu hides Caddy when it is not installed: $(cat "$menu_file")"
[[ $(cat "$update_file") == $'1\n2' ]] || fail "without Caddy, update choices still target core and script: $(cat "$update_file")"
CASE
}

run_home_return_case() {
    local core_file=$1 menu_choice=${2:-1}
    CORE_FILE="$core_file" MENU_CHOICE="$menu_choice" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^mainmenu=(/,/^)/p' "$CORE_FILE")
source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^node_menu_has_nodes() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^node_menu_empty_state() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^node_menu() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^service_menu() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^update_menu() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^system_tools_menu() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_list() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu_has_entries() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu_empty_state() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^is_main_menu() {/,/^}/p' "$CORE_FILE")

[[ ${mainmenu[4]} == '系统设置' ]] || fail "home system settings label is clear: ${mainmenu[4]}"
[[ ${mainmenu[5]} == '帮助反馈' ]] || fail "home help label is clear: ${mainmenu[5]}"
[[ ${mainmenu[6]} == '关于' ]] || fail "home about label is clear: ${mainmenu[6]}"
[[ ${mainmenu[7]} == '卸载' ]] || fail "home uninstall label is clear: ${mainmenu[7]}"

msg() { printf '%b\n' "$*"; }
msg_ul() { printf '%s' "$1"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
qrcode_dependency_checked() { return 0; }
core_status_read() { is_core_ver=1.46; is_core_status=运行中; }
log_limit_read() { printf '100'; }
log_usage_read() { printf '0'; }
load() { :; }
block_cn_status_text() { printf '未启用'; }

is_script_name=one-singbox
is_sh_ver=1.46
author=ouones
is_core_name=sing-box
is_core_ver=1.46
is_core_status=运行中

case $MENU_CHOICE in
1) input=$'1\n0\nq\n' ;;
2) input=$'2\n0\nq\n' ;;
3) input=$'3\n6\nq\n' ;;
4) input=$'4\n0\nq\n' ;;
5) input=$'5\n0\nq\n' ;;
6) input=$'1\n\n0\nq\n' ;;
esac
output=$(printf '%s' "$input" | is_main_menu)
[[ ${mainmenu[2]} == '内核管理' && ${mainmenu[3]} == '更新' ]] || fail "home labels distinguish kernel management and updates: ${mainmenu[*]}"
[[ ${mainmenu[1]} == '端口转发' ]] || fail "home labels relay management as port forwarding: ${mainmenu[1]}"
if [[ $MENU_CHOICE == 2 ]]; then
    [[ $output == *'请选择端口中转操作'* ]] || fail "home choice 2 still opens relay management: $output"
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
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^system_tools_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
load() { action_calls+=("load:$1"); }
_try_enable_bbr() { action_calls+=(bbr); }
dns_set() { action_calls+=(dns); }
log_limit_set() { action_calls+=(log-limit); }
block_cn_menu_toggle() { action_calls+=(block-cn); }
block_cn_status_text() { printf '未启用'; }
get() { action_calls+=("get:$1"); }

action_calls=()
input_file=$(mktemp)
output_file=$(mktemp)
trap 'rm -f "$input_file" "$output_file"' EXIT
printf '1\n\n2\n\n3\n\n4\n\n5\n\n0\n6\n' >"$input_file"
system_tools_menu <"$input_file" >"$output_file"
output=$(cat "$output_file")
for label in '启用 BBR' 'DNS' '日志上限' '屏蔽回国流量' '重装脚本'; do
    [[ $output == *"$label"* ]] || fail "system settings show '$label': $output"
done
[[ $output != *$'\n返回\n'* ]] || fail "system settings have no legacy return item: $output"
[[ $output == *'0) 返回上级'* ]] || fail "system settings show the shared return item: $output"
[[ $output == *'请选择系统设置'* ]] || fail "system settings prompt uses its menu name: $output"
[[ ${action_calls[*]} == 'load:bbr.sh bbr load:dns.sh dns log-limit block-cn get:reinstall' ]] || fail "system setting choices keep their actions: ${action_calls[*]}"
CASE
}

run_dns_display_mapping_case() {
    local core_file=$1
    CORE_FILE="$core_file" REPO_ROOT="$repo_root" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source "$REPO_ROOT/src/dns.sh"

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
_green() { printf '%s' "$*"; }
shared_config_lock() { :; }
shared_config_unlock() { :; }
sync_runtime_node_outbound_modes() { cp "$1" "$2"; }
manage() { printf '%s\n' "$*" >>"$manage_log"; }

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_config_json=$case_dir/config.json
is_conf_dir=$case_dir/conf
manage_log=$case_dir/manage.log
mkdir -p "$is_conf_dir"
is_core_ver=1.16.0
printf '%s\n' '{"dns":{"servers":[{"tag":"old"}]},"route":{"default_domain_resolver":"old"}}' >"$is_config_json"
printf '6\nh3://dns.google/dns-query\n' >"$case_dir/custom-input"
dns_set <"$case_dir/custom-input" >"$case_dir/custom-output"
output=$(cat "$case_dir/custom-output")
for address in 1.1.1.1 8.8.8.8 h3://dns.google/dns-query h3://cloudflare-dns.com/dns-query h3://family.cloudflare-dns.com/dns-query; do
    [[ $output == *"$address"* ]] || fail "DNS menu retains service address '$address': $output"
done
[[ $output == *'自定义'* ]] || fail "DNS menu names custom DNS in Chinese: $output"
[[ $output != *$'\nset\n'* && $output != *$'\nnone\n'* ]] || fail "DNS menu hides internal option names: $output"
jq -e '.dns.servers[0].type == "h3" and .dns.servers[0].server == "dns.google" and .route.default_domain_resolver == "dns"' "$is_config_json" >/dev/null || fail 'custom DNS selection still applies the entered address'
[[ $output != *'已更新 DNS 为: none'* ]] || fail "custom DNS success output does not expose an internal option name: $output"

printf '%s\n' '{"dns":{"servers":[{"tag":"old"}]},"route":{"default_domain_resolver":"old"}}' >"$is_config_json"
printf '7\n' >"$case_dir/none-input"
dns_set <"$case_dir/none-input" >"$case_dir/none-output"
output=$(cat "$case_dir/none-output")
[[ $output == *'不设置'* ]] || fail "DNS menu names the disabled option in Chinese: $output"
[[ $output != *$'\nset\n'* && $output != *$'\nnone\n'* ]] || fail "DNS menu hides internal option names: $output"
jq -e '.dns == {} and (.route | has("default_domain_resolver") | not)' "$is_config_json" >/dev/null || fail 'no-DNS selection still removes DNS configuration'
[[ $output == *'已更新 DNS 为: 不设置'* ]] || fail "no-DNS result uses the display name: $output"

printf '%s\n' '{"dns":{"servers":[{"tag":"old"}]},"route":{"default_domain_resolver":"old"}}' >"$is_config_json"
dns_set none >"$case_dir/cli-none-output"
output=$(cat "$case_dir/cli-none-output")
[[ $output == *'已更新 DNS 为: none'* ]] || fail "CLI DNS success output keeps the argument value: $output"
[[ $output != *'已更新 DNS 为: 不设置'* ]] || fail "CLI DNS success output does not use interactive display copy: $output"

printf '%s\n' '{"dns":{"servers":[{"tag":"keep"}]},"route":{"default_domain_resolver":"keep"}}' >"$is_config_json"
: >"$manage_log"
config_before=$(cat "$is_config_json")
output=$(printf '0\n7\n' | dns_set); status=$?
[[ $status == 2 ]] || fail "0 returns from the DNS menu: status=$status output=$output"
[[ $output == *'0) 返回上级'* ]] || fail "DNS menu shows the shared return item: $output"
[[ $(cat "$is_config_json") == "$config_before" ]] || fail '0 must not modify DNS configuration'
[[ ! -s $manage_log ]] || fail '0 must not restart services'
CASE
}

run_interactive_help_case() {
    local core_file=$1
    CORE_FILE="$core_file" REPO_ROOT="$repo_root" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^mainmenu=(/,/^)/p' "$CORE_FILE")
source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^is_main_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
msg_ul() { printf '%s' "$1"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
qrcode_dependency_checked() { return 0; }
core_status_read() { is_core_ver=1.16; is_core_status=运行中; }
log_limit_read() { printf '200'; }
log_usage_read() { printf '0'; }
load() {
    [[ $1 == help.sh ]] && source "$REPO_ROOT/src/help.sh"
}

is_script_name=one-singbox
is_sh_ver=1.50
author=ouones
is_core=sing-box
is_core_name=sing-box
is_sh_repo=ouones/one-singbox
is_core_repo=SagerNet/sing-box
output=$(printf '6\n' | is_main_menu)
[[ $output == *'命令行帮助'* ]] || fail "interactive help identifies itself as command-line help: $output"
[[ $output == *'Usage: sing-box [options]'* ]] || fail "interactive help still shows command usage: $output"
CASE
}

run_uninstall_copy_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^uninstall() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
confirm_action() {
    confirmation=$1
    printf '%s [y/N]: ' "$1"
    return 1
}

run_case() {
    local caddy=$1 choice=$2 expected_label=$3
    is_caddy=$caddy
    confirmation=
    input_file=$(mktemp)
    output_file=$(mktemp)
    if [[ $caddy ]]; then printf '%s\n' "$choice" >"$input_file"; else : >"$input_file"; fi
    uninstall <"$input_file" >"$output_file"
    output=$(cat "$output_file")
    rm -f "$input_file" "$output_file"
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

run_case 1 1 'one-singbox 脚本'
[[ $confirmation != *'Caddy'* ]] || fail "core-and-script uninstall does not remove Caddy: $confirmation"
run_case 1 2 'Caddy'
[[ $confirmation == *'Caddy 服务'* ]] || fail "full uninstall confirms Caddy service removal: $confirmation"
[[ $confirmation == *'/etc/caddy'* ]] || fail "full uninstall confirms the Caddy directory scope: $confirmation"
run_case '' '' 'one-singbox 脚本'
CASE
}

run_log_limit_prompt_case() {
    REPO_ROOT="$repo_root" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL: $*"
    exit 1
}

source "$REPO_ROOT/src/log.sh"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_log_dir=$case_dir/log
mkdir -p "$is_core_dir" "$is_log_dir"
printf '125\n' >"$is_core_dir/log-limit-mb"
prompt_output=
msg() { prompt_output+="$*"$'\n'; }
log_limit_service() { fail 'pressing Enter must not restart the log service'; }
limit_before=$(log_limit_read)
log_limit_set <<<''
[[ $prompt_output == *'输入日志上限'* && $prompt_output == *'单位 MB'* && $prompt_output == *'回车保留当前值'* ]] || fail "log limit prompt explains the value, units, and Enter behavior: $prompt_output"
[[ $(log_limit_read) == "$limit_before" ]] || fail 'pressing Enter preserves the configured limit'
CASE
}

run_child_back_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^update_menu() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^system_tools_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
is_main_menu() { main_calls=$((main_calls + 1)); }
update() { update_calls=$((update_calls + 1)); }

main_calls=0
update_calls=0
block_cn_status_text() { printf '未启用'; }
update_menu <<<"0" >/dev/null
[[ $main_calls == 0 ]] || fail 'update menu back must return to its caller'
[[ $update_calls == 0 ]] || fail 'returning from update menu must not update anything'

system_tools_menu <<<"0" >/dev/null
[[ $main_calls == 0 ]] || fail 'system tools back must return to its caller'
CASE
}

run_protocol_cancel_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^protocol_list=(/,/^)/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^get() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^create() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^add() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
_green() { printf '%s' "$*"; }

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_conf_dir=$case_dir/conf
is_core_dir=$case_dir/core
mkdir -p "$is_conf_dir" "$is_core_dir"
manage_log=$case_dir/manage.log
is_core_ver=1.46.0
is_core_bin=/bin/true
is_core=sing-box
is_main_start=1
port=23456
host=203.0.113.10
uuid=123e4567-e89b-12d3-a456-426614174000

expected_protocols=(TUIC Trojan Hysteria2 VMess-WS VMess-TCP VMess-HTTP VMess-QUIC Shadowsocks VMess-H2-TLS VMess-WS-TLS VLESS-H2-TLS VLESS-WS-TLS Trojan-H2-TLS Trojan-WS-TLS VMess-HTTPUpgrade-TLS VLESS-HTTPUpgrade-TLS Trojan-HTTPUpgrade-TLS VLESS-REALITY VLESS-HTTP2-REALITY AnyTLS Socks Snell)
[[ ${protocol_list[*]} == "${expected_protocols[*]}" ]] || fail "existing protocol order changed: ${protocol_list[*]}"
manage() { printf '%s\n' "$*" >>"$manage_log"; }
info() { :; }
meta_set() { :; }
node_port_used() { return 1; }
node_protocol_transport() { printf 'udp\n'; }
config_port_used() { return 1; }
shared_config_lock() { return 0; }
shared_config_unlock() { :; }
sync_runtime_node_outbound_modes() { return 0; }
cancel_choice=$((${#protocol_list[@]} + 1))
output=$(printf '0\n%s\n1\nsample-node\n' "$cancel_choice" | add); status=$?
wait
[[ $status == 2 ]] || fail "0 returns from protocol selection: status=$status output=$output"
[[ $output == *'0) 返回上级'* ]] || fail "protocol list shows the shared return item: $output"
[[ $output != *$'\n返回节点管理\n'* ]] || fail "protocol list has no legacy return item: $output"
[[ $output == *'已取消添加节点'* ]] || fail "canceling protocol selection returns without adding: $output"
[[ -z $(find "$is_conf_dir" -type f -print -quit) ]] || fail 'canceling protocol selection must not change configuration'
[[ ! -s $manage_log ]] || fail 'canceling protocol selection must not change services'
CASE
}

run_cli_relay_list_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^relay_list() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_main() {/,/^}/p' "$CORE_FILE")
msg() { printf '%b\n' "$*"; }

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_conf_dir=$case_dir/conf
mkdir -p "$is_conf_dir"
output=$(relay_main list) || fail "relay list CLI succeeds: $output"
[[ $output == *'当前未配置任何中转'* ]] || fail "relay list CLI keeps its output: $output"
[[ $output != *'按回车返回'* ]] || fail 'noninteractive relay list must not pause'
CASE
}

run_cli_add_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^main() {/,/^}/p' "$CORE_FILE")
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
    local log_file=$1
    LOG_FILE="$log_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${LOG_FILE}): $*"
    exit 1
}

source <(sed -n '/^log_set() {/,/^}/p' "$LOG_FILE")

is_log_dir=$(mktemp -d)
trap 'rm -rf "$is_log_dir"' EXIT
touch "$is_log_dir/access.log"
_green() { printf '%s' "$*"; }
msg() { printf '%b\n' "$*"; }
tail() { printf 'log stream started\n'; }

output=$(log_set)
[[ $output == *'按 Ctrl+C 退出'* ]] || fail "log exit prompt names the Ctrl+C shortcut: $output"
[[ $output == *'log stream started'* ]] || fail "log streaming remains active after the prompt: $output"
CASE
}

for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
    run_node_menu_navigation_case "$core_file"
    run_main_menu_navigation_case "$core_file"
    run_node_change_menu_return_case "$core_file"
    run_node_selector_return_case "$core_file"
    run_empty_node_case "$core_file"
    run_empty_relay_case "$core_file"
    run_relay_add_copy_case "$core_file"
    run_relay_view_copy_case "$core_file"
    run_relay_delete_cancel_case "$core_file"
    run_service_result_case "$core_file"
    run_narrow_terminal_case "$core_file"
    run_kernel_management_copy_case "$core_file"
    run_update_copy_case "$core_file"
    run_home_return_case "$core_file" 1
    run_home_return_case "$core_file" 2
    run_home_return_case "$core_file" 3
    run_home_return_case "$core_file" 4
    run_home_return_case "$core_file" 5
    run_home_return_case "$core_file" 6
    run_system_settings_case "$core_file"
    run_dns_display_mapping_case "$core_file"
    run_interactive_help_case "$core_file"
    run_uninstall_copy_case "$core_file"
    run_child_back_case "$core_file"
    run_protocol_cancel_case "$core_file"
    run_cli_relay_list_case "$core_file"
    run_cli_add_case "$core_file"
    help_output=$(bash -c 'msg() { printf "%b\n" "$*"; }; msg_ul() { printf "%s" "$*"; }; source "$1"; show_help' _ "$repo_root/src/help.sh") || fail 'help output failed'
    [[ $help_output == *'节点出站'* ]] || fail 'help output is missing'
    [[ $help_output != *frontend* && $help_output != *'443 SNI 前置'* ]] || fail 'help must not offer frontend management'
done

run_log_limit_prompt_case

run_log_exit_prompt_case "$repo_root/src/log.sh"

echo 'PASS: terminal menu navigation, labels, DNS mapping, uninstall, and log prompts'
