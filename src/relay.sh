# Port forwarding (relay) helpers.

relay_warn_security() {
    warn "端口转发没有身份验证。请在系统防火墙或云安全组中限制可访问此监听端口的来源。"
}

relay_info_show() {
    local l_port=$1 r_addr=$2 r_port=$3 r_note=
    r_note=$(note_get "relay-${l_port}.json")
    msg "类型: TCP/UDP 端口转发"
    msg "监听地址: ::"
    msg "监听端口: $l_port"
    msg "目标地址: $r_addr"
    msg "目标端口: $r_port"
    if [[ $r_note ]]; then
        printf '备注: %s\n' "$r_note"
    fi
}

relay_add() {
    local local_port=${1-} remote_addr=${2-} remote_port=${3-} relay_note= interactive_add=0 raw_note=
    if (($# >= 4)); then
        local IFS=' '
        relay_note=$(note_trim "${*:4}")
    fi
    if [[ ! $local_port ]]; then
        interactive_add=1
        while :; do
            get_port
            local_port=$tmp_port
            config_port_used "$local_port" || break
        done
        local auto_port=$local_port
        is_default_arg=$auto_port
        ask string local_port "输入监听端口 (1-65535，回车自动分配 $local_port):"
        [[ -z "$REPLY" ]] && msg "自动分配本地端口: $local_port"
    fi
    local_port=$(echo "$local_port" | tr -d ' ')
    [[ $(is_test port "$local_port") ]] || { err "($local_port) 不是一个有效的端口."; return 1; }
    [[ $(is_test port_used "$local_port") ]] && { err "本地端口 ($local_port) 已被占用."; return 1; }
    config_port_used "$local_port" && { err "本地端口 ($local_port) 已被现有配置占用."; return 1; }

    if [[ ! $remote_addr ]]; then
        interactive_add=1
        ask string remote_addr "输入目标地址 (IPv4、IPv6 或域名):"
    fi
    remote_addr=$(echo "$remote_addr" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [[ -n $remote_addr ]] || { err "目标地址不能为空."; return 1; }

    if [[ ! $remote_port ]]; then
        interactive_add=1
        ask string remote_port "输入目标端口 (1-65535):"
    fi
    remote_port=$(echo "$remote_port" | tr -d ' ')
    [[ $(is_test port "$remote_port") ]] || { err "($remote_port) 不是一个有效的目标端口."; return 1; }

    if ((interactive_add == 1 && $# < 4)); then
        echo -ne "输入备注 (可选，直接回车跳过):"
        if note_read_line raw_note; then
            relay_note=$(note_trim "$raw_note")
        fi
    fi

    local relay_file="$is_conf_dir/relay-${local_port}.json"
    local tmp_file
    shared_config_lock || { err "${shared_config_error:-无法获取公共配置锁}"; return 1; }
    [[ $(is_test port_used "$local_port") ]] && { shared_config_unlock; err "本地端口 ($local_port) 已被占用."; return 1; }
    config_port_used "$local_port" && { shared_config_unlock; err "本地端口 ($local_port) 已被现有配置占用."; return 1; }
    tmp_file=$(mktemp "$is_conf_dir/.relay-XXXXXX") || { shared_config_unlock; err "无法创建端口转发临时配置文件."; return 1; }

    local relay_inbound
    relay_inbound=$(jq -n \
        --arg tag "relay-${local_port}.json" \
        --arg addr "$remote_addr" \
        --argjson local_port "$local_port" \
        --argjson remote_port "$remote_port" \
        '{inbounds:[{tag:$tag,type:"direct",listen:"::",listen_port:$local_port,override_address:$addr,override_port:$remote_port}]}') || {
        rm -f "$tmp_file"
        shared_config_unlock
        err "生成端口转发配置 JSON 失败."
        return 1
    }
    printf '%s\n' "$relay_inbound" > "$tmp_file"

    if ! "$is_core_bin" check -c "$tmp_file" &>/dev/null; then
        rm -f "$tmp_file"
        shared_config_unlock
        err "端口转发配置校验失败."
        return 1
    fi

    if ! mv -f "$tmp_file" "$relay_file"; then
        rm -f "$tmp_file"
        shared_config_unlock
        err "保存端口转发配置文件失败."
        return 1
    fi

    if [[ -f $is_config_json ]]; then
        if ! "$is_core_bin" check -c "$is_config_json" -C "$is_conf_dir" &>/dev/null; then
            rm -f "$relay_file"
            shared_config_unlock
            err "完整运行时配置校验失败，已取消安装该端口转发配置."
            return 1
        fi
    fi

    shared_config_unlock
    if [[ $relay_note ]]; then
        note_set "relay-${local_port}.json" "$relay_note" || { err "保存备注失败."; return 1; }
    fi
    manage_restart_checked "" "端口转发配置已保存" || return 1
    msg "\n$(_green '端口转发配置添加成功!')"
    msg "------------------------------------------------"
    relay_info_show "$local_port" "$remote_addr" "$remote_port"
    msg "------------------------------------------------"
    relay_warn_security
}

relay_info() {
    local local_port=${1-}
    if [[ ! $local_port ]]; then
        if ! relay_menu_has_entries; then
            relay_list
            return 1
        fi
        local file l_port r_addr r_port cfg_name base_label choice_status
        local -a files=() ports=() labels=()
        shopt -s nullglob
        files=("$is_conf_dir"/relay-*.json)
        shopt -u nullglob
        for file in "${files[@]}"; do
            l_port=$(jq -r '.inbounds[0].listen_port // empty' "$file")
            r_addr=$(jq -r '.inbounds[0].override_address // empty' "$file")
            r_port=$(jq -r '.inbounds[0].override_port // empty' "$file")
            cfg_name=${file##*/}
            [[ $l_port ]] || l_port=${cfg_name#relay-}
            l_port=${l_port%.json}
            ports+=("$l_port")
            base_label="监听端口 $l_port -> 目标 $r_addr:$r_port (TCP/UDP)"
            labels+=("$(note_format_list_label "$cfg_name" "$base_label")")
        done
        menu_select parent local_port "\n请选择要查看的端口转发:\n" "${labels[@]}"
        choice_status=$?
        [[ $choice_status == 2 ]] && return 0
        [[ $choice_status == 0 ]] || return 1
        local_port=${ports[REPLY - 1]}
    fi
    local_port=${local_port#relay-}
    local_port=${local_port%.json}
    local relay_file="$is_conf_dir/relay-${local_port}.json"
    [[ -f $relay_file ]] || { err "未找到端口转发配置 (relay-${local_port}.json)."; return 1; }
    local r_addr r_port
    r_addr=$(jq -r '.inbounds[0].override_address // empty' "$relay_file")
    r_port=$(jq -r '.inbounds[0].override_port // empty' "$relay_file")
    msg "\n------------- 端口转发配置信息 -------------"
    relay_info_show "$local_port" "$r_addr" "$r_port"
    msg "----------------------------------------"
    relay_warn_security
}

relay_list() {
    local files count=0 file l_port r_addr r_port cfg_name base_label
    shopt -s nullglob
    files=("$is_conf_dir"/relay-*.json)
    shopt -u nullglob
    if [[ ${#files[@]} -eq 0 ]]; then
        if [[ $is_main_start ]]; then
            msg "\n暂无端口转发，请先添加\n"
        else
            msg "\n当前未配置任何端口转发.\n"
        fi
        return
    fi
    msg "\n------------- 端口转发列表 -------------"
    for file in "${files[@]}"; do
        l_port=$(jq -r '.inbounds[0].listen_port // empty' "$file")
        r_addr=$(jq -r '.inbounds[0].override_address // empty' "$file")
        r_port=$(jq -r '.inbounds[0].override_port // empty' "$file")
        cfg_name=${file##*/}
        base_label="监听端口 $l_port -> 目标 $r_addr:$r_port (TCP/UDP)"
        printf '%s\n' "$(note_format_list_label "$cfg_name" "$base_label")"
        ((count++))
    done
    msg "------------------------------------"
    msg "共 $count 个端口转发"
    relay_warn_security
}

relay_delete() {
    local local_port=$1 relay_file backup_file remote_addr remote_port
    if [[ ! $local_port ]]; then
        relay_list
        # Existing relays may be listening; only validate the port format here.
        local is_cant_test_port=1
        ask string local_port "输入要删除的监听端口:"
    fi
    local_port=${local_port#relay-}
    local_port=${local_port%.json}
    relay_file="$is_conf_dir/relay-${local_port}.json"
    [[ -f $relay_file ]] || { err "未找到端口转发配置 (relay-${local_port}.json)."; return 1; }
    if [[ $is_main_start ]]; then
        remote_addr=$(jq -r '.inbounds[0].override_address // empty' "$relay_file")
        remote_port=$(jq -r '.inbounds[0].override_port // empty' "$relay_file")
        confirm_action "将删除监听端口 $local_port → $remote_addr:$remote_port 的端口转发；删除范围包括配置文件 $relay_file 和运行时转发规则，不影响其他端口转发，删除后将重启 sing-box。确认删除" || { msg "已取消删除端口转发。"; return; }
    fi
    shared_config_lock || { err "${shared_config_error:-无法获取公共配置锁}"; return 1; }
    backup_file="$is_conf_dir/.relay-${local_port}.json.bak"
    mv -f "$relay_file" "$backup_file" || { shared_config_unlock; err "备份端口转发配置失败，未执行删除."; return 1; }
    if [[ -f $is_config_json ]]; then
        if ! "$is_core_bin" check -c "$is_config_json" -C "$is_conf_dir" &>/dev/null; then
            mv -f "$backup_file" "$relay_file"
            shared_config_unlock
            err "删除端口转发后完整运行时配置校验失败，已恢复端口转发配置."
            return 1
        fi
    fi
    rm -f "$backup_file"
    if [[ -f $(meta_file "relay-${local_port}.json") ]]; then
        meta_rm_unlocked "relay-${local_port}.json" || {
            shared_config_unlock
            err "删除端口转发元数据失败: relay-${local_port}.json"
            return 1
        }
    fi
    [[ -f $is_config_json ]] && sync_runtime_node_outbound_modes || {
        if [[ -f $is_config_json ]]; then
            shared_config_unlock
            err "节点代理路由同步失败: ${runtime_sync_error:-未知错误}"
            return 1
        fi
    }
    shared_config_unlock
    manage_restart_checked "" "已删除端口转发配置 relay-${local_port}.json" || return 1
    _green "\n已删除端口转发配置: relay-${local_port}.json\n"
}

relay_note() {
    local local_port=${1-} relay_cfg relay_file
    if [[ ! $local_port ]]; then
        if ! relay_menu_has_entries; then
            relay_list
            return 1
        fi
        relay_list
        # Existing relays may be listening; only validate the port format here.
        local is_cant_test_port=1
        ask string local_port "输入要编辑备注的监听端口:"
    fi
    local_port=$(printf '%s' "$local_port" | tr -d '[:space:]')
    local_port=${local_port#relay-}
    local_port=${local_port%.json}
    [[ $local_port ]] || { err "监听端口不能为空."; return 1; }
    relay_cfg="relay-${local_port}.json"
    relay_file="$is_conf_dir/$relay_cfg"
    [[ -f $relay_file ]] || { err "未找到端口转发配置 ($relay_cfg)."; return 1; }

    note_apply_cli "$relay_cfg" "${@:2}"
}

relay_menu_has_entries() {
    local files
    shopt -s nullglob
    files=("$is_conf_dir"/relay-*.json)
    shopt -u nullglob
    ((${#files[@]} > 0))
}

relay_menu_empty_state() {
    relay_menu_has_entries && return 1
    relay_list
    menu_pause
    return 0
}

relay_menu() {
    local choice_status
    while :; do
        menu_select parent is_relay_action "\n请选择端口转发操作:\n" "添加" "查看" "备注" "删除"
        choice_status=$?
        [[ $choice_status == 2 ]] && return
        [[ $choice_status == 0 ]] || return 1
        case $REPLY in
        1)
            menu_action relay_add
            ;;
        2)
            menu_action relay_list
            ;;
        3)
            relay_menu_empty_state && continue
            menu_action relay_note
            ;;
        4)
            relay_menu_empty_state && continue
            menu_action relay_delete
            ;;
        esac
    done
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
    note)
        relay_note "${@:2}"
        ;;
    del | delete | rm)
        relay_delete "${@:2}"
        ;;
    "")
        relay_menu
        ;;
    *)
        err "无法识别端口转发命令 ($1), 正确用法: $is_core relay [add|list|info|note|delete]"
        return 1
        ;;
    esac
}
