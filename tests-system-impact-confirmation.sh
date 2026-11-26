#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

setup_case_env() {
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

    cat >"$sh_dir/src/bbr.sh" <<'TEST_BBR'
_try_enable_bbr() {
    printf 'bbr-applied\n' >>"${TEST_BBR_EFFECT:?}"
}
TEST_BBR

    cat >"$root/etc/sing-box/bin/sing-box" <<'FAKE_CORE'
#!/usr/bin/env bash
case $1 in
version) printf 'sing-box version %s\n' "${FAKE_CORE_VER:-1.16.0}" ;;
check) exit 0 ;;
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
    if [[ ${TEST_WITH_CADDY:-0} == 1 ]]; then
        printf 'loaded\n'
    else
        printf 'not-found\n'
    fi
    exit 0
fi
printf '%s\n' "$*" >>"${SERVICE_LOG:?}"
if [[ $1 == is-active ]]; then
    [[ $2 == --quiet ]] && exit 0
    state=$(cat "${TEST_STATE_FILE:-/dev/null}" 2>/dev/null || printf '%s' "${TEST_SERVICE_STATE:-active}")
    [[ $state ]] || state=active
    case $state in
        active) printf 'active\n'; exit 0 ;;
        inactive) printf 'inactive\n'; exit 3 ;;
        *) printf 'unknown\n'; exit 1 ;;
    esac
fi
if [[ $1 == start || $1 == restart ]]; then
    [[ -n ${TEST_STATE_FILE:-} ]] && printf 'active\n' >"$TEST_STATE_FILE"
elif [[ $1 == stop ]]; then
    [[ -n ${TEST_STATE_FILE:-} ]] && printf 'inactive\n' >"$TEST_STATE_FILE"
fi
exit 0
FAKE_SYS
    cat >"$case_dir/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
out=
while (($#)); do
    case $1 in
    -o) out=$2; shift 2 ;;
    *) shift ;;
    esac
done
if [[ $out ]]; then
    printf '[{"domain_suffix":["example.org"]}]\n' >"$out"
fi
exit 0
FAKE_CURL
    cat >"$case_dir/bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
    chmod +x "$root/etc/sing-box/bin/sing-box" "$case_dir/bin/apt-get" "$case_dir/bin/systemctl" "$case_dir/bin/curl" "$case_dir/bin/sleep"
    touch "$root/etc/sing-box/qrcode-dependency-checked" "$root/etc/sing-box/bin/tls.cer" "$root/etc/sing-box/bin/tls.key"
    printf '200\n' >"$root/etc/sing-box/log-limit-mb"
    printf '{"dns":{},"route":{"rules":[]},"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$root/etc/sing-box/config.json"

    printf '%s\n' "$case_dir"
}

run_bbr_confirmation_case() {
    local case_dir entry input output
    case_dir=$(setup_case_env bbr)
    entry="$case_dir/root/etc/sing-box/sh/sing-box.sh"
    export SERVICE_LOG="$case_dir/service.log"
    export TEST_STATE_FILE="$case_dir/service.state"
    printf 'active\n' >"$TEST_STATE_FILE"
    export TEST_BBR_EFFECT="$case_dir/bbr-effect"

    for input in y Y n N '' 0 no 'Y '; do
        rm -f "$TEST_BBR_EFFECT"
        output=$(printf '5\n1\n%s\n0\nq\n' "$input" | PATH="$case_dir/bin:$PATH" bash "$entry" 2>&1)
        [[ $output == *'操作对象：系统内核拥塞控制（BBR）'* ]] || fail "BBR input '$input' did not identify BBR: $output"
        [[ $output == *'主要影响：修改 /etc/sysctl.conf 中的拥塞控制与队列设置'* ]] || fail "BBR input '$input' did not explain impact: $output"
        [[ $output == *'是否重启核心：否'* ]] || fail "BBR input '$input' did not state no restart: $output"
        if [[ $input == y || $input == Y ]]; then
            [[ -f $TEST_BBR_EFFECT ]] || fail "BBR input '$input' did not apply BBR: $output"
        else
            [[ ! -e $TEST_BBR_EFFECT ]] || fail "BBR input '$input' applied BBR: $output"
            [[ $output == *'已取消'* ]] || fail "BBR input '$input' did not report cancellation: $output"
            [[ $output != *'按回车返回菜单。'* ]] || fail "BBR input '$input' left an extra pause after cancellation: $output"
        fi
    done
}

