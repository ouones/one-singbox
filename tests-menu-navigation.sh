#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)

fail() {
    echo "FAIL: $*"
    exit 1
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

output=$(printf '3\n\n5\n' | node_menu)
[[ $output == *'尚未添加任何节点'* ]] || fail "empty node state is explained: $output"
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
source <(sed -n '/^relay_list() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu_has_entries() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu_empty_state() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_conf_dir=$case_dir/conf
mkdir -p "$is_conf_dir"

output=$(printf '2\n\n5\n' | relay_menu)
[[ $output == *'当前未配置任何中转'* ]] || fail "empty relay state is explained: $output"
[[ $output == *'按回车返回菜单'* ]] || fail "empty relay state remains visible until return: $output"
[[ $(grep -o '请选择端口中转操作' <<<"$output" | wc -l) == 2 ]] || fail "empty state returns to relay menu: $output"
[[ -z $(find "$is_conf_dir" -type f -print -quit) ]] || fail 'empty relay listing must not change configuration'
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
source <(sed -n '/^service_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
service_action_result() { printf '%s\n' "${1}服务成功：运行状态已确认。"; }

output=$(printf '2\n\n6\n' | service_menu)
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
source <(sed -n '/^service_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { :; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
service_action_result() { printf '启动服务结果：当前状态已确认。\n'; }

export COLUMNS=20
output=$(printf '2\n\n6\n' | service_menu)
[[ $output == *'启动服务结果：当前状态已确认。'* ]] || fail "service result stays complete: $output"
pause_width=$(grep -F '按回车返回菜单。' <<<"$output" | wc -L)
[[ $pause_width =~ ^[0-9]+$ && $pause_width -le $COLUMNS ]] || fail "pause guidance fits a ${COLUMNS}-column terminal (width $pause_width)"
CASE
}

run_home_return_case() {
    local core_file=$1 frontend_choice=${2:-1}
    CORE_FILE="$core_file" REPO_ROOT="$repo_root" FRONTEND_CHOICE="$frontend_choice" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*"
    exit 1
}

source <(sed -n '/^mainmenu=(/,/^)/p' "$CORE_FILE")
source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p' "$CORE_FILE")
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

msg() { printf '%b\n' "$*"; }
msg_ul() { printf '%s' "$1"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
qrcode_dependency_checked() { return 0; }
core_status_read() { is_core_ver=1.46; is_core_status=运行中; }
log_limit_read() { printf '100'; }
log_usage_read() { printf '0'; }
load() {
    [[ $1 == frontend.sh ]] || return 0
    source <(sed -n '/^frontend_menu() {/,/^}/p' "$REPO_ROOT/src/frontend.sh")
}

is_script_name=one-singbox
is_sh_ver=1.46
author=ouones
is_core_name=sing-box
is_core_ver=1.46
is_core_status=运行中

case $FRONTEND_CHOICE in
1) input=$'1\n5\n\n' ;;
2) input=$'2\n0\n\n' ;;
3) input=$'3\n5\n\n' ;;
4) input=$'4\n6\n\n' ;;
5) input=$'5\n3\n\n' ;;
6) input=$'6\n5\n\n' ;;
7) input=$'1\n\n5\n\n' ;;
esac
output=$(printf '%s' "$input" | is_main_menu)
[[ $(grep -o 'one-singbox script' <<<"$output" | wc -l) == 2 ]] || fail "returning from a child menu goes back to home: $output"
if [[ $FRONTEND_CHOICE == 2 ]]; then
    [[ $output == *'443 SNI 前置'* ]] || fail "frontend menu is shown before returning home: $output"
elif [[ $FRONTEND_CHOICE == 7 ]]; then
    [[ $output == *'输入无效'* ]] || fail "blank input in a child menu is not exit: $output"
fi
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
source <(sed -n '/^update_menu() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^system_tools_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
is_main_menu() { main_calls=$((main_calls + 1)); }
update() { update_calls=$((update_calls + 1)); }

main_calls=0
update_calls=0
update_menu <<<"3" >/dev/null
[[ $main_calls == 0 ]] || fail 'update menu back must return to its caller'
[[ $update_calls == 0 ]] || fail 'returning from update menu must not update anything'

system_tools_menu <<<"5" >/dev/null
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
output=$(printf '%s\n1\nsample-node\n' "$cancel_choice" | add)
wait
[[ $output == *'返回节点管理'* ]] || fail "protocol list offers a clear back choice: $output"
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

for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
    run_empty_node_case "$core_file"
    run_empty_relay_case "$core_file"
    run_service_result_case "$core_file"
    run_narrow_terminal_case "$core_file"
    run_home_return_case "$core_file" 1
    run_home_return_case "$core_file" 2
    run_home_return_case "$core_file" 3
    run_home_return_case "$core_file" 4
    run_home_return_case "$core_file" 5
    run_home_return_case "$core_file" 6
    run_home_return_case "$core_file" 7
    run_child_back_case "$core_file"
    run_protocol_cancel_case "$core_file"
    run_cli_relay_list_case "$core_file"
    run_cli_add_case "$core_file"
done

echo 'PASS: empty node and relay states return to their menus'
