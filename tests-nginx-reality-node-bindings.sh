#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
    case_dir="$workdir/$(basename "$(dirname "$core_file")")-$(basename "$core_file")"
    mkdir -p "$case_dir/bin"
    export CASE_DIR="$case_dir" FRONTEND_EVENT_LOG="$case_dir/events"
    export FRONTEND_NGINX_BIN="$case_dir/bin/nginx" FRONTEND_NGINX_CONF="$case_dir/nginx.conf"
    export FRONTEND_NGINX_PREFIX="$case_dir/prefix" FRONTEND_NGINX_READY=1 FRONTEND_NGINX_LISTENERS=
    export FRONTEND_UDP_LISTENERS= FRONTEND_LISTENER_SOURCE_DIR=
    export FRONTEND_LISTENER_FILE="$case_dir/listeners"
    export FRONTEND_RELOAD_COUNT_FILE="$case_dir/reload-count"
    export FRONTEND_SINGBOX_RESTART_COUNT_FILE="$case_dir/singbox-restart-count"
    export FRONTEND_FAIL_RELOAD_AT=0 FRONTEND_FAIL_NGINX_CHECK=0 FRONTEND_FAIL_SINGBOX_CHECK=0 FRONTEND_FAIL_SINGBOX_RESTART=0 FRONTEND_FAIL_SINGBOX_RESTART_AT=0
    export FRONTEND_PAUSE_RELOAD_AT=0 FRONTEND_PAUSE_FILE="$case_dir/reload-paused" FRONTEND_RELEASE_FILE="$case_dir/release-reload" FRONTEND_PAUSE_PID_FILE="$case_dir/reload-pid"
    : >"$FRONTEND_EVENT_LOG"
    : >"$FRONTEND_RELOAD_COUNT_FILE"
    : >"$FRONTEND_LISTENER_FILE"
    : >"$FRONTEND_SINGBOX_RESTART_COUNT_FILE"

    cat >"$case_dir/bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
case "$*" in
    'is-active --quiet nginx.service') [[ $FRONTEND_NGINX_READY == 1 ]] ;;
    'show -p MainPID --value nginx.service') [[ $FRONTEND_NGINX_READY == 1 ]] && printf '123\n' ;;
    'show -p MainPID --value sing-box') printf '777\n' ;;
    'show -p ExecStart --value nginx.service') [[ $FRONTEND_NGINX_READY == 1 ]] && printf '{ path=%s ; argv[]=%s -c %s -p %s ; ignore_errors=no }\n' "$FRONTEND_NGINX_BIN" "$FRONTEND_NGINX_BIN" "$FRONTEND_NGINX_CONF" "$FRONTEND_NGINX_PREFIX" ;;
    'show -p ExecReload --value nginx.service') [[ $FRONTEND_NGINX_READY == 1 ]] && printf '{ path=/bin/kill ; argv[]=/bin/kill -s HUP $MAINPID ; ignore_errors=no }\n' ;;
    'reload nginx.service')
        count=0
        [[ -f $FRONTEND_RELOAD_COUNT_FILE ]] && read -r count <"$FRONTEND_RELOAD_COUNT_FILE"
        count=$((count + 1))
        printf '%s\n' "$count" >"$FRONTEND_RELOAD_COUNT_FILE"
        printf '%s\n' nginx-reload >>"$FRONTEND_EVENT_LOG"
        if [[ $FRONTEND_PAUSE_RELOAD_AT == "$count" ]]; then
            printf '%s\n' "$BASHPID" >"$FRONTEND_PAUSE_PID_FILE"
            : >"$FRONTEND_PAUSE_FILE"
            while [[ ! -e $FRONTEND_RELEASE_FILE ]]; do /bin/sleep 0.02; done
        fi
        [[ ,$FRONTEND_FAIL_RELOAD_AT, != *,$count,* ]] || exit 1
        project_stream_file="$CASE_DIR/one-singbox/stream.conf"
        [[ $FRONTEND_LISTENER_SOURCE_DIR ]] && project_stream_file="$FRONTEND_LISTENER_SOURCE_DIR/one-singbox/stream.conf"
        if grep -Eq 'listen[[:space:]].*([^0-9]|^)443([[:space:]]|;)' "$FRONTEND_NGINX_CONF" "$project_stream_file" 2>/dev/null; then
            printf '%s\n' 'LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=123,fd=6))' >"$FRONTEND_LISTENER_FILE"
        else
            : >"$FRONTEND_LISTENER_FILE"
        fi
        ;;
    *) exit 1 ;;
esac
FAKE_SYSTEMCTL
    cat >"$case_dir/bin/ps" <<'FAKE_PS'
#!/usr/bin/env bash
case "$*" in
    '-o ppid= -p 456') printf '123\n' ;;
    '-o ppid= -p 900'|'-o ppid= -p 901'|'-o ppid= -p 124') printf '1\n' ;;
    '-o args= -p 123') printf 'nginx: master process %s -c %s -p %s\n' "$FRONTEND_NGINX_BIN" "$FRONTEND_NGINX_CONF" "$FRONTEND_NGINX_PREFIX" ;;
    '-eo pid=,args=')
        count=0
        [[ -f $FRONTEND_RELOAD_COUNT_FILE ]] && read -r count <"$FRONTEND_RELOAD_COUNT_FILE"
        printf '123 nginx: master process %s -c %s -p %s\n' "$FRONTEND_NGINX_BIN" "$FRONTEND_NGINX_CONF" "$FRONTEND_NGINX_PREFIX"
        printf '900 nginx: worker process\n'
        printf '%s nginx: worker process\n' "$((456 + count))"
        ;;
    *) exit 2 ;;
esac
FAKE_PS
    cat >"$case_dir/bin/readlink" <<'FAKE_READLINK'
