#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

setup_case_env() {
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
version) printf 'sing-box version 1.14.4\n' ;;
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
if [[ $1 == is-active ]]; then
    [[ $2 == --quiet ]] || printf 'active\n'
    exit 0
fi
if [[ $1 == show ]]; then
    printf '4321\n'
    exit 0
fi
printf '%s\n' "$*" >>"${SERVICE_LOG:?}"
exit 0
FAKE_SYS
    cat >"$case_dir/bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
    local real_sed
    real_sed=$(command -v sed)
    cat >"$case_dir/bin/sed" <<FAKE_SED
#!/usr/bin/env bash
for arg in "\$@"; do
    [[ \$arg == /root/.bashrc ]] && exit 0
done
exec "$real_sed" "\$@"
FAKE_SED
    local real_rm
    real_rm=$(command -v rm)
    cat >"$case_dir/bin/rm" <<FAKE_RM
#!/usr/bin/env bash
safe_args=()
for arg in "\$@"; do
    [[ \$arg == /lib/systemd/system/* || \$arg == /etc/init.d/* ]] && continue
    safe_args+=("\$arg")
done
(( \${#safe_args[@]} == 0 )) && exit 0
exec "$real_rm" "\${safe_args[@]}"
FAKE_RM
    chmod +x "$case_dir/core/bin/sing-box" "$case_dir/bin/apt-get" "$case_dir/bin/systemctl" "$case_dir/bin/sleep" "$case_dir/bin/sed" "$case_dir/bin/rm"
    printf '%s\n' "$case_dir"
}

run_node_delete_confirmation_matrix() {
    local case_dir
    case_dir=$(setup_case_env node-delete)
    export SERVICE_LOG="$case_dir/service.log"

    for input in y Y n N '' 0 yes 'Y '; do
        cat >"$case_dir/conf/node.json" <<'JSON'
{"inbounds":[{"tag":"node.json","type":"shadowsocks","listen":"::","listen_port":21001,"method":"aes-128-gcm","password":"secret"}]}
JSON
        printf '{"outbound_mode":"V4优先","node_name":"测试节点"}\n' >"$case_dir/conf/.quan-meta/node.json.meta.json"
        printf '{"log":{"level":"info"},"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$case_dir/core/config.json"
        : >"$SERVICE_LOG"

        output=$(
            PATH="$case_dir/bin:$PATH" bash -c '
                set -o pipefail
                is_core_dir="$1/core"
                is_conf_dir="$1/conf"
                is_log_dir="$1/log"
                is_sh_dir="$1/sh"
                is_sh_bin="$1/bin/sb"
                is_config_json="$1/core/config.json"
                is_core_bin="$1/core/bin/sing-box"
                is_caddy_dir="$1/caddy"
                is_core_ver=1.14.4
                is_sh_ver=test
                source "$1/sh/src/core.sh"
                is_main_menu
            ' _ "$case_dir" <<<$'1\n4\n1\n'"$input"$'\n0\nq\n' 2>&1
        )
        [[ $output == *'node.json'* ]] || fail "input '$input' did not identify the node config file: $output"
        [[ $output == *'删除范围包括该节点的配置、关联元数据和运行时路由，不影响其他节点'* ]] || fail "input '$input' did not explain the node deletion scope: $output"
        [[ $output == *'删除后将重启 sing-box'* ]] || fail "input '$input' did not explain the core restart: $output"
        if [[ $input == y || $input == Y ]]; then
            [[ ! -e $case_dir/conf/node.json ]] || fail "input '$input' did not execute node deletion: $output"
            grep -Fq 'restart sing-box' "$SERVICE_LOG" || fail "input '$input' did not restart sing-box: $(cat "$SERVICE_LOG")"
            [[ $output != *'已取消删除节点'* ]] || fail "accepted input '$input' was reported as canceled: $output"
        else
            [[ -f $case_dir/conf/node.json ]] || fail "input '$input' executed node deletion: $output"
            [[ ! -s $SERVICE_LOG ]] || fail "input '$input' restarted sing-box: $(cat "$SERVICE_LOG")"
            [[ $output == *'已取消删除节点'* ]] || fail "input '$input' did not show cancellation: $output"
            [[ $output != *'按回车返回菜单'* ]] || fail "input '$input' left an extra pause after cancellation: $output"
        fi
    done
}

run_relay_delete_confirmation_matrix() {
    local case_dir
    case_dir=$(setup_case_env relay-delete)
    export SERVICE_LOG="$case_dir/relay-service.log"

    for input in y Y n N '' 0 yes 'Y '; do
        printf '%s\n' '{"inbounds":[{"tag":"relay-10000.json","type":"direct","listen_port":10000,"override_address":"203.0.113.10","override_port":20000}]}' >"$case_dir/conf/relay-10000.json"
        : >"$SERVICE_LOG"
        output=$(
            PATH="$case_dir/bin:$PATH" bash -c '
                set -o pipefail
                is_core_dir="$1/core"
                is_conf_dir="$1/conf"
                is_log_dir="$1/log"
                is_sh_dir="$1/sh"
                is_sh_bin="$1/bin/sb"
                is_config_json="$1/core/config.json"
                is_core_bin="$1/core/bin/sing-box"
                is_caddy_dir="$1/caddy"
                is_core_ver=1.14.4
                is_sh_ver=test
                source "$1/sh/src/core.sh"
                is_main_menu
            ' _ "$case_dir" <<<$'2\n4\n1\n'"$input"$'\n0\nq\n' 2>&1
        )
        [[ $output == *'监听端口 10000'* && $output == *'203.0.113.10:20000'* ]] || fail "input '$input' did not identify the forwarding rule: $output"
        [[ $output == *'删除范围包括配置文件'* && $output == *'不影响其他端口转发'* && $output == *'重启 sing-box'* ]] || fail "input '$input' did not explain the forwarding deletion scope: $output"
        if [[ $input == y || $input == Y ]]; then
            [[ ! -f $case_dir/conf/relay-10000.json ]] || fail "input '$input' did not remove the forwarding rule: $output"
            grep -Fq 'restart sing-box' "$SERVICE_LOG" || fail "input '$input' did not restart sing-box: $(cat "$SERVICE_LOG")"
            [[ $output != *'已取消删除端口转发'* ]] || fail "accepted input '$input' was reported as canceled: $output"
        else
            [[ -f $case_dir/conf/relay-10000.json ]] || fail "input '$input' removed the forwarding rule: $output"
            [[ ! -s $SERVICE_LOG ]] || fail "input '$input' restarted sing-box: $(cat "$SERVICE_LOG")"
            [[ $output == *'已取消删除端口转发'* ]] || fail "input '$input' did not show cancellation: $output"
            [[ $output != *'按回车返回菜单'* ]] || fail "input '$input' left an extra pause after cancellation: $output"
        fi
    done
}

run_uninstall_confirmation_matrix() {
    local case_dir
    case_dir=$(setup_case_env uninstall)

    for input in yes y Y '' 0 ' YES ' 'YES ' 'other' YES; do
        mkdir -p "$case_dir/install/core" "$case_dir/install/log" "$case_dir/install/caddy"
        printf 'core\n' >"$case_dir/install/sing-box"
        printf 'sb\n' >"$case_dir/install/sb"
        printf 'caddy\n' >"$case_dir/install/caddy-bin"
        : >"$case_dir/uninstall-effects"

        output=$(
            CASE_DIR="$case_dir" PATH="$case_dir/bin:$PATH" bash -c '
                set -o pipefail
                is_core_dir="$CASE_DIR/install/core"
                is_conf_dir="$CASE_DIR/conf"
                is_log_dir="$CASE_DIR/install/log"
                is_sh_dir="$CASE_DIR/sh"
                is_sh_bin="$CASE_DIR/install/sing-box"
                is_config_json="$CASE_DIR/core/config.json"
                is_core_bin="$CASE_DIR/core/bin/sing-box"
                is_caddy_dir="$CASE_DIR/install/caddy"
                is_core_ver=1.14.4
                is_sh_ver=test
                source "$CASE_DIR/sh/src/core.sh"
                is_caddy=1
                is_caddy_bin="$CASE_DIR/install/caddy-bin"
                is_systemd=1
                is_openrc=
                qrcode_dependency_checked() { return 0; }
                SERVICE_LOG="$CASE_DIR/uninstall-effects"
                export SERVICE_LOG
                log_limit_remove() { printf "logs\n" >>"$CASE_DIR/uninstall-effects"; }
                load() { [[ $1 == log.sh ]] && return 0; . "$is_sh_dir/src/$1"; }
                is_main_menu
            ' <<<$'8\n2\n'"$input"$'\nq\n' 2>&1
        )
        [[ $output == *'sing-box 程序、服务和配置'* && $output == *'日志维护服务及日志'* && $output == *'one-singbox 程序、脚本和快捷命令'* ]] || fail "input '$input' did not explain the core/script removal scope: $output"
        [[ $output == *'Caddy 服务、程序及整个 /etc/caddy 安装和配置目录'* ]] || fail "input '$input' did not explain the Caddy removal scope: $output"
        if [[ $input == YES ]]; then
            [[ ! -e $case_dir/install/core && ! -e $case_dir/install/log && ! -e $case_dir/install/sing-box && ! -e $case_dir/install/caddy && ! -e $case_dir/install/caddy-bin ]] || fail "YES did not remove the core, log, script, and Caddy scope: $output"
            grep -Fxq 'stop sing-box' "$case_dir/uninstall-effects" || fail "YES did not stop the service: $output"
            grep -Fxq 'disable sing-box' "$case_dir/uninstall-effects" || fail "YES did not disable the service: $output"
            grep -Fxq 'stop caddy' "$case_dir/uninstall-effects" || fail "YES did not stop Caddy: $output"
            grep -Fxq 'disable caddy' "$case_dir/uninstall-effects" || fail "YES did not disable Caddy: $output"
            grep -Fxq 'logs' "$case_dir/uninstall-effects" || fail "YES did not remove the managed logs: $output"
            [[ $output != *'已取消卸载'* ]] || fail "YES was reported as canceled: $output"
        else
            [[ -d $case_dir/install/core && -d $case_dir/install/log && -f $case_dir/install/sing-box && -d $case_dir/install/caddy && -f $case_dir/install/caddy-bin ]] || fail "input '$input' removed installation data: $output"
            [[ ! -s $case_dir/uninstall-effects ]] || fail "input '$input' changed services or logs: $output"
            [[ $output == *'已取消卸载'* ]] || fail "input '$input' did not show cancellation: $output"
            [[ $output != *'按回车返回菜单'* ]] || fail "input '$input' left an extra pause after cancellation: $output"
        fi
    done
}

run_reinstall_confirmation_matrix() {
    local case_dir
    case_dir=$(setup_case_env reinstall)
    local installer_marker="$case_dir/reinstall-ran"

    for input in yes y Y '' 0 ' YES ' 'YES ' 'other' YES; do
        mkdir -p "$case_dir/reinstall/apps/src" "$case_dir/reinstall/core" "$case_dir/reinstall/log"
        cp -R "$repo_root/src/." "$case_dir/reinstall/apps/src/"
        rm -f "$installer_marker"
        printf 'core\n' >"$case_dir/reinstall/sing-box"
        printf '#!/usr/bin/env bash\nprintf installed > %q\nprintf %s > %q\nchmod +x %q\n' "$installer_marker" '#!/usr/bin/env bash
printf "RELOADED_PANEL\n"' "$case_dir/reinstall/sing-box" "$case_dir/reinstall/sing-box" >"$case_dir/reinstall/apps/install.sh"

        output=$(
            CASE_DIR="$case_dir" PATH="$case_dir/bin:$PATH" bash -c '
                set -o pipefail
                is_sh_dir="$CASE_DIR/reinstall/apps"
                is_core_dir="$CASE_DIR/reinstall/core"
                is_conf_dir="$CASE_DIR/conf"
                is_log_dir="$CASE_DIR/reinstall/log"
                is_sh_bin="$CASE_DIR/reinstall/sing-box"
                is_config_json="$CASE_DIR/core/config.json"
                is_core_bin="$CASE_DIR/core/bin/sing-box"
                is_core_ver=1.14.4
                is_sh_ver=test
                source "$CASE_DIR/reinstall/apps/src/core.sh"
                is_caddy=
                is_systemd=
                is_openrc=
                touch "$is_core_dir/qrcode-dependency-checked"
                is_main_menu
            ' <<<$'5\n5\n'"$input"$'\n0\nq\n' 2>&1
        )
        [[ $output == *'sing-box 程序、服务和配置'* && $output == *'日志维护服务及日志'* && $output == *'one-singbox 程序、脚本和快捷命令'* ]] || fail "input '$input' did not explain the reinstall removal scope: $output"
        [[ $output == *'Caddy 未安装，不涉及 Caddy 删除'* ]] || fail "input '$input' did not explain the Caddy scope: $output"
        if [[ $input == YES ]]; then
            [[ -f $installer_marker ]] || fail "YES did not run the installer: $output"
            [[ $output == *'RELOADED_PANEL'* ]] || fail "YES did not reload the reinstalled panel: $output"
            [[ $output != *'已取消'* ]] || fail "YES was reported as canceled: $output"
        else
            [[ ! -e $installer_marker ]] || fail "input '$input' ran the installer: $output"
            [[ -d $case_dir/reinstall/core && -d $case_dir/reinstall/log && -f $case_dir/reinstall/sing-box ]] || fail "input '$input' removed installation data: $output"
            [[ $output == *'已取消'* ]] || fail "input '$input' did not show cancellation: $output"
            [[ $output != *'按回车返回菜单'* ]] || fail "input '$input' left an extra pause after cancellation: $output"
            [[ $output != *'检测到脚本已安装'* ]] || fail "input '$input' reported conflicting post-cancel state: $output"
        fi
    done
}

run_node_delete_confirmation_matrix
run_relay_delete_confirmation_matrix
run_uninstall_confirmation_matrix
run_reinstall_confirmation_matrix

echo 'PASS: destructive operation confirmation matrix'
