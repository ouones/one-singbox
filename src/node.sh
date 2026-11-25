# Node probing, validation, Reality/Snell helpers, and share/QR rendering.

reality_sni_pick() {
    local -a pool=("$@")
    local index max=$((${#pool[@]} - 1))
    ((max >= 0)) || return 1
    index=$(shuf -i "0-$max" -n1)
    [[ $index =~ ^[0-9]+$ ]] && ((index <= max)) || index=0
    printf '%s\n' "${pool[index]}"
}

reality_sni_select() {
    local response country_code city_region
    local -a pool
    response=$(env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        timeout 10 wget --no-check-certificate -q -O - -T 10 -t 1 'https://my.ippure.com/v1/info' 2>/dev/null) || response=
    country_code=$(jq -ers 'if length == 1 and (.[0] | type == "object") and (.[0].countryCode | type == "string" and length > 0) then .[0].countryCode else empty end' <<<"$response" 2>/dev/null) || country_code=
    city_region=$(jq -ers 'if length == 1 and (.[0] | type == "object") and .[0].countryCode == "US" then if .[0].city == "San Jose" then "san-jose" elif .[0].city == "Los Angeles" then "los-angeles" else empty end else empty end' <<<"$response" 2>/dev/null) || city_region=
    case $country_code/$city_region in
    US/san-jose)
        pool=(www.sccoe.org historysanjose.org www.rosicrucianpark.org)
        ;;
    US/los-angeles)
        pool=(lamag.org)
        ;;
    DE/*)
        pool=(www.uni-frankfurt.de www.staedelmuseum.de liebieghaus.de www.schirn.de dff.film)
        ;;
    SG/*)
        pool=(trinitycollege.edu.sg)
        ;;
    HK/*)
        pool=(www.hkapa.edu www.hsu.edu.hk www.hko.gov.hk www.archsd.gov.hk)
        ;;
    *)
        pool=(www.amd.com www.ibm.com www.ebay.com www.tesla.com www.amazon.com)
        ;;
    esac
    reality_sni_pick "${pool[@]}"
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
    echo -e "\n------------- Snell v6 运行模式说明 -------------\n1. default    \e[92m[推荐]\e[0m     : 使用默认的流量处理与填充策略。\n2. unshaped   \e[96m[减少填充]\e[0m : 不使用流量整形和额外填充。\n3. unsafe-raw \e[33m[裸传输]\e[0m   : 不提供流量保护，仅用于可信的内网或专用线路。\n--------------------------------------------------"
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
    local wanted=$1 current=${2:-} transport=${3:-both} file nullglob_was_set
    if shopt -q nullglob; then
        nullglob_was_set=1
    else
        nullglob_was_set=0
    fi
    shopt -s nullglob
    for file in "$is_conf_dir"/*.json; do
        [[ ${file##*/} == "$current" ]] && continue
        if jq -e --argjson port "$wanted" --arg transport "$transport" '
            def listens_tcp:
                (.network // "") != "udp" and
                (.transport.type // "") != "quic" and
                (.type != "hysteria" and .type != "hysteria2" and .type != "tuic");
            def listens_udp:
                if .network == "tcp" then false
                elif .network == "udp" then true
                elif (.transport.type // "") == "quic" or .type == "hysteria" or .type == "hysteria2" or .type == "tuic" then true
                elif .type == "vless" or .type == "vmess" or .type == "trojan" or .type == "anytls" or .type == "socks" or .type == "http" or .type == "mixed" or .type == "shadowtls" then false
                else true end;
            any(.inbounds[]?;
                .listen_port == $port and
                (if $transport == "tcp" then listens_tcp
                 elif $transport == "udp" then listens_udp
                 else true end))
        ' "$file" >/dev/null 2>&1; then
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
    local flag trace line candidate=
    for flag in -4 -6; do
        trace=$(_wget "$flag" -qO- https://one.one.one.one/cdn-cgi/trace 2>/dev/null) || continue
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%$'\r'}
            [[ $line == ip=* ]] || continue
            candidate=${line#ip=}
            if is_valid_ipv4_addr "$candidate" || is_valid_ipv6_addr "$candidate"; then
                export ip="$candidate"
                return 0
            fi
        done <<<"$trace"
    done
    err "无法获取服务器公网 IP。请检查网络连接后重试。"
    return 1
}

get_port() {
    local is_count=0
    while :; do
        ((is_count++))
        if [[ $is_count -ge 233 ]]; then
            err "已尝试 233 次，仍未找到可用端口。请检查端口占用情况。"
        fi
        tmp_port=$(shuf -i 20000-65535 -n 1)
        [[ ! $(node_port_used "$tmp_port" "$is_new_protocol") && $tmp_port != "$port" ]] && break
    done
}

get_pbk() {
    local pbk_output
    local -a is_tmp_pbk=()
    pbk_output=$("$is_core_bin" generate reality-keypair)
    mapfile -t is_tmp_pbk < <(sed 's/.*:[[:space:]]*//' <<<"$pbk_output")
    is_public_key=${is_tmp_pbk[1]}
    is_private_key=${is_tmp_pbk[0]}
}

is_test() {
    case $1 in
    number)
        if [[ $2 != *$'\n'* && $2 != *$'\r'* ]]; then
            echo "$2" | grep -E '^[1-9][0-9]?+$'
        fi
        ;;
    port)
        if [[ $(is_test number "$2") ]]; then
            [[ $2 -le 65535 ]] && echo ok
        fi
        ;;
    port_used)
        [[ $(node_port_used "$2" "$is_new_protocol") && ! $is_cant_test_port ]] && echo ok
        ;;
    domain)
        if [[ $2 != *$'\n'* && $2 != *$'\r'* ]]; then
            echo "$2" | grep -E -i '^\w(\w|\-|\.)?+\.\w+$'
        fi
        ;;
    path)
        if [[ $2 != *$'\n'* && $2 != *$'\r'* ]]; then
            echo "$2" | grep -E -i '^\/\w(\w|\-|\/)?+\w$'
        fi
        ;;
    uuid)
        if [[ $2 != *$'\n'* && $2 != *$'\r'* ]]; then
            echo "$2" | grep -E -i '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
        fi
        ;;
    esac

}

