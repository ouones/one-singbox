#!/bin/bash

author=ouones
is_script_name=one-singbox

# bash fonts colors
red='\e[31m'
yellow='\e[33m'
gray='\e[90m'
green='\e[92m'
blue='\e[94m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'

_red() { echo -e "${red}$*${none}"; }
_blue() { echo -e "${blue}$*${none}"; }
_cyan() { echo -e "${cyan}$*${none}"; }
_green() { echo -e "${green}$*${none}"; }
_yellow() { echo -e "${yellow}$*${none}"; }
_magenta() { echo -e "${magenta}$*${none}"; }
_red_bg() { echo -e "\e[41m$*${none}"; }

_rm() {
    rm -rf "$@"
}
_cp() {
    cp -rf "$@"
}
_sed() {
    sed -i "$@"
}
_mkdir() {
    mkdir -p "$@"
}

is_err=$(_red_bg 错误!)
is_warn=$(_red_bg 警告!)

err() {
    echo -e "\n$is_err $*\n"
    [[ $is_dont_auto_exit ]] && return
    exit 1
}

warn() {
    echo -e "\n$is_warn $*\n"
}

# load bash script.
load() {
    . "$is_sh_dir/src/$1"
}

# wget add --no-check-certificate
_wget() {
    [[ $proxy ]] && export https_proxy=$proxy
    wget --no-check-certificate "$@"
}

# apt-get, yum, zypper or apk
cmd=$(type -P apt-get || type -P yum || type -P zypper || type -P apk)

_init_pre_core_dir=${is_core_dir:-}
_init_pre_core_bin=${is_core_bin:-}
_init_pre_conf_dir=${is_conf_dir:-}
_init_pre_log_dir=${is_log_dir:-}
_init_pre_sh_bin=${is_sh_bin:-}
_init_pre_sh_dir=${is_sh_dir:-}
_init_pre_config_json=${is_config_json:-}
_init_pre_caddy_dir=${is_caddy_dir:-}
_init_pre_tls_cer=${is_tls_cer:-}
_init_pre_tls_key=${is_tls_key:-}

is_core=sing-box
is_core_name=sing-box
is_core_dir=/etc/$is_core
[[ $_init_pre_core_dir ]] && is_core_dir=$_init_pre_core_dir
is_core_bin=$is_core_dir/bin/$is_core
is_core_repo=SagerNet/$is_core
is_conf_dir=$is_core_dir/conf
is_log_dir=/var/log/$is_core
is_sh_bin=/usr/local/bin/$is_core
is_sh_dir=$is_core_dir/sh
is_sh_repo=ouones/one-singbox
is_pkg="wget unzip tar qrencode bash"
is_config_json=$is_core_dir/config.json
is_caddy_dir=/etc/caddy
[[ $_init_pre_caddy_dir ]] && is_caddy_dir=$_init_pre_caddy_dir
is_caddy_bin=$(type -P caddy)
[[ ! $is_caddy_bin ]] && is_caddy_bin=/usr/local/bin/caddy
is_caddy_repo=caddyserver/caddy
is_caddyfile=$is_caddy_dir/Caddyfile
is_caddy_conf=$is_caddy_dir/$is_script_name
[[ ! -d $is_caddy_conf && -d $is_caddy_dir/233boy ]] && is_caddy_conf=$is_caddy_dir/233boy
is_systemd=$(type -P systemctl)
is_openrc=$(type -P rc-service)
is_http_port=80
is_https_port=443
is_tls_cer=$is_core_dir/bin/tls.cer
is_tls_key=$is_core_dir/bin/tls.key

