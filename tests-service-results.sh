#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

setup_entry_env() {
    local name=$1 mode=$2
    local case_dir="$workdir/$name"
    local root="$case_dir/root"
    local sh_dir="$root/etc/sing-box/sh"
    local entry="$sh_dir/sing-box.sh"
    local bin_dir="$case_dir/bin"

    mkdir -p "$sh_dir/src" "$root/etc/sing-box/bin" "$root/etc/sing-box/conf/.quan-meta" \
        "$root/usr/local/bin" "$root/var/log/sing-box" "$bin_dir"
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

    cat >"$root/etc/sing-box/bin/sing-box" <<'FAKE_CORE'
#!/usr/bin/env bash
[[ $1 == version ]] && printf 'sing-box version 1.14.4\n'
exit 0
FAKE_CORE
    chmod +x "$root/etc/sing-box/bin/sing-box"
    touch "$root/etc/sing-box/qrcode-dependency-checked" "$root/etc/sing-box/bin/tls.cer" "$root/etc/sing-box/bin/tls.key"
    printf '200\n' >"$root/etc/sing-box/log-limit-mb"

    # Build an isolated PATH directory for deterministic init-system detection.
    local tool tool_path
    for tool in bash env awk sed grep cat mkdir rm mv cp head tail cut tr dirname basename readlink jq sleep wc sort uname mktemp flock chmod touch; do
        tool_path=$(command -v "$tool" || true)
        [[ -n $tool_path ]] && ln -sf "$tool_path" "$bin_dir/$tool"
    done
    cat >"$bin_dir/apt-get" <<'FAKE_APT'
#!/usr/bin/env bash
exit 0
FAKE_APT
    chmod +x "$bin_dir/apt-get"

    if [[ $mode == systemd ]]; then
        cat >"$bin_dir/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
if [[ $1 == show && $* == *caddy.service* ]]; then
    printf 'not-found\n'
    exit 0
fi
if [[ $1 == is-active && $2 == --quiet ]]; then
    exit 0
fi
printf '%s\n' "$*" >>"${SERVICE_CALLS_FILE:?}"
if [[ $1 == is-active ]]; then
    state=$(cat "${SERVICE_STATE_FILE:?}" 2>/dev/null || printf 'unknown')
    case $state in
        active) printf 'active\n'; exit 0 ;;
        inactive) printf 'inactive\n'; exit 3 ;;
        failed) printf 'failed\n'; exit 3 ;;
        *) printf 'unknown\n'; exit 1 ;;
    esac
fi
if [[ $1 == start || $1 == stop || $1 == restart ]]; then
    cp "${SERVICE_FINAL_FILE:?}" "${SERVICE_STATE_FILE:?}"
    exit "${SERVICE_ACTION_STATUS:-0}"
fi
exit 0
FAKE_SYSTEMCTL
        chmod +x "$bin_dir/systemctl"
    else
        cat >"$bin_dir/rc-service" <<'FAKE_OPENRC'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SERVICE_CALLS_FILE:?}"
if [[ $2 == status ]]; then
    state=$(cat "${SERVICE_STATE_FILE:?}" 2>/dev/null || printf 'unknown')
    case $state in
        active) exit 0 ;;
        inactive) exit 3 ;;
        failed) exit 32 ;;
        *) exit 1 ;;
    esac
fi
if [[ $2 == start || $2 == stop || $2 == restart ]]; then
    cp "${SERVICE_FINAL_FILE:?}" "${SERVICE_STATE_FILE:?}"
    exit "${SERVICE_ACTION_STATUS:-0}"
fi
exit 0
FAKE_OPENRC
        chmod +x "$bin_dir/rc-service"
    fi

    printf '%s\n' "$case_dir"
}

