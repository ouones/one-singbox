#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

fake_bin="$workdir/bin"
no_shuf_bin="$workdir/no-shuf-bin"
mkdir -p "$fake_bin" "$no_shuf_bin"

cat >"$fake_bin/wget" <<'FAKE_WGET'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_WGET_LOG"
printf 'http_proxy=%s https_proxy=%s HTTP_PROXY=%s HTTPS_PROXY=%s ALL_PROXY=%s all_proxy=%s\n' \
  "${http_proxy:-}" "${https_proxy:-}" "${HTTP_PROXY:-}" "${HTTPS_PROXY:-}" "${ALL_PROXY:-}" "${all_proxy:-}" >>"$FAKE_WGET_ENV_LOG"
[[ ${FAKE_WGET_EXIT:-0} == 0 ]] || exit "$FAKE_WGET_EXIT"
[[ ${FAKE_WGET_SLEEP:-0} == 0 ]] || /usr/bin/sleep "$FAKE_WGET_SLEEP"
cat "$FAKE_WGET_RESPONSE"
FAKE_WGET

cat >"$fake_bin/timeout" <<'FAKE_TIMEOUT'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$TIMEOUT_LOG"
exec /usr/bin/timeout "$@"
FAKE_TIMEOUT

cat >"$fake_bin/shuf" <<'FAKE_SHUF'
#!/usr/bin/env bash
range=
while (($#)); do
  case $1 in
    -i) range=$2; shift 2 ;;
    *) shift ;;
  esac
done
IFS=- read -r first last <<<"$range"
if [[ ${SHUF_CHOICE:-first} == last ]]; then
  printf '%s\n' "$last"
elif [[ ${SHUF_CHOICE:-first} == middle ]]; then
  printf '%s\n' "$(((first + last) / 2))"
else
  printf '%s\n' "$first"
fi
FAKE_SHUF

cat >"$fake_bin/sing-box" <<'FAKE_CORE'
#!/usr/bin/env bash
case $1 in
  generate)
    printf 'Private key: private-key-value\nPublic key: public-key-value\n'
    ;;
  check)
    exit 0
    ;;
esac
FAKE_CORE

cat >"$fake_bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
case $1 in
  show) printf '4321\n' ;;
esac
exit 0
FAKE_SYSTEMCTL

cat >"$fake_bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP

chmod +x "$fake_bin"/*
ln -s "$(command -v apt-get)" "$no_shuf_bin/apt-get"
ln -s "$(command -v awk)" "$no_shuf_bin/awk"
ln -s "$(command -v dirname)" "$no_shuf_bin/dirname"
ln -s "$fake_bin/systemctl" "$no_shuf_bin/systemctl"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

run_case() {
  local core_file=$1 scenario=$2 response=$3 expected=$4 choice=${5:-first}
  CORE_FILE="$core_file" TEST_SCENARIO="$scenario" TEST_RESPONSE="$response" \
    TEST_EXPECTED="$expected" SHUF_CHOICE="$choice" FAKE_WGET="$fake_bin/wget" \
    FAKE_CORE="$fake_bin/sing-box" TEST_BIN="$fake_bin" TEST_NOSHUFBIN="$no_shuf_bin" \
    PATH="$fake_bin:$PATH" bash <<'CASE'
set -o pipefail

case_dir=$(mktemp -d)
cleanup_case() { rm -rf "$case_dir"; }
trap cleanup_case EXIT
fail() { echo "FAIL(${CORE_FILE##*/}): $1" >&2; exit 1; }

export FAKE_WGET_LOG="$case_dir/wget.log"
export FAKE_WGET_ENV_LOG="$case_dir/wget-env.log"
export TIMEOUT_LOG="$case_dir/timeout.log"
export FAKE_WGET_RESPONSE="$case_dir/response.json"
export FAKE_WGET_EXIT=0
export FAKE_WGET_SLEEP=0
export SHUF_CHOICE
export http_proxy=http://script-proxy.invalid
export https_proxy=http://script-proxy.invalid
export HTTP_PROXY=http://script-proxy.invalid
export HTTPS_PROXY=http://script-proxy.invalid
export ALL_PROXY=http://script-proxy.invalid
export all_proxy=http://script-proxy.invalid
: >"$FAKE_WGET_LOG"
: >"$FAKE_WGET_ENV_LOG"
: >"$TIMEOUT_LOG"
printf '%s' "$TEST_RESPONSE" >"$FAKE_WGET_RESPONSE"
testable_core="$case_dir/core.sh"
sed '/^\[\[ \$EUID != 0 \]\] && err/d' "$CORE_FILE" >"$testable_core"

