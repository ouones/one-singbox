#!/bin/bash

author=233boy

red='\e[31m'
yellow='\e[33m'
gray='\e[90m'
green='\e[92m'
blue='\e[94m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'
_red() { echo -e ${red}$@${none}; }
_blue() { echo -e ${blue}$@${none}; }
_cyan() { echo -e ${cyan}$@${none}; }
_green() { echo -e ${green}$@${none}; }
_yellow() { echo -e ${yellow}$@${none}; }
_magenta() { echo -e ${magenta}$@${none}; }
_red_bg() { echo -e "\e[41m$@${none}"; }

is_err=$(_red_bg 错误!)
is_warn=$(_red_bg 警告!)

err() {
    echo -e "\n$is_err $@\n" && exit 1
}

warn() {
    echo -e "\n$is_warn $@\n"
}

[[ $EUID != 0 ]] && err "当前非 ${yellow}ROOT用户.${none}"

cmd=$(type -P apt-get || type -P yum || type -P zypper || type -P apk)
[[ ! $cmd ]] && err "此脚本仅支持 ${yellow}(Ubuntu or Debian or CentOS or SUSE or Alpine)${none}."

is_systemd=$(type -P systemctl)
is_openrc=$(type -P rc-service)
[[ ! $is_systemd && ! $is_openrc ]] && {
    err "此系统缺少 ${yellow}(systemctl 或 rc-service)${none}, 请安装 systemd 或确认 OpenRC 已启用."
}

is_core=sing-box
is_core_name=sing-box
is_core_dir=/etc/$is_core
is_core_bin=$is_core_dir/bin/$is_core
is_core_repo=SagerNet/$is_core
is_conf_dir=$is_core_dir/conf
is_log_dir=/var/log/$is_core
is_sh_bin=/usr/local/bin/$is_core
is_sh_dir=$is_core_dir/sh
is_sh_repo=ouones/one-singbox
is_config_json=$is_core_dir/config.json
is_caddy_dir=/etc/caddy
is_caddy_bin=$(type -P caddy)
is_caddyfile=$is_caddy_dir/Caddyfile
is_caddy_conf=$is_caddy_dir/conf.d

load() {
    . $is_sh_dir/src/$1
}

_wget() {
    [[ $proxy ]] && export https_proxy=$proxy
    wget --no-check-certificate $*
}

if [[ -x $is_core_bin ]]; then
    is_core_ver=$($is_core_bin version 2>/dev/null | awk 'NR==1{print $3}')
fi
[[ -z $is_core_ver ]] && is_core_ver=unknown
if [[ -d $is_conf_dir ]] && compgen -G "$is_conf_dir/*.json" >/dev/null; then
    is_core_status=installed
else
    is_core_status=not-installed
fi
[[ -x $is_caddy_bin ]] && is_caddy=1

export LC_ALL=C

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
    "添加配置"
    "更改配置"
    "查看配置"
    "删除配置"
    "运行管理"
    "更新"
    "卸载"
    "帮助"
    "其他"
    "关于"
    "中转管理"
)
info_list=(
    "协议 (protocol)"
    "地址 (address)"
    "端口 (port)"
    "用户ID (id)"
    "传输协议 (network)"
    "伪装类型 (type)"
    "伪装域名 (host)"
    "路径 (path)"
    "传输层安全 (TLS)"
    "应用层协议协商 (Alpn)"
    "密码 (password)"
    "加密方式 (encryption)"
    "链接 (URL)"
    "目标地址 (remote addr)"
    "目标端口 (remote port)"
    "流控 (flow)"
    "SNI (serverName)"
    "指纹 (Fingerprint)"
    "公钥 (Public key)"
    "用户名 (Username)"
    "跳过证书验证 (allowInsecure)"
    "拥塞控制算法 (congestion_control)"
    "版本 (version)"
    "PSK"
    "混淆模式 (obfs_mode)"
    "运行模式 (mode)"
)
change_list=(
    "更改协议"
    "更改端口"
    "更改域名"
    "更改路径"
    "更改密码"
    "更改 UUID"
    "更改加密方式"
    "更改目标地址"
    "更改目标端口"
    "更改密钥"
    "更改 SNI (serverName)"
    "更改伪装网站"
    "更改用户名 (Username)"
    "更改节点名称"
    "更改出站方式"
    "更改入口地址"
    "查看当前节点链接"
    "更改 PSK"
    "更改 Snell 版本"
    "更改 Snell 混淆模式"
    "更改 Snell 运行模式"
)
outbound_mode_list=(
    "V6优先"
    "V4优先"
    "仅V4"
    "仅V6"
    "SS 出站"
)
servername_list=(
    www.amazon.com
    www.ebay.com
    www.paypal.com
    www.cloudflare.com
    dash.cloudflare.com
    aws.amazon.com
)

# shuf fallback for systems without shuf (e.g., Alpine BusyBox)
if ! type -P shuf &>/dev/null; then
    shuf() {
        local min max n
        while [[ $# -gt 0 ]]; do
            case $1 in
            -i) IFS=- read min max <<<"$2"; shift 2 ;;
            -n) n=$2; shift 2 ;;
            esac
        done
        echo $(( RANDOM % (max - min + 1) + min ))
    }
fi

is_random_ss_method=${ss_method_list[$(shuf -i 4-6 -n1)]} # random only use ss2022
is_random_servername=${servername_list[$(shuf -i 0-${#servername_list[@]} -n1) - 1]}

msg() {
    echo -e "$@"
}

msg_ul() {
    echo -e "\e[4m$@\e[0m"
}

# pause
pause() {
    echo
    echo -ne "按 $(_green Enter 回车键) 继续, 或按 $(_red Ctrl + C) 取消."
    read -rs -d $'\n'
    echo
}

get_uuid() {
    tmp_uuid=$(cat /proc/sys/kernel/random/uuid)
}

json_strip_comments() {
    awk '
    {
        line = ""
        in_string = 0
        escaped = 0
        for (i = 1; i <= length($0); i++) {
            char = substr($0, i, 1)
            if (in_string) {
                line = line char
                if (escaped) {
                    escaped = 0
                } else if (char == "\\") {
                    escaped = 1
                } else if (char == "\"") {
                    in_string = 0
                }
            } else if (char == "\"") {
                in_string = 1
                line = line char
            } else if (char == "/" && substr($0, i + 1, 1) == "/") {
                break
            } else {
                line = line char
            }
        }
        print line
    }' "$1"
}

get_snell_psk() {
    local psk
    psk=$(openssl rand -base64 32 2>/dev/null | tr -d '\n') || return 1
    [[ $psk ]] || return 1
    printf '%s\n' "$psk"
}

snell_version_valid() {
    [[ $1 == 5 || $1 == 6 ]]
}

snell_mode_valid() {
    [[ $1 =~ ^(default|unshaped|unsafe-raw)$ ]]
}

snell_mode_desc() {
    echo -e "\n------------- Snell v6 运行模式说明 (小白指南) -------------\n1. default    \e[92m[推荐]\e[0m   : 自动特征整型与动态填充，防封锁能力最强 (小白首选)\n2. unshaped   \e[96m[低延迟]\e[0m : 纯净直连无额外填充，延迟更低、更省流量 (适合游戏或中转)\n3. unsafe-raw \e[33m[极速]\e[0m   : 极高吞吐裸跑传输，无安全防御机制 (仅限内网专线或自建中转)\n-----------------------------------------------------------"
}

snell_obfs_mode_valid() {
    [[ $1 == none || $1 == http ]]
}

require_snell_support() {
    local version=${is_core_ver#v} major minor
    [[ $version =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || err "无法确认当前 sing-box 版本 ($is_core_ver), Snell 需要 sing-box 1.14.0 或更高版本."
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
    ((major > 1 || major == 1 && minor >= 14)) || err "当前 sing-box 版本 ($is_core_ver) 不支持 Snell, 请先升级 sing-box core 到 1.14.0 或更高版本."
}

config_port_used() {
    local wanted=$1 current=${2:-} file nullglob_was_set
    if shopt -q nullglob; then
        nullglob_was_set=1
    else
        nullglob_was_set=0
    fi
    shopt -s nullglob
    for file in "$is_conf_dir"/*.json; do
        [[ ${file##*/} == "$current" ]] && continue
        if jq -e --argjson port "$wanted" 'any(.inbounds[]?.listen_port?; . == $port)' "$file" >/dev/null 2>&1; then
            if ((nullglob_was_set)); then
                shopt -s nullglob
            else
                shopt -u nullglob
            fi
            return 0
        fi
    done
    if ((nullglob_was_set)); then
        shopt -s nullglob
    else
        shopt -u nullglob
    fi
    return 1
}

snell_config_port_used() {
    config_port_used "$@"
}

validate_snell() {
    local current_port
    require_snell_support
    [[ $(is_test port "$port") ]] || err "($port) 不是一个有效的端口. $is_err_tips"
    current_port=$(jq -r '.inbounds[0].listen_port // empty' "$is_conf_dir/${is_config_file:-missing}" 2>/dev/null)
    if [[ $port != "$current_port" ]] && [[ $(is_test port_used "$port") ]]; then
        err "无法使用 ($port) 端口. $is_err_tips"
    fi
    config_port_used "$port" "${is_config_file:-}" && err "无法使用 ($port) 端口. $is_err_tips"
    [[ $snell_psk ]] || err "Snell PSK 不能为空. $is_err_tips"
    snell_version_valid "$snell_version" || err "Snell 版本只支持 5 或 6. $is_err_tips"
    if [[ $snell_version == 6 ]]; then
        ((${#snell_psk} >= 12 && ${#snell_psk} <= 255)) || err "Snell v6 PSK 长度必须在 12 到 255 字符之间. $is_err_tips"
        snell_mode_valid "$snell_mode" || err "Snell 运行模式只支持 default, unshaped 或 unsafe-raw. $is_err_tips"
    else
        snell_obfs_mode_valid "$snell_obfs_mode" || err "Snell 混淆模式只支持 none 或 http. $is_err_tips"
    fi
}


get_ip() {
    [[ $ip || $is_no_auto_tls || $is_gen || $is_dont_get_ip ]] && return
    export "$(_wget -4 -qO- https://one.one.one.one/cdn-cgi/trace | grep ip=)" &>/dev/null
    [[ ! $ip ]] && export "$(_wget -6 -qO- https://one.one.one.one/cdn-cgi/trace | grep ip=)" &>/dev/null
    [[ ! $ip ]] && {
        err "获取服务器 IP 失败.."
    }
}

get_port() {
    is_count=0
    while :; do
        ((is_count++))
        if [[ $is_count -ge 233 ]]; then
            err "自动获取可用端口失败次数达到 233 次, 请检查端口占用情况."
        fi
        tmp_port=$(shuf -i 20000-65535 -n 1)
        [[ ! $(is_test port_used $tmp_port) && $tmp_port != $port ]] && break
    done
}

get_pbk() {
    is_tmp_pbk=($($is_core_bin generate reality-keypair | sed 's/.*://'))
    is_public_key=${is_tmp_pbk[1]}
    is_private_key=${is_tmp_pbk[0]}
}

show_list() {
    PS3=''
    COLUMNS=1
    select i in "$@"; do echo; done &
    wait
    # i=0
    # for v in "$@"; do
    #     ((i++))
    #     echo "$i) $v"
    # done
    # echo

}

is_test() {
    case $1 in
    number)
        echo $2 | grep -E '^[1-9][0-9]?+$'
        ;;
    port)
        if [[ $(is_test number $2) ]]; then
            [[ $2 -le 65535 ]] && echo ok
        fi
        ;;
    port_used)
        [[ $(is_port_used $2) && ! $is_cant_test_port ]] && echo ok
        ;;
    domain)
        echo $2 | grep -E -i '^\w(\w|\-|\.)?+\.\w+$'
        ;;
    path)
        echo $2 | grep -E -i '^\/\w(\w|\-|\/)?+\w$'
        ;;
    uuid)
        echo $2 | grep -E -i '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        ;;
    esac

}

is_port_used() {
    if [[ $(type -P netstat) ]]; then
        [[ ! $is_used_port ]] && is_used_port="$(netstat -tunlp | sed -n 's/.*:\([0-9]\+\).*/\1/p' | sort -nu)"
        echo $is_used_port | sed 's/ /\n/g' | grep ^${1}$
        return
    fi
    if [[ $(type -P ss) ]]; then
        [[ ! $is_used_port ]] && is_used_port="$(ss -tunlp | sed -n 's/.*:\([0-9]\+\).*/\1/p' | sort -nu)"
        echo $is_used_port | sed 's/ /\n/g' | grep ^${1}$
        return
    fi
    is_cant_test_port=1
    msg "$is_warn 无法检测端口是否可用."
    msg "请执行: $(_yellow "${cmd} update -y; ${cmd} install net-tools -y") 来修复此问题."
}

# ask input a string or pick a option for list.
ask() {
    case $1 in
    set_ss_method)
        is_tmp_list=(${ss_method_list[@]})
        is_default_arg=$is_random_ss_method
        is_opt_msg="\n请选择加密方式:\n"
        is_opt_input_msg="(默认\e[92m $is_default_arg\e[0m):"
        is_ask_set=ss_method
        ;;
    set_protocol)
        is_tmp_list=(${protocol_list[@]})
        [[ $is_no_auto_tls ]] && {
            unset is_tmp_list
            for v in ${protocol_list[@]}; do
                [[ $(grep -i "\-tls$" <<<$v) ]] && is_tmp_list=(${is_tmp_list[@]} $v)
            done
        }
        is_opt_msg="\n请选择协议:\n"
        is_ask_set=is_new_protocol
        ;;
    set_change_list)
        is_tmp_list=()
        for v in ${is_can_change[@]}; do
            is_tmp_list+=("${change_list[$v]}")
        done
        is_opt_msg="\n请选择更改:\n"
        is_ask_set=is_change_str
        is_opt_input_msg=$3
        ;;
    set_outbound_mode)
        is_tmp_list=("${outbound_mode_list[@]}")
        is_opt_msg="\n当前出站方式: $(current_outbound_mode_display "$is_config_file")\n\n请选择出站方式:\n"
        is_ask_set=is_outbound_mode
        ;;
    string)
        is_ask_set=$2
        is_opt_input_msg=$3
        ;;
    list)
        is_ask_set=$2
        [[ ! $is_tmp_list ]] && is_tmp_list=($3)
        is_opt_msg=$4
        is_opt_input_msg=$5
        ;;
    get_config_file)
        is_tmp_list=("${is_all_json[@]}")
        is_opt_msg="\n请选择配置:\n"
        is_ask_set=is_config_file
        ;;
    mainmenu)
        is_tmp_list=("${mainmenu[@]}")
        is_ask_set=is_main_pick
        is_emtpy_exit=1
        ;;
    esac
    msg $is_opt_msg
    [[ ! $is_opt_input_msg ]] && is_opt_input_msg="请选择 [\e[91m1-${#is_tmp_list[@]}\e[0m]:"
    [[ $is_tmp_list ]] && show_list "${is_tmp_list[@]}"
    while :; do
        echo -ne $is_opt_input_msg
        read REPLY
        [[ ! $REPLY && $is_emtpy_exit ]] && exit
        [[ ! $REPLY && $is_default_arg ]] && export "$is_ask_set=$is_default_arg" && break
        [[ "$REPLY" == "${is_str}2${is_get}3${is_opt}3" && $is_ask_set == 'is_main_pick' ]] && {
            msg "\n${is_get}2${is_str}3${is_msg}3b${is_tmp}o${is_opt}y\n" && exit
        }
        if [[ ! $is_tmp_list ]]; then
            [[ $(grep port <<<$is_ask_set) ]] && {
                [[ ! $(is_test port "$REPLY") ]] && {
                    msg "$is_err 请输入正确的端口, 可选(1-65535)"
                    continue
                }
                if [[ $(is_test port_used $REPLY) && $is_ask_set != 'door_port' ]]; then
                    msg "$is_err 无法使用 ($REPLY) 端口."
                    continue
                fi
            }
            [[ $(grep path <<<$is_ask_set) && ! $(is_test path "$REPLY") ]] && {
                [[ ! $tmp_uuid ]] && get_uuid
                msg "$is_err 请输入正确的路径, 例如: /$tmp_uuid"
                continue
            }
            [[ $(grep uuid <<<$is_ask_set) && ! $(is_test uuid "$REPLY") ]] && {
                [[ ! $tmp_uuid ]] && get_uuid
                msg "$is_err 请输入正确的 UUID, 例如: $tmp_uuid"
                continue
            }
            [[ $(grep ^y$ <<<$is_ask_set) ]] && {
                [[ $(grep -i ^y$ <<<"$REPLY") ]] && break
                msg "请输入 (y)"
                continue
            }
            [[ $REPLY ]] && export "$is_ask_set=$REPLY" && msg "使用: ${!is_ask_set}" && break
        else
            [[ $(is_test number "$REPLY") ]] && is_ask_result=${is_tmp_list[$REPLY - 1]}
            [[ $is_ask_result ]] && export $is_ask_set="$is_ask_result" && msg "选择: ${!is_ask_set}" && break
        fi

        msg "输入${is_err}"
    done
    unset is_opt_msg is_opt_input_msg is_tmp_list is_ask_result is_default_arg is_emtpy_exit
}

