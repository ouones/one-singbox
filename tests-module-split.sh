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

# 2. Direct source of src/core.sh loads all submodules cleanly with zero output.
out=$(
    REPO_ROOT="$repo_root" bash <<'CASE' 2>&1
set -o pipefail
source "$REPO_ROOT/src/core.sh" || exit 11
for fn in meta_get parse_vless_uri render_runtime_node_outbound_modes validate_snell relay_note main; do
    declare -F "$fn" >/dev/null || { echo "missing fn: $fn" >&2; exit 12; }
done
CASE
)
rc=$?
[[ $rc == 0 ]] || fail "direct source src/core.sh failed (rc=$rc): $out"
[[ -z $out ]] || fail "direct source src/core.sh produced unexpected output: $out"

# 3. Deferred loading works for lightweight CLI commands and loads full modules for heavy commands.
out=$(
    REPO_ROOT="$repo_root" bash <<'CASE' 2>&1
set -o pipefail
is_core_defer_modules=1 source "$REPO_ROOT/src/core.sh" || exit 21
if declare -F parse_vless_uri >/dev/null 2>&1; then
    echo "parse_vless_uri should be deferred under is_core_defer_modules=1" >&2
    exit 22
fi
is_core_dir=/tmp/nonexistent-sb-root
is_core_ver=1.14.4
main version >/dev/null || exit 23
if declare -F parse_vless_uri >/dev/null 2>&1; then
    echo "main version unexpectedly loaded heavy uri module" >&2
    exit 24
fi
core_load_modules || exit 25
declare -F parse_vless_uri >/dev/null || exit 26
declare -F render_runtime_node_outbound_modes >/dev/null || exit 27
CASE
)
rc=$?
[[ $rc == 0 ]] || fail "deferred module loading check failed (rc=$rc): $out"

# 4. Isolated sing-box.sh entry exercises lightweight fast-path and heavy subcommands end-to-end.
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
chmod +x "$root/etc/sing-box/bin/sing-box" "$workdir/bin/apt-get" "$workdir/bin/systemctl"
printf '{"log":{"level":"info"},"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$root/etc/sing-box/config.json"

out=$(PATH="$workdir/bin:$PATH" bash "$entry" version 2>&1) || fail "entry version failed: $out"
[[ $out == *'sing-box 1.14.4'* ]] || fail "entry version output unexpected: $out"

out=$(PATH="$workdir/bin:$PATH" bash "$entry" help 2>&1) || fail "entry help failed: $out"
[[ $out == *'Usage: sing-box'* ]] || fail "entry help output unexpected: $out"

out=$(PATH="$workdir/bin:$PATH" bash "$entry" block-cn status 2>&1) || fail "entry block-cn status failed: $out"
[[ $out == *'屏蔽回国流量: 未启用'* ]] || fail "entry block-cn status unexpected: $out"

out=$(PATH="$workdir/bin:$PATH" bash "$entry" relay list 2>&1) || fail "entry relay list failed: $out"
[[ $out == *'当前未配置任何端口转发'* ]] || fail "entry relay list unexpected: $out"

# 5. Local variable scope isolation: helper calls do not clobber caller scratch globals.
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
get_port
[[ $tmp_port =~ ^[0-9]+$ ]] || { echo "get_port failed" >&2; exit 32; }
[[ $is_count == sentinel_count ]] || { echo "get_port leaked is_count=$is_count" >&2; exit 33; }

get_pbk
[[ $is_private_key == priv123 && $is_public_key == pub123 ]] || { echo "get_pbk failed" >&2; exit 34; }
[[ $is_tmp_pbk == sentinel_pbk ]] || { echo "get_pbk leaked is_tmp_pbk" >&2; exit 35; }

vless_grpc_default_authority "example.com" 443 tls "example.com"
[[ $vless_grpc_default_authority_value == example.com ]] || { echo "vless_grpc_default_authority failed" >&2; exit 36; }
[[ $tag == sentinel_tag ]] || { echo "vless_grpc_default_authority leaked tag=$tag" >&2; exit 37; }

url_qr url ss-10001.json >/dev/null
[[ $is_url == ss://* ]] || { echo "url_qr failed" >&2; exit 38; }
[[ $i == sentinel_i && $a == sentinel_a && $tt == sentinel_tt && $is_node_name == sentinel_name ]] || {
    echo "info leaked loop/display vars: i=$i a=$a tt=$tt is_node_name=$is_node_name" >&2
    exit 39
}
[[ -z $is_dont_show_info ]] || { echo "url_qr leaked is_dont_show_info=$is_dont_show_info" >&2; exit 40; }
CASE
)
rc=$?
[[ $rc == 0 ]] || fail "local scope isolation check failed (rc=$rc): $out"

echo "PASS: tests-module-split"
