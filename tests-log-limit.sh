#!/usr/bin/env bash
set -euo pipefail

interactive_read() { builtin read "$@"; }
run_interactive_operation() { "$@"; }
export -f interactive_read run_interactive_operation

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
log_limit_set <<<''
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

# Exercise the actual menu branches in both distributed core copies.
qrcode_dependency_checked() { return 0; }
qrcode_dependency_install() { fail 'unexpected QR migration in isolated menu test'; }
for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
    source <(sed -n '/^service_status_read() {/,/^}/p' "$repo_root/src/init.sh")
    source <(sed -n '/^core_status_read() {/,/^}/p' "$repo_root/src/init.sh")
    source <(sed -n '/^menu_select() {/,/^}/p' "$core_file")
    source <(sed -n '/^is_main_menu() {/,/^}/p' "$core_file")
    source <(sed -n '/^system_tools_menu() {/,/^}/p' "$core_file")
    is_script_name=one-singbox is_core_name=sing-box is_sh_ver=test author=test is_core_ver=test is_core_status=running
    is_systemd= is_openrc=
    _green() { printf 'GREEN:%s' "$*"; }
    _red() { printf 'RED:%s' "$*"; }
    msg_ul() { :; }
    load() { [[ $1 == log.sh ]] || fail 'menu loads log module'; }
    menu_pause() { :; }
    block_cn_status_text() { printf '未启用'; }
    menu_select() {
        case $2 in
        is_main_pick)
            main_menu_calls=$((${main_menu_calls:-0} + 1))
            [[ $main_menu_calls == 1 ]] || return 3
            REPLY=5
            ;;
        is_system_tool)
            [[ $6 == '日志上限' ]] || fail 'system menu shows log limit setting'
            system_menu_calls=$((${system_menu_calls:-0} + 1))
            [[ $system_menu_calls == 1 ]] || return 2
            REPLY=3
            ;;
        esac
    }
    run_main_menu() { main_menu_calls=0 system_menu_calls=0; is_main_menu; }
    menu_called=
    log_limit_set() { menu_called=1; }
    run_main_menu
    [[ $menu_called == 1 ]] || fail 'menu calls log limit setting'

    menu_output=
    menu_service_calls="$workdir/home-status-calls"
    : >"$menu_service_calls"
    msg() { menu_output+="$*"$'\n'; }
    systemctl() {
        printf 'systemctl %s\n' "$*" >>"$menu_service_calls"
        [[ $* == 'is-active sing-box' ]] || fail "unexpected systemd status command: $*"
        case $service_state in
            active) echo active ;;
            inactive | failed) echo "$service_state"; return 3 ;;
            *) return 1 ;;
        esac
    }
    rc-service() {
        printf 'rc-service %s\n' "$*" >>"$menu_service_calls"
        [[ $* == 'sing-box status' ]] || fail "unexpected OpenRC status command: $*"
        return "$openrc_status"
    }
    run_main_menu_status() {
        local expected=$1
        menu_output=
        menu_called=
        run_main_menu
        [[ $menu_called == 1 ]] || fail 'status failure must not stop the main menu'
        [[ $menu_output == *"sing-box 内核：test ($expected)"* ]] || fail "wrong homepage status: $menu_output"
    }

    is_systemd=1
    is_openrc=
    service_state=inactive
    is_core_status=installed
    run_main_menu_status 'RED:已停止'
    [[ $is_core_stop == 1 ]] || fail 'stopped systemd service should set the stop marker'
    [[ $(sort -u "$menu_service_calls") == 'systemctl is-active sing-box' ]] || fail 'homepage should only query systemd status'

    : >"$menu_service_calls"
    service_state=active
    is_core_stop=1
    run_main_menu_status 'GREEN:运行中'
    [[ -z $is_core_stop ]] || fail 'running systemd service should clear the old stop marker'
    [[ $(sort -u "$menu_service_calls") == 'systemctl is-active sing-box' ]] || fail 'homepage should refresh systemd status on every display'

    : >"$menu_service_calls"
    service_state=failed
    run_main_menu_status 'RED:启动失败'
    service_state=query-error
    run_main_menu_status 'RED:状态读取失败'

    is_systemd=
    is_openrc=1
    openrc_status=0
    : >"$menu_service_calls"
    run_main_menu_status 'GREEN:运行中'
    [[ $(sort -u "$menu_service_calls") == 'rc-service sing-box status' ]] || fail 'OpenRC homepage should query rc-service only'
    openrc_status=3
    : >"$menu_service_calls"
    run_main_menu_status 'RED:已停止'
    openrc_status=32
    : >"$menu_service_calls"
    run_main_menu_status 'RED:启动失败'
    openrc_status=1
    : >"$menu_service_calls"
    run_main_menu_status 'RED:状态读取失败'
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
for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
    is_log_dir="$workdir/usage-log"
    head -c 1048576 /dev/zero >"$is_log_dir/access.log"
    head -c 524288 /dev/zero >"$is_log_dir/error.log"
    head -c 262144 /dev/zero >"$is_log_dir/access.log.1"
    echo 200 >"$is_core_dir/log-limit-mb"
    source <(sed -n '/^menu_select() {/,/^}/p' "$core_file")
    source <(sed -n '/^is_main_menu() {/,/^}/p' "$core_file")
    source <(sed -n '/^system_tools_menu() {/,/^}/p' "$core_file")
    is_script_name=one-singbox is_core_name=sing-box is_sh_ver=test author=test is_core_ver=test is_core_status=running
    menu_output=
    msg() { menu_output+="$*"$'\n'; }
    load() { [[ $1 == log.sh ]] || fail 'menu loads log module'; }
    menu_pause() { :; }
    block_cn_status_text() { printf '未启用'; }
    menu_select() {
        case $2 in
        is_main_pick)
            main_menu_calls=$((${main_menu_calls:-0} + 1))
            [[ $main_menu_calls == 1 ]] || return 3
            REPLY=5
            ;;
        is_system_tool)
            [[ $6 == '日志上限' ]] || fail 'system menu shows log limit setting'
            system_menu_calls=$((${system_menu_calls:-0} + 1))
            [[ $system_menu_calls == 1 ]] || return 2
            REPLY=3
            ;;
        esac
    }
    run_main_menu() { main_menu_calls=0 system_menu_calls=0; is_main_menu; }
    menu_called=
    log_limit_set() { menu_called=1; }
    service_calls_before=$service_calls
    size_before=$(command stat -c %s "$is_log_dir/access.log")
    archive_before=$(command stat -c %s "$is_log_dir/access.log.1")
    run_main_menu
    [[ $menu_output == *'日志占用：1.75 MB / 上限 200 MB'* ]] || fail 'menu displays current usage and limit'
    [[ $menu_called == 1 ]] || fail 'menu remains usable after usage display'
    [[ $(command stat -c %s "$is_log_dir/access.log") == "$size_before" && $(command stat -c %s "$is_log_dir/access.log.1") == "$archive_before" && $service_calls == "$service_calls_before" ]] || fail 'usage display does not mutate logs or services'

    head -c 524288 /dev/zero >"$is_log_dir/access.log"
    echo 100 >"$is_core_dir/log-limit-mb"
    menu_output=
    run_main_menu
    [[ $menu_output == *'日志占用：1.25 MB / 上限 100 MB'* ]] || fail 'menu recomputes usage and limit'
    echo 1 >"$is_core_dir/log-limit-mb"
    menu_output=
    run_main_menu
    [[ $menu_output == *'日志占用：1.25 MB / 上限 1 MB'* ]] || fail 'usage display is not truncated to limit'
    echo 100 >"$is_core_dir/log-limit-mb"

    is_log_dir="$workdir/empty-log"
    mkdir -p "$is_log_dir"
    menu_output=
    run_main_menu
    [[ $menu_output == *'日志占用：0.00 MB / 上限 100 MB'* ]] || fail 'empty log directory displays zero usage'

    is_log_dir="$workdir/no-log-directory"
    menu_output=
    run_main_menu
    [[ $menu_output == *'日志占用：0.00 MB / 上限 100 MB'* ]] || fail 'missing log directory displays zero usage'

    is_log_dir="$workdir/non-stat-log"
    menu_output=
    run_main_menu
    [[ $menu_output == *'日志占用：0.00 MB / 上限 100 MB'* ]] || fail 'directory with no matching logs displays zero usage'

    rm -f "$is_core_dir/log-limit-mb"
    is_log_dir="$workdir/empty-log"
    menu_output=
    run_main_menu
    [[ $menu_output == *'日志占用：0.00 MB / 上限 200 MB'* ]] || fail 'menu uses default limit without saved value'

    echo 100 >"$is_core_dir/log-limit-mb"
    is_log_dir="$workdir/usage-log"
    usage_stat_failure="$is_log_dir/error.log"
    stat() {
        [[ ${3-} == "$usage_stat_failure" ]] && return 1
        command stat "$@"
    }
    menu_output=
    menu_called=
    run_main_menu
    [[ $menu_output == *'日志占用：暂不可用 / 上限 100 MB'* ]] || fail 'menu reports unreadable usage without hiding limit'
    [[ $menu_called == 1 ]] || fail 'menu remains usable after usage read failure'
    unset -f stat
    is_log_dir="$workdir/log"
done
echo 'PASS: log size limit and service lifecycle'