case ${TEST_SCENARIO} in
no-shuf)
  original_path=$PATH
  PATH=$TEST_NOSHUFBIN
  source "$testable_core"
  PATH="$TEST_BIN:$original_path"
  ;;
*)
  source "$testable_core"
  ;;
esac

is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$FAKE_CORE"
is_core_ver=1.14.0
is_dont_show_info=1
is_no_manage_msg=1
is_dont_get_ip=1
export ip=203.0.113.10
mkdir -p "$is_conf_dir/.quan-meta"
cat >"$is_config_json" <<'EOF'
{"dns":{},"route":{"default_domain_resolver":"local"},"outbounds":[{"tag":"direct","type":"direct"}]}
EOF
is_port_used() { return 1; }
manage() { :; }

assert_request_count() {
  local expected_count=$1 count
  count=$(wc -l <"$FAKE_WGET_LOG")
  [[ $count == "$expected_count" ]] || fail "expected $expected_count location requests, got $count"
  if [[ $expected_count != 0 ]]; then
    grep -Fq 'https://my.ippure.com/v1/info' "$FAKE_WGET_LOG" || fail "location URL was not requested"
    grep -Fxq '10' "$TIMEOUT_LOG" || fail "location request did not have a 10-second timeout"
    grep -Fq -- '-T 10' "$FAKE_WGET_LOG" || fail "wget did not have a 10-second timeout"
    grep -Fq -- '-t 1' "$FAKE_WGET_LOG" || fail "wget retry was not disabled"
    grep -Fq 'http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= ALL_PROXY= all_proxy=' "$FAKE_WGET_ENV_LOG" || fail "location lookup inherited a proxy"
    [[ $http_proxy == http://script-proxy.invalid && $https_proxy == http://script-proxy.invalid && $HTTP_PROXY == http://script-proxy.invalid && $HTTPS_PROXY == http://script-proxy.invalid && $ALL_PROXY == http://script-proxy.invalid && $all_proxy == http://script-proxy.invalid ]] || fail "location lookup changed the script proxy environment"
  fi
}

assert_created_sni() {
  local file=$1 expected=$2 got
  got=$(jq -r '.inbounds[0].tls.server_name' "$file")
  [[ $got == "$expected" ]] || fail "expected server_name $expected, got ${got:-<empty>}"
  [[ $(jq -r '.inbounds[0].tls.reality.handshake.server' "$file") == "$expected" ]] || fail "handshake SNI differs from server_name"
  [[ $(jq -r '.inbounds[0].tls.reality.handshake.server_port' "$file") == 443 ]] || fail "handshake port changed"
}

assert_add_result() {
  local protocol=${1:-reality} file expected
  expected=$TEST_EXPECTED
  main add "$protocol" 12345 11111111-1111-1111-1111-111111111111
  file="$is_conf_dir/$( [[ $protocol == rh2 ]] && echo VLESS-HTTP2-REALITY || echo VLESS-REALITY )-12345.json"
  [[ -f $file ]] || fail "automatic REALITY add did not write a configuration"
  assert_created_sni "$file" "$expected"
  [[ $is_url == *"sni=$expected"* ]] || fail "share URL did not use the selected SNI"
  if [[ $protocol == rh2 ]]; then
    [[ $(jq -r '.inbounds[0].transport.type' "$file") == http ]] || fail "HTTP2-REALITY transport changed"
  fi
  assert_request_count 1
}

write_existing_reality() {
  cat >"$is_conf_dir/VLESS-REALITY-12345.json" <<'EOF'
{"inbounds":[{"tag":"VLESS-REALITY-12345.json","type":"vless","listen":"::","listen_port":12345,"users":[{"uuid":"11111111-1111-1111-1111-111111111111","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"old.example.com","reality":{"enabled":true,"handshake":{"server":"old.example.com","server_port":443},"private_key":"private-key-value","short_id":[""]}}}],"outbounds":[{"type":"direct"},{"tag":"public_key_public-key-value"}]}
EOF
  jq -n '{node_name:"KeptName",entry_addr:"edge.example.com",outbound_mode:"V4优先",custom:"preserve"}' >"$is_conf_dir/.quan-meta/VLESS-REALITY-12345.json.meta.json"
  cat >"$is_conf_dir/VLESS-REALITY-23456.json" <<'EOF'
{"inbounds":[{"tag":"VLESS-REALITY-23456.json","type":"vless","listen":"::","listen_port":23456,"users":[{"uuid":"22222222-2222-2222-2222-222222222222","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"other.example.com","reality":{"enabled":true,"handshake":{"server":"other.example.com","server_port":443},"private_key":"other-private-key","short_id":[""]}}}],"outbounds":[{"type":"direct"}]}
EOF
  jq -n '{node_name:"OtherNode",custom:"keep"}' >"$is_conf_dir/.quan-meta/VLESS-REALITY-23456.json.meta.json"
}

case $TEST_SCENARIO in
create-de-first | create-de-last | create-sg | create-sg-bad-city | create-hk-first | create-hk-last | create-hk-bad-city | create-de-bad-city | create-fallback | create-fallback-last | create-us-san-jose-first | create-us-san-jose-middle | create-us-san-jose-last | create-us-los-angeles | create-us-new-york | create-us-santa-clara | create-us-no-city | create-us-empty-city | create-us-null-city | create-us-bad-city | create-us-california | create-us-ca | create-non-us-san-jose | create-non-us-los-angeles | malformed | array | empty | missing-country | null-country | bad-country-type | unknown-country | http-error | network-error | timeout | no-shuf)
  if [[ $TEST_SCENARIO == http-error || $TEST_SCENARIO == network-error ]]; then
    export FAKE_WGET_EXIT=8
  fi
  if [[ $TEST_SCENARIO == timeout ]]; then
    export FAKE_WGET_SLEEP=11
  fi
  if [[ $TEST_SCENARIO == create-de-last || $TEST_SCENARIO == create-hk-last || $TEST_SCENARIO == create-fallback-last || $TEST_SCENARIO == create-us-san-jose-last ]]; then
    export SHUF_CHOICE=last
  fi
  if [[ $TEST_SCENARIO == create-us-san-jose-middle ]]; then
    export SHUF_CHOICE=middle
  fi
  assert_add_result
  ;;
create-rh2 | create-rh2-us)
  assert_add_result rh2
  ;;
create-manual)
  main add reality 12345 11111111-1111-1111-1111-111111111111 www.cloudflare.com
  file="$is_conf_dir/VLESS-REALITY-12345.json"
  assert_created_sni "$file" www.cloudflare.com
  [[ $is_url == *"sni=www.cloudflare.com"* ]] || fail "explicit SNI missing from share URL"
  assert_request_count 0
  ;;
gen | gen-us-san-jose | gen-us-los-angeles)
  main gen reality 12345 11111111-1111-1111-1111-111111111111 >"$case_dir/gen.out"
  [[ ! -e "$is_conf_dir/VLESS-REALITY-12345.json" ]] || fail "gen wrote a configuration file"
  generated=$(awk 'BEGIN{printing=0} /^\{/ {printing=1} printing {print}' "$case_dir/gen.out")
  [[ $(jq -r '.inbounds[0].tls.server_name' <<<"$generated") == "$TEST_EXPECTED" ]] || fail "gen did not use the selected SNI"
  [[ $(jq -r '.inbounds[0].tls.reality.handshake.server' <<<"$generated") == "$TEST_EXPECTED" ]] || fail "gen handshake SNI differs"
  assert_request_count 1
  ;;
change-auto | change-auto-us-san-jose | change-auto-us-los-angeles)
  write_existing_reality
  cp "$is_conf_dir/VLESS-REALITY-23456.json" "$case_dir/other-node.before"
  cp "$is_conf_dir/.quan-meta/VLESS-REALITY-23456.json.meta.json" "$case_dir/other-node-meta.before"
  main change VLESS-REALITY-12345.json sni auto >/dev/null
  assert_created_sni "$is_conf_dir/VLESS-REALITY-12345.json" "$TEST_EXPECTED"
  jq -e '.node_name == "KeptName" and .entry_addr == "edge.example.com" and .outbound_mode == "V4优先" and .custom == "preserve"' "$is_conf_dir/.quan-meta/VLESS-REALITY-12345.json.meta.json" >/dev/null || fail "SNI auto changed node metadata"
  jq -e '.inbounds[0].users[0].uuid == "11111111-1111-1111-1111-111111111111" and .inbounds[0].tls.reality.private_key == "private-key-value"' "$is_conf_dir/VLESS-REALITY-12345.json" >/dev/null || fail "SNI auto changed the UUID or private key"
  [[ $is_url == *"sni=$TEST_EXPECTED"* ]] || fail "share URL did not use the automatically selected SNI"
  cmp -s "$case_dir/other-node.before" "$is_conf_dir/VLESS-REALITY-23456.json" || fail "SNI auto changed another node"
  cmp -s "$case_dir/other-node-meta.before" "$is_conf_dir/.quan-meta/VLESS-REALITY-23456.json.meta.json" || fail "SNI auto changed another node's metadata"
  assert_request_count 1
  ;;
change-other)
  write_existing_reality
  main change VLESS-REALITY-12345.json name ChangedName >/dev/null
  assert_created_sni "$is_conf_dir/VLESS-REALITY-12345.json" old.example.com
  assert_request_count 0
  ;;
change-manual)
  write_existing_reality
  main change VLESS-REALITY-12345.json sni manual.example.com >/dev/null
  assert_created_sni "$is_conf_dir/VLESS-REALITY-12345.json" manual.example.com
  assert_request_count 0
  ;;
non-reality)
  main add ss 12345 test-password aes-128-gcm >/dev/null
  [[ -f "$is_conf_dir/Shadowsocks-12345.json" ]] || fail "non-REALITY configuration was not created"
  assert_request_count 0
  ;;
read-only)
  write_existing_reality
  main info VLESS-REALITY-12345.json >/dev/null
  [[ $is_url == *"sni=old.example.com"* ]] || fail "read-only info changed the existing SNI"
  main help >/dev/null
  assert_request_count 0
  ;;
*) fail "unknown scenario $TEST_SCENARIO" ;;
esac
CASE
}

expect_case() {
  local core=$1 scenario=$2 response=$3 expected=$4 choice=${5:-first}
  run_case "$core" "$scenario" "$response" "$expected" "$choice"
  echo "PASS: ${core##*/} $scenario"
}

for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
  expect_case "$core_file" create-de-first '{"countryCode":"DE"}' www.uni-frankfurt.de
  expect_case "$core_file" create-de-last '{"countryCode":"DE"}' dff.film last
  expect_case "$core_file" create-sg '{"countryCode":"SG"}' trinitycollege.edu.sg
  expect_case "$core_file" create-hk-first '{"countryCode":"HK"}' www.hkapa.edu
  expect_case "$core_file" create-hk-last '{"countryCode":"HK"}' www.archsd.gov.hk last
  expect_case "$core_file" create-hk-bad-city '{"countryCode":"HK","city":7}' www.hkapa.edu
  expect_case "$core_file" create-de-bad-city '{"countryCode":"DE","city":null}' www.uni-frankfurt.de
  expect_case "$core_file" create-sg-bad-city '{"countryCode":"SG","city":[]}' trinitycollege.edu.sg
  expect_case "$core_file" create-fallback '{"countryCode":"US","city":"San Diego"}' www.amd.com
  expect_case "$core_file" create-fallback-last '{"countryCode":"US","city":"San Diego"}' www.amazon.com last
  expect_case "$core_file" create-us-san-jose-first '{"countryCode":"US","city":"San Jose"}' www.sccoe.org
  expect_case "$core_file" create-us-san-jose-middle '{"countryCode":"US","city":"San Jose"}' historysanjose.org middle
  expect_case "$core_file" create-us-san-jose-last '{"countryCode":"US","city":"San Jose"}' www.rosicrucianpark.org last
  expect_case "$core_file" create-us-los-angeles '{"countryCode":"US","city":"Los Angeles"}' lamag.org
  expect_case "$core_file" create-us-new-york '{"countryCode":"US","city":"New York"}' www.amd.com
  expect_case "$core_file" create-us-santa-clara '{"countryCode":"US","city":"Santa Clara"}' www.amd.com
  expect_case "$core_file" create-us-no-city '{"countryCode":"US"}' www.amd.com
  expect_case "$core_file" create-us-empty-city '{"countryCode":"US","city":""}' www.amd.com
  expect_case "$core_file" create-us-null-city '{"countryCode":"US","city":null}' www.amd.com
  expect_case "$core_file" create-us-bad-city '{"countryCode":"US","city":7}' www.amd.com
  expect_case "$core_file" create-us-california '{"countryCode":"US","city":"California","regionCode":"CA"}' www.amd.com
  expect_case "$core_file" create-us-ca '{"countryCode":"US","city":"CA"}' www.amd.com
  expect_case "$core_file" create-non-us-san-jose '{"countryCode":"NL","city":"San Jose"}' www.amd.com
  expect_case "$core_file" create-non-us-los-angeles '{"countryCode":"NL","city":"Los Angeles"}' www.amd.com
  expect_case "$core_file" malformed '{"countryCode":' www.amd.com
  expect_case "$core_file" array '[{"countryCode":"DE"}]' www.amd.com
  expect_case "$core_file" empty '' www.amd.com
  expect_case "$core_file" missing-country '{"city":"Frankfurt"}' www.amd.com
  expect_case "$core_file" null-country '{"countryCode":null}' www.amd.com
  expect_case "$core_file" bad-country-type '{"countryCode":7}' www.amd.com
  expect_case "$core_file" unknown-country '{"countryCode":"NL"}' www.amd.com
  expect_case "$core_file" http-error '{"countryCode":"DE"}' www.amd.com
  expect_case "$core_file" network-error '{"countryCode":"DE"}' www.amd.com
  expect_case "$core_file" timeout '{"countryCode":"DE"}' www.amd.com
  expect_case "$core_file" no-shuf '{"countryCode":"SG"}' trinitycollege.edu.sg
  expect_case "$core_file" create-rh2 '{"countryCode":"HK"}' www.hkapa.edu
  expect_case "$core_file" create-rh2-us '{"countryCode":"US","city":"San Jose"}' www.sccoe.org
  expect_case "$core_file" create-manual '{"countryCode":"DE"}' www.cloudflare.com
  expect_case "$core_file" gen '{"countryCode":"SG"}' trinitycollege.edu.sg
  expect_case "$core_file" gen-us-san-jose '{"countryCode":"US","city":"San Jose"}' historysanjose.org middle
  expect_case "$core_file" gen-us-los-angeles '{"countryCode":"US","city":"Los Angeles"}' lamag.org
  expect_case "$core_file" change-auto '{"countryCode":"HK"}' www.hkapa.edu
  expect_case "$core_file" change-auto-us-san-jose '{"countryCode":"US","city":"San Jose"}' www.rosicrucianpark.org last
  expect_case "$core_file" change-auto-us-los-angeles '{"countryCode":"US","city":"Los Angeles"}' lamag.org
  expect_case "$core_file" change-other '{"countryCode":"US","city":"Los Angeles"}' old.example.com
  expect_case "$core_file" change-manual '{"countryCode":"DE"}' manual.example.com
  expect_case "$core_file" non-reality '{"countryCode":"DE"}' ''
  expect_case "$core_file" read-only '{"countryCode":"DE"}' old.example.com
done

echo 'All REALITY SNI tests passed.'