[[ $_init_pre_core_bin ]] && is_core_bin=$_init_pre_core_bin
[[ $_init_pre_conf_dir ]] && is_conf_dir=$_init_pre_conf_dir
[[ $_init_pre_log_dir ]] && is_log_dir=$_init_pre_log_dir
[[ $_init_pre_sh_bin ]] && is_sh_bin=$_init_pre_sh_bin
[[ $_init_pre_sh_dir ]] && is_sh_dir=$_init_pre_sh_dir
[[ $_init_pre_config_json ]] && is_config_json=$_init_pre_config_json
[[ $_init_pre_tls_cer ]] && is_tls_cer=$_init_pre_tls_cer
[[ $_init_pre_tls_key ]] && is_tls_key=$_init_pre_tls_key
unset _init_pre_core_dir _init_pre_core_bin _init_pre_conf_dir _init_pre_log_dir \
    _init_pre_sh_bin _init_pre_sh_dir _init_pre_config_json _init_pre_caddy_dir \
    _init_pre_tls_cer _init_pre_tls_key

export LC_ALL=C

init_arch_detect() {
    [[ ${is_arch:-} ]] && return 0
    case $(uname -m) in
    amd64 | x86_64)
        is_arch="amd64"
        ;;
    *aarch64* | *armv8*)
        is_arch="arm64"
        ;;
    *)
        err "当前系统架构不受支持。请使用 amd64/x86_64 或 arm64/aarch64。"
        ;;
    esac
}

init_core_ver() {
    [[ ${is_core_ver:-} ]] && return 0
    if [[ -x $is_core_bin ]]; then
        is_core_ver=$("$is_core_bin" version 2>/dev/null | awk 'NR==1{print $3}')
    fi
    if [[ -z $is_core_ver ]]; then
        is_core_ver=unknown
    fi
    return 0
}

init_tls_keypair() {
    [[ -f $is_tls_cer && -f $is_tls_key ]] && return 0
    [[ -x $is_core_bin ]] || return 0
    local is_tls_tmp=${is_tls_key/key/tmp}
    "$is_core_bin" generate tls-keypair tls -m 456 >"$is_tls_tmp"
    awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' "$is_tls_tmp" >"$is_tls_key"
    awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$is_tls_tmp" >"$is_tls_cer"
    rm -f "$is_tls_tmp"
}

init_caddy_service_probe() {
    is_caddy_service=
    if [[ $is_systemd ]]; then
        if [[ $(systemctl show -p LoadState --value caddy.service 2>/dev/null) == loaded ]]; then
            is_caddy_service=1
        fi
    elif [[ $is_openrc ]]; then
        if [[ -f /etc/init.d/caddy ]]; then
            is_caddy_service=1
        fi
    fi
    return 0
}

init_caddy_probe() {
    local mode=${1:-full}
    [[ -f $is_caddy_bin && -d $is_caddy_dir ]] || return 0
    init_caddy_service_probe
    [[ $is_caddy_service ]] || return 0
    is_caddy=1
    if [[ $mode == full && $is_systemd ]]; then
        if [[ -f /lib/systemd/system/caddy.service && ! $(grep '\-\-adapter caddyfile' /lib/systemd/system/caddy.service) ]]; then
            load systemd.sh
            install_service caddy
            systemctl restart caddy >/dev/null 2>&1 || warn "Caddy 服务自动重启失败，请检查 caddy.service 状态。"
        fi
    fi
    is_caddy_ver=$("$is_caddy_bin" version 2>/dev/null | head -n1 | cut -d " " -f1)
    [[ $mode == version ]] && return 0
    if [[ $mode == full && -f $is_caddyfile ]]; then
        is_tmp_http_port=$(grep -E '^ {2,}http_port|^http_port' "$is_caddyfile" | grep -E -o '[0-9]+')
        is_tmp_https_port=$(grep -E '^ {2,}https_port|^https_port' "$is_caddyfile" | grep -E -o '[0-9]+')
        [[ $is_tmp_http_port ]] && is_http_port=$is_tmp_http_port
        [[ $is_tmp_https_port ]] && is_https_port=$is_tmp_https_port
    fi
    if [[ $(pgrep -f "$is_caddy_bin" 2>/dev/null) ]]; then
        is_caddy_status=$(_green running)
    else
        is_caddy_status=$(_red_bg stopped)
        is_caddy_stop=1
    fi
}