#!/usr/bin/env bash
last_arg=$(printf '%s\n' "$@" | tail -n1)
case "$last_arg" in
    /proc/123/exe) printf '%s\n' "$FRONTEND_NGINX_BIN" ;;
    /proc/777/exe) printf '%s\n' "$CASE_DIR/bin/sing-box" ;;
    /proc/*/exe) printf '%s\n' "$FRONTEND_NGINX_BIN" ;;
    "$FRONTEND_NGINX_BIN"|"$CASE_DIR/bin/sing-box") printf '%s\n' "$last_arg" ;;
    *) exec /usr/bin/readlink "$@" ;;
esac
FAKE_READLINK
    cat >"$case_dir/bin/ss" <<'FAKE_SS'
#!/usr/bin/env bash
case $* in
'-Hlnpu')
    [[ $FRONTEND_UDP_LISTENERS ]] && printf '%s\n' "$FRONTEND_UDP_LISTENERS"
    ;;
'-Hlnpt')
    if [[ ${FRONTEND_UDP_LISTENERS_ONLY:-0} == 1 ]]; then
        [[ -f $FRONTEND_LISTENER_FILE ]] && cat "$FRONTEND_LISTENER_FILE"
    elif [[ $FRONTEND_NGINX_LISTENERS ]]; then
        printf '%s\n' "$FRONTEND_NGINX_LISTENERS"
    elif [[ -f $FRONTEND_LISTENER_FILE ]]; then
        cat "$FRONTEND_LISTENER_FILE"
    fi
    ;;
*) exit 2 ;;
esac
exit 0
FAKE_SS
    cat >"$case_dir/bin/ip" <<'FAKE_IP'
#!/usr/bin/env bash
case "$*" in
    '-o -4 addr show scope global') printf '2: eth0 inet 203.0.113.10/24 scope global eth0\n' ;;
    '-o -6 addr show scope global') exit 1 ;;
    *) exit 2 ;;
esac
FAKE_IP
    cat >"$case_dir/bin/nginx" <<'FAKE_NGINX'
#!/usr/bin/env bash
case " $* " in
    *' -V '*) printf 'nginx version: nginx/1.26.2\nconfigure arguments: --prefix=%s --conf-path=%s --with-stream=dynamic --with-stream_ssl_preread_module=dynamic\n' "$FRONTEND_NGINX_PREFIX" "$FRONTEND_NGINX_CONF" ;;
    *' -t '*) [[ $FRONTEND_FAIL_NGINX_CHECK != 1 ]] ;;
    *' -T '*)
        printf '# configuration file %s:\n' "$FRONTEND_NGINX_CONF"
        cat "$FRONTEND_NGINX_CONF"
        ;;
    *) exit 2 ;;
esac
FAKE_NGINX
    chmod +x "$case_dir/bin/"*
    printf 'events {}\nhttp {}\n' >"$FRONTEND_NGINX_CONF"
    mkdir -p "$FRONTEND_NGINX_PREFIX"
    cat >"$case_dir/bin/sing-box" <<'FAKE_SINGBOX'
#!/usr/bin/env bash
case "$*" in
    'generate reality-keypair') printf 'PrivateKey: test-private-key\nPublicKey: test-public-key\n' ;;
    check\ *) [[ $FRONTEND_FAIL_SINGBOX_CHECK != 1 ]] ;;
    *) exit 2 ;;
esac
FAKE_SINGBOX
    chmod +x "$case_dir/bin/sing-box"

    CORE_FILE="$core_file" REPO_ROOT="$repo_root" PATH="$case_dir/bin:$PATH" bash <<'CASE'
set -o pipefail
source "$CORE_FILE"
is_core_dir="$CASE_DIR/sing-box"
is_conf_dir="$is_core_dir/conf"
is_config_json="$is_core_dir/config.json"
is_core_bin="$CASE_DIR/bin/sing-box"
is_sh_dir="$REPO_ROOT"
is_dont_auto_exit=1
is_dont_get_ip=1
ip=203.0.113.10
mkdir -p "$is_conf_dir/.quan-meta"

is_port_used() {
    if [[ $1 == 443 && ( $FRONTEND_NGINX_LISTENERS || $FRONTEND_UDP_LISTENERS ) ]]; then
        printf '443\n'
        return 0
    fi
    return 1
}
manage_restart_confirmed() {
    printf '%s\n' singbox-restart >>"$FRONTEND_EVENT_LOG"
    count=0
    [[ -f $FRONTEND_SINGBOX_RESTART_COUNT_FILE ]] && read -r count <"$FRONTEND_SINGBOX_RESTART_COUNT_FILE"
    count=$((count + 1))
    printf '%s\n' "$count" >"$FRONTEND_SINGBOX_RESTART_COUNT_FILE"
    [[ $FRONTEND_FAIL_SINGBOX_RESTART != 1 ]] || return 1
    [[ $FRONTEND_FAIL_SINGBOX_RESTART_AT != "$count" ]] || return 1
    if [[ $FRONTEND_NGINX_LISTENERS == *'"sing-box"'* ]]; then
        FRONTEND_NGINX_LISTENERS=
        export FRONTEND_NGINX_LISTENERS
        : >"$FRONTEND_LISTENER_FILE"
    fi
    return 0
}

cat >"$is_conf_dir/existing-node.json" <<'NODE'
{"inbounds":[{"type":"vless","tag":"legacy-tag","listen":"::","listen_port":443,"users":[{"uuid":"11111111-1111-4111-8111-111111111111","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"legacy.example","reality":{"enabled":true,"handshake":{"server":"legacy.example","server_port":443},"private_key":"legacy-private","short_id":["abcd"]}}}]}
NODE
cat >"$is_conf_dir/unselected-node.json" <<'NODE'
{"inbounds":[{"type":"vless","tag":"other-legacy-tag","listen":"::","listen_port":443,"users":[{"uuid":"22222222-2222-4222-8222-222222222222","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"other.example","reality":{"enabled":true,"handshake":{"server":"other.example","server_port":443},"private_key":"other-private","short_id":["ef01"]}}}]}
NODE
cat >"$is_conf_dir/untouched-node.json" <<'NODE'
{"inbounds":[{"type":"vless","tag":"untouched-tag","listen":"::","listen_port":8443,"users":[{"uuid":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"untouched.example","reality":{"enabled":true,"handshake":{"server":"untouched.example","server_port":443},"private_key":"untouched-private","short_id":["9876"]}}}]}
NODE
jq -n '{node_name:"Legacy Node",entry_addr:"node.example"}' >"$(meta_file existing-node.json)"
jq -n '{node_name:"Other Legacy Node"}' >"$(meta_file unselected-node.json)"
jq -n '{node_name:"Untouched Node"}' >"$(meta_file untouched-node.json)"
jq -n '{log:{level:"info"},dns:{},outbounds:[{tag:"direct",type:"direct"}],test_marker:"preserve"}' >"$is_config_json"
legacy_meta_before=$(sha256sum "$(meta_file existing-node.json)" | awk '{print $1}')
untouched_before=$(sha256sum "$is_conf_dir/untouched-node.json" "$(meta_file untouched-node.json)" | sha256sum | awk '{print $1}')
FRONTEND_NGINX_LISTENERS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("sing-box",pid=777,fd=7))'
export FRONTEND_NGINX_LISTENERS

unselected_before=$(sha256sum "$is_conf_dir/existing-node.json" "$is_conf_dir/unselected-node.json" "$is_config_json" | sha256sum | awk '{print $1}')
unselected_error=$(printf '1\n' | main frontend enable existing-node.json 2>&1) && {
    echo 'FAIL: enable must reject a partial migration while another direct-443 node is unselected'
    exit 1
}
[[ $(sha256sum "$is_conf_dir/existing-node.json" "$is_conf_dir/unselected-node.json" "$is_config_json" | sha256sum | awk '{print $1}') == "$unselected_before" && ! -s "$FRONTEND_EVENT_LOG" ]] || {
    echo "FAIL: partial migration changed node files or restarted a service: $unselected_error"
    exit 1
}

migration_output=$(printf '1\n' | main frontend enable existing-node.json unselected-node.json 2>&1) || {
    echo "FAIL: explicit migration of all eligible direct-443 nodes should succeed: $migration_output"
    exit 1
}
jq -e '.enabled == true and (.bindings | length == 2) and ([.bindings[].node_ref] | sort == ["existing-node.json","unselected-node.json"])' "$is_core_dir/frontend.json" >/dev/null || {
    echo 'FAIL: migration should record both explicit bindings'
    exit 1
}
for node_ref in existing-node.json unselected-node.json; do
    jq -e '.inbounds[0].listen == "127.0.0.1" and .inbounds[0].listen_port >= 49152 and .inbounds[0].listen_port <= 65535' "$is_conf_dir/$node_ref" >/dev/null || {
        echo "FAIL: migrated node should use a unique loopback backend: $node_ref"
        exit 1
    }
done
jq -e '.inbounds[0].tag == "legacy-tag" and .inbounds[0].users[0].uuid == "11111111-1111-4111-8111-111111111111" and .inbounds[0].users[0].flow == "xtls-rprx-vision" and .inbounds[0].tls.server_name == "legacy.example" and .inbounds[0].tls.reality.handshake.server == "legacy.example" and .inbounds[0].tls.reality.private_key == "legacy-private" and .inbounds[0].tls.reality.short_id == ["abcd"]' "$is_conf_dir/existing-node.json" >/dev/null || {
    echo 'FAIL: migration changed the existing tag or SNI'
    exit 1
}
[[ $(sha256sum "$(meta_file existing-node.json)" | awk '{print $1}') == "$legacy_meta_before" ]] || {
    echo 'FAIL: migration changed existing node metadata'
    exit 1
}
[[ $(sha256sum "$is_conf_dir/untouched-node.json" "$(meta_file untouched-node.json)" | sha256sum | awk '{print $1}') == "$untouched_before" ]] || {
    echo 'FAIL: migration changed an unrelated non-443 node or its metadata'
    exit 1
}
jq -e '.test_marker == "preserve"' "$is_config_json" >/dev/null 2>&1 || {
    echo "FAIL: migration dropped unrelated shared configuration at $is_config_json: $(cat "$is_config_json")"
    exit 1
}
[[ $(sed -n '1p' "$FRONTEND_EVENT_LOG") == singbox-restart && $(sed -n '2p' "$FRONTEND_EVENT_LOG") == nginx-reload ]] || {
    echo "FAIL: migration must restart sing-box before Nginx reload: $(cat "$FRONTEND_EVENT_LOG")"
    exit 1
}

FRONTEND_NGINX_LISTENERS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=123,fd=6))'
export FRONTEND_NGINX_LISTENERS
backend_one=$(jq -r '.bindings[] | select(.node_ref == "existing-node.json") | .backend_port' "$is_core_dir/frontend.json")
backend_two=$(jq -r '.bindings[] | select(.node_ref == "unselected-node.json") | .backend_port' "$is_core_dir/frontend.json")
[[ $backend_one != "$backend_two" ]] || {
    echo 'FAIL: migrated nodes must receive different backend ports'
    exit 1
}
legacy_share=$(is_dont_auto_exit= main info existing-node.json 2>&1)
[[ $legacy_share == *'node.example:443'* && $legacy_share == *'sni=legacy.example'* && $legacy_share != *":$backend_one"* && $legacy_share != *'127.0.0.1'* ]] || {
    echo "FAIL: migrated node sharing should retain its published host on port 443: $legacy_share"
    exit 1
}

collision_port=$(jq -r '[.bindings[].backend_port] | max + 1' "$is_core_dir/frontend.json")
collision_tag="vless-reality-front-$collision_port.json"
jq -n --arg tag "$collision_tag" '{inbounds:[{tag:$tag,type:"vless",listen:"::",listen_port:9999,users:[{uuid:"cccccccc-cccc-4ccc-8ccc-cccccccccccc"}]}]}' >"$is_conf_dir/tag-conflict.json"

first_add=$(main add reality 443 33333333-3333-4333-8333-333333333333 first.example 2>&1) || {
    echo "FAIL: add should create a public-443 Reality node: $first_add"
    exit 1
}
second_add=$(main add reality 443 44444444-4444-4444-8444-444444444444 second.example 2>&1) || {
    echo "FAIL: add should create a second public-443 Reality node: $second_add"
    exit 1
}
jq -e '.bindings | length == 4 and ([.[].backend_port] | unique | length == 4)' "$is_core_dir/frontend.json" >/dev/null || {
    echo 'FAIL: every binding should have a distinct backend port'
    exit 1
}
new_one=$(jq -r '[.bindings[].node_ref | select(startswith("vless-reality-front-"))][0]' "$is_core_dir/frontend.json")
new_two=$(jq -r '[.bindings[].node_ref | select(startswith("vless-reality-front-"))][1]' "$is_core_dir/frontend.json")
[[ $new_one && $new_two && $new_one != "$new_two" ]] || {
    echo 'FAIL: new public-443 nodes need distinct frontend filenames'
    exit 1
}
[[ $new_one != "$collision_tag" ]] || {
    echo 'FAIL: a new public-443 node reused a tag already present in another node'
    exit 1
}
for node_ref in "$new_one" "$new_two"; do
    node_backend=$(jq -r --arg ref "$node_ref" '.bindings[] | select(.node_ref == $ref) | .backend_port' "$is_core_dir/frontend.json")
    [[ $node_ref == "vless-reality-front-$node_backend.json" ]] || {
        echo "FAIL: generated public node filenames should include their assigned backend port: $node_ref"
        exit 1
    }
    jq -e --arg tag "$node_ref" '.inbounds[0].tag == $tag and .inbounds[0].listen == "127.0.0.1" and .inbounds[0].listen_port >= 49152 and .inbounds[0].tls.reality.enabled == true and (.inbounds[0] | has("transport") | not)' "$is_conf_dir/$node_ref" >/dev/null || {
        echo "FAIL: new nodes should have unique tags and ordinary Reality backends: $node_ref"
        exit 1
    }
done
map_file=$(jq -r '.ownership.map_file' "$is_core_dir/frontend.json")
grep -Fq 'first.example 127.0.0.1:' "$map_file" && grep -Fq 'second.example 127.0.0.1:' "$map_file" || {
    echo 'FAIL: the Nginx map should include both new SNI routes'
    exit 1
}

profile_before=$(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}')
map_before=$(sha256sum "$map_file" | awk '{print $1}')
config_before=$(sha256sum "$is_config_json" | awk '{print $1}')
reloads_before=$(cat "$FRONTEND_RELOAD_COUNT_FILE")
rh2_error=$(main add rh2 443 88888888-8888-4888-8888-888888888888 rh2.example 2>&1) && {
    echo 'FAIL: rh2 must remain unsupported by the ordinary Reality frontend'
    exit 1
}
[[ $(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}') == "$profile_before" && $(sha256sum "$map_file" | awk '{print $1}') == "$map_before" && $(sha256sum "$is_config_json" | awk '{print $1}') == "$config_before" && $(cat "$FRONTEND_RELOAD_COUNT_FILE") == "$reloads_before" ]] || {
    echo "FAIL: rejected rh2 changed frontend or shared config state: $rh2_error"
    exit 1
}

profile_before=$(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}')
map_before=$(sha256sum "$map_file" | awk '{print $1}')
reloads_before=$(cat "$FRONTEND_RELOAD_COUNT_FILE")
duplicate_error=$(main add reality 443 55555555-5555-4555-8555-555555555555 FIRST.EXAMPLE 2>&1) && {
    echo 'FAIL: SNI duplicate checks should ignore ASCII case'
    exit 1
}
invalid_error=$(main add reality 443 66666666-6666-4666-8666-666666666666 bad_name.example 2>&1) && {
    echo 'FAIL: invalid ASCII SNI should be rejected'
    exit 1
}
[[ $(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}') == "$profile_before" && $(sha256sum "$map_file" | awk '{print $1}') == "$map_before" && $(cat "$FRONTEND_RELOAD_COUNT_FILE") == "$reloads_before" ]] || {
    echo 'FAIL: rejected SNI changed profile, map, or Nginx reload count'
    exit 1
}

share_port=$(jq -r --arg ref "$new_one" '.bindings[] | select(.node_ref == $ref) | .backend_port' "$is_core_dir/frontend.json")
for output_kind in info url qr; do
    share_output=$(is_dont_auto_exit= main "$output_kind" "$new_one" 2>&1) || {
        echo "FAIL: $output_kind should work for a bound node"
        exit 1
    }
    [[ $share_output == *':443'* && $share_output == *'sni=first.example'* && $share_output != *":$share_port"* && $share_output != *'127.0.0.1'* ]] || {
        echo "FAIL: $output_kind leaked a backend or omitted the public endpoint: $share_output"
        exit 1
    }
done

bound_backend=$(jq -r --arg ref "$new_one" '.bindings[] | select(.node_ref == $ref) | .backend_port' "$is_core_dir/frontend.json")
bound_revision=$(jq -r '.revision' "$is_core_dir/frontend.json")
bound_reloads=$(cat "$FRONTEND_RELOAD_COUNT_FILE")
sni_edit=$(main change "$new_one" sni changed.example 2>&1) || {
    echo "FAIL: changing a bound node SNI should use the frontend coordinator: $sni_edit"
    exit 1
}
jq -e --arg sni changed.example --argjson backend "$bound_backend" '.inbounds[0].listen == "127.0.0.1" and .inbounds[0].listen_port == $backend and .inbounds[0].tls.server_name == $sni and .inbounds[0].tls.reality.handshake.server == $sni' "$is_conf_dir/$new_one" >/dev/null || {
    echo "FAIL: bound SNI edit changed the node outside its saved loopback binding: $(cat "$is_conf_dir/$new_one") output=$sni_edit"
    exit 1
}
[[ $(jq -r '.revision' "$is_core_dir/frontend.json") == $((bound_revision + 1)) && $(jq -r --arg ref "$new_one" '.bindings[] | select(.node_ref == $ref) | .backend_port' "$is_core_dir/frontend.json") == "$bound_backend" ]] || {
    echo 'FAIL: bound SNI edit should preserve its backend and commit the next profile revision'
    exit 1
}
map_file=$(jq -r '.ownership.map_file' "$is_core_dir/frontend.json")
grep -Fq "changed.example 127.0.0.1:$bound_backend;" "$map_file" && ! grep -Fq 'first.example ' "$map_file" || {
    echo "FAIL: bound SNI edit did not update the managed map: $(cat "$map_file")"
    exit 1
}
sni_share=$(is_dont_auto_exit= main info "$new_one" 2>&1)
[[ $sni_share == *':443'* && $sni_share == *'sni=changed.example'* && $sni_share != *":$bound_backend"* ]] || {
    echo "FAIL: bound SNI edit did not update its public share output: $sni_share"
    exit 1
}
[[ $(cat "$FRONTEND_RELOAD_COUNT_FILE") == $((bound_reloads + 1)) ]] || {
    echo 'FAIL: a changed SNI map should reload Nginx exactly once'
    exit 1
}

bound_revision=$(jq -r '.revision' "$is_core_dir/frontend.json")
bound_reloads=$(cat "$FRONTEND_RELOAD_COUNT_FILE")
entry_node_before=$(sha256sum "$is_conf_dir/$new_one" | awk '{print $1}')
entry_edit=$(main change "$new_one" entry edge.example 2>&1) || {
    echo "FAIL: changing a bound node entry address should use the frontend coordinator: $entry_edit"
    exit 1
}
jq -e --argjson backend "$bound_backend" '.inbounds[0].listen == "127.0.0.1" and .inbounds[0].listen_port == $backend' "$is_conf_dir/$new_one" >/dev/null || {
    echo 'FAIL: bound entry-address change must preserve the loopback listen'
    exit 1
}
entry_share=$(is_dont_auto_exit= main info "$new_one" 2>&1)
[[ $entry_share == *'edge.example:443'* && $entry_share == *'sni=changed.example'* && $(sha256sum "$is_conf_dir/$new_one" | awk '{print $1}') == "$entry_node_before" && $(jq -r '.revision' "$is_core_dir/frontend.json") == "$bound_revision" && $(cat "$FRONTEND_RELOAD_COUNT_FILE") == "$bound_reloads" ]] || {
    echo "FAIL: entry-address edit should update only published share data: $entry_share"
    exit 1
}

name_edit=$(main change "$new_one" name EditedBoundNode 2>&1) || {
    echo "FAIL: renaming a bound node should use the frontend coordinator: $name_edit"
    exit 1
}
name_share=$(is_dont_auto_exit= main url "$new_one" 2>&1)
[[ $(meta_get "$new_one" '.node_name') == EditedBoundNode && $name_share == *'#EditedBoundNode'* ]] || {
    echo "FAIL: bound node name should update its metadata and generated share: $name_share"
    exit 1
}

new_uuid=99999999-1111-4111-8111-111111111111
uuid_edit=$(main change "$new_one" uuid "$new_uuid" 2>&1) || {
    echo "FAIL: rebuilding a bound node UUID should use the frontend coordinator: $uuid_edit"
    exit 1
}
jq -e --arg uuid "$new_uuid" --argjson backend "$bound_backend" '.inbounds[0].listen == "127.0.0.1" and .inbounds[0].listen_port == $backend and .inbounds[0].users[0].uuid == $uuid' "$is_conf_dir/$new_one" >/dev/null || {
    echo "FAIL: bound node UUID rebuild lost its loopback binding: $(cat "$is_conf_dir/$new_one")"
    exit 1
}

outbound_edit=$(printf '1\n' | main change "$new_one" outbound 2>&1) || {
    echo "FAIL: editing a bound node outbound mode should use the frontend coordinator: $outbound_edit"
    exit 1
}
jq -e '.outbound_mode == "V6优先"' "$(meta_file "$new_one")" >/dev/null && jq -e --arg tag "$new_one" 'any(.route.rules[]?; any(.inbound[]?; . == $tag) and .outbound == "direct_v6_pref")' "$is_config_json" >/dev/null || {
    echo "FAIL: bound outbound edit did not update the metadata and derived shared route: $(cat "$(meta_file "$new_one")")"
    exit 1
}
[[ $(jq -r '.revision' "$is_core_dir/frontend.json") == "$bound_revision" && $(cat "$FRONTEND_RELOAD_COUNT_FILE") == "$bound_reloads" ]] || {
    echo 'FAIL: bound name, UUID, and outbound edits changed the SNI profile or reloaded Nginx'
    exit 1
}

same_sni_revision=$(jq -r '.revision' "$is_core_dir/frontend.json")
same_sni_reloads=$(cat "$FRONTEND_RELOAD_COUNT_FILE")
same_sni=$(main change "$new_one" sni changed.example 2>&1) || {
    echo "FAIL: bound SNI self-check rejected the node's current SNI: $same_sni"
    exit 1
}
[[ $(jq -r '.revision' "$is_core_dir/frontend.json") == "$same_sni_revision" && $(cat "$FRONTEND_RELOAD_COUNT_FILE") == "$same_sni_reloads" ]] || {
    echo 'FAIL: repeating the current SNI should not change the profile or reload Nginx'
    exit 1
}
duplicate_edit=$(main change "$new_one" sni SECOND.EXAMPLE 2>&1) && {
    echo 'FAIL: changing a bound node to another bound node SNI should be rejected'
    exit 1
}
[[ $duplicate_edit == *'SNI 已绑定'* ]] || {
    echo "FAIL: duplicate bound SNI error should explain the conflict: $duplicate_edit"
    exit 1
}
unsupported_before=$(sha256sum "$is_conf_dir/$new_one" "$is_config_json" "$map_file" "$is_core_dir/frontend.json" | sha256sum | awk '{print $1}')
auto_sni_error=$(main change "$new_one" sni auto 2>&1) && {
    echo 'FAIL: bound nodes must reject automatic SNI selection'
    exit 1
}
transport_error=$(main change "$new_one" new VLESS-HTTP2-REALITY 2>&1) && {
    echo 'FAIL: a bound ordinary Reality node must reject transport changes before moving off 443'
    exit 1
}
[[ $auto_sni_error == *'不支持自动选择 SNI'* && $transport_error == *'请先将节点移出公网 443'* && $(sha256sum "$is_conf_dir/$new_one" "$is_config_json" "$map_file" "$is_core_dir/frontend.json" | sha256sum | awk '{print $1}') == "$unsupported_before" ]] || {
    echo "FAIL: unsupported bound-node edits should fail closed without source changes: auto=$auto_sni_error transport=$transport_error"
    exit 1
}

map_file=$(jq -r '.ownership.map_file' "$is_core_dir/frontend.json")
candidate_before=$(sha256sum "$is_conf_dir/$new_one" "$is_config_json" "$map_file" "$is_core_dir/frontend.json" | sha256sum | awk '{print $1}')
candidate_reloads=$(cat "$FRONTEND_RELOAD_COUNT_FILE")
FRONTEND_FAIL_NGINX_CHECK=1
export FRONTEND_FAIL_NGINX_CHECK
candidate_rejected=$(main change "$new_one" sni candidate-fail.example 2>&1) && {
    echo 'FAIL: Nginx candidate failure should reject a bound-node SNI edit'
    exit 1
}
FRONTEND_FAIL_NGINX_CHECK=0
export FRONTEND_FAIL_NGINX_CHECK
[[ $(sha256sum "$is_conf_dir/$new_one" "$is_config_json" "$map_file" "$is_core_dir/frontend.json" | sha256sum | awk '{print $1}') == "$candidate_before" && $(cat "$FRONTEND_RELOAD_COUNT_FILE") == "$candidate_reloads" ]] || {
    echo "FAIL: rejected candidate changed source files or reloaded Nginx: $candidate_rejected"
    exit 1
}

reload_before=$(cat "$FRONTEND_RELOAD_COUNT_FILE")
FRONTEND_FAIL_RELOAD_AT=$((reload_before + 1))
export FRONTEND_FAIL_RELOAD_AT
reload_rejected=$(main change "$new_one" sni reload-fail.example 2>&1) && {
    echo 'FAIL: a failed Nginx reload should roll back a bound-node SNI edit'
    exit 1
}
FRONTEND_FAIL_RELOAD_AT=0
export FRONTEND_FAIL_RELOAD_AT
[[ $(cat "$FRONTEND_RELOAD_COUNT_FILE") == $((reload_before + 2)) && $(jq -r '.phase' "$is_core_dir/.frontend-state/transaction.json") == rolled_back && $(jq -r '.inbounds[0].tls.server_name' "$is_conf_dir/$new_one") == changed.example && $(grep -Fxc "changed.example 127.0.0.1:$bound_backend;" "$map_file") == 1 ]] || {
    echo "FAIL: reload failure did not restore the pre-edit node and map: $reload_rejected"
    exit 1
}

node_before_interrupt=$(sha256sum "$is_conf_dir/$new_one" "$is_config_json" "$map_file" "$is_core_dir/frontend.json" | sha256sum | awk '{print $1}')
reload_before_interrupt=$(cat "$FRONTEND_RELOAD_COUNT_FILE")
rm -f "$FRONTEND_RELEASE_FILE" "$FRONTEND_PAUSE_FILE" "$FRONTEND_PAUSE_PID_FILE"
FRONTEND_PAUSE_RELOAD_AT=$((reload_before_interrupt + 1))
export FRONTEND_PAUSE_RELOAD_AT
main change "$new_one" sni interrupted.example >"$CASE_DIR/interrupted-node-edit.log" 2>&1 &
edit_pid=$!
for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -e $FRONTEND_PAUSE_FILE ]] && break
    /bin/sleep 0.02
done
[[ -e $FRONTEND_PAUSE_FILE && -s $FRONTEND_PAUSE_PID_FILE ]] || {
    echo 'FAIL: bound-node edit did not reach its persisted transaction reload seam'
    kill "$edit_pid" 2>/dev/null || :
    exit 1
}
reload_pid=$(cat "$FRONTEND_PAUSE_PID_FILE")
kill -KILL "$edit_pid" "$reload_pid" 2>/dev/null || :
wait "$edit_pid" 2>/dev/null || :
: >"$FRONTEND_RELEASE_FILE"
FRONTEND_PAUSE_RELOAD_AT=0
export FRONTEND_PAUSE_RELOAD_AT
for ((attempt = 0; attempt < 100; attempt++)); do
    flock -n "$is_core_dir/.frontend-state/lock" -c true 2>/dev/null && break
    /bin/sleep 0.02
done
flock -n "$is_core_dir/.frontend-state/lock" -c true 2>/dev/null || {
    echo 'FAIL: interrupted bound-node edit did not release its transaction lock'
    exit 1
}
node_recovery=$(main frontend recover 2>&1) || {
    echo "FAIL: recover should roll back an interrupted bound-node edit: $node_recovery"
    exit 1
}
[[ $(sha256sum "$is_conf_dir/$new_one" "$is_config_json" "$map_file" "$is_core_dir/frontend.json" | sha256sum | awk '{print $1}') == "$node_before_interrupt" && $(jq -r '.phase' "$is_core_dir/.frontend-state/transaction.json") == rolled_back && $(cat "$FRONTEND_RELOAD_COUNT_FILE") == $((reload_before_interrupt + 2)) ]] || {
    echo "FAIL: recovery did not restore the interrupted bound-node edit: $node_recovery"
    exit 1
}

off_port=8449
port_out=$(main change "$new_one" port "$off_port" 2>&1) || {
    echo "FAIL: moving a bound node off 443 should use the frontend coordinator: $port_out"
    exit 1
}
off_ref=VLESS-REALITY-$off_port.json
[[ -f $is_conf_dir/$off_ref && ! -e $is_conf_dir/$new_one ]] || {
    echo "FAIL: moving off 443 should rename the node to its ordinary port reference: $off_ref"
    exit 1
}
jq -e --argjson port "$off_port" '.inbounds[0].listen == "::" and .inbounds[0].listen_port == $port' "$is_conf_dir/$off_ref" >/dev/null || {
    echo "FAIL: moving off 443 should restore the requested ordinary listen: $(cat "$is_conf_dir/$off_ref")"
    exit 1
}
! jq -e --arg ref "$new_one" 'any(.bindings[]; .node_ref == $ref)' "$is_core_dir/frontend.json" >/dev/null || {
    echo 'FAIL: moving off 443 should remove the managed binding'
    exit 1
}
! grep -Fq 'changed.example ' "$map_file" || {
    echo 'FAIL: moving off 443 should remove the node SNI from the managed map'
    exit 1
}
off_share=$(is_dont_auto_exit= main info "$off_ref" 2>&1)
[[ $off_share == *"edge.example:$off_port"* && $off_share != *'127.0.0.1'* ]] || {
    echo "FAIL: moving off 443 should restore the public ordinary share: $off_share"
    exit 1
}

reenter_out=$(main change "$off_ref" port 443 reenter.example 2>&1) || {
    echo "FAIL: explicitly naming an SNI should allow moving an ordinary node onto the frontend: $reenter_out"
    exit 1
}
reenter_ref=$(jq -r '.bindings[-1].node_ref' "$is_core_dir/frontend.json")
reenter_backend=$(jq -r --arg ref "$reenter_ref" '.bindings[] | select(.node_ref == $ref) | .backend_port' "$is_core_dir/frontend.json")
[[ $reenter_backend && -f $is_conf_dir/$reenter_ref && ! -e $is_conf_dir/$off_ref ]] || {
    echo 'FAIL: moving onto 443 should convert the node to a managed reference and backend'
    exit 1
}
jq -e --argjson backend "$reenter_backend" '.inbounds[0].listen == "127.0.0.1" and .inbounds[0].listen_port == $backend and .inbounds[0].tls.server_name == "reenter.example"' "$is_conf_dir/$reenter_ref" >/dev/null || {
    echo "FAIL: moving onto 443 should bind the candidate to a loopback backend: $(cat "$is_conf_dir/$reenter_ref")"
    exit 1
}
reenter_share=$(is_dont_auto_exit= main info "$reenter_ref" 2>&1)
[[ $reenter_share == *'edge.example:443'* && $reenter_share == *'sni=reenter.example'* ]] || {
    echo "FAIL: moving onto 443 should preserve the public entry address and share: $reenter_share"
    exit 1
}

profile_before=$(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}')
map_before=$(sha256sum "$map_file" | awk '{print $1}')
config_before=$(sha256sum "$FRONTEND_NGINX_CONF" "$is_config_json" | sha256sum | awk '{print $1}')
binding_count_before=$(find "$is_conf_dir" -maxdepth 1 -name 'vless-reality-front-*.json' | wc -l)
count=$(cat "$FRONTEND_RELOAD_COUNT_FILE")
FRONTEND_FAIL_RELOAD_AT=$((count + 1))
export FRONTEND_FAIL_RELOAD_AT
rollback_error=$(main add reality 443 77777777-7777-4777-8777-777777777777 third.example 2>&1) && {
    echo 'FAIL: a failed Nginx reload should fail the node transaction'
    exit 1
}
FRONTEND_FAIL_RELOAD_AT=0
export FRONTEND_FAIL_RELOAD_AT
[[ $(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}') == "$profile_before" && $(sha256sum "$map_file" | awk '{print $1}') == "$map_before" && $(sha256sum "$FRONTEND_NGINX_CONF" "$is_config_json" | sha256sum | awk '{print $1}') == "$config_before" && $(find "$is_conf_dir" -maxdepth 1 -name 'vless-reality-front-*.json' | wc -l) == "$binding_count_before" ]] || {
    echo "FAIL: reload failure left part of a new node committed: $rollback_error"
    exit 1
}
[[ $(tail -n 4 "$FRONTEND_EVENT_LOG" | paste -sd, -) == 'singbox-restart,nginx-reload,nginx-reload,singbox-restart' ]] || {
    echo "FAIL: rollback order did not release the map before restoring sing-box: $(tail -n 4 "$FRONTEND_EVENT_LOG")"
    exit 1
}

profile_before=$(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}')
map_before=$(sha256sum "$map_file" | awk '{print $1}')
reloads_before=$(cat "$FRONTEND_RELOAD_COUNT_FILE")
gen_output=$(main gen reality 443 88888888-8888-4888-8888-888888888888 generated.example 2>&1) || :
[[ $gen_output == *'generated.example'* ]] || {
    echo "FAIL: gen should still render its non-persistent node: $gen_output"
    exit 1
}
[[ $(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}') == "$profile_before" && $(sha256sum "$map_file" | awk '{print $1}') == "$map_before" && $(cat "$FRONTEND_RELOAD_COUNT_FILE") == "$reloads_before" ]] || {
    echo 'FAIL: gen changed frontend profile, map, or reload count'
    exit 1
}

mapfile -t remaining_bound_refs < <(jq -r '.bindings[].node_ref' "$is_core_dir/frontend.json")
((${#remaining_bound_refs[@]} > 0)) || {
    echo 'FAIL: lifecycle scenario should still have managed nodes before deletion coverage'
    exit 1
}
for node_ref in "${remaining_bound_refs[@]}"; do
    is_config_file=
    delete_output=$(main del "$node_ref" 2>&1) || {
        echo "FAIL: deleting a bound node should use the frontend coordinator: $delete_output"
        exit 1
    }
    [[ ! -e "$is_conf_dir/$node_ref" && ! -e "$(meta_file "$node_ref")" ]] || {
        echo "FAIL: bound node deletion left its file or metadata: $node_ref"
        exit 1
    }
    ! jq -e --arg ref "$node_ref" 'any(.bindings[]; .node_ref == $ref)' "$is_core_dir/frontend.json" >/dev/null || {
        echo "FAIL: bound node deletion left a profile reference: $node_ref"
        exit 1
    }
done
jq -e '.enabled == true and .bindings == []' "$is_core_dir/frontend.json" >/dev/null && [[ -f $map_file && ! -s $map_file ]] || {
    echo 'FAIL: deleting the last bound node should leave an enabled empty frontend and empty managed map'
    exit 1
}
jq -e 'all(.route.rules[]?; .outbound != "direct_v6_pref")' "$is_config_json" >/dev/null || {
    echo 'FAIL: deleting bound nodes should remove their derived outbound associations'
    exit 1
}

# A UDP-only 443 service must not count as a TCP frontend listener or prevent
# an empty-mode enable and a subsequent public TCP Reality node.
is_core_dir="$CASE_DIR/udp-sing-box"
is_conf_dir="$is_core_dir/conf"
is_config_json="$is_core_dir/config.json"
rm -rf "$CASE_DIR/one-singbox"
mkdir -p "$is_conf_dir/.quan-meta"
jq -n '{log:{level:"info"},dns:{},outbounds:[{tag:"direct",type:"direct"}]}' >"$is_config_json"
cat >"$is_conf_dir/udp-only.json" <<'NODE'
{"inbounds":[{"type":"direct","tag":"udp-only","listen":"::","listen_port":443,"network":"udp","override_address":"127.0.0.1","override_port":53}]}
NODE
cat >"$is_conf_dir/hysteria2-udp.json" <<'NODE'
{"inbounds":[{"type":"hysteria2","tag":"hysteria2-udp","listen":"::","listen_port":443}]}
NODE
udp_node_before=$(sha256sum "$is_conf_dir/udp-only.json" "$is_conf_dir/hysteria2-udp.json" | sha256sum | awk '{print $1}')
cat >"$FRONTEND_NGINX_CONF" <<'EOF'
events {}
http {}
EOF
FRONTEND_NGINX_LISTENERS=
FRONTEND_UDP_LISTENERS='UNCONN 0 0 0.0.0.0:443 0.0.0.0:* users:(("sing-box",pid=777,fd=7))'
FRONTEND_UDP_LISTENERS_ONLY=1
export FRONTEND_NGINX_LISTENERS FRONTEND_UDP_LISTENERS FRONTEND_UDP_LISTENERS_ONLY
: >"$FRONTEND_EVENT_LOG"
: >"$FRONTEND_LISTENER_FILE"
[[ $(ss -Hlnpu) == *':443'* && -z $(ss -Hlnpt) ]] || {
    echo 'FAIL: UDP fixture must expose only UDP 443 to protocol-specific socket queries'
    exit 1
}
udp_tcp_add_output=$(main add reality 443 13131313-1313-4313-8313-131313131313 udp-direct.example 2>&1) || {
    echo "FAIL: UDP-only 443 must not block a TCP Reality listener when the frontend is disabled: $udp_tcp_add_output"
    exit 1
}
udp_tcp_node_file=$(find "$is_conf_dir" -maxdepth 1 -type f -name '*.json' ! -name udp-only.json -print -quit)
[[ $udp_tcp_node_file ]] && jq -e '.inbounds[0].type == "vless" and .inbounds[0].listen_port == 443' "$udp_tcp_node_file" >/dev/null || {
    echo "FAIL: TCP Reality should keep its ordinary direct listener beside UDP-only port 443: $udp_tcp_add_output"
    exit 1
}
main del "${udp_tcp_node_file##*/}" >/dev/null 2>&1 || {
    echo 'FAIL: temporary direct Reality fixture could not be removed'
    exit 1
}
FRONTEND_UDP_LISTENERS_ONLY=0
FRONTEND_NGINX_LISTENERS='LISTEN 0 511 0.0.0.0:8443 0.0.0.0:* users:(("other-service",pid=321,fd=8))'
export FRONTEND_UDP_LISTENERS_ONLY FRONTEND_NGINX_LISTENERS
tcp_conflict_output=$(main add reality 8443 14141414-1414-4414-8414-141414141414 tcp-conflict.example 2>&1) && {
    echo 'FAIL: an unrelated TCP listener must still block a direct TCP Reality node'
    exit 1
}
[[ $tcp_conflict_output == *'无法使用 (8443) 端口'* ]] || {
    echo "FAIL: TCP listener conflict should be reported: $tcp_conflict_output"
    exit 1
}
FRONTEND_NGINX_LISTENERS=
FRONTEND_UDP_LISTENERS_ONLY=1
FRONTEND_LISTENER_SOURCE_DIR=$CASE_DIR
export FRONTEND_UDP_LISTENERS_ONLY FRONTEND_NGINX_LISTENERS FRONTEND_LISTENER_SOURCE_DIR
udp_enable_output=$(printf '1\n' | main frontend enable 2>&1) || {
    echo "FAIL: UDP-only port 443 must not block an empty TCP frontend: $udp_enable_output"
    exit 1
}
jq -e '.enabled == true and .bindings == []' "$is_core_dir/frontend.json" >/dev/null || {
    echo 'FAIL: UDP-only port 443 should not be treated as a Reality migration candidate'
    exit 1
}
udp_add_output=$(main add reality 443 12121212-1212-4212-8212-121212121212 udp-safe.example 2>&1) || {
    echo "FAIL: UDP-only 443 must not block a TCP Reality frontend node: $udp_add_output"
    exit 1
}
[[ $(sha256sum "$is_conf_dir/udp-only.json" "$is_conf_dir/hysteria2-udp.json" | sha256sum | awk '{print $1}') == "$udp_node_before" ]] || {
    echo 'FAIL: enabling the TCP frontend changed a UDP-only node'
    exit 1
}
[[ $(jq -r '.bindings | length' "$is_core_dir/frontend.json") == 1 ]] || {
    echo 'FAIL: TCP Reality add should create one binding alongside the UDP-only service'
    exit 1
}
FRONTEND_UDP_LISTENERS_ONLY=0
FRONTEND_UDP_LISTENERS=
FRONTEND_LISTENER_SOURCE_DIR=
export FRONTEND_UDP_LISTENERS_ONLY FRONTEND_UDP_LISTENERS FRONTEND_LISTENER_SOURCE_DIR

