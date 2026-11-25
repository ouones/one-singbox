# Address validation, Shadowsocks crypto/Base64, and VLESS/SS proxy URI parsing.

is_valid_ipv4_addr() {
    local addr=$1 o1 o2 o3 o4 o
    [[ $addr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r o1 o2 o3 o4 <<<"$addr"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [[ $o =~ ^(0|[1-9][0-9]{0,2})$ ]] && ((o <= 255)) || return 1
    done
    return 0
}

is_valid_ipv6_addr() {
    local addr=$1 compressed=0 ipv4_groups=0 group_count=0 left right side part ipv4
    local -a groups
    [[ $addr == *:* ]] || return 1
    if [[ $addr == *.* ]]; then
        ipv4=${addr##*:}
        [[ $ipv4 != "$addr" ]] && is_valid_ipv4_addr "$ipv4" || return 1
        addr=${addr%:*}
        ipv4_groups=2
    fi
    if [[ $addr == *::* ]]; then
        compressed=1
        left=${addr%%::*}
        right=${addr#*::}
        [[ $right != *::* && $left != *: && $right != :* ]] || return 1
    else
        left=$addr
        right=
    fi
    for side in "$left" "$right"; do
        [[ $side ]] || continue
        [[ $side != :* && $side != *: ]] || return 1
        IFS=: read -r -a groups <<<"$side"
        for part in "${groups[@]}"; do
            [[ $part =~ ^[[:xdigit:]]{1,4}$ ]] || return 1
            group_count=$((group_count + 1))
        done
    done
    group_count=$((group_count + ipv4_groups))
    if [[ $compressed == 1 ]]; then
        ((group_count < 8)) || return 1
    else
        ((group_count == 8))
    fi
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
    if [[ $(grep 128 <<<"$method") ]]; then
        "$is_core_bin" generate rand 16 --base64
    else
        "$is_core_bin" generate rand 32 --base64
    fi
}

# Normalize and validate standard or URL-safe Base64 input into padded standard Base64.
# Usage: _base64_normalize <input> [urlsafe=0|1] [out_padded_var] [out_unpadded_var]
_base64_normalize() {
    local _b64_input=$1 _b64_allow_urlsafe=${2:-0} _b64_out_padded=${3:-} _b64_out_unpadded=${4:-}
    local _b64_raw _b64_padding _b64_normalized _b64_mod _b64_canonical
    if [[ $_b64_allow_urlsafe == 1 ]]; then
        [[ $_b64_input =~ ^[A-Za-z0-9+/_-]+={0,2}$ ]] || return 1
        [[ $_b64_input != *[-_]* || ( $_b64_input != *+* && $_b64_input != */* ) ]] || return 1
    else
        [[ $_b64_input =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
    fi
    _b64_raw=${_b64_input%%=*}
    _b64_padding=${_b64_input#"$_b64_raw"}
    _b64_normalized=${_b64_raw//-/+}
    _b64_normalized=${_b64_normalized//_/\/}
    _b64_mod=$((${#_b64_normalized} % 4))
    if [[ $_b64_padding ]]; then
        [[ $((${#_b64_input} % 4)) == 0 ]] || return 1
        [[ ($_b64_padding == '==' && $_b64_mod == 2) || ($_b64_padding == '=' && $_b64_mod == 3) ]] || return 1
    else
        [[ $_b64_mod != 1 ]] || return 1
        [[ $_b64_mod == 2 ]] && _b64_padding='=='
        [[ $_b64_mod == 3 ]] && _b64_padding='='
    fi
    if [[ $_b64_allow_urlsafe != 1 ]]; then
        _b64_canonical=$(printf '%s' "$_b64_normalized$_b64_padding" | base64 -d 2>/dev/null | base64 -w 0) || return 1
        [[ $_b64_canonical == "$_b64_normalized$_b64_padding" ]] || return 1
    fi
    [[ $_b64_out_padded ]] && printf -v "$_b64_out_padded" '%s' "$_b64_normalized$_b64_padding"
    [[ $_b64_out_unpadded ]] && printf -v "$_b64_out_unpadded" '%s' "$_b64_normalized"
    return 0
}

ss_password_valid_for_method() {
    local method=$1 password=$2 expected_len decoded_len key padded
    local -a keys
    [[ $method != *2022* ]] && return 0
    [[ $password ]] || return 1
    [[ $(grep 128 <<<"$method") ]] && expected_len=16 || expected_len=32
    [[ $password != :* && $password != *: && $password != *::* ]] || return 1
    IFS=: read -r -a keys <<<"$password"
    for key in "${keys[@]}"; do
        _base64_normalize "$key" 1 padded || return 1
        decoded_len=$(printf '%s' "$padded" | base64 -d 2>/dev/null | wc -c)
        [[ ${decoded_len// /} -eq $expected_len ]] || return 1
    done
}

ss_base64_decode() {
    local input=$1 padded unpadded decoded canonical
    _base64_normalize "$input" 1 padded unpadded || return 1
    decoded=$(printf '%s' "$padded" | base64 -d 2>/dev/null) 2>/dev/null || return 1
    canonical=$(printf '%s' "$decoded" | base64 | tr -d '=\n') || return 1
    [[ $canonical == "$unpadded" ]] || return 1
    printf '%s' "$decoded"
}

ss_method_supported() {
    local method=$1 v
    for v in "${ss_method_list[@]}"; do
        [[ $v == "$method" ]] && return 0
    done
    return 1
}

url_percent_decode() {
    local input=$1 allow_newlines=${2:-0} output= prefix hex char code control_check
    if [[ $allow_newlines == 1 ]]; then
        control_check=${input//$'\r'/}
        control_check=${control_check//$'\n'/}
        [[ ! $control_check =~ [[:cntrl:]] ]] || return 1
    else
        [[ ! $input =~ [[:cntrl:]] ]] || return 1
    fi
    while [[ $input == *%* ]]; do
        prefix=${input%%\%*}
        output+=$prefix
        input=${input#*%}
        [[ $input =~ ^([[:xdigit:]]{2})(.*)$ ]] || return 1
        hex=${BASH_REMATCH[1]}
        input=${BASH_REMATCH[2]}
        code=$((16#$hex))
        if [[ $allow_newlines == 1 && ( $code == 10 || $code == 13 ) ]]; then
            :
        else
            ((code > 0 && code >= 32 && code != 127)) || return 1
        fi
        printf -v char '%b' "\\x$hex"
        output+=$char
    done
    output+=$input
    if [[ $allow_newlines == 1 ]]; then
        control_check=${output//$'\r'/}
        control_check=${control_check//$'\n'/}
        [[ ! $control_check =~ [[:cntrl:]] ]] || return 1
    else
        [[ ! $output =~ [[:cntrl:]] ]] || return 1
    fi
    printf '%s' "$output"
}

parse_uri_query() {
    local query=$1 allow_ech_pem=${2:-0} pair key raw_value value
    unset uri_query_map uri_query_keys
    declare -gA uri_query_map=()
    declare -ga uri_query_keys=()
    uri_query_json='{}'
    [[ $query ]] || return 0
    while :; do
        [[ $query == *'&'* ]] && {
            pair=${query%%&*}
            query=${query#*&}
        } || {
            pair=$query
            query=
        }
        [[ $pair == *=* ]] || return 1
        key=${pair%%=*}
        raw_value=${pair#*=}
        [[ $key && ! $key =~ [^A-Za-z0-9_-] ]] || return 1
        if [[ $allow_ech_pem == 1 && $key == ech ]]; then
            value=$(url_percent_decode "$raw_value" 1 && printf '\001') || return 1
            value=${value%$'\001'}
        else
            value=$(url_percent_decode "$raw_value") || return 1
        fi
        [[ ! ${uri_query_map[$key]+_} ]] || return 1
        uri_query_map[$key]=$value
        uri_query_keys+=("$key")
        [[ $query ]] || break
    done
}

parse_uri_authority() {
    local authority=$1 normalized_port
    uri_server=
    uri_port=
    if [[ $authority =~ ^\[([0-9A-Fa-f:.]+)\]:([0-9]+)$ ]]; then
        uri_server=${BASH_REMATCH[1]}
        uri_port=${BASH_REMATCH[2]}
        is_valid_ipv6_addr "$uri_server" || return 1
    else
        [[ $authority == *:* && $authority != *:*:* ]] || return 1
        uri_server=${authority%:*}
        uri_port=${authority##*:}
        [[ $uri_server ]] || return 1
        is_valid_ipv4_addr "$uri_server" || [[ $(is_test domain "$uri_server") ]] || return 1
    fi
    [[ $uri_port =~ ^[0-9]+$ ]] || return 1
    normalized_port=${uri_port#"${uri_port%%[!0]*}"}
    [[ $normalized_port ]] || return 1
    (( ${#normalized_port} <= 5 )) || return 1
    uri_port_number=$((10#$normalized_port))
    ((uri_port_number >= 1 && uri_port_number <= 65535))
}

uri_query_alias_value() {
    local normalize=$1 key value selected= selected_key= selected_set=0
    shift
    uri_alias_value=
    uri_alias_present=0
    for key in "$@"; do
        [[ ${uri_query_map[$key]+_} ]] || continue
        value=${uri_query_map[$key]}
        case $normalize in
        boolean)
            case $value in
            1 | true) value=true ;;
            0 | false) value=false ;;
            *)
                outbound_proxy_parse_error="VLESS 参数 $key 必须为 1、0、true 或 false"
                return 1
                ;;
            esac
            ;;
        packet_encoding)
            [[ $value == none ]] && value=
            ;;
        esac
        if ((selected_set)) && [[ $value != "$selected" ]]; then
            outbound_proxy_parse_error="VLESS 参数别名冲突: $selected_key / $key"
            return 1
        fi
        selected=$value
        selected_key=$key
        selected_set=1
    done
    uri_alias_value=$selected
    uri_alias_present=$selected_set
}

normalize_vless_ws_early_data() {
    local value=$1 normalized=$1
    [[ $value =~ ^[0-9]+$ ]] || {
        outbound_proxy_parse_error="VLESS WebSocket ed 必须为非负十进制整数"
        return 1
    }
    while [[ ${#normalized} -gt 1 && ${normalized:0:1} == 0 ]]; do
        normalized=${normalized:1}
    done
    [[ ${#normalized} -le 10 ]] && ((10#$normalized <= 4294967295)) || {
        outbound_proxy_parse_error="VLESS WebSocket ed 超出 sing-box uint32 范围"
        return 1
    }
    uri_vless_ws_early_data_normalized=$normalized
}

is_valid_vless_ws_header_name() {
    local header=$1 token_pattern='^[!#$%&'\''*+.^_`|~0-9A-Za-z-]+$'
    [[ $header =~ $token_pattern ]]
}

parse_vless_ws_early_data() {
    local path=$1 outer_ed_present=$2 outer_ed=$3 outer_eh_present=$4 outer_eh=$5
    local path_prefix=$1 query= remaining segment key raw_value has_equals more
    local keep_query= keep_query_present=0
    local inner_ed_present=0 inner_ed= inner_eh_present=0 inner_eh=
    local outer_ed_normalized= outer_eh_value= selected_ed_present=0 selected_ed= selected_eh_present=0 selected_eh=

    uri_vless_ws_path=$path
    uri_vless_ws_early_data_present=0
    uri_vless_ws_early_data=
    uri_vless_ws_early_data_header_present=0
    uri_vless_ws_early_data_header=

    if [[ $path == *\?* ]]; then
        path_prefix=${path%%\?*}
        query=${path#*\?}
        remaining=$query
        while :; do
            if [[ $remaining == *'&'* ]]; then
                segment=${remaining%%&*}
                remaining=${remaining#*&}
                more=1
            else
                segment=$remaining
                remaining=
                more=0
            fi
            if [[ $segment == *=* ]]; then
                key=${segment%%=*}
                raw_value=${segment#*=}
                has_equals=1
            else
                key=$segment
                raw_value=
                has_equals=0
            fi
            case $key in
            ed)
                [[ $has_equals == 1 && $inner_ed_present == 0 ]] || {
                    outbound_proxy_parse_error="VLESS WebSocket path query 中的 ed 格式无效或重复"
                    return 1
                }
                inner_ed=$(url_percent_decode "$raw_value") || {
                    outbound_proxy_parse_error="VLESS WebSocket path query 中的 ed 编码无效"
                    return 1
                }
                normalize_vless_ws_early_data "$inner_ed" || return 1
                inner_ed=$uri_vless_ws_early_data_normalized
                inner_ed_present=1
                ;;
            eh)
                [[ $has_equals == 1 && $inner_eh_present == 0 ]] || {
                    outbound_proxy_parse_error="VLESS WebSocket path query 中的 eh 格式无效或重复"
                    return 1
                }
                inner_eh=$(url_percent_decode "$raw_value") || {
                    outbound_proxy_parse_error="VLESS WebSocket path query 中的 eh 编码无效"
                    return 1
                }
                is_valid_vless_ws_header_name "$inner_eh" || {
                    outbound_proxy_parse_error="VLESS WebSocket early-data header 名无效"
                    return 1
                }
                inner_eh_present=1
                ;;
            *)
                if ((keep_query_present)); then keep_query+='&'; fi
                keep_query+=$segment
                keep_query_present=1
                ;;
            esac
            ((more)) || break
        done
    fi

    if [[ $outer_ed_present == 1 ]]; then
        normalize_vless_ws_early_data "$outer_ed" || return 1
        outer_ed_normalized=$uri_vless_ws_early_data_normalized
    fi
    if [[ $outer_eh_present == 1 ]]; then
        outer_eh_value=$outer_eh
        is_valid_vless_ws_header_name "$outer_eh_value" || {
            outbound_proxy_parse_error="VLESS WebSocket early-data header 名无效"
            return 1
        }
    fi
    if [[ $outer_ed_present == 1 && $inner_ed_present == 1 && $outer_ed_normalized != "$inner_ed" ]]; then
        outbound_proxy_parse_error="VLESS WebSocket 外层与 path query 的 ed 值冲突"
        return 1
    fi
    if [[ $outer_eh_present == 1 && $inner_eh_present == 1 && $outer_eh_value != "$inner_eh" ]]; then
        outbound_proxy_parse_error="VLESS WebSocket 外层与 path query 的 eh 值冲突"
        return 1
    fi

    if [[ $outer_ed_present == 1 ]]; then
        selected_ed_present=1
        selected_ed=$outer_ed_normalized
    elif [[ $inner_ed_present == 1 ]]; then
        selected_ed_present=1
        selected_ed=$inner_ed
    fi
    if [[ $outer_eh_present == 1 ]]; then
        selected_eh_present=1
        selected_eh=$outer_eh_value
    elif [[ $inner_eh_present == 1 ]]; then
        selected_eh_present=1
        selected_eh=$inner_eh
    fi
    if [[ $selected_eh_present == 1 && $selected_ed_present != 1 ]]; then
        outbound_proxy_parse_error="VLESS WebSocket eh 需要非零 ed"
        return 1
    fi
    if [[ $selected_ed_present == 1 ]]; then
        [[ $selected_ed != 0 || $selected_eh_present != 1 ]] || {
            outbound_proxy_parse_error="VLESS WebSocket ed=0 时不能设置 eh"
            return 1
        }
        uri_vless_ws_early_data_present=1
        uri_vless_ws_early_data=$selected_ed
        if [[ $selected_ed != 0 && $selected_eh_present != 1 ]]; then
            selected_eh_present=1
            selected_eh=Sec-WebSocket-Protocol
        fi
    fi
    if ((inner_ed_present || inner_eh_present)); then
        uri_vless_ws_path=$path_prefix
        if ((keep_query_present)); then uri_vless_ws_path+="?$keep_query"; fi
    fi
    uri_vless_ws_early_data_header_present=$selected_eh_present
    uri_vless_ws_early_data_header=$selected_eh
    return 0
}

vless_grpc_default_authority() {
    local server=$1 server_port=$2 security=$3 server_name=$4 version_output version tags tag_count authority_host tag
    vless_grpc_default_authority_value=
    [[ $is_core_bin ]] || return 1
    version_output=$("$is_core_bin" version 2>/dev/null) || return 1
    version=$(awk 'NR == 1 { print $3 }' <<<"$version_output")
    [[ ${version#v} == 1.14.0 ]] || return 1
    tag_count=$(grep -c '^Tags:' <<<"$version_output" || true)
    [[ $tag_count == 1 ]] || return 1
    tags=$(sed -n 's/^Tags:[[:space:]]*//p' <<<"$version_output")
    tags=${tags//[[:space:]]/}

    if [[ ,$tags, == *,with_grpc,* ]]; then
        tag=full
    else
        tag=lite
    fi
    if [[ ($security == tls || $security == reality) && $server_name ]]; then
        authority_host=$server_name
    else
        authority_host=$server
    fi
    if [[ $authority_host == *:* && $authority_host != \[*\] ]]; then
        authority_host="[$authority_host]"
    fi
    if [[ $tag == full && ($security == tls || $security == reality) && $server_name ]]; then
        vless_grpc_default_authority_value=$authority_host
    else
        vless_grpc_default_authority_value="$authority_host:$server_port"
    fi
}

normalize_vless_ech_config() {
    local input=$1 normalized begin end body raw padding mod canonical encoded decoded_len
    vless_ech_config=
    [[ $input ]] || return 0
    begin='-----BEGIN ECH CONFIGS-----'
    end='-----END ECH CONFIGS-----'
    if [[ $input == "$begin"* ]]; then
        normalized=${input//$'\r\n'/$'\n'}
        [[ $normalized != *$'\r'* ]] || return 1
        [[ $normalized == "$begin"$'\n'* ]] || return 1
        if [[ $normalized == *$'\n' ]]; then normalized=${normalized%$'\n'}; fi
        [[ $normalized == "$begin"$'\n'*$'\n'"$end" ]] || return 1
        body=${normalized#"$begin"$'\n'}
        body=${body%$'\n'"$end"}
        body=${body//$'\n'/}
    else
        [[ $input != *$'\r'* && $input != *$'\n'* ]] || return 1
        body=$input
    fi
    _base64_normalize "$body" 0 canonical || return 1
    decoded_len=$(printf '%s' "$canonical" | base64 -d 2>/dev/null | wc -c | tr -d '[:space:]') || return 1
    [[ $decoded_len != 0 ]] || return 1
    encoded=$(printf '%s' "$canonical" | base64 -d 2>/dev/null | base64) || return 1
    vless_ech_config="$begin"$'\n'"$encoded"$'\n'"$end"
}

normalize_vless_certificate_sha256() {
    local input=$1 pin decoded_len canonical normalized hex_escaped i
    local -a pins=() normalized_pins=()
    vless_certificate_sha256_csv=
    [[ $input ]] || return 0
    [[ $input != ,* && $input != *, && $input != *,,* ]] || return 1
    IFS=, read -r -a pins <<<"$input"
    for pin in "${pins[@]}"; do
        if [[ $pin =~ ^[[:xdigit:]]{64}$ ]]; then
            hex_escaped=
            for ((i = 0; i < ${#pin}; i += 2)); do
                hex_escaped+="\\x${pin:i:2}"
            done
            normalized=$(printf '%b' "$hex_escaped" | base64 -w 0) || return 1
        else
            _base64_normalize "$pin" 0 canonical || return 1
            decoded_len=$(printf '%s' "$canonical" | base64 -d 2>/dev/null | wc -c | tr -d '[:space:]') || return 1
            [[ $decoded_len == 32 ]] || return 1
            normalized=$canonical
        fi
        normalized_pins+=("$normalized")
    done
    local IFS=,
    vless_certificate_sha256_csv="${normalized_pins[*]}"
}

vless_core_supports_certificate_sha256() {
    local version=${is_core_ver:-} major minor
    [[ $version =~ ([0-9]+)\.([0-9]+)\.[0-9]+ ]] || return 0
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
    ((major > 1 || (major == 1 && minor >= 15)))
}

parse_vless_uri_common() {
    local auth authority raw_port key
    uri=${uri#"${uri%%[![:space:]]*}"}
    uri=${uri%"${uri##*[![:space:]]}"}
    [[ $uri == vless://* ]] || return 1
    uri=${uri#vless://}
    if [[ $uri == *#* ]]; then
        fragment_present=1
        raw_name=${uri#*#}
        uri=${uri%%#*}
        [[ $raw_name != *#* ]] || {
            outbound_proxy_parse_error="VLESS 链接名称格式无效"
            return 1
        }
    fi
    if [[ $uri == *\?* ]]; then
        raw_query=${uri#*\?}
        uri=${uri%%\?*}
        parse_uri_query "$raw_query" 1 || {
            outbound_proxy_parse_error="VLESS 查询参数格式无效"
            return 1
        }
    else
        parse_uri_query "" 1
    fi
    [[ $uri == *@* ]] || {
        outbound_proxy_parse_error="VLESS 链接缺少 UUID 或服务器地址"
        return 1
    }
    auth=${uri%@*}
    authority=${uri#*@}
    [[ $auth && $auth != *@* && $authority != *@* && $auth != *:* ]] || {
        outbound_proxy_parse_error="VLESS userinfo 必须是 UUID，不能包含密码"
        return 1
    }
    decoded_auth=$(url_percent_decode "$auth") || {
        outbound_proxy_parse_error="VLESS UUID 编码无效"
        return 1
    }
    [[ $decoded_auth =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
        outbound_proxy_parse_error="VLESS UUID 无效"
        return 1
    }
    [[ $authority == */ ]] && authority=${authority%/}
    [[ $authority != */* ]] || {
        outbound_proxy_parse_error="VLESS authority 不支持路径"
        return 1
    }
    raw_port=${authority##*:}
    [[ $raw_port =~ ^[0-9]{1,5}$ ]] || {
        outbound_proxy_parse_error="VLESS 端口必须为 1–65535 的十进制整数"
        return 1
    }
    parse_uri_authority "$authority" || {
        outbound_proxy_parse_error="VLESS 服务器地址或端口无效"
        return 1
    }

    for key in "${uri_query_keys[@]}"; do
        case $key in
        remark | remarks | encryption | type | security | flow | sni | serverName | alpn | fp | fingerprint | pbk | publicKey | sid | shortId | allowInsecure | insecure | skip-cert-verify | packetEncoding | packet_encoding | path | host | ed | eh | serviceName | service_name | mode | authority | headerType | quicSecurity | key | ech | pcs | vcn | spx | spiderX) ;;
        *)
            outbound_proxy_parse_error="VLESS 暂不支持连接参数: $key"
            return 1
            ;;
        esac
    done

    encryption=${uri_query_map[encryption]-none}
    [[ ! $encryption || $encryption == none ]] || {
        outbound_proxy_parse_error="VLESS encryption 仅支持 none"
        return 1
    }
    transport_original=${uri_query_map[type]-tcp}
    transport=$transport_original
    case $transport in
    tcp | raw | ws | grpc | h2 | http | httpupgrade | quic) ;;
    *)
        outbound_proxy_parse_error="VLESS type=$transport_original 传输暂不支持"
        return 1
        ;;
    esac
    security=${uri_query_map[security]-none}
    [[ ! $security ]] && security=none
    [[ $security == none || $security == tls || $security == reality ]] || {
        outbound_proxy_parse_error="VLESS security=$security 暂不支持"
        return 1
    }
    if [[ $transport_original == h2 && $security == none ]]; then
        outbound_proxy_parse_error="VLESS type=h2 需要 TLS 或 Reality，避免按明文 HTTP/2 处理"
        return 1
    fi
    if [[ $transport == quic && $security != tls ]]; then
        outbound_proxy_parse_error="VLESS QUIC 仅支持 sing-box 原生 TLS；无 TLS 或跨内核 Reality QUIC 不受支持"
        return 1
    fi
    flow=${uri_query_map[flow]-}
    [[ ! $flow || $flow == xtls-rprx-vision ]] || {
        outbound_proxy_parse_error="VLESS flow=$flow 暂不支持"
        return 1
    }
    if [[ $flow && ($transport == ws || $transport == grpc) ]]; then
        outbound_proxy_parse_error="VLESS Vision 仅支持 TCP/raw，不能用于 WebSocket 或 gRPC"
        return 1
    fi
}

parse_vless_transport_params() {
    local path path_present=0 host host_present=0 ed ed_present=0 eh eh_present=0
    local mode mode_present=0 header_type header_type_present=0
    local quic_security quic_security_present=0 quic_key quic_key_present=0
    local transport_parameter

    path=${uri_query_map[path]-}
    [[ ${uri_query_map[path]+_} ]] && path_present=1
    host=${uri_query_map[host]-}
    [[ ${uri_query_map[host]+_} ]] && host_present=1
    ed=${uri_query_map[ed]-}
    [[ ${uri_query_map[ed]+_} ]] && ed_present=1
    eh=${uri_query_map[eh]-}
    [[ ${uri_query_map[eh]+_} ]] && eh_present=1
    uri_query_alias_value raw serviceName service_name || return 1
    grpc_service_name=$uri_alias_value
    grpc_service_name_present=$uri_alias_present
    mode=${uri_query_map[mode]-}
    [[ ${uri_query_map[mode]+_} ]] && mode_present=1
    grpc_authority=${uri_query_map[authority]-}
    [[ ${uri_query_map[authority]+_} ]] && authority_present=1
    header_type=${uri_query_map[headerType]-none}
    [[ ${uri_query_map[headerType]+_} ]] && header_type_present=1
    quic_security=${uri_query_map[quicSecurity]-}
    [[ ${uri_query_map[quicSecurity]+_} ]] && quic_security_present=1
    quic_key=${uri_query_map[key]-}
    [[ ${uri_query_map[key]+_} ]] && quic_key_present=1

    if [[ $header_type_present == 1 && $header_type != none ]]; then
        if [[ $header_type == http ]]; then
            outbound_proxy_parse_error="VLESS headerType=http 的 TCP HTTP 伪装与 sing-box 原生传输不等价"
        else
            outbound_proxy_parse_error="VLESS headerType=$header_type 暂不支持"
        fi
        return 1
    fi

    case $transport in
    ws)
        if [[ $grpc_service_name_present == 1 || $mode_present == 1 || $authority_present == 1 ]]; then
            outbound_proxy_parse_error="VLESS WebSocket 不能使用 gRPC 参数 serviceName、mode 或 authority"
            return 1
        fi
        [[ $path_present != 1 || $path ]] || {
            outbound_proxy_parse_error="VLESS WebSocket path 不能为空"
            return 1
        }
        if [[ $host_present == 1 ]]; then
            [[ $host && $host != *,* && ! $host =~ [[:space:]] ]] || {
                outbound_proxy_parse_error="VLESS WebSocket host 必须是单个非空值且不能包含空白字符"
                return 1
            }
            ws_host=$host
            ws_host_present=1
        fi
        [[ $path_present == 1 ]] && ws_path=$path
        parse_vless_ws_early_data "$ws_path" "$ed_present" "$ed" "$eh_present" "$eh" || return 1
        ws_path=$uri_vless_ws_path
        ws_early_data=$uri_vless_ws_early_data
        ws_early_data_present=$uri_vless_ws_early_data_present
        ws_early_data_header=$uri_vless_ws_early_data_header
        ws_early_data_header_present=$uri_vless_ws_early_data_header_present
        ;;
    grpc)
        if [[ $path_present == 1 || $host_present == 1 || $ed_present == 1 || $eh_present == 1 ]]; then
            outbound_proxy_parse_error="VLESS gRPC 不能使用 WebSocket 参数 path、host、ed 或 eh"
            return 1
        fi
        if [[ $mode_present == 1 && $mode != gun ]]; then
            case $mode in
            multi | guna) outbound_proxy_parse_error="VLESS gRPC mode=$mode 与 sing-box 原生 gRPC 不等价" ;;
            *) outbound_proxy_parse_error="VLESS gRPC mode=$mode 仅支持 gun" ;;
            esac
            return 1
        fi
        ;;
    tcp | raw)
        if [[ $path_present == 1 || $host_present == 1 || $ed_present == 1 || $eh_present == 1 || $grpc_service_name_present == 1 || $mode_present == 1 || $authority_present == 1 ]]; then
            if [[ $path_present == 1 ]]; then transport_parameter=path
            elif [[ $host_present == 1 ]]; then transport_parameter=host
            elif [[ $ed_present == 1 ]]; then transport_parameter=ed
            elif [[ $eh_present == 1 ]]; then transport_parameter=eh
            elif [[ $grpc_service_name_present == 1 ]]; then transport_parameter=serviceName
            elif [[ $mode_present == 1 ]]; then transport_parameter=mode
            else transport_parameter=authority
            fi
            outbound_proxy_parse_error="VLESS type=$transport 不支持参数: $transport_parameter"
            return 1
        fi
        ;;
    h2 | http | httpupgrade | quic)
        if [[ $ed_present == 1 || $eh_present == 1 ]]; then
            outbound_proxy_parse_error="VLESS $transport 不能使用 WebSocket 专属参数 ed 或 eh"
            return 1
        fi
        if [[ $grpc_service_name_present == 1 || $mode_present == 1 || $authority_present == 1 ]]; then
            outbound_proxy_parse_error="VLESS $transport 不能使用 gRPC 专属参数 serviceName、mode 或 authority"
            return 1
        fi
        ;;
    esac

    transport_type=$transport
    case $transport in
    tcp | raw) transport=tcp ;;
    h2) transport=http ;;
    esac

    if [[ $transport != quic && ($quic_security_present == 1 || $quic_key_present == 1) ]]; then
        outbound_proxy_parse_error="VLESS quicSecurity 和 key 仅用于 QUIC 传输"
        return 1
    fi

    case $transport in
    tcp)
        if [[ $path_present == 1 || $host_present == 1 ]]; then
            outbound_proxy_parse_error="VLESS TCP/raw 不支持 path 或 host 传输参数"
            return 1
        fi
        if [[ $header_type_present == 1 ]]; then
            case $header_type in
            none) ;;
            http)
                outbound_proxy_parse_error="VLESS TCP headerType=http 伪装与原生 HTTP 传输不等价"
                return 1
                ;;
            *)
                outbound_proxy_parse_error="VLESS TCP headerType 仅支持 none"
                return 1
                ;;
            esac
        fi
        ;;
    http)
        if [[ $header_type_present == 1 ]]; then
            outbound_proxy_parse_error="VLESS headerType 仅适用于 TCP/raw"
            return 1
        fi
        if [[ $path_present == 1 ]]; then
            [[ $path ]] || {
                outbound_proxy_parse_error="VLESS HTTP path 不能为空"
                return 1
            }
            http_path=$path
        else
            http_path=/
        fi
        if [[ $host_present == 1 ]]; then
            [[ $host ]] || {
                outbound_proxy_parse_error="VLESS HTTP host 不能为空"
                return 1
            }
            [[ $host != ,* && $host != *, && $host != *,,* ]] || {
                outbound_proxy_parse_error="VLESS HTTP host 必须是逗号分隔的非空列表"
                return 1
            }
            http_host=$host
            http_host_present=1
        fi
        ;;
    httpupgrade)
        if [[ $header_type_present == 1 ]]; then
            outbound_proxy_parse_error="VLESS headerType 仅适用于 TCP/raw"
            return 1
        fi
        if [[ $path_present == 1 ]]; then
            [[ $path ]] || {
                outbound_proxy_parse_error="VLESS HTTPUpgrade path 不能为空"
                return 1
            }
            http_path=$path
        else
            http_path=/
        fi
        if [[ $host_present == 1 ]]; then
            [[ $host ]] || {
                outbound_proxy_parse_error="VLESS HTTPUpgrade host 不能为空"
                return 1
            }
            [[ $host != *,* ]] || {
                outbound_proxy_parse_error="VLESS HTTPUpgrade host 只支持单值，不能接收逗号分隔列表"
                return 1
            }
            http_host=$host
            http_host_present=1
        fi
        ;;
    quic)
        if [[ $path_present == 1 || $host_present == 1 || $header_type_present == 1 ]]; then
            outbound_proxy_parse_error="VLESS QUIC 不支持 path、host 或 headerType 传输参数"
            return 1
        fi
        if [[ $quic_security_present == 1 && $quic_security != none ]]; then
            outbound_proxy_parse_error="VLESS QUIC 仅支持 quicSecurity=none；额外加密不兼容 sing-box"
            return 1
        fi
        if [[ $quic_key_present == 1 && $quic_key ]]; then
            outbound_proxy_parse_error="VLESS QUIC 不支持额外加密 key；跨内核 QUIC 变体不兼容"
            return 1
        fi
        ;;
    esac
}

parse_vless_tls_params() {
    local canonical_public_key public_key_length grpc_default_authority

    uri_query_alias_value raw sni serverName || return 1
    sni=$uri_alias_value
    sni_present=$uri_alias_present
    uri_query_alias_value raw alpn || return 1
    alpn=$uri_alias_value
    alpn_present=$uri_alias_present
    uri_query_alias_value raw fp fingerprint || return 1
    fingerprint=$uri_alias_value
    fingerprint_present=$uri_alias_present
    uri_query_alias_value raw pbk publicKey || return 1
    public_key=$uri_alias_value
    public_key_present=$uri_alias_present
    uri_query_alias_value raw sid shortId || return 1
    short_id=$uri_alias_value
    short_id_present=$uri_alias_present
    uri_query_alias_value boolean allowInsecure insecure skip-cert-verify || return 1
    insecure=$uri_alias_value
    insecure_present=$uri_alias_present
    [[ $insecure_present == 1 ]] || insecure=false
    uri_query_alias_value packet_encoding packetEncoding packet_encoding || return 1
    packet_encoding=$uri_alias_value
    packet_encoding_present=$uri_alias_present
    [[ ${uri_query_map[ech]+_} ]] && ech_enabled=1
    ech=${uri_query_map[ech]-}
    pcs=${uri_query_map[pcs]-}
    vcn=${uri_query_map[vcn]-}
    uri_query_alias_value raw spx spiderX || return 1
    spx=$uri_alias_value
    uri_query_alias_value raw remark remarks || return 1
    remark_name=$uri_alias_value

    if [[ $security == none ]]; then
        if [[ ($sni_present == 1 && $sni) || ($alpn_present == 1 && $alpn) || ($fingerprint_present == 1 && $fingerprint) || ($insecure_present == 1 && $insecure) || ($public_key_present == 1 && $public_key) || ($short_id_present == 1 && $short_id) ]]; then
            outbound_proxy_parse_error="VLESS security=none 不能包含 TLS/Reality 参数"
            return 1
        fi
        [[ ! $flow ]] || {
            outbound_proxy_parse_error="VLESS Vision flow 需要 TLS 或 Reality"
            return 1
        }
    else
        [[ $sni ]] || sni=$uri_server
        if [[ $alpn_present == 1 ]]; then
            [[ $alpn ]] || {
                outbound_proxy_parse_error="VLESS alpn 不能为空"
                return 1
            }
            [[ $alpn != ,* && $alpn != *, && $alpn != *,,* ]] || {
                outbound_proxy_parse_error="VLESS alpn 必须是逗号分隔的非空协议列表"
                return 1
            }
        fi
        if [[ $fingerprint_present == 1 && $fingerprint != none ]]; then
            case $fingerprint in
            chrome | firefox | edge | safari | 360 | qq | ios | android | random | randomized) ;;
            *)
                outbound_proxy_parse_error="VLESS fingerprint=$fingerprint 不受支持"
                return 1
                ;;
            esac
            utls_enabled=true
        elif [[ $security == reality ]]; then
            [[ $fingerprint != none ]] || {
                outbound_proxy_parse_error="VLESS Reality 需要 uTLS fingerprint"
                return 1
            }
            fingerprint=chrome
            utls_enabled=true
        fi
        [[ $fingerprint_present != 1 || $fingerprint ]] || {
            outbound_proxy_parse_error="VLESS fingerprint 不能为空"
            return 1
        }
        if [[ $security == reality ]]; then
            [[ $public_key_present == 1 && $public_key ]] || {
                outbound_proxy_parse_error="VLESS Reality 需要 pbk/publicKey"
                return 1
            }
            public_key=${public_key%=}
            [[ $public_key =~ ^[A-Za-z0-9_-]{43}$ ]] || {
                outbound_proxy_parse_error="VLESS Reality public key 必须是 32 字节 Base64URL"
                return 1
            }
            canonical_public_key=$(printf '%s=' "$public_key" | tr '_-' '/+' | base64 -d 2>/dev/null | base64 -w 0 | tr '+/' '-_' | sed 's/=*$//')
            public_key_length=$(printf '%s' "$public_key" | tr '_-' '/+' | sed 's/$/=/' | base64 -d 2>/dev/null | wc -c | tr -d '[:space:]')
            [[ $canonical_public_key == "$public_key" && $public_key_length == 32 ]] || {
                outbound_proxy_parse_error="VLESS Reality public key 必须解码为 32 字节 Base64URL"
                return 1
            }
            if [[ $short_id_present == 1 && $short_id && ! $short_id =~ ^([0-9A-Fa-f]{2}){1,8}$ ]]; then
                outbound_proxy_parse_error="VLESS Reality short ID 必须是偶数位十六进制且不超过 16 位"
                return 1
            fi
            [[ $short_id_present == 1 ]] || short_id=
        elif [[ $public_key_present == 1 || $short_id_present == 1 ]]; then
            outbound_proxy_parse_error="VLESS pbk/publicKey 和 sid/shortId 仅用于 Reality"
            return 1
        fi
        if [[ $flow && $security != tls && $security != reality ]]; then
            outbound_proxy_parse_error="VLESS Vision flow 需要 TLS 或 Reality"
            return 1
        fi
        if [[ $flow && $transport != tcp ]]; then
            outbound_proxy_parse_error="VLESS Vision flow 仅支持 TCP/raw 传输"
            return 1
        fi
    fi

    if [[ $transport == grpc && $authority_present == 1 && $grpc_authority ]]; then
        vless_grpc_default_authority "$uri_server" "$uri_port_number" "$security" "$sni" || {
            outbound_proxy_parse_error="VLESS gRPC authority 默认值无法根据当前 sing-box 版本和构建确认"
            return 1
        }
        grpc_default_authority=$vless_grpc_default_authority_value
        [[ $grpc_authority == "$grpc_default_authority" ]] || {
            outbound_proxy_parse_error="VLESS gRPC authority 不能独立覆盖，当前构建默认值为 $grpc_default_authority"
            return 1
        }
    fi
    if [[ $ech_enabled == 1 ]]; then
        [[ $security == tls ]] || {
            outbound_proxy_parse_error="VLESS ECH 仅支持 TLS，不能与 security=$security 组合"
            return 1
        }
        if [[ $fingerprint && $fingerprint != none ]]; then
            outbound_proxy_parse_error="VLESS ECH 与 uTLS fingerprint 组合不兼容"
            return 1
        fi
        if [[ $ech ]]; then
            normalize_vless_ech_config "$ech" || {
                outbound_proxy_parse_error="VLESS ECH 必须是 ECH CONFIGS PEM 或静态 ECHConfigList Base64"
                return 1
            }
            ech_config=$vless_ech_config
        fi
    fi
    if [[ $pcs ]]; then
        [[ $security == tls ]] || {
            outbound_proxy_parse_error="VLESS pcs 整张证书 SHA-256 固定需要 TLS"
            return 1
        }
        vless_core_supports_certificate_sha256 || {
            outbound_proxy_parse_error="VLESS pcs 整张证书 SHA-256 固定需要 sing-box 1.15.0+，当前版本 ${is_core_ver:-未知} 不支持"
            return 1
        }
        normalize_vless_certificate_sha256 "$pcs" || {
            outbound_proxy_parse_error="VLESS pcs 必须是逗号分隔的 32 字节整张证书 SHA-256 十六进制或 Base64 摘要"
            return 1
        }
        pcs_enabled=1
    fi
    if [[ $vcn ]]; then
        [[ $security == tls && $vcn == "$sni" ]] || {
            outbound_proxy_parse_error="VLESS vcn 仅支持空值或与 TLS SNI 相同的证书校验名"
            return 1
        }
    fi
    if [[ $spx ]]; then
        outbound_proxy_parse_error="VLESS spx/spiderX 非空值与 sing-box Reality 参数不等价，暂不支持"
        return 1
    fi
    [[ ! $packet_encoding || $packet_encoding == xudp || $packet_encoding == packetaddr ]] || {
        outbound_proxy_parse_error="VLESS packetEncoding 仅支持 xudp、packetaddr、none 或空值"
        return 1
    }
}

parse_vless_uri() {
    local uri=$1 raw_name= raw_query= decoded_auth=
    local fragment_present=0 remark_name= encryption= transport= transport_original= transport_type= security= flow=
    local sni= sni_present=0 alpn= alpn_present=0 fingerprint= fingerprint_present=0
    local public_key= public_key_present=0 short_id= short_id_present=0 insecure=false insecure_present=0
    local packet_encoding= packet_encoding_present=0 utls_enabled=false
    local ech= ech_config= ech_enabled=0 pcs= pcs_enabled=0 vcn= spx=
    local vless_certificate_sha256_csv=
    local http_path=/ http_host= http_host_present=0
    local grpc_authority= authority_present=0
    local ws_path=/ ws_host= ws_host_present=0 ws_early_data= ws_early_data_present=0 ws_early_data_header= ws_early_data_header_present=0
    local grpc_service_name= grpc_service_name_present=0

    outbound_proxy_parse_error="VLESS 链接格式或参数无效"
    outbound_proxy_name=
    outbound_proxy_config_json=
    uri_query_json='{}'

    parse_vless_uri_common || return 1
    parse_vless_transport_params || return 1
    parse_vless_tls_params || return 1

    outbound_proxy_name=
    if [[ $fragment_present == 1 ]]; then
        outbound_proxy_name=$(url_percent_decode "$raw_name") || {
            outbound_proxy_parse_error="VLESS 链接名称编码无效"
            return 1
        }
    elif [[ $remark_name ]]; then
        outbound_proxy_name=$remark_name
    fi
    outbound_proxy_config_json=$(jq -cn \
        --arg server "$uri_server" \
        --argjson server_port "$uri_port_number" \
        --arg uuid "$decoded_auth" \
        --arg security "$security" \
        --arg sni "$sni" \
        --argjson insecure "$insecure" \
        --arg alpn "$alpn" \
        --argjson alpn_present "${alpn_present:-0}" \
        --argjson utls_enabled "$utls_enabled" \
        --arg fingerprint "$fingerprint" \
        --arg public_key "$public_key" \
        --arg short_id "$short_id" \
        --arg flow "$flow" \
        --arg transport "$transport" \
        --arg http_path "$http_path" \
        --arg http_host "$http_host" \
        --argjson http_host_present "$http_host_present" \
        --arg packet_encoding "$packet_encoding" \
        --argjson packet_encoding_present "${packet_encoding_present:-0}" \
        --arg transport_type "$transport_type" \
        --arg ws_path "$ws_path" \
        --arg ws_host "$ws_host" \
        --argjson ws_host_present "$ws_host_present" \
        --arg ws_early_data "$ws_early_data" \
        --argjson ws_early_data_present "$ws_early_data_present" \
        --arg ws_early_data_header "$ws_early_data_header" \
        --argjson ws_early_data_header_present "$ws_early_data_header_present" \
        --arg grpc_service_name "$grpc_service_name" \
        --argjson grpc_service_name_present "$grpc_service_name_present" \
        --arg ech_config "$ech_config" \
        --argjson ech_enabled "$ech_enabled" \
        --arg pcs_csv "$vless_certificate_sha256_csv" \
        --argjson pcs_enabled "$pcs_enabled" \
        '{type:"vless",server:$server,server_port:$server_port,uuid:$uuid}
        + if $security == "none" then {} else
            {tls:({enabled:true,server_name:$sni,insecure:$insecure}
                + if $alpn_present == 1 then {alpn:($alpn | split(","))} else {} end
                + if $utls_enabled then {utls:{enabled:true,fingerprint:$fingerprint}} else {} end
                + if $security == "reality" then {reality:{enabled:true,public_key:$public_key,short_id:$short_id}} else {} end
                + if $ech_enabled == 1 then {ech:({enabled:true} + if $ech_config == "" then {} else {config:$ech_config} end)} else {} end
                + if $pcs_enabled == 1 then {certificate_sha256:($pcs_csv | split(","))} else {} end)}
          end
        + if $flow == "" then {} else {flow:$flow} end
        + if $packet_encoding_present == 1 then {packet_encoding:$packet_encoding} else {} end
        + if $transport_type == "ws" then
            {transport:({type:"ws",path:$ws_path}
                + if $ws_host_present == 1 then {headers:{Host:$ws_host}} else {} end
                + if $ws_early_data_present == 1 then
                    {max_early_data:($ws_early_data|tonumber)}
                    + if $ws_early_data_header_present == 1 then {early_data_header_name:$ws_early_data_header} else {} end
                  else {} end)}
          elif $transport_type == "grpc" then
            {transport:({type:"grpc"}
                + if $grpc_service_name_present == 1 then {service_name:$grpc_service_name} else {} end)}
          elif $transport == "tcp" then {}
          elif $transport == "http" then
            {transport:({type:"http",path:$http_path}
                + if $http_host_present == 1 then {host:($http_host | split(","))} else {} end)}
          elif $transport == "httpupgrade" then
            {transport:({type:"httpupgrade",path:$http_path}
                + if $http_host_present == 1 then {host:$http_host} else {} end)}
          elif $transport == "quic" then
            {transport:{type:"quic"}}
          else {} end') || {
        outbound_proxy_parse_error="无法构造 VLESS 原生出站参数"
        return 1
    }
    return 0
}

parse_proxy_uri() {
    local expected=$1 uri=$2
    outbound_proxy_parse_error=
    case $expected in
    ss)
        parse_ss_uri "$uri"
        ;;
    vless)
        parse_vless_uri "$uri"
        ;;
    *)
        outbound_proxy_parse_error="不支持的代理出站类型"
        return 1
        ;;
    esac
}

parse_ss_uri() {
    local uri=$1 raw_name= raw_query= auth authority decoded_auth
    local fragment_present=0 fragment_name remark_name remarks_name remark_present remarks_present plugin key
    outbound_proxy_parse_error=
    outbound_proxy_json=
    outbound_proxy_config_json=
    outbound_proxy_name=
    is_outbound_ss_name=
    is_outbound_ss_server=
    is_outbound_ss_port=
    is_outbound_ss_method=
    is_outbound_ss_password=
    uri=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$uri")
    if [[ $uri =~ [[:cntrl:]] ]]; then
        outbound_proxy_parse_error="SS 分享链接含控制字符"
        return 1
    fi
    if [[ $uri != ss://* ]]; then
        outbound_proxy_parse_error="仅支持单条 ss:// Shadowsocks 分享链接"
        return 1
    fi
    uri=${uri#ss://}
    if [[ $uri == *#* ]]; then
        fragment_present=1
        raw_name=${uri#*#}
        uri=${uri%%#*}
    fi
    if [[ $uri == *\?* ]]; then
        raw_query=${uri#*\?}
        uri=${uri%%\?*}
        if ! parse_uri_query "$raw_query"; then
            outbound_proxy_parse_error="SS 查询参数格式、重复项或百分号编码无效"
            return 1
        fi
    else
        parse_uri_query ""
    fi
    if [[ $uri != *@* ]]; then
        outbound_proxy_parse_error="SS 分享链接缺少凭据或服务器地址"
        return 1
    fi
    auth=${uri%@*}
    authority=${uri#*@}
    if [[ ! $auth || $auth == *@* || $authority == *@* ]]; then
        outbound_proxy_parse_error="SS 分享链接凭据或服务器地址格式无效"
        return 1
    fi
    [[ $authority == */ ]] && authority=${authority%/}
    if [[ $authority == */* ]] || ! parse_uri_authority "$authority"; then
        outbound_proxy_parse_error="SS 服务器地址或端口无效"
        return 1
    fi

    if ! decoded_auth=$(url_percent_decode "$auth"); then
        outbound_proxy_parse_error="SS 凭据含无效百分号编码或控制字符"
        return 1
    fi
    if [[ $decoded_auth != *:* ]]; then
        if ! decoded_auth=$(ss_base64_decode "$decoded_auth" 2>/dev/null) 2>/dev/null; then
            outbound_proxy_parse_error="SS 凭据 Base64 编码无效"
            return 1
        fi
    fi
    if [[ $decoded_auth != *:* ]]; then
        outbound_proxy_parse_error="SS 凭据必须包含加密方式和密码"
        return 1
    fi
    is_outbound_ss_method=${decoded_auth%%:*}
    is_outbound_ss_password=${decoded_auth#*:}
    is_outbound_ss_server=$uri_server
    is_outbound_ss_port=$uri_port_number
    if ! ss_method_supported "$is_outbound_ss_method"; then
        outbound_proxy_parse_error="SS 加密方式不受支持"
        return 1
    fi
    if [[ ! $is_outbound_ss_password || $decoded_auth =~ [[:cntrl:]] ]]; then
        outbound_proxy_parse_error="SS 密码为空或含控制字符"
        return 1
    fi
    if ! ss_password_valid_for_method "$is_outbound_ss_method" "$is_outbound_ss_password"; then
        outbound_proxy_parse_error="SS2022 密钥 Base64 格式或长度无效"
        return 1
    fi

    for key in "${uri_query_keys[@]}"; do
        case $key in
        remark | remarks | plugin) ;;
        *)
            outbound_proxy_parse_error="SS 分享链接包含不支持的参数: $key"
            return 1
            ;;
        esac
    done
    plugin=${uri_query_map[plugin]-}
    if [[ $plugin ]]; then
        outbound_proxy_parse_error="SS 插件暂不支持 (plugin)"
        return 1
    fi
    remarks_name=${uri_query_map[remarks]-}
    remark_name=${uri_query_map[remark]-}
    [[ ${uri_query_map[remarks]+_} ]] && remarks_present=true || remarks_present=false
    [[ ${uri_query_map[remark]+_} ]] && remark_present=true || remark_present=false
    if [[ $remarks_present == true && $remark_present == true && $remarks_name != "$remark_name" ]]; then
        outbound_proxy_parse_error="remark 和 remarks 参数值冲突"
        return 1
    fi
    if [[ $fragment_present == 1 ]]; then
        if ! fragment_name=$(url_percent_decode "$raw_name"); then
            outbound_proxy_parse_error="SS 分享名称含无效百分号编码或控制字符"
            return 1
        fi
        is_outbound_ss_name=$fragment_name
    elif [[ $remarks_present == true ]]; then
        is_outbound_ss_name=$remarks_name
    elif [[ $remark_present == true ]]; then
        is_outbound_ss_name=$remark_name
    else
        is_outbound_ss_name=
    fi
    outbound_proxy_name=$is_outbound_ss_name
    outbound_proxy_config_json=$(jq -cn \
        --arg server "$is_outbound_ss_server" \
        --argjson server_port "$is_outbound_ss_port" \
        --arg method "$is_outbound_ss_method" \
        --arg password "$is_outbound_ss_password" \
        '{type:"shadowsocks",server:$server,server_port:$server_port,method:$method,password:$password}') || return 1
    return 0
}

parse_ss_uri_for_outbound() {
    parse_proxy_uri ss "$1"
}

outbound_proxy_from_metadata() {
    local cfg=$1 metadata_file=$2 status mode name config_json proxy_json method password
    local -a fields=()
    outbound_proxy_json=
    outbound_proxy_config_json=
    outbound_proxy_name=
    [[ -f $metadata_file ]] || return 0
    mapfile -d '' -t fields < <(jq -j '
        if type != "object" then error("not object") else . end
        | (if .outbound_mode == null or .outbound_mode == false then "" else (.outbound_mode | tostring) end) as $mode
        | if has("outbound_proxy") then
            .outbound_proxy as $op
            | if ($op | type == "object")
                and ($op.name | type == "string")
                and ($op.config | type == "object")
                and ($op.config.type == "shadowsocks" or $op.config.type == "vless")
                and ($op.config.server | type == "string" and length > 0)
                and ($op.config.server_port | type == "number" and . >= 1 and . <= 65535 and floor == .)
                and (($op.config | has("tag") or has("detour")) | not)
                and ($op.config.type != "shadowsocks" or
                    (($op.config.method | type == "string" and length > 0)
                     and ($op.config.password | type == "string" and length > 0)))
                and ($op.config.type != "vless" or
                    ($op.config.uuid | type == "string" and length > 0))
              then
                ["ok", $mode, $op.name, ($op.config | tojson), ($op | tojson), "", ""]
              else
                ["bad", $mode, "", "", "", "", ""]
              end
          elif $mode == "SS 出站" or has("outbound_ss_server") then
            (if .outbound_ss_server == null or .outbound_ss_server == false then "" else (.outbound_ss_server | tostring) end) as $server
            | (if .outbound_ss_port == null or .outbound_ss_port == false then "" else (.outbound_ss_port | tostring) end) as $port
            | (if .outbound_ss_method == null or .outbound_ss_method == false then "" else (.outbound_ss_method | tostring) end) as $method
            | (if .outbound_ss_password == null or .outbound_ss_password == false then "" else (.outbound_ss_password | tostring) end) as $password
            | (if .outbound_ss_name == null or .outbound_ss_name == false then "" else (.outbound_ss_name | tostring) end) as $name
            | if $server != "" and ($port | test("^0*[1-9][0-9]{0,4}$")) and $method != "" and $password != ""
                and (($port | tonumber) >= 1 and ($port | tonumber) <= 65535)
              then
                ({type:"shadowsocks",server:$server,server_port:($port | tonumber),method:$method,password:$password}) as $cfg
                | ["legacy_candidate", $mode, $name, ($cfg | tojson), ({name:$name,config:$cfg} | tojson), $method, $password]
              else
                ["bad", $mode, "", "", "", "", ""]
              end
          else
            ["none", $mode, "", "", "", "", ""]
          end
        | .[0], "\u0000", .[1], "\u0000", .[2], "\u0000", .[3], "\u0000", .[4], "\u0000", .[5], "\u0000", .[6], "\u0000"
    ' "$metadata_file" 2>/dev/null)
    (( ${#fields[@]} == 7 )) || return 1
    status=${fields[0]}
    mode=${fields[1]}
    name=${fields[2]}
    config_json=${fields[3]}
    proxy_json=${fields[4]}
    method=${fields[5]}
    password=${fields[6]}

    case $status in
    ok)
        outbound_proxy_name=$name
        outbound_proxy_config_json=$config_json
        outbound_proxy_json=$proxy_json
        return 0
        ;;
    legacy_candidate)
        if ss_method_supported "$method" && ss_password_valid_for_method "$method" "$password"; then
            outbound_proxy_name=$name
            outbound_proxy_config_json=$config_json
            outbound_proxy_json=$proxy_json
            return 0
        fi
        ;;
    esac
    [[ $mode == 'SS 出站' || $mode == 'VLESS 出站' ]] && return 1
    return 0
}
