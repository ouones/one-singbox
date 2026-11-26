#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_relay_selection_case() {
    local case_dir="$workdir/relay-selection"
    mkdir -p "$case_dir/core" "$case_dir/conf"
    CASE_DIR="$case_dir" REPO_ROOT="$repo_root" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(relay-selection): $*" >&2
    exit 1
}

source "$REPO_ROOT/src/core.sh"
is_core_dir="$CASE_DIR/core"
is_conf_dir="$CASE_DIR/conf"
is_config_json="$CASE_DIR/core/config.json"
is_core_bin=/bin/true
is_core_ver=1.14.0
is_main_start=1
export ip=203.0.113.10 is_dont_get_ip=1
printf '{"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_config_json"
manage() { :; }
systemctl() { return 0; }
is_port_used() { :; }

cat >"$is_conf_dir/relay-10000.json" <<'JSON'
{"inbounds":[{"tag":"relay-10000.json","type":"direct","listen":"::","listen_port":10000,"override_address":"203.0.113.10","override_port":20000}]}
JSON
cat >"$is_conf_dir/relay-10001.json" <<'JSON'
{"inbounds":[{"tag":"relay-10001.json","type":"direct","listen":"::","listen_port":10001,"override_address":"203.0.113.11","override_port":20001}]}
JSON
main relay note 10001 '落地备注' >/dev/null 2>&1 || fail 'setup relay note failed'

assert_numbered_list() {
    local output=$1 prompt=$2
    grep -Fq "$prompt" <<<"$output" || fail "missing selection prompt '$prompt': $output"
    grep -Fq '1) 监听端口 10000 -> 目标 203.0.113.10:20000 (TCP/UDP)' <<<"$output" || fail "missing first numbered relay entry: $output"
    grep -Fq '2) 监听端口 10001 -> 目标 203.0.113.11:20001 (TCP/UDP)  [备注: 落地备注]' <<<"$output" || fail "missing second numbered relay entry with note: $output"
    grep -Fq '0) 返回上级' <<<"$output" || fail "missing shared return item: $output"
}

# 1. 备注 page: numbered list, 0 returns straight to the relay menu without any pause.
note_return_out=$(printf '3\n0\n0\n' | relay_menu 2>&1) || fail "note page return failed: $note_return_out"
assert_numbered_list "$note_return_out" '请选择要编辑备注的端口转发:'
[[ $note_return_out != *'按回车返回菜单'* ]] || fail "returning from the note list must not pause: $note_return_out"
[[ $(grep -Fc '请选择端口转发操作' <<<"$note_return_out") == 2 ]] || fail "note list 0 returns straight to the relay menu: $note_return_out"
[[ $note_return_out != *'请输入新备注'* ]] || fail "returning from the note list must not open the note editor: $note_return_out"

# 2. 删除 page: numbered list, 0 returns straight to the relay menu without any pause.
delete_return_out=$(printf '4\n0\n0\n' | relay_menu 2>&1) || fail "delete page return failed: $delete_return_out"
assert_numbered_list "$delete_return_out" '请选择要删除的端口转发:'
[[ $delete_return_out != *'按回车返回菜单'* ]] || fail "returning from the delete list must not pause: $delete_return_out"
[[ $(grep -Fc '请选择端口转发操作' <<<"$delete_return_out") == 2 ]] || fail "delete list 0 returns straight to the relay menu: $delete_return_out"
[[ $delete_return_out != *'[y/N]'* ]] || fail "returning from the delete list must not ask for confirmation: $delete_return_out"
[[ -f "$is_conf_dir/relay-10000.json" && -f "$is_conf_dir/relay-10001.json" ]] || fail "returning from the delete list removed relays"

# 3. Invalid numbers re-prompt instead of leaving the selection page, then a valid number edits the note.
note_edit_out=$(printf '3\n99\n1\n新备注\n\n0\n' | relay_menu 2>&1) || fail "note selection edit failed: $note_edit_out"
[[ $(grep -Fc '输入无效' <<<"$note_edit_out") == 1 ]] || fail "invalid number explains the valid range once: $note_edit_out"
[[ $(grep -Fc '请选择要编辑备注的端口转发:' <<<"$note_edit_out") == 2 ]] || fail "invalid number re-prompts the note list: $note_edit_out"
grep -Fq '当前备注: (无)' <<<"$note_edit_out" || fail "valid number opens the note editor: $note_edit_out"
[[ $(note_get relay-10000.json) == '新备注' ]] || fail "valid number saved the note to relay-10000.json: '$(note_get relay-10000.json)'"
[[ $(grep -Fc '按回车返回菜单' <<<"$note_edit_out") == 1 ]] || fail "note result stays visible with one pause: $note_edit_out"

# 4. Invalid numbers re-prompt on the delete page, then a valid number reaches its confirmation.
delete_cancel_out=$(printf '4\nabc\n2\nn\n\n0\n' | relay_menu 2>&1) || fail "delete selection cancel failed: $delete_cancel_out"
[[ $(grep -Fc '输入无效' <<<"$delete_cancel_out") == 1 ]] || fail "invalid delete number explains the valid range once: $delete_cancel_out"
[[ $(grep -Fc '请选择要删除的端口转发:' <<<"$delete_cancel_out") == 2 ]] || fail "invalid delete number re-prompts the delete list: $delete_cancel_out"
grep -Fq '将删除监听端口 10001 → 203.0.113.11:20001 的端口转发' <<<"$delete_cancel_out" || fail "valid delete number targets the selected relay: $delete_cancel_out"
grep -Fq '已取消删除端口转发' <<<"$delete_cancel_out" || fail "declining the confirmation cancels the delete: $delete_cancel_out"
[[ -f "$is_conf_dir/relay-10001.json" ]] || fail "declining the confirmation removed relay-10001.json"

# 5. 查看 page: numbered list, 0 returns straight to the relay menu without any pause.
view_return_out=$(printf '2\n0\n0\n' | relay_menu 2>&1) || fail "view page return failed: $view_return_out"
assert_numbered_list "$view_return_out" '请选择要查看的端口转发:'
[[ $view_return_out != *'按回车返回菜单'* ]] || fail "returning from the view list must not pause: $view_return_out"
[[ $(grep -Fc '请选择端口转发操作' <<<"$view_return_out") == 2 ]] || fail "view list 0 returns straight to the relay menu: $view_return_out"
[[ $view_return_out != *'端口转发配置信息'* ]] || fail "returning from the view list must not show details: $view_return_out"

# 6. 查看 page: a valid number shows the selected relay details and then pauses once.
view_detail_out=$(printf '2\n1\n\n0\n' | relay_menu 2>&1) || fail "view detail selection failed: $view_detail_out"
grep -Fq '端口转发配置信息' <<<"$view_detail_out" || fail "valid view number shows the relay details: $view_detail_out"
grep -Fq '监听端口: 10000' <<<"$view_detail_out" || fail "view detail identifies the selected listener port: $view_detail_out"
[[ $(grep -Fc '按回车返回菜单' <<<"$view_detail_out") == 1 ]] || fail "view detail result stays visible with one pause: $view_detail_out"
CASE
}

run_relay_selection_case
echo "PASS: relay numbered selection menus"
