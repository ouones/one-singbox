#!/bin/bash

_core_resolve_src_dir() {
    local dir
    if [[ ${BASH_SOURCE[0]:-} ]]; then
        dir=$(dirname -- "${BASH_SOURCE[0]}")
        if [[ -f $dir/meta.sh || -f $dir/init.sh ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
    fi
    if [[ ${is_sh_dir:-} && ( -f $is_sh_dir/src/meta.sh || -f $is_sh_dir/src/init.sh ) ]]; then
        printf '%s\n' "$is_sh_dir/src"
        return 0
    fi
    return 1
}

_core_src_dir=$(_core_resolve_src_dir || true)

if [[ ! ${is_init_loaded:-} ]]; then
    if [[ $_core_src_dir && -f $_core_src_dir/init.sh ]]; then
        is_init_defs_only=1 . "$_core_src_dir/init.sh"
        unset is_init_defs_only
    fi
fi

[[ ! $cmd ]] && err "未检测到受支持的包管理器 (apt-get、yum、zypper 或 apk)。"

[[ ! $is_systemd && ! $is_openrc ]] && {
    err "未检测到 systemd 或 OpenRC 服务管理器。请先安装并启用其中之一。"
}

shared_config_lock() {
    # Keep the existing lock path so concurrent processes coordinate across updates.
    local state_dir="$is_core_dir/.frontend-state"
    if [[ ${shared_config_lock_depth:-0} -gt 0 && ${shared_config_lock_fd:-} ]]; then
        shared_config_lock_depth=$((shared_config_lock_depth + 1))
        return 0
    fi
    command -v flock >/dev/null 2>&1 || { shared_config_error='缺少 flock，无法协调公共配置操作'; return 1; }
    [[ ! -L $state_dir ]] && mkdir -p "$state_dir" && [[ ! -L $state_dir && -d $state_dir ]] && chmod 700 "$state_dir" || {
        shared_config_error='无法创建或保护公共配置锁目录'; return 1;
    }
    exec {shared_config_lock_fd}>"$state_dir/lock" || { shared_config_error='无法打开公共配置锁'; return 1; }
    flock -n "$shared_config_lock_fd" || {
        exec {shared_config_lock_fd}>&-
        shared_config_error='其他公共配置操作正在进行'; return 1;
    }
    shared_config_lock_depth=1
}

shared_config_unlock() {
    if [[ $shared_config_lock_fd ]]; then
        if [[ ${shared_config_lock_depth:-1} -gt 1 ]]; then
            shared_config_lock_depth=$((shared_config_lock_depth - 1))
            return 0
        fi
        flock -u "$shared_config_lock_fd" 2>/dev/null || :
        exec {shared_config_lock_fd}>&-
        shared_config_lock_fd=
        shared_config_lock_depth=0
    fi
}

core_load_module() {
    local mod=$1
    local src_dir=${_core_src_dir:-}
    local flag="_core_loaded_${mod//[^a-zA-Z0-9_]/_}"
    [[ ${!flag:-} == 1 ]] && return 0
    if [[ ! $src_dir ]]; then
        src_dir=$(_core_resolve_src_dir) || return 1
        _core_src_dir=$src_dir
    fi
    if [[ -f $src_dir/${mod}.sh ]]; then
        . "$src_dir/${mod}.sh" || return 1
        printf -v "$flag" '%s' 1
    fi
    return 0
}

core_load_modules() {
    local mod
    for mod in qrcode-deps meta uri route node relay; do
        core_load_module "$mod" || return 1
    done
    _core_modules_loaded=1
    unset is_core_defer_modules
    return 0
}

if [[ ${is_core_defer_modules:-0} != 1 ]]; then
    core_load_modules
fi

protocol_list=(
    TUIC
    Trojan
    Hysteria2
    VMess-WS
    VMess-TCP
    VMess-HTTP
    VMess-QUIC
    Shadowsocks
    VMess-H2-TLS
    VMess-WS-TLS
    VLESS-H2-TLS
    VLESS-WS-TLS
    Trojan-H2-TLS
    Trojan-WS-TLS
    VMess-HTTPUpgrade-TLS
    VLESS-HTTPUpgrade-TLS
    Trojan-HTTPUpgrade-TLS
    VLESS-REALITY
    VLESS-HTTP2-REALITY
    AnyTLS
    # Direct
    Socks
    Snell
)
ss_method_list=(
    aes-128-gcm
    aes-256-gcm
    chacha20-ietf-poly1305
    xchacha20-ietf-poly1305
    2022-blake3-aes-128-gcm
    2022-blake3-aes-256-gcm
    2022-blake3-chacha20-poly1305
)
mainmenu=(
    "节点管理"
    "端口转发"
    "内核管理"
    "更新"
    "系统设置"
    "帮助反馈"
    "关于"
    "卸载"
)
info_list=(
    "协议 (protocol)"
    "地址 (address)"
    "端口 (port)"
    "用户 ID (UUID)"
    "传输方式 (network)"
    "传输类型 (type)"
    "主机名 (host)"
    "路径 (path)"
    "传输层安全 (TLS)"
    "应用层协议协商 (Alpn)"
    "密码 (password)"
    "加密方式 (encryption)"
    "分享链接"
    "目标地址"
    "目标端口"
    "流控 (flow)"
    "SNI (serverName)"
    "指纹 (Fingerprint)"
    "公钥 (Public key)"
    "用户名"
    "跳过证书验证 (allowInsecure)"
    "拥塞控制算法 (congestion_control)"
    "版本 (version)"
    "PSK"
    "混淆模式 (obfs_mode)"
    "运行模式 (mode)"
    "出口方式"
    "备注"
)
change_labels=(
    "协议|更改协议"
    "监听端口|更改端口"
    "域名|更改域名"
    "路径|更改路径"
    "密码|更改密码"
    "UUID|更改 UUID"
    "加密方式|更改加密方式"
    "目标地址|更改目标地址"
    "目标端口|更改目标端口"
    "密钥|更改密钥"
    "SNI|更改 SNI (serverName)"
    "反向代理域名|更改反向代理目标域名"
    "用户名|更改用户名"
    "节点名称|更改节点名称"
    "出口方式|更改节点出站方式"
    "分享地址|更改分享地址"
    "查看分享链接|查看分享链接"
    "PSK|更改 PSK"
    "Snell 版本|更改 Snell 版本"
    "混淆模式|更改 Snell 混淆模式"
    "运行模式|更改 Snell 运行模式"
    "备注|更改备注"
)
# shuf fallback for systems without shuf (e.g., Alpine BusyBox)
if ! type -P shuf &>/dev/null; then
    shuf() {
        local min max n
        while [[ $# -gt 0 ]]; do
            case $1 in
            -i) IFS=- read min max <<<"$2"; shift 2 ;;
            -n) n=$2; shift 2 ;;
            -n[0-9]*) n=${1#-n}; shift ;;
            *) shift ;;
            esac
        done
        echo $(( RANDOM % (max - min + 1) + min ))
    }
fi

is_random_ss_method=${ss_method_list[$(shuf -i 4-6 -n1)]} # random only use ss2022

msg() {
    echo -e "$@"
}

msg_ul() {
    echo -e "\e[4m$*\e[0m"
}

# Read interactive input. During a menu operation the operation subprocess exits
# immediately on Ctrl+C so no later form step or business action can run.
interactive_read() {
    local previous_int status
    if [[ ${is_interactive_operation:-0} != 1 ]]; then
        builtin read "$@"
        return
    fi
    interactive_input_active=1
    previous_int=$(trap -p INT)
    trap 'exit 130' INT
    [[ $interactive_cancel_requested ]] && exit 130
    builtin read "$@"
    status=$?
    interactive_input_active=
    if [[ $previous_int ]]; then
        eval "$previous_int"
    else
        trap - INT
    fi
    return "$status"
}

# Read a form field. When the input stream ends (Ctrl+D / EOF) the current flow
# aborts instead of re-prompting forever on empty replies.
form_read() {
    interactive_read "$@" && return 0
    msg '\n输入已结束，已取消当前操作。'
    [[ ${is_interactive_operation:-0} == 1 ]] && exit 1
    return 1
}

# Leave a form input without writing anything. An interactive menu session aborts
# the running operation exactly like Ctrl+C; any other session ends the command
# with a failure so no later form step or business action can run.
form_cancel() {
    if [[ ${is_form_cancel_return:-0} == 1 ]]; then
        msg '\n已取消当前操作，未改动任何配置。'
        return 2
    fi
    if [[ ${is_interactive_operation:-0} == 1 ]]; then
        exit 130
    fi
    msg '\n已取消当前操作，未改动任何配置。'
    [[ $is_dont_auto_exit ]] && return 1
    exit 1
}

# Node name inputs keep the established contract that 0 is a literal name, so
# the shared 0-cancel token must not swallow it on those pages.
form_literal_zero_allowed() {
    case $1 in
    node_name | is_new_name | is_custom_node_name) return 0 ;;
    esac
    return 1
}

# Every manual form page names its cancel commands right above the prompt.
form_cancel_tip() {
    if [[ $1 == literal_zero ]]; then
        msg "提示：输入 q 或按 Ctrl+C 取消当前操作，不会改动任何配置；本页输入 0 会直接作为名称保存。"
    else
        msg "提示：输入 0 或 q 取消当前操作（Ctrl+C 同效），不会改动任何配置。"
    fi
}

run_interactive_operation() {
    local previous_int status
    previous_int=$(trap -p INT)
    trap ':' INT
    is_interactive_operation=1
    interactive_cancel_requested=
    (
        trap 'interactive_cancel_requested=1; [[ $interactive_input_active ]] && exit 130' INT
        "$@"
    )
    status=$?
    is_interactive_operation=
    if [[ $status == 130 ]]; then
        msg '\n已取消当前操作\n'
        menu_pause
    fi
    if [[ $previous_int ]]; then
        eval "$previous_int"
    else
        trap - INT
    fi
    [[ $status == 130 ]] && return 2
    return "$status"
}

# confirm a high-risk action; Enter (or any non-y answer) cancels.
confirm_action() {
    local answer IFS=
    echo -ne "$1 [y/N]: "
    interactive_read -r answer
    [[ $answer == y || $answer == Y ]]
}

confirm_exact_yes() {
    local answer IFS=
    echo -ne "$1 [仅输入 YES 确认]: "
    interactive_read -r answer
    [[ $answer == YES ]]
}

menu_system_impact() {
    local object=$1 impact=$2 restart_core=$3
    shift 3
    msg "\n------------- 系统影响确认 -------------"
    msg "操作对象：$object"
    msg "主要影响：$impact"
    msg "是否重启核心：$restart_core"
    if ! confirm_action "确认执行上述操作"; then
        msg "已取消。"
        return 2
    fi
    "$@"
}

show_list() {
    PS3=''
    COLUMNS=1
    select i in "$@"; do echo; done </dev/null &
    wait
    # i=0
    # for v in "$@"; do
    #     ((i++))
    #     echo "$i) $v"
    # done
    # echo

}

# ask input a string or pick a option for list.
ask() {
    local outbound_display=
    local is_secret_input=
    local ask_status=0
    case $1 in
    set_ss_method)
        is_tmp_list=("${ss_method_list[@]}")
        is_default_arg=$is_random_ss_method
        is_opt_msg="\n选择加密方式:\n"
        is_opt_input_msg="(默认\e[92m $is_default_arg\e[0m):"
        is_ask_set=ss_method
        ;;
    set_outbound_mode)
        is_tmp_list=("IPv6 优先" "IPv4 优先" "仅 IPv4" "仅 IPv6" "Shadowsocks 出口" "VLESS 出口")
        outbound_display=$(current_outbound_mode_display "$is_config_file")
        is_ask_set=is_outbound_mode
        ;;
    string)
        is_ask_set=$2
        is_opt_input_msg=$3
        ;;
    list)
        is_ask_set=$2
        if [[ ! $is_tmp_list ]]; then
            read -ra is_tmp_list <<<"$3"
        fi
        is_opt_msg=$4
        is_opt_input_msg=$5
        ;;
    esac
    case $is_ask_set in
    *pass* | *psk* | *private_key* | *uuid* | *token* | *secret*) is_secret_input=1 ;;
    esac
    if [[ $is_ask_set == is_outbound_mode ]]; then
        printf '\n当前出口方式: %s\n' "$outbound_display"
        msg "直连可选 V6 优先、V4 优先、仅 V4 或仅 V6；代理出口可选 Shadowsocks 或 VLESS。"
        printf '\n选择出口方式:\n'
    else
        msg "$is_opt_msg"
    fi
    [[ ! $is_opt_input_msg ]] && is_opt_input_msg="请输入选项编号 [\e[91m1-${#is_tmp_list[@]}\e[0m]:"
    [[ $is_tmp_list ]] && show_list "${is_tmp_list[@]}"
    if form_literal_zero_allowed "$is_ask_set"; then
        form_cancel_tip literal_zero
    else
        form_cancel_tip
    fi
    while :; do
        echo -ne "$is_opt_input_msg"
        if [[ $is_secret_input ]]; then
            form_read -rs REPLY || { ask_status=1; break; }
            echo
        else
            form_read -r REPLY || { ask_status=1; break; }
        fi
        if [[ $REPLY == q || $REPLY == Q ]]; then
            form_cancel
            ask_status=1
            break
        fi
        if [[ $REPLY == 0 ]] && ! form_literal_zero_allowed "$is_ask_set"; then
            form_cancel
            ask_status=1
            break
        fi
        [[ ! $REPLY && $is_default_arg ]] && export "$is_ask_set=$is_default_arg" && break
        if [[ ! $is_tmp_list ]]; then
            [[ $(grep port <<<"$is_ask_set") ]] && {
                [[ ! $(is_test port "$REPLY") ]] && {
                    msg "$is_err 请输入正确的端口, 可选(1-65535)"
                    continue
                }
                if [[ $(is_test port_used "$REPLY") && $is_ask_set != 'door_port' ]]; then
                    msg "$is_err 无法使用 ($REPLY) 端口."
                    continue
                fi
            }
            [[ $(grep path <<<"$is_ask_set") && ! $(is_test path "$REPLY") ]] && {
                [[ ! $tmp_uuid ]] && get_uuid
                msg "$is_err 请输入正确的路径, 例如: /$tmp_uuid"
                continue
            }
            [[ $(grep uuid <<<"$is_ask_set") && ! $(is_test uuid "$REPLY") ]] && {
                [[ ! $tmp_uuid ]] && get_uuid
                msg "$is_err 请输入正确的 UUID, 例如: $tmp_uuid"
                continue
            }
            [[ $(grep ^y$ <<<"$is_ask_set") ]] && {
                [[ $(grep -i ^y$ <<<"$REPLY") ]] && break
                msg "请输入 y 确认，或按 Ctrl+C 取消。"
                continue
            }
            if [[ $REPLY ]]; then
                export "$is_ask_set=$REPLY"
                if [[ $is_secret_input ]]; then
                    msg "已设置（输入内容已隐藏）"
                else
                    msg "使用: ${!is_ask_set}"
                fi
                break
            fi
        else
            if [[ $(is_test number "$REPLY") ]]; then
                if [[ $is_ask_set == is_outbound_mode ]]; then
                    case $REPLY in
                    1) is_ask_result="V6优先" ;;
                    2) is_ask_result="V4优先" ;;
                    3) is_ask_result="仅V4" ;;
                    4) is_ask_result="仅V6" ;;
                    5) is_ask_result="SS 出站" ;;
                    6) is_ask_result="VLESS 出站" ;;
                    esac
                else
                    is_ask_result=${is_tmp_list[$REPLY - 1]}
                fi
            fi
            if [[ $is_ask_result ]]; then
                export "$is_ask_set=$is_ask_result"
                if [[ $is_ask_set == is_outbound_mode ]]; then
                    msg "选择: ${is_tmp_list[$REPLY - 1]}"
                else
                    msg "选择: ${!is_ask_set}"
                fi
                break
            fi
        fi

        if [[ $is_tmp_list ]]; then
            msg "$is_err 输入无效，请输入 1-${#is_tmp_list[@]} 中的编号。"
        else
            msg "$is_err 输入无效，请按提示重新输入。"
        fi
    done
    unset is_opt_msg is_opt_input_msg is_tmp_list is_ask_result is_default_arg
    return "$ask_status"
}

