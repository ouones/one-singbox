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
if [[ $1 == version ]]; then
    printf 'sing-box version %s\n\nEnvironment: go1.26.7 linux/amd64\nTags: %s\n' \
        "${FAKE_CORE_VERSION:-1.14.0}" "${FAKE_CORE_TAGS:-with_gvisor,with_quic,with_utls}"
    exit 0
fi
if [[ $1 == check ]]; then
    printf '%s\n' "$*" >> /tmp/fake_core_check.log
    config=
    conf_dir=
    while [[ $# -gt 0 ]]; do
        case $1 in
        -c) config=$2; shift 2 ;;
        -C) conf_dir=$2; shift 2 ;;
        *) shift ;;
        esac
    done
    [[ $config && -f $config ]] || { echo "exit 2: config missing: config=$config" >> /tmp/fake_core_check.log; exit 2; }
    [[ ! $conf_dir || -d $conf_dir ]] || { echo "exit 2: conf_dir missing: conf_dir=$conf_dir" >> /tmp/fake_core_check.log; exit 2; }
    cat "$config" > /tmp/debug_failed_config.json 2>/dev/null || :
    jq -e 'type == "object" and ((.outbounds // []) | type == "array") and ((.inbounds // []) | type == "array")' "$config" >/dev/null 2>&1 || {
        echo "exit 4: invalid config shape" >> /tmp/fake_core_check.log
        exit 4
    }
    if jq -e '(.outbounds // []) | any(type == "object" and .tag == "block" and .type == "block")' "$config" >/dev/null 2>&1; then
        echo "exit 1: outbound block found" >> /tmp/fake_core_check.log
        printf 'FATAL[0000] decode config at %s: outbounds: outbound type block is deprecated in sing-box 1.14+\n' "$config" | tee -a /tmp/fake_core_check.log >&2
        exit 1
    fi
    if jq -e '(.route.rule_set // []) | any(type == "object" and .download_detour != null)' "$config" >/dev/null 2>&1; then
        echo "exit 1: download_detour found" >> /tmp/fake_core_check.log
        printf 'FATAL[0000] decode config at %s: route.rule_set: download_detour is deprecated in sing-box 1.14+, use http_clients instead\n' "$config" | tee -a /tmp/fake_core_check.log >&2
        exit 1
    fi
    if [[ $conf_dir ]]; then
        shopt -s nullglob
        for file in "$conf_dir"/*.json; do
            jq -e 'type == "object" and ((.inbounds // []) | type == "array")' "$file" >/dev/null 2>&1 || { echo "exit 5: invalid file $file" >> /tmp/fake_core_check.log; exit 5; }
            if jq -e '(.inbounds // []) | any(type == "object" and (.sniff != null or .sniff_override_destination != null or .sniff_timeout != null))' "$file" >/dev/null 2>&1; then
                printf 'FATAL[0000] decode config at %s: inbounds[0]: legacy inbound fields are deprecated in sing-box 1.11.0 and removed in sing-box 1.13.0\n' "$file" | tee -a /tmp/fake_core_check.log >&2
                exit 1
            fi
        done
    fi
    echo "check passed" >> /tmp/fake_core_check.log
    exit 0
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

cat >"$fake_bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
chmod +x "$fake_bin/sleep"

cat >"$fake_bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
if [[ ${FAKE_CURL_FAIL:-0} == 1 ]]; then
    exit 1
fi
out=
while [[ $# -gt 0 ]]; do
    case $1 in
    -o) out=$2; shift 2 ;;
    *) shift ;;
    esac
done
if [[ $out ]]; then
    if [[ -n $FAKE_CURL_CONTENT ]]; then
        printf '%s\n' "$FAKE_CURL_CONTENT" >"$out"
    elif [[ -f $FAKE_CURL_FILE ]]; then
        cp -f "$FAKE_CURL_FILE" "$out"
    else
        cat >"$out" <<'SAMPLE_JSONC'
{
  // Allow only verified foreign infrastructure records
  "inbound": ["<replace-with-protected-inbound-tag>"],
  "domain": [
    "www.gstatic.com",
    "connectivitycheck.gstatic.com",
    "fonts.gstatic.com",
    "fonts.googleapis.com",
    "c.pki.goog",
    "crl.pki.goog",
    "crls.pki.goog",
    "i.pki.goog",
    "o.pki.goog",
    "ocsp.pki.goog",
    "recaptcha.net",
    "www.recaptcha.net",
    "www.apple.com",
    "mesu.apple.com",
    "swcdn.apple.com",
    "swscan.apple.com",
    "ocsp.apple.com",
    "ocsp2.apple.com",
    "updates-http.cdn-apple.com",
    "updates.cdn-apple.com",
    "configuration.apple.com",
    "valid.apple.com",
    "ctldl.windowsupdate.com",
    "download.microsoft.com",
    "tlu.dl.delivery.mp.microsoft.com"
  ],
  "domain_suffix": [
    "download.windowsupdate.com",
    "dl.delivery.mp.microsoft.com"
  ],
  "action": "route",
  "outbound": "<replace-with-deployment-direct-tag>"
}
SAMPLE_JSONC
    fi
fi
exit 0
FAKE_CURL
chmod +x "$fake_bin/curl"

fail() {
    echo "FAIL: $1"
    exit 1
}

run_test_suite() {
    local core_file=$1
    CORE_FILE="$core_file" FAKE_CORE="$fake_bin/sing-box" PATH="$fake_bin:$PATH" bash <<'CASE'
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

source <(sed '/EUID != 0/d' "$CORE_FILE")
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$FAKE_CORE"
is_core_ver=1.14.0
is_dont_show_info=1
is_no_manage_msg=1
is_systemd=1
export ip=203.0.113.10 is_dont_get_ip=1

mkdir -p "$is_core_dir" "$is_conf_dir/.quan-meta"
export SERVICE_LOG="$case_dir/service.log"
export RESTART_COUNT_FILE="$case_dir/restart-count"
export FAKE_CORE_LOG="$case_dir/core-check.log"
export FAKE_CURL_LOG="$case_dir/curl.log"
: >"$SERVICE_LOG"
: >"$RESTART_COUNT_FILE"
: >"$FAKE_CORE_LOG"
: >"$FAKE_CURL_LOG"

# 防止菜单测试误触发重装卸载流程
get() {
    if [[ $1 == reinstall ]]; then
        msg "mock reinstall"
        return 0
    fi
    builtin command get "$@" 2>/dev/null || :
}

restart_count() {
    grep -c '^restart ' "$SERVICE_LOG" 2>/dev/null || true
}

reset_service_log() {
    : >"$SERVICE_LOG"
    : >"$RESTART_COUNT_FILE"
}

# 1. 基础状态辅助函数与持久化测试
[[ $(type -t block_cn_is_enabled) == function ]] || fail "block_cn_is_enabled function must exist"
[[ $(type -t block_cn_status_text) == function ]] || fail "block_cn_status_text function must exist"

block_cn_is_enabled && fail "initially block-cn must not be enabled"
[[ $(block_cn_status_text) == "未启用" ]] || fail "initial status text should be '未启用'"

# 创建标记文件测试
touch "$is_core_dir/.block-cn-enabled"
block_cn_is_enabled || fail "block_cn_is_enabled should return true when flag file exists"
[[ $(block_cn_status_text) == "已启用" ]] || fail "status text should be '已启用' when flag exists"
rm -f "$is_core_dir/.block-cn-enabled"

# 2. 准备基础运行时配置与节点
cat >"$is_config_json" <<'EOF'
{
  "dns": {},
  "route": {
    "default_domain_resolver": "local",
    "rules": [
      { "action": "resolve", "domain": ["example.com"] },
      { "action": "hijack-dns", "protocol": "dns" },
      { "action": "route", "outbound": "direct" }
    ]
  },
  "outbounds": [
    { "tag": "direct", "type": "direct" },
    { "tag": "custom-preserve", "type": "direct" }
  ]
}
EOF

cat >"$is_conf_dir/node-one.json" <<'EOF'
{
  "inbounds": [
    {
      "tag": "node-one.json",
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": 12345,
      "method": "aes-128-gcm",
      "password": "local-password"
    }
  ]
}
EOF

jq -n '{node_name:"node-one",outbound_mode:"V4优先"}' >"$is_conf_dir/.quan-meta/node-one.json.meta.json"

cat >"$is_conf_dir/node-proxy.json" <<'EOF'
{
  "inbounds": [
    {
      "tag": "node-proxy.json",
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": 23456,
      "method": "aes-128-gcm",
      "password": "proxy-password"
    }
  ]
}
EOF

jq -n '{node_name:"proxy-node",outbound_mode:"SS 出站",outbound_proxy:{name:"Upstream",config:{type:"shadowsocks",server:"127.0.0.1",server_port:8388,method:"aes-128-gcm",password:"secret"}}}' >"$is_conf_dir/.quan-meta/node-proxy.json.meta.json"

# 先同步一次未启用 block-cn 时的配置
sync_runtime_node_outbound_modes || fail "initial sync_runtime_node_outbound_modes failed"
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "block outbound must not exist when disabled"
jq -e '(.route.rule_set // []) | length == 0' "$is_config_json" >/dev/null || fail "rule_set must not exist when disabled"

# 3. CLI status 测试
status_out=$(main block-cn status 2>&1)
[[ $status_out == *"屏蔽回国流量: 未启用"* ]] || fail "CLI block-cn status output wrong: $status_out"

# 4. CLI enable / on 测试
reset_service_log
enable_out=$(main block-cn enable 2>&1)
[[ $enable_out == *"屏蔽回国流量: 已启用"* ]] || fail "CLI block-cn enable output wrong: $enable_out"
[[ -f "$is_core_dir/.block-cn-enabled" ]] || fail "flag file .block-cn-enabled must exist after enable"
[[ -f "$is_core_dir/.cn-whitelist.json" ]] || fail "whitelist file .cn-whitelist.json must exist after enable"
[[ $(restart_count) -ge 1 ]] || fail "enable must restart service"

# 5. 校验启用后的运行时配置注入
# A. 现代受管分流与出站断言
jq -e '.http_clients | any(.tag == "direct-client" and .detour == "direct")' "$is_config_json" >/dev/null || fail "managed http_clients direct-client must be injected"
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "type: block outbound must NOT exist in modern config"
jq -e '.outbounds | any(.tag == "custom-preserve")' "$is_config_json" >/dev/null || fail "custom outbounds must be preserved"

# B. rule_set 注入（使用 http_client 替代已弃用的 download_detour）
jq -e '.route.rule_set | any(.tag == "geosite-cn" and .type == "remote" and .format == "binary" and .http_client == "direct-client" and .download_detour == null and .url == "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs")' "$is_config_json" >/dev/null || fail "geosite-cn remote rule_set missing or invalid"
jq -e '.route.rule_set | any(.tag == "geoip-cn" and .type == "remote" and .format == "binary" and .http_client == "direct-client" and .download_detour == null and .url == "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs")' "$is_config_json" >/dev/null || fail "geoip-cn remote rule_set missing or invalid"

# C. route.rules 注入与顺序
# 预期顺序：
# 0: sniff (route action)
# 1: resolve
# 2: hijack-dns
# 3: cn-whitelist bypass (domain/domain_suffix -> direct)
# 4: private ip reject (ip_is_private: true -> action: reject)
# 5: cn rule_set reject (rule_set: ["geosite-cn", "geoip-cn"] -> action: reject)
# 6: proxy_rules (node-proxy.json -> managed_node_ss_node-proxy_json)
# 7: direct_rules (node-one.json -> direct_v4_pref)
# 8: broad direct fallback (outbound: direct)
rules_count=$(jq '.route.rules | length' "$is_config_json")
[[ $rules_count -ge 9 ]] || fail "rules count should be at least 9, got $rules_count: $(jq -c '.route.rules' "$is_config_json")"

jq -e '.route.rules[0].action == "sniff"' "$is_config_json" >/dev/null || fail "rule 0 should be route action sniff"
jq -e '.route.rules[1].action == "resolve"' "$is_config_json" >/dev/null || fail "rule 1 should be custom resolve"
jq -e '.route.rules[2].action == "hijack-dns"' "$is_config_json" >/dev/null || fail "rule 2 should be custom hijack-dns"
jq -e '.route.rules[3].action == "route" and .route.rules[3].outbound == "direct" and (.route.rules[3].domain | length > 0) and (.route.rules[3].domain_suffix | length > 0)' "$is_config_json" >/dev/null || fail "rule 3 should be cn-whitelist bypass"
jq -e '.route.rules[3].inbound == null' "$is_config_json" >/dev/null || fail "whitelist rule must not contain inbound restriction"
jq -e '.route.rules[4].ip_is_private == true and .route.rules[4].action == "reject" and .route.rules[4].outbound == null' "$is_config_json" >/dev/null || fail "rule 4 should be private IP reject action"
jq -e '.route.rules[5].rule_set == ["geosite-cn", "geoip-cn"] and .route.rules[5].action == "reject" and .route.rules[5].outbound == null' "$is_config_json" >/dev/null || fail "rule 5 should be CN rule_set reject action"
jq -e '.route.rules[6].inbound == ["node-proxy.json"] and .route.rules[6].outbound == "managed_node_ss_node-proxy_json"' "$is_config_json" >/dev/null || fail "rule 6 should be node proxy rule"
jq -e '.route.rules[7].inbound == ["node-one.json"] and .route.rules[7].outbound == "direct_v4_pref"' "$is_config_json" >/dev/null || fail "rule 7 should be node direct rule"
jq -e '.route.rules[8].outbound == "direct"' "$is_config_json" >/dev/null || fail "rule 8 should be fallback direct rule"

# D. 幂等性与防重复堆叠测试
sync_runtime_node_outbound_modes || fail "re-syncing failed"
[[ $(jq '.route.rules | length' "$is_config_json") == "$rules_count" ]] || fail "re-syncing must not duplicate rules"
[[ $(jq '[.http_clients[]? | select(.tag == "direct-client")] | length' "$is_config_json") == 1 ]] || fail "direct-client http_client must not duplicate"
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "block outbound must NOT exist"
[[ $(jq '[.route.rule_set[] | select(.tag == "geosite-cn")] | length' "$is_config_json") == 1 ]] || fail "geosite-cn must not duplicate"
[[ $(jq '[.route.rules[] | select(.action == "route" and .outbound == "direct" and (.domain // [] | length > 0))] | length' "$is_config_json") == 1 ]] || fail "whitelist rule must not duplicate"

# 6. 入站嗅探 (sniff) 检查
# 在 sing-box 1.13+ 中，嗅探通过路由规则 {"action":"sniff"} 实现，入站配置不应包含 legacy 嗅探字段
jq -e '.route.rules | any(.action == "sniff")' "$is_config_json" >/dev/null || fail "route action sniff must be enabled"
jq -e '(.inbounds[0].sniff == null) and (.inbounds[0].sniff_override_destination == null)' "$is_conf_dir/node-one.json" >/dev/null || fail "node-one.json must NOT contain legacy inbound sniff fields"
jq -e '(.inbounds[0].sniff == null) and (.inbounds[0].sniff_override_destination == null)' "$is_conf_dir/node-proxy.json" >/dev/null || fail "node-proxy.json must NOT contain legacy inbound sniff fields"

# 存量遗留字段自动清洗迁移测试
jq '.inbounds[0].sniff = true | .inbounds[0].sniff_override_destination = true' "$is_conf_dir/node-one.json" >"$is_conf_dir/node-one.json.tmp" && mv -f "$is_conf_dir/node-one.json.tmp" "$is_conf_dir/node-one.json"
block_cn_clean_all_legacy_inbounds "$is_conf_dir" || fail "block_cn_clean_all_legacy_inbounds failed"
jq -e '(.inbounds[0].sniff == null) and (.inbounds[0].sniff_override_destination == null)' "$is_conf_dir/node-one.json" >/dev/null || fail "legacy inbound fields must be cleaned up by migration"

# 7. CLI disable / off 测试
reset_service_log
disable_out=$(main block-cn disable 2>&1)
[[ $disable_out == *"屏蔽回国流量: 未启用"* ]] || fail "CLI block-cn disable output wrong: $disable_out"
[[ ! -f "$is_core_dir/.block-cn-enabled" ]] || fail "flag file .block-cn-enabled must be removed after disable"
[[ $(restart_count) -ge 1 ]] || fail "disable must restart service"

# 校验禁用后的运行时配置恢复
jq -e '(.http_clients // []) | any(.tag == "direct-client") | not' "$is_config_json" >/dev/null || fail "direct-client must be removed after disable"
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "block outbound must be removed after disable"
jq -e '(.route.rule_set // []) | any(.tag == "geosite-cn" or .tag == "geoip-cn") | not' "$is_config_json" >/dev/null || fail "CN rule_sets must be removed after disable"
jq -e '.route.rules | any(.outbound == "block") | not' "$is_config_json" >/dev/null || fail "block rules must be removed after disable"
jq -e '.route.rules | any(.action == "reject" and (.ip_is_private == true or .rule_set == ["geosite-cn", "geoip-cn"])) | not' "$is_config_json" >/dev/null || fail "managed reject rules must be removed after disable"
jq -e '.route.rules | any(.action == "route" and .outbound == "direct" and (.domain // [] | length > 0)) | not' "$is_config_json" >/dev/null || fail "whitelist rule must be removed after disable"
[[ -f "$is_core_dir/.cn-whitelist.json" ]] || fail "whitelist cache file should be preserved on disk after disable"
jq -e '.outbounds | any(.tag == "custom-preserve")' "$is_config_json" >/dev/null || fail "custom outbounds must be preserved after disable"

# 禁用屏蔽回国后，受管节点常态化路由嗅探依然保留，入站配置依然保持干净
jq -e '(.route.rules // []) | any(.action == "sniff" and (.inbound // [] | length > 0))' "$is_config_json" >/dev/null || fail "sniff rule should remain active and scoped after disable"
jq -e '(.inbounds[0].sniff == null) and (.inbounds[0].sniff_override_destination == null)' "$is_conf_dir/node-one.json" >/dev/null || fail "node-one.json must remain clean without legacy fields"
jq -e '(.inbounds[0].sniff == null) and (.inbounds[0].sniff_override_destination == null)' "$is_conf_dir/node-proxy.json" >/dev/null || fail "node-proxy.json must remain clean without legacy fields"

# 8. CLI toggle 测试
reset_service_log
toggle_out1=$(main block-cn toggle 2>&1)
[[ $toggle_out1 == *"屏蔽回国流量: 已启用"* ]] || fail "toggle from disabled should enable: $toggle_out1"
[[ -f "$is_core_dir/.block-cn-enabled" ]] || fail "flag file should exist after toggle to enable"

reset_service_log
toggle_out2=$(main block-cn 2>&1)
[[ $toggle_out2 == *"屏蔽回国流量: 未启用"* ]] || fail "toggle without args from enabled should disable: $toggle_out2"
[[ ! -f "$is_core_dir/.block-cn-enabled" ]] || fail "flag file should not exist after toggle to disable"

# 9. 新增节点入站自动开启嗅探测试
main block-cn on 2>&1 >/dev/null
[[ -f "$is_core_dir/.block-cn-enabled" ]] || fail "flag file must exist"
cat >"$is_conf_dir/node-new.json" <<'EOF'
{
  "inbounds": [
    {
      "tag": "node-new.json",
      "type": "vless",
      "listen": "::",
      "listen_port": 34567
    }
  ]
}
EOF
# 验证 block_cn_clean_legacy_inbounds 作用于新节点（确保入站无 legacy sniff 字段）
block_cn_clean_legacy_inbounds "$is_conf_dir/node-new.json"
jq -e '(.inbounds[0].sniff == null) and (.inbounds[0].sniff_override_destination == null)' "$is_conf_dir/node-new.json" >/dev/null || fail "new node must NOT have legacy sniff fields"

# 10. 保留自定义 rule_set 测试（用户自定义 remote/local 规则集不被受管逻辑破坏）
jq '.route.rule_set += [{"tag":"custom-ads","type":"remote","format":"binary","url":"https://example.com/ads.srs"}]' "$is_config_json" >"$is_config_json.tmp" && mv -f "$is_config_json.tmp" "$is_config_json"
sync_runtime_node_outbound_modes || fail "sync with custom rule_set failed"
jq -e '.route.rule_set | any(.tag == "custom-ads")' "$is_config_json" >/dev/null || fail "custom rule_set must be preserved while block-cn enabled"
jq -e '.route.rule_set | any(.tag == "geosite-cn")' "$is_config_json" >/dev/null || fail "geosite-cn must still exist alongside custom rule_set"

# 禁用后自定义 rule_set 依然保留
main block-cn off 2>&1 >/dev/null
[[ ! -f "$is_core_dir/.block-cn-enabled" ]] || fail "flag file should not exist after off"
jq -e '.route.rule_set | any(.tag == "custom-ads")' "$is_config_json" >/dev/null || fail "custom rule_set must be preserved after block-cn disabled"
jq -e '(.route.rule_set // []) | any(.tag == "geosite-cn") | not' "$is_config_json" >/dev/null || fail "geosite-cn must be removed"

# 11. 在启用状态下执行 create config.json 重建配置
main block-cn on 2>&1 >/dev/null
create config.json >/dev/null 2>&1
jq -e '.http_clients | any(.tag == "direct-client" and .detour == "direct")' "$is_config_json" >/dev/null || fail "create config.json should retain direct-client http_client when enabled"
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "create config.json should NOT retain type: block outbound"
jq -e '.route.rule_set | any(.tag == "geosite-cn" and .http_client == "direct-client" and .download_detour == null)' "$is_config_json" >/dev/null || fail "create config.json should retain geosite-cn when enabled"
jq -e '.route.rules | any(.ip_is_private == true and .action == "reject" and .outbound == null)' "$is_config_json" >/dev/null || fail "create config.json should retain private IP reject rule when enabled"
jq -e '.route.rules[0].action == "sniff"' "$is_config_json" >/dev/null || fail "create config.json should retain route action sniff when enabled"
jq -e '.route.rules[1].action == "route" and .route.rules[1].outbound == "direct" and (.route.rules[1].domain | length > 0)' "$is_config_json" >/dev/null || fail "create config.json should retain whitelist bypass when enabled"

# 12. 白名单独立解析、注释剥离与规范化持久化测试
[[ $(type -t block_cn_sync_whitelist) == function ]] || fail "block_cn_sync_whitelist function must exist"
rm -f "$is_core_dir/.cn-whitelist.json"
block_cn_sync_whitelist || fail "block_cn_sync_whitelist failed"
[[ -f "$is_core_dir/.cn-whitelist.json" ]] || fail ".cn-whitelist.json must be created by block_cn_sync_whitelist"
jq -e '.action == "route"' "$is_core_dir/.cn-whitelist.json" >/dev/null || fail "whitelist action must be route"
jq -e '.outbound == "direct"' "$is_core_dir/.cn-whitelist.json" >/dev/null || fail "whitelist outbound must be direct"
jq -e '.inbound == null' "$is_core_dir/.cn-whitelist.json" >/dev/null || fail "whitelist inbound must be stripped"
jq -e '.domain | any(. == "connectivitycheck.gstatic.com")' "$is_core_dir/.cn-whitelist.json" >/dev/null || fail "whitelist domain connectivitycheck.gstatic.com must be present"
jq -e '.domain_suffix | any(. == "download.windowsupdate.com")' "$is_core_dir/.cn-whitelist.json" >/dev/null || fail "whitelist domain_suffix download.windowsupdate.com must be present"

# 13. 网络失败与本地缓存降级测试
# 预置一个带有特殊 marker 域名的本地缓存
cat >"$is_core_dir/.cn-whitelist.json" <<'EOF'
{
  "action": "route",
  "outbound": "direct",
  "domain": ["cached-marker.infra.example"],
  "domain_suffix": ["cached-suffix.infra.example"]
}
EOF
export FAKE_CURL_FAIL=1
warn_out=$(block_cn_sync_whitelist 2>&1)
[[ $warn_out == *"降级采用本地缓存白名单"* ]] || fail "should warn about falling back to local cache when network fails: $warn_out"
[[ -f "$is_core_dir/.cn-whitelist.json" ]] || fail "cached file must still exist after download failure"
# 同步配置后验证生效的是本地缓存的 marker 域名
sync_runtime_node_outbound_modes || fail "syncing with cached whitelist should succeed"
jq -e '.route.rules | any(.domain // [] | any(. == "cached-marker.infra.example"))' "$is_config_json" >/dev/null || fail "cached whitelist marker domain must be injected"
jq -e '
  ([.route.rules[] | .domain // [] | any(. == "cached-marker.infra.example")] | index(true))
  < ([.route.rules[] | .ip_is_private == true] | index(true))
' "$is_config_json" >/dev/null || fail "cached whitelist rule must precede private IP block"

# 14. 网络失败且无本地缓存时的容错断言
rm -f "$is_core_dir/.cn-whitelist.json"
create config.json >/dev/null 2>&1
export FAKE_CURL_FAIL=1
warn_out2=$(block_cn_sync_whitelist 2>&1)
[[ $warn_out2 == *"下载回国白名单失败且无本地缓存"* ]] || fail "should warn about no cache available: $warn_out2"
# 确保虽然无白名单缓存，但配置同步不崩溃且阻断引擎正常运行
sync_runtime_node_outbound_modes || fail "sync without whitelist cache must not fail"
jq -e '.route.rules | any(.ip_is_private == true and .action == "reject")' "$is_config_json" >/dev/null || fail "private ip reject must still exist"
jq -e '.route.rules | any(.rule_set == ["geosite-cn", "geoip-cn"] and .action == "reject")' "$is_config_json" >/dev/null || fail "cn rule_set reject must still exist"
jq -e '.route.rules | any(.outbound == "block") | not' "$is_config_json" >/dev/null || fail "no outbound block rule should exist"
jq -e '.route.rules | any(.action == "route" and .outbound == "direct" and (.domain // [] | length > 0)) | not' "$is_config_json" >/dev/null || fail "no whitelist rule should be injected when cache is missing"
export FAKE_CURL_FAIL=0

# 15. 用户自定义直连规则在 block-cn 切换中的隔离与保护
# 添加一条用户自定义直连规则到 route.rules 首部
jq '.route.rules = [{action:"route",domain:["user-custom.direct.lan"],outbound:"direct"}] + .route.rules' "$is_config_json" >"$is_config_json.tmp" && mv -f "$is_config_json.tmp" "$is_config_json"
# 重新拉取标准白名单并同步
block_cn_sync_whitelist || fail "re-syncing whitelist failed"
sync_runtime_node_outbound_modes || fail "sync with user custom direct rule failed"
# 验证用户自定义直连规则位于嗅探之后、白名单之前 (First-Match)
jq -e '.route.rules[0].action == "sniff"' "$is_config_json" >/dev/null || fail "rule 0 should be action: sniff"
jq -e '.route.rules[1].domain == ["user-custom.direct.lan"] and .route.rules[1].outbound == "direct"' "$is_config_json" >/dev/null || fail "user custom direct rule must remain first route rule"
# 验证白名单规则紧随用户自定义规则之后且位于阻断规则之前
jq -e '
  ([.route.rules[] | .domain // [] | any(. == "user-custom.direct.lan")] | index(true))
  < ([.route.rules[] | .domain // [] | any(. == "connectivitycheck.gstatic.com")] | index(true))
  and
  ([.route.rules[] | .domain // [] | any(. == "connectivitycheck.gstatic.com")] | index(true))
  < ([.route.rules[] | .ip_is_private == true] | index(true))
' "$is_config_json" >/dev/null || fail "rule order must be: user custom -> whitelist -> private block"
# 禁用 block-cn 后，用户自定义直连规则不被误删
main block-cn off 2>&1 >/dev/null
jq -e '.route.rules | any(.domain == ["user-custom.direct.lan"] and .outbound == "direct")' "$is_config_json" >/dev/null || fail "user custom direct rule must be preserved after block-cn disabled"
jq -e '.route.rules | any(.domain // [] | any(. == "connectivitycheck.gstatic.com")) | not' "$is_config_json" >/dev/null || fail "whitelist rule must be removed after disable"

# 16. system_tools_menu 交互仿真测试 (Issue #73)
# 确保初始为未启用状态
main block-cn off 2>&1 >/dev/null
[[ ! -f "$is_core_dir/.block-cn-enabled" ]] || fail "ensure block-cn disabled initially"

# 仿真执行: 选中 4 (切换为启用) -> 回车确认 -> 选中 4 (切换为未启用) -> 回车确认 -> 选中 6 (返回)
menu_in=$'4\n\n4\n\n6\n'
menu_out=$(printf '%s' "$menu_in" | system_tools_menu 2>&1)

# 断言 1: 初始菜单展示包含 "屏蔽回国流量 (未启用)"
[[ $menu_out == *"屏蔽回国流量 (未启用)"* ]] || fail "menu should show '屏蔽回国流量 (未启用)': $menu_out"

# 断言 2: 首次选中后显示反馈信息 "已启用屏蔽回国流量"
[[ $menu_out == *"已启用屏蔽回国流量"* ]] || fail "menu output should contain '已启用屏蔽回国流量': $menu_out"

# 断言 3: 再次展示菜单时动态展示 "屏蔽回国流量 (已启用)"
[[ $menu_out == *"屏蔽回国流量 (已启用)"* ]] || fail "menu should dynamically show '屏蔽回国流量 (已启用)': $menu_out"

# 断言 4: 第二次选中后显示反馈信息 "已禁用屏蔽回国流量"
[[ $menu_out == *"已禁用屏蔽回国流量"* ]] || fail "menu output should contain '已禁用屏蔽回国流量': $menu_out"

# 断言 5: 返回后状态依然为未启用，标志文件不存在
block_cn_is_enabled && fail "block-cn should be disabled after toggling back"

# 仿真仅切换为启用并退出菜单
reset_service_log
printf '4\n\n6\n' | system_tools_menu 2>&1 >/dev/null
block_cn_is_enabled || fail "block-cn should be enabled after menu toggle"
[[ -f "$is_core_dir/.block-cn-enabled" ]] || fail "flag file should exist after menu toggle to enable"
[[ -f "$is_core_dir/.cn-whitelist.json" ]] || fail "whitelist file should exist after menu toggle to enable"
[[ $(restart_count) -ge 1 ]] || fail "menu toggle to enable must restart service"
jq -e '.http_clients | any(.tag == "direct-client")' "$is_config_json" >/dev/null || fail "direct-client must exist after menu enable"
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "block outbound must NOT exist after menu enable"
jq -e '.route.rule_set | any(.tag == "geosite-cn")' "$is_config_json" >/dev/null || fail "geosite-cn must exist after menu enable"

# 再次从已启用状态切换为未启用并退出菜单
reset_service_log
printf '4\n\n6\n' | system_tools_menu 2>&1 >/dev/null
block_cn_is_enabled && fail "block-cn should be disabled after second menu toggle"
[[ ! -f "$is_core_dir/.block-cn-enabled" ]] || fail "flag file must be removed after menu toggle to disable"
[[ $(restart_count) -ge 1 ]] || fail "menu toggle to disable must restart service"
jq -e '(.http_clients // []) | any(.tag == "direct-client") | not' "$is_config_json" >/dev/null || fail "direct-client must be removed after menu disable"
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "block outbound must be removed after menu disable"

# 17. 节点全生命周期联动与无损保留测试 (Issue #73)
# 开启 block-cn
main block-cn on 2>&1 >/dev/null
block_cn_is_enabled || fail "block-cn must be enabled for lifecycle test"

# 17.1 新增节点生命周期联动：测试入站 sniff 注入与运行时配置中 block-cn 规则保留
cat >"$is_conf_dir/node-lifecycle.json" <<'EOF'
{
  "inbounds": [
    {
      "tag": "node-lifecycle.json",
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": 45678,
      "method": "aes-128-gcm",
      "password": "pass-lifecycle"
    }
  ]
}
EOF
# 为新节点注入元数据
jq -n '{node_name:"lifecycle-node",outbound_mode:"V6优先"}' >"$is_conf_dir/.quan-meta/node-lifecycle.json.meta.json"
# 确保入站嗅探配置（1.13+ 入站不包含旧版 sniff 字段）
block_cn_clean_legacy_inbounds "$is_conf_dir/node-lifecycle.json"
jq -e '(.inbounds[0].sniff == null) and (.inbounds[0].sniff_override_destination == null)' "$is_conf_dir/node-lifecycle.json" >/dev/null || fail "lifecycle node inbound must not have legacy sniff fields"

# 触发同步
sync_runtime_node_outbound_modes || fail "sync_runtime_node_outbound_modes failed after adding node"
# 断言：运行时配置中保留了 block-cn http_clients、规则集与白名单规则，无 block 出站，且新增节点的直连路由正确生成
jq -e '.http_clients | any(.tag == "direct-client")' "$is_config_json" >/dev/null || fail "direct-client http_client lost after adding node"
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "type: block outbound must not exist after adding node"
jq -e '.route.rule_set | any(.tag == "geosite-cn")' "$is_config_json" >/dev/null || fail "geosite-cn lost after adding node"
jq -e '.route.rule_set | any(.tag == "geoip-cn")' "$is_config_json" >/dev/null || fail "geoip-cn lost after adding node"
jq -e '.route.rules | any(.ip_is_private == true and .action == "reject")' "$is_config_json" >/dev/null || fail "private ip reject rule lost after adding node"
jq -e '.route.rules | any(.rule_set == ["geosite-cn", "geoip-cn"] and .action == "reject")' "$is_config_json" >/dev/null || fail "cn rule_set reject rule lost after adding node"
jq -e '.route.rules | any(.domain // [] | any(. == "connectivitycheck.gstatic.com"))' "$is_config_json" >/dev/null || fail "whitelist rule lost after adding node"
jq -e '.route.rules | any(.inbound == ["node-lifecycle.json"] and .outbound == "direct_v6_pref")' "$is_config_json" >/dev/null || fail "new node route not found"

# 17.2 更改节点出站方式生命周期联动 (apply_node_outbound_mode_unlocked)
apply_node_outbound_mode_unlocked "node-lifecycle.json" "仅V4" || fail "apply_node_outbound_mode_unlocked failed"
# 断言：出站方式已变更为 direct_v4_only，但 http_clients、规则集与 reject 规则依然完整无损
jq -e '.route.rules | any(.inbound == ["node-lifecycle.json"] and .outbound == "direct_v4_only")' "$is_config_json" >/dev/null || fail "node route not updated to direct_v4_only"
jq -e '.http_clients | any(.tag == "direct-client")' "$is_config_json" >/dev/null || fail "direct-client lost after modifying outbound mode"
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "block outbound appeared after modifying outbound mode"
jq -e '.route.rule_set | any(.tag == "geosite-cn")' "$is_config_json" >/dev/null || fail "geosite-cn lost after modifying outbound mode"
jq -e '.route.rules | any(.ip_is_private == true and .action == "reject")' "$is_config_json" >/dev/null || fail "private reject lost after modifying outbound mode"
jq -e '.route.rules | any(.domain // [] | any(. == "connectivitycheck.gstatic.com"))' "$is_config_json" >/dev/null || fail "whitelist lost after modifying outbound mode"

# 17.3 节点替换/重命名生命周期联动 (apply_node_config_lifecycle replace)
node_lifecycle_renamed_json=$(jq '.inbounds[0].tag = "node-lifecycle-renamed.json" | .inbounds[0].listen_port = 56789' "$is_conf_dir/node-lifecycle.json")
apply_node_config_lifecycle replace "node-lifecycle.json" "node-lifecycle-renamed.json" "$node_lifecycle_renamed_json" || fail "apply_node_config_lifecycle replace failed"
# 断言：重命名后新配置文件入站不含 legacy 字段
jq -e '(.inbounds[0].sniff == null) and (.inbounds[0].sniff_override_destination == null)' "$is_conf_dir/node-lifecycle-renamed.json" >/dev/null || fail "renamed node must not have legacy sniffing fields"
# 断言：运行时配置中 block-cn 规则无损
jq -e '.http_clients | any(.tag == "direct-client")' "$is_config_json" >/dev/null || fail "direct-client lost after renaming node"
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "block outbound appeared after renaming node"
jq -e '.route.rule_set | any(.tag == "geosite-cn")' "$is_config_json" >/dev/null || fail "geosite-cn lost after renaming node"
jq -e '.route.rules | any(.domain // [] | any(. == "connectivitycheck.gstatic.com"))' "$is_config_json" >/dev/null || fail "whitelist lost after renaming node"
jq -e '.route.rules | any(.inbound == ["node-lifecycle-renamed.json"])' "$is_config_json" >/dev/null || fail "renamed node route not found"

# 17.4 节点删除生命周期联动 (apply_node_config_lifecycle delete)
apply_node_config_lifecycle delete "node-lifecycle-renamed.json" || fail "apply_node_config_lifecycle delete failed"
[[ ! -f "$is_conf_dir/node-lifecycle-renamed.json" ]] || fail "deleted node file should not exist"
# 断言：删除节点后 block-cn 规则依然完整无损
jq -e '.http_clients | any(.tag == "direct-client")' "$is_config_json" >/dev/null || fail "direct-client lost after deleting node"
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "block outbound appeared after deleting node"
jq -e '.route.rule_set | any(.tag == "geosite-cn")' "$is_config_json" >/dev/null || fail "geosite-cn lost after deleting node"
jq -e '.route.rules | any(.domain // [] | any(. == "connectivitycheck.gstatic.com"))' "$is_config_json" >/dev/null || fail "whitelist lost after deleting node"
jq -e '.route.rules | any(.inbound == ["node-lifecycle-renamed.json"]) | not' "$is_config_json" >/dev/null || fail "deleted node route must be removed"

# 18.1 用户自定义 reject 规则在多次同步与状态切换中保持隔离不被误删，且受管逻辑不注入 block 出站
# 注入一条用户自定义 reject 规则（例如广告拦截）
jq '.route.rules = [{domain_suffix:["ad-analytics.custom.lan"],action:"reject"}] + .route.rules' "$is_config_json" >"$is_config_json.tmp" && mv -f "$is_config_json.tmp" "$is_config_json"

# 在 block-cn 启用状态下同步
sync_runtime_node_outbound_modes || fail "sync failed with custom reject rule while block-cn enabled"
jq -e '.route.rules | any(.domain_suffix == ["ad-analytics.custom.lan"] and .action == "reject")' "$is_config_json" >/dev/null || fail "custom reject rule must be preserved when enabled"
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "block outbound must NOT exist when block-cn enabled"

# 切换为关闭状态
main block-cn off 2>&1 >/dev/null
jq -e '.route.rules | any(.domain_suffix == ["ad-analytics.custom.lan"] and .action == "reject")' "$is_config_json" >/dev/null || fail "custom reject rule must be preserved when disabled"
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "block outbound must NOT exist when disabled"

# 重新启用并再次验证
main block-cn on 2>&1 >/dev/null
jq -e '.route.rules | any(.domain_suffix == ["ad-analytics.custom.lan"] and .action == "reject")' "$is_config_json" >/dev/null || fail "custom reject rule must survive re-enabling"

# 18.2 中转节点入站嗅探配置与清理断言
# 场景 A: 在 block-cn 启用状态下新增中转节点，入站不应包含 legacy sniff 配置
main relay add 10088 198.51.100.1 20088 >/dev/null 2>&1 || fail "relay add 10088 failed"
jq -e '
  .inbounds[0].tag == "relay-10088.json"
  and .inbounds[0].sniff == null
  and .inbounds[0].sniff_override_destination == null
' "$is_conf_dir/relay-10088.json" >/dev/null || fail "new relay node inbound must not have legacy sniffing fields"

# 场景 B: 模拟之前存在包含旧版嗅探字段的中转节点，启用时应被 block_cn_clean_all_legacy_inbounds 自动清理迁移
jq -n '{inbounds:[{tag:"relay-10089.json",type:"direct",listen:"::",listen_port:10089,override_address:"198.51.100.2",override_port:20089,sniff:true,sniff_override_destination:true}]}' >"$is_conf_dir/relay-10089.json"
block_cn_clean_all_legacy_inbounds "$is_conf_dir" || fail "block_cn_clean_all_legacy_inbounds failed"
jq -e '
  .inbounds[0].tag == "relay-10089.json"
  and .inbounds[0].sniff == null
  and .inbounds[0].sniff_override_destination == null
' "$is_conf_dir/relay-10089.json" >/dev/null || fail "existing relay node legacy sniffing must be cleaned"
rm -f "$is_conf_dir/relay-10088.json" "$is_conf_dir/relay-10089.json"

# 18.3 默认 final 兜底路由断言
sync_runtime_node_outbound_modes || fail "sync failed for default final assertion"
jq -e '.route.final == "direct"' "$is_config_json" >/dev/null || fail "route.final must default to direct"

# 如果用户已有自定义 final，应保留用户配置
jq '.route.final = "custom-final"' "$is_config_json" >"$is_config_json.tmp" && mv -f "$is_config_json.tmp" "$is_config_json"
sync_runtime_node_outbound_modes || fail "sync failed with custom route.final"
jq -e '.route.final == "custom-final"' "$is_config_json" >/dev/null || fail "custom route.final must be preserved"
# 恢复为默认
jq 'del(.route.final)' "$is_config_json" >"$is_config_json.tmp" && mv -f "$is_config_json.tmp" "$is_config_json"
sync_runtime_node_outbound_modes || fail "sync failed after resetting route.final"
jq -e '.route.final == "direct"' "$is_config_json" >/dev/null || fail "route.final must fall back to direct"

# 18.4 生产代码无 mock 测试域名泄漏断言
if grep -E '(cached-marker|cached-suffix)' "$CORE_FILE" >/dev/null 2>&1; then
  fail "production file $CORE_FILE must not leak mock test domains"
fi

# 19. Spec 审查回归测试 (Issue #75)
# 19.1 update core 校验失败必须阻断重启 (Seam 1)
load() {
    if [[ $1 == download.sh ]]; then
        download() { :; }
        return 0
    fi
    . "$is_sh_dir/src/$1"
}
download() { :; }
cat >"$is_conf_dir/invalid-broken.json" <<'EOF'
{ "inbounds": "invalid_array_expected" }
EOF
reset_service_log
restart_before=$(restart_count)
update_fail_out=$(update core 1.15.0 2>&1 || true)
restart_after=$(restart_count)
rm -f "$is_conf_dir/invalid-broken.json"
[[ $restart_after -eq $restart_before ]] || fail "update core must NOT restart service when config validation fails: $update_fail_out"

# 19.2 全局自愈式一次性迁移 (Seam 2)
cat >"$is_conf_dir/unmigrated-node.json" <<'EOF'
{
  "inbounds": [
    {
      "tag": "unmigrated-node.json",
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": 39999,
      "method": "aes-128-gcm",
      "password": "pass",
      "sniff": true,
      "sniff_override_destination": true
    }
  ]
}
EOF
is_sh_ver=1.52
(update sh 1.53 >/dev/null 2>&1) || true
jq -e '(.inbounds[0].sniff == null) and (.inbounds[0].sniff_override_destination == null)' "$is_conf_dir/unmigrated-node.json" >/dev/null || fail "update sh must auto-migrate legacy inbound sniff fields"
rm -f "$is_conf_dir/unmigrated-node.json"

# 20. Standards 审查回归测试：验证废弃旧别名退役
for fn in block_cn_inject_inbounds_sniffing_json block_cn_ensure_inbounds_sniffing block_cn_ensure_all_nodes_sniffing; do
  if declare -F "$fn" >/dev/null 2>&1; then
    fail "deprecated legacy alias $fn must be retired"
  fi
done

# 21. sing-box 1.14+ 现代内核语法专项测试 (Ticket #77)
# 21.1 用户自定义 http_clients 隔离与保留测试
main block-cn on 2>&1 >/dev/null
jq '.http_clients += [{"tag":"custom-http-client","detour":"direct"}]' "$is_config_json" >"$is_config_json.tmp" && mv -f "$is_config_json.tmp" "$is_config_json"
sync_runtime_node_outbound_modes || fail "sync with custom http_client failed"
jq -e '.http_clients | any(.tag == "custom-http-client" and .detour == "direct")' "$is_config_json" >/dev/null || fail "custom http_client must be preserved when enabled"
jq -e '.http_clients | any(.tag == "direct-client" and .detour == "direct")' "$is_config_json" >/dev/null || fail "managed direct-client must be present alongside custom http_client"

# 禁用后自定义 http_clients 依然保留，仅受管 direct-client 被清除
main block-cn off 2>&1 >/dev/null
jq -e '.http_clients | any(.tag == "custom-http-client" and .detour == "direct")' "$is_config_json" >/dev/null || fail "custom http_client must be preserved after block-cn disabled"
jq -e '(.http_clients // []) | any(.tag == "direct-client") | not' "$is_config_json" >/dev/null || fail "managed direct-client must be removed after disable"

# 21.2 历史老配置升级自愈：清理废弃的 type: "block" 出站和旧版 block 路由规则
main block-cn on 2>&1 >/dev/null
# 模拟配置中残留了历史旧版的受管 block 出站与旧规则
jq '.outbounds += [{"tag":"block","type":"block"}] | .route.rules += [{"rule_set":["geosite-cn","geoip-cn"],"outbound":"block"}]' "$is_config_json" >"$is_config_json.tmp" && mv -f "$is_config_json.tmp" "$is_config_json"
sync_runtime_node_outbound_modes || fail "sync failed on legacy config cleanup"
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "legacy block outbound must be cleaned up"
jq -e '.route.rules | any(.outbound == "block") | not' "$is_config_json" >/dev/null || fail "legacy outbound: block rules must be migrated"
jq -e '.route.rules | any(.rule_set == ["geosite-cn", "geoip-cn"] and .action == "reject")' "$is_config_json" >/dev/null || fail "migrated rule must use action: reject"

# 21.3 若系统安装了真实 sing-box 二进制，对最终运行时配置执行真实 sing-box check 验证
"$FAKE_CORE" check -c "$is_config_json" -C "$is_conf_dir" || fail "mock sing-box check failed on final config"
real_core=
for b in /etc/sing-box/bin/sing-box /usr/local/bin/sing-box /usr/bin/sing-box; do
    if [[ -x $b ]]; then real_core=$b; break; fi
done
if [[ $real_core ]]; then
    real_check_out=$("$real_core" check -c "$is_config_json" -C "$is_conf_dir" 2>&1) || fail "real sing-box check failed ($real_core): $real_check_out"
    [[ $real_check_out != *"deprecated"* && $real_check_out != *"WARN"* ]] || fail "real sing-box check output should not contain deprecation warnings: $real_check_out"
fi

# 清理测试
main block-cn off 2>&1 >/dev/null
echo "PASS: all block-cn tests passed for $CORE_FILE"
CASE
}

run_test_suite "$repo_root/src/core.sh" || fail "test suite failed for src/core.sh"
run_test_suite "$repo_root/core.sh" || fail "test suite failed for core.sh"

echo "PASS: tests-block-cn.sh completed successfully."
