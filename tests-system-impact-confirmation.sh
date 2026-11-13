#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fail() {
    echo "FAIL: $*"
    exit 1
}

run_bbr_confirmation_case() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL($CORE_FILE bbr): $*"
    exit 1
}

source <(sed -n '/^interactive_read() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^run_interactive_operation() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p; /^menu_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^confirm_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_system_impact() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^system_tools_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
load() { :; }
log_limit_set() { :; }
dns_set() { :; }
block_cn_status_text() { printf '未启用'; }
block_cn_menu_toggle() { :; }
get() { :; }
_try_enable_bbr() { printf 'bbr-applied\n' >"$WORKDIR/bbr-effect"; }

for input in y Y n N '' 0 no 'Y '; do
    rm -f "$WORKDIR/bbr-effect"
    output=$(printf '1\n%s\n\n0\n' "$input" | system_tools_menu 2>&1)
    [[ $output == *'操作对象：系统内核拥塞控制（BBR）'* ]] || fail "input '$input' did not identify BBR: $output"
    [[ $output == *'主要影响：修改 /etc/sysctl.conf 中的拥塞控制与队列设置'* ]] || fail "input '$input' did not explain the BBR impact: $output"
    [[ $output == *'是否重启核心：否'* ]] || fail "input '$input' did not state that the core is not restarted: $output"
    if [[ $input == y || $input == Y ]]; then
        [[ -f $WORKDIR/bbr-effect ]] || fail "input '$input' did not apply BBR: $output"
    else
        [[ ! -e $WORKDIR/bbr-effect ]] || fail "input '$input' applied BBR: $output"
        [[ $output == *'已取消'* ]] || fail "input '$input' did not report cancellation: $output"
        [[ $output == *'按回车返回菜单。'* ]] || fail "input '$input' did not pause after cancellation: $output"
    fi
done
CASE
}

run_dns_confirmation_case() {
    local core_file=$1
    CORE_FILE="$core_file" REPO_ROOT="$repo_root" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL($CORE_FILE dns): $*"
    exit 1
}

source <(sed -n '/^interactive_read() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^run_interactive_operation() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p; /^menu_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^confirm_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_system_impact() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p; /^ask() {/,/^}/p' "$CORE_FILE")
source "$REPO_ROOT/src/dns.sh"

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
_green() { printf '%s' "$*"; }
shared_config_lock() { return 0; }
shared_config_unlock() { :; }
sync_runtime_node_outbound_modes() { cp "$1" "$2"; }
manage() { printf '%s\n' "$*" >"$WORKDIR/dns-manage"; }

is_config_json=$WORKDIR/config.json
is_conf_dir=$WORKDIR/conf
is_core_ver=1.16.0
mkdir -p "$is_conf_dir"

for spec in 'custom|6|h3://dns.google/dns-query|DNS 配置：h3://dns.google/dns-query' 'none|7||DNS 配置：不设置'; do
    IFS='|' read -r branch choice address target <<<"$spec"
    for answer in y n; do
        printf '%s\n' '{"dns":{"servers":[{"tag":"old"}]},"route":{"default_domain_resolver":"old"}}' >"$is_config_json"
        rm -f "$WORKDIR/dns-manage"
        if [[ $branch == custom ]]; then
            input=$(printf '%s\n%s\n%s\n\n' "$choice" "$address" "$answer")
        else
            input=$(printf '%s\n%s\n\n' "$choice" "$answer")
        fi
        output=$(printf '%s' "$input" | menu_action dns_set 2>&1)
        [[ $output == *"操作对象：$target"* ]] || fail "$branch/$answer did not identify the DNS target: $output"
        [[ $output == *'是否重启核心：是'* ]] || fail "$branch/$answer did not state that the core restarts: $output"
        if [[ $answer == y ]]; then
            [[ $(cat "$WORKDIR/dns-manage" 2>/dev/null) == 'restart core' || $(cat "$WORKDIR/dns-manage" 2>/dev/null) == 'restart' ]] || fail "$branch/y did not restart the core: $output"
            if [[ $branch == custom ]]; then
                jq -e '.dns.servers[0].type == "h3" and .dns.servers[0].server == "dns.google"' "$is_config_json" >/dev/null || fail 'custom DNS was not applied'
            else
                jq -e '.dns == {} and (.route | has("default_domain_resolver") | not)' "$is_config_json" >/dev/null || fail 'no-DNS selection was not applied'
            fi
        else
            jq -e '.dns.servers[0].tag == "old" and .route.default_domain_resolver == "old"' "$is_config_json" >/dev/null || fail "$branch/$answer changed the DNS config"
            [[ ! -e $WORKDIR/dns-manage ]] || fail "$branch/$answer restarted the core"
            [[ $output == *'已取消'* && $output == *'按回车返回菜单。'* ]] || fail "$branch/$answer did not pause after cancellation: $output"
        fi
    done
done
CASE
}

