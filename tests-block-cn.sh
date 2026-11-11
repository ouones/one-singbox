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
    [[ $config && -f $config ]] || exit 2
    [[ ! $conf_dir || -d $conf_dir ]] || exit 2
    jq -e 'type == "object" and ((.outbounds // []) | type == "array") and ((.inbounds // []) | type == "array")' "$config" >/dev/null 2>&1 || exit 4
    if [[ $conf_dir ]]; then
        shopt -s nullglob
        for file in "$conf_dir"/*.json; do
            jq -e . "$file" >/dev/null 2>&1 || exit 5
        done
    fi
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
# A. outbounds 注入
jq -e '.outbounds | any(.tag == "block" and .type == "block")' "$is_config_json" >/dev/null || fail "block outbound must be injected"
jq -e '.outbounds | any(.tag == "custom-preserve")' "$is_config_json" >/dev/null || fail "custom outbounds must be preserved"

# B. rule_set 注入
jq -e '.route.rule_set | any(.tag == "geosite-cn" and .type == "remote" and .format == "binary" and .download_detour == "direct" and .url == "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs")' "$is_config_json" >/dev/null || fail "geosite-cn remote rule_set missing or invalid"
jq -e '.route.rule_set | any(.tag == "geoip-cn" and .type == "remote" and .format == "binary" and .download_detour == "direct" and .url == "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs")' "$is_config_json" >/dev/null || fail "geoip-cn remote rule_set missing or invalid"

# C. route.rules 注入与顺序
# 预期顺序：
# 0: resolve
# 1: hijack-dns
# 2: cn-whitelist bypass (domain/domain_suffix -> direct)
# 3: private ip block (ip_is_private: true -> block)
# 4: cn rule_set block (rule_set: ["geosite-cn", "geoip-cn"] -> block)
# 5: proxy_rules (node-proxy.json -> managed_node_ss_node-proxy_json)
# 6: direct_rules (node-one.json -> direct_v4_pref)
# 7: broad direct fallback (outbound: direct)
rules_count=$(jq '.route.rules | length' "$is_config_json")
[[ $rules_count -ge 8 ]] || fail "rules count should be at least 8, got $rules_count: $(jq -c '.route.rules' "$is_config_json")"

jq -e '.route.rules[0].action == "resolve"' "$is_config_json" >/dev/null || fail "rule 0 should be custom resolve"
jq -e '.route.rules[1].action == "hijack-dns"' "$is_config_json" >/dev/null || fail "rule 1 should be custom hijack-dns"
jq -e '.route.rules[2].action == "route" and .route.rules[2].outbound == "direct" and (.route.rules[2].domain | length > 0) and (.route.rules[2].domain_suffix | length > 0)' "$is_config_json" >/dev/null || fail "rule 2 should be cn-whitelist bypass"
jq -e '.route.rules[2].inbound == null' "$is_config_json" >/dev/null || fail "whitelist rule must not contain inbound restriction"
jq -e '.route.rules[3].ip_is_private == true and .route.rules[3].outbound == "block"' "$is_config_json" >/dev/null || fail "rule 3 should be private IP block"
jq -e '.route.rules[4].rule_set == ["geosite-cn", "geoip-cn"] and .route.rules[4].outbound == "block"' "$is_config_json" >/dev/null || fail "rule 4 should be CN rule_set block"
jq -e '.route.rules[5].inbound == ["node-proxy.json"] and .route.rules[5].outbound == "managed_node_ss_node-proxy_json"' "$is_config_json" >/dev/null || fail "rule 5 should be node proxy rule"
jq -e '.route.rules[6].inbound == ["node-one.json"] and .route.rules[6].outbound == "direct_v4_pref"' "$is_config_json" >/dev/null || fail "rule 6 should be node direct rule"
jq -e '.route.rules[7].outbound == "direct"' "$is_config_json" >/dev/null || fail "rule 7 should be fallback direct rule"

# D. 幂等性与防重复堆叠测试
sync_runtime_node_outbound_modes || fail "re-syncing failed"
[[ $(jq '.route.rules | length' "$is_config_json") == "$rules_count" ]] || fail "re-syncing must not duplicate rules"
[[ $(jq '[.outbounds[] | select(.tag == "block")] | length' "$is_config_json") == 1 ]] || fail "block outbound must not duplicate"
[[ $(jq '[.route.rule_set[] | select(.tag == "geosite-cn")] | length' "$is_config_json") == 1 ]] || fail "geosite-cn must not duplicate"
[[ $(jq '[.route.rules[] | select(.action == "route" and .outbound == "direct" and (.domain // [] | length > 0))] | length' "$is_config_json") == 1 ]] || fail "whitelist rule must not duplicate"

# 6. 入站嗅探 (sniff) 检查
# 现有节点在 enable 之后必须自动拥有 sniff: true 和 sniff_override_destination: true
jq -e '.inbounds[0].sniff == true and .inbounds[0].sniff_override_destination == true' "$is_conf_dir/node-one.json" >/dev/null || fail "node-one.json inbound sniffing should be enabled"
jq -e '.inbounds[0].sniff == true and .inbounds[0].sniff_override_destination == true' "$is_conf_dir/node-proxy.json" >/dev/null || fail "node-proxy.json inbound sniffing should be enabled"

# 7. CLI disable / off 测试
reset_service_log
disable_out=$(main block-cn disable 2>&1)
[[ $disable_out == *"屏蔽回国流量: 未启用"* ]] || fail "CLI block-cn disable output wrong: $disable_out"
[[ ! -f "$is_core_dir/.block-cn-enabled" ]] || fail "flag file .block-cn-enabled must be removed after disable"
[[ $(restart_count) -ge 1 ]] || fail "disable must restart service"

# 校验禁用后的运行时配置恢复
jq -e '.outbounds | any(.tag == "block") | not' "$is_config_json" >/dev/null || fail "block outbound must be removed after disable"
jq -e '(.route.rule_set // []) | any(.tag == "geosite-cn" or .tag == "geoip-cn") | not' "$is_config_json" >/dev/null || fail "CN rule_sets must be removed after disable"
jq -e '.route.rules | any(.outbound == "block") | not' "$is_config_json" >/dev/null || fail "block rules must be removed after disable"
jq -e '.route.rules | any(.action == "route" and .outbound == "direct" and (.domain // [] | length > 0)) | not' "$is_config_json" >/dev/null || fail "whitelist rule must be removed after disable"
[[ -f "$is_core_dir/.cn-whitelist.json" ]] || fail "whitelist cache file should be preserved on disk after disable"
jq -e '.outbounds | any(.tag == "custom-preserve")' "$is_config_json" >/dev/null || fail "custom outbounds must be preserved after disable"

# 禁用后不回滚嗅探设置
jq -e '.inbounds[0].sniff == true and .inbounds[0].sniff_override_destination == true' "$is_conf_dir/node-one.json" >/dev/null || fail "inbound sniffing must NOT be reverted on disable"
jq -e '.inbounds[0].sniff == true and .inbounds[0].sniff_override_destination == true' "$is_conf_dir/node-proxy.json" >/dev/null || fail "inbound sniffing must NOT be reverted on disable"

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
# 验证 block_cn_ensure_inbounds_sniffing 作用于新节点
block_cn_ensure_inbounds_sniffing "$is_conf_dir/node-new.json"
jq -e '.inbounds[0].sniff == true and .inbounds[0].sniff_override_destination == true' "$is_conf_dir/node-new.json" >/dev/null || fail "new node must have sniff enabled"

# 10. 保留自定义 rule_set 测试（用户自定义 remote/local 规则集不被受管逻辑破坏）
jq '.route.rule_set += [{"tag":"custom-ads","type":"remote","format":"binary","url":"https://example.com/ads.srs","download_detour":"direct"}]' "$is_config_json" >"$is_config_json.tmp" && mv -f "$is_config_json.tmp" "$is_config_json"
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
jq -e '.outbounds | any(.tag == "block")' "$is_config_json" >/dev/null || fail "create config.json should retain block outbound when enabled"
jq -e '.route.rule_set | any(.tag == "geosite-cn")' "$is_config_json" >/dev/null || fail "create config.json should retain geosite-cn when enabled"
jq -e '.route.rules | any(.ip_is_private == true and .outbound == "block")' "$is_config_json" >/dev/null || fail "create config.json should retain private IP block rule when enabled"
jq -e '.route.rules[0].action == "route" and .route.rules[0].outbound == "direct" and (.route.rules[0].domain | length > 0)' "$is_config_json" >/dev/null || fail "create config.json should retain whitelist bypass when enabled"

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
export FAKE_CURL_FAIL=1
warn_out2=$(block_cn_sync_whitelist 2>&1)
[[ $warn_out2 == *"下载回国白名单失败且无本地缓存"* ]] || fail "should warn about no cache available: $warn_out2"
# 确保虽然无白名单缓存，但配置同步不崩溃且阻断引擎正常运行
sync_runtime_node_outbound_modes || fail "sync without whitelist cache must not fail"
jq -e '.route.rules | any(.ip_is_private == true and .outbound == "block")' "$is_config_json" >/dev/null || fail "private ip block must still exist"
jq -e '.route.rules | any(.rule_set == ["geosite-cn", "geoip-cn"] and .outbound == "block")' "$is_config_json" >/dev/null || fail "cn rule_set block must still exist"
jq -e '.route.rules | any(.action == "route" and .outbound == "direct" and (.domain // [] | length > 0)) | not' "$is_config_json" >/dev/null || fail "no whitelist rule should be injected when cache is missing"
export FAKE_CURL_FAIL=0

# 15. 用户自定义直连规则在 block-cn 切换中的隔离与保护
# 添加一条用户自定义直连规则到 route.rules 首部
jq '.route.rules = [{action:"route",domain:["user-custom.direct.lan"],outbound:"direct"}] + .route.rules' "$is_config_json" >"$is_config_json.tmp" && mv -f "$is_config_json.tmp" "$is_config_json"
# 重新拉取标准白名单并同步
block_cn_sync_whitelist || fail "re-syncing whitelist failed"
sync_runtime_node_outbound_modes || fail "sync with user custom direct rule failed"
# 验证用户自定义直连规则仍然位于最前 (First-Match)
jq -e '.route.rules[0].domain == ["user-custom.direct.lan"] and .route.rules[0].outbound == "direct"' "$is_config_json" >/dev/null || fail "user custom direct rule must remain first"
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
jq -e '.outbounds | any(.tag == "block")' "$is_config_json" >/dev/null || fail "block outbound must exist after menu enable"
jq -e '.route.rule_set | any(.tag == "geosite-cn")' "$is_config_json" >/dev/null || fail "geosite-cn must exist after menu enable"

# 再次从已启用状态切换为未启用并退出菜单
reset_service_log
printf '4\n\n6\n' | system_tools_menu 2>&1 >/dev/null
block_cn_is_enabled && fail "block-cn should be disabled after second menu toggle"
[[ ! -f "$is_core_dir/.block-cn-enabled" ]] || fail "flag file must be removed after menu toggle to disable"
[[ $(restart_count) -ge 1 ]] || fail "menu toggle to disable must restart service"
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
# 确保入站嗅探配置
block_cn_ensure_inbounds_sniffing "$is_conf_dir/node-lifecycle.json"
jq -e '.inbounds[0].sniff == true and .inbounds[0].sniff_override_destination == true' "$is_conf_dir/node-lifecycle.json" >/dev/null || fail "lifecycle node inbound must have sniffing"

# 触发同步
sync_runtime_node_outbound_modes || fail "sync_runtime_node_outbound_modes failed after adding node"
# 断言：运行时配置中保留了 block-cn 出站、规则集与白名单规则，且新增节点的直连路由正确生成
jq -e '.outbounds | any(.tag == "block" and .type == "block")' "$is_config_json" >/dev/null || fail "block outbound lost after adding node"
jq -e '.route.rule_set | any(.tag == "geosite-cn")' "$is_config_json" >/dev/null || fail "geosite-cn lost after adding node"
jq -e '.route.rule_set | any(.tag == "geoip-cn")' "$is_config_json" >/dev/null || fail "geoip-cn lost after adding node"
jq -e '.route.rules | any(.ip_is_private == true and .outbound == "block")' "$is_config_json" >/dev/null || fail "private ip block rule lost after adding node"
jq -e '.route.rules | any(.rule_set == ["geosite-cn", "geoip-cn"] and .outbound == "block")' "$is_config_json" >/dev/null || fail "cn rule_set block rule lost after adding node"
jq -e '.route.rules | any(.domain // [] | any(. == "connectivitycheck.gstatic.com"))' "$is_config_json" >/dev/null || fail "whitelist rule lost after adding node"
jq -e '.route.rules | any(.inbound == ["node-lifecycle.json"] and .outbound == "direct_v6_pref")' "$is_config_json" >/dev/null || fail "new node route not found"

# 17.2 更改节点出站方式生命周期联动 (apply_node_outbound_mode_unlocked)
apply_node_outbound_mode_unlocked "node-lifecycle.json" "仅V4" || fail "apply_node_outbound_mode_unlocked failed"
# 断言：出站方式已变更为 direct_v4_only，但 block 出站与规则依然完整无损
jq -e '.route.rules | any(.inbound == ["node-lifecycle.json"] and .outbound == "direct_v4_only")' "$is_config_json" >/dev/null || fail "node route not updated to direct_v4_only"
jq -e '.outbounds | any(.tag == "block")' "$is_config_json" >/dev/null || fail "block outbound lost after modifying outbound mode"
jq -e '.route.rule_set | any(.tag == "geosite-cn")' "$is_config_json" >/dev/null || fail "geosite-cn lost after modifying outbound mode"
jq -e '.route.rules | any(.ip_is_private == true and .outbound == "block")' "$is_config_json" >/dev/null || fail "private block lost after modifying outbound mode"
jq -e '.route.rules | any(.domain // [] | any(. == "connectivitycheck.gstatic.com"))' "$is_config_json" >/dev/null || fail "whitelist lost after modifying outbound mode"

# 17.3 节点替换/重命名生命周期联动 (apply_node_config_lifecycle replace)
node_lifecycle_renamed_json=$(jq '.inbounds[0].tag = "node-lifecycle-renamed.json" | .inbounds[0].listen_port = 56789' "$is_conf_dir/node-lifecycle.json")
apply_node_config_lifecycle replace "node-lifecycle.json" "node-lifecycle-renamed.json" "$node_lifecycle_renamed_json" || fail "apply_node_config_lifecycle replace failed"
# 断言：重命名后新配置文件入站嗅探保留
jq -e '.inbounds[0].sniff == true and .inbounds[0].sniff_override_destination == true' "$is_conf_dir/node-lifecycle-renamed.json" >/dev/null || fail "renamed node must retain sniffing"
# 断言：运行时配置中 block-cn 规则无损
jq -e '.outbounds | any(.tag == "block")' "$is_config_json" >/dev/null || fail "block outbound lost after renaming node"
jq -e '.route.rule_set | any(.tag == "geosite-cn")' "$is_config_json" >/dev/null || fail "geosite-cn lost after renaming node"
jq -e '.route.rules | any(.domain // [] | any(. == "connectivitycheck.gstatic.com"))' "$is_config_json" >/dev/null || fail "whitelist lost after renaming node"
jq -e '.route.rules | any(.inbound == ["node-lifecycle-renamed.json"])' "$is_config_json" >/dev/null || fail "renamed node route not found"

# 17.4 节点删除生命周期联动 (apply_node_config_lifecycle delete)
apply_node_config_lifecycle delete "node-lifecycle-renamed.json" || fail "apply_node_config_lifecycle delete failed"
[[ ! -f "$is_conf_dir/node-lifecycle-renamed.json" ]] || fail "deleted node file should not exist"
# 断言：删除节点后 block-cn 规则依然完整无损
jq -e '.outbounds | any(.tag == "block")' "$is_config_json" >/dev/null || fail "block outbound lost after deleting node"
jq -e '.route.rule_set | any(.tag == "geosite-cn")' "$is_config_json" >/dev/null || fail "geosite-cn lost after deleting node"
jq -e '.route.rules | any(.domain // [] | any(. == "connectivitycheck.gstatic.com"))' "$is_config_json" >/dev/null || fail "whitelist lost after deleting node"
jq -e '.route.rules | any(.inbound == ["node-lifecycle-renamed.json"]) | not' "$is_config_json" >/dev/null || fail "deleted node route must be removed"

# 清理测试
main block-cn off 2>&1 >/dev/null
echo "PASS: all block-cn tests passed for $CORE_FILE"
CASE
}

run_test_suite "$repo_root/src/core.sh" || fail "test suite failed for src/core.sh"
run_test_suite "$repo_root/core.sh" || fail "test suite failed for core.sh"

echo "PASS: tests-block-cn.sh completed successfully."
