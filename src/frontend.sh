#!/usr/bin/env bash

frontend_emit_json() {
    local ok=$1 enabled=$2 revision=$3 phase=$4 nginx=$5 bindings=$6 errors=$7
    jq -cn \
        --argjson ok "$ok" \
        --argjson enabled "$enabled" \
        --argjson revision "$revision" \
        --arg phase "$phase" \
        --argjson nginx "$nginx" \
        --argjson bindings "$bindings" \
        --argjson errors "$errors" \
        '{ok:$ok,enabled:$enabled,revision:$revision,phase:$phase,nginx:$nginx,bindings:$bindings,errors:$errors}'
}

frontend_no_profile_status() {
    local json=$1 phase=${2:-idle} errors=${3:-'[]'} ok=true
    [[ $errors == '[]' ]] || ok=false
    if [[ $json == --json ]]; then
        frontend_emit_json "$ok" false 0 "$phase" null '[]' "$errors"
    else
        printf '443 SNI 前置：未启用\nrevision：0\n本机检查：未执行（前置未启用）\n'
        [[ $errors == '[]' ]] || jq -r '.[0].message' <<<"$errors" >&2
    fi
    [[ $errors == '[]' ]]
}

frontend_load_profile() {
    local profile_file="$is_core_dir/frontend.json"
    frontend_profile=
    frontend_profile_error_code=
    frontend_profile_error_message=

    if [[ ! -e $profile_file && ! -L $profile_file ]]; then
        return 0
    fi
    if [[ -L $profile_file || ! -f $profile_file ]]; then
        frontend_profile_error_code=invalid_profile
        frontend_profile_error_message=$(frontend_localize_error_message "$frontend_profile_error_code" 'frontend.json 必须是普通文件，不能是符号链接。')
        return 1
    fi
    if ! jq -e . "$profile_file" >/dev/null 2>&1; then
        frontend_profile_error_code=invalid_profile
        frontend_profile_error_message=$(frontend_localize_error_message "$frontend_profile_error_code" 'frontend.json 不是有效的 JSON。')
        return 1
    fi
    if [[ $(jq -r '.schema_version // empty' "$profile_file") != 1 ]]; then
        frontend_profile_error_code=unsupported_schema
        frontend_profile_error_message=$(frontend_localize_error_message "$frontend_profile_error_code" 'frontend.json 使用了不受支持的 schema_version。')
        return 1
    fi
    if ! jq -e '
        type == "object" and
        (.enabled | type == "boolean") and
        (.revision | type == "number" and floor == . and . >= 0) and
        .engine == "nginx" and
        (.listen_addresses | type == "array" and all(.[]; type == "string")) and
        (.bindings | type == "array" and all(.[];
            type == "object" and
            (.node_ref | type == "string" and test("^[A-Za-z0-9_.-]+\\.json$")) and
            .public_port == 443 and
            .backend_host == "127.0.0.1" and
            (.backend_port | type == "number" and floor == . and . >= 1024 and . <= 65535)
        )) and
        (.nginx | type == "object") and
        (.ownership | type == "object")
    ' "$profile_file" >/dev/null 2>&1; then
        frontend_profile_error_code=invalid_profile
        frontend_profile_error_message=$(frontend_localize_error_message "$frontend_profile_error_code" 'frontend.json 不符合 schema_version 1 的结构。')
        return 1
    fi
    frontend_profile=$(jq -c . "$profile_file") || {
        frontend_profile_error_code=invalid_profile
        frontend_profile_error_message=$(frontend_localize_error_message "$frontend_profile_error_code" '无法读取 frontend.json。')
        return 1
    }
    return 0
}

frontend_read_phase() {
    local transaction_file="$is_core_dir/.frontend-state/transaction.json"
    frontend_phase=idle
    frontend_phase_error_code=
    frontend_phase_error_message=
    if [[ ! -e $transaction_file && ! -L $transaction_file ]]; then
        return 0
    fi
    if [[ -L $transaction_file || ! -f $transaction_file ]] || ! jq -e '.phase | type == "string"' "$transaction_file" >/dev/null 2>&1; then
        frontend_phase_error_code=transaction_corrupt
        frontend_phase_error_message=$(frontend_localize_error_message "$frontend_phase_error_code" '已保存的前置事务记录缺失或无效。')
        frontend_phase=recovery_required
        return 1
    fi
    frontend_phase=$(jq -r '.phase' "$transaction_file")
    case $frontend_phase in
    prepared | backend_applied | frontend_applied | verified | committed | rolling_back | rolled_back | recovery_required) ;;
    *)
        frontend_phase_error_code=transaction_corrupt
        frontend_phase_error_message=$(frontend_localize_error_message "$frontend_phase_error_code" "已保存的前置事务包含未知阶段：$frontend_phase")
        frontend_phase=recovery_required
        return 1
        ;;
    esac
    return 0
}

frontend_status() {
    local json=${1:-} enabled revision nginx bindings errors phase=idle detection_attempted=0
    if ! frontend_load_profile; then
        errors=$(jq -cn --arg code "$frontend_profile_error_code" --arg message "$frontend_profile_error_message" '[{code:$code,message:$message}]')
        if [[ $json == --json ]]; then
            frontend_emit_json false null 0 "$phase" null '[]' "$errors"
        else
            printf '443 SNI 前置：状态不可用（%s）\n' "$frontend_profile_error_message" >&2
        fi
        return 1
    fi
    if [[ ! $frontend_profile ]]; then
        if ! frontend_read_phase; then
            errors=$(jq -cn --arg code "$frontend_phase_error_code" --arg message "$frontend_phase_error_message" '[{code:$code,message:$message}]')
        else
            phase=$frontend_phase
            case $phase in
            prepared | backend_applied | frontend_applied | verified | rolling_back | recovery_required)
                errors=$(jq -cn --arg phase "$phase" '[{code:"recovery_required",message:("前置事务未完成，当前阶段：" + $phase + "。继续更改前请先运行 frontend recover。")}]')
                ;;
            *) errors='[]' ;;
            esac
        fi
        frontend_no_profile_status "$json" "$phase" "$errors"
        return $?
    fi

    if ! frontend_read_phase; then
        errors=$(jq -cn --arg code "$frontend_phase_error_code" --arg message "$frontend_phase_error_message" '[{code:$code,message:$message}]')
    else
        phase=$frontend_phase
        errors='[]'
        case $phase in
        prepared | backend_applied | frontend_applied | verified | rolling_back | recovery_required)
            errors=$(jq -cn --arg phase "$phase" '[{code:"recovery_required",message:("前置事务未完成，当前阶段：" + $phase + "。继续更改前请先运行 frontend recover。")}]')
            ;;
        esac
    fi

    enabled=$(jq -c '.enabled' <<<"$frontend_profile")
    revision=$(jq -c '.revision' <<<"$frontend_profile")
    nginx=$(jq -c '.nginx' <<<"$frontend_profile")
    bindings=$(jq -c '.bindings' <<<"$frontend_profile")
    if [[ $enabled == true && $errors == '[]' ]]; then
        nginx=null
        detection_attempted=1
        if frontend_refresh_detection; then
            nginx=$frontend_nginx
        else
            errors=$(jq -cn --arg code "$frontend_error_code" --arg message "$frontend_error_message" '[{code:$code,message:$message}]')
        fi
    fi
    if [[ $json == --json ]]; then
        local ok=true
        [[ $errors == '[]' ]] || ok=false
        frontend_emit_json "$ok" "$enabled" "$revision" "$phase" "$nginx" "$bindings" "$errors"
    else
        printf '443 SNI 前置：%s\nrevision：%s\nbindings：%s\n' \
            "$([[ $enabled == true ]] && printf '已启用' || printf '未启用')" \
            "$revision" "$(jq -r 'length' <<<"$bindings")"
        if [[ $enabled == true ]]; then
            local status_nginx=$nginx service binary listener_range check_result
            [[ $status_nginx != null ]] || status_nginx=$(jq -c '.nginx' <<<"$frontend_profile")
            service=$(jq -r '.service // empty' <<<"$status_nginx")
            binary=$(jq -r '.binary // empty' <<<"$status_nginx")
            listener_range=$(jq -r '.listen_addresses | join(", ")' <<<"$frontend_profile")
            [[ $service ]] || service=未检测到
            [[ $binary ]] || binary=未检测到
            if [[ $detection_attempted == 1 ]]; then
                if [[ $errors == '[]' ]]; then
                    check_result=通过
                else
                    check_result=未通过
                fi
            else
                check_result='未执行（待恢复事务）'
            fi
            printf 'Nginx 服务：%s\nNginx 二进制：%s\nTCP 443 监听范围：%s\n本机检查：%s\n' \
                "$service" "$binary" "$listener_range" "$check_result"
        else
            printf '本机检查：未执行（前置未启用）\n'
        fi
        [[ $errors == '[]' ]] || jq -r '.[0].message' <<<"$errors" >&2
    fi
    [[ $errors == '[]' ]]
}

frontend_localize_path_context() {
    local message=$1 context
    case $message in
    *'refusing to replace '*) context=${message##*refusing to replace } ;;
    *'refusing to overwrite '*) context=${message##*refusing to overwrite } ;;
    *'remove it from '*) context=${message##*remove it from } ;;
    *'restore '*) context=${message##*restore }; context=${context%% from*} ;;
    *'transaction-created file '*) context=${message##*transaction-created file } ;;
    'Could not fingerprint '*) context=${message#Could not fingerprint }; context=${context%% during*} ;;
    'Could not read permissions for '*) context=${message#Could not read permissions for }; context=${context%% during*} ;;
    'Could not read ownership for '*) context=${message#Could not read ownership for }; context=${context%% during*} ;;
    *'replace '*) context=${message##*replace } ;;
    *'remove '*) context=${message##*remove } ;;
    *' for '*) context=${message##* for } ;;
    *' at '*) context=${message##* at } ;;
    *' reaches '*) context=${message##* reaches } ;;
    *' from '*) context=${message##* from } ;;
    *' in '*) context=${message##* in } ;;
    *': '*) context=${message##*: } ;;
    *'file '*) context=${message#*file }; context=${context%% *} ;;
    *'directory '*) context=${message#*directory } ;;
    *) return 1 ;;
    esac
    context=${context%%;*}
    context=${context%% (*}
    context=${context%.}
    printf '%s' "$context"
}

frontend_localize_error_message() {
    local code=$1 message=$2 context active_addresses
    case $code in
    already_enabled) printf '443 SNI 前置已启用；仅首次迁移时可指定节点引用。' ;;
    auxiliary_port_unavailable) printf '无法为本机拒绝服务分配可用的 TCP 端口。' ;;
    backend_port_unavailable) printf '无法为 sing-box 后端分配可用的回环端口。' ;;
    backend_restart_failed) printf '候选 sing-box 服务未能重启并进入运行状态。' ;;
    binding_drift)
        if [[ $message == *': '* ]]; then
            context=${message##*: }
            printf '已绑定节点 %s 缺失、不安全或与保存的后端配置不一致。' "$context"
        else
            printf '已绑定节点缺失、不安全或与保存的后端配置不一致。'
        fi
        ;;
    binding_missing)
        context=${message##*: }
        printf '节点 %s 未绑定到已启用的前置。' "$context"
        ;;
    bindings_present)
        context=${message##*: }
        printf '以下节点仍绑定到前置，无法停用：%s。' "$context"
        ;;
    candidate_validation_failed) printf '完整的隔离 Nginx 候选配置未通过当前二进制的检查。' ;;
    config_drift)
        context=$(frontend_localize_path_context "$message") || context=
        if [[ $context ]]; then
            printf '文件 %s 在检查期间发生变化；为避免覆盖用户修改，已停止操作。' "$context"
        else
            printf '文件在检查期间发生变化；为避免覆盖用户修改，已停止操作。'
        fi
        ;;
    duplicate_sni)
        if [[ $message == *' at '* ]]; then
            context=${message#* at }
            printf 'SNI 与用户 Nginx map 规则冲突（%s）。' "$context"
        elif [[ $message == *'already bound by '* ]]; then
            context=${message#*already bound by }
            printf 'SNI 已绑定到其他节点（%s）。' "$context"
        elif [[ $message == *'already used by another binding: '* ]]; then
            context=${message#*another binding: }
            printf 'SNI 已由另一个绑定使用（%s）。' "$context"
        else
            printf 'SNI 与现有 Nginx map 规则冲突。'
        fi
        ;;
    file_apply_failed)
        context=$(frontend_localize_path_context "$message") || context=
        if [[ $context ]]; then
            printf '无法安全地应用文件更改：%s。' "$context"
        else
            printf '无法安全地应用文件更改。'
        fi
        ;;
    frontend_disabled) printf 'Nginx Reality 前置尚未启用。' ;;
    inline_443_node) printf '共享 sing-box 配置中包含无法通过节点引用纳管的 443 入站。' ;;
    invalid_profile) printf '前置配置文件无效或包含不安全的 Nginx 所有权信息。' ;;
    invalid_sni) printf 'Reality SNI 必须是由有效标签组成的 ASCII 域名。' ;;
    listen_addresses_invalid) printf '所选监听地址范围无效，或所需地址族不可用。' ;;
    listen_addresses_required) printf '必须明确选择 IPv4、IPv6 或双栈监听范围。' ;;
    listen_addresses_unavailable) printf '无法确定可用的全局 IPv4 或 IPv6 地址。' ;;
    listener_check_unavailable) printf '无法使用 ss 检查当前 TCP 监听端口。' ;;
    lock_unavailable) printf '缺少 flock，无法协调前置配置更改。' ;;
    map_variable_unavailable) printf '无法为 Nginx map 选择未使用的变量名。' ;;
    nginx_build_args_missing) printf 'Nginx 未提供构建参数，无法验证其 prefix 和配置路径。' ;;
    nginx_candidate_failed) printf '无法安全准备完整的隔离 Nginx 候选配置。' ;;
    nginx_config_invalid)
        if [[ $message == *': '* ]]; then
            context=${message##*: }
            printf 'Nginx 完整配置的语法检查未通过：%s。' "$context"
        else
            printf 'Nginx 完整配置的语法检查未通过。'
        fi
        ;;
    nginx_config_missing)
        context=${message##*: }
        printf '当前 Nginx 配置文件不存在、不可读或不是普通文件：%s。' "$context"
        ;;
    nginx_config_unreadable) printf '无法读取完整的当前 Nginx 配置。' ;;
    nginx_config_unsupported)
        context=$(frontend_localize_path_context "$message") || context=
        if [[ $context ]]; then
            printf '当前 Nginx 配置包含无法安全处理的结构（%s）。' "$context"
        else
            printf '当前 Nginx 配置包含无法安全处理的结构。'
        fi
        ;;
    nginx_detection_failed) printf '无法记录当前 Nginx 实例的检查结果。' ;;
    nginx_http_443_conflict)
        context=${message##* in }
        printf 'HTTP 配置文件 %s 已监听 TCP 443，不能启用 stream 前置。' "$context"
        ;;
    nginx_instance_ambiguous) printf '无法唯一识别当前 Nginx 服务实例。' ;;
    nginx_instance_drift) printf '当前 Nginx 实例或支持的配置入口与已保存的前置配置不一致。' ;;
    nginx_listener_address_unknown) printf '无法确定当前 TCP 443 监听器的地址范围。' ;;
    nginx_listener_check_failed) printf '无法识别当前 Nginx 二进制以检查监听端口归属。' ;;
    nginx_listener_drift)
        if [[ $message == 'Saved address range '* ]]; then
            context=${message#Saved address range }
            active_addresses=${context#* active listener addresses }
            context=${context%% does not match*}
            printf '已保存的监听范围 %s 与当前 Nginx 地址 %s 不一致。' "$context" "$active_addresses"
        else
            printf '当前 TCP 443 监听地址与已保存的监听范围不一致。'
        fi
        ;;
    nginx_listener_missing)
        if [[ $message == *'address '* && $message == *' at TCP 443.' ]]; then
            context=${message#*address }
            context=${context% at TCP 443.}
            printf '选定的 Nginx 服务未在地址 %s 上监听 TCP 443。' "$context"
        else
            printf '选定的 Nginx 服务未在配置的 TCP 443 地址上监听。'
        fi
        ;;
    nginx_map_overlap)
        if [[ $message == *' at '* ]]; then
            context=${message#* at }
            printf '无法确认该 SNI 与用户 Nginx map 规则不重叠，已停止操作（%s）。' "$context"
        else
            printf '无法确认该 SNI 与用户 Nginx map 规则不重叠，已停止操作。'
        fi
        ;;
    nginx_path_unsupported) printf '包含空白字符的 Nginx 项目路径不受支持。' ;;
    nginx_reload_failed) printf 'Nginx 服务 reload 命令执行失败。' ;;
    nginx_reload_unavailable) printf '当前 Nginx 服务没有受支持的 reload 目标。' ;;
    nginx_service_manager_missing) printf '无法通过 systemd 或 OpenRC 识别 Nginx 服务。' ;;
    nginx_ssl_preread_missing) printf '当前 Nginx 未提供 stream ssl_preread 支持。' ;;
    nginx_stream_missing) printf '当前 Nginx 未提供 stream 模块。' ;;
    nginx_unavailable) printf 'Nginx 服务未运行，或无法读取其活动配置。' ;;
    nginx_worker_unverified) printf '在等待时间内未能确认 Nginx 已启动新的 worker。' ;;
    node_candidate_failed)
        case $message in
        *'candidate for '*) context=${message##*candidate for } ;;
        *'migrated node candidate: '*) context=${message##*: } ;;
        *) context= ;;
        esac
        if [[ $context ]]; then printf '无法准备候选节点或共享 sing-box 配置：%s。' "$context"; else printf '无法准备完整的候选节点和共享 sing-box 配置。'; fi
        ;;
    node_candidate_invalid) printf '绑定节点编辑需要有效的候选文件，并且必须产生一个入站和有效的监听端口。' ;;
    node_not_on_public_443) printf '所选节点未配置为监听公网 TCP 443。' ;;
    node_operation_invalid) printf '不支持此绑定节点操作。' ;;
    node_ref_conflict)
        context=${message##*: }
        printf '目标节点文件或元数据已存在：%s。' "$context"
        ;;
    node_ref_duplicate) printf '同一节点引用被重复选择。' ;;
    node_ref_invalid)
        context=$(frontend_localize_path_context "$message") || context=
        if [[ $context ]]; then printf '节点引用无效或无法解析：%s。' "$context"; else printf '节点引用无效或无法解析。'; fi
        ;;
    node_ref_missing)
        context=$(frontend_localize_path_context "$message") || context=
        printf '节点引用未指向普通节点文件：%s。' "$context"
        ;;
    node_unsupported)
        if [[ $message == 'Move the node off public port 443'* ]]; then
            printf '请先将节点移出公网 443，再更改协议或传输层；前置仅支持普通 VLESS-REALITY。'
        elif [[ $message == 'Only a single ordinary VLESS-REALITY inbound without transport can be bound: '* ]]; then
            context=${message##*: }
            printf '节点 %s 必须是未启用传输层的普通 VLESS-REALITY 入站。' "$context"
        else
            printf '节点必须是未启用传输层的普通 VLESS-REALITY 入站。'
        fi
        ;;
    operation_in_progress) printf '另一个前置操作正在进行。' ;;
    owned_file_drift)
        context=$(frontend_localize_path_context "$message") || context=
        if [[ $context ]]; then printf '受管理的 Reality map 缺失、元数据无效或已被外部修改：%s。' "$context"; else printf '受管理的 Reality map 缺失、元数据无效或已被外部修改。'; fi
        ;;
    profile_bindings_present) printf '已停用的配置仍包含节点绑定，拒绝启用不一致的状态。' ;;
    project_file_conflict) printf '项目自有的 Nginx 文件已存在，但没有对应的已启用配置。' ;;
    project_path_conflict)
        context=$(frontend_localize_path_context "$message") || context=
        printf 'Nginx 项目目录不是安全的普通目录：%s。' "$context"
        ;;
    recovery_failed)
        context=$(frontend_localize_path_context "$message") || context=
        if [[ $context ]]; then printf '前置事务恢复失败：%s。' "$context"; else printf '前置事务恢复未通过验证。'; fi
        ;;
    recovery_required) printf '前置事务尚未完成；请先运行 frontend recover。' ;;
    shared_entry_changed)
        context=${message#*file }
        context=${context%% changed*}
        printf '项目自有的 Nginx 文件 %s 已在启用后更改；为保留可能存在的用户依赖，不会删除共享入口。' "$context"
        ;;
    shared_entry_in_use)
        context=${message#*file }
        context=${context%% refers*}
        printf 'Nginx 文件 %s 仍引用项目创建的 Reality 入口；停用前请检查该依赖。' "$context"
        ;;
    singbox_candidate_invalid) printf '完整的候选 sing-box 配置未通过验证。' ;;
    singbox_config_unreadable)
        context=$(frontend_localize_path_context "$message") || context=
        if [[ $context ]]; then printf '无法安全检查 sing-box 配置：%s。' "$context"; else printf '无法安全检查 sing-box 配置。'; fi
        ;;
    state_unwritable)
        if [[ $message == 'Could not '* ]]; then context=$(frontend_localize_path_context "$message") || context=; else context=; fi
        if [[ $context ]]; then printf '前置状态目录不可安全写入：%s。' "$context"; else printf '前置状态目录不可安全写入。'; fi
        ;;
    tcp_443_owner_unknown)
        context=${message#*socket }
        context=${context%% is occupied*}
        printf 'TCP 443 地址 %s 已被占用，但 ss 未报告其所属进程。' "$context"
        ;;
    tcp_443_port_conflict)
        if [[ $message == *': '* ]]; then
            context=${message##*: }
            printf 'TCP 443 地址 %s 由所选 Nginx 实例以外的进程占用。' "$context"
        else
            printf 'TCP 443 的目标地址范围由所选 Nginx 实例以外的进程占用。'
        fi
        ;;
    transaction_candidate_missing)
        context=$(frontend_localize_path_context "$message") || context=
        if [[ $context ]]; then printf '事务候选文件缺失或不安全：%s。' "$context"; else printf '事务候选文件缺失或不安全。'; fi
        ;;
    transaction_corrupt)
        if [[ $message == *'未知阶段：'* ]]; then
            context=${message##*未知阶段：}
            printf '前置事务包含未知阶段：%s。' "$context"
        elif [[ $message == *' for '* ]] && context=$(frontend_localize_path_context "$message"); then
            printf '前置事务记录包含不安全的文件路径：%s。' "$context"
        else
            printf '前置事务记录缺失、损坏或包含不安全的数据。'
        fi
        ;;
    transaction_path_invalid)
        context=$(frontend_localize_path_context "$message") || context=
        printf '事务目标路径不安全：%s。' "$context"
        ;;
    transaction_state_write_failed) printf '无法安全保存前置事务状态。' ;;
    unselected_443_nodes)
        context=${message##*: }
        printf '启用前置时必须选择所有现有的 443 节点；未选择：%s。' "$context"
        ;;
    unsupported_schema) printf '前置配置文件使用了不受支持的 schema_version。' ;;
    nginx_module_check_failed|nginx_stream_proxy_missing|nginx_stream_return_missing) printf '当前 Nginx 二进制未通过所需模块能力检查。' ;;
    *) printf '前置操作失败（%s）。' "$code" ;;
    esac
}