meta_dir() {
    echo "$is_conf_dir/.quan-meta"
}

meta_file() {
    echo "$(meta_dir)/$1.meta.json"
}

meta_get() {
    local f
    f=$(meta_file "$1")
    [[ -f "$f" ]] || return
    jq -r "$2 // empty" "$f" 2>/dev/null
}

meta_set() {
    local cfg=$1
    local key=$2
    local val=$3
    local f
    f=$(meta_file "$cfg")
    mkdir -p "$(meta_dir)"
    if [[ -f "$f" ]]; then
        jq --arg v "$val" ".$key=\$v" "$f" >"$f.tmp" && mv -f "$f.tmp" "$f"
    else
        jq -n --arg v "$val" "{$key:\$v}" >"$f"
    fi
}

meta_move() {
    local old=$1
    local new=$2
    local of nf
    of=$(meta_file "$old")
    nf=$(meta_file "$new")
    [[ -f "$of" ]] && mv -f "$of" "$nf"
}

meta_rm() {
    local cfg=$1
    local f
    f=$(meta_file "$cfg")
    [[ -f "$f" ]] && rm -f "$f"
}

node_name_for_link() {
    local cfg=$1
    local name
    name=$(meta_get "$cfg" '.node_name')
    [[ $name ]] && {
        echo "$name"
        return
    }
    echo "${cfg%.json}"
}

outbound_mode_to_direct_tag() {
    case $1 in
    "V6优先") echo direct_v6_pref ;;
    "V4优先") echo direct_v4_pref ;;
    "仅V4") echo direct_v4_only ;;
    "仅V6") echo direct_v6_only ;;
    *) return 1 ;;
    esac
}

current_outbound_mode_display() {
    local cfg=$1 mode name server port
    [[ $cfg ]] || {
        echo 未设置
        return
    }
    mode=$(meta_get "$cfg" '.outbound_mode')
    [[ $mode ]] || {
        echo 未设置
        return
    }
    if [[ $mode == 'SS 出站' ]]; then
        name=$(meta_get "$cfg" '.outbound_ss_name')
        [[ $name ]] && {
            echo "$mode ($name)"
            return
        }
        server=$(meta_get "$cfg" '.outbound_ss_server')
        port=$(meta_get "$cfg" '.outbound_ss_port')
        [[ $server && $port ]] && {
            echo "$mode ($server:$port)"
            return
        }
    fi
    echo "$mode"
}

