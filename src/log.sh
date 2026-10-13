log_limit_valid() {
    [[ $1 =~ ^[1-9][0-9]*$ && ${#1} -le 13 ]] && (( $1 <= 8796093022207 ))
}

log_limit_read() {
    local value=
    [[ -f $is_core_dir/log-limit-mb ]] && read -r value <"$is_core_dir/log-limit-mb"
    log_limit_valid "$value" || value=200
    printf '%s\n' "$value"
}

# Copy/truncate keeps the core's open log descriptors usable without restarting it.
log_limit_check() {
    local limit=$(($(log_limit_read) * 1048576)) total=0 file size tmp keep
    local files=()
    for file in "$is_log_dir"/*.log "$is_log_dir"/*.log.1; do
        [[ -f $file && ! -L $file ]] || continue
        size=$(stat -c %s "$file") || return 1
        total=$((total + size))
    done
    (( total > limit )) || return 0
    for file in "$is_log_dir"/*.log; do
        [[ -s $file && ! -L $file ]] || continue
        tmp=$(mktemp "$is_log_dir/.log-rotate.XXXXXX") || return 1
        if ! tail -c "$limit" "$file" >"$tmp" || ! chmod 600 "$tmp" || ! touch -r "$file" "$tmp" || ! mv -f "$tmp" "$file.1"; then
            rm -f "$tmp"
            return 1
        fi
        : >"$file"
    done
    # Leave half the budget for new records; discard the oldest archives first.
    keep=$((limit / 2))
    total=0
    for file in "$is_log_dir"/*.log.1; do
        [[ -f $file && ! -L $file ]] || continue
        files+=("$file")
        size=$(stat -c %s "$file") || return 1
        total=$((total + size))
    done
    (( total > keep )) || return 0
    while IFS= read -r file; do
        size=$(stat -c %s "$file") || return 1
        if (( total - size >= keep )); then
            rm -f "$file" || return 1
            total=$((total - size))
        else
            tmp=$(mktemp "$is_log_dir/.log-rotate.XXXXXX") || return 1
            if ! tail -c "$((keep - total + size))" "$file" >"$tmp" || ! chmod 600 "$tmp" || ! touch -r "$file" "$tmp" || ! mv -f "$tmp" "$file"; then
                rm -f "$tmp"
                return 1
            fi
            break
        fi
    done < <(ls -tr -- "${files[@]}")
}

log_limit_service() {
    local service=$is_core-log-limit
    if [[ $is_systemd ]]; then
        if [[ ! -f /lib/systemd/system/$service.service ]]; then
            cat >"/lib/systemd/system/$service.service" <<EOF
[Unit]
Description=$is_core log size limit
After=local-fs.target

[Service]
ExecStart=/bin/bash $is_sh_dir/src/log-limit.sh $is_core_dir $is_log_dir
Restart=always
RestartSec=5
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload || return 1
        fi
        systemctl enable "$service" >/dev/null 2>&1 || return 1
        systemctl restart "$service"
    elif [[ $is_openrc ]]; then
        if [[ ! -f /etc/init.d/$service ]]; then
            cat >"/etc/init.d/$service" <<EOF
#!/sbin/openrc-run
description="$is_core log size limit"
command="/bin/bash"
command_args="$is_sh_dir/src/log-limit.sh $is_core_dir $is_log_dir"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
supervisor=supervise-daemon
depend() {
    need localmount
}
EOF
            chmod +x "/etc/init.d/$service"
        fi
        rc-update add "$service" default >/dev/null 2>&1 || return 1
        rc-service "$service" restart
    else
        return 1
    fi
}

log_limit_init() {
    if [[ -f $is_core_dir/log-limit-mb ]]; then
        if [[ $is_systemd ]]; then
            systemctl is-active --quiet "$is_core-log-limit" && return 0
        elif [[ $is_openrc ]]; then
            rc-service "$is_core-log-limit" status >/dev/null 2>&1 && return 0
        fi
        log_limit_service
        return $?
    fi
    echo 200 >"$is_core_dir/log-limit-mb" || return 1
    if ! log_limit_service; then
        rm -f "$is_core_dir/log-limit-mb"
        return 1
    fi
}

log_limit_set() {
    local current=$(log_limit_read) value
    msg "\n当前日志大小限制: $current MB (默认 200 MB)"
    while :; do
        msg "请输入日志大小限制 (正整数, 单位 MB), 回车保留当前值:"
        IFS= read -r value || return
        [[ ! $value ]] && return 0
        if log_limit_valid "$value"; then
            break
        fi
        msg "请输入有效的正整数 (单位 MB)."
    done
    echo "$value" >"$is_core_dir/log-limit-mb" || return 1
    # Stop the worker before the immediate check to avoid concurrent rotation.
    if [[ $is_systemd && -f /lib/systemd/system/$is_core-log-limit.service ]]; then
        systemctl stop "$is_core-log-limit" || return 1
    elif [[ $is_openrc && -f /etc/init.d/$is_core-log-limit ]]; then
        rc-service "$is_core-log-limit" stop || return 1
    fi
    log_limit_check || { log_limit_service; return 1; }
    log_limit_service || { warn "日志维护服务启动失败，请检查服务状态."; return 1; }
    msg "\n已设置日志大小限制: $(_green "$value MB")\n"
}

log_limit_remove() {
    local service=$is_core-log-limit
    if [[ $is_systemd && -f /lib/systemd/system/$service.service ]]; then
        systemctl disable --now "$service" >/dev/null 2>&1
        rm -f "/lib/systemd/system/$service.service"
        systemctl daemon-reload
    elif [[ $is_openrc && -f /etc/init.d/$service ]]; then
        rc-service "$service" stop >/dev/null 2>&1
        rc-update del "$service" default >/dev/null 2>&1
        rm -f "/etc/init.d/$service"
    fi
}

is_log_level_list=(
    trace
    debug
    info
    warn
    error
    fatal
    panic
    none
    del
)
log_set() {
    if [[ $1 ]]; then
        for v in ${is_log_level_list[@]}; do
            [[ $(grep -E -i "^${1,,}$" <<<$v) ]] && is_log_level_use=$v && break
        done
        [[ ! $is_log_level_use ]] && {
            err "无法识别 log 参数: $@ \n请使用 $is_core log [${is_log_level_list[@]}] 进行相关设定.\n备注: del 参数仅临时删除 log 文件; none 参数将不会生成 log 文件."
        }
        case $is_log_level_use in
        del)
            rm -rf $is_log_dir/*.log $is_log_dir/*.log.1
            msg "\n $(_green 已临时删除 log 文件, 如果你想要完全禁止生成 log 文件请使用: $is_core log none)\n"
            ;;
        none)
            rm -rf $is_log_dir/*.log $is_log_dir/*.log.1
            cat <<<$(jq '.log={"disabled":true}' $is_config_json) >$is_config_json
            ;;
        *)
            cat <<<$(jq '.log={output:"/var/log/'$is_core'/access.log",level:"'$is_log_level_use'","timestamp":true}' $is_config_json) >$is_config_json
            ;;
        esac

        manage restart &
        [[ $1 != 'del' ]] && msg "\n已更新 Log 设定为: $(_green $is_log_level_use)\n"
    else
        if [[ -f $is_log_dir/access.log ]]; then
            msg "\n 提醒: 按 $(_green Ctrl + C) 退出\n"
            tail -f $is_log_dir/access.log
        else
            err "无法找到 log 文件."
        fi
    fi
}
