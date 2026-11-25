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

# 1. Verify cohesive submodule files exist and core.sh was meaningfully reduced.
for mod in meta uri route node relay; do
    [[ -f "$repo_root/src/${mod}.sh" ]] || fail "missing split module: src/${mod}.sh"
done

core_lines=$(wc -l <"$repo_root/src/core.sh")
((core_lines < 4000)) || fail "src/core.sh is still too large ($core_lines lines)"

# 2. Direct source of src/core.sh loads all submodules cleanly with zero output and supports main entrypoints.
out=$(
    REPO_ROOT="$repo_root" WORKDIR="$workdir" bash <<'CASE' 2>&1
set -o pipefail
source "$REPO_ROOT/src/core.sh" || exit 11
declare -F main >/dev/null || { echo "missing main" >&2; exit 12; }
is_core_dir="$WORKDIR/direct-core"
is_conf_dir="$WORKDIR/direct-conf"
is_core_ver=1.14.4
mkdir -p "$is_core_dir" "$is_conf_dir/.quan-meta"
main help >/dev/null || exit 13
main relay list >/dev/null || exit 14
main block-cn status >/dev/null || exit 15
CASE
)
rc=$?
[[ $rc == 0 ]] || fail "direct source src/core.sh failed (rc=$rc): $out"
[[ -z $out ]] || fail "direct source src/core.sh produced unexpected output: $out"

# 3. Isolated sing-box.sh entry exercises lightweight fast-path and heavy subcommands end-to-end.
root="$workdir/root"
sh_dir="$root/etc/sing-box/sh"
entry="$sh_dir/sing-box.sh"
mkdir -p "$sh_dir/src" "$root/etc/sing-box/bin" "$root/etc/sing-box/conf/.quan-meta" \
    "$root/usr/local/bin" "$root/var/log/sing-box" "$workdir/bin"
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
generate)
    if [[ $2 == reality-keypair ]]; then
        printf 'Private key: priv\nPublic key: pub\n'
    elif [[ $2 == tls-keypair ]]; then
        printf '-----BEGIN PRIVATE KEY-----\nfake\n-----END PRIVATE KEY-----\n'
        printf '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n'
    fi
    ;;
check) exit 0 ;;
esac
exit 0
FAKE_CORE
cat >"$workdir/bin/apt-get" <<'FAKE_APT'
#!/usr/bin/env bash
exit 0
FAKE_APT
cat >"$workdir/bin/systemctl" <<'FAKE_SYS'
#!/usr/bin/env bash
[[ $1 == is-active ]] && printf 'active\n'
exit 0
FAKE_SYS
cat >"$workdir/bin/ss" <<'FAKE_SS'
#!/usr/bin/env bash
exit 0
FAKE_SS
cat >"$workdir/bin/wget" <<'FAKE_WGET'
#!/usr/bin/env bash
[[ $* == *cdn-cgi/trace* ]] && printf 'ip=203.0.113.10\n'
exit 0
FAKE_WGET
chmod +x "$root/etc/sing-box/bin/sing-box" "$workdir/bin/apt-get" "$workdir/bin/systemctl" "$workdir/bin/ss" "$workdir/bin/wget"
printf '{"log":{"level":"info"},"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$root/etc/sing-box/config.json"

out=$(PATH="$workdir/bin:$PATH" bash "$entry" version 2>&1) || fail "entry version failed: $out"
[[ $out == *'sing-box 1.14.4'* ]] || fail "entry version output unexpected: $out"

out=$(PATH="$workdir/bin:$PATH" bash "$entry" help 2>&1) || fail "entry help failed: $out"
[[ $out == *'Usage: sing-box'* ]] || fail "entry help output unexpected: $out"

out=$(PATH="$workdir/bin:$PATH" bash "$entry" status 2>&1) || fail "entry status failed: $out"
[[ $out == *'sing-box 1.14.4'* ]] || fail "entry status output unexpected: $out"

out=$(PATH="$workdir/bin:$PATH" bash "$entry" block-cn status 2>&1) || fail "entry block-cn status failed: $out"
[[ $out == *'屏蔽回国流量: 未启用'* ]] || fail "entry block-cn status unexpected: $out"

