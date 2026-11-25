# Node and relay sidecar metadata (.quan-meta) and note helpers.

meta_dir() {
    echo "$is_conf_dir/.quan-meta"
}

meta_file() {
    echo "$(meta_dir)/$1.meta.json"
}

meta_get() {
    local f
    f=$(meta_file "$1")
    [[ -f "$f" ]] || return
    jq -r "$2 // empty" "$f" 2>/dev/null
}

meta_set_unlocked() {
    local cfg=$1
    local key=$2
    local val=$3
    local f
    f=$(meta_file "$cfg")
    mkdir -p "$(meta_dir)"
    if [[ -f "$f" ]]; then
        jq --arg v "$val" ".$key=\$v" "$f" >"$f.tmp" && mv -f "$f.tmp" "$f"
    else
        jq -n --arg v "$val" "{$key:\$v}" >"$f"
    fi
}

meta_set() {
    shared_config_lock || return 1
    meta_set_unlocked "$@"
    local status=$?
    shared_config_unlock
    return "$status"
}

meta_move_unlocked() {
    local old=$1
    local new=$2
    local of nf
    of=$(meta_file "$old")
    nf=$(meta_file "$new")
    if [[ -f "$of" ]]; then
        mv -f "$of" "$nf" || return $?
    fi
    return 0
}

meta_move() {
    shared_config_lock || return 1
    meta_move_unlocked "$@"
    local status=$?
    shared_config_unlock
    return "$status"
}

meta_del_unlocked() {
    local cfg=$1
    local key=$2
    local f
    f=$(meta_file "$cfg")
    [[ -f "$f" ]] || return 0
    if jq --arg k "$key" 'del(.[$k])' "$f" >"$f.tmp"; then
        if jq -e 'length == 0' "$f.tmp" >/dev/null 2>&1; then
            rm -f "$f.tmp" "$f"
        else
            mv -f "$f.tmp" "$f"
        fi
    else
        rm -f "$f.tmp"
        return 1
    fi
}

meta_del() {
    shared_config_lock || return 1
    meta_del_unlocked "$@"
    local status=$?
    shared_config_unlock
    return "$status"
}

meta_rm_unlocked() {
    local cfg=$1
    local f
    f=$(meta_file "$cfg")
    if [[ -f "$f" ]]; then
        rm -f "$f" || return $?
    fi
    return 0
}

meta_rm() {
    shared_config_lock || return 1
    meta_rm_unlocked "$@"
    local status=$?
    shared_config_unlock
    return "$status"
}

note_trim() {
    local val=${1-}
    val=${val//$'\r'/ }
    val=${val//$'\n'/ }
    val=${val#"${val%%[![:space:]]*}"}
    val=${val%"${val##*[![:space:]]}"}
    printf '%s\n' "$val"
}

note_read_line() {
    local target_var=$1
    local raw= status=0 read_timeout=${ONE_SINGBOX_READ_TIMEOUT:-3}
    local IFS=
    if [[ -t 0 ]]; then
        interactive_read -r raw || status=$?
    else
        interactive_read -t "$read_timeout" -r raw || status=$?
    fi
    if ((status > 128)); then
        printf -v "$target_var" '%s' ''
        return 1
    fi
    printf -v "$target_var" '%s' "$raw"
    [[ $status == 0 || -n $raw ]]
}

note_get() {
    local cfg=$1 raw
    [[ $cfg ]] || return 0
    raw=$(meta_get "$cfg" '.note')
    [[ $raw ]] || return 0
    note_trim "$raw"
}

note_set() {
    local cfg=$1 val
    [[ $cfg ]] || return 1
    val=$(note_trim "${2-}")
    if [[ -z $val ]]; then
        note_clear "$cfg"
        return $?
    fi
    meta_set "$cfg" note "$val"
}

note_clear() {
    local cfg=$1
    [[ $cfg ]] || return 1
    meta_del "$cfg" note
}

note_summary() {
    local text limit=${2:-30}
    text=$(note_trim "${1-}")
    [[ -z $text ]] && return 0
    if ((${#text} <= limit)); then
        printf '%s\n' "$text"
        return 0
    fi
    jq -rn --arg s "$text" --argjson limit "$limit" 'if ($s | length) > $limit then ($s[0:$limit] + "...") else $s end' 2>/dev/null || printf '%s...\n' "${text:0:limit}"
}

note_edit_interactive() {
    local cfg=$1 current= raw_input= trimmed=
    [[ $cfg ]] || return 1
    current=$(note_get "$cfg")
    if [[ $current ]]; then
        printf '\n当前备注: %s\n' "$current"
    else
        printf '\n当前备注: (无)\n'
    fi
    echo -ne "请输入新备注 (直接回车保持不变，输入 - 或 clear 清空):"
    if ! note_read_line raw_input; then
        msg "\n备注保持不变.\n"
        return 0
    fi
    trimmed=$(note_trim "$raw_input")
    if [[ -z $trimmed ]]; then
        msg "\n备注保持不变.\n"
        return 0
    fi
    if [[ $trimmed == - || $trimmed == clear ]]; then
        note_clear "$cfg" || err "清空备注失败."
        msg "\n已清空备注.\n"
        return 0
    fi
    note_set "$cfg" "$trimmed" || err "保存备注失败."
    printf '\n已更新备注: \e[92m%s\e[0m\n\n' "$trimmed"
}

note_apply_cli() {
    local cfg=${1-}
    [[ $cfg ]] || return 1
    if (($# < 2)) || { (($# == 2)) && [[ -z $2 ]]; }; then
        note_edit_interactive "$cfg" || return $?
    elif (($# == 2)) && [[ $2 == '--clear' ]]; then
        note_clear "$cfg" || err "清空备注失败."
        msg "\n已清空备注.\n"
    else
        local IFS=' '
        local raw_note="${*:2}" trimmed_note
        trimmed_note=$(note_trim "$raw_note")
        [[ $trimmed_note ]] || err "备注内容不能为空，如需清空请使用 --clear."
        note_set "$cfg" "$trimmed_note" || err "保存备注失败."
        printf '\n已更新备注: \e[92m%s\e[0m\n\n' "$trimmed_note"
    fi
}

note_format_list_label() {
    local cfg=$1 base_label=$2 note= summary=
    [[ $cfg ]] && note=$(note_get "$cfg")
    if [[ $note ]]; then
        summary=$(note_summary "$note")
        printf '%s  [备注: %s]\n' "$base_label" "${summary:-$note}"
    else
        printf '%s\n' "$base_label"
    fi
}

node_name_for_link() {
    local cfg=$1
    local name
    name=$(meta_get "$cfg" '.node_name')
    [[ $name ]] && {
        echo "$name"
        return
    }
    echo "${cfg%.json}"
}
