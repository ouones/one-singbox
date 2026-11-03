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
        printf '443 SNI 前置：未启用\nrevision：0\n'
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
        frontend_profile_error_message='frontend.json must be a regular file, not a symlink.'
        return 1
    fi
    if ! jq -e . "$profile_file" >/dev/null 2>&1; then
        frontend_profile_error_code=invalid_profile
        frontend_profile_error_message='frontend.json is not valid JSON.'
        return 1
    fi
    if [[ $(jq -r '.schema_version // empty' "$profile_file") != 1 ]]; then
        frontend_profile_error_code=unsupported_schema
        frontend_profile_error_message='frontend.json uses an unsupported schema_version.'
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
        frontend_profile_error_message='frontend.json does not match schema_version 1.'
        return 1
    fi
    frontend_profile=$(jq -c . "$profile_file") || {
        frontend_profile_error_code=invalid_profile
        frontend_profile_error_message='frontend.json could not be read.'
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
        frontend_phase_error_message='The saved frontend transaction record is missing or invalid.'
        frontend_phase=recovery_required
        return 1
    fi
    frontend_phase=$(jq -r '.phase' "$transaction_file")
    case $frontend_phase in
    prepared | frontend_applied | verified | committed | rolling_back | rolled_back | recovery_required) ;;
    *)
        frontend_phase_error_code=transaction_corrupt
        frontend_phase_error_message="The saved frontend transaction has an unknown phase: $frontend_phase"
        frontend_phase=recovery_required
        return 1
        ;;
    esac
    return 0
}

frontend_status() {
    local json=${1:-} enabled revision nginx bindings errors phase=idle
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
            prepared | frontend_applied | verified | rolling_back | recovery_required)
                errors=$(jq -cn --arg phase "$phase" '[{code:"recovery_required",message:("An interrupted frontend transaction is in phase " + $phase + ". Run frontend recover before changing it.")}]')
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
        prepared | frontend_applied | verified | rolling_back | recovery_required)
            errors=$(jq -cn --arg phase "$phase" '[{code:"recovery_required",message:("An interrupted frontend transaction is in phase " + $phase + ". Run frontend recover before changing it.")}]')
            ;;
        esac
    fi

    enabled=$(jq -c '.enabled' <<<"$frontend_profile")
    revision=$(jq -c '.revision' <<<"$frontend_profile")
    nginx=$(jq -c '.nginx' <<<"$frontend_profile")
    bindings=$(jq -c '.bindings' <<<"$frontend_profile")
    if [[ $json == --json ]]; then
        local ok=true
        [[ $errors == '[]' ]] || ok=false
        frontend_emit_json "$ok" "$enabled" "$revision" "$phase" "$nginx" "$bindings" "$errors"
    else
        printf '443 SNI 前置：%s\nrevision：%s\nbindings：%s\n' \
            "$([[ $enabled == true ]] && printf '已启用' || printf '未启用')" \
            "$revision" "$(jq -r 'length' <<<"$bindings")"
    fi
}

frontend_set_error() {
    frontend_error_code=$1
    frontend_error_message=$2
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
    local file=$1 context=$2 records kind a b c d child include_pattern
    local -a includes

    [[ ${frontend_scan_active[$file]+yes} ]] && {
        frontend_set_error nginx_config_unsupported "Nginx configuration include cycle reaches $file"
        return 1
    }
    frontend_scan_active[$file]=1
    frontend_scan_source_files+=("$file")
    frontend_scan_source_hashes+=("$(sha256sum "$file" | awk '{print $1}')")
    records=$(awk -v initial_context="$context" -v source_file="$file" '
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
        function output_server(i) {
            if (has_context("stream")) {
                printf "STREAMSERVER\t%d\t%d\t%d\t%s\t%s\t%s\n", server_has_tcp443[i], server_has_udp443[i], server_preread[i], server_proxy[i], server_ports[i], server_addresses[i]
            } else if (has_context("http")) {
                printf "HTTPSERVER\t%d\t%s\n", server_has_tcp443[i], server_ports[i]
            }
        }
        function process_statement(i, port, udp, active_server, include_context, address, extracted_port) {
            if (word_count == 0) return
            if (words[1] == "include") {
                include_context = "top"
                if (has_context("map")) include_context = "map"
                else if (has_context("stream")) include_context = "stream"
                else if (has_context("server")) include_context = "server"
                else if (has_context("http")) include_context = "http"
                printf "INCLUDE\t%d\t%d\t%d\t%s\t%s\n", FNR, word_starts[1], char_index, include_context, words[2]
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
                    }
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

    while IFS=$'\t' read -r kind a b c d e f; do
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
        STREAMSERVER)
            frontend_scan_server_443+=("$a")
            frontend_scan_server_udp443+=("$b")
            frontend_scan_server_preread+=("$c")
            frontend_scan_server_proxy+=("$d")
            frontend_scan_configured_port_lists+=("$e")
            frontend_scan_server_addresses+=("$f")
            ;;
        HTTPSERVER)
            [[ $a == 1 ]] && frontend_scan_http_443+=("$file")
            frontend_scan_configured_port_lists+=("$b")
            ;;
        INCLUDE)
            local include_line=$a include_start=$b include_end=$c include_context=$d
            child=$include_context
            include_pattern=$e
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
                if ! frontend_scan_config_file "$canonical_file" "$child"; then
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
                frontend_flatten_file "$child" "$output" || return 1
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
    frontend_scan_server_443=()
    frontend_scan_server_udp443=()
    frontend_scan_server_preread=()
    frontend_scan_server_proxy=()
    frontend_scan_configured_port_lists=()
    frontend_scan_server_addresses=()
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

