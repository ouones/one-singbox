# Port forwarding (relay) helpers.

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
    [[ $local_port ]] || err "监听端口不能为空."
    relay_cfg="relay-${local_port}.json"
    relay_file="$is_conf_dir/$relay_cfg"
    [[ -f $relay_file ]] || err "未找到端口转发配置 ($relay_cfg)."

    note_apply_cli "$relay_cfg" "${@:2}"
}