is_port_used() {
    if [[ $(type -P netstat) ]]; then
        [[ ! $is_used_port ]] && is_used_port="$(netstat -tunlp | sed -n 's/.*:\([0-9]\+\).*/\1/p' | sort -nu)"
        printf '%s\n' "$is_used_port" | tr ' ' '\n' | grep -x -- "$1"
        return
    fi
    if [[ $(type -P ss) ]]; then
        [[ ! $is_used_port ]] && is_used_port="$(ss -tunlp | sed -n 's/.*:\([0-9]\+\).*/\1/p' | sort -nu)"
        printf '%s\n' "$is_used_port" | tr ' ' '\n' | grep -x -- "$1"
        return
    fi
    is_cant_test_port=1
    msg "$is_warn 无法检测端口是否可用."
    msg "请执行: $(_yellow "${cmd} update -y; ${cmd} install net-tools -y") 来修复此问题."
}

node_protocol_transport() {
    case ${1,,} in
    *hysteria* | tuic | *quic*)
        printf 'udp\n'
        ;;
    vless* | vmess | trojan | anytls | socks | http | mixed | shadowtls)
        printf 'tcp\n'
        ;;
    *)
        printf 'both\n'
        ;;
    esac
}

is_tcp_port_used() {
    local wanted=$1 output line state recv send local_address peer process port
    if [[ $(type -P ss) ]]; then
        output=$(ss -Hlnpt 2>/dev/null) || {
            is_cant_test_port=1
            return 0
        }
        while read -r state recv send local_address peer process; do
            port=${local_address##*:}
            [[ $port == "$wanted" ]] && return 0
        done <<<"$output"
        return 1
    fi
    if [[ $(type -P netstat) ]]; then
        output=$(netstat -tnlp 2>/dev/null) || {
            is_cant_test_port=1
            return 0
        }
        while read -r line; do
            [[ $line == tcp* && $line == *LISTEN* ]] || continue
            local_address=$(awk '{print $4}' <<<"$line")
            port=${local_address##*:}
            [[ $port == "$wanted" ]] && return 0
        done <<<"$output"
        return 1
    fi
    is_cant_test_port=1
    return 0
}

is_udp_port_used() {
    local wanted=$1 output state recv send local_address peer process port line
    if [[ $(type -P ss) ]]; then
        output=$(ss -Hlnpu 2>/dev/null) || {
            is_cant_test_port=1
            return 0
        }
        while read -r state recv send local_address peer process; do
            port=${local_address##*:}
            [[ $port == "$wanted" ]] && return 0
        done <<<"$output"
        return 1
    fi
    if [[ $(type -P netstat) ]]; then
        output=$(netstat -unlp 2>/dev/null) || {
            is_cant_test_port=1
            return 0
        }
        while read -r line; do
            [[ $line == udp* ]] || continue
            local_address=$(awk '{print $4}' <<<"$line")
            port=${local_address##*:}
            [[ $port == "$wanted" ]] && return 0
        done <<<"$output"
        return 1
    fi
    is_cant_test_port=1
    return 0
}

node_port_used() {
    local port=$1 transport
    transport=$(node_protocol_transport "${2:-}")
    case $transport in
    tcp) is_tcp_port_used "$port" && printf '%s\n' "$port" ;;
    udp) is_udp_port_used "$port" && printf '%s\n' "$port" ;;
    *) is_port_used "$port" ;;
    esac
}

footer_msg() {
    [[ $is_core_stop && ! $is_new_json ]] && warn "$is_core_name 当前处于停止状态."
    [[ $is_caddy_stop && $host ]] && warn "Caddy 当前处于停止状态."
    return 0
}

render_qrcode() {
    local url=$1
    local terminal_size terminal_rows terminal_columns qr_output qr_width qr_height install_command
    msg "------------- $is_config_name & QR code 二维码 -------------"
    msg
    if [[ $(type -P qrencode) ]]; then
        if ! terminal_size=$(stty size 2>/dev/null) || [[ ! $terminal_size =~ ^[1-9][0-9]*[[:space:]]+[1-9][0-9]*$ ]]; then
            warn "($is_config_name) 无法读取终端尺寸，未显示二维码，请复制上方链接."
            msg
            return 1
        fi
        read -r terminal_rows terminal_columns <<<"$terminal_size"
        if ! qr_output=$(qrencode -t UTF8 "$url"); then
            warn "($is_config_name) QR code 二维码生成失败，请复制上方链接."
            msg
            return 1
        fi
        qr_width=$(printf '%s\n' "$qr_output" | sed -e 's/█/x/g' -e 's/▀/x/g' -e 's/▄/x/g' | wc -L)
        qr_height=$(printf '%s\n' "$qr_output" | wc -l)
        if ((qr_width >= terminal_columns || qr_height >= terminal_rows)); then
            warn "($is_config_name) 终端空间不足，未显示二维码，请复制上方链接."
            msg
            return 1
        fi
        printf '%s\n' "$qr_output"
        msg
        return 0
    else
        install_command=$(qrcode_dependency_install_command) || install_command=qrencode
        msg "请安装 qrencode: $(_green "$install_command")；当前仍可复制上方链接，也可通过主动更新脚本重试."
    fi
    msg
    return 1
}

show_qrcode_link() {
    local encoded_url
    encoded_url=$(jq -rn --arg uri "$1" '$uri | @uri')
    local link="https://one-singbox-node-qr.clj1105557035.workers.dev/#data=${encoded_url}"
    msg "如果无法正常显示或识别, 请使用下面的链接来生成二维码:"
    msg "\n\e[4;${is_color}m${link}\e[0m\n"
}

url_qr() {
    local is_dont_show_info=1
    info "$2"
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
            msg "\n\e[${is_color}m${is_url}\e[0m\n"
            render_qrcode "$is_url" || :
            show_qrcode_link "$is_url"
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
