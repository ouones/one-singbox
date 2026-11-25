#!/usr/bin/env bash
set -o pipefail

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
    local with_caddy=${2:-0}
    local legacy_caddy=${3:-0}
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
printf '%s\n' "$*" >>"${TEST_CORE_LOG:?}"
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
printf '%s\n' "$*" >>"${TEST_SYS_LOG:?}"
case $1 in
show)
    if [[ $* == *LoadState* && $* == *caddy.service* ]]; then
        if [[ ${TEST_CADDY_LOADED:-0} == 1 ]]; then
            printf 'loaded\n'
        else
            printf 'not-found\n'
        fi
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
if [[ -n ${TEST_WGET_ARGS_LOG:-} ]]; then
    printf 'CALL\n' >>"$TEST_WGET_ARGS_LOG"
    for arg in "$@"; do
        printf 'ARG:%s\n' "$arg" >>"$TEST_WGET_ARGS_LOG"
    done
fi
if [[ $* == *cdn-cgi/trace* ]]; then
    printf 'ip=203.0.113.10\n'
elif [[ $* == *dns-query* ]]; then
    printf '{"Answer":[{"data":"203.0.113.10"}]}\n'
elif [[ $* == */releases/latest* ]]; then
    printf '{"tag_name":"v1.14.4"}\n'
else
    out=
    while (($#)); do
        if [[ $1 == -O ]]; then
            out=$2
            shift 2
        else
            shift
        fi
    done
    if [[ $out ]]; then
        printf 'downloaded\n' >"$out"
    fi
fi
exit 0
FAKE_WGET
    chmod +x "$case_dir/bin/wget"

    if [[ $with_caddy == 1 ]]; then
        mkdir -p "$root/etc/caddy"
        if [[ $legacy_caddy == 1 ]]; then
            mkdir -p "$root/etc/caddy/233boy"
        fi
        cat >"$root/etc/caddy/Caddyfile" <<'CADDYFILE'
{
  admin off
  http_port 80
  https_port 443
}
CADDYFILE
        cat >"$case_dir/bin/caddy" <<'FAKE_CADDY'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TEST_CADDY_LOG:?}"
printf 'v2.7.6\n'
FAKE_CADDY
        chmod +x "$case_dir/bin/caddy"
        cat >"$case_dir/bin/pgrep" <<'FAKE_PGREP'
#!/usr/bin/env bash
printf '12345\n'
FAKE_PGREP
        chmod +x "$case_dir/bin/pgrep"
    fi

    printf '%s\n' "$case_dir"
}

run_case_env() {
    local case_dir=$1
    local caddy_loaded=$2
    shift 2
    local root="$case_dir/root"
    local entry="$root/etc/sing-box/sh/sing-box.sh"
    : >"$case_dir/core.log"
    : >"$case_dir/sys.log"
    : >"$case_dir/caddy.log"
    : >"$case_dir/wget.log"
    TEST_CORE_LOG="$case_dir/core.log" \
        TEST_SYS_LOG="$case_dir/sys.log" \
        TEST_CADDY_LOG="$case_dir/caddy.log" \
        TEST_WGET_ARGS_LOG="$case_dir/wget.log" \
        TEST_CADDY_LOADED="$caddy_loaded" \
        PATH="$case_dir/bin:$PATH" \
        bash "$entry" "$@"
}

# 1. Cold-start probe optimization: help / ip / relay list / version / status / main
case_no_caddy=$(setup_entry_fixture no-caddy 0 0)
case_caddy=$(setup_entry_fixture with-caddy 1 0)

out=$(run_case_env "$case_caddy" 1 help 2>&1) || fail "entry help failed: $out"
[[ $out == *'Usage: sing-box'* ]] || fail "entry help missing usage: $out"
[[ ! -s $case_caddy/sys.log ]] || fail "entry help must not probe systemctl: $(<"$case_caddy/sys.log")"
[[ $(grep -c '^version$' "$case_caddy/core.log") -eq 0 ]] || fail "entry help must not query sing-box version: $(<"$case_caddy/core.log")"
[[ ! -e $case_caddy/root/etc/sing-box/bin/tls.cer && ! -e $case_caddy/root/etc/sing-box/log-limit-mb ]] \
    || fail "entry help must not create tls.cer or log-limit-mb"

