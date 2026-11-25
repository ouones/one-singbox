#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

setup_entry_fixture() {
    local name=$1 with_caddy=${2:-0}
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
version) printf 'sing-box version 1.14.4\n' ;;
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
    if [[ ${WITH_CADDY:-0} == 1 ]]; then
        printf 'loaded\n'
    else
        printf 'not-found\n'
    fi
    exit 0
fi
if [[ $1 == is-active ]]; then
    [[ $2 == --quiet ]] && exit 0
    printf 'active\n'
    exit 0
fi
printf '%s\n' "$*" >>"${SERVICE_LOG:?}"
if [[ $1 == restart ]]; then
    if [[ -z ${FAIL_UNIT:-} || ${2:-} == "$FAIL_UNIT" ]]; then
        exit 1
    fi
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
    cat >"$case_dir/bin/wget" <<'FAKE_WGET'
#!/usr/bin/env bash
if [[ $* == *cdn-cgi/trace* ]]; then
    printf 'ip=203.0.113.10\n'
fi
exit 0
FAKE_WGET
    cat >"$case_dir/bin/ss" <<'FAKE_SS'
#!/usr/bin/env bash
exit 0
FAKE_SS
    cat >"$case_dir/bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP

    chmod +x "$root/etc/sing-box/bin/sing-box" "$case_dir/bin/apt-get" "$case_dir/bin/systemctl" \
        "$case_dir/bin/curl" "$case_dir/bin/wget" "$case_dir/bin/ss" "$case_dir/bin/sleep"
    touch "$root/etc/sing-box/qrcode-dependency-checked" "$root/etc/sing-box/bin/tls.cer" "$root/etc/sing-box/bin/tls.key"
    printf '200\n' >"$root/etc/sing-box/log-limit-mb"
    printf '{"log":{"level":"info"},"dns":{},"route":{"rules":[]},"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$root/etc/sing-box/config.json"

    if [[ $with_caddy == 1 ]]; then
        mkdir -p "$root/etc/caddy/one-singbox" "$root/etc/caddy/sites"
        printf '{\n  admin off\n  http_port 80\n  https_port 443\n}\n' >"$root/etc/caddy/Caddyfile"
        cat >"$case_dir/bin/caddy" <<'FAKE_CADDY'
#!/usr/bin/env bash
printf 'v2.7.6\n'
FAKE_CADDY
        cat >"$case_dir/bin/pgrep" <<'FAKE_PGREP'
#!/usr/bin/env bash
printf '12345\n'
FAKE_PGREP
        chmod +x "$case_dir/bin/caddy" "$case_dir/bin/pgrep"
    fi

    printf '%s\n' "$case_dir"
}

assert_cli_restart_failure() {
    local name=$1 with_caddy=$2 fail_unit=$3 forbidden_text=$4
    shift 4
    local case_dir entry service_log out rc
    case_dir=$(setup_entry_fixture "$name" "$with_caddy")
    entry="$case_dir/root/etc/sing-box/sh/sing-box.sh"
    service_log="$case_dir/service.log"
    : >"$service_log"

    if [[ $name == relay-del ]]; then
        printf '%s\n' '{"inbounds":[{"tag":"relay-12000.json","type":"direct","listen":"::","listen_port":12000,"override_address":"203.0.113.10","override_port":20000}]}' >"$case_dir/root/etc/sing-box/conf/relay-12000.json"
    elif [[ $name == dd-node ]]; then
        printf '%s\n' '{"inbounds":[{"tag":"Shadowsocks-21001.json","type":"shadowsocks","listen":"::","listen_port":21001,"method":"aes-128-gcm","password":"secret"}]}' >"$case_dir/root/etc/sing-box/conf/Shadowsocks-21001.json"
    fi

    out=$(WITH_CADDY="$with_caddy" FAIL_UNIT="$fail_unit" SERVICE_LOG="$service_log" PATH="$case_dir/bin:$PATH" bash "$entry" "$@" 2>&1)
    rc=$?
    [[ $rc != 0 ]] || fail "$name: expected non-zero exit when $fail_unit restart fails, got rc=0 output=$out"
    [[ $out == *'服务重启失败'* ]] || fail "$name: missing restart failure feedback: $out"
    if [[ -n $forbidden_text ]]; then
        [[ $out != *"$forbidden_text"* ]] || fail "$name: printed misleading success '$forbidden_text' on restart failure: $out"
    fi
    grep -Fq "restart $fail_unit" "$service_log" || fail "$name: restart $fail_unit was not attempted: $(cat "$service_log")"
}

# 1. Critical write paths via sing-box.sh CLI
assert_cli_restart_failure log-info 0 sing-box '已更新 Log 设定为' log info
assert_cli_restart_failure dns-set 0 sing-box '已更新 DNS 为' dns set 1.1.1.1
assert_cli_restart_failure relay-add 0 sing-box '端口转发配置添加成功' relay add 12000 203.0.113.10 20000
assert_cli_restart_failure relay-del 0 sing-box '已删除端口转发配置:' relay delete 12000
assert_cli_restart_failure node-add 0 sing-box '' add ss 21001 secret aes-128-gcm
assert_cli_restart_failure dd-node 0 sing-box '' dd Shadowsocks-21001.json
assert_cli_restart_failure block-cn 0 sing-box '' block-cn enable
assert_cli_restart_failure fix-caddyfile 1 caddy 'fix 完成' fix-caddyfile

# 2. Interactive menu write path surfaces restart failure before returning to menu
menu_case=$(setup_entry_fixture menu-dns 0)
menu_entry="$menu_case/root/etc/sing-box/sh/sing-box.sh"
menu_log="$menu_case/service.log"
: >"$menu_log"
menu_out=$(printf '5\n2\n1\ny\n\n0\nq\n' | FAIL_UNIT=sing-box SERVICE_LOG="$menu_log" PATH="$menu_case/bin:$PATH" bash "$menu_entry" 2>&1)
menu_rc=$?
[[ $menu_rc == 0 ]] || fail "menu-dns: parent menu should resume cleanly after pause (rc=$menu_rc): $menu_out"
[[ $menu_out == *'服务重启失败'* ]] || fail "menu-dns: interactive DNS write did not surface restart failure: $menu_out"
[[ $menu_out != *'已更新 DNS 为'* ]] || fail "menu-dns: printed success despite restart failure: $menu_out"
[[ $menu_out == *'按回车返回菜单。'* ]] || fail "menu-dns: did not pause for user to read restart failure: $menu_out"

echo 'PASS: tests-restart-failure.sh'