runtime_node_ss_outbound_tag() {
    local cfg=$1 safe
    safe=${cfg//[^[:alnum:]_-]/_}
    echo "managed_node_ss_$safe"
}

runtime_domain_resolver_tag() {
    jq -r 'if (.route.default_domain_resolver | type) == "string" then .route.default_domain_resolver elif (.route.default_domain_resolver | type) == "object" then (.route.default_domain_resolver.server // "local") else "local" end' "$is_config_json" 2>/dev/null
}

sync_runtime_node_outbound_modes() {
    local resolver rules ss_outbounds tmp file cfg mode outbound server port method password
    [[ -f "$is_config_json" ]] || return

    resolver=$(runtime_domain_resolver_tag)
    [[ $resolver ]] || resolver=local
    rules='[]'
    ss_outbounds='[]'
    shopt -s nullglob
    for file in "$is_conf_dir"/*.json; do
        cfg=${file##*/}
        [[ $cfg =~ dynamic-port-.*-link ]] && continue
        mode=$(meta_get "$cfg" '.outbound_mode')
        [[ $mode ]] || continue
        outbound=$(outbound_mode_to_direct_tag "$mode")
        if [[ $outbound ]]; then
            rules=$(jq --arg inbound "$cfg" --arg outbound "$outbound" '. += [{inbound:[$inbound],action:"route",outbound:$outbound}]' <<<"$rules")
            continue
        fi
        [[ $mode == 'SS 出站' ]] || continue
        server=$(meta_get "$cfg" '.outbound_ss_server')
        port=$(meta_get "$cfg" '.outbound_ss_port')
        method=$(meta_get "$cfg" '.outbound_ss_method')
        password=$(meta_get "$cfg" '.outbound_ss_password')
        [[ $server && $port && $method && $password ]] || continue
        ss_method_supported "$method" || continue
        [[ $(is_test port "$port") ]] || continue
        ss_password_valid_for_method "$method" "$password" || continue
        outbound=$(runtime_node_ss_outbound_tag "$cfg")
        ss_outbounds=$(jq --arg tag "$outbound" --arg server "$server" --argjson port "$port" --arg method "$method" --arg password "$password" '. += [{tag:$tag,type:"shadowsocks",server:$server,server_port:$port,method:$method,password:$password}]' <<<"$ss_outbounds")
        rules=$(jq --arg inbound "$cfg" --arg outbound "$outbound" '. += [{inbound:[$inbound],action:"route",outbound:$outbound}]' <<<"$rules")
    done
    shopt -u nullglob

    tmp="$is_config_json.tmp"
    jq --arg resolver "$resolver" --argjson rules "$rules" --argjson ss_outbounds "$ss_outbounds" '
        def managed_tags: ["direct_v6_pref","direct_v4_pref","direct_v4_only","direct_v6_only"];
        def managed_outbounds($r): [
            {tag:"direct_v6_pref",type:"direct",domain_resolver:{server:$r,strategy:"prefer_ipv6"}},
            {tag:"direct_v4_pref",type:"direct",domain_resolver:{server:$r,strategy:"prefer_ipv4"}},
            {tag:"direct_v4_only",type:"direct",domain_resolver:{server:$r,strategy:"ipv4_only"}},
            {tag:"direct_v6_only",type:"direct",domain_resolver:{server:$r,strategy:"ipv6_only"}}
        ];
        def is_managed_ss_tag($tag): $tag | startswith("managed_node_ss_");
        .dns = (.dns // {})
        | if (($rules | length) > 0 and $resolver == "local") then
            .dns.servers = (if (.dns.servers | type) == "array" then .dns.servers else [] end)
            | if any(.dns.servers[]?; .tag == "local") then . else .dns.servers += [{tag:"local",type:"local"}] end
          else . end
        | del(.dns.strategy)
        | .route = (.route // {})
        | if (.route.default_domain_resolver | type) == "object" then
            if ((.route.default_domain_resolver.server // "") | length) > 0 then
                .route.default_domain_resolver = .route.default_domain_resolver.server
            else
                del(.route.default_domain_resolver)
            end
          elif (.route.default_domain_resolver | type) == "string" and ((.route.default_domain_resolver // "") | length) == 0 then
            del(.route.default_domain_resolver)
          else . end
        | .outbounds = ((.outbounds // []) | map(select(((.tag // "") as $tag | (managed_tags | index($tag) | not) and (is_managed_ss_tag($tag) | not)))))
        | if (($rules | length) > 0) then .outbounds += managed_outbounds($resolver) + $ss_outbounds else . end
        | .route.rules = ((.route.rules // []) | map(select(((.outbound // "") as $outbound | (managed_tags | index($outbound) | not) and (is_managed_ss_tag($outbound) | not))))) + $rules
    ' "$is_config_json" >"$tmp" && mv -f "$tmp" "$is_config_json"
}

is_valid_ipv4_addr() {
    local addr=$1
    [[ $addr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r o1 o2 o3 o4 <<<"$addr"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [[ $o -le 255 ]] || return 1
    done
    return 0
}

is_valid_entry_addr() {
    local addr=$1
    [[ $(is_test domain "$addr") ]] && return 0
    is_valid_ipv4_addr "$addr" && return 0
    [[ $addr == *:* ]] && getent ahostsv6 "$addr" >/dev/null 2>&1 && return 0
    return 1
}

get_public_entry_addr() {
    get_ip
    [[ $ip ]] || err "无法获取公网 IP"
    echo "$ip"
}

random_node_name() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8
}

ss_password_for_method() {
    local method=$1
    if [[ $(grep 128 <<<$method) ]]; then
        $is_core_bin generate rand 16 --base64
    else
        $is_core_bin generate rand 32 --base64
    fi
}

ss_password_valid_for_method() {
    local method=$1 password=$2 expected_len decoded_len
    [[ $method != *2022* ]] && return 0
    [[ $password ]] || return 1
    [[ $(grep 128 <<<$method) ]] && expected_len=16 || expected_len=32
    decoded_len=$(printf '%s' "$password" | base64 -d 2>/dev/null | wc -c)
    [[ ${decoded_len// /} -eq $expected_len ]]
}

ss_base64_decode() {
    local input=$1 mod
    input=${input//-/+}
    input=${input//_/\/}
    mod=$((${#input} % 4))
    [[ $mod == 1 ]] && return 1
    [[ $mod == 2 ]] && input+="=="
    [[ $mod == 3 ]] && input+="="
    printf '%s' "$input" | base64 -d 2>/dev/null
}

ss_method_supported() {
    local method=$1 v
    for v in ${ss_method_list[@]}; do
        [[ $v == "$method" ]] && return 0
    done
    return 1
}

url_decode() {
    local s=${1//+/ }
    printf '%b' "${s//%/\\x}"
}

parse_ss_uri_for_outbound() {
    local uri auth endpoint raw_name decoded_auth
    uri=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<$1)
    [[ $uri == ss://* ]] || return 1
    uri=${uri#ss://}
    if [[ $uri == *#* ]]; then
        raw_name=${uri#*#}
        uri=${uri%%#*}
    fi
    [[ $uri == *\?* ]] && return 1
    [[ $uri == *@* ]] || return 1
    auth=${uri%@*}
    endpoint=${uri#*@}
    decoded_auth=$(ss_base64_decode "$auth") || return 1
    [[ $decoded_auth == *:* ]] || return 1
    is_outbound_ss_method=${decoded_auth%%:*}
    is_outbound_ss_password=${decoded_auth#*:}
    is_outbound_ss_server=${endpoint%:*}
    is_outbound_ss_port=${endpoint##*:}
    [[ $is_outbound_ss_server && $is_outbound_ss_port && $is_outbound_ss_server != "$endpoint" ]] || return 1
    ss_method_supported "$is_outbound_ss_method" || return 1
    [[ $(is_test port "$is_outbound_ss_port") ]] || return 1
    [[ $is_outbound_ss_password ]] || return 1
    ss_password_valid_for_method "$is_outbound_ss_method" "$is_outbound_ss_password" || return 1
    is_outbound_ss_name=$(url_decode "$raw_name")
}

resolve_entry_addr_for_listen() {
    local addr=$1
    if [[ $(is_test domain "$addr") ]]; then
        getent ahostsv4 "$addr" 2>/dev/null | awk 'NR==1{print $1; exit}' && return 0
        getent ahostsv6 "$addr" 2>/dev/null | awk 'NR==1{print $1; exit}' && return 0
        return 1
    fi
    echo "$addr"
}

sync_entry_addr_config() {
    local cfg=$1
    local entry=$2
    local file="$is_conf_dir/$cfg"
    local listen_addr tmp normalized_entry

    [[ -f "$file" ]] || err "配置文件不存在: $cfg"

    normalized_entry=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$entry")
    if [[ ! $normalized_entry ]] || ! is_valid_entry_addr "$normalized_entry"; then
        normalized_entry=$(get_public_entry_addr)
    fi

    if jq -e '.inbounds[0].transport.headers.host? != null' "$file" >/dev/null 2>&1; then
        tmp="$file.tmp"
        jq --arg addr "$normalized_entry" '.inbounds[0].transport.headers.host = $addr' "$file" >"$tmp" && mv -f "$tmp" "$file"
        meta_set "$cfg" entry_addr "$normalized_entry"
        echo "$normalized_entry"
        return
    fi

    listen_addr=$(resolve_entry_addr_for_listen "$normalized_entry") || listen_addr=$(get_public_entry_addr)
    tmp="$file.tmp"
    jq --arg addr "$listen_addr" '.inbounds[0].listen = $addr' "$file" >"$tmp" && mv -f "$tmp" "$file"
    meta_set "$cfg" entry_addr "$normalized_entry"
    echo "$normalized_entry"
}

# create file
create() {
    case $1 in
    server)
        local preserved_node_name preserved_entry_addr preserved_outbound_mode preserved_outbound_ss_server preserved_outbound_ss_port preserved_outbound_ss_method preserved_outbound_ss_password preserved_outbound_ss_name previous_config_file is_snell_tmp_file
        is_tls=none
        get new
        # listen
        is_listen='listen: "::"'
        # file name: protocol + port
        is_config_name=${2}-${port}.json
        [[ ${2,,} == snell ]] && is_config_name=snell-${port}.json
        [[ $host ]] && is_listen='listen: "127.0.0.1"'
        is_json_file=$is_conf_dir/$is_config_name
        # get json
        [[ $is_change || ! $json_str ]] && get protocol $2
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
            is_snell_tmp_file=$(mktemp "$is_conf_dir/.snell-XXXXXX") || err "无法创建 Snell 临时配置文件."
            printf '%s\n' "$is_new_json" >"$is_snell_tmp_file"
            if ! "$is_core_bin" check -c "$is_snell_tmp_file" &>/dev/null; then
                rm -f "$is_snell_tmp_file"
                err "Snell 配置校验失败."
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
            jq <<<$is_new_json
            msg
            return
        }
        [[ $is_change && $is_config_file ]] && preserved_node_name=$(meta_get "$is_config_file" '.node_name')
        [[ $is_change && $is_config_file ]] && preserved_entry_addr=$(meta_get "$is_config_file" '.entry_addr')
        [[ $is_change && $is_config_file ]] && preserved_outbound_mode=$(meta_get "$is_config_file" '.outbound_mode')
        [[ $is_change && $is_config_file ]] && preserved_outbound_ss_server=$(meta_get "$is_config_file" '.outbound_ss_server')
        [[ $is_change && $is_config_file ]] && preserved_outbound_ss_port=$(meta_get "$is_config_file" '.outbound_ss_port')
        [[ $is_change && $is_config_file ]] && preserved_outbound_ss_method=$(meta_get "$is_config_file" '.outbound_ss_method')
        [[ $is_change && $is_config_file ]] && preserved_outbound_ss_password=$(meta_get "$is_config_file" '.outbound_ss_password')
        [[ $is_change && $is_config_file ]] && preserved_outbound_ss_name=$(meta_get "$is_config_file" '.outbound_ss_name')
        previous_config_file=$is_config_file
        if [[ ${2,,} == snell ]]; then
            if ! mv -f "$is_snell_tmp_file" "$is_json_file"; then
                rm -f "$is_snell_tmp_file"
                err "保存 Snell 配置失败, 原有配置未改变."
            fi
            if [[ $previous_config_file && $previous_config_file != "$is_config_name" ]]; then
                rm -f "$is_conf_dir/$previous_config_file"
                meta_move "$previous_config_file" "$is_config_name"
            fi
        else
            [[ $is_config_file ]] && is_no_del_msg=1 && del $is_config_file
            cat <<<$is_new_json >"$is_json_file"
        fi
        [[ $preserved_node_name && $is_config_name ]] && meta_set "$is_config_name" node_name "$preserved_node_name"
        [[ $preserved_entry_addr && $is_config_name ]] && meta_set "$is_config_name" entry_addr "$preserved_entry_addr"
        [[ $preserved_outbound_mode && $is_config_name ]] && meta_set "$is_config_name" outbound_mode "$preserved_outbound_mode"
        [[ $preserved_outbound_ss_server && $is_config_name ]] && meta_set "$is_config_name" outbound_ss_server "$preserved_outbound_ss_server"
        [[ $preserved_outbound_ss_port && $is_config_name ]] && meta_set "$is_config_name" outbound_ss_port "$preserved_outbound_ss_port"
        [[ $preserved_outbound_ss_method && $is_config_name ]] && meta_set "$is_config_name" outbound_ss_method "$preserved_outbound_ss_method"
        [[ $preserved_outbound_ss_password && $is_config_name ]] && meta_set "$is_config_name" outbound_ss_password "$preserved_outbound_ss_password"
        [[ $preserved_outbound_ss_name && $is_config_name ]] && meta_set "$is_config_name" outbound_ss_name "$preserved_outbound_ss_name"
        [[ $is_config_name ]] && is_config_file=$is_config_name
        [[ $is_change && $previous_config_file && $previous_config_file != $is_config_name ]] && msg "\n配置文件修改成功: $(_green $previous_config_file) -> $(_green $is_config_name)\n"
        sync_runtime_node_outbound_modes
        if [[ $is_new_install ]]; then
            # config.json
            create config.json
        fi
        # caddy auto tls
        [[ $is_caddy && $host && ! $is_no_auto_tls ]] && {
            create caddy $net
        }
        # restart core
        manage restart &
        ;;
    client)
        is_tls=tls
        is_client=1
        get info $2
        [[ ! $is_client_id_json ]] && err "($is_config_name) 不支持生成客户端配置."
        is_new_json=$(jq '{outbounds:[{tag:'\"$is_config_name\"',protocol:'\"$is_protocol\"','"$is_client_id_json"','"$is_stream"'}]}' <<<{})
        msg
        jq <<<$is_new_json
        msg
        ;;
    caddy)
        load caddy.sh
        [[ $is_install_caddy ]] && caddy_config new
        [[ ! $(grep "$is_caddy_conf" $is_caddyfile) ]] && {
            msg "import $is_caddy_conf/*.conf" >>$is_caddyfile
        }
        [[ ! -d $is_caddy_conf ]] && mkdir -p $is_caddy_conf
        caddy_config $2
        manage restart caddy &
        ;;
    config.json)
        is_log='log:{output:"/var/log/'$is_core'/access.log",level:"info","timestamp":true}'
        is_dns='dns:{}'
        is_ntp='ntp:{"enabled":true,"server":"time.apple.com"},'
        if [[ -f $is_config_json ]]; then
            [[ $(jq .ntp.enabled $is_config_json) != "true" ]] && is_ntp=
        else
            [[ ! $is_ntp_on ]] && is_ntp=
        fi
        is_outbounds='outbounds:[{tag:"direct",type:"direct"}]'
        is_server_config_json=$(jq "{$is_log,$is_dns,$is_ntp$is_outbounds}" <<<{})
        cat <<<$is_server_config_json >$is_config_json
        sync_runtime_node_outbound_modes
        manage restart &
        ;;
    esac
}

# change config file
change() {
    is_change=1
    is_dont_show_info=1
    is_auto=
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
        *)
            [[ $is_try_change ]] && return
            err "无法识别 ($2) 更改类型."
            ;;
        esac
    fi
    [[ $is_try_change ]] && return
    [[ $is_dont_auto_exit ]] && {
        get info $1
    } || {
        [[ $is_change_id ]] && {
            is_change_msg=${change_list[$is_change_id]}
            [[ $is_change_id == 'full' ]] && {
                [[ $3 ]] && is_change_msg="更改多个参数" || is_change_msg=
            }
            [[ $is_change_msg ]] && _green "\n快速执行: $is_change_msg"
        }
        info $1
        [[ $is_auto_get_config ]] && msg "\n自动选择: $is_config_file"
    }
    is_old_net=$net
    [[ $is_tcp_http ]] && net=http
    [[ $host ]] && net=$is_protocol-$net-tls
    [[ $is_reality && $net_type =~ 'http' ]] && net=rh2

    [[ $3 == 'auto' ]] && is_auto=1 || is_auto=
    # if is_dont_show_info exist, cant show info.
    is_dont_show_info=
    # if not prefer args, show change list and then get change id.
    [[ ! $is_change_id ]] && {
        ask set_change_list
        is_change_id=${is_can_change[$REPLY - 1]}
    }
    case $is_change_id in
    full)
        add "$net" "${@:3}"
        ;;
    0)
        # new protocol
        is_set_new_protocol=1
        add "${@:3}"
        ;;
    1)
        # new port
        is_new_port=$3
        [[ $host && ! $is_caddy || $is_no_auto_tls ]] && err "($is_config_file) 不支持更改端口, 因为没啥意义."
        if [[ $is_new_port && ! $is_auto ]]; then
            [[ ! $(is_test port $is_new_port) ]] && err "请输入正确的端口, 可选(1-65535)"
            [[ $is_new_port != 443 && $(is_test port_used $is_new_port) && ${is_protocol,,} != snell ]] && err "无法使用 ($is_new_port) 端口"
        fi
        [[ $is_auto ]] && get_port && is_new_port=$tmp_port
        [[ ! $is_new_port ]] && ask string is_new_port "请输入新端口:"
        if [[ $is_caddy && $host ]]; then
            net=$is_old_net
            is_https_port=$is_new_port
            load caddy.sh
            caddy_config $net
            manage restart caddy &
            info
        else
            add $net $is_new_port
        fi
        ;;
    2)
        # new host
        is_new_host=$3
        [[ ! $host ]] && err "($is_config_file) 不支持更改域名."
        [[ ! $is_new_host ]] && ask string is_new_host "请输入新域名:"
        old_host=$host # del old host
        add $net $is_new_host
        ;;
    3)
        # new path
        is_new_path=$3
        [[ ! $path ]] && err "($is_config_file) 不支持更改路径."
        [[ $is_auto ]] && get_uuid && is_new_path=/$tmp_uuid
        [[ ! $is_new_path ]] && ask string is_new_path "请输入新路径:"
        add $net auto auto $is_new_path
        ;;
    4)
        # new password
        is_new_pass=$3
        if [[ $ss_password || $password ]]; then
            [[ $is_auto ]] && {
                get_uuid && is_new_pass=$tmp_uuid
                [[ $ss_password ]] && is_new_pass=$(get ss2022)
            }
        else
            err "($is_config_file) 不支持更改密码."
        fi
        [[ ! $is_new_pass ]] && ask string is_new_pass "请输入新密码:"
        password=$is_new_pass
        ss_password=$is_new_pass
        is_socks_pass=$is_new_pass
        add $net
        ;;
    5)
        # new uuid
        is_new_uuid=$3
        [[ ! $uuid ]] && err "($is_config_file) 不支持更改 UUID."
        [[ $is_auto ]] && get_uuid && is_new_uuid=$tmp_uuid
        [[ ! $is_new_uuid ]] && ask string is_new_uuid "请输入新 UUID:"
        add $net auto $is_new_uuid
        ;;
    6)
        # new method
        is_new_method=$3
        is_new_ss_password=$ss_password
        [[ $net != 'ss' ]] && err "($is_config_file) 不支持更改加密方式."
        [[ $is_auto ]] && is_new_method=$is_random_ss_method
        [[ ! $is_new_method ]] && {
            ask set_ss_method
            is_new_method=$ss_method
        }
        if [[ $(grep 2022 <<<$is_new_method) ]] && ! ss_password_valid_for_method "$is_new_method" "$is_new_ss_password"; then
            is_new_ss_password=$(ss_password_for_method "$is_new_method")
            msg "\n已根据新的加密方式自动更新密码: $(_green $is_new_ss_password)\n"
        fi
        [[ $is_new_ss_password ]] && add $net auto "$is_new_ss_password" $is_new_method || add $net auto auto $is_new_method
        ;;
    7)
        # new remote addr
        is_new_door_addr=$3
        [[ $net != 'direct' ]] && err "($is_config_file) 不支持更改目标地址."
        [[ ! $is_new_door_addr ]] && ask string is_new_door_addr "请输入新的目标地址:"
        door_addr=$is_new_door_addr
        add $net
        ;;
    8)
        # new remote port
        is_new_door_port=$3
        [[ $net != 'direct' ]] && err "($is_config_file) 不支持更改目标端口."
        [[ ! $is_new_door_port ]] && {
            ask string door_port "请输入新的目标端口:"
            is_new_door_port=$door_port
        }
        add $net auto auto $is_new_door_port
        ;;
    9)
        # new is_private_key is_public_key
        is_new_private_key=$3
        is_new_public_key=$4
        [[ ! $is_reality ]] && err "($is_config_file) 不支持更改密钥."
        if [[ $is_auto ]]; then
            get_pbk
            add $net
        else
            [[ $is_new_private_key && ! $is_new_public_key ]] && {
                err "无法找到 Public key."
            }
            [[ ! $is_new_private_key ]] && ask string is_new_private_key "请输入新 Private key:"
            [[ ! $is_new_public_key ]] && ask string is_new_public_key "请输入新 Public key:"
            if [[ $is_new_private_key == $is_new_public_key ]]; then
                err "Private key 和 Public key 不能一样."
            fi
            is_tmp_json=$is_conf_dir/$is_config_file-$uuid
            cp -f "$is_conf_dir/$is_config_file" "$is_tmp_json"
            sed -i s#$is_private_key #$is_new_private_key# $is_tmp_json
            $is_core_bin check -c $is_tmp_json &>/dev/null
            if [[ $? != 0 ]]; then
                is_key_err=1
                is_key_err_msg="Private key 无法通过测试."
            fi
            sed -i s#$is_new_private_key #$is_new_public_key# $is_tmp_json
            $is_core_bin check -c $is_tmp_json &>/dev/null
            if [[ $? != 0 ]]; then
                is_key_err=1
                is_key_err_msg+="Public key 无法通过测试."
            fi
            rm "$is_tmp_json"
            [[ $is_key_err ]] && err $is_key_err_msg
            is_private_key=$is_new_private_key
            is_public_key=$is_new_public_key
            is_test_json=
            add $net
        fi
        ;;
    10)
        # new serverName
        is_new_servername=$3
        [[ ! $is_reality ]] && err "($is_config_file) 不支持更改 serverName."
        [[ $is_auto ]] && is_new_servername=$is_random_servername
        [[ ! $is_new_servername ]] && ask string is_new_servername "请输入新的 serverName:"
        is_servername=$is_new_servername
        [[ $(grep -i "^233boy.com$" <<<$is_servername) ]] && {
            err "你干嘛～哎呦～"
        }
        add $net
        ;;
    11)
        # new proxy site
        is_new_proxy_site=$3
        [[ ! $is_caddy && ! $host ]] && {
            err "($is_config_file) 不支持更改伪装网站."
        }
        [[ ! -f $is_caddy_conf/${host}.conf.add ]] && err "无法配置伪装网站."
        [[ ! $is_new_proxy_site ]] && ask string is_new_proxy_site "请输入新的伪装网站 (例如 example.com):"
        proxy_site=$(sed 's#^.*//##;s#/$##' <<<$is_new_proxy_site)
        [[ $(grep -i "^233boy.com$" <<<$proxy_site) ]] && {
            err "你干嘛～哎呦～"
        } || {
            load caddy.sh
            caddy_config proxy
            manage restart caddy &
        }
        msg "\n已更新伪装网站为: $(_green $proxy_site) \n"
        ;;
    12)
        # new socks user
        [[ ! $is_socks_user ]] && err "($is_config_file) 不支持更改用户名 (Username)."
        ask string is_socks_user "请输入新用户名 (Username):"
        add $net
        ;;
    13)
        # update share link node name (does not rename json file)
        is_new_name=$3
        [[ ! $is_new_name ]] && ask string is_new_name "请输入新节点名称:"
        is_new_name=${is_new_name%.json}
        [[ ! $is_new_name ]] && err "节点名称不能为空."
        is_old_name=$(node_name_for_link "$is_config_file")
        [[ "$is_old_name" == "$is_new_name" ]] && err "新节点名称与当前名称一致."
        meta_set "$is_config_file" node_name "$is_new_name"
        msg "\n已更新节点名称为: $(_green $is_new_name)\n"
        info
        ;;
    14)
        ask set_outbound_mode
        if [[ $is_outbound_mode == 'SS 出站' ]]; then
            ask string is_outbound_ss_uri "请输入 SS 节点链接:"
            parse_ss_uri_for_outbound "$is_outbound_ss_uri" || err "SS 节点链接格式无效, 目前仅支持 ss://BASE64(method:password)@host:port#name"
            meta_set "$is_config_file" outbound_ss_server "$is_outbound_ss_server"
            meta_set "$is_config_file" outbound_ss_port "$is_outbound_ss_port"
            meta_set "$is_config_file" outbound_ss_method "$is_outbound_ss_method"
            meta_set "$is_config_file" outbound_ss_password "$is_outbound_ss_password"
            meta_set "$is_config_file" outbound_ss_name "$is_outbound_ss_name"
        fi
        meta_set "$is_config_file" outbound_mode "$is_outbound_mode"
        [[ -f "$is_config_json" ]] || create config.json
        sync_runtime_node_outbound_modes
        manage restart &
        msg "\n已更新出站方式为: $(_green $(current_outbound_mode_display "$is_config_file"))\n"
        ;;
    15)
        is_new_entry_addr=$3
        if [[ -z $is_new_entry_addr ]]; then
            echo -ne "请输入新的入口地址(IP或域名):"
            read is_new_entry_addr
        fi
        is_new_entry_addr=$(sync_entry_addr_config "$is_config_file" "$is_new_entry_addr")
        msg "\n已更新入口地址为: $(_green $is_new_entry_addr)\n"
        info
        ;;
    17)
        # psk
        [[ $is_protocol == snell ]] || err "($is_config_file) 不支持更改 Snell PSK."
        is_new_snell_psk=$3
        [[ $is_auto ]] && is_new_snell_psk=$(get_snell_psk)
        [[ ! $is_new_snell_psk ]] && ask string is_new_snell_psk "请输入新的 Snell PSK:"
        if [[ $snell_version == 6 ]]; then
            ((${#is_new_snell_psk} >= 12 && ${#is_new_snell_psk} <= 255)) || err "Snell v6 PSK 长度必须在 12 到 255 字符之间. $is_err_tips"
        fi
        snell_psk=$is_new_snell_psk
        add snell
        ;;
    18)
        # snell-version
        [[ $is_protocol == snell ]] || err "($is_config_file) 不支持更改 Snell 版本."
        is_new_snell_version=$3
        [[ $is_auto ]] && is_new_snell_version=6
        [[ ! $is_new_snell_version ]] && {
            ask string is_new_snell_version "请输入新的 Snell 版本 [5/6]:"
        }
        snell_version_valid "$is_new_snell_version" || err "Snell 版本只支持 5 或 6. $is_err_tips"
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
        [[ $is_protocol == snell ]] || err "($is_config_file) 不支持更改 Snell 混淆模式."
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
            is_tmp_list=(default unshaped unsafe-raw)
            ask list is_new_snell_mode "${is_tmp_list[*]}" "\n当前为 Snell v6 节点，请选择运行模式:\n$(snell_mode_desc)\n"
            snell_mode=$is_new_snell_mode
            add snell
            return
        fi
        is_new_snell_obfs_mode=$3
        [[ $is_new_snell_obfs_mode == auto ]] && is_new_snell_obfs_mode=none
        [[ ! $is_new_snell_obfs_mode ]] && {
            is_tmp_list=(none http)
            ask list is_new_snell_obfs_mode
        }
        snell_obfs_mode=$is_new_snell_obfs_mode
        add snell
        ;;
    20)
        # mode
        if [[ $is_protocol != snell ]]; then
            # backward compatibility for non-snell outbound mode
            ask set_outbound_mode
            if [[ $is_outbound_mode == 'SS 出站' ]]; then
                ask string is_outbound_ss_uri "请输入 SS 节点链接:"
                parse_ss_uri_for_outbound "$is_outbound_ss_uri" || err "SS 节点链接格式无效, 目前仅支持 ss://BASE64(method:password)@host:port#name"
                meta_set "$is_config_file" outbound_ss_server "$is_outbound_ss_server"
                meta_set "$is_config_file" outbound_ss_port "$is_outbound_ss_port"
                meta_set "$is_config_file" outbound_ss_method "$is_outbound_ss_method"
                meta_set "$is_config_file" outbound_ss_password "$is_outbound_ss_password"
                meta_set "$is_config_file" outbound_ss_name "$is_outbound_ss_name"
            fi
            meta_set "$is_config_file" outbound_mode "$is_outbound_mode"
            [[ -f "$is_config_json" ]] || create config.json
            sync_runtime_node_outbound_modes
            manage restart &
            msg "\n已更新出站方式为: $(_green $(current_outbound_mode_display "$is_config_file"))\n"
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
            is_tmp_list=(none http)
            ask list is_new_snell_obfs_mode "${is_tmp_list[*]}" "\n当前为 Snell v5 节点，请选择混淆模式:\n"
            snell_obfs_mode=$is_new_snell_obfs_mode
            add snell
            return
        fi
        is_new_snell_mode=$3
        [[ $is_new_snell_mode == auto ]] && is_new_snell_mode=default
        [[ ! $is_new_snell_mode ]] && {
            is_tmp_list=(default unshaped unsafe-raw)
            ask list is_new_snell_mode "${is_tmp_list[*]}" "\n请选择 Snell v6 运行模式:\n$(snell_mode_desc)\n"
        }
        snell_mode_valid "$is_new_snell_mode" || err "Snell 运行模式只支持 default, unshaped 或 unsafe-raw. $is_err_tips"
        snell_mode=$is_new_snell_mode
        add snell
        ;;
    16)
        # view current share link
        url_qr url
        ;;
    esac
}

# delete config.
del() {
    # dont get ip
    is_dont_get_ip=1
    [[ $is_conf_dir_empty ]] && return # not found any json file.
    # get a config file
    [[ ! $is_config_file ]] && get info $1
    if [[ $is_config_file ]]; then
        if [[ $is_main_start && ! $is_no_del_msg ]]; then
            msg "\n是否删除配置文件?: $is_config_file"
            pause
        fi
        rm -rf $is_conf_dir/"$is_config_file"
        meta_rm "$is_config_file"
        [[ -f "$is_config_json" ]] && sync_runtime_node_outbound_modes
        [[ ! $is_new_json ]] && manage restart &
        [[ ! $is_no_del_msg ]] && _green "\n已删除: $is_config_file\n"

        [[ $is_caddy ]] && {
            is_del_host=$host
            [[ $is_change ]] && {
                [[ ! $old_host ]] && return # no host exist or not set new host;
                is_del_host=$old_host
            }
            [[ $is_del_host && $host != $old_host && -f $is_caddy_conf/$is_del_host.conf ]] && {
                rm -rf $is_caddy_conf/$is_del_host.conf $is_caddy_conf/$is_del_host.conf.add
                [[ ! $is_new_json ]] && manage restart caddy &
            }
        }
    fi
    if [[ ! $(ls $is_conf_dir | grep .json) && ! $is_change ]]; then
        warn "当前配置目录为空! 因为你刚刚删除了最后一个配置文件."
        is_conf_dir_empty=1
    fi
    unset is_dont_get_ip
    [[ $is_dont_auto_exit ]] && unset is_config_file
}

# uninstall
uninstall() {
    if [[ $is_caddy ]]; then
        is_tmp_list=("卸载 $is_core_name" "卸载 ${is_core_name} & Caddy")
        ask list is_do_uninstall
    else
        ask string y "是否卸载 ${is_core_name}? [y]:"
    fi
    manage stop &>/dev/null
    manage disable &>/dev/null
    rm -rf $is_core_dir $is_log_dir $is_sh_bin ${is_sh_bin/$is_core/sb}
    if [[ $is_systemd ]]; then
        rm -f /lib/systemd/system/$is_core.service
    elif [[ $is_openrc ]]; then
        rm -f /etc/init.d/$is_core
    fi
    sed -i "/$is_core/d" /root/.bashrc
    # uninstall caddy; 2 is ask result
    if [[ $REPLY == '2' ]]; then
        manage stop caddy &>/dev/null
        manage disable caddy &>/dev/null
        if [[ $is_systemd ]]; then
            rm -rf $is_caddy_dir $is_caddy_bin /lib/systemd/system/caddy.service
        elif [[ $is_openrc ]]; then
            rm -rf $is_caddy_dir $is_caddy_bin /etc/init.d/caddy
        fi
    fi
    [[ $is_install_sh ]] && return # reinstall
    _green "\n卸载完成!"
    msg "脚本哪里需要完善? 请反馈"
    msg "反馈问题) $(msg_ul https://github.com/${is_sh_repo}/issues)\n"
}

# manage run status
manage() {
    [[ $is_dont_auto_exit ]] && return
    case $1 in
    1 | start)
        is_do=start
        is_do_msg=启动
        is_test_run=1
        ;;
    2 | stop)
        is_do=stop
        is_do_msg=停止
        ;;
    3 | r | restart)
        is_do=restart
        is_do_msg=重启
        is_test_run=1
        ;;
    *)
        is_do=$1
        is_do_msg=$1
        ;;
    esac
    case $2 in
    caddy)
        is_do_name=$2
        is_run_bin=$is_caddy_bin
        is_do_name_msg=Caddy
        ;;
    *)
        is_do_name=$is_core
        is_run_bin=$is_core_bin
        is_do_name_msg=$is_core_name
        ;;
    esac
    if [[ $is_systemd ]]; then
        systemctl $is_do $is_do_name 2>/dev/null
    elif [[ $is_openrc ]]; then
        case $is_do in
        enable)
            rc-update add $is_do_name default 2>/dev/null
            ;;
        disable)
            rc-update del $is_do_name default 2>/dev/null
            ;;
        *)
            rc-service $is_do_name $is_do 2>/dev/null
            ;;
        esac
    fi
    [[ $is_test_run && ! $is_new_install ]] && {
        sleep 2
        if [[ ! $(pgrep -f $is_run_bin) ]]; then
            is_run_fail=${is_do_name_msg,,}
            [[ ! $is_no_manage_msg ]] && {
                msg
                warn "($is_do_msg) $is_do_name_msg 失败"
                _yellow "检测到运行失败, 自动执行测试运行."
                get test-run
                _yellow "测试结束, 请按 Enter 退出."
            }
        fi
    }
}