out=$(run_case_env "$case_caddy" 1 ip 2>&1) || fail "entry ip failed: $out"
[[ $out == *'203.0.113.10'* ]] || fail "entry ip output unexpected: $out"
[[ ! -s $case_caddy/sys.log ]] || fail "entry ip must not probe systemctl: $(<"$case_caddy/sys.log")"
[[ $(grep -c '^version$' "$case_caddy/core.log") -eq 0 ]] || fail "entry ip must not query sing-box version: $(<"$case_caddy/core.log")"

out=$(run_case_env "$case_caddy" 1 relay list 2>&1) || fail "entry relay list failed: $out"
[[ $out == *'端口转发'* ]] || fail "entry relay list output unexpected: $out"
[[ ! -s $case_caddy/sys.log ]] || fail "entry relay list must not probe systemctl: $(<"$case_caddy/sys.log")"
[[ $(grep -c '^version$' "$case_caddy/core.log") -eq 0 ]] || fail "entry relay list must not query sing-box version: $(<"$case_caddy/core.log")"

out=$(run_case_env "$case_no_caddy" 0 version 2>&1) || fail "entry version (no caddy) failed: $out"
[[ $out == *'sing-box 1.14.4'* ]] || fail "entry version (no caddy) missing version: $out"
[[ $(grep -c '^version$' "$case_no_caddy/core.log") -eq 1 ]] || fail "entry version (no caddy) must query sing-box version exactly once: $(<"$case_no_caddy/core.log")"
[[ ! -s $case_no_caddy/sys.log ]] || fail "entry version (no caddy) must not call systemctl: $(<"$case_no_caddy/sys.log")"

out=$(run_case_env "$case_caddy" 1 version 2>&1) || fail "entry version (with caddy) failed: $out"
[[ $out == *'sing-box 1.14.4'* && $out == *'Caddy v2.7.6'* ]] || fail "entry version (with caddy) missing versions: $out"
[[ $(grep -c '^version$' "$case_caddy/core.log") -eq 1 ]] || fail "entry version (with caddy) must query sing-box version exactly once: $(<"$case_caddy/core.log")"
! grep -Fq 'list-units' "$case_caddy/sys.log" || fail "entry version must not run systemctl list-units: $(<"$case_caddy/sys.log")"
grep -Fq 'caddy.service' "$case_caddy/sys.log" || fail "entry version must use single-unit caddy.service probe: $(<"$case_caddy/sys.log")"

out=$(run_case_env "$case_no_caddy" 0 status 2>&1) || fail "entry status (no caddy) failed: $out"
[[ $out == *'sing-box 1.14.4'* && $out == *'运行中'* ]] || fail "entry status (no caddy) output unexpected: $out"
[[ $(grep -c '^version$' "$case_no_caddy/core.log") -eq 1 ]] || fail "entry status (no caddy) must query sing-box version exactly once: $(<"$case_no_caddy/core.log")"
! grep -Fq 'list-units' "$case_no_caddy/sys.log" || fail "entry status (no caddy) must not run systemctl list-units: $(<"$case_no_caddy/sys.log")"

out=$(run_case_env "$case_caddy" 1 status 2>&1) || fail "entry status failed: $out"
[[ $out == *'sing-box 1.14.4'* && $out == *'运行中'* && $out == *'Caddy v2.7.6'* ]] || fail "entry status output unexpected: $out"
[[ $(grep -c '^version$' "$case_caddy/core.log") -eq 1 ]] || fail "entry status must query sing-box version exactly once: $(<"$case_caddy/core.log")"
! grep -Fq 'list-units' "$case_caddy/sys.log" || fail "entry status must not run systemctl list-units: $(<"$case_caddy/sys.log")"

out=$(printf 'q\n' | run_case_env "$case_caddy" 1 2>&1) || fail "entry main menu failed: $out"
[[ $out == *'sing-box 内核：1.14.4'* ]] || fail "entry main menu missing core version: $out"
[[ $(grep -c '^version$' "$case_caddy/core.log") -eq 1 ]] || fail "entry main menu must query sing-box version exactly once: $(<"$case_caddy/core.log")"
! grep -Fq 'list-units' "$case_caddy/sys.log" || fail "entry main menu must not run systemctl list-units: $(<"$case_caddy/sys.log")"