select_ss_method() {
    local status previous_default=${is_default_arg-} had_default=${is_default_arg+x}
    is_default_arg=$is_random_ss_method
    menu_select parent ss_method "\n选择加密方式:\n" "${ss_method_list[@]}"
    status=$?
    if [[ $had_default ]]; then
        is_default_arg=$previous_default
    else
        unset is_default_arg
    fi
    return "$status"
}

select_snell_mode() {
    local prompt=$1 status
    menu_select parent is_new_snell_mode "$prompt" default unshaped unsafe-raw
    status=$?
    return "$status"
}

select_snell_obfs_mode() {
    local prompt=$1 status
    menu_select parent is_new_snell_obfs_mode "$prompt" none http
    status=$?
    return "$status"
}

current_outbound_mode_display() {
    local cfg=$1 mode mode_label name server port tls_enabled insecure tls_status=
    [[ $cfg ]] || {
        printf '%s\n' 未设置
        return
    }
    mode=$(meta_get "$cfg" '.outbound_mode')
    [[ $mode ]] || mode="V4优先"
    mode_label=$(outbound_mode_display_name "$mode")
    if [[ $mode == 'SS 出站' || $mode == 'VLESS 出站' ]]; then
        if [[ $mode == 'VLESS 出站' ]]; then
            tls_enabled=$(meta_get "$cfg" '.outbound_proxy.config.tls.enabled')
            if [[ $tls_enabled == true ]]; then
                insecure=$(meta_get "$cfg" '.outbound_proxy.config.tls.insecure')
                if [[ $insecure == true ]]; then
                    tls_status='，跳过 TLS 证书校验'
                else
                    tls_status='，校验 TLS 证书'
                fi
            fi
        fi
        name=$(meta_get "$cfg" '.outbound_proxy.name')
        [[ $name ]] && {
            printf '%s\n' "$mode_label ($name)$tls_status"
            return
        }
        if [[ $mode == 'SS 出站' ]]; then
            name=$(meta_get "$cfg" '.outbound_ss_name')
            [[ $name ]] && {
                printf '%s\n' "$mode_label ($name)"
                return
            }
        fi
        server=$(meta_get "$cfg" '.outbound_proxy.config.server')
        port=$(meta_get "$cfg" '.outbound_proxy.config.server_port')
        if [[ $mode == 'SS 出站' ]]; then
            [[ ! $server ]] && server=$(meta_get "$cfg" '.outbound_ss_server')
            [[ ! $port ]] && port=$(meta_get "$cfg" '.outbound_ss_port')
        fi
        [[ $server == *:* && $server != \[*\] ]] && server="[$server]"
        [[ $server && $port ]] && {
            printf '%s\n' "$mode_label ($server:$port)$tls_status"
            return
        }
    fi
    printf '%s\n' "$mode_label${tls_status:-}"
}

# Read one proxy share link for the exit-mode page. A malformed link is
# re-prompted instead of dropping back to the node menu, an empty reply reuses
# the cached proxy when one exists, and 0/q return the caller to the exit-mode
# selection (exit code 2).
read_proxy_link() {
    local out_var=$1 proxy_type=$2 label=$3 can_reuse=$4
    local IFS= link= link_prompt= parse_error=
    if [[ $can_reuse == 1 ]]; then
        link_prompt="请输入 $label 分享链接 (回车保留当前配置；输入内容隐藏):"
    else
        link_prompt="请输入 $label 分享链接 (输入内容隐藏):"
    fi
    form_cancel_tip
    while :; do
        echo -ne "$link_prompt"
        form_read -rs link || { err "未收到 $label 分享链接，已取消当前操作。"; return 1; }
        echo
        case $link in
        0 | q | Q)
            printf -v "$out_var" '%s' ''
            return 2
            ;;
        '')
            if [[ $can_reuse == 1 ]]; then
                printf -v "$out_var" '%s' ''
                return 0
            fi
            msg "$is_err 没有可复用的 $label 配置，请粘贴 $label 分享链接（输入 0 返回选择出口方式）。"
            continue
            ;;
        esac
        if parse_proxy_uri "$proxy_type" "$link"; then
            msg "已接收分享链接（输入内容已隐藏）。"
            printf -v "$out_var" '%s' "$link"
            return 0
        fi
        if [[ $proxy_type == ss ]]; then
            parse_error=${outbound_proxy_parse_error:-SS 链接格式或参数无效，请检查地址、端口和加密方式.}
        else
            parse_error=${outbound_proxy_parse_error:-VLESS 链接格式或参数无效}
        fi
        msg "$is_err $parse_error"
        msg "可重新粘贴 $label 分享链接，或输入 0 返回选择出口方式。"
    done
}

edit_node_outbound_mode() {
    local metadata_file proxy_config= proxy_name= proxy_json= current_proxy_type outbound_status link_status
    local can_reuse= link_used=
    while :; do
        printf '\n当前出口方式: %s\n' "$(current_outbound_mode_display "$is_config_file")"
        msg "直连可选 V6 优先、V4 优先、仅 V4 或仅 V6；代理出口可选 Shadowsocks 或 VLESS。"
        menu_select parent is_outbound_mode "\n选择出口方式:\n" "IPv6 优先" "IPv4 优先" "仅 IPv4" "仅 IPv6" "Shadowsocks 出口" "VLESS 出口"
        outbound_status=$?
        [[ $outbound_status == 2 ]] && return 2
        [[ $outbound_status == 0 ]] || return 1
        case $is_outbound_mode in
        'IPv6 优先') is_outbound_mode='V6优先' ;;
        'IPv4 优先') is_outbound_mode='V4优先' ;;
        '仅 IPv4') is_outbound_mode='仅V4' ;;
        '仅 IPv6') is_outbound_mode='仅V6' ;;
        'Shadowsocks 出口') is_outbound_mode='SS 出站' ;;
        'VLESS 出口') is_outbound_mode='VLESS 出站' ;;
        esac
        proxy_config=
        proxy_name=
        link_used=
        if [[ $is_outbound_mode == 'SS 出站' || $is_outbound_mode == 'VLESS 出站' ]]; then
            proxy_json=
            metadata_file=$(meta_file "$is_config_file")
            if outbound_proxy_from_metadata "$is_config_file" "$metadata_file"; then
                proxy_json=$outbound_proxy_json
            fi
            current_proxy_type=$(jq -r '.config.type // empty' <<<"$proxy_json" 2>/dev/null)
            if [[ $is_outbound_mode == 'SS 出站' ]]; then
                can_reuse=
                [[ $current_proxy_type == shadowsocks ]] && can_reuse=1
                read_proxy_link is_outbound_ss_uri ss Shadowsocks "$can_reuse"
                link_status=$?
            else
                can_reuse=
                [[ $current_proxy_type == vless ]] && can_reuse=1
                read_proxy_link is_outbound_vless_uri vless VLESS "$can_reuse"
                link_status=$?
            fi
            if [[ $link_status == 2 ]]; then
                msg "\n已返回选择出口方式。\n"
                continue
            fi
            [[ $link_status == 0 ]] || return 1
            if [[ $is_outbound_mode == 'SS 出站' && $is_outbound_ss_uri ]]; then
                link_used=1
            elif [[ $is_outbound_mode == 'VLESS 出站' && $is_outbound_vless_uri ]]; then
                link_used=1
            fi
            if [[ $link_used ]]; then
                proxy_config=$outbound_proxy_config_json
                proxy_name=$outbound_proxy_name
            fi
        fi
        apply_node_outbound_mode "$is_config_file" "$is_outbound_mode" "$proxy_config" "$proxy_name" || { err "$outbound_apply_error"; return 1; }
        msg_outbound_mode_display "配置已应用:" "$is_config_file"
        return 0
    done
}

# create file
create() {
    case $1 in
    server)
        local previous_config_file is_snell_tmp_file node_migration_applied new_node_lock new_node_transport
        [[ $is_change ]] && previous_config_file=$is_config_file
        is_tls=none
        get new
        # listen
        is_listen='listen: "::"'
        [[ $is_change && $is_listen_addr && ! $host ]] && is_listen="listen: $(jq -Rn --arg addr "$is_listen_addr" '$addr')"
        # file name: protocol + port
        is_config_name=${2}-${port}.json
        [[ ${2,,} == snell ]] && is_config_name=snell-${port}.json
        [[ $host ]] && is_listen='listen: "127.0.0.1"'
        is_json_file=$is_conf_dir/$is_config_name
        [[ ${2,,} == *reality* && ! $is_servername ]] && is_servername=$(reality_sni_select)
        # get json
        [[ $is_change || ! $json_str ]] && get protocol "$2"
        [[ $net == "reality" ]] && is_add_public_key=",outbounds:[{type:\"direct\"},{tag:\"public_key_$is_public_key\",type:\"direct\"}]"
        if [[ ${2,,} == snell ]]; then
            if [[ $snell_version == 6 ]]; then
                is_new_json=$(jq -n \
                    --arg tag "$is_config_name" \
                    --argjson port "$port" \
                    --arg psk "$snell_psk" \
                    --arg mode "$snell_mode" \
                    --argjson version 6 \
                    '{inbounds:[{tag:$tag,type:"snell",listen:"::",listen_port:$port,version:$version,psk:$psk,mode:$mode}]}')
            else
                is_new_json=$(jq -n \
                    --arg tag "$is_config_name" \
                    --argjson port "$port" \
                    --arg psk "$snell_psk" \
                    --arg obfs_mode "$snell_obfs_mode" \
                    --argjson version 5 \
                    '{inbounds:[{tag:$tag,type:"snell",listen:"::",listen_port:$port,version:$version,psk:$psk,obfs_mode:$obfs_mode}]}')
            fi
            is_snell_tmp_file=$(mktemp "$is_conf_dir/.snell-XXXXXX") || { err "无法创建 Snell 临时配置文件."; return 1; }
            printf '%s\n' "$is_new_json" >"$is_snell_tmp_file"
            if ! "$is_core_bin" check -c "$is_snell_tmp_file" &>/dev/null; then
                rm -f "$is_snell_tmp_file"
                err "Snell 配置校验失败."
                return 1
            fi
        else
            is_new_json=$(jq "{inbounds:[{tag:\"$is_config_name\",type:\"$is_protocol\",$is_listen,listen_port:$port,$json_str}]$is_add_public_key}" <<<{})
        fi
        [[ $is_test_json ]] && {
            [[ $is_snell_tmp_file ]] && rm -f "$is_snell_tmp_file"
            return
        }
        # only show json, dont save to file.
        [[ $is_gen ]] && {
            [[ $is_snell_tmp_file ]] && rm -f "$is_snell_tmp_file"
            msg
            jq <<<"$is_new_json"
            msg
            return
        }
        node_migration_applied=
        if [[ ! $is_change || ! $previous_config_file ]]; then
            shared_config_lock || { err "${shared_config_error:-无法获取公共配置锁}"; return 1; }
            new_node_lock=1
            if [[ ${2,,} != snell ]]; then
                is_used_port=
                if [[ $(node_port_used "$port" "$is_new_protocol") ]]; then
                    shared_config_unlock
                    err "无法使用 ($port) 端口"
                    return 1
                fi
            fi
            new_node_transport=$(node_protocol_transport "$is_new_protocol")
            if config_port_used "$port" "$previous_config_file" "$new_node_transport"; then
                shared_config_unlock
                err "节点监听端口 ($port) 已被现有配置占用"
                return 1
            fi
        fi
        if [[ $is_change && $previous_config_file ]]; then
            [[ $is_snell_tmp_file ]] && rm -f "$is_snell_tmp_file"
            apply_node_config_lifecycle replace "$previous_config_file" "$is_config_name" "$is_new_json" || { err "$node_lifecycle_error"; return 1; }
            node_migration_applied=1
            is_config_file=$is_config_name
            msg "\n节点配置已应用: $(_green "$is_config_name")\n"
            if [[ $is_caddy && $is_change && $old_host ]]; then
                is_del_host=$old_host
                if [[ $host != "$old_host" && -f $is_caddy_conf/$is_del_host.conf ]]; then
                    rm -rf "$is_caddy_conf/$is_del_host.conf" "$is_caddy_conf/$is_del_host.conf.add"
                fi
            fi
        elif [[ ${2,,} == snell ]]; then
            if ! mv -f "$is_snell_tmp_file" "$is_json_file"; then
                rm -f "$is_snell_tmp_file"
                [[ $new_node_lock ]] && shared_config_unlock
                err "保存 Snell 配置失败, 原有配置未改变."
                return 1
            fi
        else
            cat <<<"$is_new_json" >"$is_json_file"
        fi
        [[ $is_config_name ]] && is_config_file=$is_config_name
        [[ $is_change && $previous_config_file && $previous_config_file != "$is_config_name" ]] && msg "\n配置文件修改成功: $(_green "$previous_config_file") -> $(_green "$is_config_name")\n"
        if [[ ! $is_change ]]; then
            meta_set "$is_config_name" outbound_mode "V4优先"
        fi
        if [[ ! $node_migration_applied ]]; then
            sync_runtime_node_outbound_modes "$is_config_json" "$is_config_json" "$is_conf_dir" 1 || {
                [[ ! $is_change ]] && rm -f "$is_json_file" "$is_conf_dir/.quan-meta/$is_config_name.meta.json"
                [[ $new_node_lock ]] && shared_config_unlock
                err "节点代理路由同步失败: ${runtime_sync_error:-未知错误}"
                return 1
            }
            if [[ $is_new_install ]]; then
                # config.json
                create config.json
            fi
        fi
        [[ $new_node_lock ]] && shared_config_unlock
        # caddy auto tls
        if [[ $is_caddy && $host && ! $is_no_auto_tls ]]; then
            create caddy "$net" || return $?
        fi
        # restart core
        if [[ ! $node_migration_applied ]]; then
            manage_restart_checked "" "节点配置已保存" || return 1
        fi
        return 0
        ;;
    client)
        is_tls=tls
        is_client=1
        get info "$2"
        [[ ! $is_client_id_json ]] && { err "($is_config_name) 不支持生成客户端配置."; return 1; }
        is_new_json=$(jq --arg tag "$is_config_name" --arg proto "$is_protocol" "{outbounds:[{tag:\$tag,protocol:\$proto,$is_client_id_json,$is_stream}]}" <<<{})
        msg
        jq <<<"$is_new_json"
        msg
        ;;
    caddy)
        shared_config_lock || { err "${shared_config_error:-无法获取公共配置锁}"; return 1; }
        load caddy.sh
        if [[ $is_install_caddy ]]; then
            caddy_config new
            [[ -f $is_caddyfile ]] || { shared_config_unlock; err "无法创建 Caddy 主配置文件."; return 1; }
        fi
        if [[ ! $(grep "$is_caddy_conf" "$is_caddyfile" 2>/dev/null) ]]; then
            msg "import $is_caddy_conf/*.conf" >>"$is_caddyfile" || {
                shared_config_unlock
                err "无法更新 Caddy 主配置文件."
                return 1
            }
        fi
        if [[ ! -d $is_caddy_conf ]] && ! mkdir -p "$is_caddy_conf"; then
            shared_config_unlock
            err "无法创建 Caddy 配置目录."
            return 1
        fi
        caddy_config "$2"
        [[ -s $is_caddy_conf/${host}.conf ]] || { shared_config_unlock; err "无法创建 Caddy 站点配置文件."; return 1; }
        shared_config_unlock
        manage_restart_checked caddy "Caddy 配置已更新" || return 1
        ;;
    config.json)
        local candidate_config
        shared_config_lock || { err "${shared_config_error:-无法获取公共配置锁}"; return 1; }
        is_log='log:{output:"/var/log/'$is_core'/access.log",level:"info","timestamp":true}'
        is_dns='dns:{}'
        is_ntp='ntp:{"enabled":true,"server":"time.apple.com"},'
        if [[ -f $is_config_json ]]; then
            [[ $(jq .ntp.enabled "$is_config_json") != "true" ]] && is_ntp=
        else
            [[ ! $is_ntp_on ]] && is_ntp=
        fi
        is_outbounds='outbounds:[{tag:"direct",type:"direct"}]'
        is_server_config_json=$(jq "{$is_log,$is_dns,$is_ntp$is_outbounds}" <<<{})
        candidate_config=$(mktemp "$is_config_json.rebuild.XXXXXX") || { shared_config_unlock; err "无法创建候选公共配置"; return 1; }
        printf '%s\n' "$is_server_config_json" >"$candidate_config" || { rm -f "$candidate_config"; shared_config_unlock; err "无法写入候选公共配置"; return 1; }
        if ! sync_runtime_node_outbound_modes "$candidate_config" "$is_config_json" "$is_conf_dir" 1; then
            rm -f "$candidate_config"
            shared_config_unlock
            err "节点代理路由同步失败: ${runtime_sync_error:-未知错误}"
            return 1
        fi
        rm -f "$candidate_config"
        shared_config_unlock
        manage_restart_checked "" "公共配置已更新" || return 1
        ;;
    esac
}

