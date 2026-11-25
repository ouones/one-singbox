#!/usr/bin/env bash
# Unified offline static guardrail and regression test runner.
# Runs directly in the workspace (e.g. CI) or in an isolated /tmp copy (--copy-to-tmp).

set -uo pipefail

export LANG=C.UTF-8 LC_ALL=C.UTF-8

usage() {
    cat <<'EOF'
Usage: scripts/run-offline-tests.sh [options] [tests-*.sh ...]

Options:
  --copy-to-tmp       Copy repository payload to /tmp before running tests
  --reuse-id <id>     With --copy-to-tmp, reuse /tmp/one-singbox-work-<id>
  --clean-reuse <id>  Remove /tmp/one-singbox-work-<id> and exit
  --jobs <N>          Parallel test workers (default: 1)
  --static-only       Run static checks (CRLF, bash -n, blocking read, shellcheck) only
  --no-static         Skip static checks
  --no-shellcheck     Skip shellcheck in static checks (keep LF, bash -n, blocking read)
  -h, --help          Show this help
EOF
}

copy_to_tmp=0
reuse_id=
clean_reuse=
jobs=1
static_only=0
no_static=0
no_shellcheck=0
selected_tests=()

while (($# > 0)); do
    case "$1" in
        --copy-to-tmp)
            copy_to_tmp=1
            shift
            ;;
        --reuse-id)
            [[ ${2-} ]] || { echo "Missing value for --reuse-id" >&2; exit 2; }
            reuse_id=$2
            shift 2
            ;;
        --clean-reuse)
            [[ ${2-} ]] || { echo "Missing value for --clean-reuse" >&2; exit 2; }
            clean_reuse=$2
            shift 2
            ;;
        --jobs)
            [[ ${2-} =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --jobs value: ${2-}" >&2; exit 2; }
            jobs=$2
            shift 2
            ;;
        --static-only)
            static_only=1
            shift
            ;;
        --no-static)
            no_static=1
            shift
            ;;
        --no-shellcheck)
            no_shellcheck=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            while (($# > 0)); do
                selected_tests+=("$1")
                shift
            done
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            selected_tests+=("$1")
            shift
            ;;
    esac
done

validate_reuse_id() {
    local id=$1
    if [[ ! $id =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "Invalid reuse id '$id': allowed [A-Za-z0-9._-]" >&2
        exit 2
    fi
}

if [[ -n $clean_reuse ]]; then
    validate_reuse_id "$clean_reuse"
    target="/tmp/one-singbox-work-${clean_reuse}"
    rm -rf "$target"
    echo "Cleaned reusable workdir: $target"
    exit 0
fi

if [[ -n $reuse_id ]]; then
    validate_reuse_id "$reuse_id"
    if ((copy_to_tmp == 0)); then
        echo "--reuse-id requires --copy-to-tmp" >&2
        exit 2
    fi
fi

repo_root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
work=$repo_root
cleanup_dir=

cleanup() {
    if [[ -n $cleanup_dir ]]; then
        rm -rf "$cleanup_dir"
    fi
}
trap cleanup EXIT

TAR_EXCLUDES=(
    --exclude=.git
    --exclude=.codegraph
    --exclude=.worktrees
    --exclude=.scratch
    --exclude=.superpowers
    --exclude=.logs
    --exclude=AGENTS.md
    --exclude=docs/history.md
    --exclude=docs/testing-vps.local.md
    --exclude=dsh-installed-inventory.md
    '--exclude=*.png'
    '--exclude=*.jpg'
    '--exclude=*.jpeg'
    '--exclude=*.webp'
    '--exclude=*.gif'
)

sync_to_workdir() {
    local src=$1 dst=$2
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete \
            --exclude='.git' \
            --exclude='.codegraph' \
            --exclude='.worktrees' \
            --exclude='.scratch' \
            --exclude='.superpowers' \
            --exclude='.logs' \
            --exclude='AGENTS.md' \
            --exclude='docs/history.md' \
            --exclude='docs/testing-vps.local.md' \
            --exclude='dsh-installed-inventory.md' \
            --exclude='*.png' \
            --exclude='*.jpg' \
            --exclude='*.jpeg' \
            --exclude='*.webp' \
            --exclude='*.gif' \
            "$src/" "$dst/"
    else
        # Keep .logs directory slot; wipe previous payload entries cleanly before tar extract.
        find "$dst" -mindepth 1 -maxdepth 1 ! -name '.logs' -exec rm -rf {} +
        tar -C "$src" "${TAR_EXCLUDES[@]}" -cf - . | tar -C "$dst" -xf -
    fi
}

if ((copy_to_tmp == 1)); then
    if [[ -n $reuse_id ]]; then
        work="/tmp/one-singbox-work-${reuse_id}"
        mkdir -p "$work"
    else
        work=$(mktemp -d /tmp/one-singbox-suite.XXXXXX)
        cleanup_dir=$work
    fi
    sync_to_workdir "$repo_root" "$work"
fi

cd "$work" || exit 1

run_static_checks() {
    local shell_files=() crlf_files=() file
    while IFS= read -r -d '' file; do
        shell_files+=("$file")
    done < <(
        find . -type f -name '*.sh' \
            -not -path './.git/*' \
            -not -path './.codegraph/*' \
            -not -path './.worktrees/*' \
            -not -path './.scratch/*' \
            -not -path './.superpowers/*' \
            -print0 | LC_ALL=C sort -z
    )

    if ((${#shell_files[@]} == 0)); then
        echo "STATIC FAIL: no *.sh files found" >&2
        return 1
    fi

    for file in "${shell_files[@]}"; do
        if grep -q $'\r' "$file"; then
            crlf_files+=("$file")
        fi
    done
    if ((${#crlf_files[@]} > 0)); then
        printf 'STATIC FAIL: CRLF line endings detected in:\n' >&2
        printf '  %s\n' "${crlf_files[@]}" >&2
        return 1
    fi

    local syntax_fail=0
    for file in "${shell_files[@]}"; do
        if ! bash -n "$file"; then
            syntax_fail=1
        fi
    done
    if ((syntax_fail != 0)); then
        echo "STATIC FAIL: bash -n syntax validation failed" >&2
        return 1
    fi

    local read_targets=() candidate
    for candidate in sing-box.sh install.sh src/*.sh scripts/*.sh tests-*.sh; do
        [[ -f $candidate ]] && read_targets+=("$candidate")
    done

    if ((${#read_targets[@]} > 0)); then
        local read_hits
        read_hits=$(gawk '
            /^[[:space:]]*#/ { next }
            /#[[:space:]]*allow-blocking-read/ { next }
            /(interactive_read|read)\(\)/ { next }
            /builtin[[:space:]]+read[[:space:]]+"\$@"/ { next }
            /(^|[;&|][[:space:]]*|then[[:space:]]+|do[[:space:]]+)read([[:space:]]|$)/ {
                if ($0 ~ /^[[:space:]]*while[[:space:]]/) next
                if ($0 ~ /[[:space:]]-t[[:space:]]*["'\''0-9.$A-Za-z_]/) next
                if ($0 ~ /<<<|<["'\''\/$a-zA-Z0-9_(]/) next
                printf "%s:%d: %s\n", FILENAME, FNR, $0
            }
        ' "${read_targets[@]}")
        if [[ -n $read_hits ]]; then
            printf 'STATIC FAIL: blocking read without -t timeout or redirect:\n%s\n' "$read_hits" >&2
            return 1
        fi
    fi

    local sc_targets=()
    for candidate in sing-box.sh install.sh src/*.sh; do
        [[ -f $candidate ]] && sc_targets+=("$candidate")
    done

    local shellcheck_status="shellcheck skipped: not installed"
    if ((no_shellcheck == 1)); then
        shellcheck_status="shellcheck skipped: --no-shellcheck"
    elif command -v shellcheck >/dev/null 2>&1; then
        if ((${#sc_targets[@]} > 0)); then
            local sc_fail=0 target
            for target in "${sc_targets[@]}"; do
                if ! shellcheck -s bash --include=SC2086,SC2155,SC2164,SC2046,SC2145,SC2068 "$target"; then
                    sc_fail=1
                fi
            done
            if ((sc_fail != 0)); then
                echo "STATIC FAIL: shellcheck high-severity check failed" >&2
                return 1
            fi
        fi
        shellcheck_status="shellcheck"
    else
        echo "STATIC WARN: shellcheck not found in PATH; skipping shellcheck static check (install shellcheck for full local parity)" >&2
    fi

    echo "STATIC OK: ${#shell_files[@]} *.sh files passed (LF, bash -n, non-blocking read, $shellcheck_status)"
}

if ((no_static == 0)); then
    run_static_checks || exit 1
fi

if ((static_only == 1)); then
    exit 0
fi

tests=()
if ((${#selected_tests[@]} > 0)); then
    for t in "${selected_tests[@]}"; do
        t=${t#./}
        if [[ ! -f $t ]]; then
            echo "Test file not found: $t" >&2
            exit 2
        fi
        tests+=("$t")
    done
else
    while IFS= read -r t; do
        tests+=("$t")
    done < <(LC_ALL=C printf '%s\n' tests-*.sh | LC_ALL=C sort)
fi

if ((${#tests[@]} == 0)); then
    echo "No tests-*.sh files found" >&2
    exit 1
fi

effective_jobs=$jobs
if ((effective_jobs > ${#tests[@]})); then
    effective_jobs=${#tests[@]}
fi

mkdir -p "$work/.logs"
rm -f "$work/.logs/"*

run_one_test() {
    local test_file=$1
    local log_file="$work/.logs/${test_file}.log"
    local sec_file="$work/.logs/${test_file}.sec"
    local rc_file="$work/.logs/${test_file}.rc"
    local start=$SECONDS rc=0

    if env --default-signal=INT,QUIT timeout 300 bash "$test_file" >"$log_file" 2>&1; then
        rc=0
    else
        rc=$?
    fi
    printf '%s\n' "$((SECONDS - start))" >"$sec_file"
    printf '%s\n' "$rc" >"$rc_file"
}

suite_start=$SECONDS

if ((effective_jobs <= 1)); then
    for test_file in "${tests[@]}"; do
        run_one_test "$test_file"
    done
else
    for test_file in "${tests[@]}"; do
        while (( $(jobs -rp | wc -l) >= effective_jobs )); do
            sleep 0.1
        done
        run_one_test "$test_file" &
    done
    wait
fi

pass=0
fail=0
failed=()

for test_file in "${tests[@]}"; do
    sec=$(cat "$work/.logs/${test_file}.sec" 2>/dev/null || echo "?")
    rc=$(cat "$work/.logs/${test_file}.rc" 2>/dev/null || echo "1")
    if [[ $rc == 0 ]]; then
        pass=$((pass + 1))
        printf 'PASS %-40s %ss\n' "$test_file" "$sec"
    else
        fail=$((fail + 1))
        failed+=("$test_file")
        printf 'FAIL %-40s %ss (rc=%s)\n' "$test_file" "$sec" "$rc"
        tail -n 30 "$work/.logs/${test_file}.log" | sed 's/^/    /'
    fi
done

total_secs=$((SECONDS - suite_start))
echo "===== $pass passed, $fail failed (${total_secs}s, jobs=${effective_jobs}) ====="
if ((fail > 0)); then
    printf 'failed: %s\n' "${failed[*]}" >&2
    exit 1
fi
