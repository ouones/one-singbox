is_dns_list=(
    1.1.1.1
    8.8.8.8
    h3://dns.google/dns-query
    h3://cloudflare-dns.com/dns-query
    h3://family.cloudflare-dns.com/dns-query
    set
    none
)
dns_set() {
    local candidate_config
    if [[ $(echo -e "1.11.99\n$is_core_ver" | sort -V | head -n1) == '1.11.99' ]]; then
        is_dns_new=1
    fi
    if [[ $1 ]]; then
        case ${1,,} in
        11 | 1111)
            is_dns_use=${is_dns_list[0]}
            ;;
        88 | 8888)
            is_dns_use=${is_dns_list[1]}
            ;;
        gg | google)
            is_dns_use=${is_dns_list[2]}
            ;;
        cf | cloudflare)
            is_dns_use=${is_dns_list[3]}
            ;;
        nosex | family)
            is_dns_use=${is_dns_list[4]}
            ;;
        set)
            if [[ $2 ]]; then
                is_dns_use=${2,,}
            else
                ask string is_dns_use "请输入 DNS: "
            fi
            ;;
        none)
            is_dns_use=none
            ;;
        *)
            err "无法识别 DNS 参数: $@"
            ;;
        esac
    else
        is_tmp_list=(${is_dns_list[@]})
        ask list is_dns_use null "\n请选择 DNS:\n"
        if [[ $is_dns_use == "set" ]]; then
            ask string is_dns_use "请输入 DNS: "
        fi
    fi
    is_dns_use_bak=$is_dns_use
    candidate_config=$(mktemp "$is_config_json.dns.XXXXXX") || err "无法创建 DNS 候选配置"
    if [[ $is_dns_use == "none" ]]; then
        jq '.|.dns={}|del(.route.default_domain_resolver)' "$is_config_json" >"$candidate_config" || { rm -f "$candidate_config"; err "无法生成 DNS 候选配置"; }
    else
        if [[ $is_dns_new ]]; then
            dns_set_server $is_dns_use
            jq '.|.dns.servers=[{tag:"dns",type:"'$is_dns_type'",server:"'$is_dns_use'",domain_resolver:"local"},{tag:"local",type:"local"}]|.route.default_domain_resolver="dns"' "$is_config_json" >"$candidate_config" || { rm -f "$candidate_config"; err "无法生成 DNS 候选配置"; }
        else
            jq '.dns.servers=[{address:"'$is_dns_use'",address_resolver:"local"},{tag:"local",address:"local"}]' "$is_config_json" >"$candidate_config" || { rm -f "$candidate_config"; err "无法生成 DNS 候选配置"; }
        fi
    fi
    if ! sync_runtime_node_outbound_modes "$candidate_config" "$is_config_json" "$is_conf_dir" 1; then
        rm -f "$candidate_config"
        err "节点代理路由同步失败: ${runtime_sync_error:-未知错误}"
    fi
    rm -f "$candidate_config"
    manage restart &
    msg "\n已更新 DNS 为: $(_green $is_dns_use_bak)\n"
}
dns_set_server() {
    if [[ $(grep '://' <<<$1) ]]; then
        is_tmp_dns_set=($(awk -F '://|/' '{print $1, $2}' <<<${1,,}))
        case ${is_tmp_dns_set[0]} in
        tcp | udp | tls | https | quic | h3)
            is_dns_use=${is_tmp_dns_set[1]}
            is_dns_type=${is_tmp_dns_set[0]}
            ;;
        *)
            err "无法识别 DNS 类型!"
            ;;
        esac
    else
        is_dns_use=$1
        is_dns_type=udp
    fi
}
