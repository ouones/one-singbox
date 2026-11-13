#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fail() {
    echo "FAIL: $*"
    exit 1
}

run_node_delete_confirmation_matrix() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL($CORE_FILE): $*"
    exit 1
}

source <(sed -n '/^interactive_read() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^run_interactive_operation() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^confirm_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^del() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
_green() { printf '%s' "$*"; }
err() { printf '%s\n' "$*" >&2; return 1; }
apply_node_config_lifecycle() {
    printf 'delete:%s\n' "$2" >>"$WORKDIR/effects"
}

is_main_start=1
is_dont_get_ip=1
is_conf_dir="$WORKDIR/conf"
is_config_file=node.json
is_config_name='测试节点'
mkdir -p "$is_conf_dir"
printf '{}\n' >"$is_conf_dir/$is_config_file"

for input in y Y n N '' 0 yes 'Y '; do
    : >"$WORKDIR/effects"
    output=$(printf '%s\n\n' "$input" | menu_action del 2>&1)
    [[ $output == *'测试节点'* && $output == *'node.json'* ]] || fail "input '$input' did not identify the node and its config file: $output"
    [[ $output == *'删除范围包括该节点的配置、关联元数据和运行时路由，不影响其他节点'* ]] || fail "input '$input' did not explain the node deletion scope: $output"
    [[ $output == *'删除后将重启 sing-box'* ]] || fail "input '$input' did not explain the core restart: $output"
    if [[ $input == y || $input == Y ]]; then
        [[ $(cat "$WORKDIR/effects") == 'delete:node.json' ]] || fail "input '$input' did not execute node deletion: $output"
        [[ $output != *'已取消删除节点'* ]] || fail "accepted input '$input' was reported as canceled: $output"
    else
        [[ ! -s "$WORKDIR/effects" ]] || fail "input '$input' executed node deletion: $output"
        [[ $output == *'已取消删除节点'* ]] || fail "input '$input' did not show cancellation: $output"
        [[ $output == *'按回车返回菜单'* ]] || fail "input '$input' did not pause after cancellation: $output"
    fi
done
CASE
}

run_relay_delete_confirmation_matrix() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL($CORE_FILE): $*"
    exit 1
}

source <(sed -n '/^interactive_read() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^run_interactive_operation() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^confirm_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_delete() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
_green() { printf '%s' "$*"; }
err() { printf '%s\n' "$*" >&2; return 1; }
shared_config_lock() { return 0; }
shared_config_unlock() { :; }
sync_runtime_node_outbound_modes() { :; }
manage() { printf 'manage:%s\n' "$*" >>"$WORKDIR/relay-effects"; }

is_main_start=1
is_conf_dir="$WORKDIR/relay-conf"
is_config_json=
mkdir -p "$is_conf_dir"
relay_file="$is_conf_dir/relay-10000.json"
printf '%s\n' '{"inbounds":[{"tag":"relay-10000.json","type":"direct","listen_port":10000,"override_address":"203.0.113.10","override_port":20000}]}' >"$relay_file"

for input in y Y n N '' 0 yes 'Y '; do
    printf '%s\n' '{"inbounds":[{"tag":"relay-10000.json","type":"direct","listen_port":10000,"override_address":"203.0.113.10","override_port":20000}]}' >"$relay_file"
    : >"$WORKDIR/relay-effects"
    output=$(printf '%s\n\n' "$input" | menu_action relay_delete 10000 2>&1)
    wait
    [[ $output == *'监听端口 10000'* && $output == *'203.0.113.10:20000'* ]] || fail "input '$input' did not identify the forwarding rule: $output"
    [[ $output == *'删除范围包括配置文件'* && $output == *'不影响其他端口转发'* && $output == *'重启 sing-box'* ]] || fail "input '$input' did not explain the forwarding deletion scope: $output"
    if [[ $input == y || $input == Y ]]; then
        [[ ! -f $relay_file ]] || fail "input '$input' did not remove the forwarding rule: $output"
        grep -Fxq 'manage:restart' "$WORKDIR/relay-effects" || fail "input '$input' did not restart sing-box: $output"
        [[ $output != *'已取消删除端口转发'* ]] || fail "accepted input '$input' was reported as canceled: $output"
    else
        [[ -f $relay_file ]] || fail "input '$input' removed the forwarding rule: $output"
        [[ ! -s "$WORKDIR/relay-effects" ]] || fail "input '$input' restarted sing-box: $output"
        [[ $output == *'已取消删除端口转发'* ]] || fail "input '$input' did not show cancellation: $output"
        [[ $output == *'按回车返回菜单'* ]] || fail "input '$input' did not pause after cancellation: $output"
    fi
done
CASE
}

run_uninstall_confirmation_matrix() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL($CORE_FILE): $*"
    exit 1
}

