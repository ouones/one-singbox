#!/usr/bin/env bash
# Regression coverage for issue #134: declining a confirmation or keeping the
# current log limit returns straight to the parent menu, and a reinstall reloads
# the newly installed panel instead of repainting the old session.
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

init_case_env() {
    local name=$1
    local case_dir="$workdir/$name"
    mkdir -p "$case_dir/core" "$case_dir/conf/.quan-meta" "$case_dir/log" "$case_dir/sh/src" "$case_dir/bin"
    cp -R "$repo_root/src/." "$case_dir/sh/src/"
    printf '200\n' >"$case_dir/core/log-limit-mb"
    printf '{"log":{"level":"info"},"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$case_dir/core/config.json"
    printf '%s\n' "$case_dir"
}

# Declining node delete, relay delete, uninstall, or a system impact confirmation
# returns to the parent menu without an extra "press Enter" pause.
run_cancel_policy_case() {
    local case_dir
    case_dir=$(init_case_env cancel-policy)
    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(cancel-policy): $*" >&2; exit 1; }
is_core_dir="$CASE_DIR/core"
is_conf_dir="$CASE_DIR/conf"
is_log_dir="$CASE_DIR/log"
is_sh_dir="$CASE_DIR/sh"
is_sh_bin="$CASE_DIR/bin/sb"
is_config_json="$CASE_DIR/core/config.json"
is_core_bin=/bin/true
is_core_ver=1.16.0
is_sh_ver=test
source "$CASE_DIR/sh/src/core.sh"
qrcode_dependency_checked() { return 0; }
core_status_read() { is_core_ver=1.16.0; is_core_status=运行中; }
service_action_result() { printf 'SERVICE_APPLIED:%s\n' "$1" >>"$CASE_DIR/service-effects"; }
manage() { printf 'MANAGE:%s\n' "$*" >>"$CASE_DIR/manage-effects"; }
load() { . "$is_sh_dir/src/$1"; }
printf '%s\n' '{"inbounds":[{"tag":"node.json","type":"shadowsocks","listen":"::","listen_port":21001,"method":"aes-128-gcm","password":"secret"}]}' >"$is_conf_dir/node.json"

for answer in n ''; do
    output=$(printf '1\n4\n1\n%s\n0\nq\n' "$answer" | is_main_menu 2>&1)
    [[ $output == *'已取消删除节点。'* ]] || fail "node delete cancel '$answer' is not reported: $output"
    [[ $output != *'按回车返回菜单'* ]] || fail "node delete cancel '$answer' left an extra pause: $output"
    [[ $(grep -Fc '请选择节点操作' <<<"$output") == 2 ]] || fail "node delete cancel '$answer' did not return to the node menu: $output"
    [[ -f $is_conf_dir/node.json ]] || fail "node delete cancel '$answer' removed the node"
done

printf '%s\n' '{"inbounds":[{"tag":"relay-10000.json","type":"direct","listen_port":10000,"override_address":"203.0.113.10","override_port":20000}]}' >"$is_conf_dir/relay-10000.json"
for answer in n ''; do
    output=$(printf '2\n4\n1\n%s\n0\nq\n' "$answer" | is_main_menu 2>&1)
    [[ $output == *'已取消删除端口转发。'* ]] || fail "relay delete cancel '$answer' is not reported: $output"
    [[ $output != *'按回车返回菜单'* ]] || fail "relay delete cancel '$answer' left an extra pause: $output"
    [[ $(grep -Fc '请选择端口转发操作' <<<"$output") == 2 ]] || fail "relay delete cancel '$answer' did not return to the relay menu: $output"
    [[ -f $is_conf_dir/relay-10000.json ]] || fail "relay delete cancel '$answer' removed the rule"
done

output=$(printf '8\n\nq\n' | is_main_menu 2>&1)
[[ $output == *'已取消卸载。'* ]] || fail "uninstall cancel is not reported: $output"
[[ $output != *'按回车返回菜单'* ]] || fail "uninstall cancel left an extra pause: $output"
[[ -d $is_core_dir ]] || fail 'uninstall cancel removed the installation'

: >"$CASE_DIR/service-effects"
output=$(printf '3\n4\nn\n0\nq\n' | is_main_menu 2>&1)
[[ $output == *'已取消。'* ]] || fail "restart confirmation cancel is not reported: $output"
[[ $output != *'按回车返回菜单'* ]] || fail "restart confirmation cancel left an extra pause: $output"
[[ $(grep -Fc '请选择服务操作' <<<"$output") == 2 ]] || fail "restart confirmation cancel did not return to the kernel menu: $output"
[[ ! -s $CASE_DIR/service-effects ]] || fail 'restart confirmation cancel restarted the service'

# Keeping the current log limit explains the value and returns without a pause.
output=$(printf '5\n3\n\n0\nq\n' | is_main_menu 2>&1)
[[ $output == *'已保留当前日志占用上限:'* && $output == *'200 MB'* ]] || fail "keeping the log limit is not reported: $output"
[[ $output != *'按回车返回菜单'* ]] || fail "keeping the log limit left an extra pause: $output"
[[ $(grep -Fc '请选择系统设置' <<<"$output") == 2 ]] || fail "keeping the log limit did not return to system settings: $output"
[[ $(cat "$is_core_dir/log-limit-mb") == 200 ]] || fail 'keeping the log limit rewrote the saved value'
CASE
}