# change config file
change() {
    local change_choice_status change_info_status change_sub_status ss_method_status snell_status
    local change_choice_from_menu= change_node_picked= is_entry_addr_reset=
    is_change=1
    is_dont_show_info=1
    is_auto=
    is_new_servername=
    if [[ $2 ]]; then
        case ${2,,} in
        full)
            is_change_id=full
            ;;
        new)
            is_change_id=0
            ;;
        port)
            is_change_id=1
            ;;
        host)
            is_change_id=2
            ;;
        path)
            is_change_id=3
            ;;
        pass | passwd | password)
            is_change_id=4
            ;;
        id | uuid)
            is_change_id=5
            ;;
        ssm | method | ss-method | ss_method)
            is_change_id=6
            ;;
        dda | door-addr | door_addr)
            is_change_id=7
            ;;
        ddp | door-port | door_port)
            is_change_id=8
            ;;
        key | publickey | privatekey)
            is_change_id=9
            ;;
        sni | servername | servernames)
            is_change_id=10
            ;;
        web | proxy-site)
            is_change_id=11
            ;;
        name | rename)
            is_change_id=13
            ;;
        outbound | outbound-mode)
            is_change_id=14
            ;;
        entry | entry-addr | entry_addr | addr)
            is_change_id=15
            ;;
        link | url)
            is_change_id=16
            ;;
        psk | snell-psk)
            is_change_id=17
            ;;
        snell-version | version)
            is_change_id=18
            ;;
        obfs | obfs-mode | obfs_mode)
            is_change_id=19
            ;;
        mode | snell-mode)
            is_change_id=20
            ;;
        note)
            is_change_id=21
            ;;
        *)
            [[ $is_try_change ]] && return
            err "无法识别 ($2) 更改类型."
            return 1
            ;;
        esac
    fi
    [[ $is_try_change ]] && return
    # 从哪里来就回哪里去：选择修改项按 0 退回选择节点，子选择页按 0 退回选择修改项。
    [[ $is_change_id ]] || change_choice_from_menu=1
    while :; do
        is_node_picked_by_menu=
        [[ $is_dont_auto_exit ]] && {
            get info "$1"
            change_info_status=$?
        } || {
            [[ $is_change_id ]] && {
                if [[ $is_change_id == 'full' ]]; then
                    [[ $3 ]] && is_change_msg="更改多个参数" || is_change_msg=
                else
                    is_change_msg=${change_labels[$is_change_id]#*|}
                fi
                if [[ $is_change_msg ]]; then
                    _green "\n快速执行: $is_change_msg"
                fi
            }
            info "$1"
            change_info_status=$?
            if [[ $is_auto_get_config ]]; then
                msg "\n自动选择: $is_config_file"
            fi
        }
        change_node_picked=$is_node_picked_by_menu
        [[ $change_info_status == 2 ]] && return 2
        [[ $change_info_status == 0 ]] || return "$change_info_status"
        is_old_net=$net
        [[ $is_tcp_http ]] && net=http
        [[ $host ]] && net=$is_protocol-$net-tls
        [[ $is_reality && $net_type =~ 'http' ]] && net=rh2

        [[ $3 == 'auto' ]] && is_auto=1 || is_auto=
        # if is_dont_show_info exist, cant show info.
        is_dont_show_info=
        while :; do
            # if not prefer args, show change list and then get change id.
            if [[ ! $is_change_id ]]; then
                is_tmp_list=()
                for v in "${is_can_change[@]}"; do
                    is_tmp_list+=("${change_labels[$v]%%|*}")
                done
                menu_select parent is_change_str "\n请选择更改:\n" "${is_tmp_list[@]}"
                change_choice_status=$?
                if [[ $change_choice_status == 2 ]]; then
                    [[ $change_node_picked ]] || return 2
                    # 退回选择节点：清空上一个节点的状态后重新选择。
                    is_config_file=
                    is_config_name=
                    is_protocol=
                    is_auto_get_config=
                    is_reality=
                    is_anytls_domain=
                    continue 2
                fi
                [[ $change_choice_status == 0 ]] || return 1
                is_change_id=${is_can_change[$REPLY - 1]}
            fi
            case $is_change_id in
            full)
                add "$net" "${@:3}"
                ;;
            0)
                # new protocol
                is_set_new_protocol=1
                add "${@:3}"
                change_sub_status=$?
                if [[ $change_sub_status == 2 ]]; then
                    is_set_new_protocol=
                    [[ $change_choice_from_menu ]] || return 2
                    is_change_id=
                    continue
                fi
                ;;
            1)
                # new port
                is_new_port=$3
                if [[ $4 ]]; then
                    is_new_servername=$4
                    is_servername=$4
                fi
                [[ $host && ! $is_caddy || $is_no_auto_tls ]] && { err "($is_config_file) 不支持更改端口, 因为没啥意义."; return 1; }
                if [[ $is_new_port && ! $is_auto ]]; then
                    [[ ! $(is_test port "$is_new_port") ]] && { err "请输入正确的端口, 可选(1-65535)"; return 1; }
                    [[ $is_new_port != 443 && $(node_port_used "$is_new_port" "$is_protocol") && ${is_protocol,,} != snell ]] && { err "无法使用 ($is_new_port) 端口"; return 1; }
                fi
                [[ $is_auto ]] && get_port && is_new_port=$tmp_port
            [[ ! $is_new_port ]] && ask string is_new_port "请输入新监听端口 (1-65535):"
                if [[ $is_caddy && $host ]]; then
                    net=$is_old_net
                    is_https_port=$is_new_port
                    load caddy.sh
                    caddy_config "$net"
                    manage_restart_checked caddy "Caddy 端口配置已更新" || return 1
                    info
                else
                    add "$net" "$is_new_port"
                fi
                ;;
            2)
                # new host
                is_new_host=$3
                [[ ! $host ]] && { err "($is_config_file) 不支持更改域名."; return 1; }
            [[ ! $is_new_host ]] && ask string is_new_host "请输入新域名 (需解析到本机公网 IP):"
                old_host=$host # del old host
                add "$net" "$is_new_host"
                ;;
            3)
                # new path
                is_new_path=$3
                [[ ! $path ]] && { err "($is_config_file) 不支持更改路径."; return 1; }
                [[ $is_auto ]] && get_uuid && is_new_path=/$tmp_uuid
            [[ ! $is_new_path ]] && ask string is_new_path "请输入新路径 (以 / 开头):"
                add "$net" auto auto "$is_new_path"
                ;;
            4)
                # new password
                is_new_pass=$3
                if [[ $ss_password || $password ]]; then
                    [[ $is_auto ]] && {
                        get_uuid && is_new_pass=$tmp_uuid
                        if [[ $ss_password ]]; then
                            is_new_pass=$(get ss2022)
                        fi
                    }
                else
                    err "($is_config_file) 不支持更改密码."
                    return 1
                fi
            [[ ! $is_new_pass ]] && ask string is_new_pass "请输入新密码 (输入不显示):"
                password=$is_new_pass
                ss_password=$is_new_pass
                is_socks_pass=$is_new_pass
                add "$net"
                ;;
            5)
                # new uuid
                is_new_uuid=$3
                [[ ! $uuid ]] && { err "($is_config_file) 不支持更改 UUID."; return 1; }
                [[ $is_auto ]] && get_uuid && is_new_uuid=$tmp_uuid
            [[ ! $is_new_uuid ]] && ask string is_new_uuid "请输入新 UUID (输入不显示):"
                add "$net" auto "$is_new_uuid"
                ;;
            6)
                # new method
                is_new_method=$3
                is_new_ss_password=$ss_password
                [[ $net != 'ss' ]] && { err "($is_config_file) 不支持更改加密方式."; return 1; }
                [[ $is_auto ]] && is_new_method=$is_random_ss_method
                if [[ ! $is_new_method ]]; then
                    select_ss_method
                    ss_method_status=$?
                    if [[ $ss_method_status == 2 ]]; then
                        [[ $change_choice_from_menu ]] || return 2
                        is_change_id=
                        continue
                    fi
                    [[ $ss_method_status == 0 ]] || return 1
                    is_new_method=$ss_method
                fi
                if [[ $(grep 2022 <<<"$is_new_method") ]] && ! ss_password_valid_for_method "$is_new_method" "$is_new_ss_password"; then
                    is_new_ss_password=$(ss_password_for_method "$is_new_method")
                    msg "\n已根据新的加密方式自动更新密码: $(_green "$is_new_ss_password")\n"
                fi
                if [[ $is_new_ss_password ]]; then
                    add "$net" auto "$is_new_ss_password" "$is_new_method"
                else
                    add "$net" auto auto "$is_new_method"
                fi
                ;;
            7)
                # new remote addr
                is_new_door_addr=$3
                [[ $net != 'direct' ]] && { err "($is_config_file) 不支持更改目标地址."; return 1; }
            [[ ! $is_new_door_addr ]] && ask string is_new_door_addr "请输入新的目标地址 (IPv4、IPv6 或域名):"
                door_addr=$is_new_door_addr
                add "$net"
                ;;
            8)
                # new remote port
                is_new_door_port=$3
                [[ $net != 'direct' ]] && { err "($is_config_file) 不支持更改目标端口."; return 1; }
                [[ ! $is_new_door_port ]] && {
                ask string door_port "请输入新的目标端口 (1-65535):"
                    is_new_door_port=$door_port
                }
                add "$net" auto auto "$is_new_door_port"
                ;;
            9)
                # new is_private_key is_public_key
                is_new_private_key=$3
                is_new_public_key=$4
                [[ ! $is_reality ]] && { err "($is_config_file) 不支持更改密钥."; return 1; }
                if [[ $is_auto ]]; then
                    get_pbk
                    add "$net"
                else
                    [[ $is_new_private_key && ! $is_new_public_key ]] && {
                        err "无法找到 Public key."
                        return 1
                    }
                    [[ ! $is_new_private_key ]] && ask string is_new_private_key "请输入新的私钥 (输入不显示):"
                    [[ ! $is_new_public_key ]] && ask string is_new_public_key "请输入新的公钥:"
                    if [[ $is_new_private_key == "$is_new_public_key" ]]; then
                        err "Private key 和 Public key 不能一样."
                        return 1
                    fi
                    is_tmp_json=$is_conf_dir/$is_config_file-$uuid
                    cp -f "$is_conf_dir/$is_config_file" "$is_tmp_json"
                    sed -i "s#$is_private_key" "#$is_new_private_key#" "$is_tmp_json"
                    "$is_core_bin" check -c "$is_tmp_json" &>/dev/null
                    if [[ $? != 0 ]]; then
                        is_key_err=1
                        is_key_err_msg="Private key 无法通过测试."
                    fi
                    sed -i "s#$is_new_private_key" "#$is_new_public_key#" "$is_tmp_json"
                    "$is_core_bin" check -c "$is_tmp_json" &>/dev/null
                    if [[ $? != 0 ]]; then
                        is_key_err=1
                        is_key_err_msg+="Public key 无法通过测试."
                    fi
                    rm "$is_tmp_json"
                    [[ $is_key_err ]] && { err "$is_key_err_msg"; return 1; }
                    is_private_key=$is_new_private_key
                    is_public_key=$is_new_public_key
                    is_test_json=
                    add "$net"
                fi
                ;;
            10)
                # new serverName
                is_new_servername=$3
                [[ ! $is_reality ]] && { err "($is_config_file) 不支持更改 serverName."; return 1; }
                [[ $is_auto ]] && is_new_servername=$(reality_sni_select)
                [[ ! $is_new_servername ]] && ask string is_new_servername "请输入新的 SNI 域名 (TLS 握手域名):"
                is_servername=$is_new_servername
                add "$net"
                ;;
            11)
                # new proxy site
                is_new_proxy_site=$3
                [[ ! $is_caddy && ! $host ]] && {
                    err "($is_config_file) 不支持更改伪装网站."
                    return 1
                }
                [[ ! -f $is_caddy_conf/${host}.conf.add ]] && { err "无法配置伪装网站."; return 1; }
                [[ ! $is_new_proxy_site ]] && ask string is_new_proxy_site "请输入新的反向代理目标域名 (例如 example.com):"
                proxy_site=$(sed 's#^.*//##;s#/$##' <<<"$is_new_proxy_site")
                load caddy.sh
                caddy_config proxy
                manage_restart_checked caddy "伪装网站配置已更新" || return 1
                msg "\n已更新伪装网站为: $(_green "$proxy_site") \n"
                ;;
            12)
                # new socks user
                [[ ! $is_socks_user ]] && { err "($is_config_file) 不支持更改用户名 (Username)."; return 1; }
            ask string is_socks_user "请输入新用户名:"
                add "$net"
                ;;
            13)
                # update share link node name (does not rename json file)
                is_new_name=$3
            [[ ! $is_new_name ]] && ask string is_new_name "请输入新的节点名称 (不能为空):"
                is_new_name=${is_new_name%.json}
                [[ ! $is_new_name ]] && { err "节点名称不能为空."; return 1; }
                is_old_name=$(node_name_for_link "$is_config_file")
                [[ "$is_old_name" == "$is_new_name" ]] && { err "新节点名称与当前名称一致."; return 1; }
                meta_set "$is_config_file" node_name "$is_new_name"
                msg "\n已更新节点名称为: $(_green "$is_new_name")\n"
                info
                ;;
            14)
                edit_node_outbound_mode
                change_sub_status=$?
                if [[ $change_sub_status == 2 ]]; then
                    [[ $change_choice_from_menu ]] || return 2
                    is_change_id=
                    continue
                fi
                ;;
            15)
                is_new_entry_addr=$3
                is_entry_addr_reset=
                if [[ $is_new_entry_addr == auto ]]; then
                    is_new_entry_addr=
                    is_entry_addr_reset=1
                fi
                if [[ ! $is_new_entry_addr && ! $is_entry_addr_reset ]]; then
                    form_cancel_tip
                    echo -ne "请输入分享链接中的服务器地址 (IPv4、IPv6 或域名；输入 auto 恢复公网 IP，直接回车取消):"
                    form_read -r is_new_entry_addr || return 1
                    if [[ $is_new_entry_addr == auto ]]; then
                        is_new_entry_addr=
                        is_entry_addr_reset=1
                    fi
                fi
                if [[ ! $is_entry_addr_reset ]]; then
                    case $is_new_entry_addr in
                    '' | 0 | q | Q)
                        msg "\n已取消，分享地址保持不变。"
                        form_cancel
                        return 1
                        ;;
                    esac
                fi
                is_new_entry_addr=$(sync_entry_addr_config "$is_config_file" "$is_new_entry_addr") || { err "入口地址更新失败: $is_new_entry_addr"; return 1; }
                msg "\n已更新入口地址为: $(_green "$is_new_entry_addr")\n"
                info
                ;;
            17)
                # psk
                [[ $is_protocol == snell ]] || { err "($is_config_file) 不支持更改 Snell PSK."; return 1; }
                is_new_snell_psk=$3
                [[ $is_auto ]] && is_new_snell_psk=$(get_snell_psk)
            [[ ! $is_new_snell_psk ]] && ask string is_new_snell_psk "请输入新的 Snell PSK (输入不显示):"
                if [[ $snell_version == 6 ]]; then
                    ((${#is_new_snell_psk} >= 12 && ${#is_new_snell_psk} <= 255)) || { err "Snell v6 PSK 长度必须在 12 到 255 字符之间. $is_err_tips"; return 1; }
                fi
                snell_psk=$is_new_snell_psk
                add snell
                ;;
            18)
                # snell-version
                [[ $is_protocol == snell ]] || { err "($is_config_file) 不支持更改 Snell 版本."; return 1; }
                is_new_snell_version=$3
                [[ $is_auto ]] && is_new_snell_version=6
                [[ ! $is_new_snell_version ]] && {
            ask string is_new_snell_version "请输入 Snell 版本 (5 或 6):"
                }
                snell_version_valid "$is_new_snell_version" || { err "Snell 版本只支持 5 或 6. $is_err_tips"; return 1; }
                if [[ $is_new_snell_version == 6 && $snell_version != 6 ]]; then
                    # migrating v5 -> v6
                    unset snell_obfs_mode
                    snell_mode=default
                    if ((${#snell_psk} < 12)); then
                        warn "原 PSK 长度不足 12 位，已自动生成符合 v6 规范的新 PSK."
                        snell_psk=$(get_snell_psk)
                    fi
                elif [[ $is_new_snell_version == 5 && $snell_version != 5 ]]; then
                    # migrating v6 -> v5
                    unset snell_mode
                    snell_obfs_mode=none
                fi
                snell_version=$is_new_snell_version
                add snell
                ;;
            19)
                # obfs-mode
                [[ $is_protocol == snell ]] || { err "($is_config_file) 不支持更改 Snell 混淆模式."; return 1; }
                if [[ $snell_version == 6 ]]; then
                    # smart routing for v6 node
                    if [[ $3 =~ ^(default|unshaped|unsafe-raw)$ ]]; then
                        snell_mode=$3
                        add snell
                        return
                    fi
                    if [[ $3 == 'auto' || $3 == 'none' || $3 == 'http' ]]; then
                        warn "当前为 Snell v6 节点，不支持混淆模式 (obfs_mode)，已自动转换为默认运行模式 (mode: default)."
                        snell_mode=default
                        add snell
                        return
                    fi
                    # interactive prompt for mode
                    select_snell_mode "\n当前为 Snell v6 节点，请选择运行模式:\n$(snell_mode_desc)\n"
                    snell_status=$?
                    if [[ $snell_status == 2 ]]; then
                        [[ $change_choice_from_menu ]] || return 2
                        is_change_id=
                        continue
                    fi
                    [[ $snell_status == 0 ]] || return 1
                    snell_mode=$is_new_snell_mode
                    add snell
                    return
                fi
                is_new_snell_obfs_mode=$3
                [[ $is_new_snell_obfs_mode == auto ]] && is_new_snell_obfs_mode=none
                if [[ ! $is_new_snell_obfs_mode ]]; then
                    select_snell_obfs_mode "\n选择 Snell 混淆模式:\n"
                    snell_status=$?
                    if [[ $snell_status == 2 ]]; then
                        [[ $change_choice_from_menu ]] || return 2
                        is_change_id=
                        continue
                    fi
                    [[ $snell_status == 0 ]] || return 1
                fi
                snell_obfs_mode=$is_new_snell_obfs_mode
                add snell
                ;;
            20)
                # mode
                if [[ $is_protocol != snell ]]; then
                    # backward compatibility for non-snell outbound mode
                    edit_node_outbound_mode
                    return
                fi
                if [[ $snell_version == 5 ]]; then
                    # smart routing for v5 node
                    if [[ $3 =~ ^(none|http)$ ]]; then
                        snell_obfs_mode=$3
                        add snell
                        return
                    fi
                    if [[ $3 == 'auto' || $3 =~ ^(default|unshaped|unsafe-raw)$ ]]; then
                        warn "当前为 Snell v5 节点，不支持运行模式 (mode)，已自动转换为默认混淆模式 (obfs_mode: none)."
                        snell_obfs_mode=none
                        add snell
                        return
                    fi
                    select_snell_obfs_mode "\n当前为 Snell v5 节点，请选择混淆模式:\n"
                    snell_status=$?
                    if [[ $snell_status == 2 ]]; then
                        [[ $change_choice_from_menu ]] || return 2
                        is_change_id=
                        continue
                    fi
                    [[ $snell_status == 0 ]] || return 1
                    snell_obfs_mode=$is_new_snell_obfs_mode
                    add snell
                    return
                fi
                is_new_snell_mode=$3
                [[ $is_new_snell_mode == auto ]] && is_new_snell_mode=default
                if [[ ! $is_new_snell_mode ]]; then
                    select_snell_mode "\n请选择 Snell v6 运行模式:\n$(snell_mode_desc)\n"
                    snell_status=$?
                    if [[ $snell_status == 2 ]]; then
                        [[ $change_choice_from_menu ]] || return 2
                        is_change_id=
                        continue
                    fi
                    [[ $snell_status == 0 ]] || return 1
                fi
                snell_mode_valid "$is_new_snell_mode" || { err "Snell 运行模式只支持 default, unshaped 或 unsafe-raw. $is_err_tips"; return 1; }
                snell_mode=$is_new_snell_mode
                add snell
                ;;
            16)
                # view current share link
                url_qr url
                ;;
            21)
                # note
                note_apply_cli "$is_config_file" "${@:3}" || return $?
                info
                ;;
            esac
            break 2
        done
    done
    is_change_id=
}

