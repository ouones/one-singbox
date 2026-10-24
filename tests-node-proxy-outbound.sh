#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
cleanup() {
    rm -rf "$workdir"
}
trap cleanup EXIT

fake_bin="$workdir/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/sing-box" <<'FAKE_CORE'
#!/usr/bin/env bash
if [[ $1 == check ]]; then
    printf '%s\n' "$*" >>"$FAKE_CORE_LOG"
    config=
    conf_dir=
    while [[ $# -gt 0 ]]; do
        case $1 in
        -c) config=$2; shift 2 ;;
        -C) conf_dir=$2; shift 2 ;;
        *) shift ;;
        esac
    done
    [[ $config && -f $config && $conf_dir && -d $conf_dir ]] || exit 2
    [[ $config != "$is_config_json" ]] || exit 3
    [[ ${TEST_REJECT_CHECK:-0} != 1 ]] || exit 1
    jq -e '.outbounds | type == "array"' "$config" >/dev/null || exit 4
    shopt -s nullglob
    for file in "$conf_dir"/*.json; do
        jq -e . "$file" >/dev/null || exit 5
    done
fi
FAKE_CORE
chmod +x "$fake_bin/sing-box"

cat >"$fake_bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SERVICE_LOG"
case $1 in
restart)
    count=0
    [[ -f $RESTART_COUNT_FILE ]] && read -r count <"$RESTART_COUNT_FILE"
    count=$((count + 1))
    printf '%s\n' "$count" >"$RESTART_COUNT_FILE"
    if [[ $count == 1 && ${RESTART_MOUNT_CONFIG:-} ]]; then
        mount --bind "$RESTART_MOUNT_SOURCE" "$RESTART_MOUNT_CONFIG" || exit 1
        mount -o remount,bind,ro "$RESTART_MOUNT_CONFIG" || exit 1
        exit 1
    fi
    [[ ,${RESTART_FAIL_AT:-0}, != *,$count,* ]] || exit 1
    ;;
is-active)
    [[ ${SERVICE_ACTIVE:-1} == 1 ]] || exit 1
    ;;
show)
    printf '%s\n' "${SERVICE_PID:-4321}"
    ;;
esac
FAKE_SYSTEMCTL
chmod +x "$fake_bin/systemctl"

cat >"$fake_bin/rc-service" <<'FAKE_OPENRC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SERVICE_LOG"
case $2 in
restart)
    count=0
    [[ -f $RESTART_COUNT_FILE ]] && read -r count <"$RESTART_COUNT_FILE"
    count=$((count + 1))
    printf '%s\n' "$count" >"$RESTART_COUNT_FILE"
    [[ ,${RESTART_FAIL_AT:-0}, != *,$count,* ]] || exit 1
    ;;
status)
    [[ ${SERVICE_ACTIVE:-1} == 1 ]]
    ;;
esac
FAKE_OPENRC
chmod +x "$fake_bin/rc-service"

cat >"$fake_bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
chmod +x "$fake_bin/sleep"

fail() {
    echo "FAIL: $1"
    exit 1
}

run_core_case() {
    local core_file=$1 scenario=$2
    CORE_FILE="$core_file" TEST_SCENARIO="$scenario" FAKE_CORE="$fake_bin/sing-box" PATH="$fake_bin:$PATH" bash <<'CASE'
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $1"
    exit 1
}

case_dir=$(mktemp -d)
cleanup() {
    rm -rf "$case_dir"
}
trap cleanup EXIT

source "$CORE_FILE"

is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$FAKE_CORE"
is_core_ver=1.14.0
is_dont_show_info=1
is_no_manage_msg=1
export ip=203.0.113.10 is_dont_get_ip=1
mkdir -p "$is_conf_dir/.quan-meta"

export SERVICE_LOG="$case_dir/service.log"
export RESTART_COUNT_FILE="$case_dir/restart-count"
export FAKE_CORE_LOG="$case_dir/core-check.log"
: >"$SERVICE_LOG"
: >"$FAKE_CORE_LOG"

cat >"$is_conf_dir/node-one.json" <<'EOF'
{"inbounds":[{"tag":"node-one.json","type":"shadowsocks","listen":"::","listen_port":12345,"method":"aes-128-gcm","password":"local-password"}]}
EOF
jq -n '{node_name:"local-node",entry_addr:"edge.example.com",outbound_mode:"V4优先",custom:"preserve"}' >"$is_conf_dir/.quan-meta/node-one.json.meta.json"
meta_file="$is_conf_dir/.quan-meta/node-one.json.meta.json"
cat >"$is_config_json" <<'EOF'
{"dns":{},"route":{"default_domain_resolver":"local","rules":[{"action":"resolve","domain":["example.com"]},{"action":"hijack-dns","protocol":"dns"},{"action":"route","outbound":"direct"}]},"outbounds":[{"tag":"direct","type":"direct"},{"tag":"custom","type":"direct"}]}
EOF

ss_auth=$(printf '%s' 'aes-128-gcm:secret' | base64 | tr -d '\n')
ss_uri="ss://${ss_auth}@127.0.0.1:8388#Upstream"

restart_count() {
    grep -c '^restart ' "$SERVICE_LOG" 2>/dev/null || true
}

case $TEST_SCENARIO in
happy)
    ;;
parser-ss2022)
    key_one=$(printf '%s' '1234567890123456' | base64 | tr -d '\n')
    key_two=$(printf '%s' 'abcdefghijklmnop' | base64 | tr -d '\n')
    method=2022-blake3-aes-128-gcm
    multi_password="$key_one:$key_two"
    valid_auth=$(printf '%s:%s' "$method" "$multi_password" | base64 | tr -d '\n')
    parse_proxy_uri ss "ss://${valid_auth}@127.0.0.1:8388#TwoKeys" || fail "SS2022 multi-key password should be accepted"
    [[ $(jq -r '.password' <<<"$outbound_proxy_config_json") == "$multi_password" ]] || fail "SS2022 multi-key password must not be truncated"
    invalid_key="${key_one%%=*}!"
    invalid_auth=$(printf '%s:%s' "$method" "$invalid_key:$key_two" | base64 | tr -d '\n')
    if parse_proxy_uri ss "ss://${invalid_auth}@127.0.0.1:8388#InvalidKey"; then
        fail "SS2022 key with invalid trailing Base64 must be rejected"
    fi
    ss_uri="ss://${valid_auth}@127.0.0.1:8388#TwoKeys"
    change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1)
    [[ $change_output == *"配置已应用"* ]] || fail "SS2022 multi-key link should apply through the menu: $change_output"
    jq -e --arg password "$multi_password" '.outbound_proxy.config.method == "2022-blake3-aes-128-gcm" and .outbound_proxy.config.password == $password' "$meta_file" >/dev/null || fail "SS2022 multi-key password should be stored without truncation"
    jq -e --arg password "$multi_password" '.outbounds[] | select(.tag == "managed_node_ss_node-one_json") | .method == "2022-blake3-aes-128-gcm" and .password == $password' "$is_config_json" >/dev/null || fail "SS2022 multi-key password should reach the runtime outbound"
    [[ $change_output != *"$multi_password"* && $change_output != *"ss://"* ]] || fail "SS2022 link credentials must not be echoed"
    exit 0
    ;;
ss-import-encoding)
    auth=$(printf '%s' 'aes-128-gcm:💩' | base64 | tr '+/' '-_' | tr -d '=\n')
    ss_uri="ss://${auth}@node.example:8388/#中文+Name%20one"
    change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1)
    [[ $change_output == *"配置已应用"* && $change_output == *"SS 出站 (中文+Name one)"* ]] || fail "Base64URL credentials and an encoded display name should import: $change_output"
    jq -e '.outbound_proxy.name == "中文+Name one" and .outbound_proxy.config.server == "node.example" and .outbound_proxy.config.server_port == 8388 and .outbound_proxy.config.password == "💩"' "$meta_file" >/dev/null || fail "Base64URL credentials should preserve the decoded SS fields"
    jq -e '.outbounds[] | select(.tag == "managed_node_ss_node-one_json") | .server == "node.example" and .server_port == 8388 and .password == "💩"' "$is_config_json" >/dev/null || fail "Base64URL credentials should reach the runtime outbound"
    ss_uri='ss://aes-256-gcm:p%3Aass%2B%2525%26%3D@127.0.0.1:443/?plugin=&remarks=R%2B%20%26%3DName'
    change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1)
    [[ $change_output == *"配置已应用"* && $change_output == *"SS 出站 (R+ &=Name)"* ]] || fail "percent-encoded plaintext credentials and remarks should import: $change_output"
    jq -e '.outbound_proxy.name == "R+ &=Name" and .outbound_proxy.config.server == "127.0.0.1" and .outbound_proxy.config.server_port == 443 and .outbound_proxy.config.password == "p:ass+%25&="' "$meta_file" >/dev/null || fail "plaintext credentials should split at the first colon and decode exactly once"
    jq -e '.outbounds[] | select(.tag == "managed_node_ss_node-one_json") | .password == "p:ass+%25&="' "$is_config_json" >/dev/null || fail "plaintext credentials should be saved to runtime JSON"
    [[ $change_output != *"p:ass"* && $change_output != *"ss://"* ]] || fail "SS credentials must not be echoed"
    ss_uri='ss://aes-128-gcm:ipv6-secret@[2001:db8::1]:8388/'
    change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1)
    [[ $change_output == *"配置已应用"* && $change_output == *"SS 出站 ([2001:db8::1]:8388)"* ]] || fail "unnamed IPv6 SS should display a bracketed endpoint: $change_output"
    [[ $change_output != *"ipv6-secret"* && $change_output != *"ss://"* ]] || fail "IPv6 SS credentials must not be echoed"
    exit 0
    ;;
ss-import-invalid)
    change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1)
    [[ $change_output == *"配置已应用"* ]] || fail "setup SS application failed: $change_output"
    cp "$meta_file" "$case_dir/meta.before"
    cp "$is_config_json" "$case_dir/config.before"
    nul_auth=$(printf 'aes-128-gcm:bad\000secret' | base64 | tr -d '\n')
    invalid_auth=$(printf '%s' 'aes-128-gcm:bad-secret' | base64 | tr -d '\n')!
    for bad_uri in \
        'ss://aes-128-gcm:bad-secret@127.0.0.1:8388?plugin=obfs-local' \
        'ss://aes-128-gcm:bad-secret@127.0.0.1:8388?unknown=1' \
        'ss://aes-128-gcm:bad-secret@127.0.0.1:65536' \
        'ss://aes-128-gcm:bad-secret@127.0.0.1:8388?plugin=&plugin=' \
        'ss://aes-128-gcm:bad%GGsecret@127.0.0.1:8388' \
        'ss://aes-128-gcm:bad-secret@127.0.0.1:8388?remarks=%00' \
        'ss://aes-128-gcm:bad-secret@127.0.0.1:8388?remark=&remarks=Name' \
        "ss://${invalid_auth}@127.0.0.1:8388" \
        'ss://aes-128-gcm:bad-secret@127.0.0.1:8388#Bad%' \
        'ss://aes-128-gcm:bad%00secret@127.0.0.1:8388' \
        'ss://aes-128-gcm:bad-secret@127.0.0.1:8388#Bad%00Name' \
        "ss://${nul_auth}@127.0.0.1:8388" \
        'vless://bad-secret@127.0.0.1:8388'; do
        if change_output=$(printf '5\n%s\n' "$bad_uri" | change node-one.json outbound 2>&1); then
            fail "invalid SS URI should be rejected: $bad_uri"
        fi
        [[ $change_output != *"bad-secret"* && $change_output != *"bad%00secret"* ]] || fail "invalid SS credentials must not be echoed"
        cmp -s "$case_dir/meta.before" "$meta_file" || fail "invalid SS URI must preserve metadata"
        cmp -s "$case_dir/config.before" "$is_config_json" || fail "invalid SS URI must preserve runtime config"
    done
    [[ $change_output == *"仅支持单条 ss://"* ]] || fail "wrong scheme should be explained: $change_output"
    [[ $(restart_count) == 1 ]] || fail "invalid SS URIs must not restart the service"
    change_output=$(printf '5\n%s\n' 'ss://aes-128-gcm:bad-secret@127.0.0.1:8388?unknown=1' | change node-one.json outbound 2>&1 || true)
    [[ $change_output == *"不支持的参数: unknown"* ]] || fail "unknown SS query parameter should be identified: $change_output"
    change_output=$(printf '5\n%s\n' 'ss://aes-128-gcm:bad-secret@127.0.0.1:8388?plugin=obfs-local' | change node-one.json outbound 2>&1 || true)
    [[ $change_output == *"plugin"* && $change_output == *"暂不支持"* ]] || fail "unsupported SS plugin should be identified: $change_output"
    change_output=$(printf '5\n%s\n' 'ss://aes-128-gcm:bad-secret@127.0.0.1:8388?remark=&remarks=Name' | change node-one.json outbound 2>&1 || true)
    [[ $change_output == *"remark 和 remarks 参数值冲突"* ]] || fail "conflicting display aliases should be identified: $change_output"
    cmp -s "$case_dir/meta.before" "$meta_file" || fail "SS parameter errors must preserve metadata"
    cmp -s "$case_dir/config.before" "$is_config_json" || fail "SS parameter errors must preserve runtime config"
    [[ $(restart_count) == 1 ]] || fail "SS parameter errors must not restart the service"
    exit 0
    ;;
parser-ss-encoding)
    parse_proxy_uri ss 'ss://aes-128-gcm:p%2B%25%26%3D@[2001:db8::1]:8388?remark=R%2B%20%26&remarks=R%2B%20%26#N%2B%20M' || fail "SS parser should accept escaped credentials, bracketed IPv6, and display parameters (server=$uri_server port=$uri_port query=$uri_query_json)"
    jq -e '.server == "2001:db8::1" and .server_port == 8388 and (.server_port | type == "number") and .password == "p+%&="' <<<"$outbound_proxy_config_json" >/dev/null || fail "SS parser should decode credentials once and preserve IPv6 as an unbracketed server"
    [[ $outbound_proxy_name == 'N+ M' ]] || fail "SS fragment should take precedence and preserve plus as a literal plus"
    jq -cn --arg name "$outbound_proxy_name" --argjson config "$outbound_proxy_config_json" '{outbound_mode:"SS 出站",outbound_proxy:{name:$name,config:$config}}' >"$meta_file"
    sync_runtime_node_outbound_modes || fail "IPv6 upstream should synchronize: $runtime_sync_error"
    jq -e '.outbounds[] | select(.tag == "managed_node_ss_node-one_json") | .server == "2001:db8::1" and (has("domain_resolver") | not)' "$is_config_json" >/dev/null || fail "IPv6 upstream should be emitted without a domain resolver"
    parse_ss_uri_for_outbound 'ss://aes-128-gcm:compatibility-secret@127.0.0.1:8388#LegacyWrapper' || fail "parse_ss_uri_for_outbound compatibility wrapper should keep working"
    [[ $outbound_proxy_name == 'LegacyWrapper' && $(jq -r '.password' <<<"$outbound_proxy_config_json") == 'compatibility-secret' ]] || fail "legacy SS parser wrapper should return the same normalized result"
    if parse_proxy_uri ss 'ss://aes-128-gcm:secret@[1:2:3:4:5:6:7:8:9]:8388'; then
        fail "SS parser must reject IPv6 addresses with too many groups"
    fi
    if parse_proxy_uri ss 'ss://aes-128-gcm:secret@127.0.0.1:8388?plugin=obfs-local'; then
        fail "SS plugin parameters must be rejected"
    fi
    if parse_proxy_uri ss 'ss://aes-128-gcm:secret@127.0.0.1:8388#Bad%'; then
        fail "malformed percent escape in SS name must be rejected"
    fi
    exit 0
    ;;
vless-menu)
    vless_uuid=550e8400-e29b-41d4-a716-446655440000
    vless_pbk=$(printf '%s' '01234567890123456789012345678901' | base64 | tr '+/' '-_' | tr -d '=\n')
    [[ ${TEST_VLESS_PUBLIC_KEY:-} ]] && vless_pbk=$TEST_VLESS_PUBLIC_KEY
    parse_proxy_uri vless "vless://$vless_uuid@default.example.com:443/" || fail "VLESS defaults should accept TCP, no encryption, and no security"
    jq -e '.type == "vless" and .server == "default.example.com" and .server_port == 443 and .tls == null and .transport == null and .network == null and .packet_encoding == null' <<<"$outbound_proxy_config_json" >/dev/null || fail "VLESS omitted parameters should use native defaults without adding transport or a TCP-only restriction"
    parse_proxy_uri vless "vless://$vless_uuid@default.example.com:443?remark=Query+Name&remarks=Query+Name#Fragment+Name" || fail "VLESS display remark aliases should parse"
    [[ $outbound_proxy_name == 'Fragment+Name' ]] || fail "VLESS fragment should take precedence and plus should remain literal"
    parse_proxy_uri vless "vless://$vless_uuid@default.example.com:443?remarks=Query+Name" || fail "VLESS remarks should provide a display name when no fragment is present"
    [[ $outbound_proxy_name == 'Query+Name' ]] || fail "VLESS query remark should preserve plus instead of decoding it as a space"
    parse_proxy_uri vless "vless://$vless_uuid@[2001:db8::2]:443?encryption=none&type=raw&security=none&packetEncoding=none#VLESS%20%E8%8A%82%E7%82%B9" || fail "VLESS TCP/raw with encryption=none and packetEncoding=none should parse"
    jq -e '.type == "vless" and .server == "2001:db8::2" and .server_port == 443 and (.server_port | type == "number") and .uuid == "'"$vless_uuid"'" and .packet_encoding == "" and (has("transport") | not) and (has("network") | not) and (has("tls") | not)' <<<"$outbound_proxy_config_json" >/dev/null || fail "VLESS raw should normalize to an unwrapped VLESS outbound without a TCP-only restriction"
    [[ $outbound_proxy_name == 'VLESS 节点' ]] || fail "VLESS fragment should decode UTF-8 and preserve the display name"
    parse_proxy_uri vless "vless://$vless_uuid@[2001:db8::2]:443?security=none&packetEncoding=none&packet_encoding=#PacketAliases" || fail "packetEncoding none and an empty alias should normalize to the same explicit empty value"
    [[ $(jq -r '.packet_encoding' <<<"$outbound_proxy_config_json") == '' ]] || fail "explicitly disabled packet encoding should remain an empty native string"
    if [[ ${TEST_VLESS_EXPORT_DIR:-} ]]; then printf '%s\n' "$outbound_proxy_config_json" >"$TEST_VLESS_EXPORT_DIR/vless-none.json"; fi
    parse_proxy_uri vless "vless://$vless_uuid@[2001:db8::2]:443?security=none&packetEncoding=packetaddr#PacketAddress" || fail "VLESS packetaddr encoding should parse"
    [[ $(jq -r '.packet_encoding' <<<"$outbound_proxy_config_json") == packetaddr ]] || fail "packetaddr should map to the native packet_encoding field"
    if [[ ${TEST_VLESS_EXPORT_DIR:-} ]]; then printf '%s\n' "$outbound_proxy_config_json" >"$TEST_VLESS_EXPORT_DIR/vless-packetaddr.json"; fi
    parse_proxy_uri vless "vless://$vless_uuid@vless.example.com:443?security=tls&sni=front.example.com&serverName=front.example.com&alpn=h2%2Chttp%2F1.1&fp=firefox&fingerprint=firefox&allowInsecure=1&insecure=true&packet_encoding=xudp#TLS" || fail "VLESS TLS aliases and boolean aliases with equal meaning should parse"
    jq -e '.tls.enabled == true and .tls.server_name == "front.example.com" and .tls.alpn == ["h2","http/1.1"] and .tls.utls.enabled == true and .tls.utls.fingerprint == "firefox" and .tls.insecure == true and .packet_encoding == "xudp" and .flow == null' <<<"$outbound_proxy_config_json" >/dev/null || fail "VLESS TLS fields should use native JSON types and preserve ALPN order"
    if [[ ${TEST_VLESS_EXPORT_DIR:-} ]]; then printf '%s\n' "$outbound_proxy_config_json" >"$TEST_VLESS_EXPORT_DIR/vless-tls-insecure.json"; fi
    parse_proxy_uri vless "vless://$vless_uuid@vless.example.com:443?security=tls&flow=xtls-rprx-vision#TLSVision" || fail "VLESS Vision should be accepted with TCP + TLS"
    jq -e '.flow == "xtls-rprx-vision" and .tls.enabled == true' <<<"$outbound_proxy_config_json" >/dev/null || fail "VLESS TLS + Vision should retain flow and TLS fields"
    if [[ ${TEST_VLESS_EXPORT_DIR:-} ]]; then printf '%s\n' "$outbound_proxy_config_json" >"$TEST_VLESS_EXPORT_DIR/vless-tls-vision.json"; fi
    parse_proxy_uri vless "vless://$vless_uuid@vless.example.com:443?security=tls&sni=front.example.com&fp=none#TLSDefault" || fail "TLS default certificate validation should parse"
    jq -e '.tls.enabled == true and .tls.insecure == false and (.tls | has("utls") | not)' <<<"$outbound_proxy_config_json" >/dev/null || fail "TLS should validate certificates by default and fp=none should omit uTLS"
    if [[ ${TEST_VLESS_EXPORT_DIR:-} ]]; then printf '%s\n' "$outbound_proxy_config_json" >"$TEST_VLESS_EXPORT_DIR/vless-tls.json"; fi
    parse_proxy_uri vless "vless://$vless_uuid@reality.example.com:443?security=reality&flow=xtls-rprx-vision&publicKey=$vless_pbk&pbk=$vless_pbk&sid=&shortId=&skip-cert-verify=1&insecure=true#Reality" || fail "VLESS Reality aliases, empty short ID, and Vision should parse"
    jq -e '.flow == "xtls-rprx-vision" and .tls.enabled == true and .tls.server_name == "reality.example.com" and .tls.utls.enabled == true and .tls.utls.fingerprint == "chrome" and .tls.insecure == true and .tls.reality.enabled == true and .tls.reality.public_key == "'"$vless_pbk"'" and .tls.reality.short_id == ""' <<<"$outbound_proxy_config_json" >/dev/null || fail "VLESS Reality should retain the public-key authentication and default short ID"
    if [[ ${TEST_VLESS_EXPORT_DIR:-} ]]; then printf '%s\n' "$outbound_proxy_config_json" >"$TEST_VLESS_EXPORT_DIR/vless-reality-vision.json"; fi
    for bad_uri in \
        "vless://not-a-uuid@vless.example.com:443" \
        "vless://$vless_uuid@vless.example.com:443?encryption=aes-128-gcm" \
        "vless://$vless_uuid@vless.example.com:443?type=ws&security=tls" \
        "vless://$vless_uuid@vless.example.com:443?security=none&sni=front.example.com" \
        "vless://$vless_uuid@vless.example.com:443?security=none&flow=xtls-rprx-vision" \
        "vless://$vless_uuid@vless.example.com:443?security=reality" \
        "vless://$vless_uuid@vless.example.com:443?security=reality&pbk=invalid" \
        "vless://$vless_uuid@vless.example.com:443?security=reality&pbk=$vless_pbk&sid=abc" \
        "vless://$vless_uuid@vless.example.com:443?security=reality&pbk=$vless_pbk&sid=0123456789abcdef0" \
        "vless://$vless_uuid:password@vless.example.com:443" \
        "vless://$vless_uuid@vless.example.com:0" \
        "vless://$vless_uuid@vless.example.com:65536" \
        "https://$vless_uuid@vless.example.com:443" \
        "vless://$vless_uuid@vless.example.com:443#Bad%" \
        "vless://$vless_uuid@vless.example.com:443?security=tls&fp=unknown" \
        "vless://$vless_uuid@vless.example.com:443?security=tls&allowInsecure=yes" \
        "vless://$vless_uuid@vless.example.com:443?security=tls&packetEncoding=other" \
        "vless://$vless_uuid@vless.example.com:443?security=tls&sni=a&serverName=b" \
        "vless://$vless_uuid@vless.example.com:443?security=tls&sni=a&sni=b" \
        "vless://$vless_uuid@vless.example.com:443?security=tls&allowInsecure=0&insecure=true" \
        "vless://$vless_uuid@vless.example.com:443?security=tls&path=%2Fws" \
        "vless://$vless_uuid@vless.example.com:443?security=tls&sni=%00bad"; do
        if parse_proxy_uri vless "$bad_uri"; then
            fail "unsupported or invalid VLESS URI should be rejected: $bad_uri"
        fi
    done
    vless_uri="vless://$vless_uuid@reality.example.com:443?type=raw&security=reality&flow=xtls-rprx-vision&pbk=$vless_pbk&sid=01020304#VLESS%20%E8%8A%82%E7%82%B9"
    if change_output=$(printf '6\n%s\n' "$vless_uri" | change node-one.json outbound 2>&1); then :; else fail "VLESS Reality menu entry should apply: $change_output"; fi
    [[ $change_output == *"配置已应用"* && $change_output == *"VLESS 节点"* ]] || fail "VLESS menu success should show the applied upstream name: $change_output"
    [[ $change_output != *"$vless_uuid"* && $change_output != *"$vless_pbk"* && $change_output != *"vless://"* ]] || fail "VLESS menu output must not expose credentials or the share link"
    jq -e '.outbound_mode == "VLESS 出站" and .outbound_proxy.name == "VLESS 节点" and .outbound_proxy.config.type == "vless" and .outbound_proxy.config.uuid == "'"$vless_uuid"'" and .outbound_proxy.config.tls.reality.public_key == "'"$vless_pbk"'"' "$meta_file" >/dev/null || fail "VLESS normalized config should be saved in the shared per-node proxy cache"
    jq -e '.outbounds[] | select(.tag | startswith("managed_node_vless_")) | .type == "vless" and .flow == "xtls-rprx-vision" and .tls.reality.public_key == "'"$vless_pbk"'" and (has("network") | not) and (has("transport") | not)' "$is_config_json" >/dev/null || fail "runtime VLESS outbound should carry native Reality/Vision fields without restricting proxied traffic to TCP"
    [[ $(current_outbound_mode_display node-one.json) == 'VLESS 出站 (VLESS 节点)' ]] || fail "VLESS renderer should display the upstream name"
    cp "$meta_file" "$case_dir/meta.before"
    cp "$is_config_json" "$case_dir/config.before"
    restart_before=$(restart_count)
    if change_output=$(printf '6\nvless://%s@vless.example.com:443?type=ws\n' "$vless_uuid" | change node-one.json outbound 2>&1); then
        fail "invalid VLESS replacement should fail"
    fi
    [[ $change_output == *"VLESS"* && $change_output == *"type"* ]] || fail "invalid VLESS input should name the rejected field or capability: $change_output"
    cmp -s "$case_dir/meta.before" "$meta_file" || fail "invalid VLESS replacement must preserve metadata"
    cmp -s "$case_dir/config.before" "$is_config_json" || fail "invalid VLESS replacement must preserve the public config"
    [[ $(restart_count) == "$restart_before" ]] || fail "invalid VLESS replacement must not restart the service"

    change_output=$(printf '6\n\n' | change node-one.json outbound 2>&1) || fail "cached VLESS config should be reusable: $change_output"
    change_output=$(printf '3\n' | change node-one.json outbound 2>&1) || fail "switching VLESS to direct should succeed: $change_output"
    jq -e '.outbound_mode == "仅V4" and .outbound_proxy.config.type == "vless"' "$meta_file" >/dev/null || fail "switching to direct should retain the VLESS cache"
    jq -e '[.outbounds[] | select(.tag | startswith("managed_node_vless_"))] | length == 0' "$is_config_json" >/dev/null || fail "switching to direct should remove the active VLESS outbound"
    change_output=$(printf '6\n\n' | change node-one.json outbound 2>&1) || fail "VLESS cache should remain reusable after switching direct: $change_output"
    ss_auth=$(printf '%s' 'aes-128-gcm:secret' | base64 | tr -d '\n')
    ss_uri="ss://${ss_auth}@127.0.0.1:8388#SS-Replacement"
    change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1) || fail "VLESS to SS replacement should succeed: $change_output"
    jq -e '.outbound_mode == "SS 出站" and .outbound_proxy.config.type == "shadowsocks"' "$meta_file" >/dev/null || fail "SS replacement should replace the VLESS cache"
    change_output=$(printf '6\n%s\n' "$vless_uri" | change node-one.json outbound 2>&1) || fail "SS to VLESS replacement should succeed: $change_output"
    jq -e '.outbound_mode == "VLESS 出站" and .outbound_proxy.config.type == "vless"' "$meta_file" >/dev/null || fail "VLESS replacement should replace the SS cache"
    change_output=$(printf '6\n\n' | change node-one.json mode 2>&1) || fail "non-Snell mode compatibility entry should reuse VLESS: $change_output"
    exit 0
    ;;
reject-check)
    cp "$meta_file" "$case_dir/meta.before"
    cp "$is_config_json" "$case_dir/config.before"
    export TEST_REJECT_CHECK=1
    if change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1); then
        fail "check rejection should fail the menu operation"
    fi
    [[ $change_output == *"完整配置校验失败"* ]] || fail "check rejection should explain that the original config was retained: $change_output"
    cmp -s "$case_dir/meta.before" "$meta_file" || fail "check rejection must preserve metadata"
    cmp -s "$case_dir/config.before" "$is_config_json" || fail "check rejection must preserve the public config"
    [[ $(restart_count) == 0 ]] || fail "check rejection must not restart the service"
    exit 0
    ;;
restart-fail-recovered|restart-fail-unrecovered|inactive-service|empty-mainpid)
    cp "$meta_file" "$case_dir/meta.before"
    cp "$is_config_json" "$case_dir/config.before"
    case $TEST_SCENARIO in
        restart-fail-recovered) export RESTART_FAIL_AT=1 ;;
        restart-fail-unrecovered) export RESTART_FAIL_AT=1,2 ;;
        inactive-service) export SERVICE_ACTIVE=0 ;;
        empty-mainpid) export SERVICE_PID=0 ;;
    esac
    if change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1); then
        fail "$TEST_SCENARIO should fail the menu operation"
    fi
    cmp -s "$case_dir/meta.before" "$meta_file" || fail "$TEST_SCENARIO must restore metadata"
    cmp -s "$case_dir/config.before" "$is_config_json" || fail "$TEST_SCENARIO must restore the public config"
    [[ $(restart_count) == 2 ]] || fail "$TEST_SCENARIO must attempt one application restart and one recovery restart"
    case $TEST_SCENARIO in
        restart-fail-recovered) [[ $change_output == *"已恢复原配置并恢复服务"* ]] || fail "recovery success should be reported accurately: $change_output" ;;
        restart-fail-unrecovered|inactive-service|empty-mainpid) [[ $change_output == *"原配置已恢复但服务恢复失败"* ]] || fail "recovery failure should be reported accurately: $change_output" ;;
    esac
    exit 0
    ;;
legacy-migration)
    jq -n '{node_name:"legacy",outbound_mode:"SS 出站",outbound_ss_server:"127.0.0.1",outbound_ss_port:"8388",outbound_ss_method:"aes-128-gcm",outbound_ss_password:"legacy-secret",outbound_ss_name:"Legacy",extra:"keep"}' >"$meta_file"
    change_output=$(printf '5\n\n' | change node-one.json outbound 2>&1)
    [[ $change_output == *"配置已应用"* ]] || fail "valid historical SS fields should be reusable: $change_output"
    jq -e '.outbound_proxy.name == "Legacy" and .outbound_proxy.config.password == "legacy-secret" and .extra == "keep" and (has("outbound_ss_server") | not) and (has("outbound_ss_port") | not) and (has("outbound_ss_method") | not) and (has("outbound_ss_password") | not) and (has("outbound_ss_name") | not)' "$meta_file" >/dev/null || fail "successful application should migrate old SS fields and preserve unrelated metadata"
    exit 0
    ;;
legacy-migration-check-fail)
    jq -n '{node_name:"legacy",outbound_mode:"SS 出站",outbound_ss_server:"127.0.0.1",outbound_ss_port:"8388",outbound_ss_method:"aes-128-gcm",outbound_ss_password:"legacy-secret",outbound_ss_name:"Legacy",extra:"keep"}' >"$meta_file"
    cp "$meta_file" "$case_dir/meta.before"
    cp "$is_config_json" "$case_dir/config.before"
    export TEST_REJECT_CHECK=1
    if change_output=$(printf '5\n\n' | change node-one.json outbound 2>&1); then
        fail "failed candidate check should not migrate old SS metadata"
    fi
    cmp -s "$case_dir/meta.before" "$meta_file" || fail "failed candidate check must preserve old SS fields exactly"
    cmp -s "$case_dir/config.before" "$is_config_json" || fail "failed candidate check must preserve the runtime config"
    [[ $(restart_count) == 0 ]] || fail "failed candidate check must not restart the service"
    exit 0
    ;;
broken-cache-replace)
    jq '.outbound_mode="SS 出站" | .outbound_proxy={name:"broken",config:{type:"vless",server:"old.example.com",server_port:443,uuid:"bad"}} | .outbound_ss_server="old.example.com"' "$meta_file" >"$case_dir/meta.bad"
    mv "$case_dir/meta.bad" "$meta_file"
    change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1)
    [[ $change_output == *"配置已应用"* ]] || fail "a new valid link should replace a broken active cache: $change_output"
    jq -e '.outbound_proxy.config.type == "shadowsocks" and .outbound_proxy.config.password == "secret" and (has("outbound_ss_server") | not)' "$meta_file" >/dev/null || fail "replacement should install the new unified cache"
    exit 0
    ;;
broken-cache-reuse)
    jq '.outbound_mode="SS 出站" | .outbound_proxy={name:"broken",config:{type:"vless",server:"old.example.com",server_port:443,uuid:"bad"}} | .outbound_ss_server="old.example.com"' "$meta_file" >"$case_dir/meta.bad"
    mv "$case_dir/meta.bad" "$meta_file"
    jq '.outbounds += [{tag:"managed_node_ss_node-one_json",type:"shadowsocks",server:"old-upstream.example.com",server_port:8388,method:"aes-128-gcm",password:"old-secret"}] | .route.rules = [{inbound:["node-one.json"],action:"route",outbound:"managed_node_ss_node-one_json"}] + .route.rules' "$is_config_json" >"$case_dir/config.proxy"
    mv "$case_dir/config.proxy" "$is_config_json"
    cp "$is_config_json" "$case_dir/config.before"
    if change_output=$(printf '5\n\n' | change node-one.json outbound 2>&1); then
        fail "broken active cache should not be reused"
    fi
    [[ $change_output == *"没有可复用的 Shadowsocks 配置"* ]] || fail "broken unified cache should not fall back to legacy fields: $change_output"
    cmp -s "$case_dir/config.before" "$is_config_json" || fail "broken active cache must retain the existing runtime config"
    [[ $(restart_count) == 0 ]] || fail "broken active cache must not restart the service"
    exit 0
    ;;
missing-config-success|missing-config-check-fail|missing-config-restart-fail)
    rm -f "$is_config_json"
    cp "$meta_file" "$case_dir/meta.before"
    case $TEST_SCENARIO in
        missing-config-check-fail) export TEST_REJECT_CHECK=1 ;;
        missing-config-restart-fail) export RESTART_FAIL_AT=1 ;;
    esac
    if [[ $TEST_SCENARIO == missing-config-check-fail || $TEST_SCENARIO == missing-config-restart-fail ]]; then
        if change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1); then
            fail "$TEST_SCENARIO should fail the menu operation"
        fi
        cmp -s "$case_dir/meta.before" "$meta_file" || fail "$TEST_SCENARIO must restore or retain metadata"
        [[ ! -e $is_config_json ]] || fail "$TEST_SCENARIO must preserve the original missing config state"
        [[ $(restart_count) == 0 && $TEST_SCENARIO == missing-config-check-fail ]] && exit 0
        [[ $(restart_count) == 2 ]] || fail "restart failure with a missing original config should attempt one recovery restart"
        [[ $change_output == *"已恢复原配置并恢复服务"* ]] || fail "missing config recovery should be reported accurately: $change_output"
        exit 0
    fi
    change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1)
    [[ $change_output == *"配置已应用"* && -f $is_config_json ]] || fail "application should create a missing public config after full check: $change_output"
    [[ $(restart_count) == 1 ]] || fail "missing config success should restart once"
    exit 0
    ;;
no-files-restart-fail)
    rm -f "$is_config_json" "$meta_file"
    export RESTART_FAIL_AT=1
    if change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1); then
        fail "restart failure should fail the operation when both original files were absent"
    fi
    [[ ! -e $is_config_json && ! -e $meta_file ]] || fail "rollback should restore both original files to absent"
    [[ $(restart_count) == 2 ]] || fail "missing file rollback should attempt one recovery restart"
    [[ $change_output == *"已恢复原配置并恢复服务"* ]] || fail "missing file rollback should report recovery success"
    exit 0
    ;;
config-install-failure)
    cp "$meta_file" "$case_dir/meta.before"
    cp "$is_config_json" "$case_dir/config.before"
    cp "$is_config_json" "$case_dir/config.mount"
    export TEST_CASE_DIR="$case_dir" TEST_SS_URI="$ss_uri"
    unshare --mount --propagation private bash <<'READONLY'
set -o pipefail
fail() {
    echo "FAIL(${CORE_FILE}): $1"
    exit 1
}
source "$CORE_FILE"
case_dir=$TEST_CASE_DIR
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$FAKE_CORE"
is_core_ver=1.14.0
is_dont_show_info=1
is_no_manage_msg=1
export ip=203.0.113.10 is_dont_get_ip=1
meta_file="$is_conf_dir/.quan-meta/node-one.json.meta.json"
mount --bind "$case_dir/config.mount" "$is_config_json" || fail "could not bind mount the public config"
mount -o remount,bind,ro "$is_config_json" || fail "could not make the public config mount read-only"
if change_output=$(printf '5\n%s\n' "$TEST_SS_URI" | change node-one.json outbound 2>&1); then
    fail "public config replacement failure should fail the menu operation"
fi
cmp -s "$case_dir/meta.before" "$meta_file" || fail "public config replacement failure must restore the already installed metadata"
cmp -s "$case_dir/config.before" "$is_config_json" || fail "public config replacement failure must preserve the public config"
[[ $(grep -c '^restart ' "$SERVICE_LOG" 2>/dev/null || true) == 0 ]] || fail "public config replacement failure must not restart the service"
READONLY
    [[ $? == 0 ]] || fail "read-only bind replacement failure test did not complete"
    exit 0
    ;;
file-restore-failure)
    cp "$is_config_json" "$case_dir/config.before"
    cp "$is_config_json" "$case_dir/config.mount"
    export TEST_CASE_DIR="$case_dir" TEST_SS_URI="$ss_uri"
    export RESTART_MOUNT_CONFIG="$is_config_json" RESTART_MOUNT_SOURCE="$case_dir/config.mount"
    unshare --mount --propagation private bash <<'RESTOREFAIL'
set -o pipefail
fail() {
    echo "FAIL(${CORE_FILE}): $1"
    exit 1
}
source "$CORE_FILE"
case_dir=$TEST_CASE_DIR
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$FAKE_CORE"
is_core_ver=1.14.0
is_dont_show_info=1
is_no_manage_msg=1
export ip=203.0.113.10 is_dont_get_ip=1
meta_file="$is_conf_dir/.quan-meta/node-one.json.meta.json"
cp "$meta_file" "$case_dir/meta.before"
if change_output=$(printf '5\n%s\n' "$TEST_SS_URI" | change node-one.json outbound 2>&1); then
    fail "file restore failure should fail the menu operation"
fi
[[ $change_output == *"重启失败且文件恢复失败"* && $change_output == *"$is_config_json"* && $change_output == *"原配置恢复重启已完成"* ]] || fail "file restore failure must name the file and distinguish recovery restart status: $change_output"
cmp -s "$case_dir/meta.before" "$meta_file" || fail "metadata should be restored even when config restoration fails"
[[ $(grep -c '^restart ' "$SERVICE_LOG" 2>/dev/null || true) == 2 ]] || fail "file restore failure should still attempt one recovery restart"
RESTOREFAIL
    [[ $? == 0 ]] || fail "file restore failure test did not complete"
    exit 0
    ;;
multiple-nodes)
    change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1)
    [[ $change_output == *"配置已应用"* ]] || fail "first node proxy setup failed: $change_output"
    cat >"$is_conf_dir/node-two.json" <<'EOF'
{"inbounds":[{"tag":"node-two-main","type":"shadowsocks"},{"tag":"node-two-alt","type":"shadowsocks"}]}
EOF
    jq --arg name "Second" '.outbound_proxy.name = $name | .outbound_mode = "SS 出站"' "$meta_file" >"$is_conf_dir/.quan-meta/node-two.json.meta.json"
    sync_runtime_node_outbound_modes || fail "multiple node synchronization should succeed: $runtime_sync_error"
    cp "$is_config_json" "$case_dir/config.synced"
    jq -e '.outbounds | any(.tag == "managed_node_ss_node-one_json" and .server == "127.0.0.1") and any(.tag == "managed_node_ss_node-two_json" and .server == "127.0.0.1")' "$is_config_json" >/dev/null || fail "same-upstream nodes should receive independent managed outbounds"
    jq -e '[.route.rules[] | select(.outbound == "managed_node_ss_node-two_json") | .inbound] == [["node-two-main","node-two-alt"]]' "$is_config_json" >/dev/null || fail "each node route should use all actual inbound tags"
    jq '.outbound_proxy.config.server = "upstream-two.example.com" | .outbound_proxy.config.password = "second-secret"' "$is_conf_dir/.quan-meta/node-two.json.meta.json" >"$case_dir/node-two-meta.json"
    mv "$case_dir/node-two-meta.json" "$is_conf_dir/.quan-meta/node-two.json.meta.json"
    sync_runtime_node_outbound_modes || fail "different-upstream synchronization should succeed: $runtime_sync_error"
    jq -e '.outbounds | any(.tag == "managed_node_ss_node-one_json" and .server == "127.0.0.1" and .password == "secret") and any(.tag == "managed_node_ss_node-two_json" and .server == "upstream-two.example.com" and .password == "second-secret")' "$is_config_json" >/dev/null || fail "upstream replacement should affect only its own node"
    cp "$is_config_json" "$case_dir/config.synced"
    sync_runtime_node_outbound_modes || fail "repeated synchronization should succeed: $runtime_sync_error"
    cmp -s "$case_dir/config.synced" "$is_config_json" || fail "repeated synchronization should be idempotent"
    exit 0
    ;;
tag-collision)
    proxy_config='{"type":"shadowsocks","server":"127.0.0.1","server_port":8388,"method":"aes-128-gcm","password":"secret"}'
    for cfg in node@one.json node_one.json; do
        printf '{"inbounds":[{"tag":"%s","type":"shadowsocks"}]}\n' "$cfg" >"$is_conf_dir/$cfg"
        jq -cn --argjson config "$proxy_config" '{outbound_mode:"SS 出站",outbound_proxy:{name:"Collision",config:$config}}' >"$is_conf_dir/.quan-meta/$cfg.meta.json"
    done
    cp "$is_config_json" "$case_dir/config.before"
    if sync_runtime_node_outbound_modes; then
        fail "sanitized managed tag collision should fail synchronization"
    fi
    [[ $runtime_sync_error == *"tag 冲突"* ]] || fail "tag collision should be explicit: $runtime_sync_error"
    cmp -s "$case_dir/config.before" "$is_config_json" || fail "tag collision must leave the public config unchanged"
    exit 0
    ;;
direct-switches)
    change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1)
    [[ $change_output == *"配置已应用"* ]] || fail "setup SS application failed: $change_output"
    for entry in '1 V6优先 direct_v6_pref' '2 V4优先 direct_v4_pref' '3 仅V4 direct_v4_only' '4 仅V6 direct_v6_only'; do
        read -r choice mode tag <<<"$entry"
        change_output=$(printf '%s\n' "$choice" | change node-one.json outbound 2>&1)
        [[ $change_output == *"配置已应用"* ]] || fail "direct mode $mode failed: $change_output"
        jq -e --arg mode "$mode" --arg tag "$tag" '.outbound_mode == $mode and .outbound_proxy.config.password == "secret"' "$meta_file" >/dev/null || fail "direct mode $mode should retain the latest proxy cache"
        jq -e --arg inbound "node-one.json" --arg outbound "$tag" '.route.rules[0].action == "resolve" and .route.rules[1].action == "hijack-dns" and .route.rules[2].inbound == [$inbound] and .route.rules[2].outbound == $outbound and .route.rules[3].outbound == "direct"' "$is_config_json" >/dev/null || fail "direct mode $mode should follow DNS rules, precede the broad direct rule, and preserve the original DNS behavior"
    done
    change_output=$(printf '5\n\n' | change node-one.json outbound 2>&1)
    [[ $change_output == *"配置已应用"* ]] || fail "cached SS should be reusable after direct mode switches: $change_output"
    jq -e '.outbound_mode == "SS 出站" and .outbound_proxy.config.password == "secret"' "$meta_file" >/dev/null || fail "reusing the cache should reactivate the same SS configuration"
    jq -e '.outbounds[] | select(.tag == "managed_node_ss_node-one_json") | .password == "secret"' "$is_config_json" >/dev/null || fail "reusing the cache should restore the SS runtime outbound"
    exit 0
    ;;
compatibility-aliases)
    change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound-mode 2>&1)
    [[ $change_output == *"配置已应用"* ]] || fail "outbound-mode compatibility alias should apply SS: $change_output"
    change_output=$(printf '3\n' | change node-one.json mode 2>&1)
    [[ $change_output == *"配置已应用"* ]] || fail "non-Snell mode compatibility alias should select direct mode: $change_output"
    jq -e '.outbound_mode == "仅V4" and .outbound_proxy.config.password == "secret"' "$meta_file" >/dev/null || fail "non-Snell mode alias should preserve the proxy cache"
    change_output=$(printf '5\n\n' | change node-one.json mode 2>&1)
    [[ $change_output == *"配置已应用"* ]] || fail "non-Snell mode alias should reuse cached SS: $change_output"
    exit 0
    ;;
openrc-success|openrc-fail-recovered)
    is_systemd=
    is_openrc=1
    cp "$meta_file" "$case_dir/meta.before"
    cp "$is_config_json" "$case_dir/config.before"
    [[ $TEST_SCENARIO != openrc-fail-recovered ]] || export RESTART_FAIL_AT=1
    if [[ $TEST_SCENARIO == openrc-success ]]; then
        change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1)
        [[ $change_output == *"配置已应用"* ]] || fail "OpenRC success should apply the new config: $change_output"
        [[ $(grep -c '^sing-box restart$' "$SERVICE_LOG") == 1 ]] || fail "OpenRC success should restart once"
        grep -q '^sing-box status$' "$SERVICE_LOG" || fail "OpenRC success should verify service status"
    else
        if change_output=$(printf '5\n%s\n' "$ss_uri" | change node-one.json outbound 2>&1); then
            fail "OpenRC restart failure should fail the menu operation"
        fi
        cmp -s "$case_dir/meta.before" "$meta_file" || fail "OpenRC restart failure must restore metadata"
        cmp -s "$case_dir/config.before" "$is_config_json" || fail "OpenRC restart failure must restore the public config"
        [[ $(grep -c '^sing-box restart$' "$SERVICE_LOG") == 2 ]] || fail "OpenRC restart failure should attempt one recovery restart"
        [[ $change_output == *"已恢复原配置并恢复服务"* ]] || fail "OpenRC recovery should be reported: $change_output"
    fi
    exit 0
    ;;
sync-failure-no-restart)
    jq '.outbound_mode="SS 出站" | .outbound_proxy={name:"broken",config:{type:"vless",server:"bad",server_port:443,uuid:"bad"}}' "$meta_file" >"$case_dir/meta.bad"
    mv "$case_dir/meta.bad" "$meta_file"
    if change_output=$(create config.json 2>&1); then
        fail "config rebuild with a broken active cache should fail"
    fi
    [[ $change_output == *"节点代理路由同步失败"* ]] || fail "config rebuild should surface the synchronization failure: $change_output"
    [[ $(restart_count) == 0 ]] || fail "sync failure must stop the caller before service restart"
    exit 0
    ;;
*)
    fail "unknown test scenario: $TEST_SCENARIO"
    ;;
esac

change_output=$(printf '5\n%s\n' "$ss_uri" | (change node-one.json outbound) 2>&1)
[[ $? == 0 ]] || fail "existing outbound entry should accept SS: $change_output"
[[ $change_output == *"配置已应用"* ]] || fail "successful restart should report applied configuration: $change_output"
[[ $change_output != *"secret"* && $change_output != *"ss://"* ]] || fail "SS credentials must not be echoed"

meta_file="$is_conf_dir/.quan-meta/node-one.json.meta.json"
jq -e '
    .outbound_mode == "SS 出站"
    and .outbound_proxy.name == "Upstream"
    and .outbound_proxy.config.type == "shadowsocks"
    and .outbound_proxy.config.server == "127.0.0.1"
    and .outbound_proxy.config.server_port == 8388
    and (.outbound_proxy.config.server_port | type == "number")
    and .outbound_proxy.config.method == "aes-128-gcm"
    and .outbound_proxy.config.password == "secret"
    and .node_name == "local-node"
    and .entry_addr == "edge.example.com"
    and .custom == "preserve"
    and (has("outbound_ss_server") | not)
' "$meta_file" >/dev/null || fail "SS settings should be saved in the shared proxy cache"

jq -e '
    .outbounds[] | select(.tag == "managed_node_ss_node-one_json")
    | .type == "shadowsocks" and .server == "127.0.0.1"
      and .server_port == 8388 and .password == "secret"
' "$is_config_json" >/dev/null || {
    jq -c '{outbounds:[.outbounds[]? | {tag,type,server,server_port,method}]}' "$is_config_json"
    fail "runtime should contain the selected SS outbound"
}
jq -e '
    .route.rules[0].inbound == ["node-one.json"]
    and .route.rules[0].outbound == "managed_node_ss_node-one_json"
    and .route.rules[1].action == "resolve"
    and .route.rules[2].action == "hijack-dns"
    and .route.rules[3].outbound == "direct"
' "$is_config_json" >/dev/null || fail "proxy route should precede existing broad routes"
[[ $(grep -c '^restart ' "$SERVICE_LOG") == 1 ]] || fail "successful application should restart exactly once"
grep -q -- '-c ' "$FAKE_CORE_LOG" || fail "candidate should be completely checked by sing-box"
grep -q -- '-C ' "$FAKE_CORE_LOG" || fail "complete check should include the node config directory"

CASE
}

run_core_case "$repo_root/core.sh" happy || exit 1
for scenario in parser-ss2022 ss-import-encoding ss-import-invalid parser-ss-encoding vless-menu reject-check restart-fail-recovered restart-fail-unrecovered inactive-service empty-mainpid legacy-migration legacy-migration-check-fail broken-cache-replace broken-cache-reuse missing-config-success missing-config-check-fail missing-config-restart-fail no-files-restart-fail config-install-failure file-restore-failure multiple-nodes tag-collision direct-switches compatibility-aliases openrc-success openrc-fail-recovered sync-failure-no-restart; do
    run_core_case "$repo_root/core.sh" "$scenario" || exit 1
done
for scenario in happy parser-ss2022 ss-import-encoding ss-import-invalid parser-ss-encoding vless-menu reject-check restart-fail-recovered restart-fail-unrecovered inactive-service empty-mainpid legacy-migration legacy-migration-check-fail broken-cache-replace broken-cache-reuse missing-config-success missing-config-check-fail missing-config-restart-fail no-files-restart-fail config-install-failure file-restore-failure multiple-nodes tag-collision direct-switches compatibility-aliases openrc-success openrc-fail-recovered sync-failure-no-restart; do
    run_core_case "$repo_root/src/core.sh" "$scenario" || exit 1
done
echo "PASS: node proxy outbound application"
