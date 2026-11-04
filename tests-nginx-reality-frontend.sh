#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
export REPO_ROOT="$repo_root"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fail() {
    echo "FAIL: $1"
    exit 1
}

for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
    case_dir="$workdir/$(basename "$(dirname "$core_file")")-$(basename "$core_file")"
    mkdir -p "$case_dir/bin" "$case_dir/conf"
    export FRONTEND_SERVICE_LOG="$case_dir/service.log"
    export FRONTEND_NGINX_BIN="$case_dir/bin/nginx"
    export FRONTEND_NGINX_CONF="$case_dir/nginx.conf"
    export FRONTEND_NGINX_PREFIX="$case_dir/prefix"
    export FRONTEND_NGINX_MASTER_PID=123
    export FRONTEND_NGINX_READY=0
    export FRONTEND_NGINX_LISTENERS=
    export FRONTEND_RELOAD_COUNT_FILE="$case_dir/reload-count"
    export FRONTEND_FAIL_FIRST_RELOAD=0
    export FRONTEND_FAIL_RELOAD_AT=0
    export FRONTEND_NO_NEW_WORKER_AT=0
    export FRONTEND_CHANGE_OTHER_WORKER_AT=0
    export FRONTEND_PAUSE_RELOAD_AT=0
    export FRONTEND_PAUSE_FILE="$case_dir/reload-paused"
    export FRONTEND_PAUSE_PID_FILE="$case_dir/reload-pid"
    export FRONTEND_REJECT_STREAM_PROBE=0
    export FRONTEND_REJECT_CANDIDATE=0
    : >"$FRONTEND_SERVICE_LOG"

    cat >"$case_dir/bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FRONTEND_SERVICE_LOG"
case "$*" in
    'is-active --quiet nginx.service') [[ $FRONTEND_NGINX_READY == 1 ]] ;;
    'show -p MainPID --value nginx.service') [[ $FRONTEND_NGINX_READY == 1 ]] && printf '%s\n' "$FRONTEND_NGINX_MASTER_PID" ;;
    'show -p ExecStart --value nginx.service') [[ $FRONTEND_NGINX_READY == 1 ]] && printf '{ path=%s ; argv[]=%s -c %s -p %s ; ignore_errors=no }\n' "$FRONTEND_NGINX_BIN" "$FRONTEND_NGINX_BIN" "$FRONTEND_NGINX_CONF" "$FRONTEND_NGINX_PREFIX" ;;
    'show -p ExecReload --value nginx.service') [[ $FRONTEND_NGINX_READY == 1 ]] && printf '{ path=/bin/kill ; argv[]=/bin/kill -s HUP $MAINPID ; ignore_errors=no }\n' ;;
    'reload nginx.service')
        printf '%s\n' nginx-reload >>"$FRONTEND_EVENT_LOG"
        count=0
        [[ -f $FRONTEND_RELOAD_COUNT_FILE ]] && read -r count <"$FRONTEND_RELOAD_COUNT_FILE"
        count=$((count + 1))
        printf '%s\n' "$count" >"$FRONTEND_RELOAD_COUNT_FILE"
        if [[ $FRONTEND_PAUSE_RELOAD_AT == "$count" ]]; then
            printf '%s\n' "$BASHPID" >"$FRONTEND_PAUSE_PID_FILE"
            : >"$FRONTEND_PAUSE_FILE"
            while [[ ! -e $FRONTEND_RELEASE_FILE ]]; do /bin/sleep 0.02; done
        fi
        [[ $FRONTEND_FAIL_RELOAD_AT != "$count" ]] || exit 1
        [[ $FRONTEND_FAIL_FIRST_RELOAD != 1 || $count != 1 ]]
        ;;
    *) exit 1 ;;
esac
FAKE_SYSTEMCTL
    chmod +x "$case_dir/bin/systemctl"

    cat >"$case_dir/bin/ps" <<'FAKE_PS'
#!/usr/bin/env bash
case "$*" in
    '-o ppid= -p '*)
        pid=${*: -1}
        case $pid in
            900|901) printf '124\n' ;;
            124) printf '1\n' ;;
            "$FRONTEND_NGINX_MASTER_PID") printf '1\n' ;;
            4[0-9][0-9]) printf '%s\n' "$FRONTEND_NGINX_MASTER_PID" ;;
            *) exit 1 ;;
        esac
        ;;
    '-o args= -p '* )
        [[ ${*: -1} == "$FRONTEND_NGINX_MASTER_PID" ]] || exit 1
        printf 'nginx: master process %s -c %s -p %s\n' "$FRONTEND_NGINX_BIN" "$FRONTEND_NGINX_CONF" "$FRONTEND_NGINX_PREFIX"
        ;;
    '-eo pid=,args=')
        count=0
        [[ -f $FRONTEND_RELOAD_COUNT_FILE ]] && read -r count <"$FRONTEND_RELOAD_COUNT_FILE"
        printf '%s nginx: master process %s -c %s -p %s\n' "$FRONTEND_NGINX_MASTER_PID" "$FRONTEND_NGINX_BIN" "$FRONTEND_NGINX_CONF" "$FRONTEND_NGINX_PREFIX"
        other_worker=900
        [[ $FRONTEND_CHANGE_OTHER_WORKER_AT != "$count" ]] || other_worker=901
        printf '%s nginx: worker process\n' "$other_worker"
        worker_count=$count
        [[ $FRONTEND_NO_NEW_WORKER_AT != "$count" ]] || worker_count=$((count - 1))
        printf '%s nginx: worker process\n' "$((456 + worker_count))"
        ;;
    *) exit 2 ;;
esac
FAKE_PS
    chmod +x "$case_dir/bin/ps"

    cat >"$case_dir/bin/readlink" <<'FAKE_READLINK'
#!/usr/bin/env bash
case ${*: -1} in
    /proc/123/exe) printf '%s\n' "$FRONTEND_NGINX_BIN" ;;
    /proc/777/exe) printf '%s\n' "$CASE_DIR/bin/sing-box" ;;
    /proc/[0-9]*/exe) printf '%s\n' "$FRONTEND_NGINX_BIN" ;;
    "$FRONTEND_NGINX_BIN") printf '%s\n' "$FRONTEND_NGINX_BIN" ;;
    *) exec /usr/bin/readlink "$@" ;;
esac
FAKE_READLINK
    chmod +x "$case_dir/bin/readlink"

    cat >"$case_dir/bin/ss" <<'FAKE_SS'
#!/usr/bin/env bash
[[ $* == '-Hlnpt' ]] || exit 2
[[ $FRONTEND_NGINX_LISTENERS ]] && printf '%s\n' "$FRONTEND_NGINX_LISTENERS"
exit 0
FAKE_SS
    chmod +x "$case_dir/bin/ss"

    cat >"$case_dir/bin/ip" <<'FAKE_IP'