service_status_read() {
    local service=${1:-$is_core} service_status service_status_code
    is_service_state=unknown
    if [[ $is_systemd ]]; then
        if service_status=$(systemctl is-active "$service" 2>/dev/null); then
            service_status_code=0
        else
            service_status_code=$?
        fi
        case "$service_status_code:$service_status" in
            0:active) is_service_state=running ;;
            3:failed) is_service_state=failed ;;
            3:inactive) is_service_state=stopped ;;
        esac
    elif [[ $is_openrc ]]; then
        if rc-service "$service" status >/dev/null 2>&1; then
            service_status_code=0
        else
            service_status_code=$?
        fi
        case $service_status_code in
            0) is_service_state=running ;;
            3 | 4 | 8 | 16) is_service_state=stopped ;;
            32) is_service_state=failed ;;
        esac
    fi
}

core_status_read() {
    service_status_read "$is_core"
    is_core_state=$is_service_state
    is_core_stop=
    case $is_core_state in
        running) is_core_status=$(_green "运行中") ;;
        stopped) is_core_status=$(_red "已停止"); is_core_stop=1 ;;
        failed) is_core_status=$(_red "启动失败"); is_core_stop=1 ;;
        *) is_core_status=$(_red "状态读取失败"); is_core_stop=1 ;;
    esac
}

require_root_for_system_exec() {
    if [[ $EUID != 0 && ${is_core_dir:-} == "/etc/${is_core:-sing-box}" ]]; then
        err "请以 root 用户重新运行此脚本。"
        return 1
    fi
    return 0
}

is_init_loaded=1

init_entry() {
    require_root_for_system_exec || exit 1

    # 清理旧版本遗留在安装目录根部的管理脚本副本。
    if [[ -e $is_sh_dir/core.sh ]]; then
        rm -f "$is_sh_dir/core.sh" 2>/dev/null || warn "无法删除历史根管理脚本: $is_sh_dir/core.sh，该文件仍残留在安装目录中，可能因内容过期而干扰问题排查；请手动删除。"
    fi

    local subcmd=${1:-main}
    case $subcmd in
    h | help | --help | \
    bin | pbk | check | completion | format | generate | geoip | geosite | merge | rule-set | run | tools | \
    start | stop | r | restart)
        is_core_defer_modules=1
        ;;
    ip | get-port | ssss | ss2022 | relay | block-cn | __post-update)
        ;;
    v | ver | version)
        init_core_ver
        init_caddy_probe version
        is_core_defer_modules=1
        ;;
    s | status)
        init_core_ver
        init_caddy_probe status
        is_core_defer_modules=1
        ;;
    i | info | url | qr | debug)
        init_core_ver
        core_status_read
        init_caddy_probe status
        ;;
    d | del | rm | dd | ddel | un | uninstall | dns | fix-caddyfile)
        init_core_ver
        init_caddy_probe status
        ;;
    log | bbr)
        init_core_ver
        init_caddy_probe status
        is_core_defer_modules=1
        ;;
    u | up | update | U | update.sh | reinstall)
        init_arch_detect
        init_core_ver
        init_caddy_probe status
        ;;
    *)
        init_arch_detect
        init_core_ver
        init_tls_keypair
        core_status_read
        init_caddy_probe full
        load log.sh
        log_limit_init || warn "无法启用日志容量维护。请从“系统工具”重新设置日志占用上限。"
        ;;
    esac

    load core.sh
    if declare -p args 2>/dev/null | grep -q '^declare -a '; then
        ((${#args[@]} == 0)) && args=(main)
        main "${args[@]}"
    else
        [[ ! $args ]] && args=main
        local -a _init_args=()
        read -ra _init_args <<<"$args"
        main "${_init_args[@]}"
    fi
}

if [[ ! ${is_init_defs_only:-} ]]; then
    if declare -p args 2>/dev/null | grep -q '^declare -a '; then
        init_entry "${args[0]:-main}"
    else
        init_entry "${args:-main}"
    fi
fi