run_dns_confirmation_case() {
    local case_dir entry spec branch choice address target answer input output
    case_dir=$(setup_case_env dns)
    entry="$case_dir/root/etc/sing-box/sh/sing-box.sh"
    local config_json="$case_dir/root/etc/sing-box/config.json"
    export SERVICE_LOG="$case_dir/service.log"
    export TEST_STATE_FILE="$case_dir/service.state"
    printf 'active\n' >"$TEST_STATE_FILE"

    for spec in 'custom|6|h3://dns.google/dns-query|DNS 配置：h3://dns.google/dns-query' 'none|7||DNS 配置：不设置'; do
        IFS='|' read -r branch choice address target <<<"$spec"
        for answer in y n; do
            printf '%s\n' '{"dns":{"servers":[{"tag":"old"}]},"route":{"default_domain_resolver":"old"},"outbounds":[{"tag":"direct","type":"direct"}]}' >"$config_json"
            : >"$SERVICE_LOG"
            if [[ $branch == custom ]]; then
                if [[ $answer == y ]]; then
                    input=$(printf '5\n2\n%s\n%s\n%s\n\n0\nq\n' "$choice" "$address" "$answer")
                else
                    input=$(printf '5\n2\n%s\n%s\n%s\n0\n0\nq\n' "$choice" "$address" "$answer")
                fi
            else
                if [[ $answer == y ]]; then
                    input=$(printf '5\n2\n%s\n%s\n\n0\nq\n' "$choice" "$answer")
                else
                    input=$(printf '5\n2\n%s\n%s\n0\n0\nq\n' "$choice" "$answer")
                fi
            fi
            output=$(printf '%s' "$input" | PATH="$case_dir/bin:$PATH" bash "$entry" 2>&1)
            [[ $output == *"操作对象：$target"* ]] || fail "DNS $branch/$answer did not identify target: $output"
            [[ $output == *'是否重启核心：是'* ]] || fail "DNS $branch/$answer did not state restart: $output"
            if [[ $answer == y ]]; then
                grep -Fq 'restart sing-box' "$SERVICE_LOG" || fail "DNS $branch/y did not restart core: $(cat "$SERVICE_LOG")"
                if [[ $branch == custom ]]; then
                    jq -e '.dns.servers[0].type == "h3" and .dns.servers[0].server == "dns.google"' "$config_json" >/dev/null || fail 'custom DNS was not applied'
                else
                    jq -e '.dns == {} and (.route | has("default_domain_resolver") | not)' "$config_json" >/dev/null || fail 'no-DNS selection was not applied'
                fi
            else
                jq -e '.dns.servers[0].tag == "old" and .route.default_domain_resolver == "old"' "$config_json" >/dev/null || fail "DNS $branch/$answer changed config"
                ! grep -Fq 'restart' "$SERVICE_LOG" || fail "DNS $branch/$answer restarted core"
                [[ $output == *'已取消'* ]] || fail "DNS $branch/$answer did not report the cancellation: $output"
                [[ $(grep -Fc '请选择 DNS' <<<"$output") == 2 ]] || fail "DNS $branch/$answer did not return to the DNS selection list: $output"
                [[ $output != *'按回车返回菜单。'* ]] || fail "DNS $branch/$answer must not leave the DNS selection after cancellation: $output"
            fi
        done
    done
}

run_block_cn_confirmation_case() {
    local case_dir entry spec initial action object impact answer output
    case_dir=$(setup_case_env block-cn)
    entry="$case_dir/root/etc/sing-box/sh/sing-box.sh"
    local marker="$case_dir/root/etc/sing-box/.block-cn-enabled"
    export SERVICE_LOG="$case_dir/service.log"
    export TEST_STATE_FILE="$case_dir/service.state"
    printf 'active\n' >"$TEST_STATE_FILE"

    for spec in 'disabled|enable|启用屏蔽回国流量（block-cn）|写入启用标记、同步回国白名单并重写运行时路由' 'enabled|disable|停用屏蔽回国流量（block-cn）|移除启用标记并重写运行时路由，恢复原有出站规则'; do
        IFS='|' read -r initial action object impact <<<"$spec"
        for answer in y n; do
            : >"$SERVICE_LOG"
            printf '%s\n' '{"dns":{},"route":{"rules":[]},"outbounds":[{"tag":"direct","type":"direct"}]}' >"$case_dir/root/etc/sing-box/config.json"
            if [[ $initial == enabled ]]; then : >"$marker"; else rm -f "$marker"; fi
            output=$(printf '5\n4\n%s\n0\nq\n' "$answer" | PATH="$case_dir/bin:$PATH" bash "$entry" 2>&1)
            [[ $output == *"操作对象：$object"* ]] || fail "block-cn $action/$answer did not identify target: $output"
            [[ $output == *"主要影响：$impact"* ]] || fail "block-cn $action/$answer did not explain impact: $output"
            [[ $output == *'是否重启核心：是'* ]] || fail "block-cn $action/$answer did not state restart: $output"
            if [[ $answer == y ]]; then
                grep -Fq 'restart sing-box' "$SERVICE_LOG" || fail "block-cn $action/y did not restart core"
                if [[ $action == enable ]]; then
                    [[ -f $marker ]] || fail 'enable did not create block-cn marker'
                else
                    [[ ! -e $marker ]] || fail 'disable did not remove block-cn marker'
                fi
            else
                ! grep -Fq 'restart' "$SERVICE_LOG" || fail "block-cn $action/$answer restarted core"
                if [[ $initial == enabled ]]; then
                    [[ -f $marker ]] || fail "block-cn $action/$answer removed marker"
                else
                    [[ ! -e $marker ]] || fail "block-cn $action/$answer created marker"
                fi
                [[ $output == *'已取消'* && $output != *'按回车返回菜单。'* ]] || fail "block-cn $action/$answer left an extra pause after cancellation: $output"
            fi
        done
    done
}

