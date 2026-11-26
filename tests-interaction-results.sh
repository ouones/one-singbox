#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

setup_entry_env() {
    local name=$1
    local case_dir="$workdir/$name"
    local root="$case_dir/root"
    local sh_dir="$root/etc/sing-box/sh"
    local entry="$sh_dir/sing-box.sh"

    mkdir -p "$sh_dir/src" "$root/etc/sing-box/bin" "$root/etc/sing-box/conf/.quan-meta" \
        "$root/usr/local/bin" "$root/var/log/sing-box" "$case_dir/bin"
    cp -R "$repo_root/src/." "$sh_dir/src/"
    cp "$repo_root/sing-box.sh" "$entry"
    sed -i "s|^\. /etc/sing-box/sh/src/init.sh$|. $sh_dir/src/init.sh|" "$entry"
    sed -i \
        -e "s|^is_core_dir=/etc/|is_core_dir=$root/etc/|" \
        -e "s|^is_log_dir=/var/log/|is_log_dir=$root/var/log/|" \
        -e "s|^is_sh_bin=/usr/local/bin/|is_sh_bin=$root/usr/local/bin/|" \
        -e "s|^is_caddy_dir=/etc/caddy$|is_caddy_dir=$root/etc/caddy|" \
        "$sh_dir/src/init.sh"
    chmod +x "$entry"

    cat >"$root/etc/sing-box/bin/sing-box" <<'FAKE_CORE'
#!/usr/bin/env bash
case $1 in
version) printf 'sing-box version %s\n' "${FAKE_CORE_VER:-1.50.0}" ;;
check) [[ ${FAKE_CORE_CHECK_FAIL:-0} == 1 ]] && exit 1 || exit 0 ;;
esac
exit 0
FAKE_CORE
    cat >"$case_dir/bin/apt-get" <<'FAKE_APT'
#!/usr/bin/env bash
exit 0
FAKE_APT
    cat >"$case_dir/bin/systemctl" <<'FAKE_SYS'
#!/usr/bin/env bash
if [[ $1 == show && $* == *caddy.service* ]]; then
    printf 'not-found\n'
    exit 0
fi
if [[ -n ${SERVICE_LOG:-} ]]; then
    printf '%s\n' "$*" >>"$SERVICE_LOG"
fi
if [[ $1 == is-active ]]; then
    [[ $2 == --quiet ]] && exit 0
    printf '%s\n' "${TEST_SERVICE_STATE:-active}"
    case ${TEST_SERVICE_STATE:-active} in
        active) exit 0 ;;
        inactive | failed) exit 3 ;;
        *) exit 1 ;;
    esac
fi
exit 0
FAKE_SYS
    cat >"$case_dir/bin/wget" <<'FAKE_WGET'
#!/usr/bin/env bash
if [[ $* == *releases/latest* ]]; then
    printf '{"tag_name":"%s"}\n' "${FAKE_LATEST_VER:-v1.50.0}"
    exit 0
fi
printf 'UNEXPECTED_WGET:%s\n' "$*" >>"${WGET_LOG:-/dev/null}"
exit 1
FAKE_WGET
    cat >"$case_dir/bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
    chmod +x "$root/etc/sing-box/bin/sing-box" "$case_dir/bin/apt-get" "$case_dir/bin/systemctl" "$case_dir/bin/wget" "$case_dir/bin/sleep"
    touch "$root/etc/sing-box/qrcode-dependency-checked" "$root/etc/sing-box/bin/tls.cer" "$root/etc/sing-box/bin/tls.key"
    printf '200\n' >"$root/etc/sing-box/log-limit-mb"
    printf '{"log":{"level":"info"},"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$root/etc/sing-box/config.json"

    printf '%s\n' "$case_dir"
}

