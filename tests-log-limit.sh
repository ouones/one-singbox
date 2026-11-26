#!/usr/bin/env bash
set -euo pipefail

interactive_read() { builtin read "$@"; }
run_interactive_operation() { ( "$@" ); }
menu_action() {
    local status
    "$@"
    status=$?
    menu_pause
    return "$status"
}
export -f interactive_read run_interactive_operation menu_action

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
is_core_dir="$workdir/core"
is_log_dir="$workdir/log"
mkdir -p "$is_core_dir" "$is_log_dir"
source "$repo_root/src/log.sh"
fail() { echo "FAIL: $*"; exit 1; }
msg() { :; }
warn() { :; }
_green() { echo "$*"; }
is_systemd=
is_openrc=
service_calls=0
log_limit_service() { service_calls=$((service_calls + 1)); }

[[ $(log_limit_read) == 200 ]] || fail 'default'
for value in 1 200 1024 8796093022207; do
    log_limit_valid "$value" || fail "valid input: $value"
done
for value in '' 0 -1 1.5 abc ' 200' 01 8796093022208 99999999999999999999; do
    if log_limit_valid "$value"; then fail "invalid input: $value"; fi
done
log_limit_init
[[ $(cat "$is_core_dir/log-limit-mb") == 200 ]] || fail 'initialize default'
log_limit_set <<<'0
abc
1.5
1'
[[ $(log_limit_read) == 1 ]] || fail 'retry invalid input and save'
[[ $service_calls == 2 ]] || fail 'start maintenance service'
keep_status=0
log_limit_set <<<'' || keep_status=$?
[[ $keep_status == 2 ]] || fail 'enter must return to the settings menu without a change'
[[ $(log_limit_read) == 1 && $service_calls == 2 ]] || fail 'enter preserves value'
[[ $(bash -c 'is_core_dir=$1; source "$2"; log_limit_read' _ "$is_core_dir" "$repo_root/src/log.sh") == 1 ]] || fail 'persist across process restart'

printf 'small log\n' >"$is_log_dir/access.log"
log_limit_check
[[ ! -e $is_log_dir/access.log.1 ]] || fail 'below limit untouched'

# Hold an append descriptor open across rotation, as the core does.
exec 3>>"$is_log_dir/access.log"
head -c 1500000 /dev/zero >>"$is_log_dir/access.log"
printf 'LATEST-ACCESS\n' >&3
log_limit_check
[[ ! -s $is_log_dir/access.log ]] || fail 'rotate active log'
[[ $(tail -c 14 "$is_log_dir/access.log.1") == LATEST-ACCESS ]] || fail 'retain newest records'
[[ $(stat -c %s "$is_log_dir/access.log.1") == 524288 ]] || fail 'leave space for new logs'
printf 'AFTER-ROTATION\n' >&3
exec 3>&-
[[ $(cat "$is_log_dir/access.log") == AFTER-ROTATION ]] || fail 'existing descriptor keeps writing'