# Exercise a reused user map through the public add command. The map rules live
# in a static include so scanner provenance must survive the include boundary.
is_core_dir="$CASE_DIR/map-sing-box"
is_conf_dir="$is_core_dir/conf"
is_config_json="$is_core_dir/config.json"
rm -rf "$CASE_DIR/one-singbox"
mkdir -p "$is_conf_dir/.quan-meta" "$CASE_DIR/maps"
jq -n '{log:{level:"info"},dns:{},outbounds:[{tag:"direct",type:"direct"}]}' >"$is_config_json"
cat >"$FRONTEND_NGINX_CONF" <<EOF
events {}
http {}
stream {
    map \$ssl_preread_server_name \$backend {
        default 127.0.0.1:9443;
        include $CASE_DIR/maps/user.conf;
    }
    server {
        listen 0.0.0.0:443;
        ssl_preread on;
        proxy_pass \$backend;
    }
}
EOF
printf 'taken.example 127.0.0.1:9444;\n' >"$CASE_DIR/maps/user.conf"
FRONTEND_NGINX_LISTENERS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("sing-box",pid=777,fd=7))'
export FRONTEND_NGINX_LISTENERS
: >"$FRONTEND_EVENT_LOG"
cat >"$is_conf_dir/migration-conflict.json" <<'NODE'
{"inbounds":[{"type":"vless","listen":"::","listen_port":443,"users":[{"uuid":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"taken.example","reality":{"enabled":true,"handshake":{"server":"taken.example","server_port":443},"private_key":"legacy-private","short_id":["abcd"]}}}]}
NODE
migration_before=$(sha256sum "$is_conf_dir/migration-conflict.json" "$is_config_json" | sha256sum | awk '{print $1}')
migration_map_error=$(main frontend enable migration-conflict.json 2>&1) && {
    echo 'FAIL: first-enable migration should reject an SNI already present in the reused user map'
    exit 1
}
[[ $migration_map_error == *"$CASE_DIR/maps/user.conf:1"* && $(sha256sum "$is_conf_dir/migration-conflict.json" "$is_config_json" | sha256sum | awk '{print $1}') == "$migration_before" && ! -s "$FRONTEND_EVENT_LOG" ]] || {
    echo "FAIL: migration map conflict should identify its file and line without changing node/config files or services: $migration_map_error"
    exit 1
}
rm -f "$is_conf_dir/migration-conflict.json"
cat >"$is_conf_dir/map-migration.json" <<'NODE'
{"inbounds":[{"type":"vless","tag":"map-legacy-tag","listen":"::","listen_port":443,"users":[{"uuid":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"migrated.example","reality":{"enabled":true,"handshake":{"server":"migrated.example","server_port":443},"private_key":"legacy-private","short_id":["abcd"]}}}]}
NODE
map_migration_output=$(main frontend enable map-migration.json 2>&1) || {
    echo "FAIL: first-enable migration should release sing-box before enabling an existing map listener: $map_migration_output"
    exit 1
}
jq -e '.enabled == true and (.bindings | length == 1) and .bindings[0].node_ref == "map-migration.json"' "$is_core_dir/frontend.json" >/dev/null || {
    echo 'FAIL: existing-map migration should bind the explicitly selected node'
    exit 1
}
[[ $(sed -n '1p' "$FRONTEND_EVENT_LOG") == singbox-restart && $(sed -n '2p' "$FRONTEND_EVENT_LOG") == nginx-reload ]] || {
    echo "FAIL: existing-map migration should release sing-box before reloading Nginx: $(cat "$FRONTEND_EVENT_LOG")"
    exit 1
}
FRONTEND_NGINX_LISTENERS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=123,fd=6))'
export FRONTEND_NGINX_LISTENERS
exact_path="$CASE_DIR/maps/user.conf:1"
map_reloads_before=$(cat "$FRONTEND_RELOAD_COUNT_FILE")
exact_error=$(main add reality 443 99999999-9999-4999-8999-999999999999 TAKEN.EXAMPLE 2>&1) && {
    echo "FAIL: public add should reject an SNI already present in the reused user map: $exact_error"
    exit 1
}
[[ $exact_error == *"$exact_path"* && $(cat "$FRONTEND_RELOAD_COUNT_FILE") == "$map_reloads_before" ]] || {
    echo "FAIL: exact map conflict should include its file and line without reloading Nginx: $exact_error"
    exit 1
}

