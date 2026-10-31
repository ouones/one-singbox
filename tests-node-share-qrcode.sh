#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
cleanup() {
  local status=$?
  if [[ $status != 0 ]]; then
    for output_file in "$workdir"/*/*.out; do
      [[ -f $output_file ]] || continue
      printf '%s\n' "--- $output_file ---"
      cat "$output_file"
    done
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT

mkdir -p "$workdir/bin"
cat >"$workdir/bin/qrencode" <<'FAKE_QRENCODE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$QR_LOG"
printf 'QRCODE_RENDERED\n'
exit "${QR_EXIT:-0}"
FAKE_QRENCODE
chmod +x "$workdir/bin/qrencode"

fail() {
  echo "FAIL: $1"
  exit 1
}

run_core_case() {
  local core_file=$1 case_name=$2
  CORE_FILE="$core_file" CASE_DIR="$workdir/$case_name" QR_BIN="$workdir/bin" bash <<'CASE' || exit 1
set -o pipefail

fail() {
  echo "FAIL(${CORE_FILE}): $1"
  exit 1
}

expect_qr_args() {
  local expected_url=$1
  [[ -f $QR_LOG ]] || fail "qrencode was not called"
  local qr_args=()
  mapfile -t qr_args <"$QR_LOG"
  [[ ${#qr_args[@]} == 3 ]] || fail "qrencode expected exactly three arguments, got ${#qr_args[@]}"
  [[ ${qr_args[0]} == -t && ${qr_args[1]} == ANSI ]] || fail "qrencode options changed: ${qr_args[*]}"
  [[ ${qr_args[2]} == "$expected_url" ]] || fail "qrencode input differs from the displayed URL"
}

type() {
  if [[ ${QR_MISSING:-} && $1 == -P && $2 == qrencode ]]; then
    return 0
  fi
  builtin type "$@"
}

source "$CORE_FILE"
case_dir=$CASE_DIR
mkdir -p "$case_dir/conf/.quan-meta"
export PATH="$QR_BIN:$PATH"
export QR_LOG="$case_dir/qr-args.log"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin=/bin/true
is_core_ver=1.14.0
is_dont_get_ip=1
is_dont_auto_exit=
is_dont_show_info=
is_gen=
ip=203.0.113.10
is_config_file=
is_config_name=
is_new_protocol=
is_protocol=
net=
is_main_start=
is_change=
manage_log="$case_dir/manage.log"
: >"$manage_log"
manage() { printf '%s\n' "$*" >>"$manage_log"; }
is_port_used() { return 1; }
printf '%s\n' '{"outbounds":[{"tag":"direct","type":"direct"}],"route":{"rules":[]}}' >"$is_config_json"

# Creation and automatic details share the existing add -> info flow.
unset is_config_file is_config_name is_new_protocol is_protocol net port uuid password ss_password ss_method
add ss 41601 'p@ss:#/雪' aes-128-gcm >"$case_dir/add.out" 2>&1 || fail "SS node creation should succeed"
wait
expected_url=$is_url
[[ $expected_url == ss://* ]] || fail "created SS node should expose its original URL"
[[ $(<"$case_dir/add.out") == *"$expected_url"* ]] || fail "creation output should retain the original URL"
expect_qr_args "$expected_url"
[[ $(grep -c 'QRCODE_RENDERED' "$case_dir/add.out") == 1 ]] || fail "creation should render one QR code"
[[ $(grep -c '^' "$manage_log") == 1 ]] || fail "successful creation should perform its existing single restart"

# QR failures must not turn a successful create into a failure or trigger another restart.
before_restarts=$(grep -c '^' "$manage_log")
rm -f "$QR_LOG"
(
  unset is_config_file is_config_name is_new_protocol is_protocol net net_type port uuid password ss_password ss_method json_str is_url
  QR_EXIT=23 add ss 41604 'test-failure-password' aes-128-gcm || exit 1
  printf '%s\n' "$is_url" >"$case_dir/add-failure-url.txt"
) >"$case_dir/add-failure.out" 2>&1 || fail "qrencode failure must not fail node creation"
wait
failure_url=$(<"$case_dir/add-failure-url.txt")
[[ $(<"$case_dir/add-failure.out") == *"二维码生成失败"* && $(<"$case_dir/add-failure.out") == *"$failure_url"* ]] || fail "creation should report QR failure and retain URL"
[[ -f "$is_conf_dir/Shadowsocks-41604.json" ]] || fail "qrencode failure must not remove the created node"
[[ $(grep -c '^' "$manage_log") == $((before_restarts + 1)) ]] || fail "QR failure must not trigger an extra service operation"

before_restarts=$(grep -c '^' "$manage_log")
rm -f "$QR_LOG"
(
  unset is_config_file is_config_name is_new_protocol is_protocol net net_type port uuid password ss_password ss_method json_str is_url
  QR_MISSING=1 add ss 41605 'test-missing-password' aes-128-gcm || exit 1
  printf '%s\n' "$is_url" >"$case_dir/add-missing-url.txt"
) >"$case_dir/add-missing.out" 2>&1 || fail "missing qrencode must not fail node creation"
wait
missing_url=$(<"$case_dir/add-missing-url.txt")
[[ $(<"$case_dir/add-missing.out") == *"qrencode"* && $(<"$case_dir/add-missing.out") == *"$missing_url"* ]] || fail "creation should show install guidance and retain URL"
[[ ! -f $QR_LOG && -f "$is_conf_dir/Shadowsocks-41605.json" ]] || fail "missing qrencode must not block node creation"
[[ $(grep -c '^' "$manage_log") == $((before_restarts + 1)) ]] || fail "missing qrencode must not trigger an extra service operation"
QR_MISSING=

# A visible info call for a node with special characters and IPv6 passes one exact URL argument.
cat >"$is_conf_dir/special.json" <<'NODE'
{"inbounds":[{"tag":"special.json","type":"shadowsocks","listen":"::","listen_port":41602,"method":"aes-128-gcm","password":"p@ss:#/雪"}]}
NODE
meta_set special.json node_name '二维码%20node'
meta_set special.json entry_addr '2001:db8::10'
rm -f "$QR_LOG"
info special.json >"$case_dir/info.out" 2>&1 || fail "visible info should succeed"
special_url=$is_url
[[ $special_url == *"@[2001:db8::10]:41602#二维码%20node" ]] || fail "special IPv6 URL should preserve existing formatting: $special_url"
[[ $(<"$case_dir/info.out") == *"$special_url"* ]] || fail "info output should include its original URL"
expect_qr_args "$special_url"
[[ $(grep -c 'QRCODE_RENDERED' "$case_dir/info.out") == 1 ]] || fail "info should render one QR code"

# A node without a share URL must not reuse the preceding node's URL.
cat >"$is_conf_dir/relay-41603.json" <<'NODE'
{"inbounds":[{"tag":"relay-41603.json","type":"direct","listen":"::","listen_port":41603,"override_address":"203.0.113.20","override_port":41603}]}
NODE
rm -f "$QR_LOG"
info relay-41603.json >"$case_dir/no-link.out" 2>&1 || fail "info for an unshareable node should succeed"
[[ ! -f $QR_LOG ]] || fail "node without a share URL must not call qrencode"
[[ $is_url ]] && fail "node without a share URL must clear the previous URL"
[[ $(<"$case_dir/no-link.out") != *"QRCODE_RENDERED"* ]] || fail "node without a share URL must not display a QR code"

# Existing quiet and export paths do not invoke qrencode.
rm -f "$QR_LOG"
is_dont_show_info=1
info special.json >"$case_dir/quiet.out" 2>&1 || fail "is_dont_show_info path should succeed"
[[ ! -s "$case_dir/quiet.out" && ! -f $QR_LOG ]] || fail "is_dont_show_info path must stay quiet"
is_dont_show_info=
is_gen=1
info special.json >"$case_dir/gen.out" 2>&1 || fail "is_gen path should succeed"
[[ ! -s "$case_dir/gen.out" && ! -f $QR_LOG ]] || fail "is_gen path must stay quiet"
is_gen=
is_dont_auto_exit=1
info special.json >"$case_dir/no-auto-exit.out" 2>&1 || fail "is_dont_auto_exit path should succeed"
[[ ! -s "$case_dir/no-auto-exit.out" && ! -f $QR_LOG ]] || fail "is_dont_auto_exit path must stay quiet"
is_dont_auto_exit=
url_qr url special.json >"$case_dir/url.out" 2>&1 || fail "URL export should succeed"
[[ ! -f $QR_LOG ]] || fail "URL export must not call qrencode"
[[ $(<"$case_dir/url.out") == *"$special_url"* ]] || fail "URL export should retain the share URL"
[[ $(<"$case_dir/url.out") != *"QRCODE_RENDERED"* ]] || fail "URL export must not display a QR code"

# Independent QR remains available through the same renderer.
rm -f "$QR_LOG"
url_qr qr special.json >"$case_dir/qr.out" 2>&1 || fail "independent QR command should succeed"
expect_qr_args "$special_url"
[[ $(grep -c 'QRCODE_RENDERED' "$case_dir/qr.out") == 1 ]] || fail "independent QR command should render one QR code"

# Missing and failing qrencode are non-blocking for node details.
rm -f "$QR_LOG"
QR_MISSING=1
is_dont_show_info=
info special.json >"$case_dir/missing.out" 2>&1 || fail "missing qrencode must not fail info"
[[ ! -f $QR_LOG ]] || fail "missing qrencode must not be called"
[[ $(<"$case_dir/missing.out") == *"qrencode"* && $(<"$case_dir/missing.out") == *"$special_url"* ]] || fail "missing qrencode should show install guidance and retain URL: $(<"$case_dir/missing.out")"
QR_MISSING=
rm -f "$QR_LOG"
is_dont_show_info=
QR_EXIT=23 info special.json >"$case_dir/failing.out" 2>&1 || fail "qrencode failure must not fail info"
[[ -f $QR_LOG ]] || fail "failing qrencode should have been called"
[[ $(<"$case_dir/failing.out") == *"二维码生成失败"* && $(<"$case_dir/failing.out") == *"$special_url"* ]] || fail "qrencode failure should be clear and retain URL"

echo "PASS: QR details behavior for $(basename "$CORE_FILE")"
CASE
}

run_core_case "$repo_root/core.sh" root || fail "root core QR tests failed"
run_core_case "$repo_root/src/core.sh" src || fail "src core QR tests failed"
echo "PASS: node share QR tests"
