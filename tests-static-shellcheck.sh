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

copy_repo_to() {
    local dst=$1
    mkdir -p "$dst"
    tar -C "$repo_root" \
        --exclude=.git \
        --exclude=.logs \
        -cf - . | tar -C "$dst" -xf -
}

make_fake_shellcheck() {
    local bin_dir=$1
    local mode=${2:-check}
    local log_file=${3:-}
    mkdir -p "$bin_dir"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -uo pipefail\n'
        printf 'log_file=%s\n' "${log_file@Q}"
        printf 'mode=%s\n' "${mode@Q}"
        cat <<'EOF'
include_arg=""
shell_arg=""
files=()
while (($# > 0)); do
    case "$1" in
        --include=*)
            include_arg=${1#--include=}
            shift
            ;;
        -i)
            include_arg=${2:-}
            shift 2
            ;;
        -s)
            shell_arg=${2:-}
            shift 2
            ;;
        --shell=*)
            shell_arg=${1#--shell=}
            shift
            ;;
        -*)
            shift
            ;;
        *)
            files+=("$1")
            shift
            ;;
    esac
done
if [[ -n $log_file ]]; then
    printf 'SHELL=%s\nINCLUDE=%s\nFILES=%s\n' "$shell_arg" "$include_arg" "${files[*]}" >"$log_file"
fi
if [[ $mode == pass ]]; then
    exit 0
fi
for req in SC2086 SC2155 SC2164; do
    if [[ ",$include_arg," != *,$req,* ]]; then
        echo "missing required rule in --include: $req (got: $include_arg)" >&2
        exit 2
    fi
done
rc=0
for f in "${files[@]}"; do
    if grep -nE 'echo[[:space:]]+\$[A-Za-z_][A-Za-z0-9_]*([[:space:]]|$)' "$f"; then
        echo "$f: SC2086: Double quote to prevent globbing and word splitting." >&2
        rc=1
    fi
    if grep -nE '^[[:space:]]*local[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=\$\(' "$f"; then
        echo "$f: SC2155: Declare and assign separately to avoid masking return values." >&2
        rc=1
    fi
    if grep -nE '^[[:space:]]*cd[[:space:]]+[^|&;]+$' "$f"; then
        echo "$f: SC2164: Use cd ... || exit in case cd fails." >&2
        rc=1
    fi
done
exit "$rc"
EOF
    } >"$bin_dir/shellcheck"
    chmod +x "$bin_dir/shellcheck"
}

# Case 1: Missing shellcheck in PATH emits clear notice and does not hard-fail.
case1_dir="$workdir/case1"
copy_repo_to "$case1_dir"
no_sc_bin="$workdir/no-sc-bin"
mkdir -p "$no_sc_bin"
for tool in bash env find grep gawk sort cat mkdir rm cp mv tar sed printf head tail cut tr basename dirname readlink; do
    tool_path=$(command -v "$tool" || true)
    [[ -n $tool_path ]] && ln -sf "$tool_path" "$no_sc_bin/$tool"
done
out1=$(PATH="$no_sc_bin" bash "$case1_dir/scripts/run-offline-tests.sh" --static-only 2>&1) || fail "static check should not fail when shellcheck is missing: $out1"
grep -qi 'shellcheck' <<<"$out1" || fail "expected clear notice mentioning shellcheck when binary is missing, got: $out1"
grep -q 'STATIC OK' <<<"$out1" || fail "expected STATIC OK when shellcheck is missing, got: $out1"

# Case 2: With fake shellcheck in PATH, verifies flags (--include SC2086,SC2155,SC2164 and -s bash) and production targets.
case2_dir="$workdir/case2"
copy_repo_to "$case2_dir"
sc_bin2="$workdir/sc-bin2"
sc_log2="$workdir/sc2.log"
make_fake_shellcheck "$sc_bin2" pass "$sc_log2"
out2=$(PATH="$sc_bin2:$PATH" bash "$case2_dir/scripts/run-offline-tests.sh" --static-only 2>&1) || fail "static check failed with passing fake shellcheck: $out2"
[[ -f $sc_log2 ]] || fail "shellcheck was not invoked by run-offline-tests.sh"
log_content=$(cat "$sc_log2")
grep -q '^SHELL=bash$' <<<"$log_content" || fail "expected -s bash / --shell=bash, got: $log_content"
include_line=$(grep '^INCLUDE=' <<<"$log_content" || true)
for rule in SC2086 SC2155 SC2164; do
    grep -q "$rule" <<<"$include_line" || fail "expected $rule in shellcheck --include, got: $include_line"
done
files_line=$(grep '^FILES=' <<<"$log_content" || true)
for target in sing-box.sh install.sh src/core.sh src/init.sh src/log.sh src/dns.sh; do
    grep -q "$target" <<<"$files_line" || fail "expected $target in shellcheck targets, got: $files_line"
done

# Case 3: Fake shellcheck blocks SC2086, SC2155, and SC2164 violations.
for kind in SC2086 SC2155 SC2164; do
    case3_dir="$workdir/case3-$kind"
    copy_repo_to "$case3_dir"
    sc_bin3="$workdir/sc-bin3-$kind"
    make_fake_shellcheck "$sc_bin3" check
    case "$kind" in
        SC2086)
            printf '\necho $unquoted_test_var\n' >>"$case3_dir/src/bbr.sh"
            ;;
        SC2155)
            printf '\ntest_sc2155() {\n    local bad_val=$(echo test)\n}\n' >>"$case3_dir/src/bbr.sh"
            ;;
        SC2164)
            printf '\ntest_sc2164() {\n    cd /tmp\n}\n' >>"$case3_dir/src/bbr.sh"
            ;;
    esac
    if out3=$(PATH="$sc_bin3:$PATH" bash "$case3_dir/scripts/run-offline-tests.sh" --static-only 2>&1); then
        fail "expected static check to fail on injected $kind violation, but it passed: $out3"
    fi
done

echo "PASS: tests-static-shellcheck"