run_block_cn_confirmation_case() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL($CORE_FILE block-cn): $*"
    exit 1
}

source <(sed -n '/^interactive_read() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^run_interactive_operation() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p; /^menu_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^confirm_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_system_impact() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^system_tools_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
load() { :; }
_try_enable_bbr() { :; }
dns_set() { :; }
log_limit_set() { :; }
get() { :; }
block_cn_is_enabled() { [[ -f $WORKDIR/block-cn-enabled ]]; }
block_cn_status_text() { if block_cn_is_enabled; then printf '已启用'; else printf '未启用'; fi; }
block_cn_menu_toggle() {
    printf 'toggle\n' >>"$WORKDIR/block-cn-effects"
    if block_cn_is_enabled; then
        rm "$WORKDIR/block-cn-enabled"
    else
        : >"$WORKDIR/block-cn-enabled"
    fi
}

for spec in 'disabled|enable|启用屏蔽回国流量（block-cn）|写入启用标记、同步回国白名单并重写运行时路由' 'enabled|disable|停用屏蔽回国流量（block-cn）|移除启用标记并重写运行时路由，恢复原有出站规则'; do
    IFS='|' read -r initial action object impact <<<"$spec"
    for answer in y n; do
        rm -f "$WORKDIR/block-cn-effects"
        if [[ $initial == enabled ]]; then : >"$WORKDIR/block-cn-enabled"; else rm -f "$WORKDIR/block-cn-enabled"; fi
        output=$(printf '4\n%s\n\n0\n' "$answer" | system_tools_menu 2>&1)
        [[ $output == *"操作对象：$object"* ]] || fail "$action/$answer did not identify the block-cn target: $output"
        [[ $output == *"主要影响：$impact"* ]] || fail "$action/$answer did not explain the impact: $output"
        [[ $output == *'是否重启核心：是'* ]] || fail "$action/$answer did not state that the core restarts: $output"
        if [[ $answer == y ]]; then
            [[ $(cat "$WORKDIR/block-cn-effects" 2>/dev/null) == toggle ]] || fail "$action/y did not invoke block-cn: $output"
            if [[ $action == enable ]]; then
                [[ -f $WORKDIR/block-cn-enabled ]] || fail 'enable did not enable block-cn'
            else
                [[ ! -e $WORKDIR/block-cn-enabled ]] || fail 'disable did not disable block-cn'
            fi
        else
            [[ ! -e $WORKDIR/block-cn-effects ]] || fail "$action/$answer invoked block-cn"
            if [[ $initial == enabled ]]; then
                [[ -f $WORKDIR/block-cn-enabled ]] || fail "$action/$answer removed the enabled marker"
            else
                [[ ! -e $WORKDIR/block-cn-enabled ]] || fail "$action/$answer created the enabled marker"
            fi
            [[ $output == *'已取消'* && $output == *'按回车返回菜单。'* ]] || fail "$action/$answer did not pause after cancellation: $output"
        fi
    done
done
CASE
}

run_update_confirmation_case() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL($CORE_FILE update): $*"
    exit 1
}

source <(sed -n '/^interactive_read() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^run_interactive_operation() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p; /^menu_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^confirm_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_system_impact() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p; /^update_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
update() { printf '%s\n' "$*" >>"$WORKDIR/update-effects"; }

is_caddy=1
for spec in '1|1|sing-box 内核|下载并替换 sing-box 内核程序，保留现有配置|是' '2|2|one-singbox 脚本|下载并替换 one-singbox 脚本，不改 sing-box 配置|否' '3|caddy|Caddy|下载并替换 Caddy 程序并重启 Caddy，不改 sing-box 配置|否'; do
    IFS='|' read -r choice expected_call object impact restart <<<"$spec"
    for answer in y n; do
        rm -f "$WORKDIR/update-effects"
        output=$(printf '%s\n%s\n\n0\n' "$choice" "$answer" | update_menu 2>&1)
        [[ $output == *"操作对象：$object"* ]] || fail "choice $choice/$answer did not identify the update target: $output"
        [[ $output == *"主要影响：$impact"* ]] || fail "choice $choice/$answer did not explain the impact: $output"
        [[ $output == *"是否重启核心：$restart"* ]] || fail "choice $choice/$answer did not state the restart impact: $output"
        if [[ $answer == y ]]; then
            [[ $(cat "$WORKDIR/update-effects" 2>/dev/null) == "$expected_call" ]] || fail "choice $choice/y did not invoke update $expected_call: $output"
        else
            [[ ! -e $WORKDIR/update-effects ]] || fail "choice $choice/$answer ran the update"
            [[ $output == *'已取消'* && $output == *'按回车返回菜单。'* ]] || fail "choice $choice/$answer did not pause after cancellation: $output"
        fi
    done
done

is_caddy=
rm -f "$WORKDIR/update-effects"
output=$(printf '3\n0\n' | update_menu 2>&1)
[[ $output != *'更新 Caddy'* ]] || fail "uninstalled Caddy must not appear in the update menu: $output"
[[ $output == *'输入无效'* ]] || fail 'uninstalled Caddy choice must be rejected: $output'
[[ ! -e $WORKDIR/update-effects ]] || fail 'uninstalled Caddy choice ran an update'
CASE
}

