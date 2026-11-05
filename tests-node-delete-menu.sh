#!/usr/bin/env bash
set -o pipefail
repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

for core in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
  (
    source <(sed '/EUID != 0/d' "$core")
    is_core_dir="$workdir/core"
    is_conf_dir="$workdir/conf"
    is_config_json="$workdir/config.json"
    is_core_bin=/bin/true
    is_main_start=1
    is_dont_get_ip=1
    mkdir -p "$is_core_dir" "$is_conf_dir"
    for name in a b; do
      printf '{"inbounds":[{"type":"vless","listen_port":12345,"transport":{"type":"ws"}}],"outbounds":[{},{}]}\n' > "$is_conf_dir/$name.json"
    done
    node_menu >"$workdir/output" 2>&1 <<'INPUT'
4
1
y

4
1
n

4
1
y

4

5
INPUT
    output=$(cat "$workdir/output")
    [[ $(grep -Fx -c '选择节点:' <<<"$output") == 3 ]] || { echo "FAIL: node list prompt is concise and shown for every deletion"; exit 1; }
    [[ $(grep -c '将删除节点“a.json”' <<<"$output") == 1 ]] || { echo "FAIL: deleted node selected again"; exit 1; }
    [[ $(grep -c '将删除节点“b.json”' <<<"$output") == 2 ]] || { echo "FAIL: second node confirmation missing"; exit 1; }
    [[ $(grep -c '已取消删除节点' <<<"$output") == 1 ]] || { echo "FAIL: cancellation not honored"; exit 1; }
    [[ ! -f $is_conf_dir/a.json && ! -f $is_conf_dir/b.json ]] || { echo "FAIL: confirmed deletion failed"; exit 1; }
    grep -q '暂无节点，请先添加' <<<"$output" || { echo "FAIL: empty list not reported"; exit 1; }
    echo "PASS: $core"
    rm -rf "$is_conf_dir" "$is_core_dir"
  ) || exit 1
done
