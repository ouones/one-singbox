#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)

interactive_read() { builtin read "$@"; }
run_interactive_operation() { ( "$@" ); }
export -f interactive_read run_interactive_operation

run_action_result_case() {
    local core_file=$1 result=$2
    CORE_FILE="$core_file" RESULT="$result" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE} action ${RESULT}): $*"
    exit 1
}

source <(sed -n '/^menu_pause() {/,/^}/p; /^menu_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu_has_entries() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu_empty_state() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
relay_menu_has_entries() { return 0; }

case $RESULT in
success)
    relay_add() { msg '操作成功：端口转发已保存。'; }
    ;;
failure)
    relay_add() { msg '操作失败：模拟配置写入失败。'; exit 1; }
    ;;
cancel)
    relay_add() { msg '已取消：未写入任何配置。'; }
    ;;
esac

output=$(printf '1\n\n0\n' | relay_menu 2>&1); status=$?
[[ $status == 0 ]] || fail "the parent menu resumes after the result: status=$status output=$output"
[[ $output == *'按回车返回菜单。'* ]] || fail "the result waits for Enter: $output"
case $RESULT in
success) expected='操作成功：端口转发已保存。' ;;
failure) expected='操作失败：模拟配置写入失败。' ;;
cancel) expected='已取消：未写入任何配置。' ;;
esac
[[ $output == *"$expected"* ]] || fail "the result explains what happened: $output"
message_line=$(awk -v text="$expected" 'index($0, text) { print NR; exit }' <<<"$output")
pause_line=$(awk 'index($0, "按回车返回菜单。") { print NR; exit }' <<<"$output")
return_line=$(awk 'index($0, "按回车返回菜单。") { paused=1 } paused && index($0, "0) 返回上级") { print NR; exit }' <<<"$output")
[[ $message_line -lt $pause_line && $pause_line -lt $return_line ]] || fail "result, pause, and parent menu stay in order: $output"
[[ $(grep -o '请选择端口转发操作' <<<"$output" | wc -l) == 2 ]] || fail "Enter returns to the port-forwarding menu: $output"
CASE
}

run_update_no_change_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE} update no-change): $*"
    exit 1
}

source <(sed -n '/^_green() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p; /^menu_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^update() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^update_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
get_latest_version() { latest_ver=v1.50.0; }
download() { fail 'an already-current version must not download'; }
load() { :; }
manage() { fail 'an already-current version must not restart services'; }

is_core=sing-box
is_core_name=sing-box
is_core_ver=1.50.0
is_core_repo=SagerNet/sing-box
is_update_repo=$is_core_repo
is_show_name=sing-box

output=$(printf '1\n\n0\n' | update_menu 2>&1); status=$?
[[ $status == 0 ]] || fail "the update menu resumes after no change: status=$status output=$output"
[[ $output == *'当前已经是最新版本了'* ]] || fail "the no-change reason is visible: $output"
message_line=$(awk 'index($0, "当前已经是最新版本了") { print NR; exit }' <<<"$output")
pause_line=$(awk 'index($0, "按回车返回菜单。") { print NR; exit }' <<<"$output")
return_line=$(awk 'index($0, "按回车返回菜单。") { paused=1 } paused && index($0, "0) 返回上级") { print NR; exit }' <<<"$output")
[[ $message_line -lt $pause_line && $pause_line -lt $return_line ]] || fail "no-change, pause, and parent menu stay in order: $output"
[[ $(grep -o '请选择要更新的软件' <<<"$output" | wc -l) == 2 ]] || fail "Enter returns to the update menu: $output"
CASE
}

run_custom_update_no_change_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE} custom update no-change): $*"
    exit 1
}

source <(sed -n '/^_green() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p; /^menu_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^update() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
is_core=sing-box
is_core_name=sing-box
is_core_ver=1.50.0

run_custom_update() {
    menu_action update core 1.50.0
    msg '父菜单继续显示'
}

output=$(printf '\n' | run_custom_update 2>&1); status=$?
[[ $status == 0 ]] || fail "custom no-change does not exit the panel: status=$status output=$output"
[[ $output == *'自定义版本和当前 sing-box 版本一样, 无需更新.'* ]] || fail "custom no-change explains itself: $output"
message_line=$(awk 'index($0, "自定义版本和当前 sing-box 版本一样") { print NR; exit }' <<<"$output")
pause_line=$(awk 'index($0, "按回车返回菜单。") { print NR; exit }' <<<"$output")
parent_line=$(awk 'index($0, "父菜单继续显示") { print NR; exit }' <<<"$output")
[[ $message_line -lt $pause_line && $pause_line -lt $parent_line ]] || fail "custom no-change, pause, and parent stay in order: $output"
CASE
}

run_status_color_case() {
    local core_file=$1
    CORE_FILE="$core_file" REPO_ROOT="$repo_root" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE} status ${test_state:-unknown}): $*"
    exit 1
}

