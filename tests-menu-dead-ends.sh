#!/usr/bin/env bash
# Regression coverage for issue #130: interactive menu dead ends, broken
# defaults, and broken post-uninstall state.
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
core_file="$repo_root/src/core.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Enter accepts the "回车默认" encryption method in both add and change flows.
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
is_core_bin=/bin/true
mkdir -p "$is_core_dir" "$is_conf_dir"
ask() { printf 'unexpected ask prompt\n'; }
info() {
    is_config_file=node.json
    net=ss
    is_protocol=ss
    ss_password=old-password
    return 0
}
get() { printf 'generated-password'; }
node_port_used() { return 1; }
create() { printf 'created:%s\n' "$ss_method"; }
meta_set() { :; }
is_random_ss_method=2022-blake3-aes-128-gcm

add_output=$(unset ss_method; is_main_start=1; port=32002; ss_password=generated-password; printf '\nmy-node\n' | add shadowsocks 2>&1) || {
    echo "FAIL: Enter must add a node with the default encryption method: $add_output" >&2
    exit 1
}
[[ $add_output == *'回车默认 2022-blake3-aes-128-gcm'* ]] || { echo "FAIL: add hides the encryption default: $add_output" >&2; exit 1; }
[[ $add_output == *'created:2022-blake3-aes-128-gcm'* ]] || { echo "FAIL: Enter did not create the node with the default method: $add_output" >&2; exit 1; }
[[ $add_output != *'输入无效'* ]] || { echo "FAIL: Enter was rejected as an invalid method: $add_output" >&2; exit 1; }

(
    add() { printf 'changed:%s\n' "$is_new_method"; }
    change_output=$(unset ss_method; printf '\n' | change node.json method 2>&1)
    [[ $change_output == *'changed:2022-blake3-aes-128-gcm'* ]] || { echo "FAIL: Enter did not change the method to the default: $change_output" >&2; exit 1; }
    [[ $change_output != *'输入无效'* ]] || { echo "FAIL: Enter was rejected as an invalid change method: $change_output" >&2; exit 1; }
) || exit 1
CASE

# End of input (Ctrl+D / EOF) aborts a manual form page instead of looping.
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
mkdir -p "$is_core_dir" "$is_conf_dir"
get_port() { tmp_port=12000; }
node_port_used() { return 1; }

printf '1\n' | relay_menu >"$case_dir/output" 2>&1
status=$?
output=$(cat "$case_dir/output")
[[ $status != 0 ]] || { echo "FAIL: end of input must not report success: $output" >&2; exit 1; }
[[ $(grep -Fc '输入监听端口' <<<"$output") == 1 ]] || { echo "FAIL: closed input re-prompted the port form: $output" >&2; exit 1; }
[[ $(grep -Fc '输入已结束，已取消当前操作。' <<<"$output") == 1 ]] || { echo "FAIL: closed input is not reported once: $output" >&2; exit 1; }
[[ $output != *'输入无效'* ]] || { echo "FAIL: closed input keeps printing invalid-input errors: $output" >&2; exit 1; }
[[ -z $(find "$is_conf_dir" -type f -print -quit) ]] || { echo "FAIL: closed input still created a forwarding rule" >&2; exit 1; }
CASE

# A completed uninstall ends the interactive session instead of repainting it.
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/install/core
is_conf_dir=$case_dir/conf
is_log_dir=$case_dir/install/log
is_sh_bin=$case_dir/install/sing-box
is_config_json=$case_dir/core/config.json
is_core_bin=/bin/true
is_caddy_dir=$case_dir/install/caddy
is_caddy_bin=$case_dir/install/caddy-bin
mkdir -p "$is_core_dir" "$is_log_dir" "$is_caddy_dir" "$is_conf_dir"
printf 'core\n' >"$is_sh_bin"
printf 'caddy\n' >"$is_caddy_bin"
qrcode_dependency_checked() { return 0; }
core_status_read() { is_core_ver=1.50; is_core_status=运行中; }
log_limit_read() { printf '200'; }
log_usage_read() { printf '0'; }
load() { [[ $1 == log.sh ]] && return 0; return 0; }
manage() { :; }
log_limit_remove() { :; }
sed() { :; }
is_caddy=1
is_systemd=
is_openrc=