run_update_confirmation_case() {
    local case_dir spec choice expected_call object impact restart answer output
    case_dir=$(setup_case_env update)
    export SERVICE_LOG="$case_dir/service.log"
    export TEST_STATE_FILE="$case_dir/service.state"
    printf 'active\n' >"$TEST_STATE_FILE"

    run_update_menu_with_caddy() {
        local with_caddy=$1 input=$2
        CASE_DIR="$case_dir" WITH_CADDY="$with_caddy" PATH="$case_dir/bin:$PATH" bash -c '
            set -o pipefail
            is_core_dir="$CASE_DIR/root/etc/sing-box"
            is_conf_dir="$CASE_DIR/root/etc/sing-box/conf"
            is_log_dir="$CASE_DIR/root/var/log/sing-box"
            is_sh_dir="$CASE_DIR/root/etc/sing-box/sh"
            is_config_json="$CASE_DIR/root/etc/sing-box/config.json"
            is_core_bin="$CASE_DIR/root/etc/sing-box/bin/sing-box"
            is_core_ver=1.16.0
            source "$CASE_DIR/root/etc/sing-box/sh/src/core.sh"
            is_caddy=$WITH_CADDY
            update() { printf "%s\n" "$*" >>"$CASE_DIR/update-effects"; }
            update_menu
        ' <<<"$input" 2>&1
    }

    for spec in '1|1|sing-box 内核|下载并替换 sing-box 内核程序，保留现有配置|是' '2|2|one-singbox 脚本|下载并替换 one-singbox 脚本，不改 sing-box 配置|否' '3|caddy|Caddy|下载并替换 Caddy 程序并重启 Caddy，不改 sing-box 配置|否'; do
        IFS='|' read -r choice expected_call object impact restart <<<"$spec"
        for answer in y n; do
            rm -f "$case_dir/update-effects"
            output=$(run_update_menu_with_caddy 1 $''"$choice"$'\n'"$answer"$'\n0\n')
            [[ $output == *"操作对象：$object"* ]] || fail "update $choice/$answer did not identify target: $output"
            [[ $output == *"主要影响：$impact"* ]] || fail "update $choice/$answer did not explain impact: $output"
            [[ $output == *"是否重启核心：$restart"* ]] || fail "update $choice/$answer did not state restart impact: $output"
            if [[ $answer == y ]]; then
                [[ $(cat "$case_dir/update-effects" 2>/dev/null) == "$expected_call" ]] || fail "update $choice/y did not invoke update $expected_call: $output"
            else
                [[ ! -e $case_dir/update-effects ]] || fail "update $choice/$answer ran update"
                [[ $output == *'已取消'* && $output != *'按回车返回菜单。'* ]] || fail "update $choice/$answer left an extra pause after cancellation: $output"
            fi
        done
    done

    rm -f "$case_dir/update-effects"
    output=$(run_update_menu_with_caddy '' $'3\n0\n')
    [[ $output != *'更新 Caddy'* ]] || fail "uninstalled Caddy must not appear in update menu: $output"
    [[ $output == *'输入无效'* ]] || fail 'uninstalled Caddy choice must be rejected: $output'
    [[ ! -e $case_dir/update-effects ]] || fail 'uninstalled Caddy choice ran update'
}

