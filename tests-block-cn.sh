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
: >"$SERVICE_LOG"
: >"$RESTART_COUNT_FILE"
: >"$FAKE_CORE_LOG"

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
# 2: private ip block (ip_is_private: true -> block)
# 3: cn rule_set block (rule_set: ["geosite-cn", "geoip-cn"] -> block)
# 4: proxy_rules (node-proxy.json -> managed_node_ss_node-proxy_json)
# 5: direct_rules (node-one.json -> direct_v4_pref)
# 6: broad direct fallback (outbound: direct)
rules_count=$(jq '.route.rules | length' "$is_config_json")
[[ $rules_count -ge 7 ]] || fail "rules count should be at least 7, got $rules_count: $(jq -c '.route.rules' "$is_config_json")"

jq -e '.route.rules[0].action == "resolve"' "$is_config_json" >/dev/null || fail "rule 0 should be custom resolve"
jq -e '.route.rules[1].action == "hijack-dns"' "$is_config_json" >/dev/null || fail "rule 1 should be custom hijack-dns"
jq -e '.route.rules[2].ip_is_private == true and .route.rules[2].outbound == "block"' "$is_config_json" >/dev/null || fail "rule 2 should be private IP block"
jq -e '.route.rules[3].rule_set == ["geosite-cn", "geoip-cn"] and .route.rules[3].outbound == "block"' "$is_config_json" >/dev/null || fail "rule 3 should be CN rule_set block"
jq -e '.route.rules[4].inbound == ["node-proxy.json"] and .route.rules[4].outbound == "managed_node_ss_node-proxy_json"' "$is_config_json" >/dev/null || fail "rule 4 should be node proxy rule"
jq -e '.route.rules[5].inbound == ["node-one.json"] and .route.rules[5].outbound == "direct_v4_pref"' "$is_config_json" >/dev/null || fail "rule 5 should be node direct rule"
jq -e '.route.rules[6].outbound == "direct"' "$is_config_json" >/dev/null || fail "rule 6 should be fallback direct rule"

# D. 幂等性与防重复堆叠测试
sync_runtime_node_outbound_modes || fail "re-syncing failed"
[[ $(jq '.route.rules | length' "$is_config_json") == "$rules_count" ]] || fail "re-syncing must not duplicate rules"
[[ $(jq '[.outbounds[] | select(.tag == "block")] | length' "$is_config_json") == 1 ]] || fail "block outbound must not duplicate"
[[ $(jq '[.route.rule_set[] | select(.tag == "geosite-cn")] | length' "$is_config_json") == 1 ]] || fail "geosite-cn must not duplicate"

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

# 清理测试
main block-cn off 2>&1 >/dev/null
echo "PASS: all block-cn tests passed for $CORE_FILE"
CASE
}

run_test_suite "$repo_root/src/core.sh" || fail "test suite failed for src/core.sh"
run_test_suite "$repo_root/core.sh" || fail "test suite failed for core.sh"

echo "PASS: tests-block-cn.sh completed successfully."