out=$(PATH="$workdir/bin:$PATH" bash "$entry" relay list 2>&1) || fail "entry relay list failed: $out"
[[ $out == *'当前未配置任何端口转发'* ]] || fail "entry relay list unexpected: $out"

out=$(PATH="$workdir/bin:$PATH" bash "$entry" add ss 30011 secret aes-128-gcm 2>&1) || fail "entry add ss failed: $out"
[[ -f $root/etc/sing-box/conf/Shadowsocks-30011.json ]] || fail "entry add ss did not create node config"

# 4. Local variable scope isolation: main subcommand calls do not clobber caller scratch globals.
out=$(
    REPO_ROOT="$repo_root" WORKDIR="$workdir" bash <<'CASE' 2>&1
set -o pipefail
source "$REPO_ROOT/src/core.sh" || exit 31
is_core_dir="$WORKDIR/scope/core"
is_conf_dir="$WORKDIR/scope/conf"
mkdir -p "$is_core_dir/bin" "$is_conf_dir/.quan-meta"
is_core_bin="$WORKDIR/scope/fake-core"
cat >"$is_core_bin" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == version ]]; then
    printf 'sing-box version 1.14.0\nTags: with_grpc\n'
elif [[ $1 == generate && $2 == reality-keypair ]]; then
    printf 'Private key: priv123\nPublic key: pub123\n'
fi
EOF
chmod +x "$is_core_bin"
cat >"$is_conf_dir/ss-10001.json" <<'EOF'
{"inbounds":[{"tag":"ss-10001.json","type":"shadowsocks","listen":"::","listen_port":10001,"method":"aes-128-gcm","password":"secret"}]}
EOF
cat >"$is_conf_dir/.quan-meta/ss-10001.json.meta.json" <<'EOF'
{"outbound_mode":"V4优先","node_name":"demo"}
EOF
export ip=203.0.113.10 is_dont_get_ip=1
node_port_used() { return 1; }

is_count=sentinel_count
is_tmp_pbk=sentinel_pbk
tag=sentinel_tag
i=sentinel_i
a=sentinel_a
tt=sentinel_tt
is_node_name=sentinel_name
is_dont_show_info=

port=10001
is_new_protocol=Shadowsocks
main get-port >/dev/null || exit 32
[[ $tmp_port =~ ^[0-9]+$ ]] || { echo "main get-port failed" >&2; exit 32; }
[[ $is_count == sentinel_count ]] || { echo "main get-port leaked is_count=$is_count" >&2; exit 33; }

main gen reality 10002 11111111-1111-4111-8111-111111111111 www.amazon.com >/dev/null || exit 34
[[ $is_private_key == priv123 && $is_public_key == pub123 ]] || { echo "main gen reality failed" >&2; exit 34; }
[[ $is_tmp_pbk == sentinel_pbk ]] || { echo "main gen reality leaked is_tmp_pbk" >&2; exit 35; }

main no-auto-tls >/dev/null 2>&1 || true
is_no_auto_tls=1
main gen vh2 example.com 11111111-1111-4111-8111-111111111111 /h2 >/dev/null || exit 36
is_no_auto_tls=
[[ $tag == sentinel_tag ]] || { echo "main gen vh2 leaked tag=$tag" >&2; exit 37; }

main url ss-10001.json >/dev/null || exit 38
[[ $is_url == ss://* ]] || { echo "main url failed" >&2; exit 38; }
[[ $i == sentinel_i && $a == sentinel_a && $tt == sentinel_tt && $is_node_name == sentinel_name ]] || {
    echo "main url leaked loop/display vars: i=$i a=$a tt=$tt is_node_name=$is_node_name" >&2
    exit 39
}
[[ -z $is_dont_show_info ]] || { echo "main url leaked is_dont_show_info=$is_dont_show_info" >&2; exit 40; }
CASE
)
rc=$?
[[ $rc == 0 ]] || fail "local scope isolation check failed (rc=$rc): $out"

echo "PASS: tests-module-split"
