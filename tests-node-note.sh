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

run_slice1_helpers "$repo_root/src/core.sh"
run_slice2_info_display "$repo_root/src/core.sh"
run_slice3_node_selection_list "$repo_root/src/core.sh"
run_slice4_interactive_edit "$repo_root/src/core.sh"
run_slice5_cli_commands "$repo_root"
run_slice6_help_and_gate "$repo_root"
echo "PASS: node note tests"