# add a config
add() {
    is_lower=${1,,}
    if [[ $is_lower ]]; then
        case $is_lower in
        ws | tcp | quic | http)
            is_new_protocol=VMess-${is_lower^^}
            ;;
        wss | h2 | hu | vws | vh2 | vhu | tws | th2 | thu)
            is_new_protocol=$(sed -E "s/^V/VLESS-/;s/^T/Trojan-/;/^(W|H)/{s/^/VMess-/};s/WSS/WS/;s/HU/HTTPUpgrade/" <<<${is_lower^^})-TLS
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
            for v in ${protocol_list[@]}; do
                [[ $(grep -E -i "^$is_lower$" <<<$v) ]] && is_new_protocol=$v && break
            done

            [[ ! $is_new_protocol ]] && err "无法识别 ($1), 请使用: $is_core add [protocol] [args... | auto]"
            ;;
        esac
    fi

    # no prefer protocol
    [[ ! $is_new_protocol ]] && ask set_protocol

    if [[ ${is_new_protocol,,} == 'anytls' ]]; then
        is_core_major=$(echo "$is_core_ver" | cut -d. -f1)
        is_core_minor=$(echo "$is_core_ver" | cut -d. -f2)
        if [[ ${is_core_major:-0} -lt 1 || ${is_core_major:-0} -eq 1 && ${is_core_minor:-0} -lt 12 ]]; then
            err "当前 sing-box 版本 ($is_core_ver) 不支持 AnyTLS，请先升级 sing-box core 到 1.12.0 或更高版本。"
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

    [[ $1 && ! $is_change ]] && {
        msg "\n使用协议: $is_new_protocol"
        # err msg tips
        is_err_tips="\n\n请使用: $(_green $is_core add $1 $is_add_opts) 来添加 $is_new_protocol 配置"
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
            [[ ! $(grep -i reality <<<$is_new_protocol) ]] && is_reality=
            ;;
        ss)
            [[ $(is_test uuid $ss_password) ]] && uuid=$ss_password
            ;;
        esac
        [[ ! $(is_test uuid $uuid) ]] && uuid=
        [[ $(is_test uuid $password) ]] && uuid=$password
    fi

    # no-auto-tls only use h2,ws,grpc
    if [[ $is_no_auto_tls && ! $is_use_tls ]]; then
        err "$is_new_protocol 不支持手动配置 tls."
    fi

    # prefer args.
    if [[ $2 ]]; then
        for v in is_use_port is_use_uuid is_use_host is_use_path is_use_pass is_use_method is_use_door_addr is_use_door_port is_use_version; do
            [[ ${!v} == 'auto' ]] && unset $v
        done

        if [[ $is_use_port ]]; then
            [[ ! $(is_test port ${is_use_port}) ]] && {
                err "($is_use_port) 不是一个有效的端口. $is_err_tips"
            }
            [[ $(is_test port_used $is_use_port) && ! $is_gen && ${is_new_protocol,,} != snell ]] && {
                err "无法使用 ($is_use_port) 端口. $is_err_tips"
            }
            port=$is_use_port
        fi
        if [[ $is_use_door_port ]]; then
            [[ ! $(is_test port ${is_use_door_port}) ]] && {
                err "(${is_use_door_port}) 不是一个有效的目标端口. $is_err_tips"
            }
            door_port=$is_use_door_port
        fi
        if [[ $is_use_uuid ]]; then
            [[ ! $(is_test uuid $is_use_uuid) ]] && {
                err "($is_use_uuid) 不是一个有效的 UUID. $is_err_tips"
            }
            uuid=$is_use_uuid
        fi
        if [[ $is_use_path ]]; then
            [[ ! $(is_test path $is_use_path) ]] && {
                err "($is_use_path) 不是有效的路径. $is_err_tips"
            }
            path=$is_use_path
        fi
        if [[ $is_use_method ]]; then
            is_tmp_use_name=加密方式
            is_tmp_list=${ss_method_list[@]}
            for v in ${is_tmp_list[@]}; do
                [[ $(grep -E -i "^${is_use_method}$" <<<$v) ]] && is_tmp_use_type=$v && break
            done
            [[ ! ${is_tmp_use_type} ]] && {
                warn "(${is_use_method}) 不是一个可用的${is_tmp_use_name}."
                msg "${is_tmp_use_name}可用如下: "
                for v in ${is_tmp_list[@]}; do
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
                msg "\e[41m no-auto-tls 帮助(help)\e[0m: $(msg_ul https://233boy.com/$is_core/no-auto-tls/)\n"
                msg "\n Caddy 将使用非标准端口实现自动配置 TLS, HTTP:$is_http_port HTTPS:$is_https_port\n"
                msg "请确定是否继续???"
                pause
            }
            is_install_caddy=1
        fi
        # set host
        [[ ! $host ]] && ask string host "请输入域名:"
        # test host dns
        get host-test
    else
        # for main menu start, dont auto create args
        if [[ $is_main_start ]]; then

            # set port
            [[ ! $port ]] && {
                get_port
                is_default_arg=$tmp_port
                ask string port "请输入端口(直接回车随机):"
            }

            case ${is_new_protocol,,} in
            socks)
                # set user
                [[ ! $is_socks_user ]] && ask string is_socks_user "请设置用户名:"
                # set password
                [[ ! $is_socks_pass ]] && {
                    [[ ! $tmp_uuid ]] && get_uuid
                    is_default_arg=$tmp_uuid
                    ask string is_socks_pass "请设置密码(直接回车随机):"
                }
                ;;
            shadowsocks)
                # set method
                [[ ! $ss_method ]] && ask set_ss_method
                # set password
                [[ ! $ss_password ]] && {
                    if [[ $(grep 2022 <<<$ss_method) ]]; then
                        is_default_arg=$(get ss2022)
                    else
                        [[ ! $tmp_uuid ]] && get_uuid
                        is_default_arg=$tmp_uuid
                    fi
                    ask string ss_password "请设置密码(直接回车随机):"
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
        validate_snell
    fi

    # Dokodemo-Door
    if [[ $is_new_protocol == 'Direct' ]]; then
        # set remote addr
        [[ ! $door_addr ]] && ask string door_addr "请输入目标地址:"
        # set remote port
        [[ ! $door_port ]] && ask string door_port "请输入目标端口:"
    fi

    # Shadowsocks 2022
    if [[ $(grep 2022 <<<$ss_method) ]]; then
        # test ss2022 password
        [[ $ss_password ]] && {
            is_test_json=1
            create server Shadowsocks
            [[ ! $tmp_uuid ]] && get_uuid
            is_test_json_save=$is_conf_dir/tmp-test-$tmp_uuid
            cat <<<"$is_new_json" >$is_test_json_save
            $is_core_bin check -c $is_test_json_save &>/dev/null
            if [[ $? != 0 ]]; then
                warn "Shadowsocks 协议 ($ss_method) 不支持使用密码 ($(_red_bg $ss_password))\n\n你可以使用命令: $(_green $is_core ss2022) 生成支持的密码.\n\n脚本将自动创建可用密码:)"
                ss_password=
                # create new json.
                json_str=
            fi
            is_test_json=
            rm -f $is_test_json_save
        }

    fi

    # install caddy
    if [[ $is_install_caddy ]]; then
        get install-caddy
    fi

    if [[ $is_main_start && ! $is_change && ! $is_gen ]]; then
        echo -ne "请输入节点名称(直接回车随机8位):"
        read is_custom_node_name
        is_custom_node_name=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$is_custom_node_name")
        is_custom_node_name=${is_custom_node_name%.json}
        [[ ! $is_custom_node_name ]] && is_custom_node_name=$(random_node_name)
    fi

    # create json
    create server $is_new_protocol
    [[ $is_custom_node_name && $is_config_name ]] && meta_set "$is_config_name" node_name "$is_custom_node_name"

    # show config info.
    info
}