# 2. Single source of truth: is_caddy_conf legacy 233boy & default one-singbox
case_legacy_caddy=$(setup_entry_fixture legacy-caddy 1 1)
out=$(run_case_env "$case_legacy_caddy" 1 add wss legacy.example.com 11111111-1111-1111-1111-111111111111 /ws 2>&1) \
    || fail "entry add wss with legacy 233boy caddy dir failed: $out"
[[ -s $case_legacy_caddy/root/etc/caddy/233boy/legacy.example.com.conf ]] \
    || fail "legacy 233boy caddy conf dir was overwritten by core.sh"
[[ ! -e $case_legacy_caddy/root/etc/caddy/conf.d/legacy.example.com.conf ]] \
    || fail "core.sh erroneously wrote to conf.d instead of 233boy"
grep -Fq 'ARG:--header=accept: application/dns-json' "$case_legacy_caddy/wget.log" \
    || fail "_wget split argument with spaces: $(<"$case_legacy_caddy/wget.log")"

case_modern_caddy=$(setup_entry_fixture modern-caddy 1 0)
out=$(run_case_env "$case_modern_caddy" 1 add wss modern.example.com 11111111-1111-1111-1111-111111111111 /ws 2>&1) \
    || fail "entry add wss with default one-singbox caddy dir failed: $out"
[[ -s $case_modern_caddy/root/etc/caddy/one-singbox/modern.example.com.conf ]] \
    || fail "default one-singbox caddy conf dir was overwritten by core.sh"
[[ ! -e $case_modern_caddy/root/etc/caddy/conf.d/modern.example.com.conf ]] \
    || fail "core.sh erroneously wrote to conf.d instead of one-singbox"

# 3. Single source of truth: err() honors is_dont_auto_exit via ddel & direct core.sh
case_auto_exit=$(setup_entry_fixture auto-exit 0 0)
cat >"$case_auto_exit/root/etc/sing-box/conf/keep-me.json" <<'JSON'
{"inbounds":[{"tag":"keep-me.json","type":"shadowsocks","listen":"::","listen_port":23001,"method":"aes-128-gcm","password":"p"}]}
JSON
out=$(run_case_env "$case_auto_exit" 0 ddel nonexistent.json keep-me.json 2>&1)
[[ ! -e $case_auto_exit/root/etc/sing-box/conf/keep-me.json ]] \
    || fail "ddel aborted on first missing node because core.sh overwrote err() is_dont_auto_exit handling: $out"
[[ $out == *'nonexistent.json'* ]] || fail "ddel did not report missing node error: $out"

# Direct source src/core.sh (before #123) honors is_dont_auto_exit and _wget quoting with spaces
REPO_ROOT="$repo_root" WORKDIR="$workdir" bash <<'DIRECT' || exit 1
set -o pipefail
fail() { echo "FAIL(direct): $*" >&2; exit 1; }
case_dir="$WORKDIR/direct"
mkdir -p "$case_dir/bin" "$case_dir/space dir"
export WGET_LOG="$case_dir/wget.log"
cat >"$case_dir/bin/wget" <<'FAKE_WGET'
#!/usr/bin/env bash
for arg in "$@"; do
    printf 'ARG:%s\n' "$arg" >>"$WGET_LOG"
done
FAKE_WGET
chmod +x "$case_dir/bin/wget"
PATH="$case_dir/bin:$PATH"
source "$REPO_ROOT/src/core.sh"
is_dont_auto_exit=1
err_out=$(err "non fatal err" 2>&1) || fail "err() exited or failed under is_dont_auto_exit=1"
[[ $err_out == *'non fatal err'* ]] || fail "err() did not print message: $err_out"
_wget -O "$case_dir/space dir/out file.txt" --header="X-Test: one two" "https://example.invalid/a"
grep -Fxq "ARG:$case_dir/space dir/out file.txt" "$WGET_LOG" || fail "_wget split filename with spaces: $(<"$WGET_LOG")"
grep -Fxq 'ARG:--header=X-Test: one two' "$WGET_LOG" || fail "_wget split header with spaces: $(<"$WGET_LOG")"
DIRECT

echo "PASS: tests-init-coldstart"