frontend_set_error() {
    frontend_error_code=$1
    frontend_error_message=$(frontend_localize_error_message "$1" "$2")
}

frontend_detect_nginx_service() {
    local service_pid service_exec service_reload process_line process_args process_binary process_real exec_real
    local build_output build_args token runtime_config runtime_prefix service_kind service_name
    local stream= ssl_preread= extra= arg_index
    frontend_error_code=
    frontend_error_message=
    frontend_nginx=

    if [[ $is_systemd ]]; then
        service_kind=systemd
        service_name=nginx.service
        systemctl is-active --quiet "$service_name" >/dev/null 2>&1 || {
            frontend_set_error nginx_unavailable 'Nginx systemd service is not active.'
            return 1
        }
        service_pid=$(systemctl show -p MainPID --value "$service_name" 2>/dev/null) || {
            frontend_set_error nginx_instance_ambiguous 'Could not read the Nginx service MainPID.'
            return 1
        }
        service_exec=$(systemctl show -p ExecStart --value "$service_name" 2>/dev/null) || {
            frontend_set_error nginx_instance_ambiguous 'Could not read the Nginx service ExecStart.'
            return 1
        }
        service_reload=$(systemctl show -p ExecReload --value "$service_name" 2>/dev/null) || service_reload=
        service_exec=$(sed -n 's/.*path=\([^ ;]*\).*/\1/p' <<<"$service_exec")
        [[ $service_reload ]] || {
            frontend_set_error nginx_reload_unavailable 'The active Nginx systemd service has no ExecReload target.'
            return 1
        }
        [[ $service_pid =~ ^[0-9]+$ && $service_pid -gt 1 && $service_exec == /* && -x $service_exec ]] || {
            frontend_set_error nginx_instance_ambiguous 'Nginx service must expose one active master PID and a direct executable path.'
            return 1
        }
        process_line=$(ps -o args= -p "$service_pid" 2>/dev/null) || process_line=
        [[ $process_line == *'nginx: master process '* ]] || {
            frontend_set_error nginx_instance_ambiguous 'The Nginx service MainPID is not an identifiable Nginx master process.'
            return 1
        }
        process_args=${process_line#*nginx: master process }
    elif [[ $is_openrc ]]; then
        service_kind=openrc
        service_name=nginx
        rc-service "$service_name" status >/dev/null 2>&1 || {
            frontend_set_error nginx_unavailable 'Nginx OpenRC service is not active.'
            return 1
        }
        local master_lines
        master_lines=$(ps -eo pid=,args= 2>/dev/null | awk '/nginx: master process / {print}')
        [[ $(wc -l <<<"$master_lines") == 1 ]] || {
            frontend_set_error nginx_instance_ambiguous 'Expected exactly one identifiable Nginx master process.'
            return 1
        }
        process_line=${master_lines#* }
        service_pid=${process_line%% *}
        process_args=${process_line#*nginx: master process }
        service_exec=${process_args%% *}
        service_reload='rc-service nginx reload'
        [[ $service_pid =~ ^[0-9]+$ && $service_pid -gt 1 && $service_exec == /* && -x $service_exec ]] || {
            frontend_set_error nginx_instance_ambiguous 'Could not identify the active Nginx executable from its master process.'
            return 1
        }
    else
        frontend_set_error nginx_service_manager_missing 'Neither systemd nor OpenRC is available to identify the Nginx service.'
        return 1
    fi

    process_args=${process_args#"$service_exec"}
    if [[ $process_args == *'-g '* ]]; then
        if [[ $process_args =~ -g[[:space:]]+daemon[[:space:]]+on\;[[:space:]]+master_process[[:space:]]+on\; ]]; then
            process_args=${process_args/-g daemon on; master_process on;/}
        else
            frontend_set_error nginx_instance_ambiguous 'Nginx uses custom global command-line directives that cannot be safely reproduced for checks.'
            return 1
        fi
    fi

    local -a process_args_list
    read -r -a process_args_list <<<"$process_args"
    runtime_config=
    runtime_prefix=
    for ((arg_index = 0; arg_index < ${#process_args_list[@]}; arg_index++)); do
        token=${process_args_list[$arg_index]}
        case $token in
        -c | -p)
            ((arg_index + 1 < ${#process_args_list[@]})) || {
                frontend_set_error nginx_instance_ambiguous "Nginx master process has an incomplete $token argument."
                return 1
            }
            if [[ $token == -c ]]; then
                runtime_config=${process_args_list[$((arg_index + 1))]}
            else
                runtime_prefix=${process_args_list[$((arg_index + 1))]}
            fi
            ((arg_index += 1))
            ;;
        -e)
            ((arg_index + 1 < ${#process_args_list[@]})) || {
                frontend_set_error nginx_instance_ambiguous 'Nginx master process has an incomplete -e argument.'
                return 1
            }
            ((arg_index += 1))
            ;;
        '') ;;
        *)
            frontend_set_error nginx_instance_ambiguous "Nginx master process contains an unsupported argument: $token"
            return 1
            ;;
        esac
    done

    process_real=$(readlink -f "/proc/$service_pid/exe" 2>/dev/null) || process_real=
    exec_real=$(readlink -f "$service_exec" 2>/dev/null) || exec_real=
    [[ $process_real && $exec_real && $process_real == "$exec_real" ]] || {
        frontend_set_error nginx_instance_ambiguous 'The active Nginx master executable does not match the service definition.'
        return 1
    }

    build_output=$("$service_exec" -V 2>&1) || {
        frontend_set_error nginx_unavailable 'Could not read the active Nginx binary build arguments.'
        return 1
    }
    build_args=$(sed -n 's/^.*configure arguments:[[:space:]]*//p' <<<"$build_output" | tail -n 1)
    [[ $build_args ]] || {
        frontend_set_error nginx_build_args_missing 'Nginx did not report configure arguments; its prefix and config path cannot be verified.'
        return 1
    }
    local build_config= build_prefix=
    local -a build_args_list
    read -r -a build_args_list <<<"$build_args"
    for token in "${build_args_list[@]}"; do
        case $token in
        --prefix=*) build_prefix=${token#--prefix=} ;;
        --conf-path=*) build_config=${token#--conf-path=} ;;
        --with-stream | --with-stream=dynamic) stream=true ;;
        --with-stream_ssl_preread_module | --with-stream_ssl_preread_module=dynamic) ssl_preread=true ;;
        esac
    done
    [[ $stream == true ]] || {
        frontend_set_error nginx_stream_missing 'The active Nginx binary was not built with the stream module.'
        return 1
    }
    [[ $ssl_preread == true ]] || {
        frontend_set_error nginx_ssl_preread_missing 'The active Nginx binary was not built with stream ssl_preread support.'
        return 1
    }
    [[ $runtime_prefix ]] && build_prefix=$runtime_prefix
    [[ $runtime_config ]] && build_config=$runtime_config
    [[ $build_prefix == /* && $build_config ]] || {
        frontend_set_error nginx_instance_ambiguous 'Could not determine the active Nginx prefix and configuration path.'
        return 1
    }
    if [[ $build_config != /* ]]; then
        build_config=${build_prefix%/}/$build_config
    fi
    [[ -f $build_config && -r $build_config ]] || {
        frontend_set_error nginx_config_missing "The active Nginx configuration is not readable: $build_config"
        return 1
    }

    local -a nginx_args=("$service_exec")
    [[ $build_prefix ]] && nginx_args+=(-p "$build_prefix")
    nginx_args+=(-c "$build_config")
    "${nginx_args[@]}" -t >/dev/null 2>&1 || {
        frontend_set_error nginx_config_invalid "The active Nginx configuration failed its full syntax check: $build_config"
        return 1
    }
    "${nginx_args[@]}" -T >/dev/null 2>&1 || {
        frontend_set_error nginx_config_unreadable 'Nginx could not dump the complete active configuration.'
        return 1
    }

    frontend_nginx=$(jq -cn \
        --arg service "$service_name" \
        --arg service_kind "$service_kind" \
        --arg binary "$service_exec" \
        --arg config "$build_config" \
        --arg prefix "$build_prefix" \
        --arg reload_target "$service_reload" \
        --argjson pid "$service_pid" \
        --argjson stream "$stream" \
        --argjson ssl_preread "$ssl_preread" \
        '{service:$service,service_kind:$service_kind,binary:$binary,config:$config,prefix:$prefix,pid:$pid,reload_target:$reload_target,modules:{stream:false,ssl_preread:false,map:false,proxy:false,return:false},compiled:{stream:$stream,ssl_preread:$ssl_preread}}') || {
        frontend_set_error nginx_detection_failed 'Could not serialize the Nginx instance details.'
        return 1
    }
    return 0
}

frontend_scan_config_file() {
    local file=$1 context=$2 inherited_map_target=${3:-} records kind a b c d e f child include_pattern include_map_target
    local -a includes

    [[ ${frontend_scan_active[$file]+yes} ]] && {
        frontend_set_error nginx_config_unsupported "Nginx configuration include cycle reaches $file"
        return 1
    }
    frontend_scan_active[$file]=1
    frontend_scan_source_files+=("$file")
    frontend_scan_source_hashes+=("$(sha256sum "$file" | awk '{print $1}')")
    records=$(awk -v initial_context="$context" -v initial_map_target="$inherited_map_target" -v source_file="$file" '
        function flush_token() {
            if (token != "") {
                words[++word_count] = token
                word_starts[word_count] = token_start
                token = ""
                token_start = 0
            }
        }
        function has_context(wanted, i) {
            for (i = 1; i <= depth; i++) if (stack[i] == wanted) return 1
            return 0
        }
        function current_map_target(i, j) {
            for (i = depth; i > 0; i--) {
                if (stack[i] != "map") continue
                for (j = 1; j <= map_count; j++) if (map_depth[j] == i) return map_target[j]
                return initial_map_target
            }
            return ""
        }
        function output_server(i) {
            if (has_context("stream")) {
                printf "STREAMSERVER\t%d\t%d\t%d\t%s\t%s\t%s\t%d\n", server_has_tcp443[i], server_has_udp443[i], server_preread[i], server_proxy[i], server_ports[i], server_addresses[i], server_ipv6only_off[i]
            } else if (has_context("http")) {
                printf "HTTPSERVER\t%d\t%s\n", server_has_tcp443[i], server_ports[i]
            }
        }
        function process_statement(i, port, udp, active_server, include_context, address, extracted_port, target, key, rule_kind) {
            if (word_count == 0) return
            if (words[1] == "include") {
                include_context = "top"
                if (has_context("map")) include_context = "map"
                else if (has_context("stream")) include_context = "stream"
                else if (has_context("server")) include_context = "server"
                else if (has_context("http")) include_context = "http"
                printf "INCLUDE\t%d\t%d\t%d\t%s\t%s\t%s\n", FNR, word_starts[1], char_index, include_context, words[2], current_map_target()
            }
            if (has_context("map") && words[1] != "include") {
                target = current_map_target()
                key = words[1]
                rule_kind = "exact"
                if (key == "hostnames") {
                    rule_kind = "directive"
                    if (target != "") printf "MAP_HOSTNAMES\t%s\n", target
                }
                else if (key ~ /^~/) rule_kind = "regex"
                else if (key ~ /\*/ || key ~ /^\./) rule_kind = "wildcard"
                else if (key == "volatile") rule_kind = "directive"
                else if (key ~ /\\/ || key ~ /\$/) rule_kind = "complex"
                if (target != "" && rule_kind != "directive") printf "MAP_RULE\t%d\t%s\t%s\t%s\n", FNR, target, key, rule_kind
            }
            if (words[1] == "listen" && has_context("server")) {
                port = 0
                udp = 0
                for (i = 2; i <= word_count; i++) {
                    if (words[i] == "udp") udp = 1
                    if (words[i] == "443" || words[i] ~ /:443$/) port = 443
                }
                active_server = depth
                while (active_server > 0 && stack[active_server] != "server") active_server--
                if (active_server > 0) {
                    address = words[2]
                    extracted_port = address
                    if (address ~ /:[0-9]+$/) sub(/^.*:/, "", extracted_port)
                    if (port == 443 && !udp && (address ~ /^\[/ || address ~ /::/)) {
                        for (i = 2; i <= word_count; i++) if (words[i] == "ipv6only=off") server_ipv6only_off[active_server] = 1
                    }
                    if (extracted_port ~ /^[0-9]+$/ && !udp) {
                        if (server_ports[active_server] != "") server_ports[active_server] = server_ports[active_server] ","
                        server_ports[active_server] = server_ports[active_server] extracted_port
                    }
                    if (port == 443) {
                        if (udp) server_has_udp443[active_server] = 1
                        else {
                            server_has_tcp443[active_server] = 1
                            if (address == "443") address = "*"
                            else sub(/:443$/, "", address)
                            gsub(/^\[/, "", address)
                            gsub(/\]$/, "", address)
                            if (server_addresses[active_server] != "") server_addresses[active_server] = server_addresses[active_server] ","
                            server_addresses[active_server] = server_addresses[active_server] address
                        }
                    }
                }
            }
            if (has_context("stream") && has_context("server")) {
                active_server = depth
                while (active_server > 0 && stack[active_server] != "server") active_server--
                if (active_server > 0) {
                    if (words[1] == "ssl_preread" && words[2] == "on") server_preread[active_server] = 1
                    if (words[1] == "proxy_pass" && word_count == 2) server_proxy[active_server] = words[2]
                }
            }
            word_count = 0
            delete words
        }
        function open_block(i, head, map_index) {
            flush_token()
            if (word_count == 0) {
                print "ERROR\tblock has no directive"
                return
            }
            head = words[1]
            if (head == "stream" && !has_context("stream")) {
                stream_index = ++stream_count
                stream_start[stream_index] = FNR
                stream_depth[stream_index] = depth + 1
                printf "STREAM_START\t%d\n", FNR
            }
            if (head == "map" && has_context("stream") && word_count >= 3) {
                map_index = ++map_count
                map_source[map_index] = words[2]
                map_target[map_index] = words[3]
                map_depth[map_index] = depth + 1
                map_start[map_index] = FNR
            }
            stack[++depth] = head
            if (head == "server" && (has_context("stream") || has_context("http"))) {
                server_has_tcp443[depth] = 0
                server_has_udp443[depth] = 0
                server_preread[depth] = 0
                server_proxy[depth] = ""
                server_ports[depth] = ""
                server_addresses[depth] = ""
                server_ipv6only_off[depth] = 0
            }
            word_count = 0
            delete words
        }
        function close_block(i, map_index) {
            flush_token()
            if (word_count > 0) process_statement()
            if (depth == 0) {
                print "ERROR\tunmatched closing brace"
                return
            }
            if (stack[depth] == "server") output_server(depth)
            if (stack[depth] == "map") {
                for (map_index = 1; map_index <= map_count; map_index++) {
                    if (map_depth[map_index] == depth) {
                        printf "MAP\t%d\t%d\t%s\t%s\n", map_start[map_index], FNR, map_source[map_index], map_target[map_index]
                        delete map_depth[map_index]
                    }
                }
            }
            if (stack[depth] == "stream") {
                printf "STREAM_END\t%d\n", FNR
            }
            delete server_has_tcp443[depth]
            delete server_has_udp443[depth]
            delete server_preread[depth]
            delete server_proxy[depth]
            delete server_ports[depth]
            delete server_addresses[depth]
            delete server_ipv6only_off[depth]
            delete stack[depth]
            depth--
        }
        BEGIN {
            depth = 0
            word_count = 0
            if (initial_context != "top") {
                n = split(initial_context, initial_parts, "/")
                for (i = 1; i <= n; i++) {
                    stack[++depth] = initial_parts[i]
                    if (initial_parts[i] == "server") {
                        server_has_tcp443[depth] = 0
                        server_has_udp443[depth] = 0
                        server_preread[depth] = 0
                        server_proxy[depth] = ""
                        server_ports[depth] = ""
                        server_addresses[depth] = ""
                        server_ipv6only_off[depth] = 0
                    }
                }
                if (initial_context == "map") {
                    map_count = 1
                    map_depth[1] = depth
                    map_target[1] = initial_map_target
                }
            }
            base_depth = depth
        }
        {
            for (char_index = 1; char_index <= length($0); char_index++) {
                ch = substr($0, char_index, 1)
                if (comment) break
                if (quote != "") {
                    if (escaped) {
                        token = token ch
                        escaped = 0
                    } else if (ch == "\\") {
                        escaped = 1
                    } else if (ch == quote) {
                        quote = ""
                    } else {
                        token = token ch
                    }
                    continue
                }
                if (ch == "#") {
                    comment = 1
                } else if (ch == "\"" || ch == "\047") {
                    if (token == "") token_start = char_index
                    quote = ch
                } else if (ch == "{") {
                    open_block()
                } else if (ch == "}") {
                    close_block()
                } else if (ch == ";") {
                    flush_token()
                    process_statement()
                } else if (ch ~ /[[:space:]]/) {
                    flush_token()
                } else {
                    if (token == "") token_start = char_index
                    token = token ch
                }
            }
            comment = 0
        }
        END {
            if (quote != "" || escaped || depth != base_depth) print "ERROR\tunbalanced quote or block"
            if (word_count > 0) process_statement()
            if (depth == 0 && initial_context == "top") print "FILE_OK"
        }
    ' "$file" 2>/dev/null) || {
        frontend_set_error nginx_config_unsupported "Could not parse the active Nginx configuration file $file"
        unset 'frontend_scan_active[$file]'
        return 1
    }

    while IFS=$'\t' read -r kind a b c d e f g; do
        case $kind in
        STREAM_START)
            frontend_scan_stream_files+=("$file")
            frontend_scan_stream_starts+=("$a")
            ;;
        STREAM_END)
            frontend_scan_stream_ends+=("$a")
            ;;
        MAP)
            frontend_scan_map_files+=("$file")
            frontend_scan_map_starts+=("$a")
            frontend_scan_map_ends+=("$b")
            frontend_scan_map_sources+=("$c")
            frontend_scan_map_targets+=("$d")
            ;;
        MAP_RULE)
            frontend_scan_map_rule_files+=("$file")
            frontend_scan_map_rule_lines+=("$a")
            frontend_scan_map_rule_targets+=("$b")
            frontend_scan_map_rule_keys+=("$c")
            frontend_scan_map_rule_kinds+=("$d")
            ;;
        MAP_HOSTNAMES)
            frontend_scan_map_hostnames_targets+=("$a")
            ;;
        STREAMSERVER)
            frontend_scan_server_443+=("$a")
            frontend_scan_server_udp443+=("$b")
            frontend_scan_server_preread+=("$c")
            frontend_scan_server_proxy+=("$d")
            frontend_scan_configured_port_lists+=("$e")
            frontend_scan_server_addresses+=("$f")
            frontend_scan_server_ipv6only_off+=("$g")
            ;;
        HTTPSERVER)
            [[ $a == 1 ]] && frontend_scan_http_443+=("$file")
            frontend_scan_configured_port_lists+=("$b")
            ;;
        INCLUDE)
            local include_line=$a include_start=$b include_end=$c include_context=$d
            child=$include_context
            include_pattern=$e
            include_map_target=$f
            [[ $include_pattern && $include_pattern != *'$'* && $include_pattern != *[[:space:]]* ]] || {
                frontend_set_error nginx_config_unsupported "Dynamic or empty Nginx include cannot be followed from $file"
                unset 'frontend_scan_active[$file]'
                return 1
            }
            [[ $child != server ]] || {
                frontend_set_error nginx_config_unsupported "An include inside an Nginx server block cannot be safely resolved from $file"
                unset 'frontend_scan_active[$file]'
                return 1
            }
            [[ $include_pattern == /* ]] || include_pattern=${frontend_nginx_prefix%/}/$include_pattern
            shopt -s nullglob
            includes=( $include_pattern )
            shopt -u nullglob
            ((${#includes[@]} > 0)) || {
                frontend_set_error nginx_config_unsupported "Nginx include did not resolve to a file: $include_pattern"
                unset 'frontend_scan_active[$file]'
                return 1
            }
            local include_file canonical_file
            frontend_scan_include_parent+=("$file")
            frontend_scan_include_lines+=("$include_line")
            frontend_scan_include_starts+=("$include_start")
            frontend_scan_include_ends+=("$include_end")
            frontend_scan_include_contexts+=("$include_context")
            frontend_scan_include_patterns+=("$include_pattern")
            local include_index=$((${#frontend_scan_include_parent[@]} - 1))
            for include_file in "${includes[@]}"; do
                canonical_file=$(readlink -f "$include_file" 2>/dev/null) || canonical_file=
                [[ $canonical_file && -f $canonical_file && -r $canonical_file ]] || {
                    frontend_set_error nginx_config_unsupported "Nginx include is not a readable regular file: $include_file"
                    unset 'frontend_scan_active[$file]'
                    return 1
                }
                frontend_scan_include_edges+=("$include_index:$canonical_file")
                if ! frontend_scan_config_file "$canonical_file" "$child" "$include_map_target"; then
                    unset 'frontend_scan_active[$file]'
                    return 1
                fi
            done
            ;;
        ERROR)
            frontend_set_error nginx_config_unsupported "Malformed Nginx configuration at $file:$a"
            unset 'frontend_scan_active[$file]'
            return 1
            ;;
        esac
    done <<<"$records"
    unset 'frontend_scan_active[$file]'
    return 0
}

frontend_flatten_file() {
    local file=$1 output=$2 line line_number=0 position start end include_index edge_index child
    local -a line_includes=() line_children=()
    while IFS= read -r line || [[ $line ]]; do
        ((line_number += 1))
        line_includes=()
        for ((include_index = 0; include_index < ${#frontend_scan_include_parent[@]}; include_index++)); do
            [[ ${frontend_scan_include_parent[$include_index]} == "$file" && ${frontend_scan_include_lines[$include_index]} == "$line_number" ]] && line_includes+=("$include_index")
        done
        if ((${#line_includes[@]} == 0)); then
            printf '%s\n' "$line" >>"$output"
            continue
        fi
        position=0
        for include_index in "${line_includes[@]}"; do
            start=$((${frontend_scan_include_starts[$include_index]} - 1))
            end=${frontend_scan_include_ends[$include_index]}
            ((start >= position && end > start && end <= ${#line})) || {
                frontend_set_error nginx_config_unsupported "Could not preserve the include statement in $file:$line_number"
                return 1
            }
            printf '%s' "${line:position:start-position}" >>"$output"
            line_children=()
            for edge_index in "${frontend_scan_include_edges[@]}"; do
                [[ ${edge_index%%:*} == "$include_index" ]] && line_children+=("${edge_index#*:}")
            done
            ((${#line_children[@]} > 0)) || {
                frontend_set_error nginx_config_unsupported "Could not resolve the static include in $file:$line_number"
                return 1
            }
            for child in "${line_children[@]}"; do
                printf '\n' >>"$output"
                if [[ $child == "${frontend_flatten_override_file:-}" && $frontend_flatten_override_content ]]; then
                    cat "$frontend_flatten_override_content" >>"$output" || return 1
                else
                    frontend_flatten_file "$child" "$output" || return 1
                fi
                printf '\n' >>"$output"
            done
            position=$end
        done
        printf '%s\n' "${line:position}" >>"$output"
    done <"$file"
    return 0
}

frontend_write_insert_before_line() {
    local source=$1 line_number=$2 insertion=$3 destination=$4 offset total_lines
    [[ $line_number =~ ^[0-9]+$ && $line_number -gt 0 ]] || return 1
    total_lines=$(wc -l <"$source") || return 1
    ((line_number <= total_lines)) || return 1
    offset=$(head -n "$((line_number - 1))" "$source" | wc -c) || return 1
    head -c "$offset" "$source" >"$destination" || return 1
    printf '%s' "$insertion" >>"$destination" || return 1
    [[ $insertion == *$'\n' ]] || printf '\n' >>"$destination" || return 1
    tail -c +$((offset + 1)) "$source" >>"$destination" || return 1
}

frontend_write_append() {
    local source=$1 insertion=$2 destination=$3 last_byte
    cat "$source" >"$destination" || return 1
    if [[ -s $source ]]; then
        last_byte=$(tail -c 1 "$source" | od -An -tu1 | tr -d '[:space:]')
        [[ $last_byte == 10 ]] || {
            frontend_set_error nginx_config_unsupported "Nginx config file $source has no final newline; safe insertion cannot be proven."
            return 1
        }
    fi
    printf '%s' "$insertion" >>"$destination" || return 1
    [[ $insertion == *$'\n' ]] || printf '\n' >>"$destination"
}

frontend_remove_marker_block() {
    local source=$1 destination=$2 expected_hash=${3:-} begin_line end_line start_offset end_offset actual_hash
    local begin_count end_count byte_count
    begin_count=$(grep -cF '# one-singbox-frontend:begin' "$source" 2>/dev/null) || begin_count=0
    end_count=$(grep -cF '# one-singbox-frontend:end' "$source" 2>/dev/null) || end_count=0
    [[ $begin_count == 1 && $end_count == 1 ]] || {
        frontend_set_error config_drift "Expected one owned frontend block in $source; found begin=$begin_count end=$end_count."
        return 1
    }
    begin_line=$(grep -nF '# one-singbox-frontend:begin' "$source" | cut -d: -f1)
    end_line=$(grep -nF '# one-singbox-frontend:end' "$source" | cut -d: -f1)
    ((begin_line < end_line)) || {
        frontend_set_error config_drift "Owned frontend block markers are out of order in $source."
        return 1
    }
    start_offset=$(head -n "$((begin_line - 1))" "$source" | wc -c) || return 1
    end_offset=$(head -n "$end_line" "$source" | wc -c) || return 1
    byte_count=$(wc -c <"$source") || return 1
    ((end_offset <= byte_count)) || {
        frontend_set_error config_drift "Owned frontend block does not end on a complete line in $source (offset $end_offset exceeds $byte_count bytes)."
        return 1
    }
    actual_hash=$(dd if="$source" bs=1 skip="$start_offset" count="$((end_offset - start_offset))" status=none | sha256sum | awk '{print $1}') || return 1
    if [[ $expected_hash && $actual_hash != "$expected_hash" ]]; then
        frontend_set_error config_drift "Owned frontend block changed after enable; refusing to remove it from $source."
        return 1
    fi
    head -c "$start_offset" "$source" >"$destination" || return 1
    tail -c +$((end_offset + 1)) "$source" >>"$destination" || return 1
}

frontend_probe_nginx_modules() {
    local need_return=$1 config_file prefix binary probe_dir flat_config candidate_config probe_stream probe_output code
    config_file=$(jq -r '.config' <<<"$frontend_nginx")
    prefix=$(jq -r '.prefix' <<<"$frontend_nginx")
    binary=$(jq -r '.binary' <<<"$frontend_nginx")
    probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/one-singbox-frontend-check.XXXXXX") || {
        frontend_set_error nginx_candidate_failed 'Could not create an isolated Nginx candidate directory.'
        return 1
    }
    chmod 700 "$probe_dir" || {
        rm -rf "$probe_dir"
        frontend_set_error nginx_candidate_failed 'Could not secure the isolated Nginx candidate directory.'
        return 1
    }
    flat_config="$probe_dir/tree.conf"
    candidate_config="$probe_dir/candidate.conf"
    : >"$flat_config"
    frontend_flatten_file "$config_file" "$flat_config" || {
        rm -rf "$probe_dir"
        return 1
    }
    frontend_scan_config_tree "$flat_config" "$prefix" || {
        rm -rf "$probe_dir"
        return 1
    }

    local probe_var="\$one_singbox_frontend_probe_${BASHPID}_${RANDOM}"
    probe_stream=$'stream {\n    map $ssl_preread_server_name '"$probe_var"$' {\n        default 127.0.0.1:55001;\n    }\n    server {\n        listen 127.0.0.1:55002;\n        ssl_preread on;\n        proxy_pass '"$probe_var"$';\n    }\n'
    if [[ $need_return == true ]]; then
        probe_stream+=$'    server {\n        listen 127.0.0.1:55003;\n        return "";\n    }\n'
    fi
    probe_stream+=$'}\n'

    if ((${#frontend_scan_stream_files[@]} == 0)); then
        frontend_write_append "$flat_config" "$probe_stream" "$candidate_config" || {
            rm -rf "$probe_dir"
            return 1
        }
    elif ((${#frontend_scan_stream_files[@]} == 1)); then
        frontend_write_insert_before_line "$flat_config" "${frontend_scan_stream_ends[0]}" "$probe_stream" "$candidate_config" || {
            rm -rf "$probe_dir"
            frontend_set_error nginx_candidate_failed 'Could not add the capability probe to the isolated Nginx candidate.'
            return 1
        }
    else
        rm -rf "$probe_dir"
        frontend_set_error nginx_config_unsupported 'More than one stream block prevents an isolated capability check.'
        return 1
    fi
    probe_output=$("$binary" -t -p "$prefix" -c "$candidate_config" 2>&1)
    if [[ $? != 0 ]]; then
        rm -rf "$probe_dir"
        case $probe_output in
        *'unknown directive "stream"'*) code=nginx_stream_missing ;;
        *'unknown directive "ssl_preread"'*) code=nginx_ssl_preread_missing ;;
        *'unknown directive "map"'*) code=nginx_stream_map_missing ;;
        *'unknown directive "proxy_pass"'*) code=nginx_stream_proxy_missing ;;
        *'unknown directive "return"'*) code=nginx_stream_return_missing ;;
        *) code=nginx_module_check_failed ;;
        esac
        frontend_set_error "$code" 'The full active configuration plus isolated Reality directives did not pass the active Nginx binary check.'
        return 1
    fi
    rm -rf "$probe_dir"
    frontend_nginx=$(jq -c --argjson return "$need_return" '.modules = {stream:true,ssl_preread:true,map:true,proxy:true,return:$return}' <<<"$frontend_nginx") || {
        frontend_set_error nginx_detection_failed 'Could not record the validated Nginx module capabilities.'
        return 1
    }
    return 0
}

frontend_scan_config_tree() {
    frontend_scan_stream_files=()
    frontend_scan_stream_starts=()
    frontend_scan_stream_ends=()
    frontend_scan_map_files=()
    frontend_scan_map_starts=()
    frontend_scan_map_ends=()
    frontend_scan_map_sources=()
    frontend_scan_map_targets=()
    frontend_scan_map_rule_files=()
    frontend_scan_map_rule_lines=()
    frontend_scan_map_rule_targets=()
    frontend_scan_map_rule_keys=()
    frontend_scan_map_rule_kinds=()
    frontend_scan_map_hostnames_targets=()
    frontend_scan_server_443=()
    frontend_scan_server_udp443=()
    frontend_scan_server_preread=()
    frontend_scan_server_proxy=()
    frontend_scan_configured_port_lists=()
    frontend_scan_server_addresses=()
    frontend_scan_server_ipv6only_off=()
    frontend_scan_http_443=()
    frontend_scan_include_parent=()
    frontend_scan_include_lines=()
    frontend_scan_include_starts=()
    frontend_scan_include_ends=()
    frontend_scan_include_contexts=()
    frontend_scan_include_patterns=()
    frontend_scan_include_edges=()
    frontend_scan_source_files=()
    frontend_scan_source_hashes=()
    declare -gA frontend_scan_active=()
    frontend_nginx_prefix=$2
    local config_file
    config_file=$(readlink -f "$1" 2>/dev/null) || config_file=$1
    frontend_scan_config_file "$config_file" top || return 1

    ((${#frontend_scan_http_443[@]} == 0)) || {
        frontend_set_error nginx_http_443_conflict "An HTTP server already listens on TCP 443 in ${frontend_scan_http_443[0]}"
        return 1
    }
    ((${#frontend_scan_stream_files[@]} <= 1)) || {
        frontend_set_error nginx_config_unsupported 'More than one Nginx stream block was found.'
        return 1
    }

    frontend_entry_type=new_stream
    frontend_entry_file=$config_file
    frontend_entry_line=
    frontend_entry_map_variable=
    frontend_entry_addresses=
    frontend_entry_ipv6only_off=0
    local compatible=0 server_count=0 server_is_compatible=0 map_index=0 server_index=0
    for ((map_index = 0; map_index < ${#frontend_scan_map_targets[@]}; map_index++)); do
        [[ ${frontend_scan_map_sources[$map_index]} == '$ssl_preread_server_name' ]] || continue
        ((compatible += 1))
        frontend_entry_file=${frontend_scan_map_files[$map_index]}
        frontend_entry_line=${frontend_scan_map_ends[$map_index]}
        frontend_entry_map_variable=${frontend_scan_map_targets[$map_index]}
    done
    for ((server_index = 0; server_index < ${#frontend_scan_server_443[@]}; server_index++)); do
        [[ ${frontend_scan_server_443[$server_index]} == 1 ]] || continue
        ((server_count += 1))
        if ((compatible == 1)) && [[ ${frontend_scan_server_preread[$server_index]} == 1 && ${frontend_scan_server_proxy[$server_index]} == "$frontend_entry_map_variable" ]]; then
            ((server_is_compatible += 1))
            frontend_entry_addresses=${frontend_scan_server_addresses[$server_index]}
            frontend_entry_ipv6only_off=${frontend_scan_server_ipv6only_off[$server_index]:-0}
        else
            frontend_set_error nginx_config_unsupported 'A TCP 443 stream listener is not the supported ssl_preread map-to-proxy structure.'
            return 1
        fi
    done
    if ((compatible > 1)); then
        frontend_set_error nginx_config_unsupported 'More than one stream map uses $ssl_preread_server_name.'
        return 1
    fi
    if ((server_count > 1)); then
        frontend_set_error nginx_config_unsupported 'More than one TCP 443 stream server was found.'
        return 1
    fi
    if ((server_count == 1 && server_is_compatible == 1)); then
        frontend_entry_type=existing_map
    elif ((server_count > 0)); then
        frontend_set_error nginx_config_unsupported 'The existing TCP 443 stream listener has no compatible Reality map.'
        return 1
    fi
    if ((${#frontend_scan_stream_files[@]} == 1)) && [[ $frontend_entry_type != existing_map ]]; then
        frontend_entry_type=empty_stream
        frontend_entry_file=${frontend_scan_stream_files[0]}
        frontend_entry_line=${frontend_scan_stream_ends[0]}
    fi
    if [[ $frontend_entry_type == existing_map ]]; then
        frontend_entry_line=${frontend_entry_line}
    fi
    return 0
}

frontend_managed_core_pid() {
    local pid=$1 main_pid args
    if [[ $is_systemd ]]; then
        main_pid=$(systemctl show -p MainPID --value "$is_core" 2>/dev/null) || return 1
        [[ $main_pid == "$pid" && $main_pid =~ ^[1-9][0-9]*$ ]]
        return $?
    fi
    if [[ $is_openrc ]]; then
        args=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
        [[ $args == *"$is_core_dir"* ]]
        return $?
    fi
    return 1
}

frontend_nginx_pid_is_managed() {
    local pid=$1 parent depth
    [[ $frontend_nginx_pid =~ ^[1-9][0-9]*$ && $pid =~ ^[1-9][0-9]*$ ]] || return 1
    for ((depth = 0; depth < 32; depth++)); do
        [[ $pid == "$frontend_nginx_pid" ]] && return 0
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null) || return 1
        parent=${parent//[[:space:]]/}
        [[ $parent =~ ^[1-9][0-9]*$ && $parent != "$pid" ]] || return 1
        pid=$parent
    done
    return 1
}

frontend_listener_addresses_overlap() {
    local wanted=${1//[\[\]]/} bound=${2//[\[\]]/} ipv6only_off=${3:-0} wanted_family bound_family
    [[ $wanted == '*' || $bound == '*' ]] && return 0
    [[ $wanted == *:* ]] && wanted_family=ipv6 || wanted_family=ipv4
    [[ $bound == *:* ]] && bound_family=ipv6 || bound_family=ipv4
    if [[ $wanted_family != "$bound_family" ]]; then
        [[ $ipv6only_off == 1 && ( $wanted == :: || $bound == :: ) ]] && return 0
        return 1
    fi
    if [[ $wanted == 0.0.0.0 || $wanted == :: || $bound == 0.0.0.0 || $bound == :: ]]; then
        return 0
    fi
    [[ $wanted == "$bound" ]]
}

frontend_read_tcp_listeners() {
    local output line state recv send local_address socket_address peer process port owner_pid owner_exe core_binary_real migration_direct_443=0
    local selected_range_known=0 address_match expected_address address_index
    local -a selected_addresses=() configured_addresses=() running_addresses=()
    frontend_error_code=
    frontend_error_message=
    declare -gA frontend_bound_ports=()
    declare -gA frontend_configured_ports=()
    frontend_bound_ports=()
    frontend_configured_ports=()
    frontend_running_443=0
    frontend_nginx_pid=$(jq -r '.pid' <<<"$frontend_nginx")
    frontend_nginx_binary_real=$(readlink -f "$(jq -r '.binary' <<<"$frontend_nginx")" 2>/dev/null) || frontend_nginx_binary_real=
    core_binary_real=$(readlink -f "$is_core_bin" 2>/dev/null) || core_binary_real=
    if [[ $frontend_profile ]] && jq -e '.enabled == true' <<<"$frontend_profile" >/dev/null; then
        mapfile -t selected_addresses < <(jq -r '.listen_addresses[]' <<<"$frontend_profile")
        IFS=, read -r -a configured_addresses <<<"${frontend_entry_addresses:-}"
        for address_index in "${!selected_addresses[@]}"; do
            [[ ${selected_addresses[$address_index]} == '*' ]] && selected_addresses[$address_index]=0.0.0.0
        done
        for address_index in "${!configured_addresses[@]}"; do
            [[ ${configured_addresses[$address_index]} == '*' ]] && configured_addresses[$address_index]=0.0.0.0
        done
        if [[ $(printf '%s\n' "${selected_addresses[@]}" | sort) != $(printf '%s\n' "${configured_addresses[@]}" | sort) ]]; then
            frontend_set_error nginx_listener_drift "Saved address range ${selected_addresses[*]} does not match active listener addresses ${configured_addresses[*]}"
            return 1
        fi
        selected_range_known=1
    elif [[ ${frontend_listener_range_selected:-0} == 1 ]]; then
        selected_addresses=("${frontend_listen_addresses[@]}")
        selected_range_known=1
    elif [[ ${frontend_entry_addresses:-} ]]; then
        IFS=, read -r -a selected_addresses <<<"$frontend_entry_addresses"
        for address_index in "${!selected_addresses[@]}"; do
            [[ ${selected_addresses[$address_index]} == '*' ]] && selected_addresses[$address_index]=0.0.0.0
        done
        selected_range_known=1
    fi
    [[ $frontend_nginx_binary_real ]] || {
        frontend_set_error nginx_listener_check_failed 'Could not identify the active Nginx binary for listener ownership checks.'
        return 1
    }
    output=$(ss -Hlnpt 2>/dev/null) || {
        frontend_set_error listener_check_unavailable 'Could not inspect active TCP listeners with ss.'
        return 1
    }
    while read -r state recv send local_address peer process; do
        [[ $local_address ]] || continue
        port=${local_address##*:}
        [[ $port =~ ^[0-9]+$ ]] || continue
        frontend_bound_ports[$port]=1
        [[ $port == 443 ]] || continue
        if [[ ${frontend_allow_unknown_listener_range:-0} == 1 && $selected_range_known == 0 ]]; then
            continue
        fi
        socket_address=${local_address%:*}
        socket_address=${socket_address#\[}
        socket_address=${socket_address%\]}
        address_match=0
        if [[ $selected_range_known == 0 ]]; then
            address_match=1
        else
            for expected_address in "${selected_addresses[@]}"; do
                if frontend_listener_addresses_overlap "$expected_address" "$socket_address" "${frontend_entry_ipv6only_off:-0}"; then
                    address_match=1
                    break
                fi
            done
        fi
        [[ $address_match == 1 ]] || continue
        [[ $process ]] || {
            frontend_set_error tcp_443_owner_unknown "TCP 443 socket $socket_address is occupied, but ss did not report the owning process."
            return 1
        }
        local found_owner=0 owner_is_nginx=1 owner_is_core=1 owner_is_managed_core=1
        while [[ $process =~ pid=([0-9]+) ]]; do
            owner_pid=${BASH_REMATCH[1]}
            found_owner=1
            owner_exe=$(readlink -f "/proc/$owner_pid/exe" 2>/dev/null) || owner_exe=
            [[ $owner_exe == "$frontend_nginx_binary_real" ]] && frontend_nginx_pid_is_managed "$owner_pid" || owner_is_nginx=0
            [[ $core_binary_real && $owner_exe == "$core_binary_real" ]] || owner_is_core=0
            if [[ $core_binary_real && $owner_exe == "$core_binary_real" ]] && ! frontend_managed_core_pid "$owner_pid"; then
                owner_is_managed_core=0
            fi
            process=${process#*"pid=$owner_pid"}
        done
        if [[ $found_owner == 1 && $owner_is_core == 1 && $owner_is_managed_core == 1 && ( ${frontend_migration_active:-0} == 1 || ${frontend_migration_handoff:-0} == 1 ) ]]; then
            migration_direct_443=1
            continue
        fi
        [[ $found_owner == 1 && $owner_is_nginx == 1 ]] || {
            frontend_set_error tcp_443_port_conflict "TCP 443 is owned by a process outside the selected Nginx instance: $socket_address:443"
            return 1
        }
        frontend_running_443=1
        running_addresses+=("$socket_address")
    done <<<"$output"

    local configured_443=0 port_list configured_port
    for port_list in "${frontend_scan_configured_port_lists[@]}"; do
        IFS=, read -r -a frontend_tmp_configured_ports <<<"$port_list"
        for configured_port in "${frontend_tmp_configured_ports[@]}"; do
            [[ $configured_port =~ ^[0-9]+$ ]] || continue
            frontend_configured_ports[$configured_port]=1
            [[ $configured_port == 443 ]] && configured_443=1
        done
    done
    if [[ $configured_443 == 1 && $frontend_running_443 != 1 && $migration_direct_443 != 1 && ${frontend_migration_handoff:-0} != 1 ]]; then
        frontend_set_error nginx_listener_missing 'Nginx configuration contains a TCP 443 listener, but the selected service does not own a running TCP 443 socket.'
        return 1
    fi
    if [[ $configured_443 == 1 && $selected_range_known == 1 && $migration_direct_443 != 1 && ${frontend_migration_handoff:-0} != 1 ]]; then
        for expected_address in "${selected_addresses[@]}"; do
            address_match=0
            for socket_address in "${running_addresses[@]}"; do
                if frontend_listener_addresses_overlap "$expected_address" "$socket_address" "${frontend_entry_ipv6only_off:-0}"; then
                    address_match=1
                    break
                fi
            done
            [[ $address_match == 1 ]] || {
                frontend_set_error nginx_listener_missing "The selected Nginx service is not listening on configured address $expected_address at TCP 443."
                return 1
            }
        done
    fi
    if [[ $configured_443 == 0 && $frontend_running_443 == 1 ]]; then
        frontend_set_error nginx_listener_drift 'The selected Nginx service owns TCP 443, but its checked configuration has no TCP 443 listener.'
        return 1
    fi
    return 0
}

frontend_refresh_detection() {
    local config_file prefix needs_return
    frontend_detect_nginx_service || return 1
    config_file=$(jq -r '.config' <<<"$frontend_nginx")
    prefix=$(jq -r '.prefix' <<<"$frontend_nginx")
    frontend_scan_config_tree "$config_file" "$prefix" || return 1
    needs_return=true
    [[ $frontend_entry_type == existing_map ]] && needs_return=false
    if [[ $frontend_profile ]] && jq -e '.enabled == true and .nginx.return_required == true' <<<"$frontend_profile" >/dev/null; then
        needs_return=true
    fi
    frontend_probe_nginx_modules "$needs_return" || return 1
    frontend_scan_config_tree "$config_file" "$prefix" || return 1
    frontend_read_tcp_listeners || return 1
    frontend_nginx=$(jq -c \
        --arg entry_type "$frontend_entry_type" \
        --arg entry_file "$frontend_entry_file" \
        --argjson entry_line "${frontend_entry_line:-0}" \
        --arg map_variable "$frontend_entry_map_variable" \
        --argjson listener_443 "$frontend_running_443" \
        '. + {entry_type:$entry_type,entry_file:$entry_file,entry_line:$entry_line,map_variable:$map_variable,listener_443:$listener_443}' \
        <<<"$frontend_nginx") || {
        frontend_set_error nginx_detection_failed 'Could not serialize the checked Nginx configuration structure.'
        return 1
    }
    if [[ $frontend_profile ]] && jq -e '.enabled == true' <<<"$frontend_profile" >/dev/null; then
        local saved_identity current_identity
        saved_identity=$(jq -c '.nginx | {service,service_kind,binary,config,prefix,entry_type,entry_file,map_variable}' <<<"$frontend_profile")
        current_identity=$(jq -c '{service,service_kind,binary,config,prefix,entry_type,entry_file,map_variable}' <<<"$frontend_nginx")
        frontend_nginx=$(jq -c --argjson return_required "$(jq -c '.nginx.return_required // false' <<<"$frontend_profile")" '. + {return_required:$return_required}' <<<"$frontend_nginx")
        if [[ $saved_identity != "$current_identity" ]]; then
            frontend_set_error nginx_instance_drift 'The active Nginx instance or supported entry no longer matches the saved frontend profile.'
            return 1
        fi
    fi
    return 0
}

frontend_lock_state() {
    local state_dir="$is_core_dir/.frontend-state"
    if [[ ${frontend_lock_depth:-0} -gt 0 && ${frontend_lock_fd:-} ]]; then
        frontend_lock_depth=$((frontend_lock_depth + 1))
        return 0
    fi
    command -v flock >/dev/null 2>&1 || {
        frontend_set_error lock_unavailable 'The flock utility is required to coordinate frontend changes.'
        return 1
    }
    [[ ! -L $state_dir ]] || {
        frontend_set_error state_unwritable 'The frontend state directory must not be a symlink.'
        return 1
    }
    mkdir -p "$state_dir" || {
        frontend_set_error state_unwritable "Could not create frontend state directory $state_dir."
        return 1
    }
    [[ ! -L $state_dir && -d $state_dir ]] || {
        frontend_set_error state_unwritable 'The frontend state directory is not a safe directory.'
        return 1
    }
    chmod 700 "$state_dir" || {
        frontend_set_error state_unwritable "Could not secure frontend state directory $state_dir."
        return 1
    }
    exec {frontend_lock_fd}>"$state_dir/lock" || {
        frontend_set_error state_unwritable 'Could not open the frontend transaction lock.'
        return 1
    }
    flock -n "$frontend_lock_fd" || {
        exec {frontend_lock_fd}>&-
        frontend_set_error operation_in_progress 'Another frontend operation is already in progress.'
        return 1
    }
    frontend_lock_depth=1
}

frontend_unlock_state() {
    if [[ $frontend_lock_fd ]]; then
        if [[ ${frontend_lock_depth:-1} -gt 1 ]]; then
            frontend_lock_depth=$((frontend_lock_depth - 1))
            return 0
        fi
        flock -u "$frontend_lock_fd" 2>/dev/null || :
        exec {frontend_lock_fd}>&-
        frontend_lock_fd=
        frontend_lock_depth=0
    fi
}

frontend_pending_change() {
    case ${frontend_phase:-idle} in
        prepared | backend_applied | frontend_applied | verified | rolling_back | recovery_required)
        frontend_set_error recovery_required "A frontend transaction is in phase $frontend_phase. Run frontend recover before changing it."
        return 1
        ;;
    esac
    return 0
}

frontend_choose_addresses() {
    local ipv4 ipv6 choice
    local -a options=()
    frontend_listener_range_selected=0
    command -v ip >/dev/null 2>&1 || {
        frontend_set_error listen_addresses_unavailable 'The ip utility is required to determine available address families.'
        return 1
    }
    ipv4=$(ip -o -4 addr show scope global 2>/dev/null) || ipv4=
    ipv6=$(ip -o -6 addr show scope global 2>/dev/null) || ipv6=
    [[ $ipv4 ]] && options+=(ipv4)
    [[ $ipv6 ]] && options+=(ipv6)
    ((${#options[@]} > 0)) || {
        frontend_set_error listen_addresses_unavailable 'No global IPv4 or IPv6 address is configured on this host.'
        return 1
    }
    printf '\n选择 443 监听范围：\n'
    local index=1
    for choice in "${options[@]}"; do
        printf '%s) %s\n' "$index" "$([[ $choice == ipv4 ]] && printf 'IPv4 所有地址' || printf 'IPv6 所有地址')"
        ((index += 1))
    done
    if ((${#options[@]} == 2)); then
        printf '3) IPv4 和 IPv6 所有地址\n'
    fi
    read -r -p '请选择: ' choice || {
        frontend_set_error listen_addresses_required 'Choose an explicit IPv4, IPv6, or dual-stack listener range.'
        return 1
    }
    frontend_listen_addresses=()
    case $choice in
    1) [[ ${options[0]} == ipv4 ]] && frontend_listen_addresses+=(0.0.0.0) || frontend_listen_addresses+=(::) ;;
    2)
        if ((${#options[@]} == 2)); then
            [[ ${options[1]} == ipv6 ]] || {
                frontend_set_error listen_addresses_invalid 'The selected address family is not available.'
                return 1
            }
            frontend_listen_addresses+=(::)
        else
            frontend_set_error listen_addresses_invalid 'The selected address family is not available.'
            return 1
        fi
        ;;
    3)
        ((${#options[@]} == 2)) || {
            frontend_set_error listen_addresses_invalid 'Dual-stack listening requires both IPv4 and IPv6.'
            return 1
        }
        frontend_listen_addresses+=(0.0.0.0 ::)
        ;;
    *)
        frontend_set_error listen_addresses_invalid 'Select one of the listed listener ranges.'
        return 1
        ;;
    esac
    printf '监听范围：%s\n' "$(IFS=,; echo "${frontend_listen_addresses[*]}")"
    frontend_listener_range_selected=1
    return 0
}

frontend_choose_aux_port() {
    local file port
    local -a config_files=()
    declare -gA frontend_used_ports=()
    frontend_used_ports=()
    for port in "${!frontend_bound_ports[@]}" "${!frontend_configured_ports[@]}"; do
        [[ $port =~ ^[0-9]+$ ]] && frontend_used_ports[$port]=1
    done
    [[ -f $is_config_json ]] && config_files+=("$is_config_json")
    shopt -s nullglob
    config_files+=("$is_conf_dir"/*.json)
    shopt -u nullglob
    for file in "${config_files[@]}"; do
        [[ -f $file && ! -L $file ]] || continue
        jq -e 'type == "object" and ((.inbounds // []) | type == "array")' "$file" >/dev/null 2>&1 || {
            frontend_set_error singbox_config_unreadable "Cannot safely inspect configured sing-box listeners in $file"
            return 1
        }
        while IFS= read -r port; do
            [[ $port =~ ^[0-9]+$ ]] && frontend_used_ports[$port]=1
        done < <(frontend_config_tcp_ports "$file")
    done
    for ((port = 49152; port <= 65535; port++)); do
        [[ ${frontend_used_ports[$port]+yes} ]] || {
            frontend_aux_port=$port
            return 0
        }
    done
    frontend_set_error auxiliary_port_unavailable 'No free TCP port is available for the local reject service.'
    return 1
}

frontend_render_stream_body() {
    local map_file=$1 map_variable=$2 aux_port=$3 indent=$4 address
    local nested="${indent}    " listen_lines=
    for address in "${frontend_listen_addresses[@]}"; do
        if [[ $address == :: ]]; then
            listen_lines+="${nested}listen [::]:443 ipv6only=on;"$'\n'
        else
            listen_lines+="${nested}listen ${address}:443;"$'\n'
        fi
    done
    printf '%smap $ssl_preread_server_name %s {\n' "$indent" "$map_variable"
    printf '%s    default 127.0.0.1:%s;\n' "$indent" "$aux_port"
    printf '%s    include "%s";\n' "$indent" "$map_file"
    printf '%s}\n' "$indent"
    printf '%sserver {\n' "$indent"
    printf '%s' "$listen_lines"
    printf '%s    ssl_preread on;\n' "$indent"
    printf '%s    preread_timeout 10s;\n' "$indent"
    printf '%s    proxy_connect_timeout 5s;\n' "$indent"
    printf '%s    proxy_timeout 1h;\n' "$indent"
    printf '%s    proxy_pass %s;\n' "$indent" "$map_variable"
    printf '%s}\n' "$indent"
    printf '%sserver {\n' "$indent"
    printf '%s    listen 127.0.0.1:%s;\n' "$indent" "$aux_port"
    printf '%s    return "";\n' "$indent"
    printf '%s}\n' "$indent"
}

frontend_marker_block() {
    local kind=$1 final_target=$2 map_file=$3 map_variable=$4 aux_port=$5 address
    local marker_begin='# one-singbox-frontend:begin' marker_end='# one-singbox-frontend:end'
    case $kind in
    new_stream)
        printf '%s\ninclude "%s";\n%s\n' "$marker_begin" "$final_target" "$marker_end"
        ;;
    existing_map)
        printf '    %s\n    include "%s";\n    %s\n' "$marker_begin" "$final_target" "$marker_end"
        ;;
    empty_stream)
        printf '    %s\n' "$marker_begin"
        frontend_render_stream_body "$map_file" "$map_variable" "$aux_port" '    '
        printf '    %s\n' "$marker_end"
        ;;
    esac
}

frontend_atomic_write() {
    local path=$1 content=$2 mode=${3:-600} temp="${1}.tmp.$$"
    [[ ! -L $path ]] || return 1
    printf '%s' "$content" >"$temp" || return 1
    chmod "$mode" "$temp" || {
        rm -f "$temp"
        return 1
    }
    mv -f -- "$temp" "$path"
}

frontend_txn_add_change() {
    local path=$1 candidate=$2 role=$3 new_mode=${4:-644}
    local index=${#frontend_txn_paths[@]} before_exists=false after_exists=false before_sha= after_sha= before_file= after_file= before_mode=600 after_mode=$new_mode before_owner=0:0 after_owner=0:0
    [[ $path == /* && $path != *$'\n'* && $path != *$'\t'* ]] || {
        frontend_set_error transaction_path_invalid "Transaction target is not a safe absolute path: $path"
        return 1
    }
    if [[ -L $path ]]; then
        frontend_set_error transaction_path_invalid "Transaction target must not be a symlink: $path"
        return 1
    fi
    if [[ -e $path ]]; then
        [[ -f $path ]] || {
            frontend_set_error transaction_path_invalid "Transaction target is not a regular file: $path"
            return 1
        }
        before_exists=true
        before_sha=$(sha256sum "$path" | awk '{print $1}') || return 1
        before_mode=$(stat -c '%a' "$path") || return 1
        before_owner=$(stat -c '%u:%g' "$path") || return 1
        before_file="$frontend_txn_dir/before.$index"
        cp -p -- "$path" "$before_file" || return 1
    fi
    if [[ $candidate ]]; then
        [[ -f $candidate && ! -L $candidate ]] || {
            frontend_set_error transaction_candidate_missing "Candidate file is missing or unsafe for $path"
            return 1
        }
        after_exists=true
        after_sha=$(sha256sum "$candidate" | awk '{print $1}') || return 1
        after_file="$frontend_txn_dir/after.$index"
        cp -p -- "$candidate" "$after_file" || return 1
        if [[ $before_exists == true ]]; then
            after_mode=$before_mode
            after_owner=$before_owner
        fi
        chmod "$after_mode" "$after_file" || return 1
        chown "$after_owner" "$after_file" || return 1
    fi
    frontend_txn_files=$(jq -cn \
        --argjson files "$frontend_txn_files" \
        --arg path "$path" \
        --arg role "$role" \
        --argjson before_exists "$before_exists" \
        --arg before_sha "$before_sha" \
        --arg before_file "$before_file" \
        --arg before_mode "$before_mode" \
        --arg before_owner "$before_owner" \
        --argjson after_exists "$after_exists" \
        --arg after_sha "$after_sha" \
        --arg after_file "$after_file" \
        --arg after_mode "$after_mode" \
        --arg after_owner "$after_owner" \
        '$files + [{path:$path,role:$role,before_exists:$before_exists,before_sha256:$before_sha,before_file:$before_file,before_mode:$before_mode,before_owner:$before_owner,after_exists:$after_exists,after_sha256:$after_sha,after_file:$after_file,after_mode:$after_mode,after_owner:$after_owner}]') || return 1
    frontend_txn_paths+=("$path")
}

frontend_txn_write_record() {
    local phase=$1 transaction_file="$is_core_dir/.frontend-state/transaction.json" json
    json=$(jq -cn \
        --arg action "$frontend_txn_action" \
        --arg phase "$phase" \
        --arg dir "$frontend_txn_dir" \
        --argjson files "$frontend_txn_files" \
        --argjson guards "$frontend_txn_guards" \
        --argjson nginx "$frontend_nginx" \
        '{schema_version:1,action:$action,phase:$phase,dir:$dir,files:$files,guards:$guards,nginx:$nginx,nginx_rollback_pending:false,backend_rollback_pending:false}') || return 1
    frontend_atomic_write "$transaction_file" "$json"$'\n' 600
}

frontend_txn_set_phase() {
    local phase=$1 transaction_file="$is_core_dir/.frontend-state/transaction.json" json
    json=$(jq -c --arg phase "$phase" '.phase=$phase' "$transaction_file") || return 1
    frontend_atomic_write "$transaction_file" "$json"$'\n' 600 || return 1
    frontend_phase=$phase
}

frontend_txn_set_nginx_rollback_pending() {
    local pending=$1 transaction_file="$is_core_dir/.frontend-state/transaction.json" json
    json=$(jq -c --argjson pending "$pending" '.nginx_rollback_pending=$pending' "$transaction_file") || return 1
    frontend_atomic_write "$transaction_file" "$json"$'\n' 600
}

frontend_txn_set_backend_rollback_pending() {
    local pending=$1 transaction_file="$is_core_dir/.frontend-state/transaction.json" json
    json=$(jq -c --argjson pending "$pending" '.backend_rollback_pending=$pending' "$transaction_file") || return 1
    frontend_atomic_write "$transaction_file" "$json"$'\n' 600
}

frontend_record_file_state() {
    local record=$1 path=$2 expected_exists=$3 expected_sha=$4 current_sha expected_mode expected_owner actual_mode actual_owner
    if [[ -L $path ]]; then
        return 1
    fi
    if [[ $expected_exists == true ]]; then
        [[ -f $path ]] || return 1
        current_sha=$(sha256sum "$path" | awk '{print $1}') || return 1
        expected_mode=$(jq -r '.before_mode' <<<"$record")
        expected_owner=$(jq -r '.before_owner' <<<"$record")
        actual_mode=$(stat -c '%a' "$path") || return 1
        actual_owner=$(stat -c '%u:%g' "$path") || return 1
        [[ $current_sha == "$expected_sha" && $actual_mode == "$expected_mode" && $actual_owner == "$expected_owner" ]]
    else
        [[ ! -e $path ]]
    fi
}

frontend_txn_apply_record() {
    local record=$1 path after_exists before_exists before_sha before_file after_file after_sha after_mode after_owner temp
    path=$(jq -r '.path' <<<"$record")
    before_exists=$(jq -r '.before_exists' <<<"$record")
    before_sha=$(jq -r '.before_sha256' <<<"$record")
    if ! frontend_record_file_state "$record" "$path" "$before_exists" "$before_sha"; then
        frontend_set_error config_drift "File changed after candidate validation; refusing to replace $path"
        return 1
    fi
    after_exists=$(jq -r '.after_exists' <<<"$record")
    if [[ $after_exists == false ]]; then
        rm -f -- "$path" || {
            frontend_set_error file_apply_failed "Could not remove $path"
            return 1
        }
        return 0
    fi
    after_file=$(jq -r '.after_file' <<<"$record")
    after_sha=$(jq -r '.after_sha256' <<<"$record")
    after_mode=$(jq -r '.after_mode' <<<"$record")
    after_owner=$(jq -r '.after_owner' <<<"$record")
    mkdir -p -- "$(dirname -- "$path")" || {
        frontend_set_error file_apply_failed "Could not create the directory for $path"
        return 1
    }
    [[ ! -L $path ]] || {
        frontend_set_error config_drift "File became a symlink before replacement: $path"
        return 1
    }
    temp="${path}.one-singbox-tmp.$$"
    [[ ! -e $temp && ! -L $temp ]] || {
        frontend_set_error file_apply_failed "Temporary replacement path already exists: $temp"
        return 1
    }
    cp -p -- "$after_file" "$temp" && chmod "$after_mode" "$temp" && chown "$after_owner" "$temp" || {
        rm -f "$temp"
        frontend_set_error file_apply_failed "Could not stage replacement for $path"
        return 1
    }
    mv -f -- "$temp" "$path" || {
        rm -f "$temp"
        frontend_set_error file_apply_failed "Could not atomically replace $path"
        return 1
    }
    [[ $(sha256sum "$path" | awk '{print $1}') == "$after_sha" ]] || {
        frontend_set_error file_apply_failed "Replacement fingerprint does not match for $path"
        return 1
    }
}

frontend_worker_pids() {
    local nginx=$1 expected_binary expected_real pid args process_real
    expected_binary=$(jq -r '.binary' <<<"$nginx") || return 1
    frontend_nginx_pid=$(jq -r '.pid' <<<"$nginx")
    [[ $frontend_nginx_pid =~ ^[1-9][0-9]*$ ]] || return 1
    expected_real=$(readlink -f "$expected_binary" 2>/dev/null) || return 1
    while read -r pid args; do
        [[ $pid =~ ^[0-9]+$ && $args == *'nginx: worker process'* ]] || continue
        process_real=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || continue
        [[ $process_real == "$expected_real" ]] && frontend_nginx_pid_is_managed "$pid" && printf '%s\n' "$pid"
    done < <(ps -eo pid=,args= 2>/dev/null)
}

frontend_reload_and_confirm() {
    local nginx=$1 before after attempt pid found binary config prefix service service_kind
    binary=$(jq -r '.binary' <<<"$nginx")
    config=$(jq -r '.config' <<<"$nginx")
    prefix=$(jq -r '.prefix' <<<"$nginx")
    service=$(jq -r '.service' <<<"$nginx")
    service_kind=$(jq -r '.service_kind' <<<"$nginx")
    "$binary" -t -p "$prefix" -c "$config" >/dev/null 2>&1 || {
        frontend_set_error nginx_config_invalid 'The applied Nginx configuration failed its full syntax check.'
        return 1
    }
    before=$(frontend_worker_pids "$nginx")
    [[ $before ]] || {
        frontend_set_error nginx_worker_unverified 'Could not identify an existing Nginx worker before reload.'
        return 1
    }
    case $service_kind in
    systemd)
        systemctl reload "$service" >/dev/null 2>&1 || {
            frontend_set_error nginx_reload_failed 'The Nginx service reload command failed.'
            return 1
        }
        ;;
    openrc)
        rc-service "$service" reload >/dev/null 2>&1 || {
            frontend_set_error nginx_reload_failed 'The Nginx OpenRC reload command failed.'
            return 1
        }
        ;;
    *)
        frontend_set_error nginx_reload_unavailable 'The selected Nginx service has no supported reload target.'
        return 1
        ;;
    esac
    for ((attempt = 0; attempt < 20; attempt++)); do
        after=$(frontend_worker_pids "$nginx")
        while IFS= read -r pid; do
            [[ $pid ]] || continue
            if ! grep -qxF "$pid" <<<"$before"; then
                return 0
            fi
        done <<<"$after"
        sleep 0.25
    done
    frontend_set_error nginx_worker_unverified 'Nginx did not start a new worker within the bounded reload wait.'
    return 1
}

frontend_txn_validate_guards() {
    local records record path expected actual
    records=$(jq -c '.guards[]?' "$is_core_dir/.frontend-state/transaction.json") || return 1
    while IFS= read -r record; do
        [[ $record ]] || continue
        path=$(jq -r '.path' <<<"$record")
        expected=$(jq -r '.sha256' <<<"$record")
        [[ -f $path && ! -L $path ]] || {
            frontend_set_error config_drift "Nginx configuration source disappeared or changed type during recovery: $path"
            return 1
        }
        actual=$(sha256sum "$path" | awk '{print $1}') || return 1
        [[ $actual == "$expected" ]] || {
            frontend_set_error config_drift "Nginx configuration source changed during the transaction: $path"
            return 1
        }
    done <<<"$records"
}

frontend_txn_validate_manifest() {
    local transaction_file="$is_core_dir/.frontend-state/transaction.json" state_dir="$is_core_dir/.frontend-state"
    local txn_dir config entry_file project_dir binary prefix
    local index record path role before_exists before_sha before_file before_mode before_owner after_exists after_sha after_file after_mode after_owner actual
    local guard expected
    local -a file_records=() guard_records=()
    local -A seen_paths=()
    jq -e '
        .schema_version == 1 and
        (.action == "enable" or .action == "disable" or .action == "bind" or .action == "node") and
        (.phase == "prepared" or .phase == "backend_applied" or .phase == "frontend_applied" or .phase == "verified" or .phase == "rolling_back" or .phase == "recovery_required") and
        ((.nginx_rollback_pending == null) or (.nginx_rollback_pending | type == "boolean")) and
        ((.backend_rollback_pending == null) or (.backend_rollback_pending | type == "boolean")) and
        (.files | type == "array" and length > 0) and
        (.guards | type == "array") and
        (.nginx | type == "object" and
            (.binary | type == "string" and startswith("/")) and
            (.config | type == "string" and startswith("/")) and
            (.entry_file | type == "string" and startswith("/")) and
            (.prefix | type == "string" and startswith("/")) and
            ((.service_kind == "systemd" and .service == "nginx.service") or (.service_kind == "openrc" and .service == "nginx")))
    ' "$transaction_file" >/dev/null 2>&1 || {
        frontend_set_error transaction_corrupt 'The frontend transaction record is invalid.'
        return 1
    }
    [[ ! -L $state_dir && -d $state_dir ]] || {
        frontend_set_error transaction_corrupt 'The frontend transaction state directory is missing or unsafe.'
        return 1
    }
    txn_dir=$(jq -r '.dir' "$transaction_file")
    [[ $txn_dir == "$state_dir"/txn.* && ! -L $txn_dir && -d $txn_dir ]] || {
        frontend_set_error transaction_corrupt 'The frontend transaction backup directory is outside its private state directory.'
        return 1
    }
    config=$(jq -r '.nginx.config' "$transaction_file")
    entry_file=$(jq -r '.nginx.entry_file' "$transaction_file")
    binary=$(jq -r '.nginx.binary' "$transaction_file")
    prefix=$(jq -r '.nginx.prefix' "$transaction_file")
    [[ -x $binary && $binary == /* && $prefix == /* ]] || {
        frontend_set_error transaction_corrupt 'The saved Nginx executable or prefix is invalid.'
        return 1
    }
    project_dir="$(dirname -- "$config")/one-singbox"
    mapfile -t file_records < <(jq -c '.files[]' "$transaction_file")
    for index in "${!file_records[@]}"; do
        record=${file_records[$index]}
        path=$(jq -r '.path // empty' <<<"$record")
        role=$(jq -r '.role // empty' <<<"$record")
        before_exists=$(jq -r '.before_exists' <<<"$record")
        before_sha=$(jq -r '.before_sha256 // empty' <<<"$record")
        before_file=$(jq -r '.before_file // empty' <<<"$record")
        before_mode=$(jq -r '.before_mode // empty' <<<"$record")
        before_owner=$(jq -r '.before_owner // empty' <<<"$record")
        after_exists=$(jq -r '.after_exists' <<<"$record")
        after_sha=$(jq -r '.after_sha256 // empty' <<<"$record")
        after_file=$(jq -r '.after_file // empty' <<<"$record")
        after_mode=$(jq -r '.after_mode // empty' <<<"$record")
        after_owner=$(jq -r '.after_owner // empty' <<<"$record")
        [[ $path == /* && $path != *$'\n'* && $path != *$'\t'* && ! ${seen_paths[$path]+yes} ]] || {
            frontend_set_error transaction_corrupt 'The frontend transaction contains an invalid or duplicate target path.'
            return 1
        }
        seen_paths[$path]=1
        case $role in
        profile)
            [[ $path == "$is_core_dir/frontend.json" ]] || {
                frontend_set_error transaction_corrupt 'The frontend transaction profile target is outside the frontend state.'
                return 1
            }
            ;;
        nginx_config)
            [[ $path == "$config" || $path == "$entry_file" ]] || {
                frontend_set_error transaction_corrupt 'The frontend transaction Nginx config target does not match its saved instance.'
                return 1
            }
            ;;
        project_file)
            [[ $path == "$project_dir/reality-map.conf" || $path == "$project_dir/stream.conf" ]] || {
                frontend_set_error transaction_corrupt 'The frontend transaction project file target is outside its managed Nginx directory.'
                return 1
            }
            ;;
        backend_config)
            [[ $path == "$is_config_json" || $path == "$is_conf_dir"/*.json || $path == "$is_conf_dir"/.quan-meta/*.meta.json ]] || {
                frontend_set_error transaction_corrupt 'The frontend transaction backend target is outside node, metadata, or shared-config files.'
                return 1
            }
            ;;
        node_metadata)
            [[ $path == "$is_conf_dir"/.quan-meta/*.meta.json ]] || {
                frontend_set_error transaction_corrupt 'The frontend transaction metadata target is outside node metadata.'
                return 1
            }
            ;;
        *)
            frontend_set_error transaction_corrupt 'The frontend transaction contains an unknown file role.'
            return 1
            ;;
        esac
        [[ ! -L $path && ( $before_exists == true || $before_exists == false ) && ( $after_exists == true || $after_exists == false ) && $before_mode =~ ^[0-7]{3,4}$ && $after_mode =~ ^[0-7]{3,4}$ && $before_owner =~ ^[0-9]+:[0-9]+$ && $after_owner =~ ^[0-9]+:[0-9]+$ ]] || {
            frontend_set_error transaction_corrupt "The frontend transaction metadata is invalid for $path."
            return 1
        }
        if [[ $before_exists == true ]]; then
            [[ $before_sha =~ ^[0-9a-f]{64}$ && $before_file == "$txn_dir/before.$index" && -f $before_file && ! -L $before_file ]] || {
                frontend_set_error transaction_corrupt "The frontend transaction backup is missing or unsafe for $path."
                return 1
            }
            actual=$(sha256sum "$before_file" | awk '{print $1}') || return 1
            [[ $actual == "$before_sha" ]] || {
                frontend_set_error transaction_corrupt "The frontend transaction backup fingerprint is invalid for $path."
                return 1
            }
        else
            [[ -z $before_sha && -z $before_file ]] || {
                frontend_set_error transaction_corrupt "The frontend transaction has unexpected before-state data for $path."
                return 1
            }
        fi
        if [[ $after_exists == true ]]; then
            [[ $after_sha =~ ^[0-9a-f]{64}$ && $after_file == "$txn_dir/after.$index" && -f $after_file && ! -L $after_file ]] || {
                frontend_set_error transaction_corrupt "The frontend transaction candidate is missing or unsafe for $path."
                return 1
            }
            actual=$(sha256sum "$after_file" | awk '{print $1}') || return 1
            [[ $actual == "$after_sha" ]] || {
                frontend_set_error transaction_corrupt "The frontend transaction candidate fingerprint is invalid for $path."
                return 1
            }
        else
            [[ -z $after_sha && -z $after_file ]] || {
                frontend_set_error transaction_corrupt "The frontend transaction has unexpected after-state data for $path."
                return 1
            }
        fi
    done
    mapfile -t guard_records < <(jq -c '.guards[]' "$transaction_file")
    for guard in "${guard_records[@]}"; do
        path=$(jq -r '.path // empty' <<<"$guard")
        expected=$(jq -r '.sha256 // empty' <<<"$guard")
        [[ $path == /* && $path != *$'\n'* && $path != *$'\t'* && $expected =~ ^[0-9a-f]{64}$ && ! ${seen_paths[$path]+yes} ]] || {
            frontend_set_error transaction_corrupt 'The frontend transaction contains an invalid guard.'
            return 1
        }
        seen_paths[$path]=1
    done
    return 0
}

frontend_txn_restore_record_before() {
    local record=$1 path before_exists before_sha before_file before_mode before_owner after_exists after_sha after_mode after_owner current_exists current_sha current_mode current_owner temp
    path=$(jq -r '.path' <<<"$record")
    before_exists=$(jq -r '.before_exists' <<<"$record")
    before_sha=$(jq -r '.before_sha256' <<<"$record")
    before_mode=$(jq -r '.before_mode' <<<"$record")
    before_owner=$(jq -r '.before_owner' <<<"$record")
    after_exists=$(jq -r '.after_exists' <<<"$record")
    after_sha=$(jq -r '.after_sha256' <<<"$record")
    after_mode=$(jq -r '.after_mode' <<<"$record")
    after_owner=$(jq -r '.after_owner' <<<"$record")
    current_exists=false
    [[ -e $path ]] && current_exists=true
    current_sha=
    current_mode=
    current_owner=
    if [[ $current_exists == true ]]; then
        current_sha=$(sha256sum "$path" | awk '{print $1}') || return 1
        current_mode=$(stat -c '%a' "$path") || return 1
        current_owner=$(stat -c '%u:%g' "$path") || return 1
    fi
    if [[ $current_exists == "$before_exists" && ( $before_exists == false || ( $current_sha == "$before_sha" && $current_mode == "$before_mode" && $current_owner == "$before_owner" ) ) ]]; then
        return 0
    fi
    [[ $current_exists == "$after_exists" && ( $after_exists == false || ( $current_sha == "$after_sha" && $current_mode == "$after_mode" && $current_owner == "$after_owner" ) ) ]] || {
        frontend_set_error config_drift "File changed during frontend recovery; refusing to overwrite $path"
        return 1
    }
    if [[ $before_exists == true ]]; then
        before_file=$(jq -r '.before_file' <<<"$record")
        mkdir -p -- "$(dirname -- "$path")" || return 1
        temp="${path}.one-singbox-recover.$$"
        cp -p -- "$before_file" "$temp" && chmod "$before_mode" "$temp" && chown "$before_owner" "$temp" && mv -f -- "$temp" "$path" || {
            rm -f "$temp"
            frontend_set_error recovery_failed "Could not restore $path from its transaction backup."
            return 1
        }
    else
        rm -f -- "$path" || {
            frontend_set_error recovery_failed "Could not remove the transaction-created file $path."
            return 1
        }
    fi
}

frontend_txn_rollback() {
    local transaction_file="$is_core_dir/.frontend-state/transaction.json" record path role before_exists before_sha before_mode before_owner after_exists after_sha after_mode after_owner current_sha current_mode current_owner current_exists applied_nginx=false applied_backend=false nginx_rollback_pending backend_rollback_pending nginx_config nginx_prefix index
    local -a file_records=()
    [[ -f $transaction_file && ! -L $transaction_file ]] || {
        frontend_set_error transaction_corrupt 'The frontend transaction record is unavailable for recovery.'
        return 1
    }
    frontend_txn_validate_manifest || return 1
    frontend_nginx=$(jq -c '.nginx' "$transaction_file") || return 1
    nginx_rollback_pending=$(jq -r '.nginx_rollback_pending // false' "$transaction_file") || return 1
    backend_rollback_pending=$(jq -r '.backend_rollback_pending // false' "$transaction_file") || return 1
    frontend_txn_validate_guards || {
        frontend_txn_set_phase recovery_required || :
        return 1
    }
    mapfile -t file_records < <(jq -c '.files[]' "$transaction_file")
    for record in "${file_records[@]}"; do
        path=$(jq -r '.path' <<<"$record")
        before_exists=$(jq -r '.before_exists' <<<"$record")
        before_sha=$(jq -r '.before_sha256' <<<"$record")
        before_mode=$(jq -r '.before_mode' <<<"$record")
        before_owner=$(jq -r '.before_owner' <<<"$record")
        after_exists=$(jq -r '.after_exists' <<<"$record")
        after_sha=$(jq -r '.after_sha256' <<<"$record")
        after_mode=$(jq -r '.after_mode' <<<"$record")
        after_owner=$(jq -r '.after_owner' <<<"$record")
        if [[ -L $path ]]; then
            frontend_set_error config_drift "File became a symlink during the transaction: $path"
            frontend_txn_set_phase recovery_required || :
            return 1
        fi
        current_exists=false
        [[ -e $path ]] && current_exists=true
        current_sha=
        current_mode=
        current_owner=
        if [[ $current_exists == true ]]; then
            current_sha=$(sha256sum "$path" | awk '{print $1}') || {
                frontend_set_error recovery_failed "Could not fingerprint $path during recovery."
                frontend_txn_set_phase recovery_required || :
                return 1
            }
            current_mode=$(stat -c '%a' "$path") || {
                frontend_set_error recovery_failed "Could not read permissions for $path during recovery."
                frontend_txn_set_phase recovery_required || :
                return 1
            }
            current_owner=$(stat -c '%u:%g' "$path") || {
                frontend_set_error recovery_failed "Could not read ownership for $path during recovery."
                frontend_txn_set_phase recovery_required || :
                return 1
            }
        fi
        if [[ $current_exists == "$after_exists" && ( $after_exists == false || ( $current_sha == "$after_sha" && $current_mode == "$after_mode" && $current_owner == "$after_owner" ) ) ]]; then
            role=$(jq -r '.role' <<<"$record")
            case $role in
            nginx_config | project_file) applied_nginx=true ;;
            backend_config) applied_backend=true ;;
            esac
        elif [[ $current_exists == "$before_exists" && ( $before_exists == false || ( $current_sha == "$before_sha" && $current_mode == "$before_mode" && $current_owner == "$before_owner" ) ) ]]; then
            :
        else
            frontend_set_error config_drift "File changed after the frontend transaction; refusing to overwrite $path"
            frontend_txn_set_phase recovery_required || :
            return 1
        fi
    done
    [[ $nginx_rollback_pending == true ]] && applied_nginx=true
    [[ $backend_rollback_pending == true ]] && applied_backend=true

    frontend_txn_set_phase rolling_back || {
        frontend_set_error transaction_state_write_failed 'Could not persist the rolling_back transaction phase.'
        return 1
    }
    if [[ $applied_nginx == true ]]; then
        frontend_txn_set_nginx_rollback_pending true || {
            frontend_set_error transaction_state_write_failed 'Could not persist the pending Nginx rollback reload.'
            frontend_txn_set_phase recovery_required || :
            return 1
        }
    fi
    for role in nginx_config project_file; do
        for ((index = ${#file_records[@]} - 1; index >= 0; index--)); do
            record=${file_records[$index]}
            [[ $(jq -r '.role' <<<"$record") == "$role" ]] || continue
            frontend_txn_restore_record_before "$record" || {
                frontend_txn_set_phase recovery_required || :
                return 1
            }
        done
    done
    if [[ $applied_nginx == true ]]; then
        frontend_reload_and_confirm "$frontend_nginx" || {
            frontend_set_error recovery_failed "Nginx recovery could not be verified; sing-box files were left untouched: $frontend_error_message"
            frontend_txn_set_phase recovery_required || :
            return 1
        }
        nginx_config=$(jq -r '.config' <<<"$frontend_nginx")
        nginx_prefix=$(jq -r '.prefix' <<<"$frontend_nginx")
        if ! frontend_scan_config_tree "$nginx_config" "$nginx_prefix" || ! frontend_read_tcp_listeners; then
            frontend_set_error recovery_failed "Nginx recovery listener could not be confirmed; sing-box files were left untouched: $frontend_error_message"
            frontend_txn_set_phase recovery_required || :
            return 1
        fi
        frontend_txn_set_nginx_rollback_pending false || {
            frontend_set_error transaction_state_write_failed 'Nginx recovery succeeded, but its confirmation could not be persisted.'
            frontend_txn_set_phase recovery_required || :
            return 1
        }
    fi
    if [[ $applied_backend == true ]]; then
        frontend_txn_set_backend_rollback_pending true || {
            frontend_set_error transaction_state_write_failed 'Could not persist the pending sing-box rollback restart.'
            frontend_txn_set_phase recovery_required || :
            return 1
        }
    fi
    for ((index = ${#file_records[@]} - 1; index >= 0; index--)); do
        record=${file_records[$index]}
        [[ $(jq -r '.role' <<<"$record") == backend_config || $(jq -r '.role' <<<"$record") == node_metadata ]] || continue
        frontend_txn_restore_record_before "$record" || {
            frontend_txn_set_phase recovery_required || :
            return 1
        }
    done
    if [[ $applied_backend == true ]] && ! manage_restart_confirmed; then
        frontend_set_error recovery_failed 'sing-box files were restored, but the original service could not be confirmed running.'
        frontend_txn_set_phase recovery_required || :
        return 1
    fi
    if [[ $applied_backend == true ]]; then
        frontend_txn_set_backend_rollback_pending false || {
            frontend_set_error transaction_state_write_failed 'sing-box recovery succeeded, but its confirmation could not be persisted.'
            frontend_txn_set_phase recovery_required || :
            return 1
        }
    fi
    for ((index = ${#file_records[@]} - 1; index >= 0; index--)); do
        record=${file_records[$index]}
        [[ $(jq -r '.role' <<<"$record") == profile ]] || continue
        frontend_txn_restore_record_before "$record" || {
            frontend_txn_set_phase recovery_required || :
            return 1
        }
    done
    frontend_txn_set_phase rolled_back || {
        frontend_set_error transaction_state_write_failed 'Could not persist the rolled_back transaction phase.'
        return 1
    }
    local txn_dir project_dir
    txn_dir=$(jq -r '.dir' "$transaction_file")
    rm -rf -- "$txn_dir"
    project_dir=$(jq -r '.nginx.config' "$transaction_file")
    project_dir="$(dirname -- "$project_dir")/one-singbox"
    rmdir -- "$project_dir" 2>/dev/null || :
    return 0
}

frontend_txn_commit() {
    local record original_code original_message status backend_changed=false nginx_changed=false
    local -a operation_records=()
    frontend_txn_write_record prepared || {
        frontend_set_error transaction_state_write_failed 'Could not persist the prepared frontend transaction.'
        return 1
    }
    mapfile -t operation_records < <(jq -c '.[] | select(.role == "backend_config" or .role == "node_metadata")' <<<"$frontend_txn_files")
    for record in "${operation_records[@]}"; do
        frontend_txn_apply_record "$record" || {
            original_code=$frontend_error_code
            original_message=$frontend_error_message
            if frontend_txn_rollback; then
                frontend_set_error "$original_code" "$original_message"
            else
                frontend_set_error recovery_required "$original_message Recovery is required: $frontend_error_message"
            fi
            return 1
        }
        [[ $(jq -r '.role' <<<"$record") == backend_config ]] && backend_changed=true
    done
    if [[ $backend_changed == true ]]; then
        if ! manage_restart_confirmed; then
            frontend_set_error backend_restart_failed 'The candidate sing-box service did not restart and become active.'
            original_code=$frontend_error_code
            original_message=$frontend_error_message
            if frontend_txn_rollback; then
                frontend_set_error "$original_code" "$original_message"
            else
                frontend_set_error recovery_required "$original_message Recovery is required: $frontend_error_message"
            fi
            return 1
        fi
        frontend_migration_active=0
        if [[ $frontend_txn_action == enable && ${#frontend_migration_refs[@]} -gt 0 ]]; then
            frontend_migration_handoff=1
        fi
        frontend_read_tcp_listeners || {
            frontend_migration_handoff=0
            original_code=$frontend_error_code
            original_message=$frontend_error_message
            if frontend_txn_rollback; then
                frontend_set_error "$original_code" "$original_message"
            else
                frontend_set_error recovery_required "$original_message Recovery is required: $frontend_error_message"
            fi
            return 1
        }
        frontend_migration_handoff=0
        frontend_txn_set_phase backend_applied || {
            frontend_set_error transaction_state_write_failed 'Could not persist the backend_applied transaction phase.'
            frontend_txn_rollback || :
            return 1
        }
    fi
    mapfile -t operation_records < <(jq -c '.[] | select(.role == "project_file" or .role == "nginx_config")' <<<"$frontend_txn_files")
    for record in "${operation_records[@]}"; do
        frontend_txn_apply_record "$record" || {
            original_code=$frontend_error_code
            original_message=$frontend_error_message
            if frontend_txn_rollback; then
                frontend_set_error "$original_code" "$original_message"
            else
                frontend_set_error recovery_required "$original_message Recovery is required: $frontend_error_message"
            fi
            return 1
        }
        nginx_changed=true
    done
    frontend_txn_set_phase frontend_applied || {
        frontend_set_error transaction_state_write_failed 'Could not persist the frontend_applied transaction phase.'
        frontend_txn_rollback || :
        return 1
    }
    if [[ $nginx_changed == true ]] && ! frontend_reload_and_confirm "$frontend_nginx"; then
        original_code=$frontend_error_code
        original_message=$frontend_error_message
        if frontend_txn_rollback; then
            frontend_set_error "$original_code" "$original_message"
        else
            frontend_set_error recovery_required "$original_message Recovery is required: $frontend_error_message"
        fi
        return 1
    fi
    if [[ $backend_changed == true && $nginx_changed == true ]]; then
        frontend_refresh_detection || {
            original_code=$frontend_error_code
            original_message=$frontend_error_message
            if frontend_txn_rollback; then
                frontend_set_error "$original_code" "$original_message"
            else
                frontend_set_error recovery_required "$original_message Recovery is required: $frontend_error_message"
            fi
            return 1
        }
    fi
    frontend_txn_set_phase verified || {
        frontend_set_error transaction_state_write_failed 'Could not persist the verified transaction phase.'
        frontend_txn_rollback || :
        return 1
    }
    mapfile -t operation_records < <(jq -c '.[] | select(.role == "profile")' <<<"$frontend_txn_files")
    for record in "${operation_records[@]}"; do
        frontend_txn_apply_record "$record" || {
            original_code=$frontend_error_code
            original_message=$frontend_error_message
            if frontend_txn_rollback; then
                frontend_set_error "$original_code" "$original_message"
            else
                frontend_set_error recovery_required "$original_message Recovery is required: $frontend_error_message"
            fi
            return 1
        }
    done
    frontend_txn_set_phase committed || {
        frontend_set_error transaction_state_write_failed 'Could not persist the committed transaction phase.'
        frontend_txn_rollback || :
        return 1
    }
    rm -rf -- "$frontend_txn_dir"
    return 0
}

frontend_render_stream_file() {
    local map_file=$1 map_variable=$2 aux_port=$3
    printf 'stream {\n'
    frontend_render_stream_body "$map_file" "$map_variable" "$aux_port" '    '
    printf '}\n'
}

frontend_choose_map_variable() {
    local suffix candidate target occupied
    for ((suffix = 0; suffix < 100; suffix++)); do
        if ((suffix == 0)); then
            candidate='$one_singbox_reality_backend'
        else
            candidate="\$one_singbox_reality_backend_${suffix}"
        fi
        occupied=0
        for target in "${frontend_scan_map_targets[@]}"; do
            [[ $target == "$candidate" ]] && occupied=1
        done
        [[ $occupied == 0 ]] && {
            frontend_map_variable=$candidate
            return 0
        }
    done
    frontend_set_error map_variable_unavailable 'Could not choose an unused Nginx map variable.'
    return 1
}

frontend_validate_sni() {
    local sni=$1
    [[ ${#sni} -le 253 && $sni =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] || {
        frontend_set_error invalid_sni 'Reality SNI must be an exact ASCII domain name with valid labels.'
        return 1
    }
}

frontend_validate_reality_node() {
    local node_file=$1 public_port=$2 sni
    jq -e --argjson port "$public_port" '
        type == "object" and
        (.inbounds | type == "array" and length == 1) and
        .inbounds[0].type == "vless" and
        .inbounds[0].listen_port == $port and
        (.inbounds[0] | has("transport") | not) and
        .inbounds[0].tls.enabled == true and
        .inbounds[0].tls.reality.enabled == true and
        .inbounds[0].tls.reality.handshake.server_port == 443 and
        (.inbounds[0].tls.server_name | type == "string") and
        (.inbounds[0].tls.reality.handshake.server == .inbounds[0].tls.server_name)
    ' "$node_file" >/dev/null 2>&1 || {
        frontend_set_error node_unsupported "Only a single ordinary VLESS-REALITY inbound without transport can be bound: ${node_file##*/}"
        return 1
    }
    sni=$(jq -r '.inbounds[0].tls.server_name' "$node_file") || return 1
    frontend_validate_sni "$sni"
}