source <(sed -n '/^red=/p; /^green=/p; /^none=/p; /^_red() {/p; /^_green() {/p' "$CORE_FILE")
source <(sed -n '/^core_status_read() {/,/^}/p' "$REPO_ROOT/src/init.sh")
source <(sed -n '/^menu_pause() {/,/^}/p; /^menu_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^service_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
service_status_read() { is_service_state=$test_state; }
is_core=sing-box
is_core_name=sing-box
is_core_ver=1.50.0
is_caddy=

for spec in \
    'running|运行中|\e[92m' \
    'stopped|已停止|\e[31m' \
    'failed|启动失败|\e[31m' \
    'unknown|状态读取失败|\e[31m'; do
    IFS='|' read -r test_state expected_text expected_color <<<"$spec"
    printf -v expected_color '%b' "$expected_color"
    output=$(printf '1\n\n0\n' | service_menu 2>&1); status=$?
    [[ $status == 0 ]] || fail "the service menu resumes after status: status=$status output=$output"
    [[ $output == *"$expected_text"* ]] || fail "status is text-readable: $output"
    [[ $output == *"$expected_color$expected_text"* ]] || fail "status has its matching color: $output"
    status_line=$(awk -v text="$expected_text" 'index($0, text) { print NR; exit }' <<<"$output")
    pause_line=$(awk 'index($0, "按回车返回菜单。") { print NR; exit }' <<<"$output")
    return_line=$(awk 'index($0, "按回车返回菜单。") { paused=1 } paused && index($0, "0) 返回上级") { print NR; exit }' <<<"$output")
    [[ $status_line -lt $pause_line && $pause_line -lt $return_line ]] || fail "status, pause, and service menu stay in order: $output"
    [[ $(grep -o '请选择服务操作' <<<"$output" | wc -l) == 2 ]] || fail "Enter returns to the service menu: $output"
done
CASE
}

run_information_page_case() {
    local core_file=$1 page=$2
    CORE_FILE="$core_file" PAGE="$page" REPO_ROOT="$repo_root" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE} ${PAGE} page): $*"
    exit 1
}

source <(sed -n '/^mainmenu=(/,/^)/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p; /^menu_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^node_menu_has_nodes() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^node_menu_empty_state() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^node_menu() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^is_main_menu() {/,/^}/p' "$CORE_FILE")
source "$REPO_ROOT/src/help.sh"

msg() { printf '%b\n' "$*"; }
msg_ul() { printf '%s' "$1"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
qrcode_dependency_checked() { return 0; }
core_status_read() { is_core_ver=1.50.0; is_core_status=$'\e[92m运行中\e[0m'; }
log_limit_read() { printf '200'; }
log_usage_read() { printf '0'; }
load() { :; }
info() { msg '节点详情结束：sample-node.json'; }
change() { :; }
del() { :; }
block_cn_status_text() { printf '未启用'; }

is_script_name=one-singbox
is_sh_ver=1.50.0
author=ouones
is_core=sing-box
is_core_name=sing-box
is_core_repo=SagerNet/sing-box
is_sh_repo=ouones/one-singbox
is_core_ver=1.50.0
is_core_status='运行中'

case $PAGE in
node)
    case_dir=$(mktemp -d)
    trap 'rm -rf "$case_dir"' EXIT
    is_conf_dir=$case_dir/conf
    mkdir -p "$is_conf_dir"
    printf '{}\n' >"$is_conf_dir/sample-node.json"
    output=$(printf '3\n\n0\n' | node_menu 2>&1); status=$?
    [[ $status == 0 ]] || fail "node menu resumes after details: status=$status output=$output"
    first_prompt='请选择节点操作'
    information='节点详情结束：sample-node.json'
    parent_count=2
    ;;
help)
    output=$(printf '6\n\nq\n' | is_main_menu 2>&1); status=$?
    [[ $status == 0 ]] || fail "main menu exits cleanly after help: status=$status output=$output"
    first_prompt='------------- one-singbox script'
    information='问题反馈:'
    parent_count=2
    ;;
about)
    output=$(printf '7\n\nq\n' | is_main_menu 2>&1); status=$?
    [[ $status == 0 ]] || fail "main menu exits cleanly after about: status=$status output=$output"
    first_prompt='------------- one-singbox script'
    information='项目源码:'
    parent_count=2
    ;;
esac

[[ $(grep -o -- "$first_prompt" <<<"$output" | wc -l) == "$parent_count" ]] || fail "Enter returns to the correct parent menu: $output"
information_line=$(awk -v text="$information" 'index($0, text) { print NR; exit }' <<<"$output")
pause_line=$(awk 'index($0, "按回车返回菜单。") { print NR; exit }' <<<"$output")
return_line=$(awk -v text="$first_prompt" 'index($0, text) { count++; if (count == 2) { print NR; exit } }' <<<"$output")
[[ $information_line -lt $pause_line && $pause_line -lt $return_line ]] || fail "information, pause, and parent menu stay in order: $output"
CASE
}

for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
    run_action_result_case "$core_file" success
    run_action_result_case "$core_file" failure
    run_action_result_case "$core_file" cancel
    run_update_no_change_case "$core_file"
    run_custom_update_no_change_case "$core_file"
    run_status_color_case "$core_file"
    run_information_page_case "$core_file" node
    run_information_page_case "$core_file" help
    run_information_page_case "$core_file" about
done

echo 'PASS: interaction results pause, explain outcomes, and return to the correct parent menu'
