#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)

workdir=$(mktemp -d)
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

fake_core="$workdir/fake-sing-box"
cat >"$fake_core" <<'FAKE_CORE'
#!/usr/bin/env bash
case ${1:-} in
version)
    printf 'sing-box version %s\n' "${FAKE_CORE_VERSION:-1.14.0}"
    ;;
check)
    config=
    conf_dir=
    while [[ $# -gt 0 ]]; do
        case $1 in
        -c)
            config=$2
            shift 2
            ;;
        -C)
            conf_dir=$2
            shift 2
            ;;
        *)
            shift
            ;;
        esac
    done
    [[ -f $config ]] || exit 1
    if [[ $conf_dir ]]; then
        [[ -d $conf_dir ]] || exit 1
        jq -e '(.outbounds // []) | type == "array"' "$config" >/dev/null || exit 1
        for file in "$conf_dir"/*.json; do
            [[ -f $file ]] || continue
            jq -e . "$file" >/dev/null || exit 1
        done
        exit 0
    fi
    jq -e '
        (.inbounds | length == 1)
        and (.inbounds[0].type == "snell")
        and (.inbounds[0].listen == "::")
        and (.inbounds[0].listen_port | type == "number")
        and ((.inbounds[0].psk | type) == "string")
        and ((.inbounds[0] | has("tls")) | not)
        and ((.inbounds[0] | has("reality")) | not)
        and ((.inbounds[0] | has("transport")) | not)
        and (
            (
                .inbounds[0].version == 6
                and (.inbounds[0].mode == "default" or .inbounds[0].mode == "unshaped" or .inbounds[0].mode == "unsafe-raw")
                and ((.inbounds[0].psk | length) >= 12)
                and ((.inbounds[0].psk | length) <= 255)
                and ((.inbounds[0] | has("obfs_mode")) | not)
            )
            or
            (
                .inbounds[0].version == 5
                and (.inbounds[0].obfs_mode == "none" or .inbounds[0].obfs_mode == "http")
                and ((.inbounds[0].psk | length) > 0)
                and ((.inbounds[0] | has("mode")) | not)
            )
        )
    ' "$config" >/dev/null || exit 1
    [[ $(jq -r '.inbounds[0].psk' "$config") != reject-me ]] || exit 1
    ;;
esac
FAKE_CORE
chmod +x "$fake_core"

fail() {
  echo "FAIL: $1"
  exit 1
}

run_core_case() {
  local core_file=$1
  CORE_FILE="$core_file" FAKE_CORE="$fake_core" bash <<'CASE'
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
systemctl() {
    case $1 in
        restart | is-active) return 0 ;;
        show) echo 4321 ;;
    esac
}
sleep() { :; }

is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$FAKE_CORE"
is_core_ver=1.14.0
ip=203.0.113.10
is_dont_show_info=1
is_dont_auto_exit=1
mkdir -p "$is_conf_dir/.quan-meta"
manage_log="$case_dir/manage.log"
: >"$manage_log"
manage() { printf "%s\n" "$*" >>"$manage_log"; }
is_port_used() { [[ ${TEST_ACTIVE_PORT:-} == "$1" ]] && printf "%s\n" "$1"; }

get_snell_psk() { printf '%s\n' generated-psk; }

[[ " ${protocol_list[*]} " == *' Snell '* ]] || fail "protocol_list should include Snell"

desc_out=$(snell_mode_desc)
[[ $desc_out == *"default"* && $desc_out == *"unshaped"* && $desc_out == *"unsafe-raw"* ]] || fail "snell_mode_desc should describe all three modes"
[[ $desc_out == *"小白首选"* ]] || fail "snell_mode_desc should contain beginner guidance"

(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  add snell 41601 supplied-psk 5
) || fail "add snell with explicit PSK should succeed"
config=$is_conf_dir/snell-41601.json
[[ -f $config ]] || fail "expected $config to be created"
jq -e '
    .inbounds[0].type == "snell"
    and .inbounds[0].tag == "snell-41601.json"
    and .inbounds[0].listen == "::"
    and .inbounds[0].listen_port == 41601
    and .inbounds[0].version == 5
    and .inbounds[0].psk == "supplied-psk"
    and .inbounds[0].obfs_mode == "none"
' "$config" >/dev/null || fail "explicit PSK Snell JSON has unexpected shape"

# Test default Snell creation creates version 6 with mode default
(
  unset snell_psk snell_version snell_obfs_mode snell_mode port is_config_file is_config_name
  add snell 41602
) || fail "add snell with default parameters should succeed"
jq -e '
    .inbounds[0].version == 6
    and .inbounds[0].mode == "default"
    and (.inbounds[0] | has("obfs_mode") | not)
    and (.inbounds[0].psk | length >= 12)
' "$is_conf_dir/snell-41602.json" >/dev/null || fail "default snell config should be v6 with mode default and no obfs_mode"

# Test v6 PSK < 12 characters is rejected
(
  unset snell_psk snell_version snell_obfs_mode snell_mode port is_config_file is_config_name
  add snell 41620 shortpsk 6
) >"$case_dir/snell-short-psk.out" 2>&1 && fail "v6 PSK < 12 chars should fail"
[[ ! -f $is_conf_dir/snell-41620.json ]] || fail "short PSK should not create config"

# Test unsupported versions (e.g., version 4 and version 7) are rejected
for bad_ver in 4 7; do
  (
    unset snell_psk snell_version snell_obfs_mode snell_mode port is_config_file is_config_name
    add snell 41621 "valid-long-psk-123" "$bad_ver"
  ) >"$case_dir/snell-bad-ver.out" 2>&1 && fail "version $bad_ver should fail"
  [[ ! -f $is_conf_dir/snell-41621.json ]] || fail "unsupported version should not create config"
done

(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  add snell 0 supplied-psk 5
) >"$case_dir/snell-port-zero.out" 2>&1 && fail "port 0 should fail"
[[ ! -f $is_conf_dir/snell-0.json ]] || fail "port 0 should not create target file"

(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  add snell 65536 supplied-psk 5
) >"$case_dir/snell-port-high.out" 2>&1 && fail "port 65536 should fail"
[[ ! -f $is_conf_dir/snell-65536.json ]] || fail "port 65536 should not create target file"

jq -n '{inbounds:[{type:"vmess",listen_port:41604}]}' >"$is_conf_dir/existing.json"
(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  add snell 41604 supplied-psk 5
) >"$case_dir/snell-conflict.out" 2>&1 && fail "saved config port conflict should fail"
[[ ! -f $is_conf_dir/snell-41604.json ]] || fail "port conflict should not create target file"

shopt -s nullglob
snell_config_port_used 41604 || fail "saved config port should be detected"
shopt -q nullglob || fail "snell_config_port_used should restore enabled nullglob on a match"
shopt -u nullglob
if snell_config_port_used 41699; then
  fail "unused saved config port should not be detected"
fi
shopt -q nullglob && fail "snell_config_port_used should restore disabled nullglob after no match"

(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  TEST_ACTIVE_PORT=41610
  add snell 41610 supplied-psk 5
) >"$case_dir/snell-active-port.out" 2>&1 && fail "active listener port conflict should fail"
[[ ! -f $is_conf_dir/snell-41610.json ]] || fail "active listener port conflict should not create target file"

invalid_obfs_output=$(
  snell_psk=supplied-psk
  snell_version=5
  snell_obfs_mode=quic
  port=41611
  is_core_ver=1.14.0
  validate_snell
) 2>&1
[[ $? != 0 ]] || fail "unsupported obfs mode should fail"

empty_psk_output=$(
  snell_psk=
  snell_version=5
  snell_obfs_mode=none
  port=41612
  is_core_ver=1.14.0
  validate_snell
) 2>&1
[[ $? != 0 ]] || fail "empty PSK should fail"

version_output=$((
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  is_core_ver=1.13.9
  add snell 41605 supplied-psk 5
) 2>&1)
[[ $? != 0 ]] || fail "sing-box 1.13.9 should fail Snell creation"
[[ $version_output == *1.14.0* ]] || fail "1.13.9 failure should mention 1.14.0"
[[ ! -f $is_conf_dir/snell-41605.json ]] || fail "unsupported core version should not create target file"

unknown_output=$((
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  is_core_ver=unknown
  add snell 41606 supplied-psk 5
) 2>&1)
[[ $? != 0 ]] || fail "unknown sing-box version should fail Snell creation"
[[ $unknown_output == *1.14.0* ]] || fail "unknown version failure should mention 1.14.0"
[[ ! -f $is_conf_dir/snell-41606.json ]] || fail "unknown core version should not create target file"
for malformed_case in "1.14garbage:41607" "1.14.0garbage:41608"; do
  malformed_version=${malformed_case%%:*}
  malformed_port=${malformed_case##*:}
  malformed_output=$( (
    unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
    is_core_ver=$malformed_version
    add snell "$malformed_port" supplied-psk 5
  ) 2>&1 )
  [[ $? != 0 ]] || fail "$malformed_version should fail Snell creation"
  [[ $malformed_output == *1.14.0* ]] || fail "$malformed_version failure should mention 1.14.0"
  [[ ! -f $is_conf_dir/snell-$malformed_port.json ]] || fail "$malformed_version should not create target file"
done

jq -n \
  '{inbounds:[{tag:"snell-41601.json",type:"snell",listen:"::",listen_port:41601,version:5,psk:"old-psk",obfs_mode:"http"}]}' \
  >"$is_conf_dir/snell-41601.json"
jq -n '{node_name:"snell-node",entry_addr:"edge.example.com",outbound_mode:"V4优先"}' \
  >"$is_conf_dir/.quan-meta/snell-41601.json.meta.json"

is_dont_show_info=1
info snell-41601.json
[[ $is_protocol == snell ]] || fail "info should identify Snell protocol"
[[ $port == 41601 ]] || fail "info should extract Snell port"
[[ $snell_version == 5 ]] || fail "info should extract Snell version"
[[ $snell_psk == old-psk ]] || fail "info should extract Snell PSK"
[[ -n ${is_url:-} ]] || fail "Snell info should create a URL"
[[ $is_url == *"snell://old-psk@edge.example.com:41601?version=5&obfs=http#snell-node"* ]] || fail "Snell is_url mismatch: $is_url"
[[ -n ${is_surge_str:-} ]] || fail "Snell info should create a Surge configuration line"
[[ $is_surge_str == *"snell-node = snell, edge.example.com, 41601, psk=old-psk, version=5, obfs=http"* ]] || fail "Snell is_surge_str mismatch: $is_surge_str"
old_is_dont_auto_exit=$is_dont_auto_exit
is_dont_show_info=
is_dont_auto_exit=
info_output=$(info snell-41601.json)
for label in "协议 (protocol)" "版本 (version)" "PSK" "混淆模式 (obfs_mode)"; do
  [[ $info_output == *"$label"* ]] || fail "Snell info output should include $label"
done
is_dont_show_info=1
is_dont_auto_exit=$old_is_dont_auto_exit

# Test v6 default mode info and export formats
jq -n \
  '{inbounds:[{tag:"snell-41622.json",type:"snell",listen:"::",listen_port:41622,version:6,psk:"test-psk-12345678",mode:"default"}]}' \
  >"$is_conf_dir/snell-41622.json"
jq -n '{node_name:"snell-v6-node",entry_addr:"v6.example.com",outbound_mode:"V4优先"}' \
  >"$is_conf_dir/.quan-meta/snell-41622.json.meta.json"

is_dont_show_info=1
info snell-41622.json
[[ $is_protocol == snell ]] || fail "info should identify Snell protocol"
[[ $port == 41622 ]] || fail "info should extract Snell port"
[[ $snell_version == 6 ]] || fail "info should extract Snell v6 version"
[[ $snell_mode == default ]] || fail "info should extract Snell mode default"
[[ $snell_psk == "test-psk-12345678" ]] || fail "info should extract Snell PSK"
[[ $is_url == "snell://test-psk-12345678@v6.example.com:41622?version=6#snell-v6-node" ]] || fail "Snell v6 default URI mismatch: $is_url"
[[ $is_surge_str == "snell-v6-node = snell, v6.example.com, 41622, psk=test-psk-12345678, version=6" ]] || fail "Snell v6 default Surge mismatch: $is_surge_str"

# Test v6 unshaped mode exports &mode=unshaped
jq -n \
  '{inbounds:[{tag:"snell-41623.json",type:"snell",listen:"::",listen_port:41623,version:6,psk:"test-psk-12345678",mode:"unshaped"}]}' \
  >"$is_conf_dir/snell-41623.json"
jq -n '{node_name:"snell-v6-unshaped",entry_addr:"v6.example.com",outbound_mode:"V4优先"}' \
  >"$is_conf_dir/.quan-meta/snell-41623.json.meta.json"

is_dont_show_info=1
info snell-41623.json
[[ $snell_mode == unshaped ]] || fail "info should extract unshaped mode"
[[ $is_url == "snell://test-psk-12345678@v6.example.com:41623?version=6&mode=unshaped#snell-v6-unshaped" ]] || fail "v6 unshaped URI mismatch: $is_url"
[[ $is_surge_str == "snell-v6-unshaped = snell, v6.example.com, 41623, psk=test-psk-12345678, version=6, mode=unshaped" ]] || fail "v6 unshaped Surge mismatch: $is_surge_str"

# Test v6 terminal info output contains 运行模式 (mode)
old_is_dont_auto_exit=$is_dont_auto_exit
is_dont_show_info=
is_dont_auto_exit=
v6_info_output=$(info snell-41622.json)
for label in "协议 (protocol)" "版本 (version)" "PSK" "运行模式 (mode)"; do
  [[ $v6_info_output == *"$label"* ]] || fail "Snell v6 info output should include $label"
done
[[ $v6_info_output != *"混淆模式 (obfs_mode)"* ]] || fail "Snell v6 info should not display obfs_mode"
is_dont_show_info=1
is_dont_auto_exit=$old_is_dont_auto_exit

slash_psk='foo//bar'
(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  add snell 41613 "$slash_psk" 5
) || fail "Snell should create a config with // in its PSK"
printf '%s\n' '// trailing config comment' >>"$is_conf_dir/snell-41613.json"
slash_info_output=$( (
  is_dont_show_info=1
  info snell-41613.json
  printf 'PSK=%s\n' "$snell_psk"
) 2>&1 )
slash_info_status=$?
[[ $slash_info_status == 0 ]] || fail "Snell info should preserve // inside a PSK"
[[ $slash_info_output == *"PSK=$slash_psk"* ]] || fail "Snell info should display the complete // PSK"
change snell-41613.json obfs http || fail "Snell change should preserve a PSK containing //"
jq -e --arg psk "$slash_psk" '.inbounds[0].psk == $psk and .inbounds[0].obfs_mode == "http"' \
  "$is_conf_dir/snell-41613.json" >/dev/null || fail "Snell change should retain the complete // PSK"

display_psk='psk with spaces'
(
  unset snell_psk snell_version snell_obfs_mode port is_config_file is_config_name
  add snell 41614 "$display_psk" 5
) || fail "Snell should create a config with spaces in its PSK"
display_output=$( (
  is_dont_show_info=
  is_dont_auto_exit=
  info snell-41614.json
) 2>&1 )
[[ $display_output == *"$display_psk"* ]] || fail "Snell info should display a spaced PSK as one value"

change snell-41601.json psk new-psk || fail "Snell PSK change should succeed"
[[ $(jq -r '.inbounds[0].psk' "$is_conf_dir/snell-41601.json") == new-psk ]] || fail "Snell PSK change was not saved"

change snell-41601.json snell-version 5 || fail "Snell version change should succeed"
[[ $(jq -r '.inbounds[0].version' "$is_conf_dir/snell-41601.json") == 5 ]] || fail "Snell version change was not saved"

change snell-41601.json obfs none || fail "Snell obfs change should succeed"
[[ $(jq -r '.inbounds[0].obfs_mode' "$is_conf_dir/snell-41601.json") == none ]] || fail "Snell obfs change was not saved"

# Test change mode on v6 node
change snell-41622.json mode unshaped || fail "change mode unshaped on v6 node should succeed"
[[ $(jq -r '.inbounds[0].mode' "$is_conf_dir/snell-41622.json") == unshaped ]] || fail "v6 mode was not saved"

# Test smart routing: change mode on v5 node routes to obfs
change snell-41601.json mode http || fail "change mode on v5 node should route to obfs"
[[ $(jq -r '.inbounds[0].obfs_mode' "$is_conf_dir/snell-41601.json") == http ]] || fail "v5 obfs was not updated via mode"
change snell-41601.json mode none || fail "change mode none on v5 node should route to obfs"
[[ $(jq -r '.inbounds[0].obfs_mode' "$is_conf_dir/snell-41601.json") == none ]] || fail "v5 obfs was not reset"
change snell-41601.json mode http || fail "set obfs http on v5 node should succeed"
change snell-41601.json mode default || fail "change mode default on v5 node should adapt to none"
[[ $(jq -r '.inbounds[0].obfs_mode' "$is_conf_dir/snell-41601.json") == none ]] || fail "v5 obfs was not adapted to none via mode default"

# Test smart routing: change obfs with mode value on v6 node updates mode
change snell-41622.json obfs unsafe-raw || fail "change obfs with unsafe-raw on v6 node should update mode"
[[ $(jq -r '.inbounds[0].mode' "$is_conf_dir/snell-41622.json") == unsafe-raw ]] || fail "v6 mode was not updated via obfs"

# Test smart routing: change obfs with none/http on v6 node adapts to default mode
change snell-41622.json obfs http || fail "change obfs with http on v6 node should adapt"
[[ $(jq -r '.inbounds[0].mode' "$is_conf_dir/snell-41622.json") == default ]] || fail "v6 mode was not adapted to default"
change snell-41622.json mode unshaped || fail "set mode unshaped on v6 node should succeed"
change snell-41622.json obfs auto || fail "change obfs auto on v6 node should adapt to default"
[[ $(jq -r '.inbounds[0].mode' "$is_conf_dir/snell-41622.json") == default ]] || fail "v6 mode was not adapted to default via obfs auto"

# Test v6 PSK change rejects < 12 characters
(change snell-41622.json psk tooshort) >"$case_dir/v6-short-psk.out" 2>&1 && fail "v6 PSK change < 12 chars should fail"
[[ $(jq -r '.inbounds[0].psk' "$is_conf_dir/snell-41622.json") == "test-psk-12345678" ]] || fail "failed PSK change altered PSK"

# Test migration v5 -> v6
jq -n \
  '{inbounds:[{tag:"snell-41624.json",type:"snell",listen:"::",listen_port:41624,version:5,psk:"long-enough-psk-1234",obfs_mode:"http"}]}' \
  >"$is_conf_dir/snell-41624.json"
change snell-41624.json snell-version 6 || fail "migration v5 to v6 should succeed"
jq -e '
    .inbounds[0].version == 6
    and .inbounds[0].mode == "default"
    and (.inbounds[0] | has("obfs_mode") | not)
    and .inbounds[0].psk == "long-enough-psk-1234"
' "$is_conf_dir/snell-41624.json" >/dev/null || fail "v5 -> v6 migration output invalid"

# Test migration v6 -> v5
change snell-41624.json snell-version 5 || fail "migration v6 to v5 should succeed"
jq -e '
    .inbounds[0].version == 5
    and .inbounds[0].obfs_mode == "none"
    and (.inbounds[0] | has("mode") | not)
    and .inbounds[0].psk == "long-enough-psk-1234"
' "$is_conf_dir/snell-41624.json" >/dev/null || fail "v6 -> v5 migration output invalid"

# Test migration v5 -> v6 with short PSK generates new valid PSK
jq -n \
  '{inbounds:[{tag:"snell-41625.json",type:"snell",listen:"::",listen_port:41625,version:5,psk:"short",obfs_mode:"http"}]}' \
  >"$is_conf_dir/snell-41625.json"
change snell-41625.json snell-version 6 || fail "migration v5 to v6 with short PSK should succeed"
jq -e '
    .inbounds[0].version == 6
    and .inbounds[0].mode == "default"
    and (.inbounds[0] | has("obfs_mode") | not)
    and (.inbounds[0].psk | length >= 12)
' "$is_conf_dir/snell-41625.json" >/dev/null || fail "v5 -> v6 migration with short PSK output invalid"

if ! (TEST_ACTIVE_PORT=41601 change snell-41601.json port 41601 >/dev/null 2>&1); then
  fail "same-port Snell change should ignore the current active listener"
fi
[[ -f $is_conf_dir/snell-41601.json ]] || fail "same-port Snell change should keep the existing filename"

change snell-41601.json port 41606 || fail "Snell port change should succeed"
[[ ! -f $is_conf_dir/snell-41601.json ]] || fail "old Snell port file should be removed after replacement"
[[ -f $is_conf_dir/snell-41606.json ]] || fail "new Snell port file should exist after replacement"
jq -e '.node_name == "snell-node" and .entry_addr == "edge.example.com" and .outbound_mode == "V4优先"' \
  "$is_conf_dir/.quan-meta/snell-41606.json.meta.json" >/dev/null || fail "Snell metadata should move with port change"

wait
manage_before=$(wc -l <"$manage_log")
failure_output=$( (change snell-41606.json psk reject-me) 2>&1 )
[[ $? != 0 ]] || fail "rejected Snell replacement should fail"
wait
manage_after=$(wc -l <"$manage_log")
[[ $manage_after == $manage_before ]] || fail "rejected replacement should not restart the service"
[[ $(jq -r '.inbounds[0].psk' "$is_conf_dir/snell-41606.json") == new-psk ]] || fail "rejected replacement should preserve old JSON"
[[ -f $is_conf_dir/.quan-meta/snell-41606.json.meta.json ]] || fail "rejected replacement should preserve metadata"
if compgen -G "$is_conf_dir/.snell-*" >/dev/null; then
  fail "rejected replacement should remove temporary files"
fi

# Info display check for Snell
old_is_dont_auto_exit=$is_dont_auto_exit
is_dont_show_info=
is_dont_auto_exit=
info_output=$( (info snell-41606.json) 2>&1 )
is_dont_show_info=1
is_dont_auto_exit=$old_is_dont_auto_exit
[[ $info_output == *"snell://new-psk@edge.example.com:41606?version=5#snell-node"* ]] || fail "Snell info output should contain sing-box URI: $info_output"
[[ $info_output == *"snell-node = snell, edge.example.com, 41606, psk=new-psk, version=5"* ]] || fail "Snell info output should contain Surge config: $info_output"

# URL command check for Snell
url_output=$( (url_qr url snell-41606.json) 2>&1 )
url_status=$?
[[ $url_status == 0 ]] || fail "Snell URL command should succeed: $url_output"
[[ $url_output == *"snell://new-psk@edge.example.com:41606?version=5#snell-node"* ]] || fail "Snell URL command should output sing-box URI"
[[ $url_output == *"snell-node = snell, edge.example.com, 41606, psk=new-psk, version=5"* ]] || fail "Snell URL command should output Surge config"

# QR command check for Snell (explicitly unsupported)
qr_output=$( (url_qr qr snell-41606.json) 2>&1 || true )
[[ $qr_output == *"Snell 不支持二维码生成，请使用 URL 链接或 Surge 配置"* ]] || fail "Snell QR command should show unsupported message: $qr_output"

# Test http obfs link and config
(change snell-41606.json obfs http) >/dev/null 2>&1 || fail "change obfs to http should succeed"
url_http_out=$( (url_qr url snell-41606.json) 2>&1 )
[[ $url_http_out == *"snell://new-psk@edge.example.com:41606?version=5&obfs=http#snell-node"* ]] || fail "Snell URL command with http obfs should have &obfs=http: $url_http_out"
[[ $url_http_out == *"snell-node = snell, edge.example.com, 41606, psk=new-psk, version=5, obfs=http"* ]] || fail "Snell Surge config with http obfs should have , obfs=http: $url_http_out"

del snell-41606.json
[[ ! -e "$is_conf_dir/snell-41606.json" ]] || fail "Snell delete should remove the node JSON"

rm -f "$is_conf_dir"/*.json "$is_conf_dir/.quan-meta"/*.meta.json
jq -n '{inbounds:[{tag:"http-41615.json",type:"vmess",listen:"::",listen_port:41615,users:[{uuid:"00000000-0000-4000-8000-000000000015"}],transport:{type:"http"}}]}' \
  >"$is_conf_dir/http-41615.json"
jq -n '{inbounds:[{tag:"snell-41616.json",type:"snell",listen:"::",listen_port:41616,version:5,psk:"fix-psk",obfs_mode:"none"}]}' \
  >"$is_conf_dir/snell-41616.json"
jq -n '{inbounds:[{tag:"snell-41617.json",type:"snell",listen:"::",listen_port:41617,version:6,psk:"v6-fix-psk-1234",mode:"unshaped"}]}' \
  >"$is_conf_dir/snell-41617.json"
fix_all_output=$( (main fix-all) 2>&1 )
fix_all_status=$?
[[ $fix_all_status == 0 ]] || fail "fix-all should process HTTP before Snell"
jq -e '.inbounds[0].type == "snell" and .inbounds[0].psk == "fix-psk"' \
  "$is_conf_dir/snell-41616.json" >/dev/null || fail "fix-all should keep the later Snell node as Snell"
jq -e '
  .inbounds[0].type == "snell"
  and .inbounds[0].version == 6
  and .inbounds[0].mode == "unshaped"
  and .inbounds[0].psk == "v6-fix-psk-1234"
  and (.inbounds[0] | has("obfs_mode") | not)
' "$is_conf_dir/snell-41617.json" >/dev/null || fail "fix-all should preserve Snell v6 configuration"
CASE
}

run_core_case "$repo_root/core.sh" || exit 1
run_core_case "$repo_root/src/core.sh" || exit 1

grep -q 'Snell' "$repo_root/src/help.sh" || fail "src/help.sh should document Snell"
grep -q 'add snell \[port\] \[psk\] \[version\]' "$repo_root/src/help.sh" || fail "src/help.sh should document Snell add syntax"
grep -q '1.14.0' "$repo_root/src/help.sh" || fail "src/help.sh should document the Snell version floor"
grep -q 'mode \[name\]' "$repo_root/src/help.sh" || fail "src/help.sh should document mode command"
grep -q 'Snell' "$repo_root/README.md" || fail "README.md should document Snell"
grep -q 'add snell \[port\] \[psk\] \[version\]' "$repo_root/README.md" || fail "README.md should document Snell add syntax"
grep -q '1.14.0' "$repo_root/README.md" || fail "README.md should document the Snell version floor"
grep -q 'Snell v6' "$repo_root/README.md" || fail "README.md should document Snell v6"

echo "PASS: Snell offline generation and validation coverage"
