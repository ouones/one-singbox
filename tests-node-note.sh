#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
cleanup() {
    rm -rf "$workdir"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

setup_lifecycle_test_bin() {
    local case_dir=$1
    mkdir -p "$case_dir/bin" "$case_dir/core" "$case_dir/conf"
    cat >"$case_dir/bin/sing-box" <<'CORE'
#!/usr/bin/env bash
case $1 in
check)
    [[ ${TEST_REJECT_CHECK:-0} == 1 ]] && exit 1
    shift
    cfg= dir=
    while (($#)); do
        case $1 in
        -c) cfg=$2; shift 2 ;;
        -C) dir=$2; shift 2 ;;
        *) shift ;;
        esac
    done
    [[ -f $cfg ]] && jq -e . "$cfg" >/dev/null || exit 1
    if [[ $dir ]]; then
        [[ -d $dir ]] || exit 1
        for f in "$dir"/*.json; do
            [[ -f $f ]] || continue
            jq -e . "$f" >/dev/null || exit 1
        done
    fi
    exit 0
    ;;
generate)
    if [[ $2 == reality-keypair ]]; then
        printf 'PrivateKey: test_priv_key\nPublicKey: test_pub_key\n'
    elif [[ $2 == rand ]]; then
        printf 'AAAAAAAAAAAAAAAAAAAAAA==\n'
    fi
    exit 0
    ;;
version)
    printf 'sing-box version 1.14.0\n'
    exit 0
    ;;
esac
exit 0
CORE
    cat >"$case_dir/bin/ss" <<'SS'
#!/usr/bin/env bash
exit 0
SS
    cat >"$case_dir/bin/systemctl" <<'SYS'
#!/usr/bin/env bash
[[ $1 == is-active ]] && exit 0
[[ $1 == show ]] && printf '4321\n'
exit 0
SYS
    chmod +x "$case_dir/bin/sing-box" "$case_dir/bin/ss" "$case_dir/bin/systemctl"
}
export -f setup_lifecycle_test_bin

run_slice1_helpers() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*" >&2
    exit 1
}

source <(sed '/EUID != 0/d' "$CORE_FILE")
case_dir="$WORKDIR/slice1"
mkdir -p "$case_dir/core" "$case_dir/conf"
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_dont_auto_exit=1
export ip=203.0.113.10 is_dont_get_ip=1

manage_log="$case_dir/manage.log"
: >"$manage_log"
manage() { printf '%s\n' "$*" >>"$manage_log"; }
systemctl() { printf '%s\n' "$*" >>"$manage_log"; return 0; }

printf '{"inbounds":[{"tag":"node-a.json","type":"shadowsocks","listen_port":12345}]}\n' >"$is_conf_dir/node-a.json"
printf '{"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_config_json"
before_node=$(cat "$is_conf_dir/node-a.json")
before_cfg=$(cat "$is_config_json")

# 1. note_trim normalizes surrounding whitespace and line breaks without dropping internal spaces or leading dash.
[[ $(note_trim $'  \t美国  落地 节点 \r\n ') == '美国  落地 节点' ]] || fail "note_trim failed to normalize surrounding whitespace"
[[ $(note_trim '  -flag-like  ') == '-flag-like' ]] || fail "note_trim failed on leading dash"
[[ -z $(note_trim $'  \t \r\n ') ]] || fail "note_trim on whitespace-only should be empty"

# 2. note_set / note_get / note_clear / meta_del preserve sibling metadata and remove empty .meta.json files.
note_set node-a.json '  东京 IPLC  ' || fail "note_set failed on clean node"
meta_path="$is_conf_dir/.quan-meta/node-a.json.meta.json"
[[ -f $meta_path ]] || fail "meta file was not created by note_set"
[[ $(jq -r '.note' "$meta_path") == '东京 IPLC' ]] || fail "stored note was not trimmed: $(cat "$meta_path")"
[[ $(note_get node-a.json) == '东京 IPLC' ]] || fail "note_get mismatch"

note_clear node-a.json || fail "note_clear failed"
[[ ! -e $meta_path ]] || fail "clearing the only metadata key must remove empty meta file"
[[ -z $(note_get node-a.json) ]] || fail "note_get after clear should be empty"

jq -n '{node_name:"KeepName",outbound_mode:"V6优先"}' >"$meta_path"
note_set node-a.json '  香港 备用  ' || fail "note_set with sibling metadata failed"
jq -e '.node_name == "KeepName" and .outbound_mode == "V6优先" and .note == "香港 备用"' "$meta_path" >/dev/null || fail "note_set clobbered sibling metadata"

note_set node-a.json '   ' || fail "note_set with whitespace should succeed by clearing"
jq -e '.node_name == "KeepName" and .outbound_mode == "V6优先" and (has("note") | not)' "$meta_path" >/dev/null || fail "whitespace note_set did not delete .note while preserving siblings"

meta_del node-a.json node_name || fail "meta_del node_name failed"
meta_del node-a.json outbound_mode || fail "meta_del outbound_mode failed"
[[ ! -e $meta_path ]] || fail "meta_del of last remaining key must delete empty meta file"

# 3. note_summary truncates by Unicode characters (30 chars) even under LC_ALL=C.
cjk30='一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十'
cjk31="${cjk30}甲"
mixed30='ab一二三四五六七八九十一二三四五六七八九十一二三四五六七八'
mixed31="${mixed30}9"
[[ $(note_summary "$cjk30") == "$cjk30" ]] || fail "30 CJK chars must not be truncated"
[[ $(note_summary "$cjk31") == "${cjk30}..." ]] || fail "31 CJK chars should truncate to 30 chars + ..."
[[ $(note_summary "$mixed30") == "$mixed30" ]] || fail "30 mixed chars must not be truncated"
[[ $(note_summary "$mixed31") == "${mixed30}..." ]] || fail "31 mixed chars should truncate to 30 chars + ..."

[[ $(cat "$is_conf_dir/node-a.json") == "$before_node" ]] || fail "note helpers mutated node json"
[[ $(cat "$is_config_json") == "$before_cfg" ]] || fail "note helpers mutated runtime config.json"
[[ ! -s $manage_log ]] || fail "note helpers triggered service management"
CASE
}

run_slice2_info_display() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*" >&2
    exit 1
}

source <(sed '/EUID != 0/d' "$CORE_FILE")
case_dir="$WORKDIR/slice2"
mkdir -p "$case_dir/core" "$case_dir/conf/.quan-meta"
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_dont_auto_exit=
is_dont_show_info=
export ip=203.0.113.10 is_dont_get_ip=1
render_qrcode() { printf '%s\n' "$1" >"$case_dir/qr-last-url"; return 0; }

cat >"$is_conf_dir/ss-plain.json" <<'JSON'
{"inbounds":[{"tag":"ss-plain.json","type":"shadowsocks","listen":"::","listen_port":20001,"method":"aes-128-gcm","password":"secret"}]}
JSON
meta_set ss-plain.json node_name 'MySSLabel'

ss_out=$(info ss-plain.json 2>&1) || fail "info ss-plain failed"
grep -Fq '出口方式' <<<"$ss_out" || fail "info missing 出口方式 label: $ss_out"
grep -Fq 'IPv4 优先' <<<"$ss_out" || fail "info missing default IPv4 优先 outbound: $ss_out"
! grep -Fq '备注' <<<"$ss_out" || fail "info must omit 备注 when node has no note: $ss_out"
is_dont_show_info=1 info ss-plain.json
[[ $is_url == *'#MySSLabel' ]] || fail "ss share url lost node_name: $is_url"
is_dont_show_info=

cat >"$is_conf_dir/reality-noted.json" <<'JSON'
{"inbounds":[{"tag":"reality-noted.json","type":"vless","listen":"::","listen_port":20002,"users":[{"uuid":"11111111-1111-4111-8111-111111111111"}],"tls":{"server_name":"edge.example.com","reality":{"private_key":"priv"}}}],"outbounds":[{"type":"direct"},{"tag":"public_key_pub","type":"direct"}]}
JSON
long_note='这是一条超过三十个字符的完整备注用于验证详情页不会被截断显示内容'
jq -n --arg note "$long_note" '{node_name:"MyRealityName",outbound_mode:"SS 出站",outbound_proxy:{name:"日本IEPL落地",config:{type:"shadowsocks",server:"1.2.3.4",server_port:8388,method:"aes-128-gcm",password:"pw"}},note:$note}' >"$is_conf_dir/.quan-meta/reality-noted.json.meta.json"

rm -f "$case_dir/qr-last-url"
reality_out=$(info reality-noted.json 2>&1) || fail "info reality-noted failed"
grep -Fq '出口方式' <<<"$reality_out" || fail "reality info missing 出口方式: $reality_out"
grep -Fq 'Shadowsocks 出口 (日本IEPL落地)' <<<"$reality_out" || fail "reality info missing proxy outbound display: $reality_out"
grep -Fq '备注' <<<"$reality_out" || fail "reality info missing 备注 label: $reality_out"
grep -Fq "$long_note" <<<"$reality_out" || fail "reality info truncated or omitted full note: $reality_out"
! grep -Fq '这是一条超过三十个字符的完整备注用于验证详情页不会被截断显...' <<<"$reality_out" || fail "reality info must not truncate note"
[[ $(cat "$case_dir/qr-last-url") != *"$long_note"* ]] || fail "QR input leaked note"
is_dont_show_info=1 info reality-noted.json
[[ $is_url == *'#MyRealityName' && $is_url != *"$long_note"* ]] || fail "reality share url polluted by note: $is_url"
is_dont_show_info=

cat >"$is_conf_dir/snell-noted.json" <<'JSON'
{"inbounds":[{"tag":"snell-noted.json","type":"snell","listen":"::","listen_port":20003,"version":6,"psk":"abcdefghijklmnop","mode":"default"}]}
JSON
meta_set snell-noted.json node_name 'SnellCustom'
note_set snell-noted.json 'Snell-Secret-Note'
snell_out=$(info snell-noted.json 2>&1) || fail "info snell-noted failed"
grep -Fq '出口方式' <<<"$snell_out" || fail "snell info missing 出口方式"
grep -Fq '备注' <<<"$snell_out" || fail "snell info missing 备注"
grep -Fq 'Snell-Secret-Note' <<<"$snell_out" || fail "snell info missing note content"
is_dont_show_info=1 info snell-noted.json
[[ $is_url == *'#SnellCustom' && $is_url != *'Snell-Secret-Note'* ]] || fail "snell url polluted by note: $is_url"
[[ $is_surge_str == 'SnellCustom = snell,'* && $is_surge_str != *'Snell-Secret-Note'* ]] || fail "snell surge config polluted by note: $is_surge_str"
CASE
}

run_slice3_node_selection_list() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*" >&2
    exit 1
}

source <(sed '/EUID != 0/d' "$CORE_FILE")
case_dir="$WORKDIR/slice3"
mkdir -p "$case_dir/core" "$case_dir/conf/.quan-meta"
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_main_start=1
is_dont_auto_exit=
export ip=203.0.113.10 is_dont_get_ip=1
render_qrcode() { :; }

cat >"$is_conf_dir/node-a.json" <<'JSON'
{"inbounds":[{"tag":"node-a.json","type":"shadowsocks","listen":"::","listen_port":21001,"method":"aes-128-gcm","password":"pass1"}]}
JSON
cat >"$is_conf_dir/node-b.json" <<'JSON'
{"inbounds":[{"tag":"node-b.json","type":"shadowsocks","listen":"::","listen_port":21002,"method":"aes-128-gcm","password":"pass2"}]}
JSON

long33='一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十甲乙丙'
meta_set node-a.json node_name 'ClientAliasA'
note_set node-a.json "$long33"
meta_set node-b.json node_name 'ClientAliasB'

# 1. Direct get file selection maps display entry back to raw filename.
list_out=$(
    is_config_file=
    get file <<<$'1\n' 2>&1
) || fail "get file selection failed: $list_out"
grep -Fq '1) node-a.json  [备注: 一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十...]' <<<"$list_out" || fail "node list missing truncated note summary: $list_out"
grep -Fxq '2) node-b.json' <<<"$list_out" || fail "plain node entry altered or has placeholder: $list_out"
! grep -Fq 'node-b.json  [备注:' <<<"$list_out" || fail "plain node must not show note placeholder: $list_out"
! grep -Fq 'ClientAliasA' <<<"$list_out" && ! grep -Fq 'ClientAliasB' <<<"$list_out" || fail "node list must not splice custom node_name: $list_out"

selected_cfg=$(
    is_config_file=
    get file <<<$'1\n' >/dev/null 2>&1
    printf '%s' "$is_config_file"
)
[[ $selected_cfg == 'node-a.json' ]] || fail "is_config_file polluted by note summary: '$selected_cfg'"

# 2. node_menu view and delete lists show note summaries and resolve real filename.
view_out=$(node_menu 2>&1 <<'INPUT'
3
1

0
INPUT
) || fail "node_menu view failed: $view_out"
grep -Fq '1) node-a.json  [备注: 一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十...]' <<<"$view_out" || fail "node_menu view list missing note summary: $view_out"
grep -Fq '备注' <<<"$view_out" && grep -Fq "$long33" <<<"$view_out" || fail "node_menu view did not open full details for selected noted node: $view_out"

del_out=$(node_menu 2>&1 <<'INPUT'
4
1
n

0
INPUT
) || fail "node_menu delete list failed: $del_out"
grep -Fq '1) node-a.json  [备注: 一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十...]' <<<"$del_out" || fail "node_menu delete list missing note summary: $del_out"
grep -Fq '将删除节点“node-a.json”及其配置文件 node-a.json' <<<"$del_out" || fail "delete confirmation received polluted filename: $del_out"
[[ -f "$is_conf_dir/node-a.json" ]] || fail "canceled delete removed node-a.json"
CASE
}

run_slice4_interactive_edit() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*" >&2
    exit 1
}

source <(sed '/EUID != 0/d' "$CORE_FILE")
case_dir="$WORKDIR/slice4"
mkdir -p "$case_dir/core" "$case_dir/conf"
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_main_start=1
is_dont_auto_exit=
export ip=203.0.113.10 is_dont_get_ip=1
render_qrcode() { :; }
manage_log="$case_dir/manage.log"
: >"$manage_log"
manage() { printf '%s\n' "$*" >>"$manage_log"; }
systemctl() { printf '%s\n' "$*" >>"$manage_log"; return 0; }

cat >"$is_conf_dir/node-a.json" <<'JSON'
{"inbounds":[{"tag":"node-a.json","type":"shadowsocks","listen":"::","listen_port":22001,"method":"aes-128-gcm","password":"pass1"}]}
JSON
cat >"$is_conf_dir/node-b.json" <<'JSON'
{"inbounds":[{"tag":"node-b.json","type":"shadowsocks","listen":"::","listen_port":22002,"method":"aes-128-gcm","password":"pass2"}]}
JSON
printf '{"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_config_json"
before_a=$(cat "$is_conf_dir/node-a.json")
before_cfg=$(cat "$is_config_json")

# 1. Interactive node_menu -> 修改 -> 备注 sets note, shows (无), and returns to menu cleanly.
set_out=$(node_menu 2>&1 <<'INPUT'
2
1
9
  初始 备注  

0
INPUT
) || fail "node_menu edit note failed: $set_out"
grep -Fq '9) 备注' <<<"$set_out" || fail "modify menu did not append 备注 at index 9: $set_out"
grep -Fq '当前备注: (无)' <<<"$set_out" || fail "interactive edit did not show (无): $set_out"
grep -Fq '请输入新备注 (直接回车保持不变，输入 - 或 clear 清空):' <<<"$set_out" || fail "interactive edit missing exact prompt: $set_out"
[[ $(note_get node-a.json) == '初始 备注' ]] || fail "note not saved after interactive edit: $(note_get node-a.json)"

# 2. Direct Enter and whitespace-only preserve existing note.
keep_enter_out=$(node_menu 2>&1 <<'INPUT'
2
1
9


0
INPUT
) || fail "node_menu keep-on-enter failed: $keep_enter_out"
grep -Fq '当前备注: 初始 备注' <<<"$keep_enter_out" || fail "interactive edit did not show current note: $keep_enter_out"
[[ $(note_get node-a.json) == '初始 备注' ]] || fail "Enter cleared existing note"

keep_ws_out=$(node_menu 2>&1 <<'INPUT'
2
1
9
   

0
INPUT
) || fail "node_menu keep-on-whitespace failed: $keep_ws_out"
[[ $(note_get node-a.json) == '初始 备注' ]] || fail "whitespace-only cleared existing note"

# 3. '-' clears note and removes empty .meta.json.
clear_dash_out=$(node_menu 2>&1 <<'INPUT'
2
1
9
-

0
INPUT
) || fail "node_menu clear with '-' failed: $clear_dash_out"
[[ -z $(note_get node-a.json) ]] || fail "'-' did not clear note"
[[ ! -e "$is_conf_dir/.quan-meta/node-a.json.meta.json" ]] || fail "'-' did not remove empty meta file"

# 4. 'clear' clears note and removes empty .meta.json.
note_set node-a.json '二次备注'
clear_word_out=$(node_menu 2>&1 <<'INPUT'
2
1
9
clear

0
INPUT
) || fail "node_menu clear with 'clear' failed: $clear_word_out"
[[ -z $(note_get node-a.json) ]] || fail "'clear' did not clear note"
[[ ! -e "$is_conf_dir/.quan-meta/node-a.json.meta.json" ]] || fail "'clear' did not remove empty meta file"

# 5. Non-TTY anti-hang guard: /dev/null and silent open pipe do not hang and keep note intact.
note_set node-a.json '防挂死保留'
timeout 2 bash -c '
    source <(sed "/EUID != 0/d" "$1")
    is_core_dir="$2/core"
    is_conf_dir="$2/conf"
    note_edit_interactive node-a.json </dev/null
' _ "$CORE_FILE" "$case_dir" >"$case_dir/eof.out" 2>&1 || fail "note_edit_interactive hung or failed on /dev/null"
[[ $(note_get node-a.json) == '防挂死保留' ]] || fail "/dev/null altered note"

timeout 5 bash -c '
    source <(sed "/EUID != 0/d" "$1")
    is_core_dir="$2/core"
    is_conf_dir="$2/conf"
    note_edit_interactive node-a.json
' _ "$CORE_FILE" "$case_dir" < <(sleep 6) >"$case_dir/pipe-timeout.out" 2>&1 || fail "note_edit_interactive hung on silent pipe"
[[ $(note_get node-a.json) == '防挂死保留' ]] || fail "silent pipe timeout altered note"

[[ $(cat "$is_conf_dir/node-a.json") == "$before_a" ]] || fail "interactive note edits mutated node json"
[[ $(cat "$is_config_json") == "$before_cfg" ]] || fail "interactive note edits mutated runtime config.json"
[[ ! -s $manage_log ]] || fail "interactive note edits triggered service restart: $(cat "$manage_log")"
CASE
}

run_slice5_cli_commands() {
    local repo_dir=$1
    REPO_DIR="$repo_dir" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${REPO_DIR}): $*" >&2
    exit 1
}

source <(sed '/EUID != 0/d' "$REPO_DIR/src/core.sh")
case_dir="$WORKDIR/slice5"
mkdir -p "$case_dir/core" "$case_dir/conf"
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_main_start=
is_dont_auto_exit=
export ip=203.0.113.10 is_dont_get_ip=1
render_qrcode() { :; }
manage_log="$case_dir/manage.log"
: >"$manage_log"
manage() { printf '%s\n' "$*" >>"$manage_log"; }
systemctl() { printf '%s\n' "$*" >>"$manage_log"; return 0; }

cat >"$is_conf_dir/node-a.json" <<'JSON'
{"inbounds":[{"tag":"node-a.json","type":"shadowsocks","listen":"::","listen_port":23001,"method":"aes-128-gcm","password":"pass1"}]}
JSON
cat >"$is_conf_dir/node-b.json" <<'JSON'
{"inbounds":[{"tag":"node-b.json","type":"shadowsocks","listen":"::","listen_port":23002,"method":"aes-128-gcm","password":"pass2"}]}
JSON
printf '{"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_config_json"
before_a=$(cat "$is_conf_dir/node-a.json")
before_b=$(cat "$is_conf_dir/node-b.json")
before_cfg=$(cat "$is_config_json")

# 1. sb change <node> note with quoted multi-space string and unquoted multi-word args.
(main change node-a.json note '  香港  落地 线路  ') >/dev/null || fail "main change note quoted failed"
[[ $(note_get node-a.json) == '香港  落地 线路' ]] || fail "main change note quoted mismatch: '$(note_get node-a.json)'"

(main change node-a.json note 新加坡 直连 节点) >/dev/null || fail "main change note unquoted failed"
[[ $(note_get node-a.json) == '新加坡 直连 节点' ]] || fail "main change note unquoted mismatch: '$(note_get node-a.json)'"

# 2. sb change <node> note --clear clears note and deletes empty meta file.
(main change node-a.json note --clear) >/dev/null || fail "main change note --clear failed"
[[ -z $(note_get node-a.json) ]] || fail "main change note --clear did not clear note"
[[ ! -e "$is_conf_dir/.quan-meta/node-a.json.meta.json" ]] || fail "main change note --clear left empty meta file"

# 3. sb note <node> with quoted value, 'auto', unquoted words, and --clear.
(main note node-a.json '  美国   BGP * 测试  ') >/dev/null || fail "main note quoted failed"
[[ $(note_get node-a.json) == '美国   BGP * 测试' ]] || fail "main note quoted mismatch: '$(note_get node-a.json)'"

(main note node-a.json auto) >/dev/null || fail "main note literal 'auto' failed"
[[ $(note_get node-a.json) == 'auto' ]] || fail "main note treated 'auto' as keyword instead of literal note: '$(note_get node-a.json)'"

(main note node-a.json 日本 东京 备用) >/dev/null || fail "main note unquoted multi-word failed"
[[ $(note_get node-a.json) == '日本 东京 备用' ]] || fail "main note unquoted mismatch: '$(note_get node-a.json)'"

(main note node-a.json --clear) >/dev/null || fail "main note --clear failed"
[[ -z $(note_get node-a.json) ]] || fail "main note --clear did not clear"

# 4. Omitting note text enters interactive edit; omitting node selects node first.
(main note node-b.json <<<$'交互快捷备注\n') >/dev/null || fail "main note <node> interactive failed"
[[ $(note_get node-b.json) == '交互快捷备注' ]] || fail "main note <node> interactive did not save note"

(main change node-b.json note <<<$'clear\n') >/dev/null || fail "main change <node> note interactive clear failed"
[[ -z $(note_get node-b.json) ]] || fail "main change <node> note interactive clear did not clear"

omit_node_out=$(main note 2>&1 <<'INPUT'
2
无节点快捷备注
INPUT
) || fail "main note (no node) failed: $omit_node_out"
[[ $(note_get node-b.json) == '无节点快捷备注' ]] || fail "main note (no node) did not save note to chosen node"

# 5. Whitespace-only CLI note is rejected without clearing existing note.
if (main note node-b.json '   ') >/dev/null 2>&1; then
    fail "whitespace-only CLI note should fail instead of silently clearing"
fi
[[ $(note_get node-b.json) == '无节点快捷备注' ]] || fail "rejected whitespace-only CLI note modified existing note"

# 6. Stale is_change_id does not leak into subsequent main calls in the same shell.
main note node-a.json '不串台' >/dev/null || fail "same-shell main note failed"
if (main unknown_subcommand) >/dev/null 2>&1; then
    fail "unknown subcommand succeeded due to leaked is_change_id"
fi

# 7. Real sing-box.sh -> src/init.sh entry preserves quoted spaces and glob characters.
entry_root="$case_dir/entry"
mkdir -p "$entry_root/etc/sing-box/sh/src" "$entry_root/etc/sing-box/bin" "$entry_root/etc/sing-box/conf" "$entry_root/var/log/sing-box" "$entry_root/usr/local/bin" "$entry_root/bin"
cp -R "$REPO_DIR/src/." "$entry_root/etc/sing-box/sh/src/"
sed -i \
    -e '/EUID != 0/d' \
    -e "s|^is_core_dir=/etc/|is_core_dir=$entry_root/etc/|" \
    -e "s|^is_log_dir=/var/log/|is_log_dir=$entry_root/var/log/|" \
    -e "s|^is_sh_bin=/usr/local/bin/|is_sh_bin=$entry_root/usr/local/bin/|" \
    "$entry_root/etc/sing-box/sh/src/core.sh"
sed -i \
    -e "s|^is_core_dir=/etc/|is_core_dir=$entry_root/etc/|" \
    -e "s|^is_log_dir=/var/log/|is_log_dir=$entry_root/var/log/|" \
    -e "s|^is_sh_bin=/usr/local/bin/|is_sh_bin=$entry_root/usr/local/bin/|" \
    "$entry_root/etc/sing-box/sh/src/init.sh"
cp "$REPO_DIR/sing-box.sh" "$entry_root/etc/sing-box/sh/sing-box.sh"
sed -i "s|^\. /etc/sing-box/sh/src/init.sh$|. $entry_root/etc/sing-box/sh/src/init.sh|" "$entry_root/etc/sing-box/sh/sing-box.sh"
cat >"$entry_root/etc/sing-box/bin/sing-box" <<'CORE'
#!/usr/bin/env bash
[[ $1 == version ]] && printf 'sing-box version 1.14.0\n'
exit 0
CORE
cat >"$entry_root/bin/systemctl" <<'SYS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ENTRY_SYS_LOG:?}"
[[ $1 == is-active ]] && printf 'active\n'
exit 0
SYS
chmod +x "$entry_root/etc/sing-box/sh/sing-box.sh" "$entry_root/etc/sing-box/bin/sing-box" "$entry_root/bin/systemctl"
printf 'cer\n' >"$entry_root/etc/sing-box/bin/tls.cer"
printf 'key\n' >"$entry_root/etc/sing-box/bin/tls.key"
printf '200\n' >"$entry_root/etc/sing-box/log-limit-mb"
printf '{"inbounds":[{"tag":"entry-node.json","type":"shadowsocks","listen":"::","listen_port":23003,"method":"aes-128-gcm","password":"p"}]}\n' >"$entry_root/etc/sing-box/conf/entry-node.json"
: >"$entry_root/sys.log"

if ! entry_out=$(
    cd "$entry_root/etc/sing-box/conf"
    ENTRY_SYS_LOG="$entry_root/sys.log" PATH="$entry_root/bin:$PATH" bash "$entry_root/etc/sing-box/sh/sing-box.sh" note entry-node.json 'entry  *  space' 2>&1
); then
    fail "sing-box.sh note entry failed: $entry_out"
fi
[[ $(jq -r '.note // empty' "$entry_root/etc/sing-box/conf/.quan-meta/entry-node.json.meta.json") == 'entry  *  space' ]] || fail "sing-box.sh mangled spaces or globs in note: $(cat "$entry_root/etc/sing-box/conf/.quan-meta/entry-node.json.meta.json")"
! grep -Eq '^(restart|reload|start|stop)' "$entry_root/sys.log" || fail "sing-box.sh note triggered service restart"

[[ $(cat "$is_conf_dir/node-a.json") == "$before_a" && $(cat "$is_conf_dir/node-b.json") == "$before_b" ]] || fail "CLI note commands mutated node json"
[[ $(cat "$is_config_json") == "$before_cfg" ]] || fail "CLI note commands mutated runtime config.json"
[[ ! -s $manage_log ]] || fail "CLI note commands triggered service restart: $(cat "$manage_log")"
CASE
}

run_slice6_help_and_gate() {
    local repo_dir=$1
    local help_out
    help_out=$(
        cd "$repo_dir" || exit 1
        is_script_name=one-singbox
        is_sh_ver=test
        is_core=sb
        is_core_name=sing-box
        is_sh_repo=ouones/one-singbox
        is_core_bin=sb
        msg() { printf '%b\n' "$*"; }
        msg_ul() { printf '%s' "$*"; }
        warn() { printf 'WARN: %s\n' "$*"; }
        source src/help.sh
        show_help ''
    ) || fail "show_help failed"

    grep -Fq 'note [name] [备注内容 | --clear]' <<<"$help_out" || fail "sb help missing short note usage: $help_out"
    grep -Fq 'change [name] note [备注内容 | --clear]' <<<"$help_out" || fail "sb help missing change note usage: $help_out"
    grep -Fq 'one-singbox' <<<"$help_out" || fail "sb help missing one-singbox term"
    ! grep -Eq '管理面板|端口中转|中转' <<<"$help_out" || fail "sb help contains forbidden terminology: $help_out"
    grep -Fq 'tests-node-note.sh' "$repo_dir/.github/workflows/pr-check.yml" || fail "pr-check.yml missing tests-node-note.sh"
}

run_slice7_interactive_create_note() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*" >&2
    exit 1
}

case_dir="$WORKDIR/slice7"
setup_lifecycle_test_bin "$case_dir"
export PATH="$case_dir/bin:$PATH"

source <(sed '/EUID != 0/d' "$CORE_FILE")
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$case_dir/bin/sing-box"
is_core_ver='1.14.0'
is_systemd=1
is_main_start=1
is_dont_auto_exit=
export ip=203.0.113.10 is_dont_get_ip=1
render_qrcode() { printf '%s\n' "$1" >"$case_dir/qr-last-url"; return 0; }
manage() { :; }
sleep() { :; }

printf '{"dns":{},"route":{"default_domain_resolver":"local"},"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_config_json"

# 1. Interactive node creation via node_menu accepts optional note, trims spaces, shows in immediate info + list + view, and isolates share URL/QR.
create_noted_out=$(node_menu 2>&1 <<'INPUT'
1
8
31001
1
pass-noted
MyNotedClient
  东京 IPLC 落地  

0
INPUT
) || fail "interactive node_menu add with note failed: $create_noted_out"
grep -Fq '输入备注 (可选，直接回车跳过):' <<<"$create_noted_out" || fail "interactive add missing optional note prompt: $create_noted_out"
grep -Fq '出口方式' <<<"$create_noted_out" || fail "immediate info after interactive add missing 出口方式: $create_noted_out"
grep -Fq '备注' <<<"$create_noted_out" && grep -Fq '东京 IPLC 落地' <<<"$create_noted_out" || fail "immediate info after interactive add missing trimmed note: $create_noted_out"

noted_cfg="Shadowsocks-31001.json"
noted_meta="$is_conf_dir/.quan-meta/$noted_cfg.meta.json"
[[ -f "$is_conf_dir/$noted_cfg" ]] || fail "noted node json missing"
[[ -f $noted_meta ]] || fail "noted node meta missing"
jq -e '.node_name == "MyNotedClient" and .note == "东京 IPLC 落地" and .outbound_mode == "V4优先"' "$noted_meta" >/dev/null || fail "noted node meta mismatch: $(cat "$noted_meta")"
[[ $(cat "$case_dir/qr-last-url") != *'东京 IPLC 落地'* ]] || fail "QR url leaked note"

(
    is_dont_show_info=1 info "$noted_cfg"
    [[ $is_url == *'#MyNotedClient' && $is_url != *'东京 IPLC 落地'* ]] || fail "share url polluted by note: $is_url"
) || exit 1

# 2. Interactive node creation with Enter skip writes no note key and omits 备注 in list & detail.
create_skip_out=$(node_menu 2>&1 <<'INPUT'
1
8
31002
1
pass-skip
MyPlainClient


0
INPUT
) || fail "interactive node_menu add with skipped note failed: $create_skip_out"
grep -Fq '输入备注 (可选，直接回车跳过):' <<<"$create_skip_out" || fail "interactive add skip missing optional note prompt: $create_skip_out"
! grep -Fq '备注 =' <<<"$create_skip_out" || fail "skipped note must not appear in detail output: $create_skip_out"

skip_cfg="Shadowsocks-31002.json"
skip_meta="$is_conf_dir/.quan-meta/$skip_cfg.meta.json"
jq -e '.node_name == "MyPlainClient" and .outbound_mode == "V4优先" and (has("note") | not)' "$skip_meta" >/dev/null || fail "skipped note must not write note key: $(cat "$skip_meta")"

# Subsequent node_menu view shows note summary for noted node and plain entry for skipped node.
view_created_out=$(node_menu 2>&1 <<'INPUT'
3
1

0
INPUT
) || fail "node_menu view after interactive add failed: $view_created_out"
grep -Fq "1) $noted_cfg  [备注: 东京 IPLC 落地]" <<<"$view_created_out" || fail "node selection list missing created note summary: $view_created_out"
grep -Fxq "2) $skip_cfg" <<<"$view_created_out" || fail "plain node list entry altered: $view_created_out"
! grep -Fq "$skip_cfg  [备注:" <<<"$view_created_out" || fail "plain node list entry must not show note placeholder: $view_created_out"
grep -Fq '备注' <<<"$view_created_out" && grep -Fq '东京 IPLC 落地' <<<"$view_created_out" || fail "node_menu view missing created note: $view_created_out"

list_after_skip=$(node_menu 2>&1 <<'INPUT'
3
2

0
INPUT
) || fail "node_menu view plain node failed: $list_after_skip"
! grep -Fq '备注 =' <<<"$list_after_skip" || fail "plain node view must not show 备注 value: $list_after_skip"

# 3. Interactive node creation with whitespace-only note writes no note key.
create_ws_out=$(node_menu 2>&1 <<'INPUT'
1
8
31003
1
pass-ws
MyWsClient
   

0
INPUT
) || fail "interactive node_menu add with whitespace note failed: $create_ws_out"
ws_cfg="Shadowsocks-31003.json"
ws_meta="$is_conf_dir/.quan-meta/$ws_cfg.meta.json"
jq -e '.node_name == "MyWsClient" and .outbound_mode == "V4优先" and (has("note") | not)' "$ws_meta" >/dev/null || fail "whitespace-only note must not write note key: $(cat "$ws_meta")"
CASE
}

run_slice8_cli_add_and_antihang() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*" >&2
    exit 1
}

case_dir="$WORKDIR/slice8"
setup_lifecycle_test_bin "$case_dir"
export PATH="$case_dir/bin:$PATH"

source <(sed '/EUID != 0/d' "$CORE_FILE")
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$case_dir/bin/sing-box"
is_core_ver='1.14.0'
is_main_start=
is_dont_auto_exit=
export ip=203.0.113.10 is_dont_get_ip=1
render_qrcode() { :; }
manage() { :; }

printf '{"dns":{},"route":{"default_domain_resolver":"local"},"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_config_json"

# 1. Non-interactive CLI add with silent open pipe neither prompts for note nor blocks stdin.
cli_out=$(timeout 2 bash -c '
    source <(sed "/EUID != 0/d" "$1")
    is_core_dir="$2/core"
    is_conf_dir="$2/conf"
    is_config_json="$2/config.json"
    is_core_bin="$2/bin/sing-box"
    is_core_ver="1.14.0"
    is_main_start=
    ip=203.0.113.10
    is_dont_get_ip=1
    render_qrcode() { :; }
    manage() { :; }
    main add ss 31101 pass-cli aes-128-gcm
' _ "$CORE_FILE" "$case_dir" < <(sleep 6) 2>&1) || fail "non-interactive CLI add hung or failed: $cli_out"
! grep -Fq '输入备注' <<<"$cli_out" || fail "non-interactive CLI add emitted note prompt: $cli_out"
! grep -Fq '输入节点名称' <<<"$cli_out" || fail "non-interactive CLI add emitted node name prompt: $cli_out"
jq -e '.outbound_mode == "V4优先" and (has("note") | not) and (has("node_name") | not)' "$is_conf_dir/.quan-meta/Shadowsocks-31101.json.meta.json" >/dev/null || fail "non-interactive CLI add wrote unexpected note or node_name"

# 2. Stale is_custom_node_note / is_custom_node_name must not leak into subsequent non-interactive add.
is_custom_node_note='残留备注'
is_custom_node_name='残留名称'
main add ss 31102 pass-cli2 aes-128-gcm >"$case_dir/cli2.out" 2>&1 || fail "second CLI add failed"
jq -e '.outbound_mode == "V4优先" and (has("note") | not) and (has("node_name") | not)' "$is_conf_dir/.quan-meta/Shadowsocks-31102.json.meta.json" >/dev/null || fail "stale globals leaked into CLI add"

# 3. gen mode (even if is_main_start=1) must not prompt for note or create config/meta.
gen_out=$(is_main_start=1 main gen ss 31103 pass-gen aes-128-gcm </dev/null 2>&1) || fail "main gen failed: $gen_out"
! grep -Fq '输入备注' <<<"$gen_out" || fail "main gen emitted note prompt: $gen_out"
[[ ! -e "$is_conf_dir/Shadowsocks-31103.json" && ! -e "$is_conf_dir/.quan-meta/Shadowsocks-31103.json.meta.json" ]] || fail "main gen wrote files"

# 4. Interactive add with non-TTY EOF or silent open pipe at note prompt does not hang and skips note safely.
eof_out=$(is_main_start=1 add ss 31104 pass-eof aes-128-gcm <<<$'MyEofNode' 2>&1) || fail "interactive add EOF at note failed: $eof_out"
jq -e '.node_name == "MyEofNode" and .outbound_mode == "V4优先" and (has("note") | not)' "$is_conf_dir/.quan-meta/Shadowsocks-31104.json.meta.json" >/dev/null || fail "interactive add EOF wrote unexpected note"

pipe_out=$(timeout 5 bash -c '
    source <(sed "/EUID != 0/d" "$1")
    is_core_dir="$2/core"
    is_conf_dir="$2/conf"
    is_config_json="$2/config.json"
    is_core_bin="$2/bin/sing-box"
    is_core_ver="1.14.0"
    is_main_start=1
    ip=203.0.113.10
    is_dont_get_ip=1
    render_qrcode() { :; }
    manage() { :; }
    add ss 31105 pass-pipe aes-128-gcm
' _ "$CORE_FILE" "$case_dir" < <(printf 'MyPipeNode\n'; sleep 6) 2>&1) || fail "interactive add hung on silent pipe at note prompt: $pipe_out"
jq -e '.node_name == "MyPipeNode" and .outbound_mode == "V4优先" and (has("note") | not)' "$is_conf_dir/.quan-meta/Shadowsocks-31105.json.meta.json" >/dev/null || fail "interactive add silent pipe timeout wrote unexpected note"
CASE
}

run_slice9_config_rename_migration() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*" >&2
    exit 1
}

case_dir="$WORKDIR/slice9"
setup_lifecycle_test_bin "$case_dir"
export PATH="$case_dir/bin:$PATH"

source <(sed '/EUID != 0/d' "$CORE_FILE")
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$case_dir/bin/sing-box"
is_core_ver='1.14.0'
is_systemd=1
is_main_start=1
is_dont_auto_exit=
export ip=203.0.113.10 is_dont_get_ip=1
render_qrcode() { :; }
manage() { :; }
sleep() { :; }

printf '{"dns":{},"route":{"default_domain_resolver":"local"},"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_config_json"

# Create node interactively with note + node_name, plus a sibling node so selection list always displays.
node_menu >/dev/null 2>&1 <<'INPUT' || fail "initial noted node creation failed"
1
8
31201
1
pass-mig
OriginAlias
  迁移测试专用备注  

1
8
31299
1
pass-sibling
SiblingNode


0
INPUT

orig_cfg="Shadowsocks-31201.json"
jq -e '.node_name == "OriginAlias" and .note == "迁移测试专用备注"' "$is_conf_dir/.quan-meta/$orig_cfg.meta.json" >/dev/null || fail "initial meta missing"

# Set custom outbound mode too so we verify full metadata preservation.
(is_main_start= apply_node_outbound_mode "$orig_cfg" "V6优先") >/dev/null || fail "initial outbound setup failed"

# 1. Port change renames config file and migrates note + node_name + outbound_mode.
port_change_out=$(is_main_start= main change "$orig_cfg" port 31202 2>&1) || fail "port change failed: $port_change_out"
port_cfg="Shadowsocks-31202.json"
[[ ! -e "$is_conf_dir/$orig_cfg" && ! -e "$is_conf_dir/.quan-meta/$orig_cfg.meta.json" ]] || fail "old config or meta lingered after port change"
[[ -f "$is_conf_dir/$port_cfg" && -f "$is_conf_dir/.quan-meta/$port_cfg.meta.json" ]] || fail "new config or meta missing after port change"
jq -e '.node_name == "OriginAlias" and .note == "迁移测试专用备注" and .outbound_mode == "V6优先"' "$is_conf_dir/.quan-meta/$port_cfg.meta.json" >/dev/null || fail "meta fields lost during port change: $(cat "$is_conf_dir/.quan-meta/$port_cfg.meta.json")"
grep -Fq '备注' <<<"$port_change_out" && grep -Fq '迁移测试专用备注' <<<"$port_change_out" || fail "info after port change missing note: $port_change_out"

list_after_port=$(is_config_file= get file <<<$'1\n' 2>&1) || fail "get file after port change failed"
grep -Fq "$port_cfg  [备注: 迁移测试专用备注]" <<<"$list_after_port" || fail "list after port change missing note summary: $list_after_port"

# 2. Protocol change (Shadowsocks -> VLESS-REALITY) renames config file and migrates note + metadata.
proto_change_out=$(is_main_start= main change "$port_cfg" new reality 31203 11111111-1111-4111-8111-111111111111 edge.example.com 2>&1) || fail "protocol change to reality failed: $proto_change_out"
reality_cfg="VLESS-REALITY-31203.json"
[[ ! -e "$is_conf_dir/$port_cfg" && ! -e "$is_conf_dir/.quan-meta/$port_cfg.meta.json" ]] || fail "old config or meta lingered after protocol change"
[[ -f "$is_conf_dir/$reality_cfg" && -f "$is_conf_dir/.quan-meta/$reality_cfg.meta.json" ]] || fail "new reality config or meta missing after protocol change"
jq -e '.node_name == "OriginAlias" and .note == "迁移测试专用备注" and .outbound_mode == "V6优先"' "$is_conf_dir/.quan-meta/$reality_cfg.meta.json" >/dev/null || fail "meta fields lost during protocol change: $(cat "$is_conf_dir/.quan-meta/$reality_cfg.meta.json")"
grep -Fq '备注' <<<"$proto_change_out" && grep -Fq '迁移测试专用备注' <<<"$proto_change_out" || fail "info after protocol change missing note: $proto_change_out"
(
    is_dont_show_info=1 info "$reality_cfg"
    [[ $is_url == *'#OriginAlias' && $is_url != *'迁移测试专用备注'* ]] || fail "share url after protocol change polluted or lost node_name: $is_url"
) || exit 1

# 3. Protocol change keeping same port (VLESS-REALITY -> Snell on 31203) migrates note + metadata.
snell_change_out=$(is_main_start= main change "$reality_cfg" new snell 31203 testpsk0123456 6 2>&1) || fail "protocol change to snell failed: $snell_change_out"
snell_cfg="snell-31203.json"
[[ ! -e "$is_conf_dir/$reality_cfg" && ! -e "$is_conf_dir/.quan-meta/$reality_cfg.meta.json" ]] || fail "reality config or meta lingered after snell migration"
[[ -f "$is_conf_dir/$snell_cfg" && -f "$is_conf_dir/.quan-meta/$snell_cfg.meta.json" ]] || fail "snell config or meta missing after migration"
jq -e '.node_name == "OriginAlias" and .note == "迁移测试专用备注" and .outbound_mode == "V6优先"' "$is_conf_dir/.quan-meta/$snell_cfg.meta.json" >/dev/null || fail "meta fields lost during snell migration: $(cat "$is_conf_dir/.quan-meta/$snell_cfg.meta.json")"
grep -Fq '备注' <<<"$snell_change_out" && grep -Fq '迁移测试专用备注' <<<"$snell_change_out" || fail "info after snell migration missing note: $snell_change_out"

list_after_snell=$(is_config_file= get file <<<$'1\n' 2>&1) || fail "get file after snell migration failed"
grep -Fq "$snell_cfg  [备注: 迁移测试专用备注]" <<<"$list_after_snell" || fail "list after snell migration missing note summary: $list_after_snell"

# 4. Interactive node_menu port change preserves note without re-prompting for note.
menu_port_out=$(node_menu 2>&1 <<'INPUT'
2
2
2
31204

0
INPUT
) || fail "interactive node_menu port change failed: $menu_port_out"
snell_port_cfg="snell-31204.json"
[[ ! -e "$is_conf_dir/$snell_cfg" && ! -e "$is_conf_dir/.quan-meta/$snell_cfg.meta.json" ]] || fail "old snell config lingered after interactive port change"
[[ -f "$is_conf_dir/$snell_port_cfg" && -f "$is_conf_dir/.quan-meta/$snell_port_cfg.meta.json" ]] || fail "new snell config missing after interactive port change"
jq -e '.node_name == "OriginAlias" and .note == "迁移测试专用备注" and .outbound_mode == "V6优先"' "$is_conf_dir/.quan-meta/$snell_port_cfg.meta.json" >/dev/null || fail "meta lost during interactive port change"
! grep -Fq '输入备注' <<<"$menu_port_out" || fail "interactive port change must not re-prompt for note: $menu_port_out"

# 5. Rejected port change preserves original config and note without leaving candidate meta.
if (TEST_REJECT_CHECK=1 is_main_start= main change "$snell_port_cfg" port 31205) >/dev/null 2>&1; then
    fail "rejected port change unexpectedly succeeded"
fi
[[ -f "$is_conf_dir/$snell_port_cfg" && -f "$is_conf_dir/.quan-meta/$snell_port_cfg.meta.json" ]] || fail "rejected port change removed original files"
[[ ! -e "$is_conf_dir/snell-31205.json" && ! -e "$is_conf_dir/.quan-meta/snell-31205.json.meta.json" ]] || fail "rejected port change left candidate files"
[[ $(note_get "$snell_port_cfg") == '迁移测试专用备注' ]] || fail "rejected port change altered note"
CASE
}

run_slice10_outbound_preserves_note() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*" >&2
    exit 1
}

case_dir="$WORKDIR/slice10"
setup_lifecycle_test_bin "$case_dir"
export PATH="$case_dir/bin:$PATH"

source <(sed '/EUID != 0/d' "$CORE_FILE")
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$case_dir/bin/sing-box"
is_core_ver='1.14.0'
is_systemd=1
is_main_start=
is_dont_auto_exit=
export ip=203.0.113.10 is_dont_get_ip=1
render_qrcode() { :; }
manage() { :; }
sleep() { :; }

printf '{"dns":{},"route":{"default_domain_resolver":"local"},"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_config_json"

main add ss 31301 pass-out1 aes-128-gcm >/dev/null 2>&1 || fail "create noted outbound test node failed"
main add ss 31302 pass-out2 aes-128-gcm >/dev/null 2>&1 || fail "create plain outbound test node failed"
noted_cfg="Shadowsocks-31301.json"
plain_cfg="Shadowsocks-31302.json"
meta_set "$noted_cfg" node_name "AliasA"
note_set "$noted_cfg" "新加坡 人工备注"

ss_uri="ss://$(printf 'aes-128-gcm:upstream-secret' | base64 -w 0)@198.51.100.20:8388#%E4%B8%8A%E6%B8%B8SS%E6%A0%87%E7%AD%BE"
vless_uri="vless://11111111-1111-4111-8111-111111111111@upstream.example.com:443?security=tls&sni=upstream.example.com&type=tcp#%E4%B8%8A%E6%B8%B8VLESS%E6%A0%87%E7%AD%BE"

# 1. Noted node preserves exact note across direct strategies, SS outbound, VLESS outbound, and switch back.
for choice in 1 3 4; do
    (change "$noted_cfg" outbound <<<"$choice"$'\n') >/dev/null 2>&1 || fail "direct outbound choice $choice failed"
    [[ $(note_get "$noted_cfg") == '新加坡 人工备注' ]] || fail "direct choice $choice altered note: $(note_get "$noted_cfg")"
done

(change "$noted_cfg" outbound <<<$'5\n'"$ss_uri"$'\n') >/dev/null 2>&1 || fail "SS outbound switch failed"
[[ $(note_get "$noted_cfg") == '新加坡 人工备注' ]] || fail "SS outbound switch altered note: $(note_get "$noted_cfg")"
ss_info=$(info "$noted_cfg" 2>&1) || fail "info after SS outbound failed"
grep -Fq 'Shadowsocks 出口 (上游SS标签)' <<<"$ss_info" || fail "info missing SS outbound label: $ss_info"
grep -Fq '备注' <<<"$ss_info" && grep -Fq '新加坡 人工备注' <<<"$ss_info" || fail "info lost original note after SS outbound: $ss_info"

(change "$noted_cfg" outbound <<<$'6\n'"$vless_uri"$'\n') >/dev/null 2>&1 || fail "VLESS outbound switch failed"
[[ $(note_get "$noted_cfg") == '新加坡 人工备注' ]] || fail "VLESS outbound switch altered note: $(note_get "$noted_cfg")"
vless_info=$(info "$noted_cfg" 2>&1) || fail "info after VLESS outbound failed"
grep -Fq 'VLESS 出口 (上游VLESS标签)' <<<"$vless_info" || fail "info missing VLESS outbound label: $vless_info"
grep -Fq '备注' <<<"$vless_info" && grep -Fq '新加坡 人工备注' <<<"$vless_info" || fail "info lost original note after VLESS outbound: $vless_info"

(change "$noted_cfg" outbound <<<$'2\n') >/dev/null 2>&1 || fail "switch back to V4优先 failed"
jq -e '.node_name == "AliasA" and .note == "新加坡 人工备注" and .outbound_mode == "V4优先"' "$is_conf_dir/.quan-meta/$noted_cfg.meta.json" >/dev/null || fail "meta mismatch after outbound roundtrip"

# 2. Plain node without note must never auto-generate or copy proxy URI label into note.
(change "$plain_cfg" outbound <<<$'5\n'"$ss_uri"$'\n') >/dev/null 2>&1 || fail "plain SS outbound switch failed"
jq -e 'has("note") | not' "$is_conf_dir/.quan-meta/$plain_cfg.meta.json" >/dev/null || fail "SS outbound auto-generated note on plain node"
(change "$plain_cfg" outbound <<<$'6\n'"$vless_uri"$'\n') >/dev/null 2>&1 || fail "plain VLESS outbound switch failed"
jq -e 'has("note") | not' "$is_conf_dir/.quan-meta/$plain_cfg.meta.json" >/dev/null || fail "VLESS outbound auto-generated note on plain node"
(change "$plain_cfg" outbound <<<$'1\n') >/dev/null 2>&1 || fail "plain direct outbound switch failed"
jq -e 'has("note") | not' "$is_conf_dir/.quan-meta/$plain_cfg.meta.json" >/dev/null || fail "direct outbound auto-generated note on plain node"
[[ -z $(note_get "$plain_cfg") ]] || fail "plain node note_get non-empty after outbound switches"
plain_info=$(info "$plain_cfg" 2>&1) || fail "plain node info failed"
! grep -Fq '备注' <<<"$plain_info" || fail "plain node info showed note after outbound switches: $plain_info"
CASE
}

run_slice11_delete_cleanup() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*" >&2
    exit 1
}

case_dir="$WORKDIR/slice11"
setup_lifecycle_test_bin "$case_dir"
export PATH="$case_dir/bin:$PATH"

source <(sed '/EUID != 0/d' "$CORE_FILE")
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$case_dir/bin/sing-box"
is_core_ver='1.14.0'
is_systemd=1
is_main_start=1
is_dont_auto_exit=
export ip=203.0.113.10 is_dont_get_ip=1
render_qrcode() { :; }
manage() { :; }
sleep() { :; }

printf '{"dns":{},"route":{"default_domain_resolver":"local"},"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_config_json"

node_menu >/dev/null 2>&1 <<'INPUT' || fail "create delete target node failed"
1
8
31401
1
pass-del
DeleteTarget
  删除清理备注  

0
INPUT

target_cfg="Shadowsocks-31401.json"
target_meta="$is_conf_dir/.quan-meta/$target_cfg.meta.json"
[[ -f "$is_conf_dir/$target_cfg" && -f $target_meta ]] || fail "target node or meta missing"

# 1. Canceled interactive delete preserves both node json and metadata.
node_menu >/dev/null 2>&1 <<'INPUT' || fail "canceled delete flow failed"
4
1
n

0
INPUT
[[ -f "$is_conf_dir/$target_cfg" && -f $target_meta ]] || fail "canceled delete removed node or meta"
[[ $(note_get "$target_cfg") == '删除清理备注' ]] || fail "canceled delete altered note"

# 2. Failed CLI delete restores both node json and metadata.
if (TEST_REJECT_CHECK=1 is_main_start= main del "$target_cfg") >/dev/null 2>&1; then
    fail "rejected delete unexpectedly succeeded"
fi
[[ -f "$is_conf_dir/$target_cfg" && -f $target_meta ]] || fail "rejected delete lost node or meta"
[[ $(note_get "$target_cfg") == '删除清理备注' ]] || fail "rejected delete altered note"

# 3. Confirmed interactive delete removes both node json and .meta.json without residue.
del_confirm_out=$(node_menu 2>&1 <<'INPUT'
4
1
y

0
INPUT
) || fail "confirmed interactive delete failed: $del_confirm_out"
[[ ! -e "$is_conf_dir/$target_cfg" ]] || fail "deleted node config still exists"
[[ ! -e $target_meta ]] || fail "deleted node meta still exists: $target_meta"

# 4. Recreating the same protocol/port node without note does not inherit stale note or node_name.
node_menu >/dev/null 2>&1 <<'INPUT' || fail "recreate same port node failed"
1
8
31401
1
pass-new
FreshAlias


0
INPUT
[[ -f "$is_conf_dir/$target_cfg" && -f $target_meta ]] || fail "recreated node or meta missing"
jq -e '.node_name == "FreshAlias" and .outbound_mode == "V4优先" and (has("note") | not)' "$target_meta" >/dev/null || fail "recreated node inherited stale metadata: $(cat "$target_meta")"

# 5. CLI main del removes both node json and .meta.json created/updated via main note.
(is_main_start= main note "$target_cfg" "CLI删前备注") >/dev/null || fail "main note before CLI delete failed"
[[ $(note_get "$target_cfg") == 'CLI删前备注' ]] || fail "main note did not persist before CLI delete"
(is_main_start= main del "$target_cfg") >/dev/null || fail "CLI main del failed"
[[ ! -e "$is_conf_dir/$target_cfg" && ! -e $target_meta ]] || fail "CLI main del left node json or meta file behind"
CASE
}

run_slice1_helpers "$repo_root/src/core.sh"
run_slice2_info_display "$repo_root/src/core.sh"
run_slice3_node_selection_list "$repo_root/src/core.sh"
run_slice4_interactive_edit "$repo_root/src/core.sh"
run_slice5_cli_commands "$repo_root"
run_slice6_help_and_gate "$repo_root"
run_slice7_interactive_create_note "$repo_root/src/core.sh"
run_slice8_cli_add_and_antihang "$repo_root/src/core.sh"
run_slice9_config_rename_migration "$repo_root/src/core.sh"
run_slice10_outbound_preserves_note "$repo_root/src/core.sh"
run_slice11_delete_cleanup "$repo_root/src/core.sh"
echo "PASS: node note tests"