# Legacy Caddy TLS creation must not take the TCP 443 reservation while the
# Nginx frontend is enabled, and both rejected and successful Caddy paths
# must release the shared lock.
is_caddy=1
is_caddy_dir="$CASE_DIR/caddy"
is_caddyfile="$is_caddy_dir/Caddyfile"
is_caddy_conf="$is_caddy_dir/conf.d"
mkdir -p "$is_caddy_dir"
is_https_port=443
is_no_auto_tls=
is_dont_test_host=1
is_install_caddy=
caddy_node_files_before=$(find "$is_conf_dir" -maxdepth 1 -type f -name '*.json' -printf '%f\n' | sort)
caddy_add_error=$(main add wss reserved.example 66666666-6666-4666-8666-666666666666 /ws 2>&1) && {
    echo 'FAIL: Caddy-backed node add must reject the Nginx-reserved TCP 443 before writing a node'
    exit 1
}
[[ $caddy_add_error == *'TCP 443 is reserved by the enabled Nginx Reality frontend'* && $(find "$is_conf_dir" -maxdepth 1 -type f -name '*.json' -printf '%f\n' | sort) == "$caddy_node_files_before" ]] || {
    echo "FAIL: reserved Caddy add must fail before changing node files: $caddy_add_error"
    exit 1
}
caddy_create_error=$(create caddy ws 2>&1) && {
    echo 'FAIL: direct Caddy creation must reject the Nginx-reserved TCP 443'
    exit 1
}
[[ $caddy_create_error == *'TCP 443 is reserved by the enabled Nginx Reality frontend'* ]] || {
    echo "FAIL: direct Caddy creation should explain the reserved port: $caddy_create_error"
    exit 1
}
flock -n "$is_core_dir/.frontend-state/lock" -c true 2>/dev/null || {
    echo 'FAIL: rejected Caddy paths did not release the shared frontend lock'
    exit 1
}
host=custom-caddy.example
is_https_port=8443
custom_caddy_output=$(manage() { :; }; create caddy ws 2>&1) || {
    echo "FAIL: Caddy creation on a non-reserved HTTPS port should succeed: $custom_caddy_output"
    exit 1
}
[[ -f $is_caddy_conf/custom-caddy.example.conf ]] && grep -Fq 'custom-caddy.example:8443' "$is_caddy_conf/custom-caddy.example.conf" && flock -n "$is_core_dir/.frontend-state/lock" -c true 2>/dev/null || {
    echo 'FAIL: successful Caddy creation should write its site and release the shared frontend lock'
    exit 1
}
is_https_port=
is_caddy=
is_dont_test_host=

