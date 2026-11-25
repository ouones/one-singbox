#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

if [[ $EUID == 0 ]]; then
    echo "SKIP: tests-root-guard.sh requires non-root execution for non-root checks"
    exit 0
fi

# 1. Side-effect-free loading of src/core.sh, src/init.sh, and install.sh as non-root.
out=$(
    REPO_ROOT="$repo_root" bash <<'CASE' 2>&1
set -o pipefail
source "$REPO_ROOT/src/core.sh" || exit 11
declare -F main >/dev/null || exit 12
declare -F add >/dev/null || exit 13
declare -F change >/dev/null || exit 14
CASE
)
rc=$?
[[ $rc == 0 ]] || fail "sourcing src/core.sh as non-root failed (rc=$rc): $out"
[[ -z $out ]] || fail "sourcing src/core.sh produced unexpected output: $out"

out=$(
    REPO_ROOT="$repo_root" bash <<'CASE' 2>&1
set -o pipefail
is_init_defs_only=1 source "$REPO_ROOT/src/init.sh" || exit 21
declare -F init_entry >/dev/null || exit 22
declare -F service_status_read >/dev/null || exit 23
CASE
)
rc=$?
[[ $rc == 0 ]] || fail "sourcing src/init.sh with is_init_defs_only=1 failed (rc=$rc): $out"
[[ -z $out ]] || fail "sourcing src/init.sh with is_init_defs_only=1 produced unexpected output: $out"

out=$(
    REPO_ROOT="$repo_root" bash <<'CASE' 2>&1
set -o pipefail
source "$REPO_ROOT/install.sh" || exit 31
_wget() { printf 'ip=203.0.113.42\n'; }
declare -F get_ip >/dev/null || exit 32
declare -F main >/dev/null || exit 33
get_ip || exit 34
[[ ${ip:-} == 203.0.113.42 ]] || exit 35
CASE
)
rc=$?
[[ $rc == 0 ]] || fail "sourcing install.sh as non-root failed (rc=$rc): $out"
[[ -z $out ]] || fail "sourcing install.sh produced unexpected output: $out"

# 2. Direct non-root execution of sing-box.sh against default system root must refuse.
entry_root="$workdir/system-entry"
mkdir -p "$entry_root/sh/src" "$entry_root/bin"
cp -R "$repo_root/src/." "$entry_root/sh/src/"
cp "$repo_root/sing-box.sh" "$entry_root/sh/sing-box.sh"
sed -i "s|^\. /etc/sing-box/sh/src/init.sh$|. $entry_root/sh/src/init.sh|" "$entry_root/sh/sing-box.sh"
cat >"$entry_root/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$entry_root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'CALLED:%s\n' "$*" >>"${TEST_SYS_LOG:?}"
exit 0
EOF
chmod +x "$entry_root/sh/sing-box.sh" "$entry_root/bin/apt-get" "$entry_root/bin/systemctl"

for subcmd in "" "status" "add" "help"; do
    : >"$entry_root/sys.log"
    if [[ -n $subcmd ]]; then
        out=$(TEST_SYS_LOG="$entry_root/sys.log" PATH="$entry_root/bin:$PATH" bash "$entry_root/sh/sing-box.sh" "$subcmd" 2>&1)
        rc=$?
    else
        out=$(TEST_SYS_LOG="$entry_root/sys.log" PATH="$entry_root/bin:$PATH" bash "$entry_root/sh/sing-box.sh" </dev/null 2>&1)
        rc=$?
    fi
    [[ $rc != 0 ]] || fail "direct non-root sing-box.sh '$subcmd' unexpectedly succeeded: $out"
    [[ $out == *'请以 root 用户重新运行此脚本'* ]] || fail "direct non-root sing-box.sh '$subcmd' missing root error: $out"
    [[ ! -s $entry_root/sys.log ]] || fail "direct non-root sing-box.sh '$subcmd' ran systemctl before root guard: $(<"$entry_root/sys.log")"
done

# 3. Direct main() invocation against default system root as non-root must refuse (even with is_dont_auto_exit=1).
out=$(
    REPO_ROOT="$repo_root" bash <<'CASE' 2>&1
source "$REPO_ROOT/src/core.sh" || exit 99
is_dont_auto_exit=1
main status
CASE
)
rc=$?
[[ $rc != 0 && $rc != 99 ]] || fail "direct non-root main status against system root succeeded (rc=$rc): $out"
[[ $out == *'请以 root 用户重新运行此脚本'* ]] || fail "direct non-root main status missing root error: $out"

# 4. Direct non-root execution of install.sh against default system root must refuse.
out=$(PATH="$entry_root/bin:$PATH" bash "$repo_root/install.sh" </dev/null 2>&1)
rc=$?
[[ $rc != 0 ]] || fail "direct non-root install.sh unexpectedly succeeded: $out"
[[ $out == *'ROOT用户'* ]] || fail "direct non-root install.sh missing root error: $out"

# 5. Isolated temp-root sing-box.sh execution works as non-root without stripping EUID checks.
iso_root="$workdir/isolated"
mkdir -p "$iso_root/etc/sing-box/sh/src" "$iso_root/etc/sing-box/bin" "$iso_root/etc/sing-box/conf" \
    "$iso_root/var/log/sing-box" "$iso_root/usr/local/bin" "$iso_root/bin"
cp -R "$repo_root/src/." "$iso_root/etc/sing-box/sh/src/"
cp "$repo_root/sing-box.sh" "$iso_root/etc/sing-box/sh/sing-box.sh"
sed -i "s|^\. /etc/sing-box/sh/src/init.sh$|. $iso_root/etc/sing-box/sh/src/init.sh|" "$iso_root/etc/sing-box/sh/sing-box.sh"
sed -i \
    -e "s|^is_core_dir=/etc/|is_core_dir=$iso_root/etc/|" \
    -e "s|^is_log_dir=/var/log/|is_log_dir=$iso_root/var/log/|" \
    -e "s|^is_sh_bin=/usr/local/bin/|is_sh_bin=$iso_root/usr/local/bin/|" \
    "$iso_root/etc/sing-box/sh/src/init.sh"
cat >"$iso_root/etc/sing-box/bin/sing-box" <<'EOF'
#!/usr/bin/env bash
[[ $1 == version ]] && printf 'sing-box version 1.14.4\n'
exit 0
EOF
cp "$entry_root/bin/apt-get" "$iso_root/bin/apt-get"
cp "$entry_root/bin/systemctl" "$iso_root/bin/systemctl"
chmod +x "$iso_root/etc/sing-box/sh/sing-box.sh" "$iso_root/etc/sing-box/bin/sing-box" "$iso_root/bin/apt-get" "$iso_root/bin/systemctl"

out=$(TEST_SYS_LOG="$iso_root/sys.log" PATH="$iso_root/bin:$PATH" bash "$iso_root/etc/sing-box/sh/sing-box.sh" version 2>&1) || fail "isolated sing-box.sh version failed: $out"
[[ $out == *'sing-box 1.14.4'* ]] || fail "isolated sing-box.sh version output unexpected: $out"

echo "PASS: tests-root-guard.sh"