frontend_read_tcp_listeners() {
    local output line state recv send local_address peer process port owner_pid owner_exe
    frontend_error_code=
    frontend_error_message=
    declare -gA frontend_bound_ports=()
    declare -gA frontend_configured_ports=()
    frontend_bound_ports=()
    frontend_configured_ports=()
    frontend_running_443=0
    frontend_nginx_pid=$(jq -r '.pid' <<<"$frontend_nginx")
    frontend_nginx_binary_real=$(readlink -f "$(jq -r '.binary' <<<"$frontend_nginx")" 2>/dev/null) || frontend_nginx_binary_real=
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
        [[ $process ]] || {
            frontend_set_error tcp_443_owner_unknown 'TCP 443 is occupied, but ss did not report the owning process.'
            return 1
        }
        local found_owner=0 owner_is_nginx=1
        while [[ $process =~ pid=([0-9]+) ]]; do
            owner_pid=${BASH_REMATCH[1]}
            found_owner=1
            owner_exe=$(readlink -f "/proc/$owner_pid/exe" 2>/dev/null) || owner_exe=
            [[ $owner_exe == "$frontend_nginx_binary_real" ]] || owner_is_nginx=0
            process=${process#*"pid=$owner_pid"}
        done
        [[ $found_owner == 1 && $owner_is_nginx == 1 ]] || {
            frontend_set_error tcp_443_port_conflict 'TCP 443 is owned by a process outside the selected Nginx instance.'
            return 1
        }
        frontend_running_443=1
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
    if [[ $configured_443 == 1 && $frontend_running_443 != 1 ]]; then
        frontend_set_error nginx_listener_missing 'Nginx configuration contains a TCP 443 listener, but the selected service does not own a running TCP 443 socket.'
        return 1
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
}

frontend_unlock_state() {
    if [[ $frontend_lock_fd ]]; then
        flock -u "$frontend_lock_fd" 2>/dev/null || :
        exec {frontend_lock_fd}>&-
        frontend_lock_fd=
    fi
}

frontend_pending_change() {
    case ${frontend_phase:-idle} in
    prepared | frontend_applied | verified | rolling_back | recovery_required)
        frontend_set_error recovery_required "A frontend transaction is in phase $frontend_phase. Run frontend recover before changing it."
        return 1
        ;;
    esac
    return 0
}

frontend_choose_addresses() {
    local ipv4 ipv6 choice
    local -a options=()
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
        done < <(jq -r '.inbounds[]?.listen_port // empty' "$file")
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
        '{schema_version:1,action:$action,phase:$phase,dir:$dir,files:$files,guards:$guards,nginx:$nginx}') || return 1
    frontend_atomic_write "$transaction_file" "$json"$'\n' 600
}