# delete config.
del() {
    # dont get ip
    is_dont_get_ip=1
    local deleted_config_file
    [[ $is_select_delete_node ]] && unset is_config_file is_conf_dir_empty
    [[ $is_conf_dir_empty ]] && return # not found any json file.
    # get a config file
    [[ ! $is_config_file ]] && { get info "$1" || return $?; }
    if [[ $is_config_file ]]; then
        if [[ $is_main_start && ! $is_no_del_msg ]]; then
            if ! confirm_action "将删除节点“$is_config_name”及其配置文件 $is_config_file；删除范围包括该节点的配置、关联元数据和运行时路由，不影响其他节点，删除后将重启 sing-box。确认删除"; then
                msg "已取消删除节点。"
                return 2
            fi
        fi
        deleted_config_file=$is_config_file
        apply_node_config_lifecycle delete "$deleted_config_file" || {
            err "$node_lifecycle_error"
            return 1
        }
        [[ ! $is_no_del_msg ]] && _green "\n已删除: $is_config_file\n"

        [[ $is_caddy ]] && {
            is_del_host=$host
            [[ $is_change ]] && {
                [[ ! $old_host ]] && return # no host exist or not set new host;
                is_del_host=$old_host
            }
            if [[ $is_del_host && $host != "$old_host" && -f $is_caddy_conf/$is_del_host.conf ]]; then
                rm -rf "$is_caddy_conf/$is_del_host.conf" "$is_caddy_conf/$is_del_host.conf.add"
                if [[ ! $is_new_json ]]; then
                    manage_restart_checked caddy "已移除 Caddy 站点配置" || return 1
                fi
            fi
        }
    fi
    if [[ ! $(ls "$is_conf_dir" | grep .json) && ! $is_change ]]; then
        warn "当前配置目录为空! 因为你刚刚删除了最后一个配置文件."
        is_conf_dir_empty=1
    fi
    unset is_dont_get_ip
    if [[ $is_dont_auto_exit ]]; then
        unset is_config_file
    fi
    return 0
}

# uninstall
uninstall() {
    local uninstall_scope="将删除 sing-box 程序、服务和配置，日志维护服务及日志，以及 one-singbox 程序、脚本和快捷命令" uninstall_choice_status
    if [[ $is_caddy ]]; then
        menu_select parent is_do_uninstall "\n请选择卸载范围:\n" "卸载内核和脚本" "全部卸载"
        uninstall_choice_status=$?
        [[ $uninstall_choice_status == 2 ]] && return 2
        [[ $uninstall_choice_status == 0 ]] || return 1
        if [[ $is_do_uninstall == '全部卸载' ]]; then
            confirm_exact_yes "$uninstall_scope；还将删除 Caddy 服务、程序及整个 /etc/caddy 安装和配置目录。确认卸载" || { msg "已取消卸载。"; return 2; }
        else
            confirm_exact_yes "$uninstall_scope。Caddy 服务、程序及 /etc/caddy 安装和配置目录保留，不删除。确认卸载" || { msg "已取消卸载。"; return 2; }
        fi
    else
        confirm_exact_yes "$uninstall_scope。Caddy 未安装，不涉及 Caddy 删除。确认卸载" || { msg "已取消卸载。"; return 2; }
    fi
    manage stop &>/dev/null
    manage disable &>/dev/null
    load log.sh
    log_limit_remove
    rm -rf "$is_core_dir" "$is_log_dir" "$is_sh_bin" "${is_sh_bin/$is_core/sb}"
    if [[ $is_systemd ]]; then
        rm -f "/lib/systemd/system/$is_core.service"
    elif [[ $is_openrc ]]; then
        rm -f "/etc/init.d/$is_core"
    fi
    sed -i "/$is_core/d" /root/.bashrc
    # uninstall caddy only when the full-removal scope was selected
    if [[ $is_do_uninstall == '全部卸载' ]]; then
        manage stop caddy &>/dev/null
        manage disable caddy &>/dev/null
        if [[ $is_systemd ]]; then
            rm -rf "$is_caddy_dir" "$is_caddy_bin" /lib/systemd/system/caddy.service
        elif [[ $is_openrc ]]; then
            rm -rf "$is_caddy_dir" "$is_caddy_bin" /etc/init.d/caddy
        fi
    fi
    [[ $is_install_sh ]] && return # reinstall
    _green "\n卸载完成!"
    msg "脚本哪里需要完善? 请反馈"
    msg "反馈问题) $(msg_ul "https://github.com/${is_sh_repo}/issues")\n"
}

# manage run status
manage() {
    [[ $is_dont_auto_exit ]] && return
    case $1 in
    1 | start)
        is_do=start
        ;;
    2 | stop)
        is_do=stop
        ;;
    3 | r | restart)
        is_do=restart
        ;;
    *)
        is_do=$1
        ;;
    esac
    case $2 in
    caddy) is_do_name=caddy ;;
    *) is_do_name=$is_core ;;
    esac
    if [[ $is_systemd ]]; then
        systemctl "$is_do" "$is_do_name" 2>/dev/null
    elif [[ $is_openrc ]]; then
        case $is_do in
        enable)
            rc-update add "$is_do_name" default 2>/dev/null
            ;;
        disable)
            rc-update del "$is_do_name" default 2>/dev/null
            ;;
        *)
            rc-service "$is_do_name" "$is_do" 2>/dev/null
            ;;
        esac
    fi
}

# Lightweight restart wrapper with context-aware error diagnostics and log hints.
# Transactional node lifecycle operations use manage_restart_confirmed (src/route.sh) instead.
manage_restart_checked() {
    local service_arg=${1:-} context=${2:-}
    local service_name=${is_core_name:-sing-box} unit_name=${is_core:-sing-box}
    local log_hint='请查看服务日志'
    if [[ $service_arg == caddy ]]; then
        service_name=Caddy
        unit_name=caddy
    fi
    if manage restart ${service_arg:+"$service_arg"}; then
        return 0
    fi
    if [[ $is_systemd ]]; then
        log_hint="查看服务日志：journalctl -u ${unit_name}.service -n 100 --no-pager"
    elif [[ $is_openrc && $unit_name == "${is_core:-sing-box}" ]]; then
        log_hint="查看服务错误日志：tail -n 100 ${is_log_dir:-/var/log/${is_core:-sing-box}}/error.log"
    elif [[ $is_openrc ]]; then
        log_hint='请查看 OpenRC 服务日志（logread，或 /var/log/messages）'
    fi
    if [[ $context ]]; then
        err "${context}，但 ${service_name} 服务重启失败，请检查服务状态（${log_hint}）。"
    else
        err "${service_name} 服务重启失败，请检查服务状态（${log_hint}）。"
    fi
    return 1
}