map_case=0
for map_rules in \
    $'hostnames;\n*.wild.example 127.0.0.1:9444;' \
    '*.wild.example 127.0.0.1:9444;' \
    '.wild.example 127.0.0.1:9444;' \
    $'~^regex\\.example$ 127.0.0.1:9444;'; do
    map_case=$((map_case + 1))
    printf '%s\n' "$map_rules" >"$CASE_DIR/maps/user.conf"
    disjoint_output=$(main add reality 443 "88888888-0000-4888-8888-00000000000$map_case" "safe-$map_case.example" 2>&1) || {
        echo "FAIL: provably disjoint user map rule should allow an SNI (case $map_case): $disjoint_output"
        exit 1
    }
done

for map_rules in \
    '*.wild.example 127.0.0.1:9444;' \
    '.wild.example 127.0.0.1:9444;' \
    $'~^regex\\.example$ 127.0.0.1:9444;' \
    $'~*^regex\\.example$ 127.0.0.1:9444;'; do
    case $map_rules in
    '*.wild.example'*) matching_sni=sub.wild.example ;;
    '.wild.example'*) matching_sni=wild.example ;;
    '~*'*) matching_sni=REGEX.example ;;
    *) matching_sni=regex.example ;;
    esac
    printf '%s\n' "$map_rules" >"$CASE_DIR/maps/user.conf"
    matching_error=$(main add reality 443 99999999-0000-4999-8999-000000000001 "$matching_sni" 2>&1) && {
        echo "FAIL: user map rule that matches an SNI should reject it ($map_rules)"
        exit 1
    }
    [[ $matching_error == *"$CASE_DIR/maps/user.conf:1"* ]] || {
        echo "FAIL: matching map rule should identify its source line: $matching_error"
        exit 1
    }