#!/usr/bin/env bash
case "${FRONTEND_IP_FIXTURE:-ipv4}:$*" in
    ipv4:'-o -4 addr show scope global') printf '2: eth0 inet 203.0.113.10/24 scope global eth0\n' ;;
    ipv4:'-o -6 addr show scope global') exit 1 ;;
    ipv6:'-o -4 addr show scope global') exit 1 ;;
    ipv6:'-o -6 addr show scope global') printf '2: eth0 inet6 2001:db8::10/64 scope global eth0\n' ;;
    both:'-o -4 addr show scope global') printf '2: eth0 inet 203.0.113.10/24 scope global eth0\n' ;;
    both:'-o -6 addr show scope global') printf '2: eth0 inet6 2001:db8::10/64 scope global eth0\n' ;;
    unknown:'-o -4 addr show scope global' | unknown:'-o -6 addr show scope global') exit 1 ;;
    *) exit 2 ;;
esac
FAKE_IP
    chmod +x "$case_dir/bin/ip"

    cat >"$case_dir/bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 0
FAKE_SLEEP
    chmod +x "$case_dir/bin/sleep"

    cat >"$case_dir/bin/nginx" <<'FAKE_NGINX'
#!/usr/bin/env bash
case " $* " in
    *' -V '*) printf 'nginx version: nginx/1.26.2\nconfigure arguments: --prefix=%s --conf-path=%s --with-stream=dynamic --with-stream_ssl_preread_module=dynamic\n' "$FRONTEND_NGINX_PREFIX" "$FRONTEND_NGINX_CONF" ;;
    *' -t '*)
        config=
        while [[ $# -gt 0 ]]; do case $1 in -c) config=$2; shift 2 ;; *) shift ;; esac; done
        if [[ $FRONTEND_REJECT_STREAM_PROBE == 1 ]] && grep -q 'one_singbox_frontend_probe_' "$config"; then
            printf '%s\n' 'unknown directive "ssl_preread"' >&2
            exit 1
        fi
        if [[ $FRONTEND_REJECT_CANDIDATE == 1 && -f $config ]] && grep -q 'one-singbox-frontend:candidate' "$config"; then
            printf '%s\n' 'synthetic candidate rejection' >&2
            exit 1
        fi
        printf 'nginx: configuration file %s test is successful\n' "$config"
        ;;
    *' -T '*) printf '# configuration file %s:\nevents {}\nhttp {}\n' "$FRONTEND_NGINX_CONF" ;;
    *) exit 2 ;;
esac
FAKE_NGINX
    chmod +x "$case_dir/bin/nginx"
    printf 'events {}\nhttp {}\n' >"$case_dir/nginx.conf"
    mkdir -p "$case_dir/prefix"

    CORE_FILE="$core_file" CASE_DIR="$case_dir" PATH="$case_dir/bin:$PATH" bash <<'CASE'
set -o pipefail
source "$CORE_FILE"
is_core_dir="$CASE_DIR/sing-box"
is_conf_dir="$is_core_dir/conf"
is_config_json="$is_core_dir/config.json"
is_core_bin="$CASE_DIR/bin/sing-box"
is_sh_dir="$REPO_ROOT"
is_dont_auto_exit=1
mkdir -p "$is_conf_dir"

status=$(main frontend status --json 2>&1) || {
    echo "FAIL: frontend status should work without a profile: $status"
    exit 1
}
jq -e '.ok == true and .enabled == false and .revision == 0 and .phase == "idle" and .bindings == [] and .errors == []' <<<"$status" >/dev/null || {
    echo "FAIL: missing profile should be reported as an idle disabled mode: $status"
    exit 1
}
[[ ! -e "$is_core_dir/frontend.json" ]] || {
    echo "FAIL: frontend status created the missing profile"
    exit 1
}
[[ " ${mainmenu[*]} " == *" 443 SNI 前置 "* ]] || {
    echo "FAIL: the main menu should expose the frontend entry"
    exit 1
}
load frontend.sh
frontend_menu_output=$(printf '0\n' | frontend_menu 2>&1)
[[ $frontend_menu_output == *"443 SNI 前置"* && $frontend_menu_output == *"3) 启用 Nginx SNI 分流"* && $frontend_menu_output == *"5) 恢复中断的操作"* && $frontend_menu_output == *"什么时候用"* && $frontend_menu_output == *"什么时候不用"* ]] || {
    echo "FAIL: the frontend submenu should expose enable and recovery actions: $frontend_menu_output"
    exit 1
}
menu_check_output=$(printf '2\n1\n0\n\n0\n' | (frontend_main() { printf '模拟检查结果\n'; return 1; }; frontend_menu) 2>&1)
[[ $menu_check_output == *'---------- 检查 Nginx ----------'*'模拟检查结果'*'按回车返回操作菜单...'*'---------- 操作菜单 ----------'* ]] || {
    echo "FAIL: check result should be separated and remain visible until returning: $menu_check_output"
    exit 1
}
[[ $(printf '%s\n' "$menu_check_output" | grep -c '模拟检查结果') == 2 ]] || {
    echo "FAIL: a failed environment check should allow another check before returning: $menu_check_output"
    exit 1
}
[[ $(printf '%s\n' "$menu_check_output" | grep -c '什么时候用') == 1 ]] || {
    echo "FAIL: frontend introduction should not repeat after each action: $menu_check_output"
    exit 1
}
[[ ! -s "$FRONTEND_SERVICE_LOG" ]] || {
    echo "FAIL: frontend status contacted a service manager"
    cat "$FRONTEND_SERVICE_LOG"
    exit 1
}
mkdir -p "$is_core_dir/.frontend-state"
jq -n '{phase:"frontend_applied"}' >"$is_core_dir/.frontend-state/transaction.json"
pending_status=$(main frontend status --json 2>&1) && {
    echo "FAIL: status must surface a pending transaction even when first enable has not committed a profile"
    exit 1
}
jq -e '.ok == false and .enabled == false and .revision == 0 and .phase == "frontend_applied" and .errors[0].code == "recovery_required"' <<<"$pending_status" >/dev/null || {
    echo "FAIL: missing-profile status should still expose the pending transaction: $pending_status"
    exit 1
}
jq -e '.errors[0].message | contains("前置事务未完成") and contains("frontend recover")' <<<"$pending_status" >/dev/null || {
    echo "FAIL: pending transaction status should use Chinese guidance: $pending_status"
    exit 1
}
pending_human=$(main frontend status 2>&1) && {
    echo 'FAIL: human-readable status should fail while a transaction is pending'
    exit 1
}
[[ $pending_human == *'前置事务未完成'* && $pending_human == *'frontend recover'* ]] || {
    echo "FAIL: human-readable status should explain how to recover: $pending_human"
    exit 1
}
jq -n '{phase:42}' >"$is_core_dir/.frontend-state/transaction.json"
corrupt_status=$(main frontend status --json 2>&1) && {
    echo 'FAIL: status must reject a transaction record with an invalid phase type'
    exit 1
}
jq -e '.errors[0].code == "transaction_corrupt" and (.errors[0].message | contains("前置事务记录"))' <<<"$corrupt_status" >/dev/null || {
    echo "FAIL: corrupt transaction status should use a localized message: $corrupt_status"
    exit 1
}
corrupt_human=$(main frontend status 2>&1) && {
    echo 'FAIL: human-readable status should reject a corrupt transaction record'
    exit 1
}
[[ $corrupt_human == *'前置事务记录'* ]] || {
    echo "FAIL: human-readable corrupt transaction status should be localized: $corrupt_human"
    exit 1
}
jq -n '{phase:"frontend_applied"}' >"$is_core_dir/.frontend-state/transaction.json"
disable_pending=$(main frontend disable 2>&1) && {
    echo "FAIL: disable must not treat a missing profile as idle while a transaction is pending"
    exit 1
}
[[ $disable_pending == *'frontend recover'* && $disable_pending == *'请先运行'* ]] || {
    echo "FAIL: disable should direct the operator to recover the pending transaction: $disable_pending"
    exit 1
}
malicious_txn_dir="$is_core_dir/.frontend-state/txn.test"
protected_file="$CASE_DIR/protected-profile.json"
mkdir -p "$malicious_txn_dir"
printf 'before\n' >"$malicious_txn_dir/before.0"
printf 'after\n' >"$malicious_txn_dir/after.0"
printf 'after\n' >"$protected_file"
before_sha=$(sha256sum "$malicious_txn_dir/before.0" | awk '{print $1}')
after_sha=$(sha256sum "$malicious_txn_dir/after.0" | awk '{print $1}')
jq -n \
    --arg dir "$malicious_txn_dir" \
    --arg target "$protected_file" \
    --arg before "$malicious_txn_dir/before.0" \
    --arg after "$malicious_txn_dir/after.0" \
    --arg before_sha "$before_sha" \
    --arg after_sha "$after_sha" \
    --arg config "$FRONTEND_NGINX_CONF" \
    '{schema_version:1,action:"enable",phase:"frontend_applied",dir:$dir,guards:[],nginx:{config:$config,binary:"/bin/true",prefix:"/tmp",service:"nginx.service",service_kind:"systemd"},files:[{path:$target,role:"profile",before_exists:true,before_sha256:$before_sha,before_file:$before,before_mode:"644",before_owner:"0:0",after_exists:true,after_sha256:$after_sha,after_file:$after,after_mode:"644",after_owner:"0:0"}]}' >"$is_core_dir/.frontend-state/transaction.json"
