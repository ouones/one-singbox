#!/usr/bin/env bash
set -uo pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
cleanup() {
    rm -rf "$workdir"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

setup_entry_fixture() {
    local case_name=$1
    local case_dir="$workdir/$case_name"
    local root="$case_dir/root"
    local sh_dir="$root/etc/sing-box/sh"
    local entry="$sh_dir/sing-box.sh"

    mkdir -p "$sh_dir/src" "$root/etc/sing-box/bin" "$root/etc/sing-box/conf/.quan-meta" \
        "$root/usr/local/bin" "$root/var/log/sing-box" "$case_dir/bin"
    cp -R "$repo_root/src/." "$sh_dir/src/"
    sed -i '/EUID != 0/d' "$sh_dir/src/core.sh"
    cp "$repo_root/sing-box.sh" "$entry"
    sed -i "s|^\. /etc/sing-box/sh/src/init.sh$|. $sh_dir/src/init.sh|" "$entry"
    sed -i \
        -e "s|^is_core_dir=/etc/|is_core_dir=$root/etc/|" \
        -e "s|^is_log_dir=/var/log/|is_log_dir=$root/var/log/|" \
        -e "s|^is_sh_bin=/usr/local/bin/|is_sh_bin=$root/usr/local/bin/|" \
        -e "s|^is_caddy_dir=/etc/caddy$|is_caddy_dir=$root/etc/caddy|" \
        "$sh_dir/src/init.sh"
    chmod +x "$entry"

    printf '{"log":{"level":"info"},"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$root/etc/sing-box/config.json"

    cat >"$root/etc/sing-box/bin/sing-box" <<'FAKE_CORE'
#!/usr/bin/env bash
case $1 in
version) printf 'sing-box version 1.14.4\n' ;;
generate)
    if [[ $2 == tls-keypair ]]; then
        printf '-----BEGIN PRIVATE KEY-----\nfake\n-----END PRIVATE KEY-----\n'
        printf '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n'
    elif [[ $2 == reality-keypair ]]; then
        printf 'Private key: priv\nPublic key: pub\n'
    elif [[ $2 == uuid ]]; then
        printf '11111111-1111-1111-1111-111111111111\n'
    fi
    ;;
check) exit 0 ;;
esac
exit 0
FAKE_CORE
    chmod +x "$root/etc/sing-box/bin/sing-box"

    cat >"$case_dir/bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
case $1 in
show)
    if [[ $* == *LoadState* && $* == *caddy.service* ]]; then
        printf 'not-found\n'
        exit 0
    fi
    printf '4321\n'
    ;;
is-active)
    [[ $2 == --quiet ]] && exit 0
    printf 'active\n'
    ;;
esac
exit 0
FAKE_SYSTEMCTL
    chmod +x "$case_dir/bin/systemctl"

    cat >"$case_dir/bin/wget" <<'FAKE_WGET'
#!/usr/bin/env bash
if [[ $* == *cdn-cgi/trace* ]]; then
    printf 'ip=203.0.113.10\n'
fi
exit 0
FAKE_WGET
    chmod +x "$case_dir/bin/wget"

    cat >"$case_dir/bin/ss" <<'FAKE_SS'
#!/usr/bin/env bash
exit 0
FAKE_SS
    chmod +x "$case_dir/bin/ss"
}

write_sample_vmess_node() {
    local conf_dir=$1
    local name=$2
    local port=$3
    cat >"$conf_dir/$name" <<EOF
{
  "inbounds": [
    {
      "tag": "$name",
      "type": "vmess",
      "listen": "::",
      "listen_port": $port,
      "users": [
        {
          "uuid": "11111111-1111-1111-1111-111111111111"
        }
      ]
    }
  ]
}
EOF
}