done

printf '%s\n' $'~^regex[0-9]+\\.example$ 127.0.0.1:9444;' >"$CASE_DIR/maps/user.conf"
unprovable_error=$(main add reality 443 99999999-0000-4999-8999-000000000002 unprovable.example 2>&1) && {
    echo 'FAIL: unsupported PCRE syntax must remain fail-closed'
    exit 1
}
[[ $unprovable_error == *"$CASE_DIR/maps/user.conf:1"* && $unprovable_error == *'无法确认该 SNI'* ]] || {
    echo "FAIL: unprovable PCRE overlap should identify its source line: $unprovable_error"
    exit 1
}

# If the applied frontend cannot be reloaded back, recovery must leave the
# loopback backend candidate in place and must not restart sing-box again.
is_core_dir="$CASE_DIR/rollback-sing-box"
is_conf_dir="$is_core_dir/conf"
is_config_json="$is_core_dir/config.json"
rm -rf "$CASE_DIR/one-singbox"
mkdir -p "$is_conf_dir/.quan-meta"
jq -n '{log:{level:"info"},dns:{},outbounds:[{tag:"direct",type:"direct"}]}' >"$is_config_json"
cat >"$FRONTEND_NGINX_CONF" <<'EOF'
events {}
stream {
}
http {}
EOF
: >"$FRONTEND_EVENT_LOG"
FRONTEND_NGINX_LISTENERS=
export FRONTEND_NGINX_LISTENERS
: >"$FRONTEND_LISTENER_FILE"
enable_rollback_output=$(printf '1\n' | main frontend enable 2>&1) || {
    echo "FAIL: rollback test frontend setup should succeed: $enable_rollback_output"
    exit 1
}
FRONTEND_NGINX_LISTENERS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=123,fd=6))'
export FRONTEND_NGINX_LISTENERS
reload_count=$(cat "$FRONTEND_RELOAD_COUNT_FILE")
FRONTEND_FAIL_RELOAD_AT="$((reload_count + 1)),$((reload_count + 2))"
export FRONTEND_FAIL_RELOAD_AT
recovery_error=$(main add reality 443 aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa recover.example 2>&1) && {
    echo 'FAIL: add should report recovery_required when Nginx rollback cannot be confirmed'
    exit 1
}
FRONTEND_FAIL_RELOAD_AT=0
export FRONTEND_FAIL_RELOAD_AT
jq -e '.phase == "recovery_required"' "$is_core_dir/.frontend-state/transaction.json" >/dev/null || {
    echo "FAIL: failed Nginx rollback should persist recovery_required: $recovery_error"
    exit 1
}
[[ $(tail -n 3 "$FRONTEND_EVENT_LOG" | paste -sd, -) == 'singbox-restart,nginx-reload,nginx-reload' ]] || {
    echo "FAIL: sing-box restarted after an unconfirmed Nginx rollback: $(cat "$FRONTEND_EVENT_LOG")"
    exit 1
}
rollback_node=$(find "$is_conf_dir" -maxdepth 1 -name 'vless-reality-front-*.json' -print -quit)
[[ $rollback_node && $(jq -r '.inbounds[0].listen' "$rollback_node") == 127.0.0.1 ]] || {
    echo 'FAIL: recovery_required should keep the safe loopback backend in place'
    exit 1
}
recovery_output=$(main frontend recover 2>&1) || {
    echo "FAIL: a later confirmed Nginx reload should allow joint rollback to finish: $recovery_output"
    exit 1
}
[[ $(tail -n 2 "$FRONTEND_EVENT_LOG" | paste -sd, -) == 'nginx-reload,singbox-restart' ]] || {
    echo "FAIL: recovery must confirm restored Nginx before restarting sing-box: $(cat "$FRONTEND_EVENT_LOG")"
    exit 1
}
jq -e '.phase == "rolled_back" and .nginx_rollback_pending == false and .backend_rollback_pending == false' "$is_core_dir/.frontend-state/transaction.json" >/dev/null || {
    echo 'FAIL: successful recovery should persist rolled_back and clear the Nginx reload marker'
    exit 1
}
[[ ! $(find "$is_conf_dir" -maxdepth 1 -name 'vless-reality-front-*.json' -print -quit) && $(jq -r '.bindings | length' "$is_core_dir/frontend.json") == 0 ]] || {
    echo 'FAIL: successful recovery should remove the uncommitted node and preserve the empty profile'
    exit 1
}