# A completed reinstall reloads the newly installed panel instead of returning to
# the old session's system settings page.
run_reinstall_reload_case() {
    local case_dir="$workdir/reinstall-reload"
    mkdir -p "$case_dir/core" "$case_dir/conf" "$case_dir/log" "$case_dir/sh/src" "$case_dir/install"
    cp -R "$repo_root/src/." "$case_dir/sh/src/"
    printf 'core\n' >"$case_dir/install/sing-box"
    cat >"$case_dir/sh/install.sh" <<INSTALLER
printf '#!/usr/bin/env bash\necho NEW_PANEL_LOADED\nexit 0\n' >"$case_dir/install/sing-box"
chmod +x "$case_dir/install/sing-box"
echo INSTALLER_RAN
INSTALLER

    CASE_DIR="$case_dir" bash <<'CASE' || exit 1
set -o pipefail
fail() { echo "FAIL(reinstall-reload): $*" >&2; exit 1; }
is_core_dir="$CASE_DIR/core"
is_conf_dir="$CASE_DIR/conf"
is_log_dir="$CASE_DIR/log"
is_sh_dir="$CASE_DIR/sh"
is_sh_bin="$CASE_DIR/install/sing-box"
is_config_json="$CASE_DIR/core/config.json"
is_core_bin=/bin/true
is_core_ver=1.16.0
is_sh_ver=test
source "$CASE_DIR/sh/src/core.sh"
qrcode_dependency_checked() { return 0; }
core_status_read() { is_core_ver=1.16.0; is_core_status=运行中; }
load() { . "$is_sh_dir/src/$1"; }
manage() { :; }
log_limit_remove() { :; }
sed() { :; }
printf '200\n' >"$is_core_dir/log-limit-mb"
printf '{"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_config_json"

output=$(printf '5\n5\nYES\n' | is_main_menu 2>&1); status=$?
[[ $status == 0 ]] || fail "reloaded panel exit status: $status output=$output"
[[ $output == *'INSTALLER_RAN'* ]] || fail "reinstall did not run the installer: $output"
[[ $output == *'正在重新加载新版本面板...'* ]] || fail "reinstall does not announce the reload: $output"
[[ $output == *'NEW_PANEL_LOADED'* ]] || fail "reinstall did not reload the new panel: $output"
[[ $output != *'按回车返回菜单'* ]] || fail "reinstall waited for Enter: $output"
[[ $(grep -Fc -- '------------- one-singbox script' <<<"$output") == 1 ]] || fail "reinstall repainted the old panel: $output"
CASE
}

run_cancel_policy_case
run_reinstall_reload_case

echo 'PASS: cancel paths return without a pause and reinstall reloads the new panel'