service_action_result() {
    local action=$1 service=${2:-$is_core} service_arg=${2:-} action_label expected_state action_status service_state service_status_text service_label service_status_color
    case $action in
        start) action_label=启动; expected_state=running ;;
        stop) action_label=停止; expected_state=stopped ;;
        r | restart) action=restart; action_label=重启; expected_state=running ;;
        *) return 2 ;;
    esac

    if manage "$action" "$service_arg"; then
        action_status=0
    else
        action_status=$?
    fi

    if [[ $service == "$is_core" ]]; then
        core_status_read
        service_state=$is_core_state
    else
        service_status_read "$service"
        service_state=$is_service_state
    fi
    service_label=$service
    [[ $service == "$is_core" ]] && service_label=$is_core_name
    [[ $service == caddy ]] && service_label=Caddy
    case $service_state in
        running) service_status_text='运行中'; service_status_color=$(_green "$service_status_text") ;;
        stopped) service_status_text='已停止'; service_status_color=$(_red "$service_status_text") ;;
        failed) service_status_text='启动失败'; service_status_color=$(_red "$service_status_text") ;;
        *) service_status_text='状态读取失败'; service_status_color=$(_red "$service_status_text") ;;
    esac

    if [[ $service_state == unknown ]]; then
        msg "无法确认 ${service_label} 当前状态（$service_status_color）；未报告${action_label}成功。"
    elif [[ $service_state == "$expected_state" && $action_status == 0 ]]; then
        msg "${action_label}服务成功：已确认 ${service_label} 当前状态为$service_status_color。"
        return 0
    elif [[ $service_state == "$expected_state" ]]; then
        msg "${action_label}服务命令返回失败，但已确认 ${service_label} 当前状态为$service_status_color。"
    else
        msg "${action_label}服务未达到目标状态：${service_label} 当前状态为$service_status_color。"
    fi
    if [[ $is_systemd ]]; then
        msg "查看服务日志：journalctl -u ${service}.service -n 100 --no-pager"
    elif [[ $is_openrc && $service == "$is_core" ]]; then
        msg "查看服务错误日志：tail -n 100 ${is_log_dir:-/var/log/$is_core}/error.log"
    elif [[ $is_openrc ]]; then
        msg "请查看 OpenRC 服务日志（logread，或 /var/log/messages）。"
    else
        msg "请从服务管理菜单选择“查看日志”，检查服务运行日志。"
    fi
    return 1
}

# 选择添加节点使用的协议，供添加流程与「返回选择协议」复用。
select_node_protocol() {
    local protocol_status
    is_tmp_list=("${protocol_list[@]}")
    [[ $is_no_auto_tls ]] && {
        is_tmp_list=()
        for v in "${protocol_list[@]}"; do
            [[ $(grep -i "\-tls$" <<<"$v") ]] && is_tmp_list+=("$v")
        done
    }
    menu_select parent is_new_protocol "\n选择协议:\n" "${is_tmp_list[@]}"
    protocol_status=$?
    return "$protocol_status"
}

# add a config
add() {
    local caddy_shared_lock= protocol_choice_status ss_method_status is_protocol_from_menu=
    is_custom_node_name=
    is_custom_node_note=
    [[ ! $1 && ! $is_change ]] && unset is_new_protocol
    if [[ ! $is_change ]]; then
        is_servername=
        is_use_servername=
        json_str=
    fi
    is_lower=${1,,}
    if [[ $is_lower ]]; then
        case $is_lower in
        ws | tcp | quic | http)
            is_new_protocol=VMess-${is_lower^^}
            ;;
        wss | h2 | hu | vws | vh2 | vhu | tws | th2 | thu)
            is_new_protocol=$(sed -E "s/^V/VLESS-/;s/^T/Trojan-/;/^(W|H)/{s/^/VMess-/};s/WSS/WS/;s/HU/HTTPUpgrade/" <<<"${is_lower^^}")-TLS
            ;;
        r | reality)
            is_new_protocol=VLESS-REALITY
            ;;
        rh2)
            is_new_protocol=VLESS-HTTP2-REALITY
            ;;
        ss)
            is_new_protocol=Shadowsocks
            ;;
        door | direct)
            is_new_protocol=Direct
            ;;
        tuic)
            is_new_protocol=TUIC
            ;;
        hy | hy2 | hysteria*)
            is_new_protocol=Hysteria2
            ;;
        trojan)
            is_new_protocol=Trojan
            ;;
        anytls)
            is_new_protocol=AnyTLS
            ;;
        socks)
            is_new_protocol=Socks
            ;;
        snell)
            is_new_protocol=Snell
            ;;
        *)
            for v in "${protocol_list[@]}"; do
                [[ $(grep -E -i "^$is_lower$" <<<"$v") ]] && is_new_protocol=$v && break
            done

            [[ ! $is_new_protocol ]] && { err "无法识别 ($1), 请使用: $is_core add [protocol] [args... | auto]"; return 1; }
            ;;
        esac
    fi

    # no prefer protocol
    if [[ ! $is_new_protocol ]]; then
        select_node_protocol
        protocol_choice_status=$?
        if [[ $protocol_choice_status == 2 ]]; then
            unset is_new_protocol
            [[ $is_change ]] || msg "\n已取消添加节点，返回节点管理菜单。\n"
            return 2
        fi
        [[ $protocol_choice_status == 0 ]] || return 1
        is_protocol_from_menu=1
    fi

    if [[ ${is_new_protocol,,} == 'anytls' ]]; then
        is_core_major=$(echo "$is_core_ver" | cut -d. -f1)
        is_core_minor=$(echo "$is_core_ver" | cut -d. -f2)
        if [[ ${is_core_major:-0} -lt 1 || ${is_core_major:-0} -eq 1 && ${is_core_minor:-0} -lt 12 ]]; then
            err "当前 sing-box 版本 ($is_core_ver) 不支持 AnyTLS，请先升级 sing-box core 到 1.12.0 或更高版本。"
            return 1
        fi
    fi

    case ${is_new_protocol,,} in
    *-tls)
        is_use_tls=1
        is_use_host=$2
        is_use_uuid=$3
        is_use_path=$4
        is_add_opts="[host] [uuid] [/path]"
        ;;
    vmess* | tuic*)
        is_use_port=$2
        is_use_uuid=$3
        is_add_opts="[port] [uuid]"
        ;;
    trojan* | hysteria*)
        is_use_port=$2
        is_use_pass=$3
        is_add_opts="[port] [password]"
        ;;
    *reality*)
        is_reality=1
        is_use_port=$2
        is_use_uuid=$3
        is_use_servername=$4
        is_add_opts="[port] [uuid] [sni]"
        ;;
    shadowsocks)
        is_use_port=$2
        is_use_pass=$3
        is_use_method=$4
        is_add_opts="[port] [password] [method]"
        ;;
    direct)
        is_use_port=$2
        is_use_door_addr=$3
        is_use_door_port=$4
        is_add_opts="[port] [remote_addr] [remote_port]"
        ;;
    anytls*)
        is_use_port=$2
        is_use_pass=$3
        [[ $4 ]] && is_anytls_domain=$4
        is_add_opts="[port] [password] [domain]"
        ;;
    socks)
        is_socks=1
        is_use_port=$2
        is_use_socks_user=$3
        is_use_socks_pass=$4
        is_add_opts="[port] [username] [password]"
        ;;
    snell)
        is_use_port=$2
        is_use_pass=$3
        is_use_version=$4
        is_add_opts="[port] [psk] [version]"
        ;;
    esac

    if [[ $is_change && $is_new_servername ]]; then
        is_use_servername=$is_new_servername
    fi

    [[ $1 && ! $is_change ]] && {
        msg "\n使用协议: $is_new_protocol"
        # err msg tips
        is_err_tips="\n\n请使用: $(_green "$is_core add $1 $is_add_opts") 来添加 $is_new_protocol 配置"
    }

    # remove old protocol args
    if [[ $is_set_new_protocol ]]; then
        case $is_old_net in
        h2 | ws | httpupgrade)
            old_host=$host
            [[ ! $is_use_tls ]] && unset host is_no_auto_tls
            ;;
        reality)
            net_type=
            [[ ! $(grep -i reality <<<"$is_new_protocol") ]] && is_reality=
            ;;
        ss)
            [[ $(is_test uuid "$ss_password") ]] && uuid=$ss_password
            ;;
        esac
        [[ ! $(is_test uuid "$uuid") ]] && uuid=
        [[ $(is_test uuid "$password") ]] && uuid=$password
    fi

    # no-auto-tls only use h2,ws,grpc
    if [[ $is_no_auto_tls && ! $is_use_tls ]]; then
        err "$is_new_protocol 不支持手动配置 tls."
        return 1
    fi

    # prefer args.
    if [[ $2 ]]; then
        for v in is_use_port is_use_uuid is_use_host is_use_path is_use_pass is_use_method is_use_door_addr is_use_door_port is_use_version; do
            [[ ${!v} == 'auto' ]] && unset "$v"
        done

        if [[ $is_use_port ]]; then
            [[ ! $(is_test port "${is_use_port}") ]] && {
                err "($is_use_port) 不是一个有效的端口. $is_err_tips"
                return 1
            }
            if [[ $(node_port_used "$is_use_port" "$is_new_protocol") && ! $is_gen && ${is_new_protocol,,} != snell ]]; then
                err "无法使用 ($is_use_port) 端口. $is_err_tips"
                return 1
            fi
            port=$is_use_port
        fi
        if [[ $is_use_door_port ]]; then
            [[ ! $(is_test port "${is_use_door_port}") ]] && {
                err "(${is_use_door_port}) 不是一个有效的目标端口. $is_err_tips"
                return 1
            }
            door_port=$is_use_door_port
        fi
        if [[ $is_use_uuid ]]; then
            [[ ! $(is_test uuid "$is_use_uuid") ]] && {
                err "($is_use_uuid) 不是一个有效的 UUID. $is_err_tips"
                return 1
            }
            uuid=$is_use_uuid
        fi
        if [[ $is_use_path ]]; then
            [[ ! $(is_test path "$is_use_path") ]] && {
                err "($is_use_path) 不是有效的路径. $is_err_tips"
                return 1
            }
            path=$is_use_path
        fi
        if [[ $is_use_method ]]; then
            is_tmp_use_name=加密方式
            is_tmp_list=("${ss_method_list[@]}")
            for v in "${is_tmp_list[@]}"; do
                [[ $(grep -E -i "^${is_use_method}$" <<<"$v") ]] && is_tmp_use_type=$v && break
            done
            [[ ! ${is_tmp_use_type} ]] && {
                warn "(${is_use_method}) 不是一个可用的${is_tmp_use_name}."
                msg "${is_tmp_use_name}可用如下: "
                for v in "${is_tmp_list[@]}"; do
                    msg "\t\t$v"
                done
                msg "$is_err_tips\n"
                exit 1
            }
            ss_method=$is_tmp_use_type
        fi
        if [[ $is_use_pass ]]; then
            if [[ ${is_new_protocol,,} == snell ]]; then
                snell_psk=$is_use_pass
            else
                ss_password=$is_use_pass
                password=$is_use_pass
            fi
        fi
        [[ $is_use_version ]] && snell_version=$is_use_version
        [[ $is_use_host ]] && host=$is_use_host
        [[ $is_use_door_addr ]] && door_addr=$is_use_door_addr
        [[ $is_use_servername ]] && is_servername=$is_use_servername
        [[ $is_use_socks_user ]] && is_socks_user=$is_use_socks_user
        [[ $is_use_socks_pass ]] && is_socks_pass=$is_use_socks_pass
    fi

    # anytls with domain (ACME TLS)
    if [[ $is_anytls_domain && ! $is_change && ! $is_gen ]]; then
        get_ip
        host=$is_anytls_domain
        get host-test
        host=
    fi

    if [[ $is_use_tls ]]; then
        if [[ ! $is_no_auto_tls && ! $is_caddy && ! $is_gen && ! $is_dont_test_host ]]; then
            # test auto tls
            [[ $(is_test port_used 80) || $(is_test port_used 443) ]] && {
                get_port
                is_http_port=$tmp_port
                get_port
                is_https_port=$tmp_port
                warn "端口 (80 或 443) 已经被占用, 你也可以考虑使用 no-auto-tls"
                msg "\e[41m no-auto-tls 帮助(help)\e[0m: $(msg_ul https://github.com/ouones/one-singbox/blob/main/docs/usage.md)\n"
                msg "\n Caddy 将使用非标准端口实现自动配置 TLS, HTTP:$is_http_port HTTPS:$is_https_port\n"
                if ! confirm_action "确认使用非标准端口安装 Caddy"; then
                    msg "\n已取消安装 Caddy，本次添加节点已取消。"
                    form_cancel
                    return 1
                fi
            }
            is_install_caddy=1
        fi
        # set host
        [[ ! $host ]] && ask string host "输入域名 (需解析到本机公网 IP):"
        # test host dns
        get host-test
    else
        # for main menu start, dont auto create args
        if [[ $is_main_start ]]; then

            # set port
            [[ ! $port ]] && {
                get_port
                is_default_arg=$tmp_port
                ask string port "输入监听端口 (1-65535，回车自动分配 $is_default_arg):"
            }

            case ${is_new_protocol,,} in
            socks)
                # set user
                [[ ! $is_socks_user ]] && ask string is_socks_user "输入用户名:"
                # set password
                [[ ! $is_socks_pass ]] && {
                    [[ ! $tmp_uuid ]] && get_uuid
                    is_default_arg=$tmp_uuid
                    ask string is_socks_pass "输入密码 (回车自动生成；输入不显示):"
                }
                ;;
            shadowsocks)
                # set method
                if [[ ! $ss_method ]]; then
                    while :; do
                        select_ss_method
                        ss_method_status=$?
                        [[ $ss_method_status == 2 ]] || break
                        if [[ ! $is_protocol_from_menu ]]; then
                            msg "\n已取消添加节点，返回节点管理菜单。\n"
                            return 2
                        fi
                        # 按 0 退回「选择协议」，按重新选定的协议继续添加。
                        select_node_protocol
                        protocol_choice_status=$?
                        if [[ $protocol_choice_status == 2 ]]; then
                            unset is_new_protocol
                            [[ $is_change ]] || msg "\n已取消添加节点，返回节点管理菜单。\n"
                            return 2
                        fi
                        [[ $protocol_choice_status == 0 ]] || return 1
                        [[ ${is_new_protocol,,} == shadowsocks ]] || {
                            add "$is_new_protocol"
                            return $?
                        }
                    done
                    [[ $ss_method_status == 0 ]] || return 1
                fi
                # set password
                [[ ! $ss_password ]] && {
                    if [[ $(grep 2022 <<<"$ss_method") ]]; then
                        is_default_arg=$(get ss2022)
                    else
                        [[ ! $tmp_uuid ]] && get_uuid
                        is_default_arg=$tmp_uuid
                    fi
                    ask string ss_password "输入密码 (回车自动生成；输入不显示):"
                }
                ;;
            esac

        fi
    fi

    if [[ ${is_new_protocol,,} == snell ]]; then
        [[ ! $port ]] && get_port && port=$tmp_port
        [[ ! $snell_psk ]] && snell_psk=$(get_snell_psk)
        [[ ! $snell_version ]] && snell_version=6
        if [[ $snell_version == 6 ]]; then
            [[ ! $snell_mode ]] && snell_mode=default
            unset snell_obfs_mode
        else
            [[ ! $snell_obfs_mode ]] && snell_obfs_mode=none
            unset snell_mode
        fi
        validate_snell || return $?
    fi

    # Dokodemo-Door
    if [[ $is_new_protocol == 'Direct' ]]; then
        # set remote addr
        [[ ! $door_addr ]] && ask string door_addr "输入目标地址 (IPv4、IPv6 或域名):"
        # set remote port
        [[ ! $door_port ]] && ask string door_port "输入目标端口 (1-65535):"
    fi

    # Shadowsocks 2022
    if [[ $(grep 2022 <<<"$ss_method") ]]; then
        # test ss2022 password
        [[ $ss_password ]] && {
            is_test_json=1
            create server Shadowsocks
            [[ ! $tmp_uuid ]] && get_uuid
            is_test_json_save=$is_conf_dir/tmp-test-$tmp_uuid
            cat <<<"$is_new_json" >"$is_test_json_save"
            "$is_core_bin" check -c "$is_test_json_save" &>/dev/null
            if [[ $? != 0 ]]; then
                warn "当前 Shadowsocks 加密方式 ($ss_method) 不支持此密码。脚本将自动生成可用密码。"
                ss_password=
                # create new json.
                json_str=
            fi
            is_test_json=
            rm -f "$is_test_json_save"
        }

    fi

    # install caddy
    if [[ $is_install_caddy ]]; then
        get install-caddy
    fi

    if [[ $is_caddy && $host && ! $is_no_auto_tls && ! $is_gen ]]; then
        shared_config_lock || { err "${shared_config_error:-无法获取公共配置锁}"; return 1; }
        caddy_shared_lock=1
    fi

    if [[ $is_main_start && ! $is_change && ! $is_gen ]]; then
        form_cancel_tip literal_zero
        echo -ne "输入节点名称 (回车自动生成 8 位名称):"
        form_read -r is_custom_node_name || return 1
        case $is_custom_node_name in
        q | Q)
            msg "\n已取消添加节点。"
            form_cancel
            return 1
            ;;
        esac
        is_custom_node_name=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$is_custom_node_name")
        is_custom_node_name=${is_custom_node_name%.json}
        [[ ! $is_custom_node_name ]] && is_custom_node_name=$(random_node_name)
        echo -ne "输入备注 (可选，直接回车跳过):"
        if note_read_line is_custom_node_note; then
            is_custom_node_note=$(note_trim "$is_custom_node_note")
        else
            is_custom_node_note=
        fi
    fi

    # create json
    local add_rc=0
    create server "$is_new_protocol" || {
        add_rc=$?
        [[ $caddy_shared_lock ]] && shared_config_unlock
        return "$add_rc"
    }
    if [[ ! $is_change && ! $is_gen && $is_config_name ]]; then
        [[ $is_custom_node_name ]] && meta_set "$is_config_name" node_name "$is_custom_node_name"
        if [[ $is_custom_node_note ]]; then
            note_set "$is_config_name" "$is_custom_node_note"
        fi
    fi

    # show config info.
    info
    [[ $caddy_shared_lock ]] && shared_config_unlock
    return 0
}