# get config info
# or somes required args
get() {
    case $1 in
    addr)
        is_addr=$host
        [[ ! $is_addr && $is_config_file ]] && is_addr=$(meta_get "$is_config_file" '.entry_addr')
        [[ ! $is_addr && $is_listen_addr && $is_listen_addr != "::" && $is_listen_addr != "0.0.0.0" ]] && is_addr=$is_listen_addr
        [[ ! $is_addr ]] && {
            get_ip
            is_addr=$ip
            [[ $(grep ":" <<<$ip) ]] && is_addr="[$ip]"
        }
        # IPv6 地址加方括号 (URL 格式要求)
        [[ $is_addr == *:* && $is_addr != \[*\] ]] && is_addr="[$is_addr]"
        ;;
    new)
        [[ ! $host ]] && get_ip
        [[ ! $port ]] && get_port && port=$tmp_port
        [[ ! $uuid ]] && get_uuid && uuid=$tmp_uuid
        ;;
    file)
        is_file_str=$2
        [[ ! $is_file_str ]] && is_file_str='.json$'
        is_all_json=()
        shopt -s nullglob
        for is_json_file in "$is_conf_dir"/*.json; do
            is_json_name=${is_json_file##*/}
            [[ $is_json_name =~ dynamic-port-.*-link ]] && continue
            grep -E -i -q -- "$is_file_str" <<<"$is_json_name" || continue
            is_all_json+=("$is_json_name")
            [[ ${#is_all_json[@]} -ge 233 ]] && break
        done
        shopt -u nullglob
        [[ ! $is_all_json ]] && err "无法找到相关的配置文件: $2"
        [[ ${#is_all_json[@]} -eq 1 ]] && is_config_file=$is_all_json && is_auto_get_config=1
        [[ ! $is_config_file ]] && {
            [[ $is_dont_auto_exit ]] && return
            ask get_config_file
        }
        ;;
    info)
        is_tcp_http=
        get file $2
        if [[ $is_config_file ]]; then
            is_json_str=$(json_strip_comments "$is_conf_dir/$is_config_file")
            is_json_data=$(jq -r '(.inbounds[0]|.type,.listen_port,.listen,(.users[0]|.uuid,.password,.username),.method,.password,.override_port,.override_address,(.transport|.type,.path,.headers.host),(.tls|.server_name,.reality.private_key)),(.outbounds[1].tag,.inbounds[0].version,.inbounds[0].psk,.inbounds[0].obfs_mode,.inbounds[0].mode)' <<<$is_json_str)
            [[ $? != 0 ]] && err "无法读取此文件: $is_config_file"
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
            for v in ${is_up_var_set[@]}; do
                [[ ${!v} == 'null' ]] && unset $v
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
                is_anytls_domain=$(jq -r '(.inbounds[0].tls.certificate_provider.domain[0] // .inbounds[0].tls.acme.domain[0]) // empty' <<<$is_json_str 2>/dev/null)
            }

            is_config_name=$is_config_file

            if [[ $is_caddy && $host && -f $is_caddy_conf/$host.conf ]]; then
                is_tmp_https_port=$(grep -E -o "$host:[1-9][0-9]?+" $is_caddy_conf/$host.conf | sed s/.*://)
            fi
            if [[ $host && ! -f $is_caddy_conf/$host.conf ]]; then
                is_no_auto_tls=1
            fi
            [[ $is_tmp_https_port ]] && is_https_port=$is_tmp_https_port
            [[ $is_client && $host ]] && port=$is_https_port
            get protocol $is_protocol-$net_type
        fi
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
                [[ $(grep 2022 <<<$ss_method) ]] && ss_password=$(get ss2022)
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
            [[ ! $is_socks_user ]] && is_socks_user=233boy
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
            [[ ! $is_servername ]] && is_servername=$is_random_servername
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
            ;;
        esac
        json_str="$is_users,$is_json_add"
        ;;
    host-test) # test host dns record; for auto *tls required.
        [[ $is_no_auto_tls || $is_gen || $is_dont_test_host ]] && return
        get_ip
        get ping
        if [[ ! $(grep $ip <<<$is_host_dns) ]]; then
            msg "\n请将 ($(_red_bg $host)) 解析到 ($(_red_bg $ip))"
            msg "\n如果使用 Cloudflare, 在 DNS 那; 关闭 (Proxy status / 代理状态), 即是 (DNS only / 仅限 DNS)"
            ask string y "我已经确定解析 [y]:"
            get ping
            if [[ ! $(grep $ip <<<$is_host_dns) ]]; then
                _cyan "\n测试结果: $is_host_dns"
                err "域名 ($host) 没有解析到 ($ip)"
            fi
        fi
        ;;
    ssss | ss2022)
        if [[ $(grep 128 <<<$ss_method) ]]; then
            $is_core_bin generate rand 16 --base64
        else
            $is_core_bin generate rand 32 --base64
        fi
        ;;
    ping)
        # is_ip_type="-4"
        # [[ $(grep ":" <<<$ip) ]] && is_ip_type="-6"
        # is_host_dns=$(ping $host $is_ip_type -c 1 -W 2 | head -1)
        is_dns_type="a"
        [[ $(grep ":" <<<$ip) ]] && is_dns_type="aaaa"
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
        is_install_sh=$(cat $is_sh_dir/install.sh)
        uninstall
        bash <<<$is_install_sh
        ;;
    test-run)
        if [[ $is_systemd ]]; then
            systemctl list-units --full -all &>/dev/null
            [[ $? != 0 ]] && {
                _yellow "\n无法执行测试, 请检查 systemctl 状态.\n"
                return
            }
        fi
        is_no_manage_msg=1
        if [[ ! $(pgrep -f $is_core_bin) ]]; then
            _yellow "\n测试运行 $is_core_name ..\n"
            manage start &>/dev/null
            if [[ $is_run_fail == $is_core ]]; then
                _red "$is_core_name 运行失败信息:"
                $is_core_bin run -c $is_config_json -C $is_conf_dir
            else
                _green "\n测试通过, 已启动 $is_core_name ..\n"
            fi
        else
            _green "\n$is_core_name 正在运行, 跳过测试\n"
        fi
        if [[ $is_caddy ]]; then
            if [[ ! $(pgrep -f $is_caddy_bin) ]]; then
                _yellow "\n测试运行 Caddy ..\n"
                manage start caddy &>/dev/null
                if [[ $is_run_fail == 'caddy' ]]; then
                    _red "Caddy 运行失败信息:"
                    $is_caddy_bin run --config $is_caddyfile
                else
                    _green "\n测试通过, 已启动 Caddy ..\n"
                fi
            else
                _green "\nCaddy 正在运行, 跳过测试\n"
            fi
        fi
        ;;
    esac
}