run_action_result_case() {
    local result=$1 case_dir entry output status expected message_line pause_line return_line
    case_dir=$(setup_entry_env "action-$result")
    entry="$case_dir/root/etc/sing-box/sh/sing-box.sh"

    case $result in
    success)
        output=$(printf '2\n1\n12000\n203.0.113.10\n20000\n\n\n0\nq\n' | PATH="$case_dir/bin:$PATH" bash "$entry" 2>&1)
        status=$?
        expected='端口转发配置添加成功!'
        ;;
    failure)
        output=$(printf '2\n1\n12000\n203.0.113.10\n20000\n\n\n0\nq\n' | FAKE_CORE_CHECK_FAIL=1 PATH="$case_dir/bin:$PATH" bash "$entry" 2>&1)
        status=$?
        expected='端口转发配置校验失败'
        ;;
    cancel)
        printf '%s\n' '{"inbounds":[{"tag":"relay-10000.json","type":"direct","listen_port":10000,"override_address":"203.0.113.10","override_port":20000}]}' >"$case_dir/root/etc/sing-box/conf/relay-10000.json"
        output=$(printf '2\n4\n1\nn\n0\nq\n' | PATH="$case_dir/bin:$PATH" bash "$entry" 2>&1)
        status=$?
        expected='已取消删除端口转发'
        ;;
    esac

    [[ $status == 0 ]] || fail "action $result parent menu did not resume cleanly: status=$status output=$output"
    [[ $output == *"$expected"* ]] || fail "action $result did not explain outcome: $output"
    message_line=$(awk -v text="$expected" 'index($0, text) { print NR; exit }' <<<"$output")
    if [[ $result == cancel ]]; then
        # A declined confirmation returns straight to the parent menu.
        [[ $output != *'按回车返回菜单。'* ]] || fail "action cancel left an extra pause: $output"
        return_line=$(awk 'index($0, "请选择端口转发操作") { count++; if (count == 2) { print NR; exit } }' <<<"$output")
        [[ $message_line -lt $return_line ]] || fail "action cancel, parent menu out of order: $output"
    else
        [[ $output == *'按回车返回菜单。'* ]] || fail "action $result did not wait for Enter: $output"
        pause_line=$(awk 'index($0, "按回车返回菜单。") { print NR; exit }' <<<"$output")
        return_line=$(awk 'index($0, "按回车返回菜单。") { paused=1 } paused && index($0, "0) 返回上级") { print NR; exit }' <<<"$output")
        [[ $message_line -lt $pause_line && $pause_line -lt $return_line ]] || fail "action $result order mismatch: $output"
    fi
    [[ $(grep -o '请选择端口转发操作' <<<"$output" | wc -l) == 2 ]] || fail "action $result did not return to relay menu: $output"
}

run_update_no_change_case() {
    local case_dir entry output status message_line pause_line return_line
    case_dir=$(setup_entry_env update-no-change)
    entry="$case_dir/root/etc/sing-box/sh/sing-box.sh"
    export SERVICE_LOG="$case_dir/service.log"
    export WGET_LOG="$case_dir/wget.log"
    : >"$SERVICE_LOG"
    : >"$WGET_LOG"

    output=$(printf '4\n1\ny\n\n0\nq\n' | FAKE_CORE_VER=1.50.0 FAKE_LATEST_VER=v1.50.0 PATH="$case_dir/bin:$PATH" bash "$entry" 2>&1)
    status=$?
    [[ $status == 0 ]] || fail "update menu did not resume after no change: status=$status output=$output"
    [[ $output == *'当前已经是最新版本了'* ]] || fail "no-change reason is not visible: $output"
    [[ ! -s $WGET_LOG ]] || fail "already-current version unexpectedly downloaded: $(cat "$WGET_LOG")"
    ! grep -Fq 'restart' "$SERVICE_LOG" || fail "already-current version restarted services: $(cat "$SERVICE_LOG")"
    message_line=$(awk 'index($0, "当前已经是最新版本了") { print NR; exit }' <<<"$output")
    pause_line=$(awk 'index($0, "按回车返回菜单。") { print NR; exit }' <<<"$output")
    return_line=$(awk 'index($0, "按回车返回菜单。") { paused=1 } paused && index($0, "0) 返回上级") { print NR; exit }' <<<"$output")
    [[ $message_line -lt $pause_line && $pause_line -lt $return_line ]] || fail "no-change, pause, and parent menu out of order: $output"
    [[ $(grep -o '请选择要更新的软件' <<<"$output" | wc -l) == 2 ]] || fail "Enter did not return to update menu: $output"
}

run_custom_update_no_change_case() {
    local case_dir output status message_line pause_line parent_line
    case_dir=$(setup_entry_env custom-update-no-change)
    output=$(
        PATH="$case_dir/bin:$PATH" bash -c '
            set -o pipefail
            is_core_dir="$1/root/etc/sing-box"
            is_conf_dir="$1/root/etc/sing-box/conf"
            is_log_dir="$1/root/var/log/sing-box"
            is_sh_dir="$1/root/etc/sing-box/sh"
            is_config_json="$1/root/etc/sing-box/config.json"
            is_core_bin="$1/root/etc/sing-box/bin/sing-box"
            is_core_ver=1.50.0
            source "$1/root/etc/sing-box/sh/src/core.sh"
            menu_action update core 1.50.0
            msg "父菜单继续显示"
        ' _ "$case_dir" <<<$'\n' 2>&1
    )
    status=$?
    [[ $status == 0 ]] || fail "custom no-change exited the panel: status=$status output=$output"
    [[ $output == *'自定义版本和当前 sing-box 版本一样, 无需更新.'* ]] || fail "custom no-change did not explain itself: $output"
    message_line=$(awk 'index($0, "自定义版本和当前 sing-box 版本一样") { print NR; exit }' <<<"$output")
    pause_line=$(awk 'index($0, "按回车返回菜单。") { print NR; exit }' <<<"$output")
    parent_line=$(awk 'index($0, "父菜单继续显示") { print NR; exit }' <<<"$output")
    [[ $message_line -lt $pause_line && $pause_line -lt $parent_line ]] || fail "custom no-change, pause, and parent out of order: $output"
}