unsafe_recovery=$(main frontend recover 2>&1) && {
    echo "FAIL: recovery must reject a transaction targeting a file outside its allowed frontend state"
    exit 1
}
[[ $(cat "$protected_file") == after ]] || {
    echo "FAIL: rejected recovery changed a file outside its allowed frontend state"
    exit 1
}
rm -rf "$is_core_dir/.frontend-state"

mkdir -p "$is_core_dir"
jq -n '{schema_version:2,enabled:true,revision:1,engine:"nginx",listen_addresses:[],bindings:[],nginx:{},ownership:{}}' >"$is_core_dir/frontend.json"
invalid_status=$(main frontend status --json 2>&1) && {
    echo "FAIL: status must reject an unknown profile schema"
    exit 1
}
jq -e '.ok == false and .enabled == null and .errors[0].code == "unsupported_schema"' <<<"$invalid_status" >/dev/null || {
    echo "FAIL: unknown profile schema should be reported without treating it as disabled: $invalid_status"
    exit 1
}
jq -e '.errors[0].message | contains("不受支持的 schema_version")' <<<"$invalid_status" >/dev/null || {
    echo "FAIL: invalid profile JSON message should be localized: $invalid_status"
    exit 1
}
invalid_status_human=$(main frontend status 2>&1) && {
    echo 'FAIL: human-readable status should reject an unsupported profile schema'
    exit 1
}
[[ $invalid_status_human == *'不受支持的 schema_version'* ]] || {
    echo "FAIL: invalid profile status should be localized: $invalid_status_human"
    exit 1
}
[[ ! -s "$FRONTEND_SERVICE_LOG" ]] || {
    echo "FAIL: status contacted a service manager while reading a profile"
    cat "$FRONTEND_SERVICE_LOG"
    exit 1
}

jq -n '{schema_version:1,enabled:true,revision:4,engine:"nginx",listen_addresses:["0.0.0.0"],bindings:[],nginx:{config:"/etc/nginx/nginx.conf"},ownership:{}}' >"$is_core_dir/frontend.json"
stopped_status=$(main frontend status --json 2>&1) && {
    echo 'FAIL: enabled status must report a stopped Nginx service as non-OK'
    exit 1
}
jq -e '.ok == false and .enabled == true and .revision == 4 and .errors[0].code == "nginx_unavailable"' <<<"$stopped_status" >/dev/null || {
    echo "FAIL: enabled status should surface the stopped Nginx service: $stopped_status"
    exit 1
}
stopped_human_status=$(main frontend status 2>&1) && {
    echo 'FAIL: enabled text status should fail when Nginx is stopped'
    exit 1
}
[[ $stopped_human_status == *'本机检查：未通过'* ]] || {
    echo "FAIL: stopped enabled status should report the local check failure: $stopped_human_status"
    exit 1
}
[[ $stopped_human_status == *'配置修订号：4'* && $stopped_human_status == *'绑定节点数：0'* ]] || {
    echo "FAIL: human-readable status should localize the revision and binding count labels without changing their values: $stopped_human_status"
    exit 1
}
mkdir -p "$is_core_dir/.frontend-state"
jq -n '{phase:"frontend_applied"}' >"$is_core_dir/.frontend-state/transaction.json"
pending_enabled_human_status=$(main frontend status 2>&1) && {
    echo 'FAIL: enabled text status should fail while a transaction is pending'
    exit 1
}
[[ $pending_enabled_human_status == *'本机检查：未执行（待恢复事务）'* ]] || {
    echo "FAIL: pending enabled status should say the local check was not run: $pending_enabled_human_status"
    exit 1
}
rm -rf "$is_core_dir/.frontend-state"
jq '.enabled = false' "$is_core_dir/frontend.json" >"$is_core_dir/frontend.json.tmp"
mv "$is_core_dir/frontend.json.tmp" "$is_core_dir/frontend.json"
: >"$FRONTEND_SERVICE_LOG"
disabled_status=$(main frontend status --json 2>&1) || {
    echo "FAIL: disabled status should remain available when Nginx is stopped: $disabled_status"
    exit 1
}
jq -e '.ok == true and .enabled == false' <<<"$disabled_status" >/dev/null || {
    echo "FAIL: disabled status should report the saved disabled profile: $disabled_status"
    exit 1
}
disabled_human_status=$(main frontend status 2>&1) || {
    echo "FAIL: disabled text status should remain available when Nginx is stopped: $disabled_human_status"
    exit 1
}
[[ $disabled_human_status == *'本机检查：未执行（前置未启用）'* ]] || {
    echo "FAIL: disabled text status should say the local check was not run: $disabled_human_status"
    exit 1
}
[[ ! -s "$FRONTEND_SERVICE_LOG" ]] || {
    echo 'FAIL: disabled status should not contact the Nginx service manager'
    exit 1
}
jq '.enabled = true' "$is_core_dir/frontend.json" >"$is_core_dir/frontend.json.tmp"
mv "$is_core_dir/frontend.json.tmp" "$is_core_dir/frontend.json"