# show info
info() {
    local info_target=${1:-${is_config_file:-$is_config_name}}
    is_surge_str=
    if [[ $info_target ]]; then
        get info "$info_target"
    elif [[ ! $is_protocol ]]; then
        get info $1
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
                is_vmess_url=$(jq -c '{v:2,ps:'\"$is_node_name\"',add:'\"$is_addr\"',port:'\"$is_https_port\"',id:'\"$uuid\"',aid:"0",net:'\"$net\"',host:'\"$host\"',path:'\"$path\"',tls:'\"tls\"'}' <<<{})
                is_url=vmess://$(echo -n $is_vmess_url | base64 -w 0)
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
            is_info_str=($is_protocol $is_addr $is_https_port $uuid $net $host $path 'tls')
        else
            is_type=none
            is_can_change=(0 1 5 13 14 15 16)
            is_info_show=(0 1 2 3 4)
            is_info_str=($is_protocol $is_addr $port $uuid $net)
            [[ $net == "http" ]] && {
                net=tcp
                is_type=http
                is_tcp_http=1
                is_info_show+=(5)
                is_info_str=(${is_info_str[@]/http/tcp http})
            }
            [[ $net == "quic" ]] && {
                is_insecure=1
                is_info_show+=(8 9 20)
                is_info_str+=(tls h3 true)
                is_quic_add=",tls:\"tls\",alpn:\"h3\"" # cant add allowInsecure
            }
            is_vmess_url=$(jq -c "{v:2,ps:\"$is_node_name\",add:\"$is_addr\",port:\"$port\",id:\"$uuid\",aid:\"0\",net:\"$net\",type:\"$is_type\"$is_quic_add}" <<<{})
            is_url=vmess://$(echo -n $is_vmess_url | base64 -w 0)
        fi
        ;;
    ss)
        is_can_change=(0 1 4 6 13 14 15 16)
        is_info_show=(0 1 2 10 11)
        is_url="ss://$(echo -n ${ss_method}:${ss_password} | base64 -w 0)@${is_addr}:${port}#$is_node_name"
        is_info_str=($is_protocol $is_addr $port $ss_password $ss_method)
        ;;
    trojan)
        is_insecure=1
        is_can_change=(0 1 4 13 14 15 16)
        is_info_show=(0 1 2 10 4 8 20)
        is_url="$is_protocol://$password@$is_addr:$port?type=tcp&security=tls&insecure=1&allowInsecure=1#$is_node_name"
        is_info_str=($is_protocol $is_addr $port $password tcp tls true)
        ;;
    hy*)
        is_can_change=(0 1 4 13 14 15 16)
        is_info_show=(0 1 2 10 8 9 20)
        # fix xray core for client use.
        is_sha256=$(openssl x509 -noout -fingerprint -sha256 -in $is_core_dir/bin/tls.cer | sed 's/.*=//;s/://g')
        is_url="$is_protocol://$password@$is_addr:$port?alpn=h3&insecure=1&allowInsecure=1&pinSHA256=$is_sha256#$is_node_name"
        is_info_str=($is_protocol $is_addr $port $password tls h3 "true (设置, 固定证书>证书指纹(SHA-256): $is_sha256)")
        ;;
    tuic)
        is_insecure=1
        is_can_change=(0 1 4 5 13 14 15 16)
        is_info_show=(0 1 2 3 10 8 9 20 21)
        is_url="$is_protocol://$uuid:$password@$is_addr:$port?alpn=h3&insecure=1&allowInsecure=1&congestion_control=bbr#$is_node_name"
        is_info_str=($is_protocol $is_addr $port $uuid $password tls h3 true bbr)
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
            is_info_show=(${is_info_show[@]/15/})
        }
        is_info_str=($is_protocol $is_addr $port $uuid $is_flow $is_net_type reality $is_servername chrome $is_public_key)
        is_url="$is_protocol://$uuid@$is_addr:$port?encryption=none&security=reality&flow=$is_flow&type=$is_net_type&sni=$is_servername&pbk=$is_public_key&fp=chrome#$is_node_name"
        ;;
    anytls)
        is_can_change=(0 1 4 13 14 15 16)
        if [[ $is_anytls_domain ]]; then
            is_info_show=(0 1 2 10 8)
            is_info_str=($is_protocol $is_anytls_domain $port $password tls)
            is_url="anytls://$password@$is_anytls_domain:$port#$is_node_name"
        else
            is_insecure=1
            is_info_show=(0 1 2 10 8 20)
            is_info_str=($is_protocol $is_addr $port $password tls true)
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
        is_info_str=($is_protocol $is_addr $port $door_addr $door_port)
        ;;
    socks)
        is_can_change=(0 1 12 4 13 14 15 16)
        is_info_show=(0 1 2 19 10)
        is_info_str=($is_protocol $is_addr $port $is_socks_user $is_socks_pass)
        is_url="socks://$(echo -n ${is_socks_user}:${is_socks_pass} | base64 -w 0)@${is_addr}:${port}#$is_node_name"
        ;;
    esac
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
    fi
    if [[ $is_surge_str ]]; then
        msg "------------- Surge 配置 -------------"
        msg "\e[${is_color}m${is_surge_str}\e[0m"
    fi
    if [[ $is_no_auto_tls ]]; then
        msg "------------- no-auto-tls INFO -------------"
        msg "端口(port): $port"
        msg "路径(path): $path"
        msg "\e[41m帮助(help)\e[0m: $(msg_ul https://233boy.com/$is_core/no-auto-tls/)"
    fi
    footer_msg
}