# A restart failure after backend files have been restored must leave a
# journal marker so a later recover still restarts sing-box.
: >"$FRONTEND_EVENT_LOG"
reload_count=$(cat "$FRONTEND_RELOAD_COUNT_FILE")
restart_count=$(cat "$FRONTEND_SINGBOX_RESTART_COUNT_FILE")
FRONTEND_FAIL_RELOAD_AT=$((reload_count + 1))
FRONTEND_FAIL_SINGBOX_RESTART_AT=$((restart_count + 2))
export FRONTEND_FAIL_RELOAD_AT FRONTEND_FAIL_SINGBOX_RESTART_AT
backend_recovery_error=$(main add reality 443 bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb backend-recover.example 2>&1) && {
    echo 'FAIL: a failed sing-box rollback restart should require recovery'
    exit 1
}
FRONTEND_FAIL_RELOAD_AT=0
FRONTEND_FAIL_SINGBOX_RESTART_AT=0
export FRONTEND_FAIL_RELOAD_AT FRONTEND_FAIL_SINGBOX_RESTART_AT
jq -e '.phase == "recovery_required" and .backend_rollback_pending == true and .nginx_rollback_pending == false' "$is_core_dir/.frontend-state/transaction.json" >/dev/null || {
    echo "FAIL: failed backend restart should persist its recovery marker: $backend_recovery_error"
    exit 1
}
[[ ! $(find "$is_conf_dir" -maxdepth 1 -name 'vless-reality-front-*.json' -print -quit) ]] || {
    echo 'FAIL: backend files should already be restored when the rollback restart fails'
    exit 1
}
backend_recovery_output=$(main frontend recover 2>&1) || {
    echo "FAIL: backend recovery marker should cause a later sing-box restart: $backend_recovery_output"
    exit 1
}
[[ $(tail -n 1 "$FRONTEND_EVENT_LOG") == singbox-restart ]] || {
    echo "FAIL: backend recovery did not retry sing-box restart: $(cat "$FRONTEND_EVENT_LOG")"
    exit 1
}
jq -e '.phase == "rolled_back" and .backend_rollback_pending == false and .nginx_rollback_pending == false' "$is_core_dir/.frontend-state/transaction.json" >/dev/null || {
    echo 'FAIL: successful backend recovery should clear both pending markers'
    exit 1
}

# fix-all must hold one shared lock around its complete rebuild loop, while
# nested lifecycle calls remain reentrant, then release it after restart.
fix_all_change_calls=0
printf '{"inbounds":[]}\n' >"$is_conf_dir/fix-all-guard.json"
change() {
    [[ ${frontend_lock_depth:-0} == 1 ]] || {
        echo 'FAIL: fix-all did not hold exactly one outer shared lock across change'
        return 1
    }
    fix_all_change_calls=$((fix_all_change_calls + 1))
}
manage() { [[ $1 == restart && ! $2 ]]; }
main fix-all >/dev/null 2>&1 || {
    echo 'FAIL: fix-all should complete under its shared lock'
    exit 1
}
[[ $fix_all_change_calls -gt 0 && ${frontend_lock_depth:-0} == 0 ]] && flock -n "$is_core_dir/.frontend-state/lock" -c true 2>/dev/null || {
    echo 'FAIL: fix-all should process nodes and release its shared lock after restart'
    exit 1
}
echo 'PASS: explicit migration, public 443 Reality add, user-map conflicts, sharing, and joint rollback'
CASE
    [[ $? == 0 ]] || fail "Reality node bindings failed for $core_file"
done