check_before=$(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}')
check_output=$(main frontend check --json 2>&1) && {
    echo "FAIL: frontend check should fail when the Nginx service is unavailable"
    exit 1
}
jq -e '.ok == false and .errors[0].code == "nginx_unavailable"' <<<"$check_output" >/dev/null || {
    echo "FAIL: check should explain unavailable Nginx: $check_output"
    exit 1
}
check_human=$(main frontend check 2>&1) && {
    echo 'FAIL: human check should fail when Nginx is unavailable'
    exit 1
}
[[ $check_human == *'错误：Nginx 服务未运行'* && $check_human == *'建议：检查 Nginx 是否已安装并运行'* &&
   $check_human == *"https://github.com/ouones/one-singbox/blob/main/docs/nginx-sni-setup.md"* ]] || {
    echo "FAIL: human check failure should include the error, an action, and the Nginx guide: $check_human"
    exit 1
}
[[ $(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}') == "$check_before" ]] || {
    echo "FAIL: frontend check modified the saved profile"
    exit 1
}
[[ ! -e "$is_core_dir/.frontend-state" ]] || {
    echo "FAIL: frontend check created transaction state"
    exit 1
}
enable_check_error=$(main frontend enable 2>&1) && {
    echo 'FAIL: enable should remain blocked while Nginx is unavailable'
    exit 1
}
[[ $enable_check_error == *'错误：Nginx 服务未运行'* && $enable_check_error == *'建议：检查 Nginx 是否已安装并运行'* &&
   $enable_check_error == *"https://github.com/ouones/one-singbox/blob/main/docs/nginx-sni-setup.md"* ]] || {
    echo "FAIL: enable should use the same actionable environment guidance as check: $enable_check_error"
    exit 1
}

FRONTEND_NGINX_READY=1
export FRONTEND_NGINX_READY
jq '.enabled = false' "$is_core_dir/frontend.json" >"$is_core_dir/frontend.json.tmp"
mv "$is_core_dir/frontend.json.tmp" "$is_core_dir/frontend.json"
FRONTEND_REJECT_STREAM_PROBE=1
export FRONTEND_REJECT_STREAM_PROBE
module_error=$(main frontend check --json 2>&1) && {
    echo "FAIL: compiled stream build flags must not count as proof that ssl_preread is loaded"
    exit 1
}
jq -e '.ok == false and .errors[0].code == "nginx_ssl_preread_missing"' <<<"$module_error" >/dev/null || {
    echo "FAIL: missing loaded stream capability should be reported: $module_error"
    exit 1
}
FRONTEND_REJECT_STREAM_PROBE=0
export FRONTEND_REJECT_STREAM_PROBE
check_output=$(main frontend check --json 2>&1) || {
    echo "FAIL: check should accept a running Nginx instance with required modules: $check_output"
    exit 1
}
jq -e --arg binary "$FRONTEND_NGINX_BIN" --arg config "$FRONTEND_NGINX_CONF" '.ok == true and .nginx.binary == $binary and .nginx.config == $config and .nginx.compiled.stream == true and .nginx.modules.stream == true and .nginx.modules.ssl_preread == true' <<<"$check_output" >/dev/null || {
    echo "FAIL: check should report the detected Nginx instance and module capabilities: $check_output"
    exit 1
}
jq -e '.nginx.entry_type == "new_stream"' <<<"$check_output" >/dev/null || {
    echo "FAIL: check should identify a configuration with no stream block: $check_output"
    exit 1
}

mkdir -p "$CASE_DIR/empty-modules"
cat >"$FRONTEND_NGINX_CONF" <<EOF
include $CASE_DIR/empty-modules/*.conf;
events {}
http {}
EOF
empty_include_output=$(main frontend check --json 2>&1) || { echo "FAIL: empty wildcard include should be accepted: $empty_include_output"; exit 1; }
jq -e '.ok == true' <<<"$empty_include_output" >/dev/null || { echo "FAIL: empty wildcard check should pass: $empty_include_output"; exit 1; }
cat >"$FRONTEND_NGINX_CONF" <<EOF
include $CASE_DIR/empty-modules/missing.conf;
events {}
http {}
EOF
missing_include_output=$(main frontend check --json 2>&1) && { echo "FAIL: missing literal include must still be rejected"; exit 1; }
jq -e '.ok == false and .errors[0].code == "nginx_config_unsupported"' <<<"$missing_include_output" >/dev/null || { echo "FAIL: missing literal include should fail: $missing_include_output"; exit 1; }

cat >"$FRONTEND_NGINX_CONF" <<'EOF'
events {}
stream {
}
http {}
EOF
check_output=$(main frontend check --json 2>&1) || {
    echo "FAIL: check should accept an empty stream block: $check_output"
    exit 1
}
jq -e '.nginx.entry_type == "empty_stream"' <<<"$check_output" >/dev/null || {
    echo "FAIL: check should identify an empty stream block: $check_output"
    exit 1
}

mkdir -p "$CASE_DIR/http.d" "$CASE_DIR/stream.d" "$CASE_DIR/maps"
cat >"$FRONTEND_NGINX_CONF" <<EOF
events {}
http { include $CASE_DIR/http.d/*.conf; }
stream { include $CASE_DIR/stream.d/*.conf; }
EOF
cat >"$CASE_DIR/http.d/site.conf" <<'EOF'
server { listen 8443 ssl; }
EOF
cat >"$CASE_DIR/stream.d/reality.conf" <<EOF
map \$ssl_preread_server_name \$backend {
    default 127.0.0.1:9443;
    include $CASE_DIR/maps/*.conf;
}
server {
    listen 0.0.0.0:443;
    ssl_preread on;
    proxy_pass \$backend;
}
EOF
printf 'old.example 127.0.0.1:12345;\n' >"$CASE_DIR/maps/old.conf"
FRONTEND_NGINX_LISTENERS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=123,fd=6))'
export FRONTEND_NGINX_LISTENERS
check_output=$(main frontend check --json 2>&1) || {
    echo "FAIL: check should accept a compatible static include tree: $check_output"
    exit 1
}
jq -e '.nginx.entry_type == "existing_map" and .nginx.map_variable == "$backend"' <<<"$check_output" >/dev/null || {
    echo "FAIL: check should recognize the existing SNI map and proxy listener: $check_output"
    exit 1
}

FRONTEND_NGINX_LISTENERS=$'LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=123,fd=6))\nLISTEN 0 511 [::]:443 [::]:* users:(("nginx",pid=124,fd=7))'
export FRONTEND_NGINX_LISTENERS
disjoint_family_check=$(main frontend check --json 2>&1) || {
    echo "FAIL: an unrelated same-binary listener on a disjoint IPv6 range should not conflict: $disjoint_family_check"
    exit 1
}

FRONTEND_NGINX_LISTENERS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=124,fd=7))'
export FRONTEND_NGINX_LISTENERS
second_instance_check=$(main frontend check --json 2>&1) && {
    echo 'FAIL: a same-binary second Nginx master must not be treated as the selected service owner'
    exit 1
}
jq -e '.errors[0].code == "tcp_443_port_conflict"' <<<"$second_instance_check" >/dev/null || {
    echo "FAIL: a same-binary second master should be reported as a TCP 443 conflict: $second_instance_check"
    exit 1
}

FRONTEND_NGINX_LISTENERS='LISTEN 0 511 [::]:443 [::]:* users:(("nginx",pid=123,fd=6))'
export FRONTEND_NGINX_LISTENERS
wrong_family_check=$(main frontend check --json 2>&1) && {
    echo 'FAIL: an IPv6 socket must not satisfy a configured IPv4 listener'
    exit 1
}
jq -e '.errors[0].code == "nginx_listener_missing"' <<<"$wrong_family_check" >/dev/null || {
    echo "FAIL: a listener on the wrong address family should be reported: $wrong_family_check"
    exit 1
}
cat >"$FRONTEND_NGINX_CONF" <<'EOF'
events {}
stream {
    map $ssl_preread_server_name $backend {
        default 127.0.0.1:9443;
    }
    server {
        listen [2001:0db8:0000:0000:0000:0000:0000:0001]:443;
        ssl_preread on;
        proxy_pass $backend;
    }
}
EOF
FRONTEND_NGINX_LISTENERS='LISTEN 0 511 [2001:db8::1]:443 [::]:* users:(("nginx",pid=123,fd=6))'
export FRONTEND_NGINX_LISTENERS
expanded_ipv6_check=$(main frontend check --json 2>&1) || {
    echo "FAIL: equivalent expanded and compressed IPv6 listener addresses should match: $expanded_ipv6_check"
    exit 1
}
FRONTEND_NGINX_LISTENERS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=123,fd=6))'
export FRONTEND_NGINX_LISTENERS
cat >"$FRONTEND_NGINX_CONF" <<'EOF'
events {}
stream {
    map $ssl_preread_server_name $backend {
        default 127.0.0.1:9443;
    }
    server {
        listen [::]:443;
        ssl_preread on;
        proxy_pass $backend;
    }
}
EOF
FRONTEND_NGINX_LISTENERS=$'LISTEN 0 511 [::]:443 [::]:* users:(("nginx",pid=123,fd=6))\nLISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("other",pid=900,fd=7))'
export FRONTEND_NGINX_LISTENERS
ipv6only_default_check=$(main frontend check --json 2>&1) || {
    echo "FAIL: default ipv6only=on should keep IPv4 sockets disjoint: $ipv6only_default_check"
    exit 1
}

sed -i 's/listen \[::\]:443;/listen [::]:443 ipv6only=off;/' "$FRONTEND_NGINX_CONF"
ipv6only_off_check=$(main frontend check --json 2>&1) && {
    echo 'FAIL: ipv6only=off should make the IPv6 listener overlap IPv4 TCP 443'
    exit 1
}
jq -e '.errors[0].code == "tcp_443_port_conflict"' <<<"$ipv6only_off_check" >/dev/null || {
    echo "FAIL: ipv6only=off overlap should report the IPv4 owner conflict: $ipv6only_off_check"
    exit 1
}

FRONTEND_NGINX_LISTENERS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=123,fd=6))'
export FRONTEND_NGINX_LISTENERS

cat >"$FRONTEND_NGINX_CONF" <<'EOF'
events {}
http { server { listen 443 ssl; } }
EOF
FRONTEND_NGINX_LISTENERS=
export FRONTEND_NGINX_LISTENERS
conflict_output=$(main frontend check --json 2>&1) && {
    echo "FAIL: check must reject an HTTP listener on TCP 443"
    exit 1
}
jq -e '.errors[0].code == "nginx_http_443_conflict"' <<<"$conflict_output" >/dev/null || {
    echo "FAIL: HTTP port conflict should be identified: $conflict_output"
    exit 1
}

cat >"$FRONTEND_NGINX_CONF" <<EOF
include $CASE_DIR/empty-modules/*.conf;
events {}
http { include $CASE_DIR/http.d/site.conf; }
EOF
FRONTEND_NGINX_LISTENERS=
FRONTEND_RELOAD_COUNT_FILE="$CASE_DIR/reload-count"
rm -f "$FRONTEND_RELOAD_COUNT_FILE"
FRONTEND_REJECT_CANDIDATE=1
export FRONTEND_NGINX_LISTENERS FRONTEND_RELOAD_COUNT_FILE FRONTEND_REJECT_CANDIDATE
config_before=$(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}')
profile_before=$(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}')
candidate_error=$(printf '1\n' | main frontend enable 2>&1) && {
    echo "FAIL: a rejected full Nginx candidate must not enable the frontend"
    exit 1
}
[[ $(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}') == "$config_before" && $(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}') == "$profile_before" ]] || {
    echo "FAIL: candidate validation failure changed active config or profile"
    exit 1
}
[[ ! -e "$CASE_DIR/one-singbox/reality-map.conf" && ! -e "$FRONTEND_RELOAD_COUNT_FILE" ]] || {
    echo "FAIL: candidate validation failure wrote project files or reloaded Nginx"
    exit 1
}

run_menu_address_case() {
    local fixture=$1 choice=$2 expected_range=$3 expected_detection=$4 output config_before profile_before
    FRONTEND_IP_FIXTURE=$fixture
    export FRONTEND_IP_FIXTURE
    config_before=$(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}')
    profile_before=$(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}')
    output=$(printf '3\n1\n%s\n\n0\n' "$choice" | frontend_menu 2>&1)
    [[ $output == *"$expected_detection"* && $output == *"$expected_range"* ]] || {
        echo "FAIL: interactive address choice for $fixture should report detection and range $expected_range: $output"
        exit 1
    }
    [[ $output == *'选择影响 Nginx 监听 TCP 443 的地址族'* && $output == *'不能证明公网可达'* && $output == *'未检测到不等于无法使用'* && $output == *'检测到也不等于公网可达'* ]] || {
        echo "FAIL: interactive address choice should explain its effect and local-detection limits: $output"
        exit 1
    }
    [[ $(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}') == "$config_before" && $(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}') == "$profile_before" ]] || {
        echo "FAIL: rejected interactive address choice changed active config or profile for $fixture"
        exit 1
    }
    [[ ! -e "$CASE_DIR/one-singbox/reality-map.conf" && ! -e "$FRONTEND_RELOAD_COUNT_FILE" ]] || {
        echo "FAIL: rejected interactive address choice wrote files or reloaded Nginx for $fixture"
        exit 1
    }
}

run_menu_address_case ipv4 1 '监听范围：0.0.0.0' '本机检测到的全局地址类型：IPv4'
run_menu_address_case ipv6 1 '监听范围：::' '本机检测到的全局地址类型：IPv6'
run_menu_address_case both 3 '监听范围：0.0.0.0,::' '本机检测到的全局地址类型：IPv4、IPv6'
run_menu_address_case unknown 2 '监听范围：::' '无法确定本机是否配置全局 IPv4 或 IPv6 地址'

FRONTEND_IP_FIXTURE=both
export FRONTEND_IP_FIXTURE
cancel_config_before=$(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}')
cancel_profile_before=$(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}')
cancel_output=$(printf '3\n1\n0\n\n0\n' | frontend_menu 2>&1)
[[ $cancel_output == *'0) 取消启用，不修改配置'* && $cancel_output == *'已取消启用，配置未修改'* ]] || {
    echo "FAIL: interactive address choice should expose a clear no-change cancel path: $cancel_output"
    exit 1
}
[[ $(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}') == "$cancel_config_before" && $(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}') == "$cancel_profile_before" ]] || {
    echo "FAIL: cancelling address choice changed active config or profile"
    exit 1
}
[[ ! -e "$CASE_DIR/one-singbox/reality-map.conf" && ! -e "$FRONTEND_RELOAD_COUNT_FILE" ]] || {
    echo "FAIL: cancelling address choice wrote project files or reloaded Nginx"
    exit 1
}

FRONTEND_IP_FIXTURE=unknown
export FRONTEND_IP_FIXTURE
cli_unknown_output=$(printf '1\n' | main frontend enable 2>&1) && {
    echo 'FAIL: the direct CLI should retain its existing failure when no address family is detected'
    exit 1
}
[[ $cli_unknown_output == *'无法确定可用的全局 IPv4 或 IPv6 地址'* && $cli_unknown_output != *'以下选项按服务器实际情况手动选择'* && $cli_unknown_output != *'0) 取消启用，不修改配置'* ]] || {
    echo "FAIL: direct CLI address detection should keep its existing noninteractive behavior: $cli_unknown_output"
    exit 1
}

FRONTEND_REJECT_CANDIDATE=0
export FRONTEND_REJECT_CANDIDATE
cancel_enable=$(printf '3\n0\n\n0\n' | frontend_menu 2>&1) || {
    echo "FAIL: cancelling zero-node enable should return to the menu: $cancel_enable"
    exit 1
}
[[ $cancel_enable == *'候选节点：无'* && $cancel_enable == *'Nginx 实例'* &&
   $cancel_enable == *'短暂中断'* && $cancel_enable == *'仅迁移现有节点时会重启 sing-box 服务'* &&
   $cancel_enable == *'已取消启用'* ]] || {
    echo "FAIL: zero-node enable should show the impact and allow cancellation: $cancel_enable"
    exit 1
}
[[ $(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}') == "$config_before" &&
   $(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}') == "$profile_before" &&
   ! -e "$FRONTEND_RELOAD_COUNT_FILE" ]] || {
    echo 'FAIL: cancelling zero-node enable changed configuration or reloaded Nginx'
    exit 1
}
FRONTEND_IP_FIXTURE=ipv4
export FRONTEND_IP_FIXTURE
enable_output=$(printf '3\n1\n1\n\n0\n' | frontend_menu 2>&1) || {
    echo "FAIL: empty-mode enable on a config without stream should succeed: $enable_output"
    exit 1
}
[[ $enable_output == *'当前没有受管节点'* && $enable_output == *'首页 → 节点管理 → 添加节点'* ]] || {
    echo "FAIL: successful zero-node enable should explain the next step: $enable_output"
    exit 1
}
FRONTEND_NGINX_LISTENERS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=123,fd=6))'
export FRONTEND_NGINX_LISTENERS
cli_idempotent_output=$(main frontend enable 2>&1) || {
    echo "FAIL: noninteractive enable should remain compatible after menu enable: $cli_idempotent_output"
    exit 1
}
[[ $cli_idempotent_output != *'选择影响 Nginx 监听 TCP 443 的地址族'* &&
   $cli_idempotent_output != *'0) 取消启用，不修改配置'* ]] || {
    echo "FAIL: direct frontend enable should not display interactive menu guidance: $cli_idempotent_output"
    exit 1
}
grep -Fq "include $CASE_DIR/empty-modules/*.conf;" "$FRONTEND_NGINX_CONF" || { echo "FAIL: enable must preserve the empty wildcard include"; exit 1; }
jq -e '.enabled == true and .revision == 5 and .bindings == [] and .listen_addresses == ["0.0.0.0"] and .nginx.return_required == true' "$is_core_dir/frontend.json" >/dev/null || {
    echo "FAIL: enable should commit an empty IPv4 profile: $enable_output profile=$(cat "$is_core_dir/frontend.json")"
    exit 1
}
[[ -f "$CASE_DIR/one-singbox/stream.conf" && -f "$CASE_DIR/one-singbox/reality-map.conf" ]] || {
    echo "FAIL: enable should create the owned stream and map files"
    exit 1
}
grep -q 'one-singbox-frontend:begin' "$FRONTEND_NGINX_CONF" || {
    echo "FAIL: enable should add one marked top-level include"
    exit 1
}
[[ $(cat "$FRONTEND_RELOAD_COUNT_FILE") == 1 ]] || {
    echo "FAIL: successful enable should reload Nginx once"
    exit 1
}
FRONTEND_NGINX_LISTENERS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=123,fd=6))'
export FRONTEND_NGINX_LISTENERS
enabled_status=$(main frontend status --json 2>&1) || {
    echo "FAIL: enabled status should refresh and report a matching active Nginx instance: $enabled_status"
    exit 1
}
jq -e '.ok == true and .enabled == true and .nginx.listener_443 == 1' <<<"$enabled_status" >/dev/null || {
    echo "FAIL: enabled status should return refreshed listener state: $enabled_status"
    exit 1
}
enabled_human_status=$(main frontend status 2>&1) || {
    echo "FAIL: enabled text status should refresh and report the local Nginx check: $enabled_human_status"
    exit 1
}
[[ $enabled_human_status == *"Nginx 服务：nginx.service"* &&
   $enabled_human_status == *"Nginx 二进制：$FRONTEND_NGINX_BIN"* &&
   $enabled_human_status == *'TCP 443 监听范围：0.0.0.0'* &&
   $enabled_human_status == *'本机检查：通过'* ]] || {
    echo "FAIL: enabled text status should show the detected instance, selected listener range, and local check result: $enabled_human_status"
    exit 1
}

status_config_before=$(sha256sum "$CASE_DIR/one-singbox/stream.conf" | awk '{print $1}')
sed -i 's/one_singbox_reality_backend/stale_reality_backend/g' "$CASE_DIR/one-singbox/stream.conf"
drifted_status=$(main frontend status --json 2>&1) && {
    echo 'FAIL: enabled status must surface an active config that no longer matches the saved profile'
    exit 1
}
jq -e '.ok == false and .errors[0].code == "nginx_instance_drift"' <<<"$drifted_status" >/dev/null || {
    echo "FAIL: drifted status should identify the stale Nginx profile: $drifted_status"
    exit 1
}
sed -i 's/stale_reality_backend/one_singbox_reality_backend/g' "$CASE_DIR/one-singbox/stream.conf"
[[ $(sha256sum "$CASE_DIR/one-singbox/stream.conf" | awk '{print $1}') == "$status_config_before" ]] || {
    echo 'FAIL: restoring the status drift fixture did not restore the Nginx config'
    exit 1
}

FRONTEND_NGINX_LISTENERS=$'LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=123,fd=6))\nLISTEN 0 511 [::]:443 [::]:* users:(("nginx",pid=124,fd=7))'
export FRONTEND_NGINX_LISTENERS
enabled_disjoint_status=$(main frontend status --json 2>&1) || {
    echo "FAIL: enabled IPv4 status should ignore a second same-binary IPv6 listener: $enabled_disjoint_status"
    exit 1
}

FRONTEND_NGINX_LISTENERS='LISTEN 0 511 [::]:443 [::]:* users:(("nginx",pid=123,fd=6))'
export FRONTEND_NGINX_LISTENERS
enabled_wrong_family_status=$(main frontend status --json 2>&1) && {
    echo 'FAIL: enabled IPv4 status must reject an IPv6-only live listener'
    exit 1
}
jq -e '.ok == false and .errors[0].code == "nginx_listener_missing"' <<<"$enabled_wrong_family_status" >/dev/null || {
    echo "FAIL: enabled wrong-family listener should be reported: $enabled_wrong_family_status"
    exit 1
}
FRONTEND_NGINX_LISTENERS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=123,fd=6))'
export FRONTEND_NGINX_LISTENERS

config_after_enable=$(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}')
profile_after_enable=$(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}')
enable_again=$(main frontend enable 2>&1) || {
    echo "FAIL: repeating empty-mode enable should be idempotent: $enable_again"
    exit 1
}
[[ $(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}') == "$config_after_enable" && $(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}') == "$profile_after_enable" && $(cat "$FRONTEND_RELOAD_COUNT_FILE") == 1 ]] || {
    echo "FAIL: repeated enable changed files, revision, or reload count"
    exit 1
}

user_file_before_disable=$(sha256sum "$CASE_DIR/http.d/site.conf" | awk '{print $1}')
disable_output=$(main frontend disable 2>&1) || {
    echo "FAIL: disabling an empty profile should succeed: $disable_output"
    exit 1
}
[[ $(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}') == "$config_before" ]] || {
    echo "FAIL: disable should remove only the managed marker block from the shared Nginx config"
    exit 1
}
[[ $(sha256sum "$CASE_DIR/http.d/site.conf" | awk '{print $1}') == "$user_file_before_disable" ]] || {
    echo "FAIL: disable changed a user-owned included Nginx file"
    exit 1
}
[[ ! -e "$CASE_DIR/one-singbox/reality-map.conf" && ! -e "$CASE_DIR/one-singbox/stream.conf" ]] || {
    echo "FAIL: disable should remove only the project-owned Nginx files"
    exit 1
}
jq -e '.enabled == false and .revision == 6 and .bindings == [] and .ownership == {}' "$is_core_dir/frontend.json" >/dev/null || {
    echo "FAIL: disable should commit a disabled profile with the next revision: $disable_output"
    exit 1
}
[[ $(cat "$FRONTEND_RELOAD_COUNT_FILE") == 2 ]] || {
    echo "FAIL: disable should reload and confirm the still-running Nginx service"
    exit 1
}

profile_before=$(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}')
service_log_before=$(sha256sum "$FRONTEND_SERVICE_LOG" | awk '{print $1}')
enable_output=$(main frontend enable missing-node.json 2>&1) && {
    echo "FAIL: enabling a nonexistent node reference must be rejected"
    exit 1
}
[[ $enable_output == *"missing-node.json"* ]] || {
    echo "FAIL: missing node references should be identified: $enable_output"
    exit 1
}
[[ $(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}') == "$profile_before" && $(sha256sum "$FRONTEND_SERVICE_LOG" | awk '{print $1}') == "$service_log_before" ]] || {
    echo "FAIL: rejected enable changed local state or contacted a service manager"
    exit 1
}

cat >"$FRONTEND_NGINX_CONF" <<EOF
events {}
stream {
    # 用户配置应原样保留
}
http { include $CASE_DIR/http.d/site.conf; }
EOF
FRONTEND_NGINX_LISTENERS=
export FRONTEND_NGINX_LISTENERS
empty_stream_enable=$(printf '1\n' | main frontend enable 2>&1) || {
    echo "FAIL: empty-mode enable inside an empty stream block should succeed: $empty_stream_enable"
    exit 1
}
jq -e '.enabled == true and .revision == 7 and .bindings == [] and .ownership.anchor_kind == "empty_stream" and .nginx.modules.return == true' "$is_core_dir/frontend.json" >/dev/null || {
    echo "FAIL: empty-stream enable should record its owned insertion and validated capabilities: $empty_stream_enable"
    exit 1
}
[[ -f "$CASE_DIR/one-singbox/reality-map.conf" && ! -e "$CASE_DIR/one-singbox/stream.conf" ]] || {
    echo "FAIL: empty-stream enable should own only its generated Reality map file"
    exit 1
}
[[ $(cat "$FRONTEND_RELOAD_COUNT_FILE") == 3 ]] || {
    echo "FAIL: empty-stream enable should reload and confirm Nginx"
    exit 1
}
FRONTEND_NGINX_LISTENERS='LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=123,fd=6))'
export FRONTEND_NGINX_LISTENERS

config_before_reload_failure=$(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}')
profile_before_reload_failure=$(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}')
FRONTEND_FAIL_RELOAD_AT=4
export FRONTEND_FAIL_RELOAD_AT
reload_failure=$(main frontend disable 2>&1) && {
    echo "FAIL: a failed Nginx reload should fail disable and trigger rollback"
    exit 1
}
FRONTEND_FAIL_RELOAD_AT=0
export FRONTEND_FAIL_RELOAD_AT
[[ $(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}') == "$config_before_reload_failure" && $(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}') == "$profile_before_reload_failure" && -f "$CASE_DIR/one-singbox/reality-map.conf" ]] || {
    echo "FAIL: reload failure did not restore the enabled config, project file, and profile: $reload_failure"
    exit 1
}
[[ $(jq -r '.phase' "$is_core_dir/.frontend-state/transaction.json") == rolled_back && $(cat "$FRONTEND_RELOAD_COUNT_FILE") == 5 ]] || {
    echo "FAIL: reload failure should persist rollback completion and reload the restored config (phase=$(jq -r '.phase' "$is_core_dir/.frontend-state/transaction.json" 2>/dev/null) count=$(cat "$FRONTEND_RELOAD_COUNT_FILE" 2>/dev/null) error=$reload_failure)"
    exit 1
}

config_before_worker_failure=$(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}')
profile_before_worker_failure=$(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}')
# Only the second same-binary master starts a new worker; selected master 123 does not.
FRONTEND_NO_NEW_WORKER_AT=6
FRONTEND_CHANGE_OTHER_WORKER_AT=6
export FRONTEND_NO_NEW_WORKER_AT
export FRONTEND_CHANGE_OTHER_WORKER_AT
worker_failure=$(main frontend disable 2>&1) && {
    echo "FAIL: a second-master worker should not confirm selected-master reload and disable should roll back"
    exit 1
}
FRONTEND_NO_NEW_WORKER_AT=0
FRONTEND_CHANGE_OTHER_WORKER_AT=0
export FRONTEND_NO_NEW_WORKER_AT
export FRONTEND_CHANGE_OTHER_WORKER_AT
[[ $(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}') == "$config_before_worker_failure" && $(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}') == "$profile_before_worker_failure" && -f "$CASE_DIR/one-singbox/reality-map.conf" ]] || {
    echo "FAIL: worker confirmation failure did not restore the enabled files and profile: $worker_failure"
    exit 1
}
[[ $(jq -r '.phase' "$is_core_dir/.frontend-state/transaction.json") == rolled_back && $(cat "$FRONTEND_RELOAD_COUNT_FILE") == 7 ]] || {
    echo "FAIL: worker confirmation failure should reload the restored config and persist rollback"
    exit 1
}

config_before_interruption=$(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}')
profile_before_interruption=$(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}')
map_before_interruption=$(sha256sum "$CASE_DIR/one-singbox/reality-map.conf" | awk '{print $1}')
FRONTEND_RELEASE_FILE="$CASE_DIR/release-reload"
rm -f "$FRONTEND_RELEASE_FILE" "$FRONTEND_PAUSE_FILE" "$FRONTEND_PAUSE_PID_FILE"
export FRONTEND_RELEASE_FILE
FRONTEND_PAUSE_RELOAD_AT=8
export FRONTEND_PAUSE_RELOAD_AT
main frontend disable >"$CASE_DIR/interrupted-disable.log" 2>&1 &
disable_pid=$!
for ((attempt = 0; attempt < 100; attempt++)); do
    [[ -e $FRONTEND_PAUSE_FILE ]] && break
    /bin/sleep 0.02
done
[[ -e $FRONTEND_PAUSE_FILE && -s $FRONTEND_PAUSE_PID_FILE ]] || {
    echo "FAIL: disable did not reach its persisted transaction reload seam"
    kill "$disable_pid" 2>/dev/null || :
    exit 1
}
reload_pid=$(cat "$FRONTEND_PAUSE_PID_FILE")
kill -KILL "$disable_pid" "$reload_pid" 2>/dev/null || :
wait "$disable_pid" 2>/dev/null || :
: >"$FRONTEND_RELEASE_FILE"
for ((attempt = 0; attempt < 100; attempt++)); do
    flock -n "$is_core_dir/.frontend-state/lock" -c true 2>/dev/null && break
    /bin/sleep 0.02
done
flock -n "$is_core_dir/.frontend-state/lock" -c true 2>/dev/null || {
    echo "FAIL: interrupted disable did not release its transaction lock"
    exit 1
}
FRONTEND_PAUSE_RELOAD_AT=0
export FRONTEND_PAUSE_RELOAD_AT
FRONTEND_NGINX_MASTER_PID=321
FRONTEND_NGINX_LISTENERS=${FRONTEND_NGINX_LISTENERS//pid=123/pid=321}
export FRONTEND_NGINX_MASTER_PID FRONTEND_NGINX_LISTENERS
saved_nginx_config=$FRONTEND_NGINX_CONF
drifted_nginx_config="$CASE_DIR/drifted-nginx.conf"
cp "$saved_nginx_config" "$drifted_nginx_config"
interrupted_profile_hash=$(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}')
FRONTEND_NGINX_CONF=$drifted_nginx_config
export FRONTEND_NGINX_CONF
drifted_recovery=$(main frontend recover 2>&1) && {
    echo 'FAIL: recovery must reject an active Nginx config path that differs from the transaction target'
    exit 1
}
[[ $(sha256sum "$saved_nginx_config" | awk '{print $1}') == "$config_before_interruption" &&
   $(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}') == "$interrupted_profile_hash" &&
   -f "$CASE_DIR/one-singbox/reality-map.conf" &&
   $(sha256sum "$CASE_DIR/one-singbox/reality-map.conf" | awk '{print $1}') == "$map_before_interruption" &&
   $(cat "$FRONTEND_RELOAD_COUNT_FILE") == 8 &&
   $(jq -r '.phase' "$is_core_dir/.frontend-state/transaction.json") == recovery_required ]] || {
    echo "FAIL: identity drift should retain recovery_required after restoring files without reloading: $drifted_recovery"
    exit 1
}
FRONTEND_NGINX_CONF=$saved_nginx_config
export FRONTEND_NGINX_CONF
recover_output=$(main frontend recover 2>&1) || {
    echo "FAIL: recover should roll back an interrupted disable transaction after the selected service restarts: $recover_output"
    exit 1
}
[[ $(sha256sum "$FRONTEND_NGINX_CONF" | awk '{print $1}') == "$config_before_interruption" && $(sha256sum "$is_core_dir/frontend.json" | awk '{print $1}') == "$profile_before_interruption" && $(sha256sum "$CASE_DIR/one-singbox/reality-map.conf" | awk '{print $1}') == "$map_before_interruption" ]] || {
    echo "FAIL: recovery did not restore the pre-interruption enabled state: $recover_output"
    exit 1
}
[[ $(jq -r '.phase' "$is_core_dir/.frontend-state/transaction.json") == rolled_back && $(cat "$FRONTEND_RELOAD_COUNT_FILE") == 9 ]] || {
    echo "FAIL: recovery should persist rollback completion and confirm the restored Nginx workers"
    exit 1
}
disable_output=$(main frontend disable 2>&1) || {
    echo "FAIL: empty-stream mode should be safely disableable after recovery: $disable_output"
    exit 1
}
jq -e '.enabled == false and .revision == 8 and .ownership == {}' "$is_core_dir/frontend.json" >/dev/null || {
    echo "FAIL: successful empty-stream disable should leave the profile disabled: $disable_output"
    exit 1
}
[[ ! -e "$CASE_DIR/one-singbox/reality-map.conf" && $(cat "$FRONTEND_RELOAD_COUNT_FILE") == 10 ]] || {
    echo "FAIL: successful empty-stream disable should remove its file and reload once"
    exit 1
}
CASE
    [[ $? == 0 ]] || fail "CLI status and enable rejection failed for $core_file"
done

echo "PASS: frontend CLI status/check, empty-mode transactions, and recovery"