# footer msg
footer_msg() {
    [[ $is_core_stop && ! $is_new_json ]] && warn "$is_core_name 当前处于停止状态."
    [[ $is_caddy_stop && $host ]] && warn "Caddy 当前处于停止状态."
    return 0
}

# URL or qrcode
url_qr() {
    is_dont_show_info=1
    info $2
    if [[ $1 == 'qr' && $is_protocol == snell ]]; then
        err "Snell 不支持二维码生成，请使用 URL 链接或 Surge 配置"
    fi
    if [[ $is_url ]]; then
        if [[ $1 == 'url' ]]; then
            msg "\n------------- $is_config_name & URL 链接 -------------"
            msg "\n\e[${is_color}m${is_url}\e[0m\n"
            if [[ $is_surge_str ]]; then
                msg "------------- Surge 配置 -------------"
                msg "\n\e[${is_color}m${is_surge_str}\e[0m\n"
            fi
            footer_msg
        else
            link="https://233boy.github.io/tools/qr.html#${is_url}"
            msg "\n------------- $is_config_name & QR code 二维码 -------------"
            msg
            if [[ $(type -P qrencode) ]]; then
                qrencode -t ANSI "${is_url}"
            else
                msg "请安装 qrencode: $(_green "$cmd update -y; $cmd install qrencode -y")"
            fi
            msg
            msg "如果无法正常显示或识别, 请使用下面的链接来生成二维码:"
            msg "\n\e[4;${is_color}m${link}\e[0m\n"
            footer_msg
        fi
    else
        [[ $1 == 'url' ]] && {
            err "($is_config_name) 无法生成 URL 链接."
        } || {
            err "($is_config_name) 无法生成 QR code 二维码."
        }
    fi
}

# update core, sh, caddy
update() {
    case $1 in
    1 | core | $is_core)
        is_update_name=core
        is_show_name=$is_core_name
        is_run_ver=v${is_core_ver##* }
        is_update_repo=$is_core_repo
        ;;
    2 | sh)
        is_update_name=sh
        is_show_name="$is_core_name 脚本"
        is_run_ver=$is_sh_ver
        is_update_repo=$is_sh_repo
        ;;
    3 | caddy)
        [[ ! $is_caddy ]] && err "不支持更新 Caddy."
        is_update_name=caddy
        is_show_name="Caddy"
        is_run_ver=$is_caddy_ver
        is_update_repo=$is_caddy_repo
        ;;
    *)
        err "无法识别 ($1), 请使用: $is_core update [core | sh | caddy] [ver]"
        ;;
    esac
    if [[ $2 ]]; then
        if [[ $is_update_name == 'sh' ]]; then
            is_new_ver=$2
        else
            is_new_ver=v${2#v}
        fi
    fi
    [[ $is_run_ver == $is_new_ver ]] && {
        msg "\n自定义版本和当前 $is_show_name 版本一样, 无需更新.\n"
        exit
    }
    load download.sh
    if [[ $is_new_ver ]]; then
        msg "\n使用自定义版本更新 $is_show_name: $(_green $is_new_ver)\n"
    else
        get_latest_version $is_update_name
        [[ $is_run_ver == $latest_ver ]] && {
            msg "\n$is_show_name 当前已经是最新版本了.\n"
            exit
        }
        msg "\n发现 $is_show_name 新版本: $(_green $latest_ver)\n"
        is_new_ver=$latest_ver
    fi
    download $is_update_name $is_new_ver
    msg "更新成功, 当前 $is_show_name 版本: $(_green $is_new_ver)\n"
    msg "$(_green 请查看更新说明: https://github.com/$is_update_repo/releases/tag/$is_new_ver)\n"
    [[ $is_update_name != 'sh' ]] && manage restart $is_update_name &
}

