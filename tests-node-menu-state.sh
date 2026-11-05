#!/usr/bin/env bash
set -o pipefail
repo_root=$(cd "$(dirname "$0")" && pwd)
for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
  for choice in 18 8; do
    CORE_FILE=$core_file CHOICE=$choice timeout 10 bash <<'CASE' || exit 1
source <(sed '/EUID != 0/d' "$CORE_FILE")
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir
is_conf_dir=$case_dir/conf
mkdir -p "$is_conf_dir"
cat >"$is_conf_dir/VLESS-REALITY-26699.json" <<'JSON'
{"inbounds":[{"type":"vless","listen":"::","listen_port":26699,"users":[{"uuid":"11111111-1111-4111-8111-111111111111"}],"tls":{"server_name":"example.com","reality":{"private_key":"key"}}}],"outbounds":[{"type":"direct"},{"tag":"public_key_key","type":"direct"}]}
JSON
is_main_start=1
ip=203.0.113.1
get_ip() { :; }
get_port() { tmp_port=30000; }
get_uuid() { tmp_uuid=22222222-2222-4222-8222-222222222222; }
render_qrcode() { :; }
node_port_used() { :; }
create() { printf '%s %s %s\n' "$2" "$port" "${is_config_file:-empty}" >"$case_dir/result"; }
# Supply SS method and password only for that protocol.
if [[ $CHOICE == 8 ]]; then
  input=$'3\n\n1\n8\n30001\n1\n\nnewname\n\n5\n'
else
  input=$'3\n\n1\n18\n30001\nnewname\n\n5\n'
fi
node_menu <<<"$input" >"$case_dir/output" 2>&1
read -r protocol selected_port selected_file <"$case_dir/result"
[[ $selected_port == 30001 && $selected_file == empty ]] || {
  printf 'FAIL: %s choice %s reused port=%s file=%s\n' "$CORE_FILE" "$CHOICE" "$selected_port" "$selected_file"
  exit 1
}
CASE
  done
done
for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
  CORE_FILE=$core_file bash <<'CASE' || exit 1
source <(sed '/EUID != 0/d' "$CORE_FILE")
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_conf_dir=$case_dir
is_main_start=1
get_port() { tmp_port=32000; }
get_uuid() { tmp_uuid=22222222-2222-4222-8222-222222222222; }
create() { echo "$port" >>"$case_dir/ports"; is_config_file=created.json; }
info() { :; }
meta_set() { :; }
node_port_used() { :; }
node_menu >"$case_dir/output" 2>&1 <<'INPUT'
1
18
30001
first

1
18
30002
second

5
INPUT
[[ $(cat "$case_dir/ports") == $'30001\n30002' ]] || { echo "FAIL: $CORE_FILE reused the first node's port"; exit 1; }
CASE
done
for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
  for action in 2 3; do
    CORE_FILE=$core_file ACTION=$action bash <<'CASE' || exit 1
source <(sed '/EUID != 0/d' "$CORE_FILE")
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_conf_dir=$case_dir
is_main_start=1
ip=203.0.113.1
get_ip() { :; }
render_qrcode() { :; }
for n in 1 2; do
    printf '{"inbounds":[{"type":"shadowsocks","listen_port":%s,"method":"aes-128-gcm","password":"example"}]}\n' "$((30000+n))" >"$is_conf_dir/node$n.json"
done
eval "$(declare -f ask | sed '1s/^ask /original_ask /')"
ask() {
    if [[ $1 == set_change_list ]]; then
        printf '%s' "$is_config_file" >"$case_dir/changed-target"
        is_can_change=(999)
        REPLY=1
    else
        original_ask "$@"
    fi
}
node_menu >"$case_dir/output" 2>&1 <<<"$(printf '3\n1\n\n%s\n2\n\n5\n' "$ACTION")"
[[ $(grep -Fx -c '选择节点:' "$case_dir/output") == 2 ]] || { echo "FAIL: $CORE_FILE did not prompt for the second node"; exit 1; }
if [[ $ACTION == 2 ]]; then
    [[ $(cat "$case_dir/changed-target") == node2.json ]] || { echo "FAIL: $CORE_FILE selected the wrong node for modification"; exit 1; }
else
    grep -q 'node2.json' "$case_dir/output" || { echo "FAIL: $CORE_FILE did not show the second node"; exit 1; }
fi
CASE
  done
done
for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
  CORE_FILE=$core_file bash <<'CASE' || exit 1
source <(sed '/EUID != 0/d' "$CORE_FILE")
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_conf_dir=$case_dir
: >"$is_conf_dir/existing.json"
change() { is_change=1; port=26699; is_config_file=existing.json; }
add() { printf '%s %s %s\n' "${is_change:-empty}" "${port:-empty}" "${is_config_file:-empty}" >"$case_dir/result"; }
node_menu <<<'2

1

5' >"$case_dir/output" 2>&1
[[ $(cat "$case_dir/result") == 'empty empty empty' ]] || { echo "FAIL: $CORE_FILE retained state after changing a node"; exit 1; }
CASE
done
for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
  CORE_FILE=$core_file bash <<'CASE' || exit 1
source <(sed '/EUID != 0/d' "$CORE_FILE")
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_core_dir=$case_dir
is_conf_dir=$case_dir/conf
mkdir -p "$is_conf_dir"
is_config_file=existing.json
cat >"$is_conf_dir/$is_config_file" <<'JSON'
{"inbounds":[{"type":"shadowsocks","listen_port":26699}]}
JSON
original=$(cat "$is_conf_dir/$is_config_file")
is_new_protocol=Shadowsocks
is_protocol=shadowsocks
json_str='method:"aes-128-gcm",password:"test"'
ip=203.0.113.1
uuid=22222222-2222-4222-8222-222222222222
get_ip() { :; }
node_port_used() { :; }
sync_runtime_node_outbound_modes() { :; }
manage() { :; }
port=26699
if (create server Shadowsocks) >"$case_dir/conflict" 2>&1; then
  echo "FAIL: $CORE_FILE allowed an existing configuration's port"
  exit 1
fi
[[ $(cat "$is_conf_dir/existing.json") == "$original" ]] || { echo 'FAIL: conflict changed the existing node'; exit 1; }
port=30001
create server Shadowsocks >"$case_dir/create" 2>&1 || { echo 'FAIL: creation with a free port failed'; exit 1; }
[[ $(cat "$is_conf_dir/existing.json") == "$original" && -f "$is_conf_dir/Shadowsocks-30001.json" ]] || { echo 'FAIL: creation removed the existing node'; exit 1; }
CASE
done
printf 'PASS: node menu isolates state and creation protects existing configurations\n' 