source <(sed -n '/^interactive_read() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^run_interactive_operation() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^confirm_exact_yes() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^uninstall() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
_green() { printf '%s' "$*"; }
show_list() { printf '%s\n' "$@"; }
is_test() { [[ $1 == number && $2 =~ ^[1-9][0-9]*$ ]] && printf '1'; }
load() { :; }
log_limit_remove() { printf 'logs\n' >>"$WORKDIR/uninstall-effects"; }
manage() { printf 'manage:%s\n' "$*" >>"$WORKDIR/uninstall-effects"; }
sed() { printf 'sed:%s\n' "$*" >>"$WORKDIR/uninstall-effects"; }

is_main_start=1
is_caddy=1
is_core=sing-box
is_systemd=
is_openrc=
is_core_dir="$WORKDIR/install/core"
is_log_dir="$WORKDIR/install/log"
is_sh_bin="$WORKDIR/install/sing-box"
is_caddy_dir="$WORKDIR/install/caddy"
is_caddy_bin="$WORKDIR/install/caddy-bin"

prepare_install() {
    mkdir -p "$is_core_dir" "$is_log_dir" "$is_caddy_dir"
    printf 'core\n' >"$is_sh_bin"
    printf 'sb\n' >"$WORKDIR/install/sb"
    printf 'caddy\n' >"$is_caddy_bin"
    : >"$WORKDIR/uninstall-effects"
}

for input in yes y Y '' 0 ' YES ' 'YES ' 'other' YES; do
    prepare_install
    output=$(printf '2\n%s\n\n' "$input" | menu_action uninstall 2>&1)
    [[ $output == *'sing-box 程序、服务和配置'* && $output == *'日志维护服务及日志'* && $output == *'one-singbox 程序、脚本和快捷命令'* ]] || fail "input '$input' did not explain the core/script removal scope: $output"
    [[ $output == *'Caddy 服务、程序及整个 /etc/caddy 安装和配置目录'* ]] || fail "input '$input' did not explain the Caddy removal scope: $output"
    if [[ $input == YES ]]; then
        [[ ! -e $is_core_dir && ! -e $is_log_dir && ! -e $is_sh_bin ]] || fail "YES did not remove the core, log, and script scope: $output"
        grep -Fxq 'manage:stop' "$WORKDIR/uninstall-effects" || fail "YES did not stop the service: $output"
        grep -Fxq 'manage:disable' "$WORKDIR/uninstall-effects" || fail "YES did not disable the service: $output"
        grep -Fxq 'manage:stop caddy' "$WORKDIR/uninstall-effects" || fail "YES did not stop Caddy: $output"
        grep -Fxq 'manage:disable caddy' "$WORKDIR/uninstall-effects" || fail "YES did not disable Caddy: $output"
        grep -Fxq 'logs' "$WORKDIR/uninstall-effects" || fail "YES did not remove the managed logs: $output"
        [[ $output != *'已取消卸载'* ]] || fail "YES was reported as canceled: $output"
    else
        [[ -d $is_core_dir && -d $is_log_dir && -f $is_sh_bin && -d $is_caddy_dir && -f $is_caddy_bin ]] || fail "input '$input' removed installation data: $output"
        [[ ! -s "$WORKDIR/uninstall-effects" ]] || fail "input '$input' changed services, logs, or shell configuration: $output"
        [[ $output == *'已取消卸载'* ]] || fail "input '$input' did not show cancellation: $output"
        [[ $output == *'按回车返回菜单'* ]] || fail "input '$input' did not pause after cancellation: $output"
    fi
done
CASE
}

run_reinstall_confirmation_matrix() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL($CORE_FILE): $*"
    exit 1
}

source <(sed -n '/^interactive_read() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^run_interactive_operation() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^confirm_exact_yes() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_pause() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^uninstall() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^get() {/,/^}/p' "$CORE_FILE")

msg() { printf '%b\n' "$*"; }
msg_ul() { printf '%s' "$*"; }
_green() { printf '%s' "$*"; }
load() { :; }
log_limit_remove() { :; }
manage() { :; }
sed() { :; }

is_main_start=1
is_caddy=
is_core=sing-box
is_systemd=
is_openrc=
is_sh_dir="$WORKDIR/reinstall/apps"
is_core_dir="$is_sh_dir/core"
is_log_dir="$is_sh_dir/log"
is_sh_bin="$is_sh_dir/sing-box"
installer_marker="$WORKDIR/reinstall/installer-ran"

prepare_reinstall() {
    mkdir -p "$is_core_dir" "$is_log_dir"
    rm -f "$installer_marker"
    printf 'core\n' >"$is_sh_bin"
    printf '#!/usr/bin/env bash\nprintf installed > %q\n' "$installer_marker" >"$is_sh_dir/install.sh"
}

for input in yes y Y '' 0 ' YES ' 'YES ' 'other' YES; do
    prepare_reinstall
    output=$(printf '%s\n\n' "$input" | menu_action get reinstall 2>&1)
    [[ $output == *'sing-box 程序、服务和配置'* && $output == *'日志维护服务及日志'* && $output == *'one-singbox 程序、脚本和快捷命令'* ]] || fail "input '$input' did not explain the reinstall removal scope: $output"
    [[ $output == *'Caddy 未安装，不涉及 Caddy 删除'* ]] || fail "input '$input' did not explain the Caddy scope: $output"
    if [[ $input == YES ]]; then
        [[ -f $installer_marker ]] || fail "YES did not run the installer: $output"
        [[ $output != *'已取消'* ]] || fail "YES was reported as canceled: $output"
    else
        [[ ! -e $installer_marker ]] || fail "input '$input' ran the installer: $output"
        [[ -d $is_core_dir && -d $is_log_dir && -f $is_sh_bin ]] || fail "input '$input' removed installation data: $output"
        [[ $output == *'已取消'* ]] || fail "input '$input' did not show cancellation: $output"
        [[ $output == *'按回车返回菜单'* ]] || fail "input '$input' did not pause after cancellation: $output"
        [[ $output != *'检测到脚本已安装'* ]] || fail "input '$input' reported conflicting post-cancel state: $output"
    fi
done
CASE
}

for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
    [[ -f $core_file ]] || fail "missing implementation: $core_file"
    rm -rf "$workdir/effects" "$workdir/conf" "$workdir/relay-effects" "$workdir/relay-conf"
    run_node_delete_confirmation_matrix "$core_file"
    run_relay_delete_confirmation_matrix "$core_file"
    run_uninstall_confirmation_matrix "$core_file"
    run_reinstall_confirmation_matrix "$core_file"
done

echo 'PASS: destructive operation confirmation matrix'