frontend_txn_set_phase() {
    local phase=$1 transaction_file="$is_core_dir/.frontend-state/transaction.json" json
    json=$(jq -c --arg phase "$phase" '.phase=$phase' "$transaction_file") || return 1
    frontend_atomic_write "$transaction_file" "$json"$'\n' 600 || return 1
    frontend_phase=$phase
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
    local expected_binary=$1 expected_real pid args process_real
    expected_real=$(readlink -f "$expected_binary" 2>/dev/null) || return 1
    while read -r pid args; do
        [[ $pid =~ ^[0-9]+$ && $args == *'nginx: worker process'* ]] || continue
        process_real=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || continue
        [[ $process_real == "$expected_real" ]] && printf '%s\n' "$pid"
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
    before=$(frontend_worker_pids "$binary")
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
        after=$(frontend_worker_pids "$binary")
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
        (.action == "enable" or .action == "disable") and
        (.phase == "prepared" or .phase == "frontend_applied" or .phase == "verified" or .phase == "rolling_back" or .phase == "recovery_required") and
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

frontend_txn_rollback() {
    local transaction_file="$is_core_dir/.frontend-state/transaction.json" record path role before_exists before_sha before_file before_mode before_owner after_exists after_sha after_mode after_owner current_sha current_mode current_owner current_exists temp applied_config=false index
    local -a file_records=()
    [[ -f $transaction_file && ! -L $transaction_file ]] || {
        frontend_set_error transaction_corrupt 'The frontend transaction record is unavailable for recovery.'
        return 1
    }
    frontend_txn_validate_manifest || return 1
    frontend_nginx=$(jq -c '.nginx' "$transaction_file") || return 1
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
            [[ $role == nginx_config ]] && applied_config=true
        elif [[ $current_exists == "$before_exists" && ( $before_exists == false || ( $current_sha == "$before_sha" && $current_mode == "$before_mode" && $current_owner == "$before_owner" ) ) ]]; then
            :
        else
            frontend_set_error config_drift "File changed after the frontend transaction; refusing to overwrite $path"
            frontend_txn_set_phase recovery_required || :
            return 1
        fi
    done

    frontend_txn_set_phase rolling_back || {
        frontend_set_error transaction_state_write_failed 'Could not persist the rolling_back transaction phase.'
        return 1
    }
    for ((index = ${#file_records[@]} - 1; index >= 0; index--)); do
        record=${file_records[$index]}
        path=$(jq -r '.path' <<<"$record")
        before_exists=$(jq -r '.before_exists' <<<"$record")
        before_sha=$(jq -r '.before_sha256' <<<"$record")
        after_exists=$(jq -r '.after_exists' <<<"$record")
        after_sha=$(jq -r '.after_sha256' <<<"$record")
        current_exists=false
        [[ -e $path ]] && current_exists=true
        current_sha=
        [[ $current_exists == true ]] && current_sha=$(sha256sum "$path" | awk '{print $1}')
        if [[ $current_exists == "$before_exists" && ( $before_exists == false || $current_sha == "$before_sha" ) ]]; then
            continue
        fi
        if [[ $before_exists == true ]]; then
            before_file=$(jq -r '.before_file' <<<"$record")
            before_mode=$(jq -r '.before_mode' <<<"$record")
            before_owner=$(jq -r '.before_owner' <<<"$record")
            mkdir -p -- "$(dirname -- "$path")" || {
                frontend_set_error recovery_failed "Could not create the parent directory for $path."
                frontend_txn_set_phase recovery_required || :
                return 1
            }
            temp="${path}.one-singbox-recover.$$"
            cp -p -- "$before_file" "$temp" && chmod "$before_mode" "$temp" && chown "$before_owner" "$temp" && mv -f -- "$temp" "$path" || {
                rm -f "$temp"
                frontend_set_error recovery_failed "Could not restore $path from its transaction backup."
                frontend_txn_set_phase recovery_required || :
                return 1
            }
        else
            rm -f -- "$path" || {
                frontend_set_error recovery_failed "Could not remove the transaction-created file $path."
                frontend_txn_set_phase recovery_required || :
                return 1
            }
        fi
    done
    if [[ $applied_config == true ]]; then
        frontend_reload_and_confirm "$frontend_nginx" || {
            frontend_set_error recovery_failed "Files were restored, but Nginx recovery could not be verified: $frontend_error_message"
            frontend_txn_set_phase recovery_required || :
            return 1
        }
    fi
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
    local record original_code original_message index
    local -a operation_records=()
    frontend_txn_write_record prepared || {
        frontend_set_error transaction_state_write_failed 'Could not persist the prepared frontend transaction.'
        return 1
    }
    mapfile -t operation_records < <(jq -c '.[] | select(.role != "profile")' <<<"$frontend_txn_files")
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
    frontend_txn_set_phase frontend_applied || {
        frontend_set_error transaction_state_write_failed 'Could not persist the frontend_applied transaction phase.'
        frontend_txn_rollback || :
        return 1
    }
    if ! frontend_reload_and_confirm "$frontend_nginx"; then
        original_code=$frontend_error_code
        original_message=$frontend_error_message
        if frontend_txn_rollback; then
            frontend_set_error "$original_code" "$original_message"
        else
            frontend_set_error recovery_required "$original_message Recovery is required: $frontend_error_message"
        fi
        return 1
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
    local config_file prefix flat_config candidate_config candidate_block final_block candidate_stream_text final_stream_text final_hash next_revision listen_json expected_entry_file return_required ownership files_json
    local -a saved_entry_addresses=()
    config_file=$(jq -r '.config' <<<"$frontend_nginx")
    prefix=$(jq -r '.prefix' <<<"$frontend_nginx")
    flat_config="$frontend_txn_dir/candidate-tree.conf"
    candidate_config="$frontend_txn_dir/candidate.conf"
    candidate_map="$frontend_txn_dir/candidate-reality-map.conf"
    candidate_stream="$frontend_txn_dir/final-stream.conf"
    printf '# Empty Reality mappings are managed by one-singbox.\n' >"$candidate_map" || return 1
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
        frontend_write_append "$anchor" "$final_block" "$frontend_txn_dir/config.after" || return 1
        ;;
    empty_stream | existing_map)
        frontend_write_insert_before_line "$anchor" "$anchor_line" "$final_block" "$frontend_txn_dir/config.after" || return 1
        ;;
    esac
    printf '# Empty Reality mappings are managed by one-singbox.\n' >"$frontend_txn_dir/map.after" || return 1
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
        '{schema_version:1,enabled:true,revision:$revision,engine:"nginx",listen_addresses:$listen_addresses,bindings:[],nginx:$nginx,ownership:$ownership}' >"$frontend_txn_dir/profile.after" || return 1
    chmod 600 "$frontend_txn_dir/profile.after" || return 1

    frontend_txn_action=enable
    frontend_txn_files='[]'
    frontend_txn_paths=()
    frontend_guard_paths=()
    frontend_changed_targets=("$anchor")
    frontend_make_guards "$anchor" || return 1
    frontend_verify_original_sources || return 1
    frontend_txn_add_change "$final_map" "$frontend_txn_dir/map.after" project_file 644 || return 1
    if [[ $kind == new_stream ]]; then
        frontend_txn_add_change "$final_stream" "$candidate_stream" project_file 644 || return 1
    fi
    frontend_txn_add_change "$anchor" "$frontend_txn_dir/config.after" nginx_config 644 || return 1
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
        frontend_refresh_detection || return 1
        printf '443 SNI 前置已启用，revision %s。\n' "$(jq -r '.revision' <<<"$frontend_profile")"
        return 0
    fi
    if [[ $frontend_profile ]] && jq -e '.bindings | length > 0' <<<"$frontend_profile" >/dev/null; then
        frontend_set_error profile_bindings_present 'A disabled profile still contains bindings; refusing to enable an inconsistent state.'
        return 1
    fi
    frontend_refresh_detection || return 1
    frontend_original_files=("${frontend_scan_source_files[@]}")
    frontend_original_hashes=("${frontend_scan_source_hashes[@]}")
    local kind=$frontend_entry_type anchor=$frontend_entry_file anchor_line=$frontend_entry_line project_dir final_map final_stream candidate_map candidate_stream aux_port=
    if [[ $kind == existing_map ]]; then
        frontend_listen_addresses=()
    else
        frontend_choose_addresses || return 1
    fi
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
    candidate_map="$frontend_txn_dir/candidate-reality-map.conf"
    candidate_stream="$frontend_txn_dir/final-stream.conf"
    frontend_plan_enable "$kind" "$anchor" "$anchor_line" "$final_map" "" "$final_stream" "" "$aux_port" "$frontend_map_variable"
    status=$?
    if ((status != 0)); then
        rm -rf -- "$frontend_txn_dir"
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
    frontend_enable_locked
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
            prepared | frontend_applied | verified | rolling_back | recovery_required)
                errors=$(jq -cn --arg phase "$phase" '[{code:"recovery_required",message:("An interrupted frontend transaction is in phase " + $phase + ". Run frontend recover before continuing.")}]')
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
        if [[ $# -gt 0 ]]; then
            printf '暂不支持迁移节点；此操作只会在空绑定模式中启用。\n' >&2
            return 2
        fi
        frontend_enable
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
        printf '用法: %s frontend [status [--json] | check [--json] | enable | disable | recover]\n' "$is_core_name" >&2
        return 2
        ;;
    esac
}

frontend_menu() {
    local action
    while :; do
        printf '\n443 SNI 前置\n'
        printf '1) 状态\n2) 检查\n3) 启用空绑定模式\n4) 停用\n5) 恢复未完成事务\n0) 返回\n'
        read -r -p '请选择: ' action || return
        case $action in
        0) return ;;
        1) frontend_main status ;;
        2) frontend_main check ;;
        3) frontend_main enable ;;
        4) frontend_main disable ;;
        5) frontend_main recover ;;
        *) printf '无效选项。\n' ;;
        esac
    done
}