printf '8\n2\nYES\n\nq\n' | is_main_menu >"$case_dir/output" 2>&1
status=$?
output=$(cat "$case_dir/output")
[[ $status == 0 ]] || { echo "FAIL: finished uninstall must end the session with success: status=$status $output" >&2; exit 1; }
[[ $output == *'卸载完成!'* ]] || { echo "FAIL: uninstall result is missing: $output" >&2; exit 1; }
[[ $output != *'按回车返回菜单'* ]] || { echo "FAIL: uninstall still asks for Enter before leaving: $output" >&2; exit 1; }
[[ $(grep -Fc -- '------------- one-singbox script' <<<"$output") == 1 ]] || { echo "FAIL: uninstall repainted the main menu: $output" >&2; exit 1; }
[[ ! -e $is_core_dir && ! -e $is_sh_bin ]] || { echo "FAIL: uninstall did not remove the installed payload" >&2; exit 1; }
CASE

# Hysteria2 / AnyTLS change menus must not offer the unsupported username item.
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
is_core_bin=/bin/true
mkdir -p "$is_core_dir" "$is_conf_dir"
is_dont_get_ip=1

for protocol in hysteria2 anytls; do
    printf '{"inbounds":[{"type":"%s","listen_port":26699,"users":[{"password":"example-password"}],"tls":{"enabled":true}}],"outbounds":[{},{}]}\n' "$protocol" >"$is_conf_dir/$protocol.json"
    output=$(printf '0\n' | change "$protocol.json" 2>&1)
    [[ $output == *'请选择更改:'* ]] || { echo "FAIL: $protocol change menu is missing: $output" >&2; exit 1; }
    [[ $output != *'用户名'* ]] || { echo "FAIL: $protocol change menu still offers 用户名: $output" >&2; exit 1; }
done

printf '{"inbounds":[{"type":"socks","listen_port":26698,"users":[{"username":"sbuser","password":"example-password"}]}],"outbounds":[{},{}]}\n' >"$is_conf_dir/socks.json"
socks_output=$(printf '0\n' | change socks.json 2>&1)
[[ $socks_output == *'用户名'* ]] || { echo "FAIL: SOCKS change menu lost its username item: $socks_output" >&2; exit 1; }
CASE

# A failed node-info load returns an error instead of rendering an empty block.
CORE_FILE=$core_file timeout 60 bash <<'CASE' || exit 1
source "$CORE_FILE"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir/core
is_conf_dir=$case_dir/conf
mkdir -p "$is_core_dir" "$is_conf_dir"
is_dont_get_ip=1
for node in 1 2; do
    printf '{"inbounds":[{"type":"shadowsocks","listen_port":%s,"method":"aes-128-gcm","password":"example-password"}],"outbounds":[{},{}]}\n' "$((30000 + node))" >"$is_conf_dir/node$node.json"
done

printf '3\n' | node_menu >"$case_dir/output" 2>&1
status=$?
output=$(cat "$case_dir/output")
[[ $status != 0 ]] || { echo "FAIL: interrupted node info must not report success: $output" >&2; exit 1; }
[[ $(grep -Fc '选择节点:' <<<"$output") == 1 ]] || { echo "FAIL: node selection prompt is missing: $output" >&2; exit 1; }
[[ $output != *'出口方式'* ]] || { echo "FAIL: failed info load rendered a partial detail block: $output" >&2; exit 1; }
[[ $output != *'--------------  -------------'* ]] || { echo "FAIL: failed info load rendered an empty detail header: $output" >&2; exit 1; }
CASE

echo 'PASS: menu dead ends, encryption default, EOF abort, uninstall exit, and info failure'
