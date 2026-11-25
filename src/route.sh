# Outbound mode rendering, block-cn routing, and node lifecycle transactions.

outbound_mode_to_direct_tag() {
    case $1 in
    "V6优先") echo direct_v6_pref ;;
    "V4优先") echo direct_v4_pref ;;
    "仅V4") echo direct_v4_only ;;
    "仅V6") echo direct_v6_only ;;
    *) return 1 ;;
    esac
}

outbound_mode_display_name() {
    case $1 in
    "V6优先") echo "IPv6 优先" ;;
    "V4优先") echo "IPv4 优先" ;;
    "仅V4") echo "仅 IPv4" ;;
    "仅V6") echo "仅 IPv6" ;;
    "SS 出站") echo "Shadowsocks 出口" ;;
    "VLESS 出站") echo "VLESS 出口" ;;
    *) echo "$1" ;;
    esac
}

msg_outbound_mode_display() {
    local prefix=$1 cfg=$2 display
    display=$(current_outbound_mode_display "$cfg")
    printf '\n%s %b%s%b\n' "$prefix" "$green" "$display" "$none"
}

runtime_node_ss_outbound_tag() {
    local cfg=$1 safe
    safe=${cfg//[^[:alnum:]_-]/_}
    echo "managed_node_ss_$safe"
}

runtime_domain_resolver_tag() {
    local config_file=${1:-$is_config_json}
    jq -r 'if (.route.default_domain_resolver | type) == "string" then .route.default_domain_resolver elif (.route.default_domain_resolver | type) == "object" then (.route.default_domain_resolver.server // "local") else "local" end' "$config_file" 2>/dev/null
}

runtime_node_vless_outbound_tag() {
    local cfg=$1 safe
    safe=${cfg//[^[:alnum:]_-]/_}
    echo "managed_node_vless_$safe"
}

block_cn_is_enabled() {
    [[ -f ${is_core_dir:-/etc/sing-box}/.block-cn-enabled ]]
}

block_cn_status_text() {
    if block_cn_is_enabled; then
        echo "已启用"
    else
        echo "未启用"
    fi
}

block_cn_strip_legacy_inbound_fields_json() {
    local json_input=${1:-}
    local filter='if .inbounds then .inbounds |= map(if type == "object" then del(.sniff, .sniff_override_destination, .sniff_timeout) else . end) else . end'
    if [[ -n $json_input ]]; then
        jq "$filter" <<<"$json_input"
    else
        jq "$filter"
    fi
}

block_cn_clean_legacy_inbounds() {
    local target_file=$1
    [[ -f $target_file ]] || return 0
    if jq -e '(.inbounds // []) | any(type == "object" and (.sniff != null or .sniff_override_destination != null or .sniff_timeout != null))' "$target_file" >/dev/null 2>&1; then
        local tmp
        tmp=$(mktemp "$target_file.tmp.XXXXXX") || return 1
        if block_cn_strip_legacy_inbound_fields_json <"$target_file" >"$tmp"; then
            mv -f "$tmp" "$target_file"
        else
            rm -f "$tmp"
            return 1
        fi
    fi
    return 0
}

block_cn_clean_all_legacy_inbounds() {
    local conf_dir=${1:-$is_conf_dir}
    [[ -d $conf_dir ]] || return 0
    local file
    for file in "$conf_dir"/*.json; do
        [[ -f $file ]] || continue
        [[ $file =~ dynamic-port-.*-link ]] && continue
        block_cn_clean_legacy_inbounds "$file"
    done
}

block_cn_load_whitelist_rules() {
    local file=${1:-${is_core_dir:-/etc/sing-box}/.cn-whitelist.json}
    [[ -f $file ]] || {
        echo "[]"
        return 0
    }
    jq -ec '
        if type == "array" then
            .
        elif type == "object" then
            [.]
        else
            []
        end
        | map(select(type == "object" and (((.domain // []) + (.domain_suffix // [])) | length > 0)))
    ' "$file" 2>/dev/null || echo "[]"
}

block_cn_sync_whitelist() {
    local core_dir=${is_core_dir:-/etc/sing-box}
    local cache_file="$core_dir/.cn-whitelist.json"
    local url="${BLOCK_CN_WHITELIST_URL:-https://raw.githubusercontent.com/ouones/quan/refs/heads/main/sing-box/cn-whitelist.jsonc}"
    local tmp_download tmp_clean tmp_json
    local download_ok=0

    mkdir -p "$core_dir" 2>/dev/null || true
    tmp_download=$(mktemp "$core_dir/.cn-whitelist.download.XXXXXX" 2>/dev/null || mktemp)

    if type -P curl >/dev/null 2>&1; then
        if curl -fsSL --connect-timeout 10 -m 30 "$url" -o "$tmp_download" 2>/dev/null; then
            download_ok=1
        fi
    elif type -P wget >/dev/null 2>&1; then
        if wget --no-check-certificate -q -T 10 -t 2 "$url" -O "$tmp_download" 2>/dev/null; then
            download_ok=1
        fi
    fi

    if [[ $download_ok -eq 1 && -s $tmp_download ]]; then
        tmp_clean=$(json_strip_comments "$tmp_download" 2>/dev/null)
        if [[ $tmp_clean ]]; then
            tmp_json=$(jq -c '
                if type == "object" then
                    del(.inbound) | .action = (.action // "route") | .outbound = "direct"
                elif type == "array" then
                    map(if type == "object" then del(.inbound) | .action = (.action // "route") | .outbound = "direct" else empty end)
                else
                    empty
                end
            ' <<<"$tmp_clean" 2>/dev/null)
        fi
    fi

    if [[ $tmp_json ]] && jq -e 'if type == "array" then length > 0 elif type == "object" then (((.domain // []) + (.domain_suffix // [])) | length > 0) else false end' <<<"$tmp_json" >/dev/null 2>&1; then
        printf '%s\n' "$tmp_json" | jq . >"$tmp_download" && mv -f "$tmp_download" "$cache_file"
        return 0
    fi

    rm -f "$tmp_download"

    if [[ -f $cache_file ]] && jq -e . "$cache_file" >/dev/null 2>&1; then
        warn "下载回国白名单失败，自动降级采用本地缓存白名单"
        return 0
    fi

    warn "下载回国白名单失败且无本地缓存，将跳过白名单规则注入"
    return 0
}

block_cn_enable() {
    local core_dir=${is_core_dir:-/etc/sing-box}
    mkdir -p "$core_dir" || {
        err "无法创建目录: $core_dir"
        return 1
    }
    touch "$core_dir/.block-cn-enabled" || {
        err "无法创建状态文件: $core_dir/.block-cn-enabled"
        return 1
    }
    block_cn_sync_whitelist
    block_cn_clean_all_legacy_inbounds "${is_conf_dir:-$core_dir/conf}"
    sync_runtime_node_outbound_modes "$is_config_json" "$is_config_json" "${is_conf_dir:-$core_dir/conf}" 1 || {
        rm -f "$core_dir/.block-cn-enabled"
        err "同步运行时路由配置失败: ${runtime_sync_error:-未知错误}"
        return 1
    }
    manage_restart_checked "" "屏蔽回国流量配置已更新" || return 1
}

block_cn_disable() {
    local core_dir=${is_core_dir:-/etc/sing-box}
    rm -f "$core_dir/.block-cn-enabled"
    sync_runtime_node_outbound_modes "$is_config_json" "$is_config_json" "${is_conf_dir:-$core_dir/conf}" 1 || {
        err "同步运行时路由配置失败: ${runtime_sync_error:-未知错误}"
        return 1
    }
    manage_restart_checked "" "屏蔽回国流量配置已更新" || return 1
}

block_cn_toggle() {
    if block_cn_is_enabled; then
        block_cn_disable
    else
        block_cn_enable
    fi
}

block_cn_menu_toggle() {
    if block_cn_is_enabled; then
        block_cn_disable || return 1
        msg "\n已禁用屏蔽回国流量。\n"
    else
        block_cn_enable || return 1
        msg "\n已启用屏蔽回国流量。\n"
    fi
}

block_cn_cli() {
    local action=${1:-toggle}
    case $action in
    status) ;;
    enable | on)
        block_cn_enable || return 1
        ;;
    disable | off)
        block_cn_disable || return 1
        ;;
    toggle)
        block_cn_toggle || return 1
        ;;
    *)
        err "无效参数: $action (支持: status, enable, disable, toggle)"
        return 1
        ;;
    esac
    msg "屏蔽回国流量: $(block_cn_status_text)"
}

_collect_managed_node_files() {
    local config_dir=$1 override_cfg=$2 override_meta=$3
    local -n _out_node_files=$4
    local -n _out_node_cfgs=$5
    local -n _out_meta_files=$6
    local -n _out_meta_unique=$7
    local file cfg meta_path nullglob_was_set=0
    local -A seen_meta=()

    _out_node_files=()
    _out_node_cfgs=()
    _out_meta_files=()
    _out_meta_unique=()
    [[ -d $config_dir ]] || return 0

    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    for file in "$config_dir"/*.json; do
        [[ -f $file ]] || continue
        cfg=${file##*/}
        [[ $cfg =~ dynamic-port-.*-link || $cfg == relay-*.json ]] && continue
        meta_path="$config_dir/.quan-meta/$cfg.meta.json"
        [[ $override_cfg && $cfg == "$override_cfg" ]] && meta_path=$override_meta
        _out_node_files+=("$file")
        _out_node_cfgs+=("$cfg")
        _out_meta_files+=("$meta_path")
        if [[ $meta_path && -f $meta_path && ! ${seen_meta[$meta_path]+exists} ]]; then
            seen_meta[$meta_path]=1
            _out_meta_unique+=("$meta_path")
        fi
    done
    (( nullglob_was_set )) || shopt -u nullglob
}

_render_locate_node_or_meta_error() {
    local -n _err_node_files=$1
    local -n _err_node_cfgs=$2
    local -n _err_meta_files=$3
    local i file cfg meta_path
    for i in "${!_err_node_files[@]}"; do
        file=${_err_node_files[i]}
        cfg=${_err_node_cfgs[i]}
        meta_path=${_err_meta_files[i]}
        if [[ -f $meta_path ]]; then
            jq -e 'type == "object"' "$meta_path" >/dev/null 2>&1 || {
                runtime_sync_error="节点元数据格式无效: $cfg"
                return 1
            }
            jq -r '.outbound_mode // empty' "$meta_path" >/dev/null 2>&1 || {
                runtime_sync_error="无法读取节点出站方式: $cfg"
                return 1
            }
        fi
        if [[ -s $file ]]; then
            jq -ce '[.inbounds[]? | .tag? // empty | select(type == "string" and length > 0)]' "$file" >/dev/null 2>&1 || {
                runtime_sync_error="无法读取节点入站 tag: $cfg"
                return 1
            }
        fi
    done
    runtime_sync_error="读取节点配置或元数据失败"
    return 1
}

render_runtime_node_outbound_modes() {
    local source_config=$1 output=$2 override_cfg=${3:-} override_meta=${4:-} config_dir=${5:-$is_conf_dir}
    local resolver file cfg mode outbound meta_path tags config_type server add_resolver status method password
    local core_dir=${is_core_dir:-/etc/sing-box}
    local block_cn_enabled=false
    local cached_whitelist="[]"
    local has_direct_nodes=false
    local node_specs_jsonl=""
    local proxy_specs_jsonl=""
    local -a node_files=() node_cfgs=() meta_files=() meta_unique_files=()
    local -a node_fields=() meta_fields=()
    local -A used_proxy_tags=()
    local -A node_tags_by_file=() node_seen_count=()
    local -A meta_status_by_file=() meta_mode_by_file=() meta_has_mode_by_file=()
    local -A meta_type_by_file=() meta_server_by_file=() meta_method_by_file=() meta_password_by_file=() meta_cfg_by_file=() meta_seen_count=()
    local i batch_ok=1

    runtime_sync_error=
    [[ -f $source_config && $output ]] || {
        runtime_sync_error="公共配置文件不存在"
        return 1
    }
    resolver=$(jq -er '
        if (type == "object" and ((.outbounds // []) | type == "array") and ((.route // {}) | type == "object") and ((.route.rules // []) | type == "array")) then
            if (.route.default_domain_resolver | type) == "string" then .route.default_domain_resolver
            elif (.route.default_domain_resolver | type) == "object" then (.route.default_domain_resolver.server // "local")
            else "local"
            end
        else
            error("invalid_source_config")
        end
    ' "$source_config" 2>/dev/null) || {
        runtime_sync_error="公共配置格式无效"
        return 1
    }
    [[ $resolver ]] || resolver=local

    if [[ -f $core_dir/.cn-whitelist.json ]]; then
        cached_whitelist=$(block_cn_load_whitelist_rules "$core_dir/.cn-whitelist.json")
    fi
    if block_cn_is_enabled; then
        block_cn_enabled=true
    fi

    _collect_managed_node_files "$config_dir" "$override_cfg" "$override_meta" node_files node_cfgs meta_files meta_unique_files

    if (( ${#node_files[@]} > 0 )); then
        mapfile -d '' -t node_fields < <(jq -j '
            [input_filename, ([.inbounds[]? | .tag? // empty | select(type == "string" and length > 0)] | tojson)]
            | .[0], "\u0000", .[1], "\u0000"
        ' "${node_files[@]}" 2>/dev/null)
        wait "$!" || batch_ok=0

        if (( batch_ok == 1 )); then
            for ((i = 0; i + 1 < ${#node_fields[@]}; i += 2)); do
                file=${node_fields[i]}
                node_tags_by_file[$file]=${node_fields[i + 1]}
                node_seen_count[$file]=$(( ${node_seen_count[$file]:-0} + 1 ))
            done
            for file in "${node_files[@]}"; do
                if [[ ! -s $file ]]; then
                    if (( ${node_seen_count[$file]:-0} == 0 )); then
                        node_tags_by_file[$file]="[]"
                        node_seen_count[$file]=1
                    else
                        batch_ok=0
                        break
                    fi
                elif (( ${node_seen_count[$file]:-0} != 1 )); then
                    batch_ok=0
                    break
                fi
            done
        fi

        if (( batch_ok == 1 && ${#meta_unique_files[@]} > 0 )); then
            mapfile -d '' -t meta_fields < <(jq -j '
                if type != "object" then error("not object") else . end
                | (if .outbound_mode == null or .outbound_mode == false then "" elif (.outbound_mode | type == "string") then .outbound_mode else (.outbound_mode | tojson) end) as $mode
                | (if has("outbound_mode") and (.outbound_mode | type == "string" and length > 0) then "1" else "0" end) as $has_mode
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
                        [input_filename, "ok", $mode, $has_mode, $op.config.type, $op.config.server, "", "", ($op.config | tojson)]
                      else
                        [input_filename, "bad", $mode, $has_mode, "", "", "", "", ""]
                      end
                  elif $mode == "SS 出站" or has("outbound_ss_server") then
                    (if .outbound_ss_server == null or .outbound_ss_server == false then "" else (.outbound_ss_server | tostring) end) as $server
                    | (if .outbound_ss_port == null or .outbound_ss_port == false then "" else (.outbound_ss_port | tostring) end) as $port
                    | (if .outbound_ss_method == null or .outbound_ss_method == false then "" else (.outbound_ss_method | tostring) end) as $method
                    | (if .outbound_ss_password == null or .outbound_ss_password == false then "" else (.outbound_ss_password | tostring) end) as $password
                    | if $server != "" and ($port | test("^0*[1-9][0-9]{0,4}$")) and $method != "" and $password != ""
                        and (($port | tonumber) >= 1 and ($port | tonumber) <= 65535)
                      then
                        ({type:"shadowsocks",server:$server,server_port:($port | tonumber),method:$method,password:$password}) as $cfg
                        | [input_filename, "legacy_candidate", $mode, $has_mode, "shadowsocks", $server, $method, $password, ($cfg | tojson)]
                      else
                        [input_filename, "bad", $mode, $has_mode, "", "", "", "", ""]
                      end
                  else
                    [input_filename, "none", $mode, $has_mode, "", "", "", "", ""]
                  end
                | .[0], "\u0000", .[1], "\u0000", .[2], "\u0000", .[3], "\u0000", .[4], "\u0000", .[5], "\u0000", .[6], "\u0000", .[7], "\u0000", .[8], "\u0000"
            ' "${meta_unique_files[@]}" 2>/dev/null)
            wait "$!" || batch_ok=0

            if (( batch_ok == 1 )); then
                for ((i = 0; i + 8 < ${#meta_fields[@]}; i += 9)); do
                    meta_path=${meta_fields[i]}
                    meta_status_by_file[$meta_path]=${meta_fields[i + 1]}
                    meta_mode_by_file[$meta_path]=${meta_fields[i + 2]}
                    meta_has_mode_by_file[$meta_path]=${meta_fields[i + 3]}
                    meta_type_by_file[$meta_path]=${meta_fields[i + 4]}
                    meta_server_by_file[$meta_path]=${meta_fields[i + 5]}
                    meta_method_by_file[$meta_path]=${meta_fields[i + 6]}
                    meta_password_by_file[$meta_path]=${meta_fields[i + 7]}
                    meta_cfg_by_file[$meta_path]=${meta_fields[i + 8]}
                    meta_seen_count[$meta_path]=$(( ${meta_seen_count[$meta_path]:-0} + 1 ))
                done
                for meta_path in "${meta_unique_files[@]}"; do
                    if (( ${meta_seen_count[$meta_path]:-0} != 1 )); then
                        batch_ok=0
                        break
                    fi
                done
            fi
        fi

        if (( batch_ok == 0 )); then
            _render_locate_node_or_meta_error node_files node_cfgs meta_files
            return 1
        fi

        for i in "${!node_files[@]}"; do
            file=${node_files[i]}
            cfg=${node_cfgs[i]}
            meta_path=${meta_files[i]}
            tags=${node_tags_by_file[$file]}
            if [[ $tags == "[]" ]]; then
                if [[ -f $meta_path && ${meta_has_mode_by_file[$meta_path]:-0} == 1 ]]; then
                    runtime_sync_error="节点没有可路由的入站 tag: $cfg"
                    return 1
                fi
                continue
            fi

            mode=
            [[ -f $meta_path ]] && mode=${meta_mode_by_file[$meta_path]:-}
            [[ $mode ]] || mode="V4优先"

            outbound=$(outbound_mode_to_direct_tag "$mode")
            if [[ $outbound ]]; then
                has_direct_nodes=true
            elif [[ $mode == 'SS 出站' || $mode == 'VLESS 出站' ]]; then
                [[ -f $meta_path ]] || {
                    runtime_sync_error="节点代理配置缺失: $cfg"
                    return 1
                }
                status=${meta_status_by_file[$meta_path]:-none}
                case $status in
                ok) ;;
                legacy_candidate)
                    method=${meta_method_by_file[$meta_path]:-}
                    password=${meta_password_by_file[$meta_path]:-}
                    if ! ss_method_supported "$method" || ! ss_password_valid_for_method "$method" "$password"; then
                        runtime_sync_error="节点代理配置无效: $cfg"
                        return 1
                    fi
                    ;;
                *)
                    runtime_sync_error="节点代理配置无效: $cfg"
                    return 1
                    ;;
                esac

                config_type=${meta_type_by_file[$meta_path]:-}
                if [[ $mode == 'SS 出站' && $config_type == shadowsocks ]]; then
                    outbound=$(runtime_node_ss_outbound_tag "$cfg")
                elif [[ $mode == 'VLESS 出站' && $config_type == vless ]]; then
                    outbound=$(runtime_node_vless_outbound_tag "$cfg")
                else
                    runtime_sync_error="节点代理协议与出站方式不一致: $cfg"
                    return 1
                fi

                [[ ! ${used_proxy_tags[$outbound]+exists} ]] || {
                    runtime_sync_error="受管出站 tag 冲突: $outbound"
                    return 1
                }
                used_proxy_tags[$outbound]=$cfg

                server=${meta_server_by_file[$meta_path]:-}
                add_resolver=false
                if ! is_valid_ipv4_addr "$server" && ! is_valid_ipv6_addr "$server"; then
                    add_resolver=true
                fi
                proxy_specs_jsonl+='{"tag":"'"$outbound"'","add_resolver":'"$add_resolver"',"config":'"${meta_cfg_by_file[$meta_path]}"'}'$'\n'
            else
                continue
            fi

            node_specs_jsonl+='{"inbound":'"$tags"',"outbound":"'"$outbound"'"}'$'\n'
        done
    fi

    jq --arg resolver "$resolver" --argjson has_direct "$has_direct_nodes" --argjson block_cn_enabled "$block_cn_enabled" --argjson cached_whitelist "$cached_whitelist" --slurpfile node_specs <(printf '%s' "$node_specs_jsonl") --slurpfile proxy_specs <(printf '%s' "$proxy_specs_jsonl") '
        def direct_managed_tags: ["direct_v6_pref","direct_v4_pref","direct_v4_only","direct_v6_only"];
        def is_managed_outbound_tag($tag):
            $tag == "block"
            or ((direct_managed_tags | index($tag)) != null)
            or ($tag | startswith("managed_node_ss_") or startswith("managed_node_vless_"));
        def is_managed_route_tag($tag):
            ((direct_managed_tags | index($tag)) != null)
            or ($tag | startswith("managed_node_ss_") or startswith("managed_node_vless_"));
        def is_broad_direct_rule($managed_inbounds):
            .outbound == "direct" and (
                ((keys - ["action","outbound"]) | length) == 0
                or (
                    ((keys - ["action","outbound","inbound"]) | length) == 0
                    and ((.inbound | type) == "array")
                    and ((.inbound | length) > 0)
                    and (.inbound | any(.[]; . as $tag | ($managed_inbounds | index($tag)) != null))
                )
            );
        def is_managed_whitelist_rule($managed_inbounds):
            (is_broad_direct_rule($managed_inbounds) | not) and (
                . as $rule |
                (
                    (($cached_whitelist // []) | any(
                        . as $cw |
                        ($cw.domain != null and $rule.domain == $cw.domain)
                        or ($cw.domain_suffix != null and $rule.domain_suffix == $cw.domain_suffix)
                    ))
                    or (
                        ($rule.domain // []) | any(. == "connectivitycheck.gstatic.com" or . == "www.gstatic.com")
                    )
                )
            );
        def is_managed_block_rule:
            (.action == "reject" or .outbound == "block") and (.ip_is_private == true or .rule_set == ["geosite-cn", "geoip-cn"]);
        def managed_direct_outbounds($r): [
            {tag:"direct_v6_pref",type:"direct",domain_resolver:{server:$r,strategy:"prefer_ipv6"}},
            {tag:"direct_v4_pref",type:"direct",domain_resolver:{server:$r,strategy:"prefer_ipv4"}},
            {tag:"direct_v4_only",type:"direct",domain_resolver:{server:$r,strategy:"ipv4_only"}},
            {tag:"direct_v6_only",type:"direct",domain_resolver:{server:$r,strategy:"ipv6_only"}}
        ];
        def managed_rule_set_tags: ["geosite-cn", "geoip-cn"];
        def is_managed_rule_set:
            ((.tag // "") as $t | (managed_rule_set_tags | index($t)) != null);
        def managed_cn_rule_sets: [
            {
                tag: "geosite-cn",
                type: "remote",
                format: "binary",
                url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
                http_client: "direct-client"
            },
            {
                tag: "geoip-cn",
                type: "remote",
                format: "binary",
                url: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
                http_client: "direct-client"
            }
        ];
        def is_managed_sniff_rule:
            .action == "sniff" and ((keys - ["action", "timeout", "inbound"]) | length) == 0;
        def managed_sniff_rules($managed_inbounds):
            if ($managed_inbounds | length) > 0 then
                [{action: "sniff", inbound: $managed_inbounds}]
            else
                []
            end;
        def is_managed_http_client:
            ((.tag // "") == "direct-client");
        def managed_http_clients: [
            {tag: "direct-client"}
        ];
        ($proxy_specs | map(
            if .add_resolver then
                .config + {tag: .tag, domain_resolver: {server: $resolver}}
            else
                .config + {tag: .tag}
            end
        )) as $proxy_outbounds
        | ([$node_specs[] | .inbound[]] | unique) as $managed_inbounds
        | (if $block_cn_enabled and ($cached_whitelist | length > 0) then
            [$cached_whitelist[] | select(type == "object")]
          else
            []
          end) as $valid_whitelist
        | ([$node_specs[] | . as $n |
            (
                ($valid_whitelist | map(. + {inbound: $n.inbound, action: (.action // "route"), outbound: $n.outbound}))
                + (if $block_cn_enabled then
                    [
                        {inbound: $n.inbound, ip_is_private: true, action: "reject"},
                        {inbound: $n.inbound, rule_set: ["geosite-cn", "geoip-cn"], action: "reject"}
                    ]
                  else
                    []
                  end)
                + [{inbound: $n.inbound, action: "route", outbound: $n.outbound}]
            )[]
        ]) as $managed_node_rules
        | .dns = (.dns // {})
        | if (($has_direct or (($proxy_outbounds | length) > 0)) and $resolver == "local") then
            .dns.servers = (if (.dns.servers | type) == "array" then .dns.servers else [] end)
            | if any(.dns.servers[]?; .tag == "local") then . else .dns.servers += [{tag:"local",type:"local"}] end
          else . end
        | del(.dns.strategy)
        | .route = (.route // {})
        | .route.final = (.route.final // "direct")
        | if (.route.default_domain_resolver | type) == "object" then
            if ((.route.default_domain_resolver.server // "") | length) > 0 then
                .route.default_domain_resolver = .route.default_domain_resolver.server
            else
                del(.route.default_domain_resolver)
            end
          elif (.route.default_domain_resolver | type) == "string" and ((.route.default_domain_resolver // "") | length) == 0 then
            del(.route.default_domain_resolver)
          else . end
        | if has("http_clients") then
            .http_clients = ((.http_clients // []) | map(select(is_managed_http_client | not)))
          else . end
        | if $block_cn_enabled then
            .http_clients = ((.http_clients // []) + managed_http_clients)
          else
            if has("http_clients") and ((.http_clients | length) == 0) then
                del(.http_clients)
            else . end
          end
        | if (.route | has("rule_set")) then
            .route.rule_set = ((.route.rule_set // []) | map(select(is_managed_rule_set | not)))
          else . end
        | if $block_cn_enabled then
            .route.rule_set = ((.route.rule_set // []) + managed_cn_rule_sets)
          else
            if (.route | has("rule_set")) and ((.route.rule_set | length) == 0) then
                del(.route.rule_set)
            else . end
          end
        | (.route.rules // [] | map(select((((( .outbound // "") as $tag | is_managed_route_tag($tag)) or is_managed_block_rule or is_managed_whitelist_rule($managed_inbounds) or is_managed_sniff_rule) | not)))) as $existing_rules
        | .outbounds = ((.outbounds // []) | map(select((((.tag // "") as $tag | is_managed_outbound_tag($tag)) | not))))
        | if $has_direct then .outbounds += managed_direct_outbounds($resolver) else . end
        | .outbounds += $proxy_outbounds
        | .route.rules = (
            (if any($existing_rules[]; .action == "sniff") then [] else managed_sniff_rules($managed_inbounds) end) as $sniff_rules
            | ([$existing_rules[] | select(is_broad_direct_rule($managed_inbounds))]) as $fallback_rules
            | ([$existing_rules[] | select(is_broad_direct_rule($managed_inbounds) | not)]) as $custom_rules
            | $sniff_rules + $custom_rules + $managed_node_rules + $fallback_rules
          )
    ' "$source_config" >"$output" || {
        rm -f "$output"
        runtime_sync_error="运行时出站配置生成失败"
        return 1
    }
    return 0
}

upgrade_legacy_node_outbound_metadata() {
    local config_dir=${1:-$is_conf_dir} file cfg meta_path meta_tmp
    local -a node_files=() node_cfgs=() meta_files=() meta_unique_files=()
    local -a node_fields=() meta_fields=()
    local -A node_valid_by_file=() node_seen_count=() meta_has_mode=() meta_seen_count=()
    local i batch_nodes_ok=1 batch_metas_ok=1

    [[ -d $config_dir ]] || return 0
    _collect_managed_node_files "$config_dir" "" "" node_files node_cfgs meta_files meta_unique_files
    (( ${#node_files[@]} > 0 )) || return 0

    mapfile -d '' -t node_fields < <(jq -j '
        [input_filename, (if type == "object" and ([.inbounds[]? | .tag? // empty | select(type == "string" and length > 0)] | length > 0) then "1" else "0" end)]
        | .[0], "\u0000", .[1], "\u0000"
    ' "${node_files[@]}" 2>/dev/null)
    wait "$!" || batch_nodes_ok=0
    if (( batch_nodes_ok == 1 )); then
        for ((i = 0; i + 1 < ${#node_fields[@]}; i += 2)); do
            file=${node_fields[i]}
            node_valid_by_file[$file]=${node_fields[i + 1]}
            node_seen_count[$file]=$(( ${node_seen_count[$file]:-0} + 1 ))
        done
    fi

    if (( ${#meta_unique_files[@]} > 0 )); then
        mapfile -d '' -t meta_fields < <(jq -j '
            [input_filename, (if type == "object" and has("outbound_mode") and (.outbound_mode | type == "string" and length > 0) then "1" else "0" end)]
            | .[0], "\u0000", .[1], "\u0000"
        ' "${meta_unique_files[@]}" 2>/dev/null)
        wait "$!" || batch_metas_ok=0
        if (( batch_metas_ok == 1 )); then
            for ((i = 0; i + 1 < ${#meta_fields[@]}; i += 2)); do
                meta_path=${meta_fields[i]}
                meta_has_mode[$meta_path]=${meta_fields[i + 1]}
                meta_seen_count[$meta_path]=$(( ${meta_seen_count[$meta_path]:-0} + 1 ))
            done
        fi
    fi

    for i in "${!node_files[@]}"; do
        file=${node_files[i]}
        cfg=${node_cfgs[i]}
        meta_path=${meta_files[i]}
        if (( batch_nodes_ok == 1 && ${node_seen_count[$file]:-0} == 1 )); then
            [[ ${node_valid_by_file[$file]:-0} == 1 ]] || continue
        else
            jq -e 'type == "object" and ([.inbounds[]? | .tag? // empty | select(type == "string" and length > 0)] | length > 0)' "$file" >/dev/null 2>&1 || continue
        fi
        if [[ ! -f $meta_path ]]; then
            mkdir -p "$config_dir/.quan-meta" &&
                meta_tmp=$(mktemp "$meta_path.tmp.XXXXXX") &&
                printf '{"outbound_mode":"V4优先"}\n' >"$meta_tmp" &&
                mv -f "$meta_tmp" "$meta_path"
        elif (( batch_metas_ok == 1 && ${meta_seen_count[$meta_path]:-0} == 1 )); then
            if [[ ${meta_has_mode[$meta_path]:-0} != 1 ]]; then
                is_conf_dir=$config_dir meta_set_unlocked "$cfg" outbound_mode "V4优先"
            fi
        elif ! jq -e 'has("outbound_mode") and (.outbound_mode | type == "string" and length > 0)' "$meta_path" >/dev/null 2>&1; then
            is_conf_dir=$config_dir meta_set_unlocked "$cfg" outbound_mode "V4优先"
        fi
    done

    return 0
}

sync_runtime_node_outbound_modes_unlocked() {
    local source_config=${1:-$is_config_json} target_config=${2:-$is_config_json} config_dir=${3:-$is_conf_dir} validate=${4:-0} tmp
    runtime_sync_error=
    [[ -f $source_config ]] || return 0
    tmp=$(mktemp "$target_config.tmp.XXXXXX") || {
        runtime_sync_error="无法创建运行时配置临时文件"
        return 1
    }
    if ! render_runtime_node_outbound_modes "$source_config" "$tmp" '' '' "$config_dir"; then
        rm -f "$tmp"
        return 1
    fi
    if [[ $validate == 1 ]] && ! "$is_core_bin" check -c "$tmp" -C "$config_dir" &>/dev/null; then
        rm -f "$tmp"
        runtime_sync_error="完整运行时配置校验失败"
        return 1
    fi
    if ! mv -f "$tmp" "$target_config"; then
        rm -f "$tmp"
        runtime_sync_error="无法保存运行时配置: $target_config"
        return 1
    fi
    upgrade_legacy_node_outbound_metadata "$config_dir"
    return 0
}

sync_runtime_node_outbound_modes() {
    shared_config_lock || {
        runtime_sync_error=${shared_config_error:-无法获取公共配置锁}
        return 1
    }
    sync_runtime_node_outbound_modes_unlocked "$@"
    local status=$?
    shared_config_unlock
    return "$status"
}

migrate_runtime_config() {
    block_cn_clean_all_legacy_inbounds "$is_conf_dir"
    [[ -f $is_config_json ]] || return 0
    sync_runtime_node_outbound_modes "$is_config_json" "$is_config_json" "$is_conf_dir" 1
}

manage_restart_confirmed() {
    local pid
    if [[ $is_systemd ]]; then
        systemctl restart "$is_core" || return 1
        sleep 2
        systemctl is-active --quiet "$is_core" || return 1
        pid=$(systemctl show -p MainPID --value "$is_core" 2>/dev/null) || return 1
        [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
        return 0
    fi
    if [[ $is_openrc ]]; then
        rc-service "$is_core" restart || return 1
        sleep 2
        rc-service "$is_core" status >/dev/null 2>&1 || return 1
        return 0
    fi
    return 1
}

default_runtime_config() {
    local log_path="/var/log/$is_core/access.log" ntp=
    [[ $is_ntp_on ]] && ntp=1
    jq -cn --arg log_path "$log_path" --arg ntp "$ntp" '
        {log:{output:$log_path,level:"info",timestamp:true},dns:{},outbounds:[{tag:"direct",type:"direct"}]}
        + (if $ntp == "1" then {ntp:{enabled:true,server:"time.apple.com"}} else {} end)
    '
}

restore_outbound_apply_file() {
    local backup=$1 target=$2 existed=$3 stage
    if [[ $existed == 1 ]]; then
        [[ -f $backup ]] || return 1
        stage=$(mktemp "$target.restore.XXXXXX") || return 1
        if ! cp -p "$backup" "$stage"; then
            rm -f "$stage"
            return 1
        fi
        if ! mv -f "$stage" "$target"; then
            rm -f "$stage"
            return 1
        fi
    else
        rm -f "$target" || return 1
    fi
}

restore_node_config_lifecycle() {
    local tmp_dir=$1 operation=$2 old_cfg=$3 new_cfg=${4:-} old_meta_exists=$5 old_config_exists=$6
    local old_node="$is_conf_dir/$old_cfg" old_meta new_node new_meta stage
    local -a errors=()
    old_meta=$(meta_file "$old_cfg")
    if ! restore_outbound_apply_file "$tmp_dir/original-old-node" "$old_node" 1; then errors+=("$old_node"); fi
    if [[ $operation == replace && $old_cfg != "$new_cfg" ]]; then
        new_node="$is_conf_dir/$new_cfg"
        new_meta=$(meta_file "$new_cfg")
        if ! restore_outbound_apply_file "$tmp_dir/original-new-node" "$new_node" 0; then errors+=("$new_node"); fi
        rm -f "$new_meta" || errors+=("$new_meta")
    fi
    if [[ $old_meta_exists == 1 ]]; then
        stage=$(mktemp "$old_meta.restore.XXXXXX") && cp -p "$tmp_dir/original-old-meta" "$stage" && mv -f "$stage" "$old_meta" || { rm -f "${stage:-}"; errors+=("$old_meta"); }
    else
        rm -f "$old_meta" || errors+=("$old_meta")
    fi
    if ! restore_outbound_apply_file "$tmp_dir/original-config" "$is_config_json" "$old_config_exists"; then errors+=("$is_config_json"); fi
    node_lifecycle_restore_errors=${errors[*]}
}

prepare_node_config_lifecycle() {
    local operation=$1 old_cfg=$2 new_cfg=${3:-} new_json=${4:-} tmp_dir=$5
    local old_node="$is_conf_dir/$old_cfg" old_meta
    local candidate_nodes candidate_config source_config original_old_node original_old_meta original_config

    node_lifecycle_error=
    candidate_nodes="$tmp_dir/nodes"
    if ! mkdir -p "$candidate_nodes" || ! cp -a "$is_conf_dir/." "$candidate_nodes/"; then
        node_lifecycle_error="无法构造候选节点集合"
        return 1
    fi
    old_meta=$(meta_file "$old_cfg")
    if [[ $operation == delete ]]; then
        rm -f "$candidate_nodes/$old_cfg" "$candidate_nodes/.quan-meta/$old_cfg.meta.json" || {
            node_lifecycle_error="无法构造候选删除节点集合"
            return 1
        }
    else
        if [[ $old_cfg != "$new_cfg" ]]; then
            if ! mv -f "$candidate_nodes/$old_cfg" "$candidate_nodes/$new_cfg"; then
                node_lifecycle_error="无法构造候选节点迁移: $old_cfg -> $new_cfg"
                return 1
            fi
            if [[ -f "$candidate_nodes/.quan-meta/$old_cfg.meta.json" ]]; then
                mkdir -p "$candidate_nodes/.quan-meta" && mv -f "$candidate_nodes/.quan-meta/$old_cfg.meta.json" "$candidate_nodes/.quan-meta/$new_cfg.meta.json" || {
                    node_lifecycle_error="无法构造候选节点元数据迁移: $old_cfg -> $new_cfg"
                    return 1
                }
            fi
        fi
        printf '%s\n' "$new_json" >"$candidate_nodes/$new_cfg" || {
            node_lifecycle_error="无法写入候选节点配置: $new_cfg"
            return 1
        }
    fi

    candidate_config="$tmp_dir/config.json"
    if [[ -f $is_config_json ]]; then
        source_config=$is_config_json
    else
        source_config="$tmp_dir/default-config.json"
        default_runtime_config >"$source_config" || {
            node_lifecycle_error="无法构造默认公共配置"
            return 1
        }
    fi
    if ! render_runtime_node_outbound_modes "$source_config" "$candidate_config" '' '' "$candidate_nodes"; then
        node_lifecycle_error="节点关联配置生成失败: ${runtime_sync_error:-未知错误}"
        return 1
    fi
    if ! "$is_core_bin" check -c "$candidate_config" -C "$candidate_nodes" &>/dev/null; then
        node_lifecycle_error="完整候选节点配置校验失败，原配置未改变: $old_cfg${new_cfg:+ -> $new_cfg}"
        return 1
    fi

    original_old_node="$tmp_dir/original-old-node"
    original_old_meta="$tmp_dir/original-old-meta"
    original_config="$tmp_dir/original-config"
    cp -p "$old_node" "$original_old_node" || {
        node_lifecycle_error="无法备份节点配置: $old_node"
        return 1
    }
    if [[ -f $old_meta ]]; then
        cp -p "$old_meta" "$original_old_meta" || {
            node_lifecycle_error="无法备份节点元数据: $old_meta"
            return 1
        }
    fi
    if [[ -f $is_config_json ]]; then
        cp -p "$is_config_json" "$original_config" || {
            node_lifecycle_error="无法备份公共配置: $is_config_json"
            return 1
        }
    fi
}

apply_node_config_lifecycle_files() {
    local operation=$1 old_cfg=$2 new_cfg=${3:-} tmp_dir=$4
    local old_node="$is_conf_dir/$old_cfg" new_node="$is_conf_dir/$new_cfg" old_meta new_meta
    local candidate_nodes="$tmp_dir/nodes" candidate_config="$tmp_dir/config.json" stage old_config_exists=0
    node_lifecycle_error=
    node_lifecycle_restart_needed=0
    old_meta=$(meta_file "$old_cfg")
    new_meta=$(meta_file "$new_cfg")
    [[ -f "$tmp_dir/original-config" ]] && old_config_exists=1

    if [[ $operation == replace ]]; then
        stage=$(mktemp "$new_node.lifecycle.XXXXXX") || node_lifecycle_error="无法准备节点配置保存: $new_node"
        if [[ ! $node_lifecycle_error ]] && { ! cp -p "$candidate_nodes/$new_cfg" "$stage" || ! mv -f "$stage" "$new_node"; }; then
            rm -f "$stage"
            node_lifecycle_error="保存节点配置失败: $new_node"
        fi
        if [[ ! $node_lifecycle_error && $old_cfg != "$new_cfg" ]]; then
            if [[ -f $old_meta ]] && ! meta_move "$old_cfg" "$new_cfg"; then
                node_lifecycle_error="迁移节点元数据失败: $old_meta -> $new_meta"
            elif ! rm -f "$old_node"; then
                node_lifecycle_error="移除旧节点配置失败: $old_node"
            fi
        fi
    else
        rm -f "$old_node" || node_lifecycle_error="删除节点配置失败: $old_node"
        if [[ ! $node_lifecycle_error && -f $old_meta ]] && ! meta_rm "$old_cfg"; then
            node_lifecycle_error="删除节点元数据失败: $old_meta"
        fi
    fi
    if [[ ! $node_lifecycle_error && ( $old_config_exists == 1 || $operation == replace ) ]]; then
        stage=$(mktemp "$is_config_json.lifecycle.XXXXXX") || node_lifecycle_error="无法准备公共配置保存: $is_config_json"
        if [[ ! $node_lifecycle_error ]] && { ! cp -p "$candidate_config" "$stage" || ! mv -f "$stage" "$is_config_json"; }; then
            rm -f "$stage"
            node_lifecycle_error="保存公共配置失败: $is_config_json"
        fi
        [[ ! $node_lifecycle_error ]] && node_lifecycle_restart_needed=1
    fi
    [[ ! $node_lifecycle_error ]]
}

apply_node_config_lifecycle_unlocked() {
    local operation=$1 old_cfg=$2 new_cfg=${3:-} new_json=${4:-}
    local old_node="$is_conf_dir/$old_cfg" tmp_dir tmp_parent old_meta_exists=0 old_config_exists=0
    node_lifecycle_error=
    node_lifecycle_restore_errors=
    node_lifecycle_restart_needed=0
    [[ $operation == delete || $operation == replace ]] || {
        node_lifecycle_error="不支持的节点操作: $operation"
        return 1
    }
    [[ -f $old_node ]] || {
        node_lifecycle_error="本机节点配置不存在: $old_node"
        return 1
    }
    if [[ $operation == replace ]]; then
        local new_node="$is_conf_dir/$new_cfg" new_meta
        new_meta=$(meta_file "$new_cfg")
        [[ $new_cfg && $new_json ]] && jq -e 'type == "object" and (.inbounds | type == "array")' <<<"$new_json" >/dev/null 2>&1 || {
            node_lifecycle_error="候选本机节点配置无效: $new_cfg"
            return 1
        }
        if [[ $old_cfg != "$new_cfg" && ( -e $new_node || -e $new_meta ) ]]; then
            node_lifecycle_error="目标节点配置或元数据已存在: $new_cfg"
            return 1
        fi
    fi
    tmp_parent=$(dirname "$is_conf_dir")
    tmp_dir=$(mktemp -d "$tmp_parent/.node-lifecycle.XXXXXX") || {
        node_lifecycle_error="无法创建节点变更临时目录: $tmp_parent"
        return 1
    }
    if ! prepare_node_config_lifecycle "$operation" "$old_cfg" "$new_cfg" "$new_json" "$tmp_dir"; then
        rm -rf "$tmp_dir"
        return 1
    fi
    [[ -f "$tmp_dir/original-old-meta" ]] && old_meta_exists=1
    [[ -f "$tmp_dir/original-config" ]] && old_config_exists=1
    if ! apply_node_config_lifecycle_files "$operation" "$old_cfg" "$new_cfg" "$tmp_dir"; then
        restore_node_config_lifecycle "$tmp_dir" "$operation" "$old_cfg" "$new_cfg" "$old_meta_exists" "$old_config_exists"
        [[ $node_lifecycle_restore_errors ]] && node_lifecycle_error+="；恢复文件失败: $node_lifecycle_restore_errors"
        rm -rf "$tmp_dir"
        return 1
    fi
    if [[ $node_lifecycle_restart_needed == 1 ]] && ! manage_restart_confirmed; then
        restore_node_config_lifecycle "$tmp_dir" "$operation" "$old_cfg" "$new_cfg" "$old_meta_exists" "$old_config_exists"
        if manage_restart_confirmed; then
            if [[ $node_lifecycle_restore_errors ]]; then
                node_lifecycle_error="节点变更重启失败，文件恢复失败: $node_lifecycle_restore_errors；原配置恢复重启已完成"
            else
                node_lifecycle_error="节点变更重启失败，已恢复原配置并恢复服务"
            fi
        elif [[ $node_lifecycle_restore_errors ]]; then
            node_lifecycle_error="节点变更重启失败，文件恢复和恢复重启均失败: $node_lifecycle_restore_errors"
        else
            node_lifecycle_error="节点变更重启失败，原配置已恢复但服务恢复失败"
        fi
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"
    return 0
}

apply_node_config_lifecycle() {
    shared_config_lock || {
        node_lifecycle_error=${shared_config_error:-无法获取公共配置锁}
        return 1
    }
    apply_node_config_lifecycle_unlocked "$@"
    local status=$?
    shared_config_unlock
    return "$status"
}

apply_node_outbound_mode_unlocked() {
    local cfg=$1 mode=$2 proxy_config=${3:-} proxy_name=${4:-}
    local node_file="$is_conf_dir/$cfg" metadata_file tmp_parent tmp_dir
    local source_config candidate_meta candidate_config original_meta original_config
    local candidate_meta_json proxy_json config_type method password
    local check_error
    local meta_install config_install old_meta_exists=0 old_config_exists=0
    local restore_errors=()
    outbound_apply_error=
    case $mode in
    "V6优先" | "V4优先" | "仅V4" | "仅V6") ;;
    "SS 出站" | "VLESS 出站") ;;
    *)
        outbound_apply_error="不支持的出站方式: $mode"
        return 1
        ;;
    esac
    [[ -f $node_file ]] || {
        outbound_apply_error="本机节点配置不存在: $node_file"
        return 1
    }
    jq -e 'type == "object" and (.inbounds | type == "array")' "$node_file" >/dev/null 2>&1 || {
        outbound_apply_error="本机节点配置格式无效: $node_file"
        return 1
    }
    metadata_file=$(meta_file "$cfg")
    if [[ -f $metadata_file ]]; then
        jq -e 'type == "object"' "$metadata_file" >/dev/null 2>&1 || {
            outbound_apply_error="节点元数据格式无效: $metadata_file"
            return 1
        }
    fi
    if [[ $proxy_config && ($mode == 'SS 出站' || $mode == 'VLESS 出站') ]]; then
        proxy_json=
    else
        outbound_proxy_from_metadata "$cfg" "$metadata_file" || {
            outbound_apply_error="当前代理缓存无效，未更改运行配置: $metadata_file"
            return 1
        }
        proxy_json=$outbound_proxy_json
    fi
    if [[ $mode == 'SS 出站' || $mode == 'VLESS 出站' ]]; then
        if [[ $proxy_config ]]; then
            config_type=$(jq -r '.type // empty' <<<"$proxy_config" 2>/dev/null)
            if [[ $mode == 'SS 出站' ]]; then
                [[ $config_type == shadowsocks ]] || {
                    outbound_apply_error="SS 出站需要 Shadowsocks 连接参数"
                    return 1
                }
                jq -e '
                    type == "object"
                    and (.server | type == "string" and length > 0)
                    and (.server_port | type == "number" and . >= 1 and . <= 65535 and floor == .)
                    and (.method | type == "string" and length > 0)
                    and (.password | type == "string" and length > 0)
                    and ((has("tag") or has("detour")) | not)
                ' <<<"$proxy_config" >/dev/null 2>&1 || {
                    outbound_apply_error="SS 出站参数无效"
                    return 1
                }
                method=$(jq -r '.method' <<<"$proxy_config")
                password=$(jq -r '.password' <<<"$proxy_config")
                ss_method_supported "$method" && ss_password_valid_for_method "$method" "$password" || {
                    outbound_apply_error="SS 加密方式或密钥无效"
                    return 1
                }
            else
                jq -e '
                    type == "object"
                    and .type == "vless"
                    and (.server | type == "string" and length > 0)
                    and (.server_port | type == "number" and . >= 1 and . <= 65535 and floor == .)
                    and (.uuid | type == "string" and length > 0)
                    and ((has("tag") or has("detour")) | not)
                ' <<<"$proxy_config" >/dev/null 2>&1 || {
                    outbound_apply_error="VLESS 出站参数无效"
                    return 1
                }
            fi
            proxy_json=$(jq -cn --arg name "$proxy_name" --argjson config "$proxy_config" '{name:$name,config:$config}') || {
                outbound_apply_error="无法构造代理缓存"
                return 1
            }
        else
            [[ $proxy_json ]] || {
                outbound_apply_error="没有可复用的代理缓存"
                return 1
            }
            config_type=$(jq -r '.config.type // empty' <<<"$proxy_json")
            [[ ($mode == 'SS 出站' && $config_type == shadowsocks) || ($mode == 'VLESS 出站' && $config_type == vless) ]] || {
                outbound_apply_error="当前代理缓存与所选出站方式不匹配"
                return 1
            }
        fi
    fi

    tmp_parent=$(dirname "$is_config_json")
    tmp_dir=$(mktemp -d "$tmp_parent/.outbound-apply.XXXXXX") || {
        outbound_apply_error="无法创建候选配置目录: $tmp_parent"
        return 1
    }
    source_config="$tmp_dir/config-source.json"
    candidate_meta="$tmp_dir/metadata-candidate.json"
    candidate_config="$tmp_dir/config-candidate.json"
    original_meta="$tmp_dir/metadata-original"
    original_config="$tmp_dir/config-original"
    if [[ -f $metadata_file ]]; then
        cp -p "$metadata_file" "$original_meta" || {
            outbound_apply_error="无法备份节点元数据: $metadata_file"
            rm -rf "$tmp_dir"
            return 1
        }
        old_meta_exists=1
        candidate_meta_json=$(jq -c --arg mode "$mode" --argjson proxy "${proxy_json:-null}" '
            .outbound_mode = $mode
            | if $proxy == null then . else .outbound_proxy = $proxy | del(.outbound_ss_server,.outbound_ss_port,.outbound_ss_method,.outbound_ss_password,.outbound_ss_name) end
        ' "$metadata_file" 2>/dev/null) || {
            outbound_apply_error="无法构造节点元数据: $metadata_file"
            rm -rf "$tmp_dir"
            return 1
        }
    else
        candidate_meta_json=$(jq -cn --arg mode "$mode" --argjson proxy "${proxy_json:-null}" '
            {outbound_mode:$mode}
            | if $proxy == null then . else .outbound_proxy = $proxy end
        ') || {
            outbound_apply_error="无法构造节点元数据"
            rm -rf "$tmp_dir"
            return 1
        }
    fi
    if ! printf '%s\n' "$candidate_meta_json" >"$candidate_meta"; then
        outbound_apply_error="无法写入候选节点元数据"
        rm -rf "$tmp_dir"
        return 1
    fi
    if [[ -f $is_config_json ]]; then
        cp -p "$is_config_json" "$original_config" || {
            outbound_apply_error="无法备份公共配置: $is_config_json"
            rm -rf "$tmp_dir"
            return 1
        }
        old_config_exists=1
        cp -p "$is_config_json" "$source_config" || {
            outbound_apply_error="无法读取公共配置: $is_config_json"
            rm -rf "$tmp_dir"
            return 1
        }
    else
        default_runtime_config >"$source_config" || {
            outbound_apply_error="无法构造默认公共配置"
            rm -rf "$tmp_dir"
            return 1
        }
    fi
    if ! render_runtime_node_outbound_modes "$source_config" "$candidate_config" "$cfg" "$candidate_meta"; then
        outbound_apply_error="完整配置生成失败: ${runtime_sync_error:-未知错误}"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! "$is_core_bin" check -c "$candidate_config" -C "$is_conf_dir" >"$tmp_dir/check.log" 2>&1; then
        outbound_apply_error="完整配置校验失败，原配置未改变"
        check_error=$(sed -n '/[^[:space:]]/{s/\\/\\\\/g;s/[[:cntrl:]]//g;p;}' "$tmp_dir/check.log")
        [[ ! $check_error ]] || outbound_apply_error+="：$check_error"
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p "$(dirname "$metadata_file")" || {
        outbound_apply_error="无法创建节点元数据目录: $(dirname "$metadata_file")"
        rm -rf "$tmp_dir"
        return 1
    }
    meta_install=$(mktemp "$metadata_file.apply.XXXXXX") || {
        outbound_apply_error="无法准备节点元数据保存: $metadata_file"
        rm -rf "$tmp_dir"
        return 1
    }
    config_install=$(mktemp "$is_config_json.apply.XXXXXX") || {
        outbound_apply_error="无法准备公共配置保存: $is_config_json"
        rm -f "$meta_install"
        rm -rf "$tmp_dir"
        return 1
    }
    if ! cp "$candidate_meta" "$meta_install" || ! cp "$candidate_config" "$config_install" || ! chmod 600 "$meta_install" "$config_install"; then
        outbound_apply_error="无法暂存候选配置文件"
        rm -f "$meta_install" "$config_install"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! mv -f "$meta_install" "$metadata_file"; then
        outbound_apply_error="保存节点元数据失败: $metadata_file"
        rm -f "$meta_install" "$config_install"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! mv -f "$config_install" "$is_config_json"; then
        outbound_apply_error="保存公共配置失败: $is_config_json"
        if ! restore_outbound_apply_file "$original_meta" "$metadata_file" "$old_meta_exists"; then
            outbound_apply_error+="；恢复节点元数据失败: $metadata_file"
        fi
        rm -f "$meta_install" "$config_install"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! manage_restart_confirmed; then
        if ! restore_outbound_apply_file "$original_meta" "$metadata_file" "$old_meta_exists"; then
            restore_errors+=("$metadata_file")
        fi
        if ! restore_outbound_apply_file "$original_config" "$is_config_json" "$old_config_exists"; then
            restore_errors+=("$is_config_json")
        fi
        if manage_restart_confirmed; then
            if ((${#restore_errors[@]})); then
                outbound_apply_error="重启失败且文件恢复失败: ${restore_errors[*]}；原配置恢复重启已完成"
            else
                outbound_apply_error="重启失败，已恢复原配置并恢复服务"
            fi
        else
            if ((${#restore_errors[@]})); then
                outbound_apply_error="重启失败且文件恢复失败: ${restore_errors[*]}；原配置恢复重启也失败"
            else
                outbound_apply_error="重启失败，原配置已恢复但服务恢复失败"
            fi
        fi
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"
    return 0
}

apply_node_outbound_mode() {
    shared_config_lock || {
        outbound_apply_error=${shared_config_error:-无法获取公共配置锁}
        return 1
    }
    apply_node_outbound_mode_unlocked "$@"
    local status=$?
    shared_config_unlock
    return "$status"
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

sync_entry_addr_config_unlocked() {
    local cfg=$1
    local entry=$2
    local file="$is_conf_dir/$cfg"
    local listen_addr new_json normalized_entry

    [[ -f "$file" ]] || err "配置文件不存在: $cfg"

    normalized_entry=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$entry")
    if [[ ! $normalized_entry ]] || ! is_valid_entry_addr "$normalized_entry"; then
        normalized_entry=$(get_public_entry_addr)
    fi

    if jq -e '.inbounds[0].transport.headers.host? != null' "$file" >/dev/null 2>&1; then
        new_json=$(jq --arg addr "$normalized_entry" '.inbounds[0].transport.headers.host = $addr' "$file") || return 1
    else
        listen_addr=$(resolve_entry_addr_for_listen "$normalized_entry") || listen_addr=$(get_public_entry_addr)
        new_json=$(jq --arg addr "$listen_addr" '.inbounds[0].listen = $addr' "$file") || return 1
    fi

    apply_node_config_lifecycle_unlocked replace "$cfg" "$cfg" "$new_json" || {
        echo "$node_lifecycle_error"
        return 1
    }
    meta_set "$cfg" entry_addr "$normalized_entry" || {
        echo "节点配置已应用，但无法保存分享地址"
        return 1
    }
    echo "$normalized_entry"
}

sync_entry_addr_config() {
    shared_config_lock || err "${shared_config_error:-无法获取公共配置锁}"
    sync_entry_addr_config_unlocked "$@"
    local status=$?
    shared_config_unlock
    return "$status"
}
