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

fake_bin="$workdir/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/sing-box" <<'FAKE_CORE'
#!/usr/bin/env bash
if [[ $1 == version ]]; then
    printf 'sing-box version %s\n\nEnvironment: go1.26.7 linux/amd64\nTags: with_gvisor,with_quic,with_utls\n' \
        "${FAKE_CORE_VERSION:-1.14.0}"
    exit 0
fi
if [[ $1 == check ]]; then
    if [[ ${TEST_REJECT_CHECK:-0} == 1 ]]; then
        printf 'FATAL[0000] simulated check failure\n' >&2
        exit 1
    fi
    config=
    conf_dir=
    while (($# > 0)); do
        case $1 in
        -c) config=$2; shift 2 ;;
        -C) conf_dir=$2; shift 2 ;;
        *) shift ;;
        esac
    done
    [[ $config && -f $config ]] || exit 2
    [[ ! $conf_dir || -d $conf_dir ]] || exit 2
    jq -e 'type == "object"' "$config" >/dev/null 2>&1 || exit 4
    exit 0
fi
FAKE_CORE
chmod +x "$fake_bin/sing-box"

cat >"$fake_bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
[[ -n ${SERVICE_LOG:-} ]] && printf '%s\n' "$*" >>"$SERVICE_LOG"
case $1 in
is-active)
    echo active
    ;;
esac
exit 0
FAKE_SYSTEMCTL
chmod +x "$fake_bin/systemctl"

cat >"$fake_bin/wget" <<'FAKE_WGET'
#!/usr/bin/env bash
mode=4
for arg in "$@"; do
    case $arg in
    -4) mode=4 ;;
    -6) mode=6 ;;
    esac
done
if [[ $mode == 4 ]]; then
    if [[ ${FAKE_WGET4_FAIL:-0} == 1 ]]; then
        exit 1
    fi
    printf '%b' "${FAKE_WGET4_BODY:-}"
else
    if [[ ${FAKE_WGET6_FAIL:-0} == 1 ]]; then
        exit 1
    fi
    printf '%b' "${FAKE_WGET6_BODY:-}"
fi
FAKE_WGET
chmod +x "$fake_bin/wget"

# Wrapper jq that can fail on demand via FAKE_JQ_FAIL=1
real_jq=$(command -v jq) || fail "jq is required for tests"
cat >"$fake_bin/jq" <<FAKE_JQ
#!/usr/bin/env bash
if [[ \${FAKE_JQ_FAIL:-0} == 1 ]]; then
    exit 2
fi
exec "$real_jq" "\$@"
FAKE_JQ
chmod +x "$fake_bin/jq"

# Helper to verify shared_config_lock is released using an independent process
assert_lock_free() {
    local lock_file=$1/\.frontend-state/lock
    local desc=$2
    if [[ -e $lock_file ]]; then
        flock -n "$lock_file" true || fail "shared_config_lock leaked ($desc)"
    fi
}