# get config info
# or somes required args
get() {
    local get_status is_cfg_item is_file_display_list
    case $1 in
    addr)
        is_public_port=$port
        is_addr=$host
        [[ ! $is_addr && $is_config_file ]] && is_addr=$(meta_get "$is_config_file" '.entry_addr')
        [[ ! $is_addr && $is_listen_addr && $is_listen_addr != "::" && $is_listen_addr != "0.0.0.0" ]] && is_addr=$is_listen_addr
        [[ ! $is_addr ]] && {
            get_ip
            is_addr=$ip
            [[ $(grep ":" <<<"$ip") ]] && is_addr="[$ip]"
        }
        # IPv6 地址加方括号 (URL 格式要求)
        if [[ $is_addr == *:* && $is_addr != \[*\] ]]; then
            is_addr="[$is_addr]"
        fi
        return 0
        ;;
    new)
        [[ ! $host ]] && get_ip
        [[ ! $port ]] && get_port && port=$tmp_port
        if [[ ! $uuid ]]; then
            get_uuid && uuid=$tmp_uuid
        fi
        return 0
        ;;
    file)
        is_file_str=$2
        [[ ! $is_file_str ]] && is_file_str='.json$'
        is_all_json=()
        shopt -s nullglob
        for is_json_file in "$is_conf_dir"/*.json; do
            is_json_name=${is_json_file##*/}
            [[ $is_json_name == relay-* || $is_json_name =~ dynamic-port-.*-link ]] && continue
            grep -E -i -q -- "$is_file_str" <<<"$is_json_name" || continue
            is_all_json+=("$is_json_name")
            [[ ${#is_all_json[@]} -ge 233 ]] && break
        done
        shopt -u nullglob
        [[ ! $is_all_json ]] && { err "无法找到相关的配置文件: $2"; return 1; }
        [[ ${#is_all_json[@]} -eq 1 && ! $is_select_delete_node ]] && is_config_file=$is_all_json && is_auto_get_config=1
        [[ ! $is_config_file ]] && {
            [[ $is_dont_auto_exit ]] && return 0
            is_file_display_list=()
            for is_cfg_item in "${is_all_json[@]}"; do
                is_file_display_list+=("$(note_format_list_label "$is_cfg_item" "$is_cfg_item")")
            done
            menu_select parent is_config_file "\n选择节点:\n" "${is_file_display_list[@]}"
            get_status=$?
            [[ $get_status == 2 ]] && return 2
            [[ $get_status == 0 ]] || return 1
            is_config_file=${is_all_json[REPLY - 1]}
            export is_config_file
            # 标记节点来自选择列表，便于上层修改流程把 0 退回本页。
            is_node_picked_by_menu=1
        }
        return 0
        ;;
    info)
        is_tcp_http=
        get file "$2"
        get_status=$?
        [[ $get_status == 2 ]] && return 2
        [[ $get_status == 0 ]] || return "$get_status"
        if [[ $is_config_file ]]; then
            is_json_str=$(json_strip_comments "$is_conf_dir/$is_config_file")
            is_json_data=$(jq -r '(.inbounds[0]|.type,.listen_port,.listen,(.users[0]|.uuid,.password,.username),.method,.password,.override_port,.override_address,(.transport|.type,.path,.headers.host),(.tls|.server_name,.reality.private_key)),(.outbounds[1].tag,.inbounds[0].version,.inbounds[0].psk,.inbounds[0].obfs_mode,.inbounds[0].mode)' <<<"$is_json_str")
            [[ $? != 0 ]] && { err "无法读取此文件: $is_config_file"; return 1; }
            is_up_var_set=(null is_protocol port is_listen_addr uuid password username ss_method ss_password door_port door_addr net_type path host is_servername is_private_key is_public_key snell_version snell_psk snell_obfs_mode snell_mode)
            [[ $is_debug ]] && msg "\n------------- debug: $is_config_file -------------"
            mapfile -t is_json_data_list <<<"$is_json_data"
            i=0
            for v in "${is_json_data_list[@]}"; do
                ((i++))
                [[ ! $v ]] && v=null
                [[ $is_debug ]] && msg "$i-${is_up_var_set[$i]}: $v"
                printf -v "${is_up_var_set[$i]}" '%s' "$v"
                export "${is_up_var_set[$i]}"
            done
            for v in "${is_up_var_set[@]}"; do
                [[ ${!v} == 'null' ]] && unset "$v"
            done

            if [[ $is_private_key ]]; then
                is_reality=1
                net_type+=reality
                is_public_key=${is_public_key/public_key_/}
            fi
            is_socks_user=$username
            is_socks_pass=$password

            # extract anytls ACME domain
            [[ $is_protocol == 'anytls' ]] && {
                is_anytls_domain=$(jq -r '(.inbounds[0].tls.certificate_provider.domain[0] // .inbounds[0].tls.acme.domain[0]) // empty' <<<"$is_json_str" 2>/dev/null)
            }

            is_config_name=$is_config_file

            if [[ $is_caddy && $host && -f $is_caddy_conf/$host.conf ]]; then
                is_tmp_https_port=$(grep -E -o "$host:[1-9][0-9]?+" "$is_caddy_conf/$host.conf" | sed 's/.*://')
            fi
            if [[ $host && ! -f $is_caddy_conf/$host.conf ]]; then
                is_no_auto_tls=1
            fi
            [[ $is_tmp_https_port ]] && is_https_port=$is_tmp_https_port
            [[ $is_client && $host ]] && port=$is_https_port
            get protocol "$is_protocol-$net_type" || return $?
        fi
        return 0
        ;;
    protocol)
        get addr # get host or server ip
        is_lower=${2,,}
        net=
        is_users="users:[{uuid:\"$uuid\"}]"
        is_tls_json='tls:{enabled:true,alpn:["h3"],key_path:"'$is_tls_key'",certificate_path:"'$is_tls_cer'"}'
        case $is_lower in
        vmess*)
            is_protocol=vmess
            [[ $is_lower =~ "tcp" || ! $net_type && $is_up_var_set ]] && net=tcp && json_str=$is_users
            ;;
        vless*)
            is_protocol=vless
            ;;
        tuic*)
            net=tuic
            is_protocol=$net
            [[ ! $password ]] && password=$uuid
            is_users="users:[{uuid:\"$uuid\",password:\"$password\"}]"
            json_str="$is_users,congestion_control:\"bbr\",$is_tls_json"
            ;;
        trojan*)
            is_protocol=trojan
            [[ ! $password ]] && password=$uuid
            is_users="users:[{password:\"$password\"}]"
            [[ ! $host ]] && {
                net=trojan
                json_str="$is_users,${is_tls_json/alpn\:\[\"h3\"\],/}"
            }
            ;;
        hysteria2*)
            net=hysteria2
            is_protocol=$net
            [[ ! $password ]] && password=$uuid
            json_str="users:[{password:\"$password\"}],$is_tls_json"
            ;;
        shadowsocks*)
            net=ss
            is_protocol=shadowsocks
            [[ ! $ss_method ]] && ss_method=$is_random_ss_method
            [[ ! $ss_password ]] && {
                ss_password=$uuid
                if [[ $(grep 2022 <<<"$ss_method") ]]; then
                    ss_password=$(get ss2022)
                fi
            }
            json_str="method:\"$ss_method\",password:\"$ss_password\""
            ;;
        direct*)
            net=direct
            is_protocol=$net
            json_str="override_port:$door_port,override_address:\"$door_addr\""
            ;;
        anytls*)
            net=anytls
            is_protocol=$net
            [[ ! $password ]] && password=$uuid
            is_users="users:[{password:\"$password\"}]"
            if [[ $is_anytls_domain ]]; then
                # sing-box >= 1.14.0 uses certificate_provider; older uses acme
                is_core_minor=$(echo "$is_core_ver" | cut -d. -f2)
                if [[ ${is_core_minor:-0} -ge 14 ]]; then
                    is_anytls_tls="tls:{enabled:true,certificate_provider:{type:\"acme\",domain:[\"$is_anytls_domain\"]}}"
                else
                    is_anytls_tls="tls:{enabled:true,acme:{domain:[\"$is_anytls_domain\"]}}"
                fi
            else
                is_anytls_tls="${is_tls_json/alpn\:\[\"h3\"\],/}"
            fi
            json_str="$is_users,$is_anytls_tls"
            ;;
        socks*)
            net=socks
            is_protocol=$net
            [[ ! $is_socks_user ]] && is_socks_user=sbuser
            [[ ! $is_socks_pass ]] && is_socks_pass=$uuid
            json_str="users:[{username: \"$is_socks_user\", password: \"$is_socks_pass\"}]"
            ;;
        snell*)
            net=snell
            is_protocol=snell
            [[ $snell_version ]] || snell_version=6
            if [[ $snell_version == 6 ]]; then
                [[ $snell_mode ]] || snell_mode=default
                unset snell_obfs_mode
            else
                [[ $snell_obfs_mode ]] || snell_obfs_mode=none
                unset snell_mode
            fi
            ;;
        *)
            err "无法识别协议: $is_config_file"
            return 1
            ;;
        esac
        [[ $net ]] && return # if net exist, dont need more json args
        [[ $host && $is_lower =~ "tls" ]] && {
            [[ ! $path ]] && path="/$uuid"
            is_path_host_json=",path:\"$path\",headers:{host:\"$host\"}"
        }
        case $is_lower in
        *quic*)
            net=quic
            is_json_add="$is_tls_json,transport:{type:\"$net\"}"
            ;;
        *ws*)
            net=ws
            is_json_add="transport:{type:\"$net\"$is_path_host_json,early_data_header_name:\"Sec-WebSocket-Protocol\"}"
            ;;
        *reality*)
            net=reality
            [[ ! $is_private_key ]] && get_pbk
            is_json_add="tls:{enabled:true,server_name:\"$is_servername\",reality:{enabled:true,handshake:{server:\"$is_servername\",server_port:443},private_key:\"$is_private_key\",short_id:[\"\"]}}"
            [[ $is_lower =~ "http" ]] && {
                is_json_add="$is_json_add,transport:{type:\"http\"}"
            } || {
                is_users=${is_users/uuid/flow:\"xtls-rprx-vision\",uuid}
            }
            ;;
        *http* | *h2*)
            net=http
            [[ $is_lower =~ "up" ]] && net=httpupgrade
            is_json_add="transport:{type:\"$net\"$is_path_host_json}"
            [[ $is_lower =~ "h2" || ! $is_lower =~ "httpupgrade" && $host ]] && {
                net=h2
                is_json_add="${is_tls_json/alpn\:\[\"h3\"\],/},$is_json_add"
            }
            ;;
        *)
            err "无法识别传输协议: $is_config_file"
            return 1
            ;;
        esac
        json_str="$is_users,$is_json_add"
        ;;
    host-test) # test host dns record; for auto *tls required.
        [[ $is_no_auto_tls || $is_gen || $is_dont_test_host ]] && return
        get_ip
        get ping
        if [[ ! $(grep "$ip" <<<"$is_host_dns") ]]; then
            msg "\n请将 ($(_red_bg "$host")) 解析到 ($(_red_bg "$ip"))"
            msg "\n如果使用 Cloudflare, 在 DNS 那; 关闭 (Proxy status / 代理状态), 即是 (DNS only / 仅限 DNS)"
            ask string y "确认域名已解析到本机公网 IP；如使用 Cloudflare，代理状态为“仅 DNS”。输入 y 继续:"
            get ping
            if [[ ! $(grep "$ip" <<<"$is_host_dns") ]]; then
                _cyan "\n测试结果: $is_host_dns"
                err "域名 ($host) 没有解析到 ($ip)"
                return 1
            fi
        fi
        ;;
    ssss | ss2022)
        if [[ $(grep 128 <<<"$ss_method") ]]; then
            "$is_core_bin" generate rand 16 --base64
        else
            "$is_core_bin" generate rand 32 --base64
        fi
        ;;
    ping)
        # is_ip_type="-4"
        # [[ $(grep ":" <<<$ip) ]] && is_ip_type="-6"
        # is_host_dns=$(ping $host $is_ip_type -c 1 -W 2 | head -1)
        is_dns_type="a"
        [[ $(grep ":" <<<"$ip") ]] && is_dns_type="aaaa"
        is_host_dns=$(_wget -qO- --header="accept: application/dns-json" "https://one.one.one.one/dns-query?name=$host&type=$is_dns_type")
        ;;
    install-caddy)
        _green "\n安装 Caddy 实现自动配置 TLS.\n"
        load download.sh
        download caddy
        load systemd.sh
        install_service caddy &>/dev/null
        is_caddy=1
        _green "安装 Caddy 成功.\n"
        ;;
    reinstall)
        is_install_sh=$(cat "$is_sh_dir/install.sh")
        uninstall || return $?
        bash <<<"$is_install_sh" || return 1
        if [[ ${is_interactive_operation:-0} == 1 ]]; then
            msg "正在重新加载新版本面板...\n"
            return "$is_reload_exit_code"
        fi
        ;;
    esac
}

