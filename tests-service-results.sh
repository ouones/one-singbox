#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
service_calls_file=$(mktemp)
trap 'rm -f "$service_calls_file"' EXIT

fail() {
    echo "FAIL: $*"
    exit 1
}

source <(sed -n '/^service_status_read() {/,/^}/p' "$repo_root/src/init.sh")
source <(sed -n '/^core_status_read() {/,/^}/p' "$repo_root/src/init.sh")

msg() { menu_output+="$*"$'\n'; }
_green() { printf '%s' "$*"; }
_red() { printf '%s' "$*"; }
ask() {
    [[ ${is_tmp_list[1]} == '启动服务' ]] || fail 'service menu offers start action'
    if [[ $menu_return_after_action ]]; then
        REPLY=6
        menu_return_after_action=
    else
        REPLY=$menu_choice
        menu_return_after_action=1
    fi
}
menu_pause() { :; }

systemctl() {
    printf '%s\n' "$*" >>"$service_calls_file"
    if [[ $1 == is-active ]]; then
        case $service_state in
            active) printf 'active\n'; return 0 ;;
            inactive) printf 'inactive\n'; return 3 ;;
            failed) printf 'failed\n'; return 3 ;;
            *) printf 'unknown\n'; return 1 ;;
        esac
    fi
    service_state=$service_final_state
    return "$service_action_status"
}

rc-service() {
    printf '%s\n' "$*" >>"$service_calls_file"
    if [[ $2 == status ]]; then
        case $service_state in
            active) return 0 ;;
            inactive) return 3 ;;
            failed) return 32 ;;
            *) return 1 ;;
        esac
    fi
    service_state=$service_final_state
    return "$service_action_status"
}

for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
    source <(sed -n '/^manage() {/,/^}/p' "$core_file")
    source <(sed -n '/^service_menu() {/,/^}/p' "$core_file")
    source <(sed -n '/^service_action_result() {/,/^}/p' "$core_file")
    source <(sed -n '/^main() {/,/^}/p' "$core_file")

    is_core=sing-box
    is_core_name=sing-box
    is_core_ver=test
    is_log_dir=/var/log/sing-box

    # The service menu waits for the operation and verifies that startup reached active.
    is_systemd=1
    is_openrc=
    service_state=inactive
    service_final_state=active
    service_action_status=0
    menu_choice=2
    menu_output=
    : >"$service_calls_file"
    service_menu || fail "$core_file menu should accept a confirmed start"
    [[ $(cat "$service_calls_file") == $'start sing-box\nis-active sing-box' ]] || fail "$core_file menu waits for and verifies start: $(cat "$service_calls_file")"
    [[ $menu_output == *'启动服务成功'* && $menu_output == *'运行中'* ]] || fail "$core_file menu reports confirmed start: $menu_output"

    # A completed request is a failure when the service remains active after stop.
    service_state=active
    service_final_state=active
    menu_choice=3
    menu_output=
    : >"$service_calls_file"
    if service_menu; then fail "$core_file menu must reject a stop that did not reach inactive"; fi
    [[ $menu_output == *'停止服务未达到目标状态'* && $menu_output == *'journalctl -u sing-box.service'* ]] || fail "$core_file menu reports stop failure with logs: $menu_output"
    [[ $(cat "$service_calls_file") == $'stop sing-box\nis-active sing-box' ]] || fail "$core_file menu verifies a completed stop"

    # Unknown status is not success, even when the service manager accepted restart.
    service_state=active
    service_final_state=unknown
    menu_choice=4
    menu_output=
    : >"$service_calls_file"
    if service_menu; then fail "$core_file menu must not report unknown restart status as success"; fi
    [[ $menu_output == *'无法确认 sing-box 当前状态'* && $menu_output == *'journalctl -u sing-box.service'* ]] || fail "$core_file menu explains unknown state and logs: $menu_output"
    [[ $menu_output != *'重启服务成功'* ]] || fail "$core_file menu does not claim success for unknown state"

    # The noninteractive command remains prompt-free and waits for OpenRC status.
    is_systemd=
    is_openrc=1
    service_state=inactive
    service_final_state=active
    service_action_status=0
    menu_output=
    : >"$service_calls_file"
    main start || fail "$core_file CLI start should succeed without interaction"
    [[ $(cat "$service_calls_file") == $'sing-box start\nsing-box status' ]] || fail "$core_file CLI waits for and verifies OpenRC start: $(cat "$service_calls_file")"
    [[ $menu_output == *'启动服务成功'* && $menu_output == *'运行中'* ]] || fail "$core_file CLI reports confirmed start: $menu_output"

    # OpenRC startup failure is reported with its service error log location.
    service_state=inactive
    service_final_state=failed
    service_action_status=1
    menu_output=
    : >"$service_calls_file"
    if main start; then fail "$core_file CLI must report OpenRC startup failure"; fi
    [[ $menu_output == *'启动服务未达到目标状态'* && $menu_output == *'/var/log/sing-box/error.log'* ]] || fail "$core_file CLI points to OpenRC error log: $menu_output"

    service_state=active
    service_final_state=unknown
    service_action_status=0
    menu_output=
    : >"$service_calls_file"
    if main restart; then fail "$core_file CLI must report unknown OpenRC restart status"; fi
    [[ $menu_output == *'无法确认 sing-box 当前状态'* && $menu_output == *'/var/log/sing-box/error.log'* ]] || fail "$core_file CLI explains unknown OpenRC state and logs: $menu_output"
    [[ $menu_output != *'重启服务成功'* ]] || fail "$core_file CLI does not claim success for unknown OpenRC state"

    # The existing optional Caddy target is checked through the same CLI entry point.
    is_systemd=1
    is_openrc=
    service_state=active
    service_final_state=active
    service_action_status=0
    menu_output=
    : >"$service_calls_file"
    main r caddy || fail "$core_file CLI preserves the restart caddy command"
    [[ $(cat "$service_calls_file") == $'restart caddy\nis-active caddy' ]] || fail "$core_file CLI verifies Caddy restart: $(cat "$service_calls_file")"
    [[ $menu_output == *'重启服务成功'* && $menu_output == *'Caddy'* ]] || fail "$core_file CLI reports confirmed Caddy restart: $menu_output"
done

echo 'PASS: service menu and CLI report confirmed systemd and OpenRC results'