# 1. High-level CLI tests for `main log ...`
run_log_cases() {
    REPO_ROOT="$repo_root" FAKE_BIN="$fake_bin" REAL_JQ="$real_jq" bash <<'CASE'
set -o pipefail
fail() { echo "FAIL(log): $*" >&2; exit 1; }
assert_lock_free() {
    local lock_file=$1/.frontend-state/lock
    local desc=$2
    if [[ -e $lock_file ]]; then
        flock -n "$lock_file" true || fail "shared_config_lock leaked ($desc)"
    fi
}

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
export PATH="$FAKE_BIN:$PATH"
export SERVICE_LOG="$case_dir/service.log"
: >"$SERVICE_LOG"

source "$REPO_ROOT/src/core.sh"
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_log_dir="$case_dir/log"
is_sh_dir="$REPO_ROOT"
is_config_json="$case_dir/core/config.json"
is_core_bin="$FAKE_BIN/sing-box"
is_core_ver=1.14.0
is_systemd=1
is_dont_get_ip=1
mkdir -p "$is_core_dir" "$is_conf_dir/.quan-meta" "$is_log_dir"

# 1a. Normal `main log info` uses $is_log_dir and preserves existing config
printf '%s\n' '{"log":{"disabled":true},"outbounds":[{"tag":"direct","type":"direct"}]}' >"$is_config_json"
main log info >/dev/null || fail "main log info should succeed"
wait
"$REAL_JQ" -e --arg out "$is_log_dir/access.log" \
    '.log.output == $out and .log.level == "info" and .log.timestamp == true and .outbounds[0].tag == "direct"' \
    "$is_config_json" >/dev/null || fail "main log info did not update config properly: $(cat "$is_config_json")"
assert_lock_free "$is_core_dir" "after main log info"
shopt -s nullglob
leftover=("$is_config_json".log.*)
shopt -u nullglob
[[ ${#leftover[@]} -eq 0 ]] || fail "leftover log temp files after main log info: ${leftover[*]}"

# 1b. Normal `main log none` deletes logs and disables log
printf 'old-log\n' >"$is_log_dir/access.log"
printf 'old-arch\n' >"$is_log_dir/access.log.1"
main log none >/dev/null || fail "main log none should succeed"
wait
"$REAL_JQ" -e '.log == {"disabled":true} and .outbounds[0].tag == "direct"' "$is_config_json" >/dev/null \
    || fail "main log none did not disable log cleanly: $(cat "$is_config_json")"
[[ ! -e $is_log_dir/access.log && ! -e $is_log_dir/access.log.1 ]] || fail "main log none must delete log files"
assert_lock_free "$is_core_dir" "after main log none"

# 1c. Failure during JSON conversion (`jq` fails) must NOT truncate $is_config_json or leak lock
err() { echo "$*" >&2; [[ $is_dont_auto_exit ]] && return; exit 1; }
is_dont_auto_exit=1
printf '%s\n' '{"log":{"level":"info","timestamp":true},"keep":"yes"}' >"$is_config_json"
cp "$is_config_json" "$case_dir/config.before"
: >"$SERVICE_LOG"
if FAKE_JQ_FAIL=1 main log warn >/dev/null 2>&1; then
    fail "main log warn must fail when jq fails"
fi
cmp -s "$case_dir/config.before" "$is_config_json" || fail "jq failure corrupted or emptied config.json: $(cat "$is_config_json")"
assert_lock_free "$is_core_dir" "after jq failure in main log"
shopt -s nullglob
leftover=("$is_config_json".log.*)
shopt -u nullglob
[[ ${#leftover[@]} -eq 0 ]] || fail "leftover log temp files after jq failure: ${leftover[*]}"
[[ ! -s $SERVICE_LOG ]] || fail "failed main log must not restart service"

# 1d. Empty config.json where jq exits 0 with empty stdout must NOT overwrite config.json
: >"$is_config_json"
if main log error >/dev/null 2>&1; then
    fail "main log error must fail on empty config.json"
fi
[[ ! -s $is_config_json ]] || fail "empty config should remain untouched"
assert_lock_free "$is_core_dir" "after empty config in main log"
CASE
}

# 2. High-level CLI tests for `main dns ...`
run_dns_cases() {
    REPO_ROOT="$repo_root" FAKE_BIN="$fake_bin" REAL_JQ="$real_jq" bash <<'CASE'
set -o pipefail
fail() { echo "FAIL(dns): $*" >&2; exit 1; }
assert_lock_free() {
    local lock_file=$1/.frontend-state/lock
    local desc=$2
    if [[ -e $lock_file ]]; then
        flock -n "$lock_file" true || fail "shared_config_lock leaked ($desc)"
    fi
}

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
export PATH="$FAKE_BIN:$PATH"
export SERVICE_LOG="$case_dir/service.log"
: >"$SERVICE_LOG"

source "$REPO_ROOT/src/core.sh"
err() { echo "$*" >&2; [[ $is_dont_auto_exit ]] && return; exit 1; }
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_log_dir="$case_dir/log"
is_sh_dir="$REPO_ROOT"
is_config_json="$case_dir/core/config.json"
is_core_bin="$FAKE_BIN/sing-box"
is_systemd=1
is_dont_get_ip=1
mkdir -p "$is_core_dir" "$is_conf_dir/.quan-meta" "$is_log_dir"

base_cfg='{"dns":{},"route":{"rules":[]},"outbounds":[{"tag":"direct","type":"direct"}]}'

# 2a. Parameterized jq with quotes, spaces, and special characters (new DNS schema >= 1.12)
is_core_ver=1.14.0
printf '%s\n' "$base_cfg" >"$is_config_json"
tricky_udp='1.1.1.1",evil:"injected'
main dns set "$tricky_udp" >/dev/null || fail "main dns set with tricky UDP string failed"
wait
"$REAL_JQ" -e --arg srv "$tricky_udp" \
    '.dns.servers[0].type == "udp" and .dns.servers[0].server == $srv and (.dns.servers[0] | has("evil") | not)' \
    "$is_config_json" >/dev/null || fail "DNS JSON broken or injected (new schema): $(cat "$is_config_json")"
assert_lock_free "$is_core_dir" "after tricky UDP dns set"

# With spaces in URL path and quotes
printf '%s\n' "$base_cfg" >"$is_config_json"
tricky_url='https://dns.example.test/query?x="1"&y=2 3'
main dns set "$tricky_url" >/dev/null || fail "main dns set with tricky URL failed"
wait
"$REAL_JQ" -e '.dns.servers[0].type == "https" and .dns.servers[0].server == "dns.example.test"' \
    "$is_config_json" >/dev/null || fail "DNS URL parsing failed with spaces/quotes: $(cat "$is_config_json")"

# Legacy DNS schema (< 1.12)
is_core_ver=1.10.0
printf '%s\n' "$base_cfg" >"$is_config_json"
tricky_legacy='8.8.8.8",injected:"true'
main dns set "$tricky_legacy" >/dev/null || fail "main dns set with tricky string failed (legacy schema)"
wait
"$REAL_JQ" -e --arg addr "$tricky_legacy" \
    '.dns.servers[0].address == $addr and (.dns.servers[0] | has("injected") | not)' \
    "$is_config_json" >/dev/null || fail "DNS JSON broken or injected (legacy schema): $(cat "$is_config_json")"

# 2b. Lock release & temp cleanup on ALL failure branches with is_dont_auto_exit=1
is_core_ver=1.14.0
is_dont_auto_exit=1

# Branch i: invalid DNS scheme in dns_set_server
printf '%s\n' "$base_cfg" >"$is_config_json"
cp "$is_config_json" "$case_dir/config.before"
if main dns set 'ftp://bad.example/dns-query' >/dev/null 2>&1; then
    fail "invalid DNS scheme must fail"
fi
cmp -s "$case_dir/config.before" "$is_config_json" || fail "invalid scheme modified config.json"
assert_lock_free "$is_core_dir" "after invalid DNS scheme"
shopt -s nullglob
leftover=("$is_config_json".dns.*)
shopt -u nullglob
[[ ${#leftover[@]} -eq 0 ]] || fail "leftover dns temp files after invalid scheme: ${leftover[*]}"

# Branch ii: jq failure during candidate config generation
if FAKE_JQ_FAIL=1 main dns set 1.1.1.1 >/dev/null 2>&1; then
    fail "main dns set must fail when jq fails"
fi
cmp -s "$case_dir/config.before" "$is_config_json" || fail "jq failure modified config.json"
assert_lock_free "$is_core_dir" "after jq failure in main dns"
shopt -s nullglob
leftover=("$is_config_json".dns.*)
shopt -u nullglob
[[ ${#leftover[@]} -eq 0 ]] || fail "leftover dns temp files after jq failure: ${leftover[*]}"

# Branch iii: sync_runtime_node_outbound_modes_unlocked failure (via sing-box check failure)
if TEST_REJECT_CHECK=1 main dns set 1.1.1.1 >/dev/null 2>&1; then
    fail "main dns set must fail when sync/check fails"
fi
cmp -s "$case_dir/config.before" "$is_config_json" || fail "sync failure modified config.json"
assert_lock_free "$is_core_dir" "after sync failure in main dns"
shopt -s nullglob
leftover=("$is_config_json".dns.* "$is_config_json".tmp.*)
shopt -u nullglob
[[ ${#leftover[@]} -eq 0 ]] || fail "leftover temp files after sync failure: ${leftover[*]}"

# Branch iv: mktemp failure
mktemp() { return 1; }
if main dns set 1.1.1.1 >/dev/null 2>&1; then
    fail "main dns set must fail when mktemp fails"
fi
unset -f mktemp
assert_lock_free "$is_core_dir" "after mktemp failure in main dns"

# Verify subsequent lock-requiring operation succeeds immediately
is_dont_auto_exit=
main dns set 8.8.8.8 >/dev/null || fail "subsequent main dns set failed after earlier failures"
wait
"$REAL_JQ" -e '.dns.servers[0].server == "8.8.8.8"' "$is_config_json" >/dev/null \
    || fail "subsequent main dns set did not update config"
CASE
}

# 3. High-level CLI tests for public IP extraction (`main ip` and `install.sh` `get_ip`)
run_ip_cases() {
    REPO_ROOT="$repo_root" FAKE_BIN="$fake_bin" bash <<'CASE'
set -o pipefail
fail() { echo "FAIL(ip): $*" >&2; exit 1; }

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
export PATH="$FAKE_BIN:$PATH"

# 3a. Valid IPv4 via `main ip`
out=$(
    unset ip is_dont_get_ip EVIL_INJECTED
    export FAKE_WGET4_BODY=$'fl=1\nip=203.0.113.10\nts=1\n'
    source "$REPO_ROOT/src/core.sh"
    is_core_dir="$case_dir/core"
    mkdir -p "$is_core_dir"
    main ip
) || fail "main ip should succeed on valid IPv4"
[[ $out == *'203.0.113.10'* ]] || fail "main ip unexpected IPv4 output: $out"

# 3b. IPv4 fails, valid IPv6 via `main ip`
out=$(
    unset ip is_dont_get_ip
    export FAKE_WGET4_FAIL=1
    export FAKE_WGET6_BODY=$'fl=1\nip=2001:db8::42\n'
    source "$REPO_ROOT/src/core.sh"
    is_core_dir="$case_dir/core"
    main ip
) || fail "main ip should succeed on valid IPv6 fallback"
[[ $out == *'2001:db8::42'* ]] || fail "main ip unexpected IPv6 output: $out"

# 3c. Untrusted response with extra env line must NOT export extra env vars
(
    unset ip is_dont_get_ip EVIL_INJECTED
    export FAKE_WGET4_BODY=$'EVIL_INJECTED=pwned\nip=203.0.113.10\n'
    source "$REPO_ROOT/src/core.sh"
    is_core_dir="$case_dir/core"
    main ip >/dev/null || exit 1
    [[ ${EVIL_INJECTED:-} == "" ]] || exit 2
    [[ $ip == "203.0.113.10" ]] || exit 3
) || fail "main ip leaked or failed on extra env line (rc=$?)"

# 3d. Malicious ip= values (spaces, command substitution, extra =, invalid octets) must be rejected
marker="$case_dir/pwned"
for bad_body in \
    $'ip=203.0.113.10 EVIL_INJECTED=pwned\n' \
    "ip=1.2.3.4\$(touch $marker)"$'\n' \
    "ip=1.2.3.4;touch $marker"$'\n' \
    $'ip=203.0.113.10=extra\n' \
    $'ip=999.999.999.999\n' \
    $'ip=not-an-ip\n'
do
    if (
        unset ip is_dont_get_ip EVIL_INJECTED
        export FAKE_WGET4_BODY="$bad_body"
        export FAKE_WGET6_FAIL=1
        source "$REPO_ROOT/src/core.sh"
        is_core_dir="$case_dir/core"
        main ip >/dev/null 2>&1
    ); then
        fail "main ip must reject malformed response: $bad_body"
    fi
    [[ ! -e $marker ]] || fail "command injection executed for: $bad_body"
done

# 3e. install.sh get_ip() validation & no env injection
(
    unset ip EVIL_INJECTED
    export FAKE_WGET4_BODY=$'EVIL_INJECTED=pwned\nip=198.51.100.7\n'
    source "$REPO_ROOT/install.sh"
    get_ip
    [[ ${EVIL_INJECTED:-} == "" ]] || exit 2
    [[ ${ip:-} == "198.51.100.7" ]] || exit 3
) || fail "install.sh get_ip failed valid IPv4 or leaked EVIL_INJECTED"

(
    unset ip EVIL_INJECTED
    export FAKE_WGET4_BODY=$'ip=198.51.100.7 EVIL_INJECTED=pwned\n'
    export FAKE_WGET6_BODY=$'ip=2001:db8::77\n'
    source "$REPO_ROOT/install.sh"
    get_ip
    [[ ${EVIL_INJECTED:-} == "" ]] || exit 2
    [[ ${ip:-} == "2001:db8::77" ]] || exit 3
) || fail "install.sh get_ip failed IPv6 fallback or leaked EVIL_INJECTED"

if (
    unset ip
    export FAKE_WGET4_BODY="ip=1.2.3.4\$(touch $marker)"$'\n'
    export FAKE_WGET6_BODY=$'ip=not-an-ip\n'
    source "$REPO_ROOT/install.sh"
    get_ip
    [[ -n ${ip:-} ]]
); then
    fail "install.sh get_ip must leave ip unset on invalid responses"
fi
[[ ! -e $marker ]] || fail "install.sh get_ip executed command injection"
CASE
}

run_log_cases || exit 1
run_dns_cases || exit 1
run_ip_cases || exit 1
echo "PASS: tests-log-dns-security.sh"