frontend_config_has_tcp_port() {
    local file=$1 port=$2 configured_port
    while IFS= read -r configured_port; do
        [[ $configured_port == "$port" ]] && return 0
    done < <(frontend_config_tcp_ports "$file")
    return 1
}

frontend_config_tcp_ports() {
    jq -r '
        .inbounds[]?
        | select(
            (.network // "") != "udp" and
            (.transport.type // "") != "quic" and
            (.type != "hysteria" and .type != "hysteria2" and .type != "tuic")
        )
        | .listen_port // empty
    ' "$1" 2>/dev/null
}

frontend_nginx_wildcard_matches_sni() {
    local pattern=${1,,} candidate=${2,,} suffix prefix
    if [[ $pattern == \*.* && ${pattern#\*.} != *'*'* ]]; then
        suffix=${pattern#\*.}
        [[ $candidate == *".$suffix" && $candidate != "$suffix" ]]
        return
    fi
    if [[ $pattern == .* && $pattern != *'*'* ]]; then
        suffix=${pattern#.}
        [[ $candidate == "$suffix" || $candidate == *".$suffix" ]]
        return
    fi
    if [[ $pattern == *.* && $pattern == *'*' ]]; then
        prefix=${pattern%\*}
        [[ $prefix != *'*'* && $prefix == *\. && $candidate == "$prefix"* && ${candidate#"$prefix"} != '' ]]
        return
    fi
    return 2
}

frontend_nginx_exact_regex_sni() {
    local rule=$1 candidate=$2 case_insensitive=0 pattern char next index normalized=
    if [[ $rule == '~*'* ]]; then
        case_insensitive=1
        pattern=${rule#\~\*}
    elif [[ $rule == '~'* ]]; then
        pattern=${rule#\~}
    else
        return 2
    fi
    [[ $pattern == ^*\$ && ${#pattern} -gt 2 ]] || return 2
    pattern=${pattern:1:${#pattern}-2}
    for ((index = 0; index < ${#pattern}; index++)); do
        char=${pattern:index:1}
        if [[ $char == '\' ]]; then
            ((index + 1 < ${#pattern})) || return 2
            next=${pattern:index+1:1}
            [[ $next == '.' ]] || return 2
            normalized+=.
            ((index += 1))
            continue
        fi
        case $char in
        [A-Za-z0-9-]) normalized+=$char ;;
        *) return 2 ;;
        esac
    done
    [[ $normalized =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] || return 2
    if ((case_insensitive)); then
        [[ ${normalized,,} == ${candidate,,} ]]
    else
        [[ $normalized == "$candidate" ]]
    fi
}

frontend_assert_user_map_sni_free() {
    local candidate=$1 target map_file rule_file rule_line rule_key rule_kind index candidate_lower=${1,,}
    local overlap_status active_hostnames hostname_target
    target=$(jq -r '.map_variable // empty' <<<"$frontend_nginx")
    [[ $target ]] || return 0
    map_file=
    [[ $frontend_profile ]] && map_file=$(jq -r '.ownership.map_file // empty' <<<"$frontend_profile")
    for index in "${!frontend_scan_map_rule_targets[@]}"; do
        [[ ${frontend_scan_map_rule_targets[$index]} == "$target" ]] || continue
        rule_file=${frontend_scan_map_rule_files[$index]}
        [[ $map_file && $rule_file == "$map_file" ]] && continue
        rule_line=${frontend_scan_map_rule_lines[$index]}
        rule_key=${frontend_scan_map_rule_keys[$index]}
        rule_kind=${frontend_scan_map_rule_kinds[$index]}
        case $rule_kind in
        exact)
            [[ $rule_key == default ]] && continue
            [[ ${rule_key,,} != "$candidate_lower" ]] || {
                frontend_set_error duplicate_sni "Reality SNI conflicts with a user Nginx map entry at $rule_file:$rule_line: $candidate"
                return 1
            }
            ;;
        wildcard)
            active_hostnames=0
            for hostname_target in "${frontend_scan_map_hostnames_targets[@]}"; do
                [[ $hostname_target == "$target" ]] && active_hostnames=1
            done
            [[ $active_hostnames == 1 ]] || continue
            frontend_nginx_wildcard_matches_sni "$rule_key" "$candidate_lower"
            overlap_status=$?
            if ((overlap_status == 0)); then
                frontend_set_error duplicate_sni "Reality SNI conflicts with a user Nginx map entry at $rule_file:$rule_line: $candidate"
                return 1
            elif ((overlap_status == 2)); then
                frontend_set_error nginx_map_overlap "Cannot prove that Reality SNI $candidate does not overlap the user Nginx map rule at $rule_file:$rule_line: $rule_key"
                return 1
            fi
            ;;
        regex)
            frontend_nginx_exact_regex_sni "$rule_key" "$candidate"
            overlap_status=$?
            if ((overlap_status == 0)); then
                frontend_set_error duplicate_sni "Reality SNI conflicts with a user Nginx map entry at $rule_file:$rule_line: $candidate"
                return 1
            elif ((overlap_status == 2)); then
                frontend_set_error nginx_map_overlap "Cannot prove that Reality SNI $candidate does not overlap the user Nginx map rule at $rule_file:$rule_line: $rule_key"
                return 1
            fi
            ;;
        complex)
            frontend_set_error nginx_map_overlap "Cannot prove that Reality SNI $candidate does not overlap the user Nginx map rule at $rule_file:$rule_line: $rule_key"
            return 1
            ;;
        esac
    done
}

frontend_assert_unique_sni() {
    local candidate=$1 skip_ref=${2:-} binding node_ref node_file existing_sni
    local candidate_lower=${candidate,,}
    frontend_validate_sni "$candidate" || return 1
    while IFS= read -r binding; do
        [[ $binding ]] || continue
        node_ref=$(jq -r '.node_ref' <<<"$binding")
        [[ $node_ref == "$skip_ref" ]] && continue
        node_file="$is_conf_dir/$node_ref"
        [[ -f $node_file && ! -L $node_file ]] || {
            frontend_set_error binding_drift "Bound node is missing or unsafe: $node_ref"
            return 1
        }
        frontend_validate_reality_node "$node_file" "$(jq -r '.inbounds[0].listen_port' "$node_file")" || return 1
        existing_sni=$(jq -r '.inbounds[0].tls.server_name' "$node_file")
        [[ ${existing_sni,,} != "$candidate_lower" ]] || {
            frontend_set_error duplicate_sni "Reality SNI is already bound by $node_ref: $candidate"
            return 1
        }
    done < <(jq -c '.bindings[]?' <<<"$frontend_profile")
    frontend_assert_user_map_sni_free "$candidate"
}

frontend_validate_migration_refs() {
    local node_ref node_file port binding ref file
    local -a all_443=()
    local -A requested=()
    frontend_migration_refs=()
    frontend_assert_no_inline_443_node || return 1
    for node_ref in "$@"; do
        [[ $node_ref =~ ^[A-Za-z0-9_.-]+\.json$ ]] || {
            frontend_set_error node_ref_invalid "Invalid node reference: $node_ref"
            return 1
        }
        [[ ! ${requested[$node_ref]+yes} ]] || {
            frontend_set_error node_ref_duplicate "Node reference was selected more than once: $node_ref"
            return 1
        }
        requested[$node_ref]=1
        node_file="$is_conf_dir/$node_ref"
        [[ -f $node_file && ! -L $node_file ]] || {
            frontend_set_error node_ref_missing "Node reference does not name a regular node file: $node_ref"
            return 1
        }
        frontend_validate_reality_node "$node_file" 443 || return 1
        frontend_migration_refs+=("$node_ref")
    done

    shopt -s nullglob
    for file in "$is_conf_dir"/*.json; do
        [[ -f $file && ! -L $file ]] || continue
        [[ ${file##*/} =~ ^dynamic-port-.*-link$ || ${file##*/} == relay-*.json ]] && continue
        jq -e 'type == "object" and (.inbounds // [] | type == "array")' "$file" >/dev/null 2>&1 || {
            frontend_set_error singbox_config_unreadable "Cannot safely inspect node configuration $file"
            shopt -u nullglob
            return 1
        }
        if frontend_config_has_tcp_port "$file" 443; then
            frontend_validate_reality_node "$file" 443 || {
                shopt -u nullglob
                return 1
            }
            all_443+=("${file##*/}")
        fi
    done
    shopt -u nullglob

    if ((${#all_443[@]} == 0 && ${#frontend_migration_refs[@]} > 0)); then
        frontend_set_error node_not_on_public_443 'Selected nodes are not configured on public port 443.'
        return 1
    fi
    for node_ref in "${all_443[@]}"; do
        [[ ${requested[$node_ref]+yes} ]] || {
            frontend_set_error unselected_443_nodes "Select every existing port-443 node before enabling the frontend: $node_ref"
            return 1
        }
    done
    for node_ref in "${frontend_migration_refs[@]}"; do
        [[ ${requested[$node_ref]+yes} ]] || {
            frontend_set_error node_ref_invalid "Could not resolve selected node reference: $node_ref"
            return 1
        }
    done

    frontend_migration_active=0
    ((${#frontend_migration_refs[@]} == 0)) || frontend_migration_active=1
    return 0
}

frontend_choose_backend_port() {
    local port file
    local -A used=()
    for port in "${!frontend_bound_ports[@]}" "${!frontend_configured_ports[@]}"; do
        [[ $port =~ ^[0-9]+$ ]] && used[$port]=1
    done
    for port in "${!frontend_reserved_backend_ports[@]}"; do
        [[ $port =~ ^[0-9]+$ ]] && used[$port]=1
    done
    [[ ${frontend_aux_port:-} =~ ^[0-9]+$ ]] && used[$frontend_aux_port]=1
    if [[ $frontend_profile ]]; then
        port=$(jq -r '.ownership.reject_port // empty' <<<"$frontend_profile")
        [[ $port =~ ^[0-9]+$ ]] && used[$port]=1
        while IFS= read -r port; do
            [[ $port =~ ^[0-9]+$ ]] && used[$port]=1
        done < <(jq -r '.bindings[].backend_port' <<<"$frontend_profile")
    fi
    shopt -s nullglob
    for file in "$is_conf_dir"/*.json; do
        [[ -f $file && ! -L $file ]] || continue
        while IFS= read -r port; do
            [[ $port =~ ^[0-9]+$ ]] && used[$port]=1
        done < <(frontend_config_tcp_ports "$file")
    done
    shopt -u nullglob
    for ((port = 49152; port <= 65535; port++)); do
        [[ ${used[$port]+yes} ]] || {
            frontend_backend_port=$port
            return 0
        }
    done
    frontend_set_error backend_port_unavailable 'No free loopback backend port is available.'
    return 1
}

frontend_render_reality_map() {
    local bindings=$1 node_dir=$2 destination=$3 binding node_ref node_file sni port lower
    local -A seen=()
    : >"$destination" || return 1
    while IFS= read -r binding; do
        [[ $binding ]] || continue
        node_ref=$(jq -r '.node_ref' <<<"$binding")
        node_file="$node_dir/$node_ref"
        [[ -f $node_file && ! -L $node_file ]] || {
            frontend_set_error binding_drift "Bound node is missing or unsafe: $node_ref"
            return 1
        }
        jq -e --argjson port "$(jq -r '.backend_port' <<<"$binding")" '
            .inbounds[0].type == "vless" and
            .inbounds[0].listen == "127.0.0.1" and
            .inbounds[0].listen_port == $port and
            .inbounds[0].tls.enabled == true and
            .inbounds[0].tls.reality.enabled == true and
            (.inbounds[0] | has("transport") | not)
        ' "$node_file" >/dev/null 2>&1 || {
            frontend_set_error binding_drift "Bound node does not match its saved loopback backend: $node_ref"
            return 1
        }
        sni=$(jq -r '.inbounds[0].tls.server_name' "$node_file") || return 1
        frontend_validate_sni "$sni" || return 1
        lower=${sni,,}
        [[ ! ${seen[$lower]+yes} ]] || {
            frontend_set_error duplicate_sni "Reality SNI is already used by another binding: $sni"
            return 1
        }
        seen[$lower]=1
        port=$(jq -r '.backend_port' <<<"$binding")
        printf '%s 127.0.0.1:%s;\n' "$sni" "$port" >>"$destination" || return 1
    done < <(jq -c '.[]' <<<"$bindings")
}

frontend_prepare_binding_bundle() {
    local candidate_json=${1:-} node_name=${2:-} node_ref node_file backend port sni meta_path source_config check_output file tag_conflict
    local candidate_node_json candidate_meta_json
    frontend_candidate_nodes="$frontend_txn_dir/nodes"
    frontend_candidate_config="$frontend_txn_dir/sing-box-config.after"
    frontend_candidate_map="$frontend_txn_dir/candidate-reality-map.conf"
    frontend_candidate_node_refs=()
    frontend_candidate_meta_refs=()
    declare -gA frontend_reserved_backend_ports
    frontend_reserved_backend_ports=()
    mkdir -p "$frontend_candidate_nodes" || return 1
    cp -a "$is_conf_dir/." "$frontend_candidate_nodes/" || {
        frontend_set_error node_candidate_failed 'Could not stage the complete candidate node directory.'
        return 1
    }
    frontend_new_bindings='[]'
    if [[ $frontend_profile ]]; then
        frontend_new_bindings=$(jq -c '.bindings' <<<"$frontend_profile") || return 1
    fi

    for node_ref in "${frontend_migration_refs[@]}"; do
        node_file="$is_conf_dir/$node_ref"
        sni=$(jq -r '.inbounds[0].tls.server_name' "$node_file") || return 1
        frontend_assert_user_map_sni_free "$sni" || return 1
        frontend_choose_backend_port || return 1
        backend=$frontend_backend_port
        frontend_reserved_backend_ports[$backend]=1
        candidate_node_json=$(jq -c --argjson port "$backend" \
            '.inbounds[0].listen="127.0.0.1" | .inbounds[0].listen_port=$port' \
            "$node_file") || {
            frontend_set_error node_candidate_failed "Could not build the migrated node candidate: $node_ref"
            return 1
        }
        printf '%s\n' "$candidate_node_json" >"$frontend_candidate_nodes/$node_ref" || return 1
        frontend_candidate_node_refs+=("$node_ref")
        meta_path="$(meta_file "$node_ref")"
        [[ -f $meta_path ]] && frontend_candidate_meta_refs+=("$node_ref")
        frontend_new_bindings=$(jq -cn --argjson bindings "$frontend_new_bindings" --arg node_ref "$node_ref" --argjson port "$backend" \
            '$bindings + [{node_ref:$node_ref,public_port:443,backend_host:"127.0.0.1",backend_port:$port}]') || return 1
    done

    if [[ $candidate_json ]]; then
        jq -e '
            type == "object" and
            (.inbounds | type == "array" and length == 1) and
            .inbounds[0].type == "vless" and
            .inbounds[0].listen_port == 443 and
            (.inbounds[0] | has("transport") | not) and
            .inbounds[0].tls.enabled == true and
            .inbounds[0].tls.reality.enabled == true and
            .inbounds[0].tls.reality.handshake.server_port == 443 and
            (.inbounds[0].tls.server_name | type == "string") and
            (.inbounds[0].tls.reality.handshake.server == .inbounds[0].tls.server_name)
        ' <<<"$candidate_json" >/dev/null 2>&1 || {
            frontend_set_error node_unsupported 'Only a single ordinary VLESS-REALITY node without transport can use the public 443 frontend.'
            return 1
        }
        sni=$(jq -r '.inbounds[0].tls.server_name // empty' <<<"$candidate_json") || return 1
        frontend_assert_unique_sni "$sni" || return 1
        while :; do
            frontend_choose_backend_port || return 1
            backend=$frontend_backend_port
            node_ref="vless-reality-front-$backend.json"
            meta_path="$(meta_file "$node_ref")"
            tag_conflict=0
            for file in "$frontend_candidate_nodes"/*.json; do
                [[ -f $file && ! -L $file ]] || continue
                if jq -e --arg tag "$node_ref" 'any(.inbounds[]?; .tag == $tag)' "$file" >/dev/null 2>&1; then
                    tag_conflict=1
                    break
                fi
            done
            if [[ -e $is_conf_dir/$node_ref || -L $is_conf_dir/$node_ref || -e $meta_path || -L $meta_path || $tag_conflict == 1 ]]; then
                frontend_reserved_backend_ports[$backend]=1
                continue
            fi
            break
        done
        frontend_reserved_backend_ports[$backend]=1
        candidate_node_json=$(jq -c --arg tag "$node_ref" --argjson port "$backend" \
            '.inbounds[0].tag=$tag | .inbounds[0].listen="127.0.0.1" | .inbounds[0].listen_port=$port' \
            <<<"$candidate_json") || {
            frontend_set_error node_candidate_failed "Could not build a loopback candidate for $node_ref"
            return 1
        }
        printf '%s\n' "$candidate_node_json" >"$frontend_candidate_nodes/$node_ref" || return 1
        frontend_candidate_node_refs+=("$node_ref")
        if [[ $node_name ]]; then
            candidate_meta_json=$(jq -cn --arg name "$node_name" '{node_name:$name}') || return 1
            mkdir -p "$frontend_candidate_nodes/.quan-meta" || return 1
            printf '%s\n' "$candidate_meta_json" >"$frontend_candidate_nodes/.quan-meta/$node_ref.meta.json" || return 1
            frontend_candidate_meta_refs+=("$node_ref")
        fi
        frontend_new_bindings=$(jq -cn --argjson bindings "$frontend_new_bindings" --arg node_ref "$node_ref" --argjson port "$backend" \
            '$bindings + [{node_ref:$node_ref,public_port:443,backend_host:"127.0.0.1",backend_port:$port}]') || return 1
        frontend_created_node_ref=$node_ref
    fi

    source_config="$frontend_txn_dir/config.source"
    if [[ -f $is_config_json ]]; then
        cp -p "$is_config_json" "$source_config" || return 1
    else
        default_runtime_config >"$source_config" || {
            frontend_set_error node_candidate_failed 'Could not construct the shared sing-box configuration.'
            return 1
        }
    fi
    if ! render_runtime_node_outbound_modes "$source_config" "$frontend_candidate_config" '' '' "$frontend_candidate_nodes"; then
        frontend_set_error node_candidate_failed "Could not render shared outbound configuration: ${runtime_sync_error:-unknown error}"
        return 1
    fi
    check_output=$("$is_core_bin" check -c "$frontend_candidate_config" -C "$frontend_candidate_nodes" 2>&1) || {
        frontend_set_error singbox_candidate_invalid 'The complete candidate sing-box configuration failed validation.'
        return 1
    }
    frontend_render_reality_map "$frontend_new_bindings" "$frontend_candidate_nodes" "$frontend_candidate_map" || return 1
}

frontend_check_binding_map_candidate() {
    local config_file flat_config
    config_file=$(jq -r '.config' <<<"$frontend_nginx")
    flat_config="$frontend_txn_dir/candidate-map-tree.conf"
    : >"$flat_config" || return 1
    frontend_flatten_override_file=$(jq -r '.ownership.map_file' <<<"$frontend_profile")
    frontend_flatten_override_content=$frontend_candidate_map
    frontend_flatten_file "$config_file" "$flat_config"
    local status=$?
    frontend_flatten_override_file=
    frontend_flatten_override_content=
    ((status == 0)) || return 1
    frontend_candidate_check "$flat_config"
}

frontend_assert_profile_map_owned() {
    local map_file expected actual
    map_file=$(jq -r '.ownership.map_file // empty' <<<"$frontend_profile")
    expected=$(jq -r '.ownership.map_sha256 // empty' <<<"$frontend_profile")
    [[ $map_file == /* && $expected =~ ^[0-9a-f]{64}$ && -f $map_file && ! -L $map_file ]] || {
        frontend_set_error owned_file_drift 'The frontend Reality map is missing or has invalid ownership metadata.'
        return 1
    }
    actual=$(sha256sum "$map_file" | awk '{print $1}') || return 1
    [[ $actual == "$expected" ]] || {
        frontend_set_error owned_file_drift "The managed Reality map changed outside one-singbox: $map_file"
        return 1
    }
    jq -e --arg path "$map_file" --arg sha "$expected" '.ownership.files | any(.path == $path and .sha256 == $sha)' <<<"$frontend_profile" >/dev/null || {
        frontend_set_error invalid_profile 'The frontend profile does not own its saved Reality map.'
        return 1
    }
}

frontend_assert_no_unmanaged_443_node() {
    local file
    frontend_assert_no_inline_443_node || return 1
    shopt -s nullglob
    for file in "$is_conf_dir"/*.json; do
        [[ -f $file && ! -L $file ]] || continue
        [[ ${file##*/} =~ ^dynamic-port-.*-link$ || ${file##*/} == relay-*.json ]] && continue
        jq -e 'type == "object" and (.inbounds // [] | type == "array")' "$file" >/dev/null 2>&1 || {
            frontend_set_error singbox_config_unreadable "Cannot safely inspect node configuration $file"
            shopt -u nullglob
            return 1
        }
        if frontend_config_has_tcp_port "$file" 443; then
            frontend_set_error tcp_443_port_conflict "An unmanaged sing-box node still uses port 443: ${file##*/}"
            shopt -u nullglob
            return 1
        fi
    done
    shopt -u nullglob
}

frontend_assert_no_inline_443_node() {
    [[ -f $is_config_json ]] || return 0
    jq -e 'type == "object" and ((.inbounds // []) | type == "array")' "$is_config_json" >/dev/null 2>&1 || {
        frontend_set_error singbox_config_unreadable "Cannot safely inspect shared configuration $is_config_json"
        return 1
    }
    frontend_config_has_tcp_port "$is_config_json" 443 && {
        frontend_set_error inline_443_node "The shared sing-box configuration contains a port-443 inbound that cannot be selected by node reference: $is_config_json"
        return 1
    }
    return 0
}

frontend_public_443_ready() {
    frontend_load_profile || {
        frontend_set_error "$frontend_profile_error_code" "$frontend_profile_error_message"
        return 1
    }
    [[ $frontend_profile ]] && jq -e '.enabled == true' <<<"$frontend_profile" >/dev/null || {
        frontend_set_error frontend_disabled 'Port 443 is available for Reality only while the Nginx frontend mode is enabled.'
        return 1
    }
    frontend_read_phase || {
        frontend_set_error "$frontend_phase_error_code" "$frontend_phase_error_message"
        return 1
    }
    frontend_pending_change || return 1
    frontend_refresh_detection || return 1
    frontend_assert_profile_map_owned || return 1
    frontend_assert_no_unmanaged_443_node
}

frontend_add_public_reality_node() {
    local node_json=$1 node_name=${2:-} status= map_file map_sha profile_after next_revision metadata_ref
    frontend_lock_state || return 1
    frontend_load_profile || {
        frontend_set_error "$frontend_profile_error_code" "$frontend_profile_error_message"
        status=1
    }
    if [[ ! $status ]]; then
        [[ $frontend_profile ]] && jq -e '.enabled == true' <<<"$frontend_profile" >/dev/null || {
            frontend_set_error frontend_disabled 'The Nginx Reality frontend is not enabled.'
            status=1
        }
    fi
    if [[ ! $status ]]; then
        frontend_read_phase || {
            frontend_set_error "$frontend_phase_error_code" "$frontend_phase_error_message"
            status=1
        }
    fi
    if [[ ! $status ]]; then
        frontend_pending_change || status=1
    fi
    if [[ ! $status ]]; then
        frontend_refresh_detection || status=1
    fi
    if [[ ! $status ]]; then
        frontend_assert_profile_map_owned || status=1
        frontend_assert_no_unmanaged_443_node || status=1
    fi
    if [[ ! $status ]]; then
        jq -e '
            type == "object" and
            (.inbounds | type == "array" and length == 1) and
            .inbounds[0].type == "vless" and
            .inbounds[0].listen_port == 443 and
            (.inbounds[0] | has("transport") | not) and
            .inbounds[0].tls.enabled == true and
            .inbounds[0].tls.reality.enabled == true and
            .inbounds[0].tls.reality.handshake.server_port == 443 and
            (.inbounds[0].tls.server_name | type == "string") and
            (.inbounds[0].tls.reality.handshake.server == .inbounds[0].tls.server_name)
        ' <<<"$node_json" >/dev/null 2>&1 || {
            frontend_set_error node_unsupported 'Only a single ordinary VLESS-REALITY node without transport can use the public 443 frontend.'
            status=1
        }
    fi
    if [[ ! $status ]]; then
        frontend_assert_unique_sni "$(jq -r '.inbounds[0].tls.server_name' <<<"$node_json")" || status=1
    fi
    if [[ ! $status ]]; then
        frontend_original_files=("${frontend_scan_source_files[@]}")
        frontend_original_hashes=("${frontend_scan_source_hashes[@]}")
        frontend_migration_refs=()
        frontend_txn_dir="$is_core_dir/.frontend-state/txn.$$.$RANDOM"
        mkdir -m 700 "$frontend_txn_dir" || {
            frontend_set_error state_unwritable 'Could not create a private frontend transaction directory.'
            status=1
        }
    fi
    if [[ ! $status ]]; then
        frontend_prepare_binding_bundle "$node_json" "$node_name" || status=1
    fi
    if [[ ! $status ]]; then
        frontend_check_binding_map_candidate || status=1
    fi
    if [[ ! $status ]]; then
        map_file=$(jq -r '.ownership.map_file' <<<"$frontend_profile")
        map_sha=$(sha256sum "$frontend_candidate_map" | awk '{print $1}') || status=1
        next_revision=$(( $(jq -r '.revision' <<<"$frontend_profile") + 1 ))
        profile_after="$frontend_txn_dir/profile.after"
        jq -c --argjson revision "$next_revision" --argjson bindings "$frontend_new_bindings" --arg path "$map_file" --arg sha "$map_sha" '
            .revision=$revision
            | .bindings=$bindings
            | .ownership.map_sha256=$sha
            | .ownership.files |= map(if .path == $path then .sha256=$sha else . end)
        ' <<<"$frontend_profile" >"$profile_after" || status=1
        chmod 600 "$profile_after" 2>/dev/null || status=1
    fi
    if [[ ! $status ]]; then
        frontend_txn_action=bind
        frontend_txn_files='[]'
        frontend_txn_paths=()
        frontend_guard_paths=()
        frontend_changed_targets=("$map_file")
        frontend_make_guards "$map_file" || status=1
        frontend_verify_original_sources || status=1
    fi
    if [[ ! $status ]]; then
        local node_ref
        for node_ref in "${frontend_candidate_node_refs[@]}"; do
            frontend_txn_add_change "$is_conf_dir/$node_ref" "$frontend_candidate_nodes/$node_ref" backend_config 644 || { status=1; break; }
        done
    fi
    if [[ ! $status ]]; then
        for metadata_ref in "${frontend_candidate_meta_refs[@]}"; do
            frontend_txn_add_change "$(meta_file "$metadata_ref")" "$frontend_candidate_nodes/.quan-meta/$metadata_ref.meta.json" backend_config 600 || { status=1; break; }
        done
    fi
    if [[ ! $status ]]; then
        frontend_txn_add_change "$is_config_json" "$frontend_candidate_config" backend_config 600 || status=1
    fi
    if [[ ! $status ]]; then
        frontend_txn_add_change "$map_file" "$frontend_candidate_map" project_file 644 || status=1
    fi
    if [[ ! $status ]]; then
        frontend_txn_add_change "$is_core_dir/frontend.json" "$profile_after" profile 600 || status=1
    fi
    if [[ ! $status ]]; then
        frontend_verify_original_sources || status=1
    fi
    if [[ ! $status ]]; then
        frontend_txn_commit || status=1
    fi
    if [[ $status ]]; then
        local original_code=$frontend_error_code original_message=$frontend_error_message
        frontend_read_phase || :
        if [[ $frontend_txn_dir && $frontend_phase != recovery_required ]]; then
            rm -rf -- "${frontend_txn_dir:-}"
        fi
        frontend_error_code=$original_code
        frontend_error_message=$original_message
    else
        is_config_name=$frontend_created_node_ref
        is_config_file=$frontend_created_node_ref
        printf '节点已加入 443 SNI 前置：%s。\n' "$frontend_created_node_ref"
    fi
    frontend_unlock_state
    return "${status:-0}"
}

frontend_txn_add_change_if_different() {
    local path=$1 candidate=${2:-} role=$3 mode=${4:-644} current_hash candidate_hash
    if [[ $candidate && -f $path ]]; then
        if [[ $role == backend_config || $role == node_metadata ]] && jq -e . "$path" >/dev/null 2>&1 && jq -e . "$candidate" >/dev/null 2>&1; then
            [[ $(jq -cS . "$path") != "$(jq -cS . "$candidate")" ]] || return 0
        fi
        current_hash=$(sha256sum "$path" | awk '{print $1}') || return 1
        candidate_hash=$(sha256sum "$candidate" | awk '{print $1}') || return 1
        [[ $current_hash != "$candidate_hash" ]] || return 0
    elif [[ ! $candidate && ! -e $path ]]; then
        return 0
    fi
    frontend_txn_add_change "$path" "$candidate" "$role" "$mode"
}

frontend_apply_node_lifecycle() {
    local operation=$1 old_ref=$2 new_ref=${3:-} node_json=${4:-} metadata_json=${5:-}
    local status= binding= old_backend= candidate_port= sni= tag= map_file= map_sha= profile_after= source_config= candidate_node_json= old_meta_path= new_meta_path= old_node_path= new_node_path= old_profile_bindings= profile_changed=false map_changed=false node_is_reality=false
    local index node_ref record new_revision current_profile_hash candidate_profile_hash
    local -a changed_refs=() changed_meta_refs=()

    frontend_lock_state || return 1
    frontend_load_profile || {
        frontend_set_error "$frontend_profile_error_code" "$frontend_profile_error_message"
        status=1
    }
    if [[ ! $status ]]; then
        [[ $frontend_profile ]] && jq -e '.enabled == true' <<<"$frontend_profile" >/dev/null || {
            frontend_set_error frontend_disabled 'The Nginx Reality frontend must be enabled to edit or delete a bound node.'
            status=1
        }
    fi
    if [[ ! $status ]]; then
        frontend_read_phase || {
            frontend_set_error "$frontend_phase_error_code" "$frontend_phase_error_message"
            status=1
        }
        [[ $status ]] || frontend_pending_change || status=1
    fi
    if [[ ! $status ]]; then
        frontend_refresh_detection || status=1
    fi
    if [[ ! $status ]]; then
        frontend_assert_profile_map_owned || status=1
        frontend_assert_no_unmanaged_443_node || status=1
    fi
    if [[ ! $status ]]; then
        old_node_path="$is_conf_dir/$old_ref"
        [[ $old_ref =~ ^[A-Za-z0-9_.-]+\.json$ && -f $old_node_path && ! -L $old_node_path ]] || {
            frontend_set_error node_ref_missing "Node reference does not name a regular node file: $old_ref"
            status=1
        }
        if [[ ! $status && ${frontend_node_source_ref:-} == "$old_ref" && ${frontend_node_source_hash:-} =~ ^[0-9a-f]{64}$ ]]; then
            local current_node_hash
            current_node_hash=$(sha256sum "$old_node_path" | awk '{print $1}') || status=1
            if [[ ! $status && $current_node_hash != "$frontend_node_source_hash" ]]; then
                frontend_set_error config_drift "Bound node changed while the edit was being prepared: $old_ref"
                status=1
            fi
        fi
        binding=$(jq -c --arg ref "$old_ref" '[.bindings[] | select(.node_ref == $ref)][0] // empty' <<<"$frontend_profile") || status=1
        [[ ! $binding ]] || old_backend=$(jq -r '.backend_port' <<<"$binding")
    fi
    if [[ ! $status && $operation != delete && $operation != replace ]]; then
        frontend_set_error node_operation_invalid "Unsupported bound-node operation: $operation"
        status=1
    fi
    if [[ ! $status && $operation == replace ]]; then
        [[ $new_ref =~ ^[A-Za-z0-9_.-]+\.json$ && $node_json ]] || {
            frontend_set_error node_candidate_invalid 'A bound-node edit requires a valid candidate file reference and node JSON.'
            status=1
        }
        if [[ ! $status ]]; then
            jq -e 'type == "object" and (.inbounds | type == "array" and length == 1)' <<<"$node_json" >/dev/null 2>&1 || {
                frontend_set_error node_candidate_invalid 'A bound-node edit must produce exactly one inbound.'
                status=1
            }
        fi
        if [[ ! $status ]]; then
            candidate_port=$(jq -r '.inbounds[0].listen_port // empty' <<<"$node_json")
            node_is_reality=$(jq -r '
                .inbounds[0].type == "vless" and
                (.inbounds[0] | has("transport") | not) and
                .inbounds[0].tls.enabled == true and
                .inbounds[0].tls.reality.enabled == true and
                .inbounds[0].tls.reality.handshake.server_port == 443 and
                (.inbounds[0].tls.server_name | type == "string") and
                (.inbounds[0].tls.reality.handshake.server == .inbounds[0].tls.server_name)
            ' <<<"$node_json")
            [[ $node_is_reality == true ]] || {
                frontend_set_error node_unsupported 'Move the node off public port 443 before changing its protocol or transport; only ordinary VLESS-REALITY without transport is supported.'
                status=1
            }
        fi
        if [[ ! $status && $candidate_port != 443 && ( ! $candidate_port =~ ^[0-9]+$ || $candidate_port -lt 1 || $candidate_port -gt 65535 ) ]]; then
            frontend_set_error node_candidate_invalid 'The candidate node has an invalid public listening port.'
            status=1
        fi
    fi
    if [[ ! $status ]]; then
        frontend_original_files=("${frontend_scan_source_files[@]}")
        frontend_original_hashes=("${frontend_scan_source_hashes[@]}")
        frontend_txn_dir="$is_core_dir/.frontend-state/txn.$$.$RANDOM"
        mkdir -m 700 "$frontend_txn_dir" || {
            frontend_set_error state_unwritable 'Could not create a private frontend transaction directory.'
            status=1
        }
    fi
    if [[ ! $status ]]; then
        declare -gA frontend_reserved_backend_ports
        frontend_reserved_backend_ports=()
        frontend_candidate_nodes="$frontend_txn_dir/nodes"
        frontend_candidate_config="$frontend_txn_dir/sing-box-config.after"
        frontend_candidate_map="$frontend_txn_dir/candidate-reality-map.conf"
        mkdir -p "$frontend_candidate_nodes" && cp -a "$is_conf_dir/." "$frontend_candidate_nodes/" || {
            frontend_set_error node_candidate_failed 'Could not stage the complete candidate node directory.'
            status=1
        }
    fi
    if [[ ! $status ]]; then
        if [[ ! $binding && $operation == delete ]]; then
            frontend_set_error binding_missing "Node is not bound to the enabled frontend: $old_ref"
            status=1
        elif [[ ! $binding && $candidate_port != 443 ]]; then
            frontend_set_error binding_missing "Node is not bound to the enabled frontend: $old_ref"
            status=1
        fi
    fi
    if [[ ! $status ]]; then
        old_meta_path=$(meta_file "$old_ref")
        new_node_path="$is_conf_dir/$new_ref"
        new_meta_path=$(meta_file "$new_ref")
        if [[ $operation == replace && $new_ref != "$old_ref" ]]; then
            [[ ! -e $new_node_path && ! -L $new_node_path && ! -e $new_meta_path && ! -L $new_meta_path ]] || {
                frontend_set_error node_ref_conflict "Target node file or metadata already exists: $new_ref"
                status=1
            }
            if [[ ! $status ]]; then
                mv -f "$frontend_candidate_nodes/$old_ref" "$frontend_candidate_nodes/$new_ref" || status=1
                if [[ -f $frontend_candidate_nodes/.quan-meta/$old_ref.meta.json ]]; then
                    mv -f "$frontend_candidate_nodes/.quan-meta/$old_ref.meta.json" "$frontend_candidate_nodes/.quan-meta/$new_ref.meta.json" || status=1
                fi
            fi
        fi
        if [[ ! $status && $operation == delete ]]; then
            rm -f "$frontend_candidate_nodes/$old_ref" "$frontend_candidate_nodes/.quan-meta/$old_ref.meta.json" || status=1
            [[ $status ]] || frontend_new_bindings=$(jq -c --arg ref "$old_ref" '.bindings | map(select(.node_ref != $ref))' <<<"$frontend_profile") || status=1
        elif [[ ! $status ]]; then
            if [[ $candidate_port == 443 ]]; then
                frontend_assert_unique_sni "$(jq -r '.inbounds[0].tls.server_name' <<<"$node_json")" "$old_ref" || status=1
                sni=$(jq -r '.inbounds[0].tls.server_name' <<<"$node_json")
                if [[ ! $status ]]; then
                    if [[ $binding ]]; then
                        tag=$(jq -r '.inbounds[0].tag' "$old_node_path")
                        old_backend=$(jq -r '.backend_port' <<<"$binding")
                    else
                        frontend_choose_backend_port || status=1
                        old_backend=$frontend_backend_port
                        tag=$(jq -r '.inbounds[0].tag // empty' <<<"$node_json")
                        [[ $tag ]] || tag=$new_ref
                    fi
                fi
                if [[ ! $status ]]; then
                    candidate_node_json=$(jq -c --arg tag "$tag" --argjson port "$old_backend" \
                        '.inbounds[0].tag=$tag | .inbounds[0].listen="127.0.0.1" | .inbounds[0].listen_port=$port' <<<"$node_json") || status=1
                    frontend_new_bindings=$(jq -cn --argjson bindings "$(jq -c --arg ref "$old_ref" '.bindings | map(select(.node_ref != $ref))' <<<"$frontend_profile")" --arg ref "$new_ref" --argjson port "$old_backend" \
                        '$bindings + [{node_ref:$ref,public_port:443,backend_host:"127.0.0.1",backend_port:$port}]') || status=1
                    declare -gA frontend_reserved_backend_ports
                    frontend_reserved_backend_ports[$old_backend]=1
                fi
            else
                candidate_node_json=$node_json
                frontend_new_bindings=$(jq -c --arg ref "$old_ref" '.bindings | map(select(.node_ref != $ref))' <<<"$frontend_profile") || status=1
            fi
            if [[ ! $status ]]; then
                printf '%s\n' "$candidate_node_json" >"$frontend_candidate_nodes/$new_ref" || status=1
                if [[ $metadata_json ]]; then
                    mkdir -p "$frontend_candidate_nodes/.quan-meta" || status=1
                    printf '%s\n' "$metadata_json" >"$frontend_candidate_nodes/.quan-meta/$new_ref.meta.json" || status=1
                fi
            fi
        else
            frontend_new_bindings=$(jq -c --arg ref "$old_ref" '.bindings | map(select(.node_ref != $ref))' <<<"$frontend_profile") || status=1
        fi
    fi
    if [[ ! $status ]]; then
        source_config="$frontend_txn_dir/config.source"
        if [[ -f $is_config_json ]]; then
            cp -p "$is_config_json" "$source_config" || status=1
        else
            default_runtime_config >"$source_config" || {
                frontend_set_error node_candidate_failed 'Could not construct the shared sing-box configuration.'
                status=1
            }
        fi
        if [[ ! $status ]] && ! render_runtime_node_outbound_modes "$source_config" "$frontend_candidate_config" '' '' "$frontend_candidate_nodes"; then
            frontend_set_error node_candidate_failed "Could not render shared outbound configuration: ${runtime_sync_error:-unknown error}"
            status=1
        fi
        if [[ ! $status ]] && ! "$is_core_bin" check -c "$frontend_candidate_config" -C "$frontend_candidate_nodes" >"$frontend_txn_dir/sing-box-check.log" 2>&1; then
            frontend_set_error singbox_candidate_invalid 'The complete candidate sing-box configuration failed validation.'
            status=1
        fi
    fi
    if [[ ! $status ]]; then
        frontend_render_reality_map "$frontend_new_bindings" "$frontend_candidate_nodes" "$frontend_candidate_map" || status=1
    fi
    if [[ ! $status ]]; then
        map_file=$(jq -r '.ownership.map_file' <<<"$frontend_profile")
        local old_map_sha new_map_sha
        old_map_sha=$(sha256sum "$map_file" | awk '{print $1}') || status=1
        new_map_sha=$(sha256sum "$frontend_candidate_map" | awk '{print $1}') || status=1
        [[ $old_map_sha == "$new_map_sha" ]] || map_changed=true
        old_profile_bindings=$(jq -c '.bindings' <<<"$frontend_profile") || status=1
        [[ $old_profile_bindings == "$frontend_new_bindings" ]] || profile_changed=true
        if [[ $map_changed == true ]]; then
            frontend_check_binding_map_candidate || status=1
            profile_changed=true
        fi
    fi
    if [[ ! $status && $profile_changed == true ]]; then
        map_sha=$(sha256sum "$frontend_candidate_map" | awk '{print $1}') || status=1
        new_revision=$(( $(jq -r '.revision' <<<"$frontend_profile") + 1 ))
        profile_after="$frontend_txn_dir/profile.after"
        jq -c --argjson revision "$new_revision" --argjson bindings "$frontend_new_bindings" --arg path "$map_file" --arg sha "$map_sha" '
            .revision=$revision
            | .bindings=$bindings
            | .ownership.map_sha256=$sha
            | .ownership.files |= map(if .path == $path then .sha256=$sha else . end)
        ' <<<"$frontend_profile" >"$profile_after" || status=1
        chmod 600 "$profile_after" 2>/dev/null || status=1
    fi
    if [[ ! $status ]]; then
        frontend_txn_action=node
        frontend_txn_files='[]'
        frontend_txn_paths=()
        frontend_guard_paths=()
        frontend_changed_targets=("$is_config_json" "$is_conf_dir/$old_ref" "$is_conf_dir/$new_ref" "$old_meta_path" "$new_meta_path" "$map_file" "$is_core_dir/frontend.json")
        frontend_make_guards "$map_file" || status=1
        frontend_verify_original_sources || status=1
    fi
    if [[ ! $status ]]; then
        if [[ $operation == delete || $new_ref != "$old_ref" ]]; then
            frontend_txn_add_change_if_different "$is_conf_dir/$old_ref" '' backend_config || status=1
        fi
        if [[ ! $status && $operation == replace ]]; then
            frontend_txn_add_change_if_different "$is_conf_dir/$new_ref" "$frontend_candidate_nodes/$new_ref" backend_config 644 || status=1
        fi
        if [[ ! $status && ( $operation == delete || $new_ref != "$old_ref" ) && -e $old_meta_path ]]; then
            frontend_txn_add_change_if_different "$old_meta_path" '' node_metadata || status=1
        fi
        if [[ ! $status && $operation == replace && -f $frontend_candidate_nodes/.quan-meta/$new_ref.meta.json ]]; then
            frontend_txn_add_change_if_different "$new_meta_path" "$frontend_candidate_nodes/.quan-meta/$new_ref.meta.json" node_metadata 600 || status=1
        fi
        if [[ ! $status ]]; then
            frontend_txn_add_change_if_different "$is_config_json" "$frontend_candidate_config" backend_config 600 || status=1
        fi
        if [[ ! $status && $map_changed == true ]]; then
            frontend_txn_add_change_if_different "$map_file" "$frontend_candidate_map" project_file 644 || status=1
        fi
        if [[ ! $status && $profile_changed == true ]]; then
            frontend_txn_add_change_if_different "$is_core_dir/frontend.json" "$profile_after" profile 600 || status=1
        fi
        if [[ ! $status && ${#frontend_txn_paths[@]} -gt 0 ]]; then
            frontend_verify_original_sources || status=1
            [[ $status ]] || frontend_txn_commit || status=1
        elif [[ ! $status ]]; then
            rm -rf -- "$frontend_txn_dir"
        fi
    fi
    if [[ $status ]]; then
        local original_code=$frontend_error_code original_message=$frontend_error_message
        frontend_read_phase || :
        if [[ $frontend_txn_dir && $frontend_phase != recovery_required ]]; then
            rm -rf -- "${frontend_txn_dir:-}"
        fi
        frontend_error_code=$original_code
        frontend_error_message=$original_message
    else
        is_config_file=$new_ref
        is_config_name=$new_ref
    fi
    frontend_unlock_state
    return "${status:-0}"
}

frontend_candidate_check() {
    local candidate=$1 binary prefix output
    binary=$(jq -r '.binary' <<<"$frontend_nginx")
    prefix=$(jq -r '.prefix' <<<"$frontend_nginx")
    output=$("$binary" -t -p "$prefix" -c "$candidate" 2>&1)
    if [[ $? != 0 ]]; then
        frontend_set_error candidate_validation_failed 'The complete isolated Nginx candidate failed the active binary configuration check.'
        return 1
    fi
    return 0
}

frontend_make_guards() {
    local anchor=$1 path hash index duplicate
    frontend_txn_guards='[]'
    for ((index = 0; index < ${#frontend_original_files[@]}; index++)); do
        path=${frontend_original_files[$index]}
        hash=${frontend_original_hashes[$index]}
        local target
        duplicate=0
        for target in "${frontend_changed_targets[@]}"; do
            [[ $path == "$target" ]] && duplicate=1
        done
        ((duplicate == 0)) || continue
        duplicate=0
        local existing
        for existing in "${frontend_guard_paths[@]}"; do
            [[ $existing == "$path" ]] && duplicate=1
        done
        ((duplicate == 0)) || continue
        frontend_guard_paths+=("$path")
        frontend_txn_guards=$(jq -cn --argjson guards "$frontend_txn_guards" --arg path "$path" --arg sha "$hash" '$guards + [{path:$path,sha256:$sha}]') || return 1
    done
}

frontend_verify_original_sources() {
    local index path expected actual
    for ((index = 0; index < ${#frontend_original_files[@]}; index++)); do
        path=${frontend_original_files[$index]}
        expected=${frontend_original_hashes[$index]}
        [[ -f $path && ! -L $path ]] || {
            frontend_set_error config_drift "Nginx configuration source changed type during candidate validation: $path"
            return 1
        }
        actual=$(sha256sum "$path" | awk '{print $1}') || return 1
        [[ $actual == "$expected" ]] || {
            frontend_set_error config_drift "Nginx configuration source changed during candidate validation: $path"
            return 1
        }
    done
}

frontend_plan_enable() {
    local kind=$1 anchor=$2 anchor_line=$3 final_map=$4 candidate_map=$5 final_stream=$6 candidate_stream=$7 aux_port=$8 map_variable=$9
    local config_file prefix flat_config candidate_config nginx_anchor_candidate candidate_block final_block candidate_stream_text final_stream_text final_hash next_revision listen_json expected_entry_file return_required ownership files_json
    local -a saved_entry_addresses=()
    config_file=$(jq -r '.config' <<<"$frontend_nginx")
    prefix=$(jq -r '.prefix' <<<"$frontend_nginx")
    flat_config="$frontend_txn_dir/candidate-tree.conf"
    candidate_config="$frontend_txn_dir/candidate.conf"
    nginx_anchor_candidate="$frontend_txn_dir/nginx-anchor.after"
    candidate_map="$frontend_txn_dir/candidate-reality-map.conf"
    candidate_stream="$frontend_txn_dir/final-stream.conf"
    if ((${#frontend_migration_refs[@]} == 0)); then
        printf '# Empty Reality mappings are managed by one-singbox.\n' >"$candidate_map" || return 1
    else
        candidate_map=$frontend_candidate_map
    fi
    frontend_flatten_file "$config_file" "$flat_config" || return 1
    frontend_scan_config_tree "$flat_config" "$prefix" || return 1

    case $kind in
    existing_map)
        [[ $frontend_entry_type == existing_map ]] || {
            frontend_set_error config_drift 'The compatible Reality map changed during candidate preparation.'
            return 1
        }
        candidate_block=$(frontend_marker_block existing_map "$candidate_map" "$candidate_map" "$map_variable" "")
        candidate_block="# one-singbox-frontend:candidate\n${candidate_block}"
        frontend_write_insert_before_line "$flat_config" "$frontend_entry_line" "$candidate_block" "$candidate_config" || {
            frontend_set_error nginx_candidate_failed 'Could not insert the project map into the isolated Nginx candidate.'
            return 1
        }
        final_block=$(frontend_marker_block existing_map "$final_map" "$final_map" "$map_variable" "")
        expected_entry_file=$anchor
        return_required=false
        ;;
    empty_stream)
        [[ $frontend_entry_type == empty_stream && ${#frontend_scan_stream_ends[@]} == 1 ]] || {
            frontend_set_error config_drift 'The empty stream block changed during candidate preparation.'
            return 1
        }
        [[ ${frontend_scan_stream_starts[0]} != "${frontend_scan_stream_ends[0]}" ]] || {
            frontend_set_error nginx_config_unsupported 'A one-line empty stream block cannot be edited without changing surrounding bytes.'
            return 1
        }
        saved_entry_addresses=("${frontend_listen_addresses[@]}")
        candidate_block=$'# one-singbox-frontend:candidate\n'
        candidate_block+="$(frontend_render_stream_body "$candidate_map" "$map_variable" "$aux_port" '    ')"
        frontend_write_insert_before_line "$flat_config" "${frontend_scan_stream_ends[0]}" "$candidate_block" "$candidate_config" || {
            frontend_set_error nginx_candidate_failed 'Could not insert the Reality entrance into the isolated Nginx candidate.'
            return 1
        }
        final_block=$(frontend_marker_block empty_stream "" "$final_map" "$map_variable" "$aux_port")
        expected_entry_file=$anchor
        return_required=true
        ;;
    new_stream)
        candidate_stream_text=$(frontend_render_stream_file "$candidate_map" "$map_variable" "$aux_port")
        candidate_block=$'# one-singbox-frontend:candidate\n'
        candidate_block+="$candidate_stream_text"
        frontend_write_append "$flat_config" "$candidate_block" "$candidate_config" || return 1
        final_stream_text=$(frontend_render_stream_file "$final_map" "$map_variable" "$aux_port")
        printf '%s' "$final_stream_text" >"$candidate_stream" || return 1
        final_block=$(frontend_marker_block new_stream "$final_stream" "$final_map" "$map_variable" "$aux_port")
        expected_entry_file=$final_stream
        return_required=true
        ;;
    *)
        frontend_set_error nginx_config_unsupported "Unsupported empty-mode entry type: $kind"
        return 1
        ;;
    esac
    frontend_candidate_check "$candidate_config" || return 1

    case $kind in
    new_stream)
        frontend_write_append "$anchor" "$final_block" "$nginx_anchor_candidate" || return 1
        ;;
    empty_stream | existing_map)
        frontend_write_insert_before_line "$anchor" "$anchor_line" "$final_block" "$nginx_anchor_candidate" || return 1
        ;;
    esac
    if ((${#frontend_migration_refs[@]} == 0)); then
        printf '# Empty Reality mappings are managed by one-singbox.\n' >"$frontend_txn_dir/map.after" || return 1
    else
        cp "$frontend_candidate_map" "$frontend_txn_dir/map.after" || return 1
    fi
    final_hash=$(sha256sum "$frontend_txn_dir/map.after" | awk '{print $1}') || return 1
    local block_hash=$(printf '%s\n' "$final_block" | sha256sum | awk '{print $1}')
    local stream_hash=
    [[ $kind == new_stream ]] && stream_hash=$(sha256sum "$candidate_stream" | awk '{print $1}')

    if [[ $kind == existing_map ]]; then
        IFS=, read -r -a saved_entry_addresses <<<"${frontend_entry_addresses:-}"
        ((${#saved_entry_addresses[@]} > 0)) || {
            frontend_set_error nginx_listener_address_unknown 'Could not determine the existing TCP 443 listener addresses.'
            return 1
        }
        local address_index
        for address_index in "${!saved_entry_addresses[@]}"; do
            [[ ${saved_entry_addresses[$address_index]} == '*' ]] && saved_entry_addresses[$address_index]=0.0.0.0
        done
    fi
    if [[ $kind == empty_stream || $kind == new_stream ]]; then
        listen_json=$(printf '%s\n' "${frontend_listen_addresses[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))') || return 1
    else
        listen_json=$(printf '%s\n' "${saved_entry_addresses[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))') || return 1
    fi
    local final_nginx
    final_nginx=$(jq -c \
        --arg entry_type existing_map \
        --arg entry_file "$expected_entry_file" \
        --arg map_variable "$map_variable" \
        --argjson return_required "$return_required" \
        --argjson listener_443 true \
        '. + {entry_type:$entry_type,entry_file:$entry_file,map_variable:$map_variable,return_required:$return_required,listener_443:$listener_443} | .modules.return=$return_required' \
        <<<"$frontend_nginx") || return 1
    files_json=$(jq -cn --arg path "$final_map" --arg sha "$final_hash" '[{path:$path,sha256:$sha}]') || return 1
    if [[ $kind == new_stream ]]; then
        files_json=$(jq -cn --argjson files "$files_json" --arg path "$final_stream" --arg sha "$stream_hash" '$files + [{path:$path,sha256:$sha}]') || return 1
    fi
    ownership=$(jq -cn \
        --arg anchor "$anchor" \
        --arg kind "$kind" \
        --arg block_sha "$block_hash" \
        --arg map_file "$final_map" \
        --arg map_sha "$final_hash" \
        --arg stream_file "$([[ $kind == new_stream ]] && printf '%s' "$final_stream")" \
        --arg stream_sha "$stream_hash" \
        --argjson reject_port "$([[ $return_required == true ]] && printf '%s' "$aux_port" || printf null)" \
        --argjson files "$files_json" \
        '{anchor_file:$anchor,anchor_kind:$kind,load_block_sha256:$block_sha,map_file:$map_file,map_sha256:$map_sha,stream_file:$stream_file,stream_sha256:$stream_sha,reject_port:$reject_port,files:$files}') || return 1
    if [[ -f $is_core_dir/frontend.json ]]; then
        next_revision=$(( $(jq -r '.revision' "$is_core_dir/frontend.json") + 1 ))
    else
        next_revision=1
    fi
    jq -n \
        --argjson revision "$next_revision" \
        --argjson listen_addresses "$listen_json" \
        --argjson nginx "$final_nginx" \
        --argjson ownership "$ownership" \
        --argjson bindings "${frontend_new_bindings:-[]}" \
        '{schema_version:1,enabled:true,revision:$revision,engine:"nginx",listen_addresses:$listen_addresses,bindings:$bindings,nginx:$nginx,ownership:$ownership}' >"$frontend_txn_dir/profile.after" || return 1
    chmod 600 "$frontend_txn_dir/profile.after" || return 1

    frontend_txn_action=enable
    frontend_txn_files='[]'
    frontend_txn_paths=()
    frontend_guard_paths=()
    frontend_changed_targets=("$anchor")
    frontend_make_guards "$anchor" || return 1
    frontend_verify_original_sources || return 1
    if ((${#frontend_migration_refs[@]} > 0)); then
        local node_ref metadata_ref
        for node_ref in "${frontend_candidate_node_refs[@]}"; do
            frontend_txn_add_change "$is_conf_dir/$node_ref" "$frontend_candidate_nodes/$node_ref" backend_config 644 || return 1
        done
        for metadata_ref in "${frontend_candidate_meta_refs[@]}"; do
            frontend_txn_add_change "$(meta_file "$metadata_ref")" "$frontend_candidate_nodes/.quan-meta/$metadata_ref.meta.json" backend_config 600 || return 1
        done
        frontend_txn_add_change "$is_config_json" "$frontend_candidate_config" backend_config 600 || return 1
    fi
    frontend_txn_add_change "$final_map" "$frontend_txn_dir/map.after" project_file 644 || return 1
    if [[ $kind == new_stream ]]; then
        frontend_txn_add_change "$final_stream" "$candidate_stream" project_file 644 || return 1
    fi
    frontend_txn_add_change "$anchor" "$nginx_anchor_candidate" nginx_config 644 || return 1
    frontend_txn_add_change "$is_core_dir/frontend.json" "$frontend_txn_dir/profile.after" profile 600 || return 1
    frontend_verify_original_sources || return 1
    frontend_txn_commit
}

frontend_enable_locked() {
    local status
    frontend_load_profile || {
        frontend_set_error "$frontend_profile_error_code" "$frontend_profile_error_message"
        return 1
    }
    frontend_read_phase || {
        frontend_set_error "$frontend_phase_error_code" "$frontend_phase_error_message"
        return 1
    }
    frontend_pending_change || return 1
    if [[ $frontend_profile ]] && jq -e '.enabled == true' <<<"$frontend_profile" >/dev/null; then
        (($# == 0)) || {
            frontend_set_error already_enabled 'The frontend is already enabled; node references are accepted only during first migration.'
            return 1
        }
        frontend_refresh_detection || return 1
        printf '443 SNI 前置已启用，revision %s。\n' "$(jq -r '.revision' <<<"$frontend_profile")"
        return 0
    fi
    if [[ $frontend_profile ]] && jq -e '.bindings | length > 0' <<<"$frontend_profile" >/dev/null; then
        frontend_set_error profile_bindings_present 'A disabled profile still contains bindings; refusing to enable an inconsistent state.'
        return 1
    fi
    frontend_validate_migration_refs "$@" || return 1
    frontend_listener_range_selected=0
    frontend_allow_unknown_listener_range=1
    frontend_refresh_detection || {
        local detect_status=$?
        frontend_allow_unknown_listener_range=0
        frontend_migration_active=0
        return "$detect_status"
    }
    frontend_allow_unknown_listener_range=0
    frontend_migration_active=0
    frontend_original_files=("${frontend_scan_source_files[@]}")
    frontend_original_hashes=("${frontend_scan_source_hashes[@]}")
    local kind=$frontend_entry_type anchor=$frontend_entry_file anchor_line=$frontend_entry_line project_dir final_map final_stream candidate_map candidate_stream aux_port=
    if [[ $kind == existing_map ]]; then
        frontend_listen_addresses=()
    else
        frontend_choose_addresses || return 1
    fi
    if ((${#frontend_migration_refs[@]} > 0)); then
        frontend_migration_handoff=1
    fi
    frontend_read_tcp_listeners || {
        frontend_migration_handoff=0
        return 1
    }
    frontend_migration_handoff=0
    if [[ $kind != existing_map ]]; then
        frontend_choose_aux_port || return 1
        aux_port=$frontend_aux_port
    fi
    if [[ $kind == existing_map ]]; then
        frontend_map_variable=$frontend_entry_map_variable
    else
        frontend_choose_map_variable || return 1
    fi
    local config_file
    config_file=$(jq -r '.config' <<<"$frontend_nginx")
    project_dir="$(dirname -- "$config_file")/one-singbox"
    [[ $project_dir != *[[:space:]]* ]] || {
        frontend_set_error nginx_path_unsupported 'Nginx project paths containing whitespace are not supported.'
        return 1
    }
    [[ ! -L $project_dir && ( ! -e $project_dir || -d $project_dir ) ]] || {
        frontend_set_error project_path_conflict "The Nginx project directory is not a regular directory: $project_dir"
        return 1
    }
    final_map="$project_dir/reality-map.conf"
    final_stream="$project_dir/stream.conf"
    if [[ -e $final_map || -L $final_map || ( $kind == new_stream && ( -e $final_stream || -L $final_stream ) ) ]]; then
        frontend_set_error project_file_conflict 'A project-owned Nginx file already exists without a matching enabled profile.'
        return 1
    fi
    frontend_txn_dir="$is_core_dir/.frontend-state/txn.$$.$RANDOM"
    mkdir -m 700 "$frontend_txn_dir" || {
        frontend_set_error state_unwritable 'Could not create a private frontend transaction directory.'
        return 1
    }
    frontend_new_bindings='[]'
    if ((${#frontend_migration_refs[@]} > 0)); then
        frontend_prepare_binding_bundle || {
            status=$?
            frontend_migration_active=0
            rm -rf -- "$frontend_txn_dir"
            return "$status"
        }
    fi
    candidate_map="$frontend_txn_dir/candidate-reality-map.conf"
    candidate_stream="$frontend_txn_dir/final-stream.conf"
    frontend_plan_enable "$kind" "$anchor" "$anchor_line" "$final_map" "" "$final_stream" "" "$aux_port" "$frontend_map_variable"
    status=$?
    frontend_migration_active=0
    if ((status != 0)); then
        local original_code=$frontend_error_code original_message=$frontend_error_message
        frontend_read_phase || :
        [[ $frontend_phase == recovery_required ]] || rm -rf -- "$frontend_txn_dir"
        frontend_error_code=$original_code
        frontend_error_message=$original_message
        return "$status"
    fi
    printf '443 SNI 前置已启用，revision %s。\n' "$(jq -r '.revision' "$is_core_dir/frontend.json")"
}

frontend_enable() {
    local status
    frontend_lock_state || {
        printf '%s\n' "$frontend_error_message" >&2
        return 1
    }
    frontend_enable_locked "$@"
    status=$?
    frontend_unlock_state
    if ((status != 0)); then
        printf '%s\n' "$frontend_error_message" >&2
        return "$status"
    fi
    return 0
}

frontend_disable_locked() {
    local anchor kind block_hash config_file flat_config candidate_config project_dir map_variable record path expected actual next_revision ownership_files
    local -a original_files=() original_hashes=() owned_records=() changed_files=()
    frontend_load_profile || {
        frontend_set_error "$frontend_profile_error_code" "$frontend_profile_error_message"
        return 1
    }
    frontend_read_phase || {
        frontend_set_error "$frontend_phase_error_code" "$frontend_phase_error_message"
        return 1
    }
    frontend_pending_change || return 1
    if [[ ! $frontend_profile ]] || ! jq -e '.enabled == true' <<<"$frontend_profile" >/dev/null; then
        printf '443 SNI 前置未启用。\n'
        return 0
    fi
    local binding_count
    binding_count=$(jq -r '.bindings | length' <<<"$frontend_profile")
    if ((binding_count > 0)); then
        frontend_set_error bindings_present "Cannot disable while nodes are bound: $(jq -r '[.bindings[].node_ref] | join(", ")' <<<"$frontend_profile")"
        return 1
    fi
    frontend_refresh_detection || return 1
    original_files=("${frontend_scan_source_files[@]}")
    original_hashes=("${frontend_scan_source_hashes[@]}")
    anchor=$(jq -r '.ownership.anchor_file // empty' <<<"$frontend_profile")
    kind=$(jq -r '.ownership.anchor_kind // empty' <<<"$frontend_profile")
    block_hash=$(jq -r '.ownership.load_block_sha256 // empty' <<<"$frontend_profile")
    map_variable=$(jq -r '.nginx.map_variable // empty' <<<"$frontend_profile")
    config_file=$(jq -r '.nginx.config' <<<"$frontend_profile")
    project_dir="$(dirname -- "$config_file")/one-singbox"
    [[ $anchor == /* && $block_hash =~ ^[0-9a-f]{64}$ && $kind =~ ^(new_stream|empty_stream|existing_map)$ ]] || {
        frontend_set_error invalid_profile 'The enabled profile does not contain valid Nginx ownership information.'
        return 1
    }
    if [[ $kind == new_stream || $kind == empty_stream ]]; then
        local source
        for source in "${original_files[@]}"; do
            [[ $source == "$anchor" || $source == "$project_dir/stream.conf" || $source == "$project_dir/reality-map.conf" ]] && continue
            if grep -Fq -- "$map_variable" "$source" || grep -Fq -- "$project_dir" "$source"; then
                frontend_set_error shared_entry_in_use "Nginx file $source refers to the project-created Reality entry; keep the shared entry and review that dependency before disabling."
                return 1
            fi
        done
    fi
    ownership_files=$(jq -c '.ownership.files // []' <<<"$frontend_profile")
    jq -e 'type == "array" and length > 0 and all(.[]; .path | type == "string")' <<<"$ownership_files" >/dev/null || {
        frontend_set_error invalid_profile 'The enabled profile has no safe project-file ownership list.'
        return 1
    }
    mapfile -t owned_records <<<"$(jq -c '.[]' <<<"$ownership_files")"
    for record in "${owned_records[@]}"; do
        path=$(jq -r '.path' <<<"$record")
        expected=$(jq -r '.sha256' <<<"$record")
        [[ $path == "$project_dir/"* && $expected =~ ^[0-9a-f]{64}$ && -f $path && ! -L $path ]] || {
            frontend_set_error owned_file_drift "A project-owned Nginx file is missing or has an unsafe path: $path"
            return 1
        }
        actual=$(sha256sum "$path" | awk '{print $1}') || return 1
        [[ $actual == "$expected" ]] || {
            frontend_set_error shared_entry_changed "Project-owned file $path changed after enable; preserving the shared entry because it may now have user dependencies."
            return 1
        }
        changed_files+=("$path")
    done

    frontend_txn_dir="$is_core_dir/.frontend-state/txn.$$.$RANDOM"
    mkdir -m 700 "$frontend_txn_dir" || {
        frontend_set_error state_unwritable 'Could not create a private frontend transaction directory.'
        return 1
    }
    flat_config="$frontend_txn_dir/candidate-tree.conf"
    candidate_config="$frontend_txn_dir/candidate-without-entry.conf"
    : >"$flat_config"
    if ! frontend_flatten_file "$config_file" "$flat_config" || ! frontend_remove_marker_block "$flat_config" "$candidate_config"; then
        rm -rf -- "$frontend_txn_dir"
        return 1
    fi
    if ! frontend_candidate_check "$candidate_config"; then
        rm -rf -- "$frontend_txn_dir"
        return 1
    fi
    frontend_remove_marker_block "$anchor" "$frontend_txn_dir/config.after" "$block_hash" || {
        rm -rf -- "$frontend_txn_dir"
        return 1
    }
    jq -c '.revision + 1' <<<"$frontend_profile" >"$frontend_txn_dir/revision" || return 1
    next_revision=$(cat "$frontend_txn_dir/revision")
    jq -c --argjson revision "$next_revision" '.enabled=false | .revision=$revision | .bindings=[] | .ownership={}' <<<"$frontend_profile" >"$frontend_txn_dir/profile.after" || return 1
    chmod 600 "$frontend_txn_dir/profile.after" || return 1

    frontend_original_files=("${original_files[@]}")
    frontend_original_hashes=("${original_hashes[@]}")
    frontend_changed_targets=("$anchor" "${changed_files[@]}")
    frontend_guard_paths=()
    frontend_txn_action=disable
    frontend_txn_files='[]'
    frontend_txn_paths=()
    frontend_make_guards "$anchor" || return 1
    frontend_verify_original_sources || return 1
    frontend_txn_add_change "$anchor" "$frontend_txn_dir/config.after" nginx_config 644 || return 1
    for path in "${changed_files[@]}"; do
        frontend_txn_add_change "$path" "" project_file 644 || return 1
    done
    frontend_txn_add_change "$is_core_dir/frontend.json" "$frontend_txn_dir/profile.after" profile 600 || return 1
    frontend_verify_original_sources || return 1
    frontend_txn_commit || return $?
    rmdir -- "$project_dir" 2>/dev/null || :
    printf '443 SNI 前置已停用，revision %s。\n' "$next_revision"
}

frontend_disable() {
    local status
    frontend_lock_state || {
        printf '%s\n' "$frontend_error_message" >&2
        return 1
    }
    frontend_disable_locked
    status=$?
    frontend_unlock_state
    if ((status != 0)); then
        printf '%s\n' "$frontend_error_message" >&2
        return "$status"
    fi
    return 0
}

frontend_recover_locked() {
    local transaction_file="$is_core_dir/.frontend-state/transaction.json" phase status
    if [[ ! -e $transaction_file && ! -L $transaction_file ]]; then
        printf '没有待恢复的前置事务。\n'
        return 0
    fi
    frontend_read_phase || {
        frontend_set_error "$frontend_phase_error_code" "$frontend_phase_error_message"
        return 1
    }
    phase=$frontend_phase
    case $phase in
    committed | rolled_back)
        printf '没有待恢复的前置事务（%s）。\n' "$phase"
        return 0
        ;;
    esac
    frontend_txn_rollback
    status=$?
    if ((status == 0)); then
        printf '前置事务已恢复。\n'
    fi
    return "$status"
}

frontend_recover() {
    local status transaction_file="$is_core_dir/.frontend-state/transaction.json"
    if [[ ! -e $transaction_file && ! -L $transaction_file ]]; then
        printf '没有待恢复的前置事务。\n'
        return 0
    fi
    frontend_lock_state || {
        printf '%s\n' "$frontend_error_message" >&2
        return 1
    }
    frontend_recover_locked
    status=$?
    frontend_unlock_state
    if ((status != 0)); then
        printf '%s\n' "$frontend_error_message" >&2
        return "$status"
    fi
    return 0
}

frontend_check() {
    local json=${1:-} enabled=false revision=0 bindings='[]' errors='[]' phase=idle nginx=null
    if ! frontend_load_profile; then
        errors=$(jq -cn --arg code "$frontend_profile_error_code" --arg message "$frontend_profile_error_message" '[{code:$code,message:$message}]')
    elif [[ $frontend_profile ]]; then
        enabled=$(jq -c '.enabled' <<<"$frontend_profile")
        revision=$(jq -c '.revision' <<<"$frontend_profile")
        bindings=$(jq -c '.bindings' <<<"$frontend_profile")
    fi
    if [[ $errors == '[]' ]]; then
        if ! frontend_read_phase; then
            errors=$(jq -cn --arg code "$frontend_phase_error_code" --arg message "$frontend_phase_error_message" '[{code:$code,message:$message}]')
        else
            phase=$frontend_phase
            case $phase in
            prepared | backend_applied | frontend_applied | verified | rolling_back | recovery_required)
                errors=$(jq -cn --arg phase "$phase" '[{code:"recovery_required",message:("前置事务未完成，当前阶段：" + $phase + "。继续操作前请先运行 frontend recover。")}]')
                ;;
            esac
        fi
    fi
    if [[ $errors == '[]' ]] && ! frontend_refresh_detection; then
        errors=$(jq -cn --arg code "$frontend_error_code" --arg message "$frontend_error_message" '[{code:$code,message:$message}]')
    fi
    [[ $errors != '[]' ]] || nginx=$frontend_nginx

    if [[ $json == --json ]]; then
        local ok=true
        [[ $errors == '[]' ]] || ok=false
        frontend_emit_json "$ok" "$enabled" "$revision" "$phase" "$nginx" "$bindings" "$errors"
    else
        if [[ $errors == '[]' ]]; then
            printf 'Nginx 检查通过。\n'
        else
            jq -r '.[0].message' <<<"$errors" >&2
        fi
    fi
    [[ $errors == '[]' ]]
}

frontend_main() {
    local action=${1:-status}
    shift || :

    case $action in
    status)
        if [[ ${1:-} && $1 != --json ]] || [[ $# -gt 1 ]]; then
            printf '用法: %s frontend status [--json]\n' "$is_core_name" >&2
            return 2
        fi
        frontend_status "${1:-}"
        return $?
        ;;
    check)
        if [[ ${1:-} && $1 != --json ]] || [[ $# -gt 1 ]]; then
            printf '用法: %s frontend check [--json]\n' "$is_core_name" >&2
            return 2
        fi
        frontend_check "${1:-}"
        return $?
        ;;
    enable)
        frontend_enable "$@"
        return $?
        ;;
    disable)
        [[ $# == 0 ]] || {
            printf '用法: %s frontend disable\n' "$is_core_name" >&2
            return 2
        }
        frontend_disable
        return $?
        ;;
    recover)
        [[ $# == 0 ]] || {
            printf '用法: %s frontend recover\n' "$is_core_name" >&2
            return 2
        }
        frontend_recover
        return $?
        ;;
    *)
        printf '用法: %s frontend [status [--json] | check [--json] | enable [node-ref ...] | disable | recover]\n' "$is_core_name" >&2
        return 2
        ;;
    esac
}

frontend_menu_enable() {
    local file selected
    local -a nodes=() refs=()
    shopt -s nullglob
    for file in "$is_conf_dir"/*.json; do
        [[ -f $file && ! -L $file ]] || continue
        frontend_config_has_tcp_port "$file" 443 && nodes+=("${file##*/}")
    done
    shopt -u nullglob
    if ((${#nodes[@]} == 0)); then
        frontend_main enable
        return $?
    fi
    printf '现有公网 443 节点：%s\n' "${nodes[*]}"
    read -r -p '输入要纳管的节点文件名（可多选，以空格分隔）: ' -a refs || return 1
    ((${#refs[@]} > 0)) || {
        printf '请明确选择要迁移的节点；取消可返回菜单。\n' >&2
        return 1
    }
    frontend_main enable "${refs[@]}"
}

frontend_menu() {
    local action
    while :; do
        printf '\n443 SNI 前置\n'
        printf '1) 状态\n2) 检查\n3) 启用空绑定模式/纳管现有节点\n4) 停用\n5) 恢复未完成事务\n0) 返回\n'
        read -r -p '请选择: ' action || return
        case $action in
        0) return ;;
        1) frontend_main status ;;
        2) frontend_main check ;;
        3) frontend_menu_enable ;;
        4) frontend_main disable ;;
        5) frontend_main recover ;;
        *) printf '无效选项。\n' ;;
        esac
    done
}