run_service_confirmation_case() {
    local case_dir entry output spec choice action object impact restart answer
    case_dir=$(setup_case_env service)
    entry="$case_dir/root/etc/sing-box/sh/sing-box.sh"
    export SERVICE_LOG="$case_dir/service.log"
    export TEST_STATE_FILE="$case_dir/service.state"
    printf 'active\n' >"$TEST_STATE_FILE"

    : >"$SERVICE_LOG"
    output=$(printf '3\n2\n\n0\nq\n' | PATH="$case_dir/bin:$PATH" bash "$entry" 2>&1)
    [[ $output != *'系统影响确认'* ]] || fail "start must not require confirmation: $output"
    grep -Fq 'start sing-box' "$SERVICE_LOG" || fail 'start did not invoke systemctl start'

    for spec in '3|stop|sing-box 内核服务（停止）|停止监听并中断所有节点连接|否（执行后保持停止）' '4|restart|sing-box 内核服务（重启）|短暂中断所有节点连接后重新加载配置|是'; do
        IFS='|' read -r choice action object impact restart <<<"$spec"
        for answer in y n; do
            : >"$SERVICE_LOG"
            output=$(printf '3\n%s\n%s\n0\nq\n' "$choice" "$answer" | PATH="$case_dir/bin:$PATH" bash "$entry" 2>&1)
            [[ $output == *"操作对象：$object"* ]] || fail "service $action/$answer did not identify action: $output"
            [[ $output == *"主要影响：$impact"* ]] || fail "service $action/$answer did not explain impact: $output"
            [[ $output == *"是否重启核心：$restart"* ]] || fail "service $action/$answer did not state restart impact: $output"
            if [[ $answer == y ]]; then
                grep -Fq "$action sing-box" "$SERVICE_LOG" || fail "service $action/y did not invoke systemctl $action: $(cat "$SERVICE_LOG")"
            else
                ! grep -Eq "^(start|stop|restart) " "$SERVICE_LOG" || fail "service $action/$answer invoked service change: $(cat "$SERVICE_LOG")"
                [[ $output == *'已取消'* && $output != *'按回车返回菜单。'* ]] || fail "service $action/$answer left an extra pause after cancellation: $output"
            fi
        done
    done
}

run_cli_no_confirmation_case() {
    local case_dir entry output command
    case_dir=$(setup_case_env cli)
    entry="$case_dir/root/etc/sing-box/sh/sing-box.sh"
    local config_json="$case_dir/root/etc/sing-box/config.json"
    export SERVICE_LOG="$case_dir/service.log"
    export TEST_STATE_FILE="$case_dir/service.state"
    printf 'active\n' >"$TEST_STATE_FILE"
    export TEST_BBR_EFFECT="$case_dir/bbr-effect"

    cat >"$case_dir/bin/wget" <<'FAKE_WGET'
#!/usr/bin/env bash
if [[ $* == *releases/latest* ]]; then
    printf '{"tag_name":"v1.16.0"}\n'
    exit 0
fi
exit 0
FAKE_WGET
    chmod +x "$case_dir/bin/wget"

    : >"$SERVICE_LOG"
    printf '%s\n' '{"dns":{"servers":[{"tag":"old"}]},"route":{"default_domain_resolver":"old"},"outbounds":[{"tag":"direct","type":"direct"}]}' >"$config_json"

    for command in 'update core' 'dns none' 'bbr' 'stop' 'restart'; do
        output=$(PATH="$case_dir/bin:$PATH" bash "$entry" $command </dev/null 2>&1) || fail "CLI '$command' failed: $output"
        [[ $output != *'系统影响确认'* && $output != *'[y/N]'* && $output != *'确认执行上述操作'* ]] || fail "CLI '$command' added interactive confirmation: $output"
    done
    [[ -f $TEST_BBR_EFFECT ]] || fail 'CLI bbr did not apply BBR'
    grep -Fq 'restart sing-box' "$SERVICE_LOG" || fail 'CLI dns/restart did not restart sing-box'
    grep -Fq 'stop sing-box' "$SERVICE_LOG" || fail 'CLI stop did not stop sing-box'
    jq -e '.dns == {} and (.route | has("default_domain_resolver") | not)' "$config_json" >/dev/null || fail 'CLI DNS action did not keep its existing behavior'
}

run_bbr_confirmation_case
run_dns_confirmation_case
run_block_cn_confirmation_case
run_update_confirmation_case
run_service_confirmation_case
run_cli_no_confirmation_case

echo 'PASS: system impact confirmation'
