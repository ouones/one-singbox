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

# 4. Observable CLI entrypoints for version, OpenRC without caddy init.d, add with explicit args, and fix-caddyfile
setup_entry_fixture "cli-version"
case4="$workdir/cli-version"
out=$(PATH="$case4/bin:$PATH" bash "$case4/root/etc/sing-box/sh/sing-box.sh" version 2>&1) || fail "sing-box.sh version failed: $out"
[[ $out == *'sing-box 1.14.4'* ]] || fail "unexpected version output: $out"

setup_entry_fixture "openrc-no-caddy"
case5="$workdir/openrc-no-caddy"
mkdir -p "$case5/root/etc/caddy" "$case5/openrc-bin"
cat >"$case5/openrc-bin/apt-get" <<'FAKE_APT'
#!/usr/bin/env bash
exit 0
FAKE_APT
cat >"$case5/openrc-bin/rc-service" <<'FAKE_RC'
#!/usr/bin/env bash
exit 0
FAKE_RC
cat >"$case5/openrc-bin/caddy" <<'FAKE_CADDY'
#!/usr/bin/env bash
printf 'v2.7.6\n'
FAKE_CADDY
chmod +x "$case5/openrc-bin/apt-get" "$case5/openrc-bin/rc-service" "$case5/openrc-bin/caddy"
for tool in "$case5/bin"/*; do
    [[ ${tool##*/} == systemctl ]] && continue
    ln -sf "$tool" "$case5/openrc-bin/${tool##*/}"
done
for cmd in awk basename bash cat chmod cp cut dirname env flock grep head jq ls mkdir mktemp mv printf readlink rm sed shuf sleep sort tr uname wc which; do
    if bin_path=$(type -P "$cmd"); then
        ln -sf "$bin_path" "$case5/openrc-bin/$cmd"
    fi
done
if ! out=$(PATH="$case5/openrc-bin" bash "$case5/root/etc/sing-box/sh/sing-box.sh" status 2>&1); then
    fail "sing-box.sh status failed under OpenRC without caddy init.d (rc=$?): $out"
fi

setup_entry_fixture "add-explicit"
case6="$workdir/add-explicit"
if ! out=$(PATH="$case6/bin:$PATH" bash "$case6/root/etc/sing-box/sh/sing-box.sh" add r 20005 11111111-1111-1111-1111-111111111111 www.amazon.com 2>&1); then
    fail "sing-box.sh add reality with explicit args failed (rc=$?): $out"
fi
[[ -f $case6/root/etc/sing-box/conf/VLESS-REALITY-20005.json ]] || fail "VLESS-REALITY-20005.json was not created"

setup_entry_fixture "fix-caddy"
case7="$workdir/fix-caddy"
mkdir -p "$case7/root/etc/caddy/one-singbox"
cat >"$case7/bin/caddy" <<'FAKE_CADDY'
#!/usr/bin/env bash
printf 'v2.7.6\n'
FAKE_CADDY
cat >"$case7/bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
case $1 in
show)
    [[ $* == *LoadState* && $* == *caddy.service* ]] && { printf 'loaded\n'; exit 0; }
    printf '4321\n'
    ;;
is-active)
    [[ $2 == --quiet ]] && exit 0
    printf 'active\n'
    ;;
esac
exit 0
FAKE_SYSTEMCTL
chmod +x "$case7/bin/caddy" "$case7/bin/systemctl"
if ! out=$(PATH="$case7/bin:$PATH" bash "$case7/root/etc/sing-box/sh/sing-box.sh" fix-caddyfile 2>&1); then
    fail "sing-box.sh fix-caddyfile failed (rc=$?): $out"
fi
[[ -s $case7/root/etc/caddy/Caddyfile ]] || fail "fix-caddyfile did not create Caddyfile"

echo "PASS: tests-trailing-exit-codes"
