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

fake_core="$workdir/fake-sing-box"
cat >"$fake_core" <<'FAKE_CORE'
#!/usr/bin/env bash
case ${1:-} in
version)
    printf 'sing-box version %s\n' "${FAKE_CORE_VERSION:-1.14.0}"
    ;;
check)
    config=
    conf_dir=
    while [[ $# -gt 0 ]]; do
        case $1 in
        -c)
            config=$2
            shift 2
            ;;
        -C)
            conf_dir=$2
            shift 2
            ;;
        *)
            shift
            ;;
        esac
    done
    if [[ ${TEST_REJECT_COMPLETE:-0} == 1 && -n $conf_dir ]]; then
        exit 1
    fi
    if [[ -n $config ]]; then
        [[ -f $config ]] || exit 1
        if jq -e '.inbounds[0].type == "direct"' "$config" >/dev/null 2>&1; then
            jq -e '
                (.inbounds | length == 1)
                and (.inbounds[0].type == "direct")
                and (.inbounds[0].listen == "::")
                and (.inbounds[0].listen_port | type == "number")
                and (.inbounds[0].listen_port > 0)
                and (.inbounds[0].listen_port <= 65535)
                and ((.inbounds[0].override_address | type) == "string")
                and ((.inbounds[0].override_address | length) > 0)
                and (.inbounds[0].override_port | type == "number")
                and (.inbounds[0].override_port > 0)
                and (.inbounds[0].override_port <= 65535)
                and ((.inbounds[0] | has("network")) | not)
            ' "$config" >/dev/null || exit 1
        fi
    fi
    if [[ -n $conf_dir ]]; then
        [[ -d $conf_dir ]] || exit 1
        shopt -s nullglob
        for f in "$conf_dir"/*.json; do
            jq -e . "$f" >/dev/null 2>&1 || exit 1
        done
        shopt -u nullglob
    fi
    ;;
esac
FAKE_CORE
chmod +x "$fake_core"

run_slice1_add_and_info() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" FAKE_CORE="$fake_core" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*" >&2
    exit 1
}

source "$CORE_FILE"
case_dir="$WORKDIR/slice1"
mkdir -p "$case_dir/core" "$case_dir/conf"
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$FAKE_CORE"
is_core_ver=1.14.0
is_dont_auto_exit=
is_dont_show_info=
export ip=203.0.113.10 is_dont_get_ip=1
printf '{"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_config_json"

manage_log="$case_dir/manage.log"
: >"$manage_log"
manage() { printf '%s\n' "$*" >>"$manage_log"; }
is_systemd=1
is_core=sing-box
systemctl() {
    case ${1:-} in
    restart) manage restart "${2:-$is_core}" ;;
    is-active) return 0 ;;
    show) printf '12345\n' ;;
    *) return 1 ;;
    esac
}
sleep() { command sleep 0.01; }
is_port_used() { [[ ${TEST_ACTIVE_PORT:-} == "$1" ]] && printf '%s\n' "$1"; }

# 1. CLI 3-arg add must not prompt or block on open stdin pipe, and must omit note when unset.
add_plain_out=$(timeout 2 bash -c '
    source "$1"
    is_core_dir="$2/core"
    is_conf_dir="$2/conf"
    is_config_json="$2/config.json"
    is_core_bin="$3"
    is_core_ver=1.14.0
    export ip=203.0.113.10 is_dont_get_ip=1
    manage() { :; }
    systemctl() { return 0; }
    is_port_used() { :; }
    main relay add 10000 203.0.113.10 20000
' _ "$CORE_FILE" "$case_dir" "$FAKE_CORE" < <(exec >/dev/null 2>&1; command sleep 2) 2>&1) || fail "CLI 3-arg relay add blocked or failed: $add_plain_out"
[[ ! -f "$is_conf_dir/.quan-meta/relay-10000.json.meta.json" ]] || fail "CLI 3-arg relay add without note created metadata"
[[ $add_plain_out != *'输入备注'* ]] || fail "CLI 3-arg relay add prompted for note: $add_plain_out"
[[ $add_plain_out != *'备注:'* ]] || fail "CLI 3-arg relay add output should omit 备注 when empty: $add_plain_out"

info_plain=$(main relay info 10000 2>&1) || fail "relay info 10000 failed"
[[ $info_plain != *'备注:'* ]] || fail "relay info should omit 备注 when empty: $info_plain"

# 2. CLI 4th arg (quoted long note with surrounding spaces) and unquoted multi-word note.
long_note='这是一条超过三十个字符的端口转发完整备注用于验证详情页不会被截断'
add_long_out=$( (main relay add 10001 203.0.113.11 20001 "  ${long_note}  ") 2>&1 ) || fail "CLI 4-arg relay add failed: $add_long_out"
[[ $(note_get relay-10001.json) == "$long_note" ]] || fail "CLI 4-arg note was not trimmed or saved: '$(note_get relay-10001.json)'"
grep -Fq "备注: $long_note" <<<"$add_long_out" || fail "relay add echo omitted full note: $add_long_out"

info_long=$(main relay info 10001 2>&1) || fail "relay info 10001 failed"
grep -Fq "备注: $long_note" <<<"$info_long" || fail "relay info truncated or omitted full note: $info_long"
! grep -Fq '这是一条超过三十个字符的端口转发完整备注用于验证详情页不会被截...' <<<"$info_long" || fail "relay info must not truncate note"

add_multi_out=$( (main relay add 10002 203.0.113.12 20002 日本 东京 落地) 2>&1 ) || fail "CLI unquoted multi-word note failed: $add_multi_out"
[[ $(note_get relay-10002.json) == '日本 东京 落地' ]] || fail "CLI multi-word note mismatch: '$(note_get relay-10002.json)'"
grep -Fq '备注: 日本 东京 落地' <<<"$add_multi_out" || fail "relay add echo missing multi-word note: $add_multi_out"

# 3. Whitespace-only 4th arg is ignored without creating metadata.
(main relay add 10003 203.0.113.13 20003 '   ') >/dev/null 2>&1 || fail "CLI whitespace-only 4th arg failed"
[[ ! -f "$is_conf_dir/.quan-meta/relay-10003.json.meta.json" ]] || fail "whitespace-only 4th arg created metadata"

# 4. Interactive add prompts after target port, trims note, and shows full note in echo.
inter_out=$(printf '10004\n203.0.113.14\n20004\n  香港 IEPL 专线  \n' | (main relay add) 2>&1) || fail "interactive relay add with note failed: $inter_out"
target_pos=$(awk 'index($0, "输入目标端口") { print NR; exit }' <<<"$inter_out")
note_pos=$(awk 'index($0, "输入备注 (可选，直接回车跳过):") { print NR; exit }' <<<"$inter_out")
[[ -n $target_pos && -n $note_pos && $target_pos -le $note_pos ]] || fail "interactive note prompt missing or out of order: $inter_out"
[[ $(note_get relay-10004.json) == '香港 IEPL 专线' ]] || fail "interactive note not saved: '$(note_get relay-10004.json)'"
grep -Fq '备注: 香港 IEPL 专线' <<<"$inter_out" || fail "interactive relay add echo missing note: $inter_out"

# 5. Interactive add with Enter skips note without creating metadata.
skip_out=$(printf '10005\n203.0.113.15\n20005\n\n' | (main relay add) 2>&1) || fail "interactive relay add skip failed: $skip_out"
grep -Fq '输入备注 (可选，直接回车跳过):' <<<"$skip_out" || fail "interactive skip missing note prompt: $skip_out"
[[ ! -f "$is_conf_dir/.quan-meta/relay-10005.json.meta.json" ]] || fail "interactive skip created metadata"
[[ $skip_out != *'备注:'* ]] || fail "interactive skip echo showed 备注: $skip_out"

# 6. Interactive add with silent open pipe after 3 inputs does not hang indefinitely (anti-hang guard).
timeout 3 bash -c '
    source "$1"
    is_core_dir="$2/core"
    is_conf_dir="$2/conf"
    is_config_json="$2/config.json"
    is_core_bin="$3"
    is_core_ver=1.14.0
    export ip=203.0.113.10 is_dont_get_ip=1 ONE_SINGBOX_READ_TIMEOUT=0.2
    manage() { :; }
    systemctl() { return 0; }
    is_port_used() { :; }
    main relay add
' _ "$CORE_FILE" "$case_dir" "$FAKE_CORE" < <(printf '10006\n203.0.113.16\n20006\n'; exec >/dev/null 2>&1; command sleep 1) >"$case_dir/slice1-timeout.out" 2>&1 || fail "interactive relay add hung on silent pipe after target port"
[[ -f "$is_conf_dir/relay-10006.json" ]] || fail "anti-hang relay add did not create relay-10006.json"
[[ ! -f "$is_conf_dir/.quan-meta/relay-10006.json.meta.json" ]] || fail "anti-hang timeout created metadata"
CASE
}

run_slice2_list_summary() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" FAKE_CORE="$fake_core" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*" >&2
    exit 1
}

source "$CORE_FILE"
case_dir="$WORKDIR/slice2"
mkdir -p "$case_dir/core" "$case_dir/conf"
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$FAKE_CORE"
is_core_ver=1.14.0
export ip=203.0.113.10 is_dont_get_ip=1
manage() { :; }
systemctl() { return 0; }
is_port_used() { :; }

main relay add 11000 203.0.113.10 21000 >/dev/null 2>&1 || fail "add 11000 failed"
main relay add 11001 203.0.113.11 21001 '  日本 东京 IPLC  ' >/dev/null 2>&1 || fail "add 11001 failed"
cjk30='一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十'
cjk33="${cjk30}甲乙丙"
main relay add 11002 203.0.113.12 21002 "$cjk33" >/dev/null 2>&1 || fail "add 11002 failed"

list_out=$(main relay list 2>&1) || fail "relay list failed: $list_out"
grep -Fxq '监听端口 11000 -> 目标 203.0.113.10:21000 (TCP/UDP)' <<<"$list_out" || fail "plain relay entry altered or added placeholder: $list_out"
grep -Fxq '监听端口 11001 -> 目标 203.0.113.11:21001 (TCP/UDP)  [备注: 日本 东京 IPLC]' <<<"$list_out" || fail "short noted relay entry mismatch: $list_out"
grep -Fxq "监听端口 11002 -> 目标 203.0.113.12:21002 (TCP/UDP)  [备注: ${cjk30}...]" <<<"$list_out" || fail "long noted relay entry summary mismatch: $list_out"
CASE
}

run_slice3_relay_note_cli_and_interactive() {
    local repo_dir=$1
    REPO_DIR="$repo_dir" WORKDIR="$workdir" FAKE_CORE="$fake_core" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${REPO_DIR}): $*" >&2
    exit 1
}

source "$REPO_DIR/src/core.sh"
case_dir="$WORKDIR/slice3"
mkdir -p "$case_dir/core" "$case_dir/conf"
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$FAKE_CORE"
is_core_ver=1.14.0
is_core=sb
export ip=203.0.113.10 is_dont_get_ip=1
printf '{"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_config_json"

manage_log="$case_dir/manage.log"
manage() { printf '%s\n' "$*" >>"$manage_log"; }
systemctl() { printf '%s\n' "$*" >>"$manage_log"; return 0; }
is_port_used() { [[ ${TEST_ACTIVE_PORT:-} == "$1" ]] && printf '%s\n' "$1"; }

main relay add 12000 203.0.113.10 22000 >/dev/null 2>&1 || fail "setup relay 12000 failed"
main relay add 12001 203.0.113.11 22001 >/dev/null 2>&1 || fail "setup relay 12001 failed"

before_12000=$(cat "$is_conf_dir/relay-12000.json")
before_cfg=$(cat "$is_config_json")
: >"$manage_log"

# 1. CLI relay note with quoted spaces/glob, normalized file name, and unquoted multi-word text.
(main relay note 12000 '  新加坡  直连 * 备忘  ') >/dev/null 2>&1 || fail "relay note quoted failed"
[[ $(note_get relay-12000.json) == '新加坡  直连 * 备忘' ]] || fail "relay note quoted mismatch: '$(note_get relay-12000.json)'"

(main relay note relay-12000.json 日本 东京 BGP) >/dev/null 2>&1 || fail "relay note normalized unquoted failed"
[[ $(note_get relay-12000.json) == '日本 东京 BGP' ]] || fail "relay note unquoted mismatch: '$(note_get relay-12000.json)'"

# 2. Whitespace-only CLI note is rejected without clearing existing note.
if (main relay note 12000 '   ') >/dev/null 2>&1; then
    fail "whitespace-only CLI relay note must fail instead of silently clearing"
fi
[[ $(note_get relay-12000.json) == '日本 东京 BGP' ]] || fail "rejected whitespace-only CLI relay note modified note"

# 3. --clear removes note and deletes empty meta file.
(main relay note 12000 --clear) >/dev/null 2>&1 || fail "relay note --clear failed"
[[ -z $(note_get relay-12000.json) ]] || fail "relay note --clear did not clear"
[[ ! -e "$is_conf_dir/.quan-meta/relay-12000.json.meta.json" ]] || fail "relay note --clear left empty meta file"

# 4. Interactive edit with port given: (无), set, Enter keeps, whitespace keeps, '-' clears, 'clear' clears.
set_out=$(main relay note 12000 <<<$'  交互新备注  \n' 2>&1) || fail "interactive relay note set failed: $set_out"
grep -Fq '当前备注: (无)' <<<"$set_out" || fail "interactive relay note missing (无): $set_out"
grep -Fq '请输入新备注 (直接回车保持不变，输入 - 或 clear 清空):' <<<"$set_out" || fail "interactive relay note missing exact prompt: $set_out"
[[ $(note_get relay-12000.json) == '交互新备注' ]] || fail "interactive relay note set mismatch: '$(note_get relay-12000.json)'"

keep_enter_out=$(main relay note 12000 <<<$'\n' 2>&1) || fail "interactive relay note Enter failed: $keep_enter_out"
grep -Fq '当前备注: 交互新备注' <<<"$keep_enter_out" || fail "interactive relay note missing current value: $keep_enter_out"
[[ $(note_get relay-12000.json) == '交互新备注' ]] || fail "Enter cleared relay note"

(main relay note 12000 <<<$'   \n') >/dev/null 2>&1 || fail "interactive relay note whitespace failed"
[[ $(note_get relay-12000.json) == '交互新备注' ]] || fail "whitespace cleared relay note"

(main relay note 12000 <<<$'-\n') >/dev/null 2>&1 || fail "interactive relay note '-' failed"
[[ -z $(note_get relay-12000.json) ]] || fail "'-' did not clear relay note"
[[ ! -e "$is_conf_dir/.quan-meta/relay-12000.json.meta.json" ]] || fail "'-' left empty meta file"

main relay note 12000 '二次备注' >/dev/null 2>&1 || fail "setup second note failed"
(main relay note 12000 <<<$'clear\n') >/dev/null 2>&1 || fail "interactive relay note 'clear' failed"
[[ -z $(note_get relay-12000.json) ]] || fail "'clear' did not clear relay note"

# 5. Anti-hang guard on /dev/null and silent open pipe.
main relay note 12000 '防挂死保留' >/dev/null 2>&1 || fail "setup anti-hang note failed"
timeout 2 bash -c '
    source "$1"
    is_core_dir="$2/core"
    is_conf_dir="$2/conf"
    main relay note 12000 </dev/null
' _ "$REPO_DIR/src/core.sh" "$case_dir" >"$case_dir/slice3-eof.out" 2>&1 || fail "relay note hung or failed on /dev/null"
[[ $(note_get relay-12000.json) == '防挂死保留' ]] || fail "/dev/null altered relay note"

timeout 3 bash -c '
    source "$1"
    is_core_dir="$2/core"
    is_conf_dir="$2/conf"
    export ONE_SINGBOX_READ_TIMEOUT=0.2
    main relay note 12000
' _ "$REPO_DIR/src/core.sh" "$case_dir" < <(exec >/dev/null 2>&1; command sleep 1) >"$case_dir/slice3-pipe.out" 2>&1 || fail "relay note hung on silent pipe"
[[ $(note_get relay-12000.json) == '防挂死保留' ]] || fail "silent pipe altered relay note"

# 6. Omitting port lists relays and accepts active listening port without leaking is_cant_test_port.
TEST_ACTIVE_PORT=12001
omit_port_out=$(main relay note 2>&1 <<'INPUT'
12001
活跃监听备注
INPUT
) || fail "relay note without port failed: $omit_port_out"
grep -Fq '端口转发列表' <<<"$omit_port_out" || fail "relay note without port did not show list: $omit_port_out"
[[ $(note_get relay-12001.json) == '活跃监听备注' ]] || fail "relay note without port did not save note on active port: '$(note_get relay-12001.json)'"

TEST_ACTIVE_PORT=12009
if (main relay add 12009 203.0.113.19 22009) >/dev/null 2>&1; then
    fail "relay note leaked is_cant_test_port into later relay add"
fi
unset TEST_ACTIVE_PORT

# 7. Non-existent port and unknown subcommand usage string.
if (main relay note 59999 'ghost') >/dev/null 2>&1; then
    fail "relay note on missing relay port should fail"
fi
[[ ! -e "$is_conf_dir/.quan-meta/relay-59999.json.meta.json" ]] || fail "failed relay note created metadata"

unknown_out=$( (main relay unknown) 2>&1 )
[[ $? != 0 ]] || fail "unknown relay subcommand must fail"
grep -Fq 'relay [add|list|info|note|delete]' <<<"$unknown_out" || fail "relay usage missing note subcommand: $unknown_out"

# 8. Zero runtime config modification and zero restart across all note operations.
[[ $(cat "$is_conf_dir/relay-12000.json") == "$before_12000" ]] || fail "relay note mutated relay-12000.json"
[[ $(cat "$is_config_json") == "$before_cfg" ]] || fail "relay note mutated runtime config.json"
[[ ! -s $manage_log ]] || fail "relay note triggered service restart: $(cat "$manage_log")"

# 9. Full entry sing-box.sh -> src/init.sh preserves quoted spaces/globs and triggers zero restart.
entry_root="$case_dir/entry"
mkdir -p "$entry_root/etc/sing-box/sh/src" "$entry_root/etc/sing-box/bin" "$entry_root/etc/sing-box/conf" "$entry_root/var/log/sing-box" "$entry_root/usr/local/bin" "$entry_root/bin"
cp -R "$REPO_DIR/src/." "$entry_root/etc/sing-box/sh/src/"
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
printf '{"inbounds":[{"tag":"relay-12003.json","type":"direct","listen":"::","listen_port":12003,"override_address":"203.0.113.13","override_port":22003}]}\n' >"$entry_root/etc/sing-box/conf/relay-12003.json"
: >"$entry_root/sys.log"

if ! entry_out=$(
    cd "$entry_root/etc/sing-box/conf"
    ENTRY_SYS_LOG="$entry_root/sys.log" PATH="$entry_root/bin:$PATH" bash "$entry_root/etc/sing-box/sh/sing-box.sh" relay note 12003 'entry  *  relay' 2>&1
); then
    fail "sing-box.sh relay note entry failed: $entry_out"
fi
[[ $(jq -r '.note // empty' "$entry_root/etc/sing-box/conf/.quan-meta/relay-12003.json.meta.json") == 'entry  *  relay' ]] || fail "sing-box.sh mangled spaces or globs in relay note"
! grep -Eq '^(restart|reload|start|stop)' "$entry_root/sys.log" || fail "sing-box.sh relay note triggered service restart"
CASE
}

run_slice4_relay_menu() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" FAKE_CORE="$fake_core" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*" >&2
    exit 1
}

source "$CORE_FILE"
case_dir="$WORKDIR/slice4"
mkdir -p "$case_dir/core" "$case_dir/conf"
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$FAKE_CORE"
is_core_ver=1.14.0
is_main_start=1
export ip=203.0.113.10 is_dont_get_ip=1
printf '{"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_config_json"

manage_log="$case_dir/manage.log"
: >"$manage_log"
manage() { printf '%s\n' "$*" >>"$manage_log"; }
systemctl() { printf '%s\n' "$*" >>"$manage_log"; return 0; }
is_port_used() { :; }

# 1. Empty state shows flat 5-item menu and guards options 4 (备注) and 5 (删除).
empty_menu_out=$(relay_menu 2>&1 <<'INPUT'
4

5

0
INPUT
) || fail "empty relay_menu navigation failed: $empty_menu_out"
for item in '1) 添加' '2) 列表' '3) 查看' '4) 备注' '5) 删除' '0) 返回上级'; do
    grep -Fq "$item" <<<"$empty_menu_out" || fail "relay_menu missing item '$item': $empty_menu_out"
done
[[ $(grep -Fc '暂无端口转发，请先添加' <<<"$empty_menu_out") == 2 ]] || fail "options 4 and 5 should both show empty state when no relays exist: $empty_menu_out"

# 2. Setup relays, then edit/keep/clear note via option 4, delete via option 5, add via option 1.
main relay add 13000 203.0.113.10 23000 >/dev/null 2>&1 || fail "setup 13000 failed"
main relay add 13001 203.0.113.11 23001 >/dev/null 2>&1 || fail "setup 13001 failed"
before_13000=$(cat "$is_conf_dir/relay-13000.json")
before_cfg=$(cat "$is_config_json")
: >"$manage_log"

edit_out=$(relay_menu 2>&1 <<'INPUT'
4
13000
  菜单编辑备注  

0
INPUT
) || fail "relay_menu option 4 edit failed: $edit_out"
grep -Fq '当前备注: (无)' <<<"$edit_out" || fail "relay_menu option 4 did not enter note_edit_interactive: $edit_out"
[[ $(note_get relay-13000.json) == '菜单编辑备注' ]] || fail "relay_menu option 4 did not save note: '$(note_get relay-13000.json)'"

(relay_menu >/dev/null 2>&1 <<'INPUT'
4
13000


0
INPUT
) || fail "relay_menu option 4 keep-on-enter failed"
[[ $(note_get relay-13000.json) == '菜单编辑备注' ]] || fail "relay_menu Enter cleared note"

(relay_menu >/dev/null 2>&1 <<'INPUT'
4
13000
clear

0
INPUT
) || fail "relay_menu option 4 clear failed"
[[ -z $(note_get relay-13000.json) ]] || fail "relay_menu clear failed"
[[ ! -e "$is_conf_dir/.quan-meta/relay-13000.json.meta.json" ]] || fail "relay_menu clear left empty meta file"

[[ $(cat "$is_conf_dir/relay-13000.json") == "$before_13000" ]] || fail "relay_menu option 4 mutated relay config"
[[ $(cat "$is_config_json") == "$before_cfg" ]] || fail "relay_menu option 4 mutated runtime config.json"
[[ ! -s $manage_log ]] || fail "relay_menu option 4 triggered service restart: $(cat "$manage_log")"

del_out=$(relay_menu 2>&1 <<'INPUT'
5
13001
y

0
INPUT
) || fail "relay_menu option 5 delete failed: $del_out"
[[ ! -f "$is_conf_dir/relay-13001.json" ]] || fail "relay_menu option 5 did not delete relay-13001.json"

add_menu_out=$(relay_menu 2>&1 <<'INPUT'
1
13002
203.0.113.12
23002
菜单添加备注

0
INPUT
) || fail "relay_menu option 1 add with note failed: $add_menu_out"
[[ $(note_get relay-13002.json) == '菜单添加备注' ]] || fail "relay_menu option 1 did not save note"
grep -Fq '备注: 菜单添加备注' <<<"$add_menu_out" || fail "relay_menu option 1 echo missing note: $add_menu_out"
CASE
}

run_slice5_delete_cleanup_and_rebuild() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" FAKE_CORE="$fake_core" bash <<'CASE' || exit 1
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*" >&2
    exit 1
}

source "$CORE_FILE"
case_dir="$WORKDIR/slice5"
mkdir -p "$case_dir/core" "$case_dir/conf"
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$FAKE_CORE"
is_core_ver=1.14.0
export ip=203.0.113.10 is_dont_get_ip=1
printf '{"outbounds":[{"tag":"direct","type":"direct"}]}\n' >"$is_config_json"

manage() { :; }
systemctl() { return 0; }
is_port_used() { :; }

main relay add 14000 203.0.113.10 24000 '旧端口转发备注' >/dev/null 2>&1 || fail "setup 14000 failed"
main relay add 14001 203.0.113.11 24001 '保留其他端口备注' >/dev/null 2>&1 || fail "setup 14001 failed"
main relay add 14002 203.0.113.12 24002 >/dev/null 2>&1 || fail "setup 14002 failed"

# 1. Failed delete rollback preserves both relay config and metadata.
export TEST_REJECT_COMPLETE=1
if (main relay delete 14000) >/dev/null 2>&1; then
    fail "delete should fail when complete config check fails"
fi
unset TEST_REJECT_COMPLETE
[[ -f "$is_conf_dir/relay-14000.json" ]] || fail "failed delete did not restore relay-14000.json"
[[ $(note_get relay-14000.json) == '旧端口转发备注' ]] || fail "failed delete rollback lost metadata"

# 2. Successful delete removes metadata; rebuilding same port without note does not inherit old note.
(main relay delete 14000) >/dev/null 2>&1 || fail "relay delete 14000 failed"
[[ ! -f "$is_conf_dir/relay-14000.json" ]] || fail "relay-14000.json still exists"
[[ ! -e "$is_conf_dir/.quan-meta/relay-14000.json.meta.json" ]] || fail "relay-14000.json.meta.json was not deleted"
[[ $(note_get relay-14001.json) == '保留其他端口备注' ]] || fail "deleting 14000 altered 14001 metadata"

main relay add 14000 203.0.113.20 24000 >/dev/null 2>&1 || fail "rebuild 14000 failed"
[[ -z $(note_get relay-14000.json) ]] || fail "rebuilt relay 14000 inherited old note"
[[ ! -e "$is_conf_dir/.quan-meta/relay-14000.json.meta.json" ]] || fail "rebuilt relay 14000 has leftover meta file"
rebuilt_info=$(main relay info 14000 2>&1)
[[ $rebuilt_info != *'备注:'* && $rebuilt_info != *'旧端口转发备注'* ]] || fail "rebuilt relay info exposed old note: $rebuilt_info"
rebuilt_list=$(main relay list 2>&1)
grep -Fxq '监听端口 14000 -> 目标 203.0.113.20:24000 (TCP/UDP)' <<<"$rebuilt_list" || fail "rebuilt relay list polluted by old note: $rebuilt_list"

# 3. Deleting a relay without metadata succeeds cleanly.
(main relay delete 14002) >/dev/null 2>&1 || fail "deleting plain relay 14002 failed"
[[ ! -f "$is_conf_dir/relay-14002.json" ]] || fail "plain relay 14002 not deleted"

# 4. Interactive menu delete cancel keeps metadata; confirm removes metadata.
is_main_start=1
(relay_menu >/dev/null 2>&1 <<'INPUT'
5
14001
n

0
INPUT
) || fail "interactive relay_menu delete cancel failed"
[[ -f "$is_conf_dir/relay-14001.json" ]] || fail "canceled delete removed 14001"
[[ $(note_get relay-14001.json) == '保留其他端口备注' ]] || fail "canceled delete removed 14001 metadata"

(relay_menu >/dev/null 2>&1 <<'INPUT'
5
14001
y

0
INPUT
) || fail "interactive relay_menu delete confirm failed"
[[ ! -f "$is_conf_dir/relay-14001.json" ]] || fail "confirmed delete did not remove 14001"
[[ ! -e "$is_conf_dir/.quan-meta/relay-14001.json.meta.json" ]] || fail "confirmed delete left 14001 metadata behind"
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

    grep -Fq 'relay add [local-port] [remote-addr] [remote-port] [note]' <<<"$help_out" || fail "sb help missing relay add [note] usage: $help_out"
    grep -Fq 'relay note [local-port] [备注内容 | --clear]' <<<"$help_out" || fail "sb help missing relay note usage: $help_out"
    grep -Fq 'one-singbox' <<<"$help_out" || fail "sb help missing one-singbox term"
    ! grep -Eq '管理面板|端口中转|中转' <<<"$help_out" || fail "sb help contains forbidden terminology: $help_out"
    grep -Fq 'scripts/run-offline-tests.sh' "$repo_dir/.github/workflows/pr-check.yml" || fail "pr-check.yml missing scripts/run-offline-tests.sh"
}

run_slice1_add_and_info "$repo_root/src/core.sh"
run_slice2_list_summary "$repo_root/src/core.sh"
run_slice3_relay_note_cli_and_interactive "$repo_root"
run_slice4_relay_menu "$repo_root/src/core.sh"
run_slice5_delete_cleanup_and_rebuild "$repo_root/src/core.sh"
run_slice6_help_and_gate "$repo_root"
echo "PASS: relay note tests"