run_systemd_cases() {
    local case_dir
    case_dir=$(setup_entry_env systemd systemd)
    local entry="$case_dir/root/etc/sing-box/sh/sing-box.sh"
    local calls="$case_dir/calls.log"
    local state_file="$case_dir/state"
    local final_file="$case_dir/final"

    run_menu_choice() {
        local initial=$1 final=$2 action_status=$3 input=$4
        printf '%s\n' "$initial" >"$state_file"
        printf '%s\n' "$final" >"$final_file"
        : >"$calls"
        SERVICE_CALLS_FILE="$calls" SERVICE_STATE_FILE="$state_file" SERVICE_FINAL_FILE="$final_file" \
            SERVICE_ACTION_STATUS="$action_status" PATH="$case_dir/bin" \
            bash -c '
                is_core_dir="$1"
                is_conf_dir="$1/conf"
                is_log_dir="$2"
                is_sh_dir="$3"
                is_sh_bin="$4"
                is_config_json="$1/config.json"
                is_core_bin="$1/bin/sing-box"
                source "$3/src/core.sh"
                service_menu
            ' _ "$case_dir/root/etc/sing-box" "$case_dir/root/var/log/sing-box" "$case_dir/root/etc/sing-box/sh" "$entry" <<<"$input" 2>&1
    }

    # 1. The service menu waits for the operation and verifies that startup reached active.
    menu_output=$(run_menu_choice inactive active 0 $'2\n\n0\n') || fail "menu should accept a confirmed start: $menu_output"
    [[ $(cat "$calls") == $'start sing-box\nis-active sing-box' ]] || fail "menu waits for and verifies start: $(cat "$calls")"
    [[ $menu_output == *'启动服务成功'* && $menu_output == *'运行中'* ]] || fail "menu reports confirmed start: $menu_output"

    # 2. A completed request is a failure when the service remains active after stop.
    if menu_output=$(run_menu_choice active active 0 $'3\ny\n\n0\n'); then
        fail "menu must reject a stop that did not reach inactive"
    fi
    [[ $menu_output == *'停止服务未达到目标状态'* && $menu_output == *'journalctl -u sing-box.service'* ]] || fail "menu reports stop failure with logs: $menu_output"
    [[ $(cat "$calls") == $'stop sing-box\nis-active sing-box' ]] || fail "menu verifies a completed stop: $(cat "$calls")"

    # 3. Unknown status is not success, even when the service manager accepted restart.
    if menu_output=$(run_menu_choice active unknown 0 $'4\ny\n\n0\n'); then
        fail "menu must not report unknown restart status as success"
    fi
    [[ $menu_output == *'无法确认 sing-box 当前状态'* && $menu_output == *'journalctl -u sing-box.service'* ]] || fail "menu explains unknown state and logs: $menu_output"
    [[ $menu_output != *'重启服务成功'* ]] || fail "menu does not claim success for unknown state"

    # 4. Also exercise full sing-box.sh main-menu -> service_menu -> start end-to-end.
    printf 'inactive\n' >"$state_file"
    printf 'active\n' >"$final_file"
    : >"$calls"
    menu_output=$(printf '3\n2\n\n0\nq\n' | SERVICE_CALLS_FILE="$calls" SERVICE_STATE_FILE="$state_file" \
        SERVICE_FINAL_FILE="$final_file" SERVICE_ACTION_STATUS=0 PATH="$case_dir/bin" bash "$entry" 2>&1) \
        || fail "sing-box.sh service menu start failed: $menu_output"
    [[ $menu_output == *'启动服务成功'* && $menu_output == *'运行中'* ]] || fail "sing-box.sh service menu missing start result: $menu_output"

    # 5. The existing optional Caddy target is checked through the CLI entry point.
    printf 'active\n' >"$state_file"
    printf 'active\n' >"$final_file"
    : >"$calls"
    cli_output=$(SERVICE_CALLS_FILE="$calls" SERVICE_STATE_FILE="$state_file" SERVICE_FINAL_FILE="$final_file" \
        SERVICE_ACTION_STATUS=0 PATH="$case_dir/bin" bash "$entry" r caddy 2>&1) \
        || fail "CLI preserves the restart caddy command: $cli_output"
    [[ $(cat "$calls") == $'restart caddy\nis-active caddy' ]] || fail "CLI verifies Caddy restart: $(cat "$calls")"
    [[ $cli_output == *'重启服务成功'* && $cli_output == *'Caddy'* ]] || fail "CLI reports confirmed Caddy restart: $cli_output"
}

run_openrc_cases() {
    local case_dir
    case_dir=$(setup_entry_env openrc openrc)
    local entry="$case_dir/root/etc/sing-box/sh/sing-box.sh"
    local calls="$case_dir/calls.log"
    local state_file="$case_dir/state"
    local final_file="$case_dir/final"

    # 1. The noninteractive command remains prompt-free and waits for OpenRC status.
    printf 'inactive\n' >"$state_file"
    printf 'active\n' >"$final_file"
    : >"$calls"
    cli_output=$(SERVICE_CALLS_FILE="$calls" SERVICE_STATE_FILE="$state_file" SERVICE_FINAL_FILE="$final_file" \
        SERVICE_ACTION_STATUS=0 PATH="$case_dir/bin" bash "$entry" start 2>&1) \
        || fail "CLI start should succeed without interaction: $cli_output"
    [[ $(cat "$calls") == $'sing-box start\nsing-box status' ]] || fail "CLI waits for and verifies OpenRC start: $(cat "$calls")"
    [[ $cli_output == *'启动服务成功'* && $cli_output == *'运行中'* ]] || fail "CLI reports confirmed start: $cli_output"

    # 2. OpenRC startup failure is reported with its service error log location.
    printf 'inactive\n' >"$state_file"
    printf 'failed\n' >"$final_file"
    : >"$calls"
    if cli_output=$(SERVICE_CALLS_FILE="$calls" SERVICE_STATE_FILE="$state_file" SERVICE_FINAL_FILE="$final_file" \
        SERVICE_ACTION_STATUS=1 PATH="$case_dir/bin" bash "$entry" start 2>&1); then
        fail "CLI must report OpenRC startup failure"
    fi
    [[ $cli_output == *'启动服务未达到目标状态'* && $cli_output == *'/var/log/sing-box/error.log'* ]] || fail "CLI points to OpenRC error log: $cli_output"

    # 3. Unknown OpenRC restart status must not claim success.
    printf 'active\n' >"$state_file"
    printf 'unknown\n' >"$final_file"
    : >"$calls"
    if cli_output=$(SERVICE_CALLS_FILE="$calls" SERVICE_STATE_FILE="$state_file" SERVICE_FINAL_FILE="$final_file" \
        SERVICE_ACTION_STATUS=0 PATH="$case_dir/bin" bash "$entry" restart 2>&1); then
        fail "CLI must report unknown OpenRC restart status"
    fi
    [[ $cli_output == *'无法确认 sing-box 当前状态'* && $cli_output == *'/var/log/sing-box/error.log'* ]] || fail "CLI explains unknown OpenRC state and logs: $cli_output"
    [[ $cli_output != *'重启服务成功'* ]] || fail "CLI does not claim success for unknown OpenRC state"
}

run_systemd_cases
run_openrc_cases

echo 'PASS: service menu and CLI report confirmed systemd and OpenRC results'
