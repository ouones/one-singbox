#!/usr/bin/env bash
# Run the full regression suite inside the dedicated WSL2 test distro.
# Invoked by scripts/test-local.ps1; do not run against a repository copy you
# care about, since the tests write to their temporary work directories.

set -u

export LANG=C.UTF-8 LC_ALL=C.UTF-8

repo_root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
work=$(mktemp -d /tmp/one-singbox-suite.XXXXXX)
trap 'rm -rf "$work"' EXIT

tar -C "$repo_root" \
    --exclude=.git \
    --exclude=.codegraph \
    --exclude=.worktrees \
    --exclude=.scratch \
    --exclude=.superpowers \
    -cf - . 2>/dev/null | tar -C "$work" -xf -
cd "$work" || exit 1

tests=(
    tests-block-cn.sh
    tests-destructive-confirmation.sh
    tests-interaction-results.sh
    tests-log-limit.sh
    tests-menu-navigation.sh
    tests-node-delete-menu.sh
    tests-node-external-frontend.sh
    tests-node-menu-copy.sh
    tests-node-menu-state.sh
    tests-node-name-label.sh
    tests-node-proxy-outbound.sh
    tests-node-share-qrcode.sh
    tests-qrcode-deps.sh
    tests-reality-sni.sh
    tests-relay-support.sh
    tests-service-results.sh
    tests-skill-inventory.sh
    tests-snell-support.sh
    tests-system-impact-confirmation.sh
    tests-terminal-cancel.sh
    tests-terminology.sh
    tests-update-script-reload.sh
)

pass=0
fail=0
failed=()
mkdir -p "$work/.logs"

for test_file in "${tests[@]}"; do
    start=$SECONDS
    if timeout 300 bash "$test_file" >"$work/.logs/$test_file.log" 2>&1; then
        pass=$((pass + 1))
        printf 'PASS %-40s %ss\n' "$test_file" "$((SECONDS - start))"
    else
        status=$?
        fail=$((fail + 1))
        failed+=("$test_file")
        printf 'FAIL %-40s %ss (rc=%s)\n' "$test_file" "$((SECONDS - start))" "$status"
        tail -n 25 "$work/.logs/$test_file.log" | sed 's/^/    /'
    fi
done

echo "===== $pass passed, $fail failed ====="
if ((fail > 0)); then
    printf 'failed: %s\n' "${failed[*]}"
    exit 1
fi
