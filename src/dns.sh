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
    local candidate_config= is_interactive= is_dns_use_bak= dns_choice_status= dns_impact=
    local is_dns_new= is_dns_type= config_locked= sync_fn=
    [[ ! $1 ]] && is_interactive=1
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
                ask string is_dns_use "请输入 DNS 地址或 URL (例如 1.1.1.1 或 https://dns.example/dns-query): "
            fi
            ;;
        none)
            is_dns_use=none
            ;;
        *)
            err "无法识别 DNS 参数: $*"
            return 1
            ;;
        esac
    else
        is_tmp_list=("${is_dns_list[@]}")
        is_tmp_list[5]="自定义"
        is_tmp_list[6]="不设置"
        menu_select parent is_dns_use "\n请选择 DNS；选择“自定义”输入地址，选择“不设置”清除 DNS 配置:\n" "${is_tmp_list[@]}"
        dns_choice_status=$?
        [[ $dns_choice_status == 2 ]] && return 2
        [[ $dns_choice_status == 0 ]] || return 1
        case $is_dns_use in
        自定义) is_dns_use=set ;;
        不设置) is_dns_use=none ;;
        esac
        if [[ $is_dns_use == "set" ]]; then
            ask string is_dns_use "请输入 DNS 地址或 URL (例如 1.1.1.1 或 https://dns.example/dns-query): "
        fi
    fi
    is_dns_use_bak=$is_dns_use
    [[ $is_interactive && $is_dns_use_bak == none ]] && is_dns_use_bak="不设置"
    if [[ $is_interactive ]]; then
        if [[ $is_dns_use == none ]]; then
            dns_impact='清除现有 DNS 配置并重启 sing-box；现有节点配置不变'
        else
            dns_impact='更新运行时 DNS 配置并重启 sing-box；现有节点配置不变'
        fi
        menu_system_impact "DNS 配置：$is_dns_use_bak" "$dns_impact" "是" : || return 1
    fi
    if [[ $is_dns_use != "none" && $is_dns_new ]]; then
        dns_set_server "$is_dns_use" || return 1
    fi
    shared_config_lock || {
        err "${shared_config_error:-无法获取公共配置锁}"
        return 1
    }
    config_locked=1
    candidate_config=$(mktemp "$is_config_json.dns.XXXXXX") || {
        shared_config_unlock
        err "无法创建 DNS 候选配置"
        return 1
    }
    if [[ $is_dns_use == "none" ]]; then
        jq '. | .dns = {} | del(.route.default_domain_resolver)' "$is_config_json" >"$candidate_config"
    elif [[ $is_dns_new ]]; then
        jq --arg dns_type "$is_dns_type" --arg dns_server "$is_dns_use" \
            '. | .dns.servers = [{tag: "dns", type: $dns_type, server: $dns_server, domain_resolver: "local"}, {tag: "local", type: "local"}] | .route.default_domain_resolver = "dns"' \
            "$is_config_json" >"$candidate_config"
    else
        jq --arg dns_server "$is_dns_use" \
            '.dns.servers = [{address: $dns_server, address_resolver: "local"}, {tag: "local", address: "local"}]' \
            "$is_config_json" >"$candidate_config"
    fi
    if [[ $? -ne 0 || ! -s $candidate_config ]] || ! jq -e 'type == "object"' "$candidate_config" >/dev/null 2>&1; then
        rm -f "$candidate_config"
        [[ $config_locked ]] && shared_config_unlock
        err "无法生成 DNS 候选配置"
        return 1
    fi
    sync_fn=sync_runtime_node_outbound_modes
    if declare -F sync_runtime_node_outbound_modes_unlocked >/dev/null 2>&1; then
        sync_fn=sync_runtime_node_outbound_modes_unlocked
    fi
    if ! "$sync_fn" "$candidate_config" "$is_config_json" "$is_conf_dir" 1; then
        rm -f "$candidate_config"
        [[ $config_locked ]] && shared_config_unlock
        err "节点代理路由同步失败: ${runtime_sync_error:-未知错误}"
        return 1
    fi
    rm -f "$candidate_config"
    [[ $config_locked ]] && shared_config_unlock
    manage restart &
    msg "\n已更新 DNS 为: $(_green "$is_dns_use_bak")\n"
}
dns_set_server() {
    local input=${1,,} scheme host_rest
    if [[ $input == *://* ]]; then
        scheme=${input%%://*}
        host_rest=${input#*://}
        host_rest=${host_rest%%/*}
        case $scheme in
        tcp | udp | tls | https | quic | h3)
            is_dns_use=$host_rest
            is_dns_type=$scheme
            ;;
        *)
            err "无法识别 DNS 类型!"
            return 1
            ;;
        esac
    else
        is_dns_use=$1
        is_dns_type=udp
    fi
}