# 1. `sb dd <node>` without Caddy must exit 0 (not bubble rc=1 from `[[ $is_del_host ]] && manage restart caddy &`)
setup_entry_fixture "dd-no-caddy"
case1="$workdir/dd-no-caddy"
write_sample_vmess_node "$case1/root/etc/sing-box/conf" "VMess-TCP-10001.json" 10001
write_sample_vmess_node "$case1/root/etc/sing-box/conf" "VMess-TCP-10002.json" 10002
if ! out=$(PATH="$case1/bin:$PATH" bash "$case1/root/etc/sing-box/sh/sing-box.sh" dd VMess-TCP-10001.json 2>&1); then
    fail "sing-box.sh dd failed with exit $? when caddy is disabled: $out"
fi
[[ ! -f $case1/root/etc/sing-box/conf/VMess-TCP-10001.json ]] || fail "VMess-TCP-10001.json was not deleted by dd"

# 2. `sb change <node> port <newport>` hits `create server` with node_migration_applied=1 (no meta file too!) and must exit 0
setup_entry_fixture "change-port"
case2="$workdir/change-port"
write_sample_vmess_node "$case2/root/etc/sing-box/conf" "VMess-TCP-20001.json" 20001
rm -rf "$case2/root/etc/sing-box/conf/.quan-meta/VMess-TCP-20001.json.meta.json"
if ! out=$(PATH="$case2/bin:$PATH" bash "$case2/root/etc/sing-box/sh/sing-box.sh" port VMess-TCP-20001.json 20002 2>&1); then
    fail "sing-box.sh port (create server with node_migration_applied=1) failed with exit $?: $out"
fi
[[ -f $case2/root/etc/sing-box/conf/VMess-TCP-20002.json ]] || fail "VMess-TCP-20002.json was not created on port change"

# 3. `sb status` and `sb url <node>` without Caddy / with IPv4 must exit 0
if ! out=$(PATH="$case2/bin:$PATH" bash "$case2/root/etc/sing-box/sh/sing-box.sh" status 2>&1); then
    fail "sing-box.sh status failed with exit $? without caddy: $out"
fi
if ! out=$(PATH="$case2/bin:$PATH" bash "$case2/root/etc/sing-box/sh/sing-box.sh" url VMess-TCP-20002.json 2>&1); then
    fail "sing-box.sh url failed with exit $?: $out"
fi

# 4. Direct helper boundary verification (meta_move_unlocked, meta_rm_unlocked, get addr, get new, init_core_ver, init_caddy_service_probe, caddy_config)
setup_entry_fixture "helpers"
case4="$workdir/helpers"
PATH="$case4/bin:$PATH" bash -c '
set -o pipefail
sh_dir="$1"
is_init_defs_only=1
. "$sh_dir/src/init.sh"
is_core_ver=
init_core_ver || { echo "init_core_ver returned non-zero when version exists" >&2; exit 1; }
[[ $is_core_ver == 1.14.4 ]] || { echo "unexpected is_core_ver: $is_core_ver" >&2; exit 1; }

is_systemd=
is_openrc=1
init_caddy_service_probe || { echo "init_caddy_service_probe returned non-zero under OpenRC without caddy init.d" >&2; exit 1; }

. "$sh_dir/src/core.sh"
meta_move_unlocked "nonexistent-a.json" "nonexistent-b.json" || { echo "meta_move_unlocked returned non-zero when source meta missing" >&2; exit 1; }
meta_rm_unlocked "nonexistent-a.json" || { echo "meta_rm_unlocked returned non-zero when meta missing" >&2; exit 1; }

host=
is_config_file=
is_listen_addr=
ip=203.0.113.10
get addr || { echo "get addr returned non-zero for IPv4" >&2; exit 1; }

host=example.com
port=12345
uuid=11111111-1111-1111-1111-111111111111
get new || { echo "get new returned non-zero when host/port/uuid already set" >&2; exit 1; }

is_caddy_dir="$sh_dir/caddy"
is_caddy_conf="$is_caddy_dir/conf"
is_caddyfile="$is_caddy_dir/Caddyfile"
is_http_port=80
is_https_port=443
. "$sh_dir/src/caddy.sh"
caddy_config new || { echo "caddy_config new returned non-zero" >&2; exit 1; }
' _ "$case4/root/etc/sing-box/sh" || fail "helper exit-code regression check failed"

echo "PASS: tests-trailing-exit-codes"
