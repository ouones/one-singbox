#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage:' \
    '  singbox_inventory.sh nodes [conf-dir]' \
    '  singbox_inventory.sh relays [conf-dir]' \
    '  singbox_inventory.sh logs [lines] [match] [log-file]'
}

need_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf 'ERROR: jq is required for inventory\n' >&2
    exit 2
  }
}

conf_dir=${SINGBOX_CONF_DIR:-/etc/sing-box/conf}
log_file=${SINGBOX_LOG_FILE:-/var/log/sing-box/access.log}
action=${1:-}

node_name() {
  local base=$1 meta name
  meta="$conf_dir/.quan-meta/${base}.meta.json"
  name=''
  if [[ -f $meta ]]; then
    name=$(jq -r '.node_name // empty' "$meta" 2>/dev/null || true)
  fi
  if [[ -n $name ]]; then
    printf '%s' "$name"
  else
    printf '%s' "${base%.json}"
  fi
}

node_value() {
  local file=$1 query=$2 value
  value=$(jq -r "$query" "$file" 2>/dev/null) || return 1
  [[ $value == null ]] && value=''
  printf '%s' "$value"
}

list_nodes() {
  local files=() file base name protocol listen listen_display port host sni network method security target count=0
  [[ -d $conf_dir ]] || {
    printf 'ERROR: configuration directory not found: %s\n' "$conf_dir" >&2
    exit 1
  }
  shopt -s nullglob
  files=("$conf_dir"/*.json)
  shopt -u nullglob
  printf '代理节点（共 '
  # The count is printed after filtering invalid and relay files below.
  local valid=()
  for file in "${files[@]}"; do
    base=${file##*/}
    [[ $base == relay-* ]] && continue
    [[ $base == dynamic-port-* ]] && continue
    jq -e . "$file" >/dev/null 2>&1 || continue
    valid+=("$file")
  done
  printf '%d 个）\n' "${#valid[@]}"
  if [[ ${#valid[@]} -eq 0 ]]; then
    printf '\n'
    return
  fi
  for file in "${valid[@]}"; do
    base=${file##*/}
    name=$(node_name "$base")
    protocol=$(node_value "$file" '.inbounds[0].type // "-"' || printf '%s' '-')
    listen=$(node_value "$file" '.inbounds[0].listen // "-"' || printf '%s' '-')
    port=$(node_value "$file" '.inbounds[0].listen_port // "-"' || printf '%s' '-')
    host=$(node_value "$file" '(.inbounds[0].transport.headers.host // .inbounds[0].tls.server_name // "")' || true)
    sni=$(node_value "$file" '.inbounds[0].tls.server_name // ""' || true)
    network=$(node_value "$file" '.inbounds[0].transport.type // ""' || true)
    method=$(node_value "$file" '.inbounds[0].method // ""' || true)
    security=$(node_value "$file" 'if .inbounds[0].tls.reality then "REALITY" elif .inbounds[0].tls then "TLS" else "" end' || true)
    target=$(node_value "$file" 'if .inbounds[0].override_address then ((.inbounds[0].override_address|tostring)+":"+(.inbounds[0].override_port|tostring)) else "" end' || true)
    if [[ $listen == *:* && $listen != \[*\] ]]; then
      listen_display="[$listen]"
    else
      listen_display="$listen"
    fi
    ((count += 1))
    printf '%d. %s\n' "$count" "$name"
    printf '   协议：%s\n' "$protocol"
    printf '   监听：%s:%s\n' "$listen_display" "$port"
    [[ -n $host ]] && printf '   域名：%s\n' "$host"
    [[ -n $sni && $sni != "$host" ]] && printf '   SNI：%s\n' "$sni"
    [[ -n $network ]] && printf '   传输：%s\n' "$network"
    [[ -n $security ]] && printf '   安全：%s\n' "$security"
    [[ -n $method ]] && printf '   加密：%s\n' "$method"
    [[ -n $target ]] && printf '   目标：%s\n' "$target"
    printf '\n'
  done
}

list_relays() {
  local files=() valid=() file base local_port address address_display remote_port count=0
  [[ -d $conf_dir ]] || {
    printf 'ERROR: configuration directory not found: %s\n' "$conf_dir" >&2
    exit 1
  }
  shopt -s nullglob
  files=("$conf_dir"/relay-*.json)
  shopt -u nullglob
  for file in "${files[@]}"; do
    jq -e . "$file" >/dev/null 2>&1 || {
      printf 'WARN: skipping invalid relay config: %s\n' "${file##*/}" >&2
      continue
    }
    valid+=("$file")
  done
  printf '中转列表（共 %d 个）\n\n' "${#valid[@]}"
  for file in "${valid[@]}"; do
    base=${file##*/}
    local_port=$(node_value "$file" '.inbounds[0].listen_port // "-"' || printf '%s' '-')
    address=$(node_value "$file" '.inbounds[0].override_address // "-"' || printf '%s' '-')
    remote_port=$(node_value "$file" '.inbounds[0].override_port // "-"' || printf '%s' '-')
    if [[ $address == *:* && $address != \[*\] ]]; then
      address_display="[$address]"
    else
      address_display="$address"
    fi
    ((count += 1))
    printf '%d. %s -> %s:%s\n' "$count" "$local_port" "$address_display" "$remote_port"
    printf '   类型：direct\n'
    printf '   网络：tcp,udp\n\n'
  done
  if [[ $count -eq 0 && ${#valid[@]} -gt 0 ]]; then
    printf '（没有有效的中转配置）\n'
  fi
}

bounded_logs() {
  local lines=${1:-100} match=${2:-} file=${3:-$log_file} rc
  [[ $lines =~ ^[1-9][0-9]*$ ]] || {
    printf 'ERROR: lines must be a positive integer\n' >&2
    exit 2
  }
  ((lines <= 1000)) || {
    printf 'ERROR: lines is capped at 1000\n' >&2
    exit 2
  }
  [[ -f $file ]] || {
    printf 'ERROR: log file not found: %s\n' "$file" >&2
    exit 1
  }
  if [[ -n $match ]]; then
    set +e
    tail -n "$lines" "$file" | grep -F -- "$match"
    rc=$?
    set -e
    [[ $rc -eq 0 || $rc -eq 1 ]] || exit "$rc"
  else
    tail -n "$lines" "$file"
  fi
}

case $action in
  nodes)
    need_jq
    [[ ${2:-} ]] && conf_dir=$2
    list_nodes
    ;;
  relays)
    need_jq
    [[ ${2:-} ]] && conf_dir=$2
    list_relays
    ;;
  logs)
    bounded_logs "${2:-100}" "${3:-}" "${4:-$log_file}"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