# show info
info() {
    local info_target=${1:-${is_config_file:-$is_config_name}}
    local info_status i a tt is_node_name is_vmess_url= is_quic_add= is_sha256= is_flow= is_net_type= is_insecure= is_type=
    local -a is_info_show=() is_info_str=()
    is_surge_str=
    is_url=
    [[ $is_gen ]] && return
    if [[ $info_target ]]; then
        get info "$info_target"
        info_status=$?
        [[ $info_status == 2 ]] && return 2
        [[ $info_status == 0 ]] || return "$info_status"
    elif [[ ! $is_protocol ]]; then
        get info "$1"
        info_status=$?
        [[ $info_status == 2 ]] && return 2
        [[ $info_status == 0 ]] || return "$info_status"
    fi
    # is_color=$(shuf -i 41-45 -n1)
    is_color=44
    is_node_name=$(node_name_for_link "${is_config_file:-$is_config_name}")
    case $net in
    ws | tcp | h2 | quic | http*)
        if [[ $host ]]; then
            is_color=45
            is_can_change=(0 1 2 3 5 13 14 15 16)
            is_info_show=(0 1 2 3 4 6 7 8)
            [[ $is_protocol == 'vmess' ]] && {
                is_vmess_url=$(jq -cn --arg ps "$is_node_name" --arg add "$is_addr" --arg port "$is_https_port" --arg id "$uuid" --arg net "$net" --arg host "$host" --arg path "$path" '{v:2,ps:$ps,add:$add,port:$port,id:$id,aid:"0",net:$net,host:$host,path:$path,tls:"tls"}')
                is_url=vmess://$(echo -n "$is_vmess_url" | base64 -w 0)
            } || {
                [[ $is_protocol == "trojan" ]] && {
                    uuid=$password
                    # is_info_str=($is_protocol $is_addr $is_https_port $password $net $host $path 'tls')
                    is_can_change=(0 1 2 3 4 13 14 15 16)
                    is_info_show=(0 1 2 10 4 6 7 8)
                }
                is_url="$is_protocol://$uuid@$host:$is_https_port?encryption=none&security=tls&type=$net&host=$host&path=$path#$is_node_name"
            }
            [[ $is_caddy ]] && is_can_change+=(11)
            is_info_str=("$is_protocol" "$is_addr" "$is_https_port" "$uuid" "$net" "$host" "$path" 'tls')
        else
            is_type=none
            is_can_change=(0 1 5 13 14 15 16)
            is_info_show=(0 1 2 3 4)
            is_info_str=("$is_protocol" "$is_addr" "$port" "$uuid" "$net")
            [[ $net == "http" ]] && {
                net=tcp
                is_type=http
                is_tcp_http=1
                is_info_show+=(5)
                is_info_str=("$is_protocol" "$is_addr" "$port" "$uuid" "tcp" "http")
            }
            [[ $net == "quic" ]] && {
                is_insecure=1
                is_info_show+=(8 9 20)
                is_info_str+=(tls h3 true)
                is_quic_add=",tls:\"tls\",alpn:\"h3\"" # cant add allowInsecure
            }
            is_vmess_url=$(jq -c "{v:2,ps:\"$is_node_name\",add:\"$is_addr\",port:\"$port\",id:\"$uuid\",aid:\"0\",net:\"$net\",type:\"$is_type\"$is_quic_add}" <<<{})
            is_url=vmess://$(echo -n "$is_vmess_url" | base64 -w 0)
        fi
        ;;
    ss)
        is_can_change=(0 1 4 6 13 14 15 16)
        is_info_show=(0 1 2 10 11)
        is_url="ss://$(echo -n "${ss_method}:${ss_password}" | base64 -w 0)@${is_addr}:${port}#$is_node_name"
        is_info_str=("$is_protocol" "$is_addr" "$port" "$ss_password" "$ss_method")
        ;;
    trojan)
        is_insecure=1
        is_can_change=(0 1 4 13 14 15 16)
        is_info_show=(0 1 2 10 4 8 20)
        is_url="$is_protocol://$password@$is_addr:$port?type=tcp&security=tls&insecure=1&allowInsecure=1#$is_node_name"
        is_info_str=("$is_protocol" "$is_addr" "$port" "$password" tcp tls true)
        ;;
    hy*)
        is_can_change=(0 1 4 13 14 15)
        is_info_show=(0 1 2 10 8 9 20)
        # fix xray core for client use.
        is_sha256=$(openssl x509 -noout -fingerprint -sha256 -in "$is_core_dir/bin/tls.cer" | sed 's/.*=//;s/://g')
        is_url="$is_protocol://$password@$is_addr:$port?alpn=h3&insecure=1&allowInsecure=1&pinSHA256=$is_sha256#$is_node_name"
        is_info_str=("$is_protocol" "$is_addr" "$port" "$password" tls h3 "true (设置, 固定证书>证书指纹(SHA-256): $is_sha256)")
        ;;
    tuic)
        is_insecure=1
        is_can_change=(0 1 4 5 13 14 15 16)
        is_info_show=(0 1 2 3 10 8 9 20 21)
        is_url="$is_protocol://$uuid:$password@$is_addr:$port?alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr#$is_node_name"
        is_info_str=("$is_protocol" "$is_addr" "$port" "$uuid" "$password" tls h3 true bbr)
        ;;
    reality)
        is_color=41
        is_can_change=(0 1 5 9 10 13 14 15 16)
        is_info_show=(0 1 2 3 15 4 8 16 17 18)
        is_flow=xtls-rprx-vision
        is_net_type=tcp
        [[ $net_type =~ "http" || ${is_new_protocol,,} =~ "http" ]] && {
            is_flow=
            is_net_type=h2
            is_info_show=(0 1 2 3 4 8 16 17 18)
        }
        is_info_str=("$is_protocol" "$is_addr" "${is_public_port:-$port}" "$uuid" "$is_flow" "$is_net_type" reality "$is_servername" chrome "$is_public_key")
        is_url="$is_protocol://$uuid@$is_addr:${is_public_port:-$port}?encryption=none&security=reality&flow=$is_flow&type=$is_net_type&sni=$is_servername&pbk=$is_public_key&fp=chrome#$is_node_name"
        ;;
    anytls)
        is_can_change=(0 1 4 13 14 15)
        if [[ $is_anytls_domain ]]; then
            is_info_show=(0 1 2 10 8)
            is_info_str=("$is_protocol" "$is_anytls_domain" "$port" "$password" tls)
            is_url="anytls://$password@$is_anytls_domain:$port#$is_node_name"
        else
            is_insecure=1
            is_info_show=(0 1 2 10 8 20)
            is_info_str=("$is_protocol" "$is_addr" "$port" "$password" tls true)
            is_url="anytls://$password@$is_addr:$port?insecure=1&allowInsecure=1#$is_node_name"
        fi
        ;;
    snell)
        if [[ $snell_version == 6 ]]; then
            is_can_change=(0 1 13 14 15 17 18 20)
            is_info_show=(0 1 2 22 23 25)
            is_info_str=("$is_protocol" "$is_addr" "$port" "$snell_version" "$snell_psk" "$snell_mode")
            local mode_param=
            local surge_mode=
            if [[ $snell_mode && $snell_mode != "default" ]]; then
                mode_param="&mode=$snell_mode"
                surge_mode=", mode=$snell_mode"
            fi
            is_url="snell://$snell_psk@$is_addr:$port?version=$snell_version${mode_param}#$is_node_name"
            is_surge_str="$is_node_name = snell, $is_addr, $port, psk=$snell_psk, version=$snell_version${surge_mode}"
        else
            is_can_change=(0 1 13 14 15 17 18 19)
            is_info_show=(0 1 2 22 23 24)
            is_info_str=("$is_protocol" "$is_addr" "$port" "$snell_version" "$snell_psk" "$snell_obfs_mode")
            local obfs_param=
            local surge_obfs=
            if [[ $snell_obfs_mode && $snell_obfs_mode != "none" ]]; then
                obfs_param="&obfs=$snell_obfs_mode"
                surge_obfs=", obfs=$snell_obfs_mode"
            fi
            is_url="snell://$snell_psk@$is_addr:$port?version=$snell_version${obfs_param}#$is_node_name"
            is_surge_str="$is_node_name = snell, $is_addr, $port, psk=$snell_psk, version=$snell_version${surge_obfs}"
        fi
        ;;
    direct)
        is_can_change=(0 1 7 8 13 14 15 16)
        is_info_show=(0 1 2 13 14)
        is_info_str=("$is_protocol" "$is_addr" "$port" "$door_addr" "$door_port")
        ;;
    socks)
        is_can_change=(0 1 12 4 13 14 15 16)
        is_info_show=(0 1 2 19 10)
        is_info_str=("$is_protocol" "$is_addr" "$port" "$is_socks_user" "$is_socks_pass")
        is_url="socks://$(echo -n "${is_socks_user}:${is_socks_pass}" | base64 -w 0)@${is_addr}:${port}#$is_node_name"
        ;;
    esac
    is_can_change+=(21)
    local info_cfg=${is_config_file:-$is_config_name}
    local info_outbound_display info_note
    info_outbound_display=$(current_outbound_mode_display "$info_cfg")
    [[ $info_outbound_display ]] || info_outbound_display='IPv4 优先'
    is_info_show+=(26)
    is_info_str+=("$info_outbound_display")
    info_note=$(note_get "$info_cfg")
    if [[ $info_note ]]; then
        is_info_show+=(27)
        is_info_str+=("$info_note")
    fi
    [[ $is_dont_show_info || $is_gen || $is_dont_auto_exit ]] && return # dont show info
    msg "-------------- $is_config_name -------------"
    for ((i = 0; i < ${#is_info_show[@]}; i++)); do
        a=${info_list[${is_info_show[$i]}]}
        if [[ ${#a} -eq 11 || ${#a} -ge 13 ]]; then
            tt='\t'
        else
            tt='\t\t'
        fi
        msg "$a $tt= \e[${is_color}m${is_info_str[$i]}\e[0m"
    done
    if [[ $is_url ]]; then
        msg "------------- ${info_list[12]} -------------"
        msg "\e[4;${is_color}m${is_url}\e[0m"
        [[ $is_insecure ]] && {
            warn "某些客户端如(V2rayN 等)导入URL需手动将: 跳过证书验证(allowInsecure) 设置为 true, 或打开: 允许不安全的连接"
        }
        if [[ $is_protocol != snell ]] && ! render_qrcode "$is_url"; then
            show_qrcode_link "$is_url"
        fi
    fi
    if [[ $is_surge_str ]]; then
        msg "------------- Surge 配置 -------------"
        msg "\e[${is_color}m${is_surge_str}\e[0m"
    fi
    if [[ $is_no_auto_tls ]]; then
        msg "------------- no-auto-tls INFO -------------"
        msg "端口(port): $port"
        msg "路径(path): $path"
        msg "\e[41m帮助(help)\e[0m: $(msg_ul https://github.com/ouones/one-singbox/blob/main/docs/usage.md)"
    fi
    footer_msg
}

# Internal exit code: a successful interactive script update must reload the new panel.
is_reload_exit_code=75

# update core, sh, caddy
update() {
    case $1 in
    1 | core | "$is_core")
        [[ ${is_core_ver:-} ]] || init_core_ver
        is_update_name=core
        is_show_name=$is_core_name
        is_run_ver=v${is_core_ver##* }
        is_update_repo=$is_core_repo
        ;;
    2 | sh)
        is_update_name=sh
        is_show_name="$is_script_name 脚本"
        is_run_ver=$is_sh_ver
        is_update_repo=$is_sh_repo
        ;;
    3 | caddy)
        [[ ! $is_caddy ]] && { err "不支持更新 Caddy."; return 1; }
        is_update_name=caddy
        is_show_name="Caddy"
        is_run_ver=$is_caddy_ver
        is_update_repo=$is_caddy_repo
        ;;
    *)
        err "无法识别 ($1), 请使用: $is_core update [core | sh | caddy] [ver]"
        return 1
        ;;
    esac
    if [[ $is_update_name == 'sh' ]]; then
        qrcode_dependency_install || :
    fi
    if [[ $2 ]]; then
        if [[ $is_update_name == 'sh' ]]; then
            is_new_ver=$2
        else
            is_new_ver=v${2#v}
        fi
    fi
    [[ $is_run_ver == "$is_new_ver" ]] && {
        msg "\n自定义版本和当前 $is_show_name 版本一样, 无需更新.\n"
        return 0
    }
    load download.sh
    if [[ $is_new_ver ]]; then
        msg "\n使用自定义版本更新 $is_show_name: $(_green "$is_new_ver")\n"
    else
        get_latest_version "$is_update_name"
        [[ $is_run_ver == "$latest_ver" ]] && {
            msg "\n$is_show_name 当前已经是最新版本了.\n"
            return 0
        }
        msg "\n发现 $is_show_name 新版本: $(_green "$latest_ver")\n"
        is_new_ver=$latest_ver
    fi
    download "$is_update_name" "$is_new_ver"
    case $is_update_name in
    sh)
        if [[ -f $is_config_json ]] && ! "$is_sh_bin" __post-update; then
            err "脚本更新后配置迁移失败，已安装新脚本但配置尚未完成同步。请运行: sb fix-config.json"
            return 1
        fi
        ;;
    core)
        if ! migrate_runtime_config; then
            err "内核更新后配置校验发现异常，已阻断内核重启以防服务故障。请检查配置或运行: sb fix-config.json"
            return 1
        fi
        if ! manage restart "$is_update_name"; then
            err "$is_show_name 更新后服务重启失败，请检查服务状态."
            return 1
        fi
        ;;
    caddy)
        if ! manage restart "$is_update_name"; then
            err "$is_show_name 更新后服务重启失败，请检查服务状态."
            return 1
        fi
        ;;
    esac
    msg "更新成功, 当前 $is_show_name 版本: $(_green "$is_new_ver")\n"
    msg "$(_green "请查看更新说明: https://github.com/$is_update_repo/releases/tag/$is_new_ver")\n"
    if [[ $is_update_name == 'sh' && ${is_interactive_operation:-0} == 1 ]]; then
        msg "正在重新加载新版本面板...\n"
        return "$is_reload_exit_code"
    fi
}

# Read one menu line without ending the panel session on Ctrl+C. The read runs
# in a subshell whose SIGINT aborts only that prompt, so the caller can step back
# to its parent menu instead of terminating the whole session.
menu_read_cancelable() {
    local var=$1 answer read_status previous_int
    previous_int=$(trap -p INT)
    trap ':' INT
    answer=$( (trap 'exit 130' INT; interactive_read -r line || exit 1; printf '%s' "${line-}") )
    read_status=$?
    if [[ $previous_int ]]; then
        eval "$previous_int"
    else
        trap - INT
    fi
    printf -v "$var" '%s' "$answer"
    return "$read_status"
}

menu_pause() {
    printf '\n按回车返回菜单。\n'
    menu_read_cancelable REPLY
    return 0
}

menu_action() {
    local action_status
    run_interactive_operation "$@"
    action_status=$?
    [[ $action_status == "$is_reload_exit_code" ]] && exec "$is_sh_bin"
    [[ $action_status == 2 ]] || menu_pause
    return "$action_status"
}

