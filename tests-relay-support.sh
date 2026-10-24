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
    if [[ $TEST_REJECT_COMPLETE == 1 && -n $conf_dir ]]; then
        exit 1
    fi
    if [[ -n $config ]]; then
        [[ -f $config ]] || exit 1
        if jq -e '.inbounds[0].type == "direct"' "$config" >/dev/null 2>&1; then
            jq -e '
                (.inbounds | length == 1)
                and (.inbounds[0].type == "direct")
                and (.inbounds[0].listen == "::")
                and (.inbounds[0].listen_port | type == "number")
                and (.inbounds[0].listen_port > 0)
                and (.inbounds[0].listen_port <= 65535)
                and ((.inbounds[0].override_address | type) == "string")
                and ((.inbounds[0].override_address | length) > 0)
                and (.inbounds[0].override_port | type == "number")
                and (.inbounds[0].override_port > 0)
                and (.inbounds[0].override_port <= 65535)
                and ((.inbounds[0] | has("network")) | not)
            ' "$config" >/dev/null || exit 1
            [[ $(jq -r '.inbounds[0].override_address' "$config") != reject-fragment ]] || exit 1
        fi
    fi
    if [[ -n $conf_dir ]]; then
        [[ -d $conf_dir ]] || exit 1
        shopt -s nullglob
        for f in "$conf_dir"/*.json; do
            jq -e . "$f" >/dev/null 2>&1 || exit 1
            if [[ $(jq -r '.inbounds[0].override_address // empty' "$f") == "reject-complete" ]]; then
                exit 1
            fi
        done
        shopt -u nullglob
    fi
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
  CORE_FILE="$core_file" FAKE_CORE="$fake_core" bash <<'CASE' || exit 1
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
is_dont_auto_exit=1
export ip=203.0.113.10 is_dont_get_ip=1
mkdir -p "$is_conf_dir"
manage_log="$case_dir/manage.log"
: >"$manage_log"
manage() { printf "%s\n" "$*" >>"$manage_log"; }
is_port_used() { [[ ${TEST_ACTIVE_PORT:-} == "$1" ]] && printf "%s\n" "$1"; }

# 1. Successful relay add with explicit values
add_out=$( (main relay add 10000 203.0.113.10 20000) 2>&1 )
[[ $? == 0 ]] || fail "relay add 10000 should succeed: $add_out"
config="$is_conf_dir/relay-10000.json"
[[ -f $config ]] || fail "relay-10000.json should exist"
jq -e '
    .inbounds[0].tag == "relay-10000.json"
    and .inbounds[0].type == "direct"
    and .inbounds[0].listen == "::"
    and .inbounds[0].listen_port == 10000
    and .inbounds[0].override_address == "203.0.113.10"
    and .inbounds[0].override_port == 20000
    and ((.inbounds[0] | has("network")) | not)
' "$config" >/dev/null || fail "relay-10000.json shape mismatch"
[[ ! -f "$is_conf_dir/.quan-meta/relay-10000.json.meta.json" ]] || fail "relay must not generate metadata"
[[ $add_out == *"防火墙"* || $add_out == *"ACL"* ]] || fail "relay add should emit security warning"
grep -q "restart" "$manage_log" || fail "manage restart should be called on successful add"

# 1.1 Successful relay add with interactive Enter allocating auto port
auto_add_out=$(printf "\n203.0.113.50\n20050\n" | (main relay add) 2>&1)
[[ $auto_add_out == *"自动分配本地端口"* ]] || fail "relay add with Enter should output auto port message: $auto_add_out"
auto_port=$(echo "$auto_add_out" | grep -o '自动分配本地端口: [0-9]\+' | awk '{print $2}')
[[ -n $auto_port ]] || fail "failed to parse auto allocated port from: $auto_add_out"
[[ -f "$is_conf_dir/relay-${auto_port}.json" ]] || fail "relay-${auto_port}.json should exist"

# 1.2 Interactive relay add with manually typed port (even matching auto port candidate) must not emit auto allocation message
(
    get_port() { tmp_port=10003; }
    manual_typed_out=$(printf "10003\n203.0.113.51\n20051\n" | (main relay add) 2>&1)
    [[ $manual_typed_out != *"自动分配本地端口"* ]] || exit 10
    [[ -f "$is_conf_dir/relay-10003.json" ]] || exit 11
) || fail "relay add with manually typed port should not emit auto allocation message even if matching auto_port"

# 2. IPv6 remote address
(main relay add 10001 "2001:db8::1" 20001) >/dev/null 2>&1 || fail "relay add with IPv6 should succeed"
[[ $(jq -r '.inbounds[0].override_address' "$is_conf_dir/relay-10001.json") == "2001:db8::1" ]] || fail "IPv6 remote address mismatch"

# 3. Invalid ports & empty address
(main relay add 0 203.0.113.10 20000) >/dev/null 2>&1 && fail "local port 0 should fail"
(main relay add 65536 203.0.113.10 20000) >/dev/null 2>&1 && fail "local port 65536 should fail"
(main relay add 10002 203.0.113.10 0) >/dev/null 2>&1 && fail "remote port 0 should fail"
(main relay add 10002 203.0.113.10 65536) >/dev/null 2>&1 && fail "remote port 65536 should fail"
(main relay add 10002 "   " 20000) >/dev/null 2>&1 && fail "empty remote address should fail"

# 4. Port conflicts (active listener, protocol node, existing relay)
TEST_ACTIVE_PORT=10005
(main relay add 10005 203.0.113.10 20000) >/dev/null 2>&1 && fail "active port conflict should fail"
jq -n '{inbounds:[{type:"vless",listen_port:10006}]}' > "$is_conf_dir/vless-10006.json"
(main relay add 10006 203.0.113.10 20000) >/dev/null 2>&1 && fail "protocol node port conflict should fail"
(main relay add 10000 203.0.113.10 30000) >/dev/null 2>&1 && fail "duplicate relay port should fail"

# 5. Fragment check failure
(main relay add 10007 reject-fragment 20000) >/dev/null 2>&1 && fail "fragment validation rejection should fail"
[[ ! -f "$is_conf_dir/relay-10007.json" ]] || fail "failed candidate must not be installed"

# 6. Complete config check failure rollback
echo '{"inbounds":[]}' > "$is_config_json"
export TEST_REJECT_COMPLETE=1
(main relay add 10008 203.0.113.10 20000) >/dev/null 2>&1 && fail "complete check rejection should fail"
[[ ! -f "$is_conf_dir/relay-10008.json" ]] || fail "complete check rollback should remove candidate"
unset TEST_REJECT_COMPLETE

# 7. Backward compatibility of config_port_used / snell_config_port_used
config_port_used 10000 || fail "config_port_used should detect relay port"
snell_config_port_used 10006 || fail "snell_config_port_used wrapper should detect vless port"
! config_port_used 59999 || fail "unused port should return 1"

# 8. relay info output format
info_out=$(main relay info 10000)
[[ $info_out == *"type = direct"* ]] || fail "relay info should contain type = direct"
[[ $info_out == *"listen = ::"* ]] || fail "relay info should contain listen = ::"
[[ $info_out == *"listen_port = 10000"* ]] || fail "relay info should contain listen_port = 10000"
[[ $info_out == *"override_address = 203.0.113.10"* ]] || fail "relay info should contain override_address"
[[ $info_out == *"override_port = 20000"* ]] || fail "relay info should contain override_port"
[[ $info_out == *"network = tcp,udp"* ]] || fail "relay info should report network = tcp,udp"
[[ $info_out == *"防火墙"* || $info_out == *"ACL"* ]] || fail "relay info should include security warning"
[[ $info_out != *"http"* && $info_out != *"vmess"* ]] || fail "relay info should not include share links"

# 9. relay list output
list_out=$(main relay list)
[[ $list_out == *"10000"* && $list_out == *"203.0.113.10"* && $list_out == *"20000"* ]] || fail "relay list should show relay 10000"
[[ $list_out == *"10001"* && $list_out == *"2001:db8::1"* ]] || fail "relay list should show relay 10001"
[[ $list_out == *"tcp,udp"* ]] || fail "relay list should report tcp,udp"
[[ $list_out == *"防火墙"* || $list_out == *"ACL"* ]] || fail "relay list should include security warning"

# 10. fix-all skips relay files
rm -f "$is_conf_dir/vless-10006.json"
jq -n '{inbounds:[{tag:"http-41615.json",type:"vmess",listen:"::",listen_port:41615,users:[{uuid:"00000000-0000-4000-8000-000000000015"}],transport:{type:"http"}}]}' \
  >"$is_conf_dir/http-41615.json"
content_before=$(cat "$is_conf_dir/relay-10000.json")
main fix-all >/dev/null 2>&1
content_after=$(cat "$is_conf_dir/relay-10000.json")
[[ "$content_before" == "$content_after" ]] || fail "fix-all must not alter relay-*.json"

# 11. relay delete rollback on complete config failure
export TEST_REJECT_COMPLETE=1
(main relay delete 10000) >/dev/null 2>&1 && fail "relay delete should fail when complete config check fails"
[[ -f "$is_conf_dir/relay-10000.json" ]] || fail "relay file should be restored after delete check failure"
unset TEST_REJECT_COMPLETE

# 12. relay delete success
restart_count_before=$(grep -c "restart" "$manage_log" || true)
(main relay delete 10000) >/dev/null 2>&1 || fail "relay delete 10000 should succeed"
[[ ! -f "$is_conf_dir/relay-10000.json" ]] || fail "relay-10000.json should be deleted"
restart_count_after=$(grep -c "restart" "$manage_log" || true)
(( restart_count_after > restart_count_before )) || fail "manage restart should be called on delete"
[[ -f "$is_conf_dir/relay-10001.json" ]] || fail "other relay files should not be deleted"

# 13. mainmenu item 11 is 中转管理 and unknown subcommand fails
[[ "${mainmenu[10]}" == "中转管理" ]] || fail "mainmenu item 11 must be 中转管理"
if (main relay unknown) >/dev/null 2>&1; then
    fail "unknown relay subcommand should fail"
fi

# 13.1. relay_menu option 2 is 中转列表 and does not prompt for local_port
(
    ask() {
        [[ "${is_tmp_list[1]}" == "中转列表" ]] || exit 2
        [[ "${is_tmp_list[1]}" != "中转列表/信息" ]] || exit 3
        REPLY=2
    }
    relay_menu
) || fail "relay_menu option 2 should be 中转列表"

menu_out=$(
    (
        ask() { REPLY=2; }
        relay_menu
    ) 2>&1
)
[[ $menu_out == *"中转列表"* ]] || fail "relay_menu option 2 should output relay list"
[[ $menu_out != *"请输入要查看的中转本地端口"* ]] || fail "relay_menu option 2 should not prompt for local port"

# 13.2. Interactive deletion must accept a relay port that is actively listening
TEST_ACTIVE_PORT=10001
restart_count_before=$(grep -c "restart" "$manage_log" || true)
delete_out=$(printf "3\n0\n65536\ninvalid\n10001\n" | (
    show_list() { :; }
    read() { builtin read "$@" || exit 99; }
    main relay || exit 1
    [[ $(is_test port_used 10001) ]] || fail "relay delete must not disable port conflict checks for later operations"
    if (main relay add 10001 203.0.113.10 20000) >/dev/null 2>&1; then
        fail "active port conflict should still prevent relay add after deletion"
    fi
) 2>&1)
delete_status=$?
[[ $delete_out != *"无法使用 (10001) 端口"* ]] || fail "interactive relay delete must accept its active port: $delete_out"
[[ $delete_status == 0 ]] || fail "interactive relay delete should succeed: $delete_out"
[[ $delete_out == *"请输入正确的端口"* ]] || fail "interactive relay delete must still validate port format"
[[ ! -f "$is_conf_dir/relay-10001.json" ]] || fail "interactive relay delete should remove relay-10001.json"
[[ -f "$is_conf_dir/relay-10003.json" ]] || fail "interactive relay delete must preserve other relays"
restart_count_after=$(grep -c "restart" "$manage_log" || true)
(( restart_count_after > restart_count_before )) || fail "interactive relay delete should restart the service"
unset TEST_ACTIVE_PORT


CASE
}

run_core_case "$repo_root/core.sh"
run_core_case "$repo_root/src/core.sh"

# 14. documentation checks
grep -q 'relay add \[local-port\] \[remote-addr\] \[remote-port\]' "$repo_root/src/help.sh" || fail "help.sh missing relay add"
grep -q 'relay list' "$repo_root/src/help.sh" || fail "help.sh missing relay list"
grep -q 'relay info \[local-port\]' "$repo_root/src/help.sh" || fail "help.sh missing relay info"
grep -q 'relay delete \[local-port\]' "$repo_root/src/help.sh" || fail "help.sh missing relay delete"
grep -q '防火墙' "$repo_root/src/help.sh" || fail "help.sh missing firewall warning"
grep -q 'ACL' "$repo_root/src/help.sh" || fail "help.sh missing ACL warning"

grep -q 'relay add \[local-port\] \[remote-addr\] \[remote-port\]' "$repo_root/README.md" || fail "README missing relay add"
grep -q 'relay list' "$repo_root/README.md" || fail "README missing relay list"
grep -q 'relay info \[local-port\]' "$repo_root/README.md" || fail "README missing relay info"
grep -q 'relay delete \[local-port\]' "$repo_root/README.md" || fail "README missing relay delete"
grep -q '防火墙' "$repo_root/README.md" || fail "README missing firewall warning"
grep -q 'ACL' "$repo_root/README.md" || fail "README missing ACL warning"
grep -q '中转管理' "$repo_root/README.md" || fail "README missing interactive relay entry"

echo "PASS: Task 3 interactive menu and documentation coverage"
