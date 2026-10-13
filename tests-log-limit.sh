#!/usr/bin/env bash
set -euo pipefail

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
for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
    source <(sed -n '/^is_main_menu() {/,/^}/p' "$core_file")
    is_core_name=sing-box is_sh_ver=test author=test is_core_ver=test is_core_status=running
    msg_ul() { :; }
    load() { [[ $1 == log.sh ]] || fail 'menu loads log module'; }
    ask() {
        if [[ $1 == mainmenu ]]; then
            REPLY=9
        else
            [[ ${is_tmp_list[5]} == '日志大小限制(1MB)' ]] || fail 'menu shows persisted limit'
            REPLY=6
        fi
    }
    menu_called=
    log_limit_set() { menu_called=1; }
    is_main_menu
    [[ $menu_called == 1 ]] || fail 'menu calls log limit setting'
done

echo 'PASS: log size limit and service lifecycle'
