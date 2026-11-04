#!/usr/bin/env bash
set -o pipefail
repo_root=$(cd "$(dirname "$0")" && pwd)
for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
CORE_FILE=$core_file REPO_ROOT=$repo_root bash <<'CASE' || exit 1
set -o pipefail
fail() { printf 'FAIL(%s): %s\n' "$CORE_FILE" "$*"; exit 1; }
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
source "$CORE_FILE"
is_core_dir=$workdir/core
is_conf_dir=$workdir/conf
is_config_json=$workdir/config.json
is_core_bin=$workdir/sing-box
is_dont_auto_exit=1
export ip=203.0.113.10 is_dont_get_ip=1
mkdir -p "$is_conf_dir" "$is_core_dir"
printf '%s\n' '#!/bin/bash' '[[ $1 == generate ]] && printf "Private key: private-key-value\\nPublic key: public-key-value\\n"' '[[ $1 == check && -f ${REJECT_CHECK_FILE:-/nonexistent} ]] && exit 1' 'exit 0' >"$is_core_bin"
chmod +x "$is_core_bin"
export REJECT_CHECK_FILE=$workdir/reject-check
manage() { :; }
systemctl() {
    case $1 in
    restart)
        if [[ -f $workdir/fail-restart ]]; then rm "$workdir/fail-restart"; return 1; fi
        [[ ! -f $is_conf_dir/VLESS-REALITY-12345.json ]] || jq -r '.inbounds[0].listen' "$is_conf_dir/VLESS-REALITY-12345.json" >"$workdir/active-listen"
        ;;
    is-active) : ;;
    show) echo 1234 ;;
    esac
}
sleep() { :; }
node_port_used() { :; }
cat >"$is_conf_dir/VLESS-REALITY-12345.json" <<'JSON'
{"inbounds":[{"tag":"VLESS-REALITY-12345.json","type":"vless","listen":"::","listen_port":12345,"users":[{"uuid":"11111111-1111-1111-1111-111111111111"}],"tls":{"enabled":true,"server_name":"old.example.com","reality":{"enabled":true,"private_key":"abcdefghijklmnopqrstuvwxyz1234567890abcd"}}}],"outbounds":[{"type":"direct"},{"tag":"public_key_abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd","type":"direct"}]}
JSON
# A competing operation must prevent a shared configuration change.
mkdir -p "$is_core_dir/.frontend-state"
(flock -x 9; touch "$workdir/locked"; while [[ ! -e $workdir/release ]]; do /bin/sleep 0.02; done) 9>"$is_core_dir/.frontend-state/lock" &
lock_pid=$!
while [[ ! -e $workdir/locked ]]; do /bin/sleep 0.02; done
if (main change VLESS-REALITY-12345.json sni blocked.example.com >/dev/null 2>&1); then
    touch "$workdir/release"; wait "$lock_pid"; fail 'concurrent edit was not rejected'
fi
if (main change VLESS-REALITY-12345.json entry 127.0.0.1 >/dev/null 2>&1); then
    touch "$workdir/release"; wait "$lock_pid"; fail 'concurrent entry edit reported success'