menu_select() {
    local menu_kind=$1 menu_var=$2 menu_prompt=$3 menu_has_parent= menu_default=${is_default_arg:-} menu_index menu_read_status
    shift 3
    [[ $menu_kind == parent ]] && menu_has_parent=1
    while :; do
        msg "$menu_prompt"
        is_tmp_list=("$@")
        show_list "${is_tmp_list[@]}"
        [[ $menu_has_parent ]] && msg "0) 返回上级"
        if [[ $menu_has_parent && $menu_default ]]; then
            echo -ne "请输入选项编号 [\e[91m0-${#is_tmp_list[@]}\e[0m] (0 返回上级，回车默认 $menu_default):"
        elif [[ $menu_has_parent ]]; then
            echo -ne "请输入选项编号 [\e[91m0-${#is_tmp_list[@]}\e[0m] (0 返回上级):"
        else
            echo -ne "请输入选项编号 [\e[91m1-${#is_tmp_list[@]}\e[0m] (q 退出):"
        fi
        if [[ $menu_has_parent && ${is_interactive_operation:-0} != 1 ]]; then
            # Ctrl+C in a nested menu steps back to the parent menu, never quits.
            menu_read_cancelable REPLY
            menu_read_status=$?
            [[ $menu_read_status == 130 ]] && { unset is_tmp_list; return 2; }
            [[ $menu_read_status == 0 ]] || { unset is_tmp_list; return 1; }
        else
            interactive_read -r REPLY || { unset is_tmp_list; return 1; }
        fi
        if [[ $menu_has_parent && ! $REPLY && $menu_default ]]; then
            for menu_index in "${!is_tmp_list[@]}"; do
                if [[ ${is_tmp_list[menu_index]} == "$menu_default" ]]; then
                    REPLY=$((menu_index + 1))
                    break
                fi
            done
        fi
        if [[ $menu_has_parent ]]; then
            if [[ $REPLY == 0 ]]; then
                export "$menu_var="
                unset is_tmp_list
                return 2
            fi
        else
            case $REPLY in
            q | Q)
                unset is_tmp_list
                return 3
                ;;
            '' | 0)
                msg "已在主菜单"
                unset is_tmp_list
                return 4
                ;;
            esac
        fi
        if [[ $REPLY =~ ^[1-9][0-9]*$ ]] && ((REPLY <= ${#is_tmp_list[@]})); then
            export "$menu_var=${is_tmp_list[REPLY - 1]}"
            msg "选择: ${!menu_var}"
            unset is_tmp_list
            return 0
        fi
        if [[ $menu_has_parent ]]; then
            msg "$is_err 输入无效，请输入 0-${#is_tmp_list[@]} 中的编号。"
        else
            msg "$is_err 输入无效，请输入 1-${#is_tmp_list[@]} 中的编号，或 q 退出。"
        fi
    done
}

node_menu_has_nodes() {
    local file
    shopt -s nullglob
    for file in "$is_conf_dir"/*.json; do
        [[ ${file##*/} == relay-* || ${file##*/} =~ dynamic-port-.*-link ]] && continue
        shopt -u nullglob
        return 0
    done
    shopt -u nullglob
    return 1
}

node_menu_empty_state() {
    node_menu_has_nodes && return 1
    msg "\n暂无节点，请先添加。\n"
    menu_pause
    return 0
}

node_menu() {
    local menu_status
    while :; do
        menu_select parent is_node_action "\n请选择节点操作:\n" "添加" "修改" "查看" "删除"
        menu_status=$?
        [[ $menu_status == 2 ]] && return
        [[ $menu_status == 0 ]] || return 1
        case $REPLY in
        1)
            menu_action add
            ;;
        2)
            node_menu_empty_state && continue
            menu_action change
            ;;
        3)
            node_menu_empty_state && continue
            menu_action info
            ;;
        4)
            node_menu_empty_state && continue
            is_select_delete_node=1 menu_action del
            ;;
        esac
    done
}

service_menu() {
    local menu_status=0 action_status choice_status
    while :; do
        menu_select parent is_service_action "\n请选择服务操作:\n" "状态" "启动" "停止" "重启" "日志"
        choice_status=$?
        [[ $choice_status == 2 ]] && return "$menu_status"
        [[ $choice_status == 0 ]] || return 1
        case $REPLY in
        1)
            core_status_read
            msg "\nsing-box 内核：$is_core_status (版本 $is_core_ver)"
            [[ $is_caddy ]] && msg "Caddy：$is_caddy_status (版本 $is_caddy_ver)"
            menu_pause
            ;;
        2)
            menu_action service_action_result start
            action_status=$?
            menu_status=$action_status
            ;;
        3)
            menu_action menu_system_impact "sing-box 内核服务（停止）" "停止监听并中断所有节点连接" "否（执行后保持停止）" service_action_result stop
            action_status=$?
            menu_status=$action_status
            ;;
        4)
            menu_action menu_system_impact "sing-box 内核服务（重启）" "短暂中断所有节点连接后重新加载配置" "是" service_action_result restart
            action_status=$?
            menu_status=$action_status
            ;;
        5)
            load log.sh
            is_terminal_log_view=1
            log_set
            action_status=$?
            unset is_terminal_log_view
            [[ $action_status == 130 ]] || menu_pause
            ;;
        esac
    done
}

update_menu() {
    local choice_status
    while :; do
        is_tmp_list=("更新 sing-box 内核" "更新脚本")
        [[ $is_caddy ]] && is_tmp_list+=("更新 Caddy")
        menu_select parent is_do_update "\n请选择要更新的软件:\n" "${is_tmp_list[@]}"
        choice_status=$?
        [[ $choice_status == 2 ]] && return
        [[ $choice_status == 0 ]] || return 1
        case $REPLY in
        1)
            menu_action menu_system_impact "sing-box 内核" "下载并替换 sing-box 内核程序，保留现有配置" "是" update 1
            ;;
        2)
            menu_action menu_system_impact "one-singbox 脚本" "下载并替换 one-singbox 脚本，不改 sing-box 配置" "否" update 2
            ;;
        3)
            menu_action menu_system_impact "Caddy" "下载并替换 Caddy 程序并重启 Caddy，不改 sing-box 配置" "否" update caddy
            ;;
        esac
    done
}

system_tools_menu() {
    local choice_status
    while :; do
        is_tmp_list=("启用 BBR" "DNS" "日志上限" "屏蔽回国流量 ($(block_cn_status_text))" "重装脚本")
        if menu_select parent is_system_tool "\n请选择系统设置:\n" "${is_tmp_list[@]}"; then
            choice_status=0
        else
            choice_status=$?
        fi
        [[ $choice_status == 2 ]] && return
        [[ $choice_status == 0 ]] || return 1
        case $REPLY in
        1)
            load bbr.sh
            menu_action menu_system_impact "系统内核拥塞控制（BBR）" "修改 /etc/sysctl.conf 中的拥塞控制与队列设置" "否" _try_enable_bbr
            ;;
        2)
            load dns.sh
            menu_action dns_set
            ;;
        3)
            menu_action log_limit_set
            ;;
        4)
            if block_cn_is_enabled; then
                menu_action menu_system_impact "停用屏蔽回国流量（block-cn）" "移除启用标记并重写运行时路由，恢复原有出站规则" "是" block_cn_menu_toggle
            else
                menu_action menu_system_impact "启用屏蔽回国流量（block-cn）" "写入启用标记、同步回国白名单并重写运行时路由" "是" block_cn_menu_toggle
            fi
            ;;
        5)
            menu_action get reinstall
            ;;
        esac
    done
}

# Main menu; q/Q exits and empty input or 0 redraws it.
is_main_menu() {
    local is_log_usage_limit is_log_usage_bytes menu_status action_status
    while :; do
        if ! qrcode_dependency_checked; then
            qrcode_dependency_install || :
        fi
        core_status_read
        load log.sh
        is_log_usage_limit=$(log_limit_read)
        msg "\n------------- $is_script_name script $is_sh_ver by $author -------------"
        msg "sing-box 内核：$is_core_ver ($is_core_status)"
        if is_log_usage_bytes=$(log_usage_read); then
            msg "日志占用：$(awk -v bytes="$is_log_usage_bytes" 'BEGIN { printf "%.2f", bytes / 1048576 }') MB / 上限 $is_log_usage_limit MB"
        else
            msg "日志占用：暂不可用 / 上限 $is_log_usage_limit MB"
        fi
        msg "问题反馈：$(msg_ul https://github.com/ouones/one-singbox/issues)"
        is_main_start=1
        if menu_select root is_main_pick "" "${mainmenu[@]}"; then
            menu_status=0
        else
            menu_status=$?
        fi
        [[ $menu_status == 3 ]] && return
        [[ $menu_status == 4 ]] && continue
        [[ $menu_status == 0 ]] || return 1
        case $REPLY in
        1) node_menu ;;
        2) relay_menu ;;
        3) service_menu ;;
        4) update_menu ;;
        5) system_tools_menu ;;
        6) msg "\n命令行帮助"; load help.sh; show_help; menu_pause ;;
        7) load help.sh; about; menu_pause ;;
        8)
            # 卸载成功后脚本与菜单依赖已被移除，直接结束本次交互会话。
            run_interactive_operation uninstall
            action_status=$?
            [[ $action_status == 0 ]] && return
            [[ $action_status == 2 ]] || menu_pause
            ;;
        esac
    done
}

# check prefer args, if not exist prefer args and show main menu
main() {
    require_root_for_system_exec || return 1
    if [[ ${is_core_defer_modules:-0} == 1 ]]; then
        case ${1:-} in
        h | help | --help | v | ver | version | s | status | start | stop | r | restart | \
        bin | pbk | check | completion | format | generate | geoip | geosite | merge | rule-set | run | tools | bbr | log)
            ;;
        *)
            core_load_modules
            ;;
        esac
    fi
    local fix_all_locked=
    [[ ! $1 ]] && {
        is_main_menu
        return
    }
    case $1 in
    a | add | gen | no-auto-tls)
        [[ $1 == 'gen' ]] && is_gen=1
        [[ $1 == 'no-auto-tls' ]] && is_no_auto_tls=1
        add "${@:2}"
        ;;
    bin | pbk | check | completion | format | generate | geoip | geosite | merge | rule-set | run | tools)
        is_run_command=$1
        if [[ $1 == 'bin' ]]; then
            "$is_core_bin" "${@:2}"
        elif [[ $is_run_command == 'pbk' ]]; then
            "$is_core_bin" generate reality-keypair "${@:2}"
        else
            "$is_core_bin" "$is_run_command" "${@:2}"
        fi
        ;;
    bbr)
        load bbr.sh
        _try_enable_bbr
        ;;
    block-cn)
        block_cn_cli "${@:2}"
        ;;
    c | config | change)
        is_change_id=
        change "${@:2}"
        ;;
    # client | genc)
    #     create client $2
    #     ;;
    d | del | rm)
        del "$2"
        ;;
    dd | ddel | fix | fix-all)
        case $1 in
        fix)
            [[ $2 ]] && {
                change "$2" full
            } || {
                is_change_id=full && change
            }
            return
            ;;
        fix-all)
            shared_config_lock || { err "${shared_config_error:-无法获取公共配置锁}"; return 1; }
            fix_all_locked=1
            is_dont_auto_exit=1
            msg
            shopt -s nullglob
            for is_json_file in "$is_conf_dir"/*.json; do
                v=${is_json_file##*/}
                [[ $v =~ dynamic-port-.*-link ]] && continue
                [[ $v == relay-*.json ]] && continue
                msg "fix: $v"
                change "$v" full
            done
            shopt -u nullglob
            _green "\nfix 完成.\n"
            ;;
        *)
            is_dont_auto_exit=1
            if [[ ! $2 ]]; then
                is_dont_auto_exit=
                err "无法找到需要删除的参数"
                return 1
            fi
            local del_ok=0
            for v in "${@:2}"; do
                if del "$v"; then
                    del_ok=1
                fi
            done
            if ((del_ok == 0)); then
                is_dont_auto_exit=
                return 1
            fi
            ;;
        esac
        is_dont_auto_exit=
        if [[ $fix_all_locked ]]; then
            shared_config_unlock
        fi
        manage_restart_checked "" "配置操作已保存" || return 1
        if [[ $is_del_host ]]; then
            manage_restart_checked caddy "Caddy 配置已更新" || return 1
        fi
        return 0
        ;;
    dns)
        load dns.sh
        dns_set "${@:2}"
        ;;
    debug)
        is_debug=1
        get info "$2"
        warn "如果需要复制; 请把 *uuid, *password, *host, *key 的值改写, 以避免泄露."
        ;;
    fix-config.json)
        block_cn_clean_all_legacy_inbounds "$is_conf_dir"
        create config.json
        ;;
    __post-update)
        migrate_runtime_config || { err "更新后配置迁移失败: ${runtime_sync_error:-未知错误}"; return 1; }
        ;;
    fix-caddyfile)
        if [[ $is_caddy ]]; then
            load caddy.sh
            caddy_config new
            manage_restart_checked caddy "Caddyfile 已更新" || return 1
            _green "\nfix 完成.\n"
        else
            err "无法执行此操作"
            return 1
        fi
        ;;
    i | info)
        info "$2"
        ;;
    ip)
        get_ip
        msg "$ip"
        ;;
    in | import)
        load import.sh
        ;;
    log)
        load log.sh
        log_set "${@:2}"
        ;;
    url | qr)
        url_qr "$@"
        ;;
    un | uninstall)
        uninstall
        ;;
    u | up | update | U | update.sh)
        is_update_name=$2
        is_update_ver=$3
        [[ ! $is_update_name ]] && is_update_name=core
        [[ $1 == 'U' || $1 == 'update.sh' ]] && {
            is_update_name=sh
            is_update_ver=
        }
        update "$is_update_name" ${is_update_ver:+"$is_update_ver"}
        ;;
    ssss | ss2022)
        get "$@"
        ;;
    s | status)
        [[ ${is_core_ver:-} ]] || init_core_ver
        core_status_read
        msg "\n$is_core_name $is_core_ver: $is_core_status\n"
        if [[ $is_caddy ]]; then
            msg "Caddy $is_caddy_ver: $is_caddy_status\n"
        fi
        ;;
    start | stop | r | restart)
        [[ $2 && $2 != 'caddy' ]] && { err "无法识别 ($2), 请使用: $is_core $1 [caddy]"; return 1; }
        service_action_result "$1" "$2"
        ;;
    reinstall)
        get "$1"
        ;;
    get-port)
        get_port
        msg "$tmp_port"
        ;;
    main)
        is_main_menu
        ;;
    v | ver | version)
        [[ ${is_core_ver:-} ]] || init_core_ver
        [[ $is_caddy_ver ]] && is_caddy_ver="/ $(_blue Caddy "$is_caddy_ver")"
        msg "\n$(_green "$is_core_name" "$is_core_ver") / $(_cyan "$is_script_name" script "$is_sh_ver") $is_caddy_ver\n"
        ;;
    h | help | --help)
        load help.sh
        show_help "${@:2}"
        ;;
    relay)
        relay_main "${@:2}"
        ;;
    *)
        is_change_id=
        is_try_change=1
        change test "$1"
        if [[ $is_change_id ]]; then
            unset is_try_change
            [[ $2 ]] && {
                change "$2" "$1" "${@:3}"
            } || {
                change
            }
        else
            err "无法识别 ($1), 获取帮助请使用: $is_core help"
            return 1
        fi
        ;;
    esac
}