# main menu; if no prefer args.
is_main_menu() {
    msg "\n------------- $is_core_name script $is_sh_ver by $author -------------"
    msg "$is_core_name $is_core_ver: $is_core_status"
    msg "群组(Chat): $(msg_ul https://t.me/tg233boy)"
    is_main_start=1
    ask mainmenu
    case $REPLY in
    1)
        add
        ;;
    2)
        change
        ;;
    3)
        info
        ;;
    4)
        del
        ;;
    5)
        ask list is_do_manage "启动 停止 重启"
        manage $REPLY &
        msg "\n管理状态执行: $(_green $is_do_manage)\n"
        ;;
    6)
        is_tmp_list=("更新$is_core_name" "更新脚本")
        [[ $is_caddy ]] && is_tmp_list+=("更新Caddy")
        ask list is_do_update null "\n请选择更新:\n"
        update $REPLY
        ;;
    7)
        uninstall
        ;;
    8)
        msg
        load help.sh
        show_help
        ;;
    9)
        ask list is_do_other "启用BBR 查看日志 测试运行 重装脚本 设置DNS"
        case $REPLY in
        1)
            load bbr.sh
            _try_enable_bbr
            ;;
        2)
            load log.sh
            log_set
            ;;
        3)
            get test-run
            ;;
        4)
            get reinstall
            ;;
        5)
            load dns.sh
            dns_set
            ;;
        esac
        ;;
    10)
        load help.sh
        about
        ;;
    11)
        relay_menu
        ;;
    esac
}

relay_warn_security() {
    warn "当前中转未设置身份验证，请务必使用系统防火墙 (如 ufw / iptables) 或云服务商安全组 / 网络 ACL 限制访问来源，以防止端口被未授权滥用."
}

relay_info_show() {
    local l_port=$1 r_addr=$2 r_port=$3
    msg "type = direct"
    msg "listen = ::"
    msg "listen_port = $l_port"
    msg "override_address = $r_addr"
    msg "override_port = $r_port"
    msg "network = tcp,udp"
}

relay_add() {
    local local_port=$1 remote_addr=$2 remote_port=$3
    if [[ ! $local_port ]]; then
        while :; do
            get_port
            local_port=$tmp_port
            config_port_used "$local_port" || break
        done
        local auto_port=$local_port
        is_default_arg=$auto_port
        ask string local_port "请输入本地监听端口 (直接回车自动生成):"
        [[ -z "$REPLY" ]] && msg "自动分配本地端口: $local_port"
    fi
    local_port=$(echo "$local_port" | tr -d ' ')
    [[ $(is_test port "$local_port") ]] || err "($local_port) 不是一个有效的端口."
    [[ $(is_test port_used "$local_port") ]] && err "本地端口 ($local_port) 已被占用."
    config_port_used "$local_port" && err "本地端口 ($local_port) 已被现有配置占用."

    if [[ ! $remote_addr ]]; then
        ask string remote_addr "请输入目标地址 (IPv4/IPv6/域名):"
    fi
    remote_addr=$(echo "$remote_addr" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [[ -n $remote_addr ]] || err "目标地址不能为空."

    if [[ ! $remote_port ]]; then
        ask string remote_port "请输入目标端口:"
    fi
    remote_port=$(echo "$remote_port" | tr -d ' ')
    [[ $(is_test port "$remote_port") ]] || err "($remote_port) 不是一个有效的目标端口."

    local relay_file="$is_conf_dir/relay-${local_port}.json"
    local tmp_file
    tmp_file=$(mktemp "$is_conf_dir/.relay-XXXXXX") || err "无法创建中转临时配置文件."

    jq -n \
        --arg tag "relay-${local_port}.json" \
        --arg addr "$remote_addr" \
        --argjson local_port "$local_port" \
        --argjson remote_port "$remote_port" \
        '{inbounds:[{tag:$tag,type:"direct",listen:"::",listen_port:$local_port,override_address:$addr,override_port:$remote_port}]}' > "$tmp_file" || {
        rm -f "$tmp_file"
        err "生成中转配置 JSON 失败."
    }

    if ! "$is_core_bin" check -c "$tmp_file" &>/dev/null; then
        rm -f "$tmp_file"
        err "中转配置校验失败."
    fi

    if ! mv -f "$tmp_file" "$relay_file"; then
        rm -f "$tmp_file"
        err "保存中转配置文件失败."
    fi

    if [[ -f $is_config_json ]]; then
        if ! "$is_core_bin" check -c "$is_config_json" -C "$is_conf_dir" &>/dev/null; then
            rm -f "$relay_file"
            err "完整运行时配置校验失败，已取消安装该中转配置."
        fi
    fi

    manage restart &
    msg "\n$(_green '中转配置添加成功!')"
    msg "------------------------------------------------"
    relay_info_show "$local_port" "$remote_addr" "$remote_port"
    msg "------------------------------------------------"
    relay_warn_security
}

relay_info() {
    local local_port=$1
    if [[ ! $local_port ]]; then
        relay_list
        ask string local_port "请输入要查看的中转本地端口:"
    fi
    local_port=${local_port#relay-}
    local_port=${local_port%.json}
    local relay_file="$is_conf_dir/relay-${local_port}.json"
    [[ -f $relay_file ]] || err "未找到中转配置 (relay-${local_port}.json)."
    local r_addr r_port
    r_addr=$(jq -r '.inbounds[0].override_address // empty' "$relay_file")
    r_port=$(jq -r '.inbounds[0].override_port // empty' "$relay_file")
    msg "\n------------- 中转配置信息 -------------"
    relay_info_show "$local_port" "$r_addr" "$r_port"
    msg "----------------------------------------"
    relay_warn_security
}

relay_list() {
    local files count=0 file l_port r_addr r_port
    shopt -s nullglob
    files=("$is_conf_dir"/relay-*.json)
    shopt -u nullglob
    if [[ ${#files[@]} -eq 0 ]]; then
        msg "\n当前未配置任何中转.\n"
        return
    fi
    msg "\n------------- 中转列表 -------------"
    for file in "${files[@]}"; do
        l_port=$(jq -r '.inbounds[0].listen_port // empty' "$file")
        r_addr=$(jq -r '.inbounds[0].override_address // empty' "$file")
        r_port=$(jq -r '.inbounds[0].override_port // empty' "$file")
        msg "本地端口: $l_port -> 目标: $r_addr:$r_port (network: tcp,udp)"
        ((count++))
    done
    msg "------------------------------------"
    msg "共 $count 个中转"
    relay_warn_security
}

relay_delete() {
    local local_port=$1 relay_file backup_file
    if [[ ! $local_port ]]; then
        relay_list
        ask string local_port "请输入要删除的中转本地端口:"
    fi
    local_port=${local_port#relay-}
    local_port=${local_port%.json}
    relay_file="$is_conf_dir/relay-${local_port}.json"
    [[ -f $relay_file ]] || err "未找到中转配置 (relay-${local_port}.json)."
    backup_file="$is_conf_dir/.relay-${local_port}.json.bak"
    mv -f "$relay_file" "$backup_file" || err "备份中转配置失败，未执行删除."
    if [[ -f $is_config_json ]]; then
        if ! "$is_core_bin" check -c "$is_config_json" -C "$is_conf_dir" &>/dev/null; then
            mv -f "$backup_file" "$relay_file"
            err "删除中转后完整运行时配置校验失败，已恢复中转配置."
        fi
    fi
    rm -f "$backup_file"
    [[ -f $is_config_json ]] && sync_runtime_node_outbound_modes
    manage restart &
    _green "\n已删除中转配置: relay-${local_port}.json\n"
}

relay_menu() {
    is_tmp_list=("添加中转" "中转列表" "删除中转" "返回主菜单")
    ask list is_relay_action null "\n请选择中转管理操作:\n"
    case $REPLY in
    1)
        relay_add
        ;;
    2)
        relay_list
        ;;
    3)
        relay_delete
        ;;
    4)
        is_main_menu
        ;;
    esac
}

relay_main() {
    case ${1:-} in
    add)
        relay_add "${@:2}"
        ;;
    list)
        relay_list
        ;;
    info)
        relay_info "${@:2}"
        ;;
    del | delete | rm)
        relay_delete "${@:2}"
        ;;
    "")
        relay_menu
        ;;
    *)
        err "无法识别中转命令 ($1), 正确用法: $is_core relay [add|list|info|delete]"
        ;;
    esac
}

# check prefer args, if not exist prefer args and show main menu
main() {
    [[ ! $1 ]] && {
        is_main_menu
        return
    }
    case $1 in
    a | add | gen | no-auto-tls)
        [[ $1 == 'gen' ]] && is_gen=1
        [[ $1 == 'no-auto-tls' ]] && is_no_auto_tls=1
        add ${@:2}
        ;;
    bin | pbk | check | completion | format | generate | geoip | geosite | merge | rule-set | run | tools)
        is_run_command=$1
        if [[ $1 == 'bin' ]]; then
            $is_core_bin ${@:2}
        else
            [[ $is_run_command == 'pbk' ]] && is_run_command="generate reality-keypair"
            $is_core_bin $is_run_command ${@:2}
        fi
        ;;
    bbr)
        load bbr.sh
        _try_enable_bbr
        ;;
    c | config | change)
        change ${@:2}
        ;;
    # client | genc)
    #     create client $2
    #     ;;
    d | del | rm)
        del $2
        ;;
    dd | ddel | fix | fix-all)
        case $1 in
        fix)
            [[ $2 ]] && {
                change $2 full
            } || {
                is_change_id=full && change
            }
            return
            ;;
        fix-all)
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
            [[ ! $2 ]] && {
                err "无法找到需要删除的参数"
            } || {
                for v in ${@:2}; do
                    del $v
                done
            }
            ;;
        esac
        is_dont_auto_exit=
        manage restart &
        [[ $is_del_host ]] && manage restart caddy &
        ;;
    dns)
        load dns.sh
        dns_set ${@:2}
        ;;
    debug)
        is_debug=1
        get info $2
        warn "如果需要复制; 请把 *uuid, *password, *host, *key 的值改写, 以避免泄露."
        ;;
    fix-config.json)
        create config.json
        ;;
    fix-caddyfile)
        if [[ $is_caddy ]]; then
            load caddy.sh
            caddy_config new
            manage restart caddy &
            _green "\nfix 完成.\n"
        else
            err "无法执行此操作"
        fi
        ;;
    i | info)
        info $2
        ;;
    ip)
        get_ip
        msg $ip
        ;;
    in | import)
        load import.sh
        ;;
    log)
        load log.sh
        log_set $2
        ;;
    url | qr)
        url_qr $@
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
        update $is_update_name $is_update_ver
        ;;
    ssss | ss2022)
        get $@
        ;;
    s | status)
        msg "\n$is_core_name $is_core_ver: $is_core_status\n"
        [[ $is_caddy ]] && msg "Caddy $is_caddy_ver: $is_caddy_status\n"
        ;;
    start | stop | r | restart)
        [[ $2 && $2 != 'caddy' ]] && err "无法识别 ($2), 请使用: $is_core $1 [caddy]"
        manage $1 $2 &
        ;;
    t | test)
        get test-run
        ;;
    reinstall)
        get $1
        ;;
    get-port)
        get_port
        msg $tmp_port
        ;;
    main)
        is_main_menu
        ;;
    v | ver | version)
        [[ $is_caddy_ver ]] && is_caddy_ver="/ $(_blue Caddy $is_caddy_ver)"
        msg "\n$(_green $is_core_name $is_core_ver) / $(_cyan $is_core_name script $is_sh_ver) $is_caddy_ver\n"
        ;;
    h | help | --help)
        load help.sh
        show_help ${@:2}
        ;;
    relay)
        relay_main "${@:2}"
        ;;
    *)
        is_try_change=1
        change test $1
        if [[ $is_change_id ]]; then
            unset is_try_change
            [[ $2 ]] && {
                change $2 $1 ${@:3}
            } || {
                change
            }
        else
            err "无法识别 ($1), 获取帮助请使用: $is_core help"
        fi
        ;;
    esac
}