run_status_color_case() {
    local case_dir entry spec test_state expected_text expected_color output status status_line pause_line return_line
    case_dir=$(setup_entry_env status-color)
    entry="$case_dir/root/etc/sing-box/sh/sing-box.sh"

    for spec in \
        'active|运行中|\e[92m' \
        'inactive|已停止|\e[31m' \
        'failed|启动失败|\e[31m' \
        'unknown|状态读取失败|\e[31m'; do
        IFS='|' read -r test_state expected_text expected_color <<<"$spec"
        printf -v expected_color '%b' "$expected_color"
        output=$(printf '3\n1\n\n0\nq\n' | TEST_SERVICE_STATE="$test_state" PATH="$case_dir/bin:$PATH" bash "$entry" 2>&1)
        status=$?
        [[ $status == 0 ]] || fail "service menu did not resume after status ($test_state): status=$status output=$output"
        [[ $output == *"$expected_text"* ]] || fail "status not text-readable ($test_state): $output"
        [[ $output == *"$expected_color$expected_text"* ]] || fail "status missing matching color ($test_state): $output"
        status_line=$(awk -v text="$expected_text" 'index($0, text) { print NR; exit }' <<<"$output")
        pause_line=$(awk 'index($0, "按回车返回菜单。") { print NR; exit }' <<<"$output")
        return_line=$(awk 'index($0, "按回车返回菜单。") { paused=1 } paused && index($0, "0) 返回上级") { print NR; exit }' <<<"$output")
        [[ $status_line -lt $pause_line && $pause_line -lt $return_line ]] || fail "status, pause, and service menu out of order ($test_state): $output"
        [[ $(grep -o '请选择服务操作' <<<"$output" | wc -l) == 2 ]] || fail "Enter did not return to service menu ($test_state): $output"
    done
}

run_information_page_case() {
    local page=$1 case_dir entry output status first_prompt information parent_count information_line pause_line return_line
    case_dir=$(setup_entry_env "info-$page")
    entry="$case_dir/root/etc/sing-box/sh/sing-box.sh"

    case $page in
    node)
        cat >"$case_dir/root/etc/sing-box/conf/Shadowsocks-21000.json" <<'JSON'
{"inbounds":[{"tag":"Shadowsocks-21000.json","type":"shadowsocks","listen":"::","listen_port":21000,"method":"aes-128-gcm","password":"secret"}]}
JSON
        output=$(printf '1\n3\n\n0\nq\n' | PATH="$case_dir/bin:$PATH" bash -c '
            is_dont_get_ip=1 ip=203.0.113.10
            export is_dont_get_ip ip
            bash "$1"
        ' _ "$entry" 2>&1)
        status=$?
        first_prompt='请选择节点操作'
        information='Shadowsocks-21000.json'
        parent_count=2
        ;;
    help)
        output=$(printf '6\n\nq\n' | PATH="$case_dir/bin:$PATH" bash "$entry" 2>&1)
        status=$?
        first_prompt='------------- one-singbox script'
        information='问题反馈:'
        parent_count=2
        ;;
    about)
        output=$(printf '7\n\nq\n' | PATH="$case_dir/bin:$PATH" bash "$entry" 2>&1)
        status=$?
        first_prompt='------------- one-singbox script'
        information='项目源码:'
        parent_count=2
        ;;
    esac

    [[ $status == 0 ]] || fail "$page info page did not exit cleanly: status=$status output=$output"
    [[ $(grep -o -- "$first_prompt" <<<"$output" | wc -l) == "$parent_count" ]] || fail "$page Enter did not return to parent menu: $output"
    information_line=$(awk -v text="$information" 'index($0, text) { print NR; exit }' <<<"$output")
    pause_line=$(awk 'index($0, "按回车返回菜单。") { print NR; exit }' <<<"$output")
    return_line=$(awk -v text="$first_prompt" 'index($0, text) { count++; if (count == 2) { print NR; exit } }' <<<"$output")
    [[ $information_line -lt $pause_line && $pause_line -lt $return_line ]] || fail "$page information, pause, and parent menu out of order: $output"
}

run_action_result_case success
run_action_result_case failure
run_action_result_case cancel
run_update_no_change_case
run_custom_update_no_change_case
run_status_color_case
run_information_page_case node
run_information_page_case help
run_information_page_case about

echo 'PASS: interaction results pause, explain outcomes, and return to the correct parent menu'