fi
jq -e '.inbounds[0].listen == "::"' "$is_conf_dir/VLESS-REALITY-12345.json" >/dev/null || fail 'rejected edit changed listener'
touch "$workdir/release"
wait "$lock_pid"
if (main frontend status >/dev/null 2>&1); then fail 'removed frontend command accepted'; fi
# Old frontend state must have no effect on ordinary operations.
printf 'invalid old state\n' >"$is_core_dir/frontend.json"
(main add reality 23456 22222222-2222-2222-2222-222222222222 new.example.com >/dev/null) || fail 'create ordinary Reality node'
jq -e '.inbounds[0].listen == "::" and .inbounds[0].listen_port == 23456' "$is_conf_dir/VLESS-REALITY-23456.json" >/dev/null || fail 'new node default listener'
cp "$is_conf_dir/VLESS-REALITY-12345.json" "$workdir/original-node"
touch "$REJECT_CHECK_FILE"
if output=$(main change VLESS-REALITY-12345.json entry 127.0.0.1 2>&1); then fail 'invalid candidate reported success'; fi
[[ $output == *'完整候选节点配置校验失败'* ]] || fail "candidate validation failure not reported: $output"
cmp -s "$workdir/original-node" "$is_conf_dir/VLESS-REALITY-12345.json" || fail 'failed validation changed node'
[[ ! -e $workdir/active-listen ]] || fail 'failed validation restarted service'
rm "$REJECT_CHECK_FILE"
touch "$workdir/fail-restart"
if output=$(main change VLESS-REALITY-12345.json entry 127.0.0.1 2>&1); then fail 'failed service restart reported success'; fi
[[ $output == *'已恢复原配置并恢复服务'* ]] || fail "restart recovery not reported: $output"
cmp -s "$workdir/original-node" "$is_conf_dir/VLESS-REALITY-12345.json" || fail 'failed restart did not restore node'
[[ $(cat "$workdir/active-listen") == '::' ]] || fail 'failed restart did not restore running listener'
is_dont_show_info=1
info VLESS-REALITY-12345.json
[[ $is_url == *'@203.0.113.10:12345'* ]] || fail "failed restart changed share address: $is_url"
main change VLESS-REALITY-12345.json entry 127.0.0.1 >/dev/null || fail 'entry change'
jq -e '.inbounds[0].listen == "127.0.0.1"' "$is_conf_dir/VLESS-REALITY-12345.json" >/dev/null || fail 'entry changes listener'
[[ $(cat "$workdir/active-listen" 2>/dev/null) == 127.0.0.1 ]] || fail 'entry change applies the listener to the running service'
unset is_change_id
printf '8\n127.0.0.2\n' | main change VLESS-REALITY-12345.json >/dev/null 2>&1 || fail 'menu entry change'
[[ $(cat "$workdir/active-listen") == 127.0.0.2 ]] || fail 'menu entry change applies the listener to the running service'
main change VLESS-REALITY-12345.json entry 127.0.0.1 >/dev/null || fail 'restore entry after menu change'
main change VLESS-REALITY-12345.json port 12346 >/dev/null || fail 'port change'
node=$is_conf_dir/VLESS-REALITY-12346.json
jq -e '.inbounds[0].listen == "127.0.0.1" and .inbounds[0].listen_port == 12346' "$node" >/dev/null || fail 'port change preserves internal listener'
main change VLESS-REALITY-12346.json sni new.example.com >/dev/null || fail 'SNI change'
jq -e '.inbounds[0].listen == "127.0.0.1" and .inbounds[0].tls.server_name == "new.example.com"' "$node" >/dev/null || fail 'SNI change preserves internal listener'
is_dont_show_info=1
info VLESS-REALITY-12346.json
[[ $is_url == *'@127.0.0.1:12346'* ]] || fail "share URL uses selected entry and port: $is_url"
main del VLESS-REALITY-12346.json >/dev/null || fail 'delete'
[[ ! -e $node ]] || fail 'node was not deleted'
[[ $(cat "$is_core_dir/frontend.json") == 'invalid old state' ]] || fail 'old state was modified'
# Caddy-backed creation still works with the same shared lock.
(
    is_sh_dir=$REPO_ROOT
    is_caddy=1
    is_caddy_dir=$workdir/caddy
    is_caddyfile=$is_caddy_dir/Caddyfile
    is_caddy_conf=$is_caddy_dir/conf.d
    is_https_port=443
    is_http_port=80
    is_dont_test_host=1
    is_change= is_config_file= is_new_protocol= host=
    mkdir -p "$is_caddy_dir"
    main add wss caddy.example 33333333-3333-3333-3333-333333333333 /ws >/dev/null
) || fail 'Caddy-backed node creation'
[[ -s $workdir/caddy/conf.d/caddy.example.conf ]] || fail 'Caddy site missing'
flock -n "$is_core_dir/.frontend-state/lock" -c true || fail 'Caddy did not release shared lock'
CASE
done
echo 'PASS: ordinary Reality lifecycle remains independent of external frontend'