head -c 700000 /dev/zero >"$is_log_dir/access.log"
printf 'OLDER-ACCESS\n' >>"$is_log_dir/access.log"
touch -t 202001010000 "$is_log_dir/access.log"
head -c 700000 /dev/zero >"$is_log_dir/error.log"
printf 'LATEST-ERROR\n' >>"$is_log_dir/error.log"
log_limit_check
[[ ! -e $is_log_dir/access.log.1 ]] || fail 'discard oldest archive first'
[[ $(tail -c 13 "$is_log_dir/error.log.1") == LATEST-ERROR ]] || fail 'retain newer error records'
total=0
for file in "$is_log_dir"/*.log*; do total=$((total + $(stat -c %s "$file"))); done
(( total <= 1048576 )) || fail 'combined log budget'

# Lowering the limit immediately trims existing logs without core restart.
echo 2 >"$is_core_dir/log-limit-mb"
head -c 1500000 /dev/zero >"$is_log_dir/access.log"
log_limit_set <<<'1'
total=0
for file in "$is_log_dir"/*.log*; do total=$((total + $(stat -c %s "$file"))); done
(( total <= 1048576 )) || fail 'lower limit applied immediately'

# Verify service lifecycle in isolated paths with service-manager stubs.
mkdir -p "$workdir/systemd" "$workdir/init.d"
sed -e "s|/lib/systemd/system|$workdir/systemd|g" \
    -e "s|/etc/init.d|$workdir/init.d|g" \
    "$repo_root/src/log.sh" >"$workdir/log.sh"
source "$workdir/log.sh"
is_core=sing-box
is_sh_dir=/etc/sing-box/sh
systemctl() { printf '%s\n' "$*" >>"$workdir/service-calls"; }
rc-service() { printf '%s\n' "$*" >>"$workdir/service-calls"; }
rc-update() { printf '%s\n' "$*" >>"$workdir/service-calls"; }
is_systemd=1
log_limit_service
grep -q 'ExecStart=/bin/bash /etc/sing-box/sh/src/log-limit.sh' "$workdir/systemd/sing-box-log-limit.service" || fail 'systemd worker command'
grep -qx 'enable sing-box-log-limit' "$workdir/service-calls" || fail 'systemd boot persistence'
grep -qx 'restart sing-box-log-limit' "$workdir/service-calls" || fail 'systemd worker start'
log_limit_remove
[[ ! -e $workdir/systemd/sing-box-log-limit.service ]] || fail 'systemd uninstall cleanup'
grep -qx 'disable --now sing-box-log-limit' "$workdir/service-calls" || fail 'systemd uninstall stops worker'
is_systemd=
is_openrc=1
log_limit_service
bash -n "$workdir/init.d/sing-box-log-limit"
grep -q 'pidfile="/run/${RC_SVCNAME}.pid"' "$workdir/init.d/sing-box-log-limit" || fail 'OpenRC pidfile'
grep -qx 'add sing-box-log-limit default' "$workdir/service-calls" || fail 'OpenRC boot persistence'
log_limit_remove
[[ ! -e $workdir/init.d/sing-box-log-limit ]] || fail 'OpenRC uninstall cleanup'
grep -qx 'del sing-box-log-limit default' "$workdir/service-calls" || fail 'OpenRC disable on uninstall'

# Exercise the actual menu branches through the full core/init entrypoint.
for core_file in "$repo_root/src/core.sh"; do
    menu_case_dir="$workdir/menu-case"
    menu_bin="$menu_case_dir/bin"
    mkdir -p "$menu_case_dir/core/bin" "$menu_case_dir/conf/.quan-meta" "$menu_case_dir/log" "$menu_bin"
    for tool in bash env awk sed grep cat mkdir rm mv cp head tail cut tr dirname basename readlink jq sleep wc sort stat uname mktemp flock chmod touch; do
        tool_path=$(command -v "$tool" || true)
        [[ -n $tool_path ]] && ln -sf "$tool_path" "$menu_bin/$tool"
    done
    cat >"$menu_bin/apt-get" <<'FAKE_APT'
#!/usr/bin/env bash
exit 0
FAKE_APT
    cat >"$menu_case_dir/core/bin/sing-box" <<'FAKE_CORE'
#!/usr/bin/env bash
[[ $1 == version ]] && printf 'sing-box version test\n'
exit 0
FAKE_CORE
    cat >"$menu_bin/systemctl" <<'FAKE_SYS'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"${MENU_SERVICE_CALLS:?}"
if [[ $1 == is-active ]]; then
    case ${TEST_SYSTEMD_STATE:-active} in
        active) echo active; exit 0 ;;
        inactive | failed) echo "$TEST_SYSTEMD_STATE"; exit 3 ;;
        *) exit 1 ;;
    esac
fi
exit 0
FAKE_SYS
    cat >"$menu_bin/rc-service" <<'FAKE_RC'
#!/usr/bin/env bash
printf 'rc-service %s\n' "$*" >>"${MENU_SERVICE_CALLS:?}"
if [[ $2 == status ]]; then
    exit "${TEST_OPENRC_STATUS:-0}"
fi
exit 0
FAKE_RC
    chmod +x "$menu_bin/apt-get" "$menu_case_dir/core/bin/sing-box" "$menu_bin/systemctl" "$menu_bin/rc-service"
    touch "$menu_case_dir/core/qrcode-dependency-checked"

    # 1. Navigating main menu -> 系统设置 -> 日志上限 exercises real system_tools_menu and log_limit_set.
    menu_service_calls="$workdir/home-status-calls"
    : >"$menu_service_calls"
    menu_out=$(
        MENU_SERVICE_CALLS="$menu_service_calls" PATH="$menu_bin" bash -c '
            set -uo pipefail
            is_core_dir="$1/core"
            is_conf_dir="$1/conf"
            is_log_dir="$1/log"
            is_sh_dir="$2"
            is_config_json="$1/config.json"
            is_core_bin="$1/core/bin/sing-box"
            is_core_ver=test
            is_sh_ver=test
            source "$3"
            is_systemd=
            is_openrc=
            is_main_menu
        ' _ "$menu_case_dir" "$repo_root" "$core_file" <<<$'5\n3\n\n\n0\nq\n' 2>&1
    ) || fail 'menu navigation to log limit failed'
    [[ $menu_out == *'日志上限'* && $menu_out == *'输入日志上限'* ]] || fail "menu did not execute log limit setting: $menu_out"
    [[ $menu_out == *'已保留当前日志占用上限'* ]] || fail "menu does not report the preserved log limit: $menu_out"

    # 2. Homepage status display refreshes systemd/OpenRC state on every display without mutating services.
    run_main_menu_status() {
        local mgr=$1 state_val=$2 expected=$3 expected_stop=$4
        : >"$menu_service_calls"
        local out
        out=$(
            MENU_SERVICE_CALLS="$menu_service_calls" TEST_SYSTEMD_STATE="$state_val" TEST_OPENRC_STATUS="$state_val" \
                PATH="$menu_bin" bash -c '
                set -uo pipefail
                is_core_dir="$1/core"
                is_conf_dir="$1/conf"
                is_log_dir="$1/log"
                is_sh_dir="$2"
                is_config_json="$1/config.json"
                is_core_bin="$1/core/bin/sing-box"
                is_core_ver=test
                is_sh_ver=test
                source "$3"
                _green() { printf "GREEN:%s" "$*"; }
                _red() { printf "RED:%s" "$*"; }
                if [[ $4 == systemd ]]; then
                    is_systemd=1; is_openrc=
                else
                    is_systemd=; is_openrc=1
                fi
                is_core_status=installed
                is_core_stop=1
                is_main_menu <<< "q" >/dev/null || exit 1
                is_main_menu <<< "q"
            ' _ "$menu_case_dir" "$repo_root" "$core_file" "$mgr" 2>&1
        ) || fail "status failure must not stop the main menu ($mgr/$state_val): $out"
        [[ $out == *"sing-box 内核：test ($expected)"* ]] || fail "wrong homepage status ($mgr/$state_val): $out"
        if [[ $mgr == systemd ]]; then
            [[ $(sort -u "$menu_service_calls") == 'systemctl is-active sing-box' ]] || fail 'homepage should only query systemd status'
        else
            [[ $(sort -u "$menu_service_calls") == 'rc-service sing-box status' ]] || fail 'OpenRC homepage should query rc-service only'
        fi
    }

    run_main_menu_status systemd inactive 'RED:已停止' 1
    run_main_menu_status systemd active 'GREEN:运行中' ''
    run_main_menu_status systemd failed 'RED:启动失败' 1
    run_main_menu_status systemd query-error 'RED:状态读取失败' 1

    run_main_menu_status openrc 0 'GREEN:运行中' ''
    run_main_menu_status openrc 3 'RED:已停止' 1
    run_main_menu_status openrc 32 'RED:启动失败' 1
    run_main_menu_status openrc 1 'RED:状态读取失败' 1
done

# Read-only usage counts only first-level regular .log and .log.1 bytes.
is_log_dir="$workdir/usage-log"
mkdir -p "$is_log_dir" "$is_log_dir/subdir"
head -c 1048576 /dev/zero >"$is_log_dir/access.log"
head -c 524288 /dev/zero >"$is_log_dir/error.log"
head -c 262144 /dev/zero >"$is_log_dir/access.log.1"
head -c 2097152 /dev/zero >"$is_log_dir/ignored.log.2"
head -c 2097152 /dev/zero >"$is_log_dir/ignored.txt"
head -c 2097152 /dev/zero >"$is_log_dir/subdir/nested.log"
ln -s "$is_log_dir/error.log" "$is_log_dir/alias.log"
[[ $(log_usage_read) == 1835008 ]] || fail 'usage includes current and rotated log bytes only'
is_log_dir="$workdir/no-log-directory"
[[ $(log_usage_read) == 0 ]] || fail 'missing log directory is empty usage'
is_log_dir="$workdir/non-stat-log"
mkdir -p "$is_log_dir/subdir"
head -c 1048576 /dev/zero >"$is_log_dir/ignored.log.2"
head -c 1048576 /dev/zero >"$is_log_dir/ignored.txt"
head -c 1048576 /dev/zero >"$is_log_dir/subdir/nested.log"
ln -s "$workdir/usage-log/error.log" "$is_log_dir/alias.log"
[[ $(log_usage_read) == 0 ]] || fail 'non-matching files and symlinks are excluded'
is_log_dir="$workdir/usage-log"
usage_stat_failure="$is_log_dir/error.log"
stat() {
    [[ ${3-} == "$usage_stat_failure" ]] && return 1
    command stat "$@"
}
if log_usage_read >/dev/null; then fail 'stat failure is not reported as zero usage'; fi
unset -f stat

echo 200 >"$is_core_dir/log-limit-mb"
for core_file in "$repo_root/src/core.sh"; do
    usage_case_dir="$workdir/usage-case"
    usage_bin="$usage_case_dir/bin"
    mkdir -p "$usage_case_dir/core/bin" "$usage_case_dir/conf/.quan-meta" "$usage_bin"
    for tool in bash env awk sed grep cat mkdir rm mv cp head tail cut tr dirname basename readlink jq sleep wc sort stat uname mktemp flock chmod touch; do
        tool_path=$(command -v "$tool" || true)
        [[ -n $tool_path ]] && ln -sf "$tool_path" "$usage_bin/$tool"
    done
    cat >"$usage_bin/apt-get" <<'FAKE_APT'
#!/usr/bin/env bash
exit 0
FAKE_APT
    cat >"$usage_bin/systemctl" <<'FAKE_SYS'
#!/usr/bin/env bash
[[ $1 == is-active ]] && echo active
exit 0
FAKE_SYS
    cat >"$usage_case_dir/core/bin/sing-box" <<'FAKE_CORE'
#!/usr/bin/env bash
[[ $1 == version ]] && printf 'sing-box version test\n'
exit 0
FAKE_CORE
    chmod +x "$usage_bin/apt-get" "$usage_bin/systemctl" "$usage_case_dir/core/bin/sing-box"
    touch "$usage_case_dir/core/qrcode-dependency-checked"

    run_usage_menu() {
        local log_dir_arg=$1 fail_stat=${2:-}
        USAGE_STAT_FAILURE="$fail_stat" PATH="$usage_bin" bash -c '
            set -uo pipefail
            is_core_dir="$1/core"
            is_conf_dir="$1/conf"
            is_log_dir="$2"
            is_sh_dir="$3"
            is_config_json="$1/config.json"
            is_core_bin="$1/core/bin/sing-box"
            is_core_ver=test
            is_sh_ver=test
            source "$4"
            if [[ -n ${USAGE_STAT_FAILURE:-} ]]; then
                stat() {
                    [[ ${3-} == "$USAGE_STAT_FAILURE" ]] && return 1
                    command stat "$@"
                }
            fi
            is_main_menu
        ' _ "$usage_case_dir" "$log_dir_arg" "$repo_root" "$core_file" <<<$'5\n3\n\n\n0\nq\n' 2>&1
    }

    is_log_dir="$workdir/usage-log"
    head -c 1048576 /dev/zero >"$is_log_dir/access.log"
    head -c 524288 /dev/zero >"$is_log_dir/error.log"
    head -c 262144 /dev/zero >"$is_log_dir/access.log.1"
    echo 200 >"$usage_case_dir/core/log-limit-mb"
    size_before=$(command stat -c %s "$is_log_dir/access.log")
    archive_before=$(command stat -c %s "$is_log_dir/access.log.1")
    menu_output=$(run_usage_menu "$is_log_dir") || fail "usage menu failed: $menu_output"
    [[ $menu_output == *'日志占用：1.75 MB / 上限 200 MB'* ]] || fail "menu displays current usage and limit: $menu_output"
    [[ $menu_output == *'输入日志上限'* ]] || fail "menu remains usable after usage display: $menu_output"
    [[ $(command stat -c %s "$is_log_dir/access.log") == "$size_before" && $(command stat -c %s "$is_log_dir/access.log.1") == "$archive_before" ]] || fail 'usage display does not mutate logs'

    head -c 524288 /dev/zero >"$is_log_dir/access.log"
    echo 100 >"$usage_case_dir/core/log-limit-mb"
    menu_output=$(run_usage_menu "$is_log_dir")
    [[ $menu_output == *'日志占用：1.25 MB / 上限 100 MB'* ]] || fail "menu recomputes usage and limit: $menu_output"
    echo 1 >"$usage_case_dir/core/log-limit-mb"
    menu_output=$(run_usage_menu "$is_log_dir")
    [[ $menu_output == *'日志占用：1.25 MB / 上限 1 MB'* ]] || fail "usage display is not truncated to limit: $menu_output"
    echo 100 >"$usage_case_dir/core/log-limit-mb"

    mkdir -p "$workdir/empty-log"
    menu_output=$(run_usage_menu "$workdir/empty-log")
    [[ $menu_output == *'日志占用：0.00 MB / 上限 100 MB'* ]] || fail "empty log directory displays zero usage: $menu_output"

    menu_output=$(run_usage_menu "$workdir/no-log-directory")
    [[ $menu_output == *'日志占用：0.00 MB / 上限 100 MB'* ]] || fail "missing log directory displays zero usage: $menu_output"

    menu_output=$(run_usage_menu "$workdir/non-stat-log")
    [[ $menu_output == *'日志占用：0.00 MB / 上限 100 MB'* ]] || fail "directory with no matching logs displays zero usage: $menu_output"

    rm -f "$usage_case_dir/core/log-limit-mb"
    menu_output=$(run_usage_menu "$workdir/empty-log")
    [[ $menu_output == *'日志占用：0.00 MB / 上限 200 MB'* ]] || fail "menu uses default limit without saved value: $menu_output"

    echo 100 >"$usage_case_dir/core/log-limit-mb"
    menu_output=$(run_usage_menu "$workdir/usage-log" "$workdir/usage-log/error.log")
    [[ $menu_output == *'日志占用：暂不可用 / 上限 100 MB'* ]] || fail "menu reports unreadable usage without hiding limit: $menu_output"
    [[ $menu_output == *'输入日志上限'* ]] || fail "menu remains usable after usage read failure: $menu_output"
done
echo 'PASS: log size limit and service lifecycle'