run_service_confirmation_case() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL($CORE_FILE service): $*"
    exit 1
}

source <(sed -n '/^interactive_read() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^run_interactive_operation() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p; /^menu_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^confirm_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_system_impact() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p; /^service_menu() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
core_status_read() { :; }
log_set() { :; }
load() { :; }
service_action_result() { printf '%s\n' "$1" >>"$WORKDIR/service-effects"; }

rm -f "$WORKDIR/service-effects"
output=$(printf '2\n\n0\n' | service_menu 2>&1)
[[ $output != *'系统影响确认'* ]] || fail "start must not require confirmation: $output"
[[ $(cat "$WORKDIR/service-effects" 2>/dev/null) == start ]] || fail 'start did not invoke the existing service action'

for spec in '3|stop|sing-box 内核服务（停止）|停止监听并中断所有节点连接|否（执行后保持停止）' '4|restart|sing-box 内核服务（重启）|短暂中断所有节点连接后重新加载配置|是'; do
    IFS='|' read -r choice action object impact restart <<<"$spec"
    for answer in y n; do
        rm -f "$WORKDIR/service-effects"
        output=$(printf '%s\n%s\n\n0\n' "$choice" "$answer" | service_menu 2>&1)
        [[ $output == *"操作对象：$object"* ]] || fail "$action/$answer did not identify the service action: $output"
        [[ $output == *"主要影响：$impact"* ]] || fail "$action/$answer did not explain the service impact: $output"
        [[ $output == *"是否重启核心：$restart"* ]] || fail "$action/$answer did not state the restore policy: $output"
        if [[ $answer == y ]]; then
            [[ $(cat "$WORKDIR/service-effects" 2>/dev/null) == "$action" ]] || fail "$action/y did not invoke the service action: $output"
        else
            [[ ! -e $WORKDIR/service-effects ]] || fail "$action/$answer invoked the service action"
            [[ $output == *'已取消'* && $output == *'按回车返回菜单。'* ]] || fail "$action/$answer did not pause after cancellation: $output"
        fi
    done
done
CASE
}

run_cli_no_confirmation_case() {
    local core_file=$1
    CORE_FILE="$core_file" REPO_ROOT="$repo_root" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL($CORE_FILE CLI): $*"
    exit 1
}

source <(sed -n '/^main() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
_green() { printf '%s' "$*"; }
load() { [[ $1 == dns.sh ]] && source "$REPO_ROOT/src/dns.sh"; }
update() { printf 'update:%s\n' "$*" >>"$WORKDIR/cli-effects"; }
_try_enable_bbr() { printf 'bbr\n' >>"$WORKDIR/cli-effects"; }
service_action_result() { printf 'service:%s:%s\n' "$1" "$2" >>"$WORKDIR/cli-effects"; }
shared_config_lock() { return 0; }
shared_config_unlock() { :; }
sync_runtime_node_outbound_modes() { cp "$1" "$2"; }
manage() { printf 'manage:%s\n' "$*" >>"$WORKDIR/cli-effects"; }

: >"$WORKDIR/cli-effects"
printf '%s\n' '{"dns":{"servers":[{"tag":"old"}]},"route":{"default_domain_resolver":"old"}}' >"$WORKDIR/config.json"
is_config_json=$WORKDIR/config.json
is_conf_dir=$WORKDIR/conf
is_core_ver=1.16.0
mkdir -p "$is_conf_dir"

for command in 'update core' 'dns none' 'bbr' 'stop' 'restart'; do
    output=$(main $command </dev/null 2>&1) || fail "CLI '$command' failed: $output"
    [[ $output != *'系统影响确认'* && $output != *'[y/N]'* && $output != *'确认执行上述操作'* ]] || fail "CLI '$command' added interactive confirmation: $output"
done
[[ $(cat "$WORKDIR/cli-effects") == $'update:core\nmanage:restart\nbbr\nservice:stop:\nservice:restart:' ]] || fail "CLI actions changed: $(cat "$WORKDIR/cli-effects")"
jq -e '.dns == {} and (.route | has("default_domain_resolver") | not)' "$is_config_json" >/dev/null || fail 'CLI DNS action did not keep its existing behavior'
CASE
}

for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
    [[ -f $core_file ]] || fail "missing implementation: $core_file"
    run_bbr_confirmation_case "$core_file"
    run_dns_confirmation_case "$core_file"
    run_block_cn_confirmation_case "$core_file"
    run_update_confirmation_case "$core_file"
    run_service_confirmation_case "$core_file"
    run_cli_no_confirmation_case "$core_file"
done

echo 'PASS: system impact confirmation'
