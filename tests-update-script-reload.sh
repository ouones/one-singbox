#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
cleanup() {
    rm -rf "$workdir"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1"
    exit 1
}

run_test_suite() {
    local core_file=$1
    CORE_FILE="$core_file" WORKDIR="$workdir" bash <<'CASE'
set -o pipefail

fail() {
    echo "FAIL(${CORE_FILE##*/}): $1"
    exit 1
}

case_dir=$(mktemp -d "$WORKDIR/case.XXXXXX")
trap 'rm -rf "$case_dir"' EXIT

mkdir -p "$case_dir/core" "$case_dir/conf" "$case_dir/bin"
touch "$case_dir/core/.block-cn-enabled"
export SERVICE_LOG="$case_dir/services.log"
cat >"$case_dir/bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SERVICE_LOG"
[[ ${FAIL_SYSTEMCTL:-0} == 1 ]] && exit 1
exit 0
FAKE_SYSTEMCTL
chmod +x "$case_dir/bin/systemctl"
export PATH="$case_dir/bin:$PATH"
cat >"$case_dir/bin/sing-box" <<'FAKE_CORE'
#!/usr/bin/env bash
case $1 in
version) printf 'sing-box version 1.14.4\n' ;;
check) [[ ${FAIL_CORE_CHECK:-0} == 1 ]] && exit 1 || exit 0 ;;
*) exit 2 ;;
esac
FAKE_CORE
chmod +x "$case_dir/bin/sing-box"

source <(sed '/EUID != 0/d' "$CORE_FILE")
is_core_dir="$case_dir/core"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin="$case_dir/bin/sing-box"
is_core_ver=1.14.4
is_sh_ver=v1.54
is_sh_dir="$case_dir/sh"
is_sh_bin="$case_dir/bin/sb"
is_sh_repo=ouones/one-singbox
is_dont_show_info=1
is_no_manage_msg=1
is_systemd=1

cat >"$is_config_json" <<'CONFIG'
{
  "outbounds": [{"tag": "direct", "type": "direct"}],
  "route": {"rule_set": []},
  "http_clients": [{"tag": "direct-client", "detour": "direct"}]
}
CONFIG

export UPDATE_CORE_FILE="$CORE_FILE"
export UPDATE_CASE_DIR="$case_dir"
export UPDATE_RELOAD_ARGS="$case_dir/new-script.args"
cat >"$is_sh_bin" <<'NEW_SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$UPDATE_RELOAD_ARGS"
source <(sed '/EUID != 0/d' "$UPDATE_CORE_FILE")
is_core_dir="$UPDATE_CASE_DIR/core"
is_conf_dir="$UPDATE_CASE_DIR/conf"
is_config_json="$UPDATE_CASE_DIR/config.json"
is_core_bin="$UPDATE_CASE_DIR/bin/sing-box"
is_core_ver=1.14.4
main "$@"
NEW_SCRIPT
chmod +x "$is_sh_bin"

run_script_update() {
    local output=$1
    (
        qrcode_dependency_install() { :; }
        load() {
            [[ $1 == download.sh ]] && {
                download() { :; }
                return 0
            }
            . "$is_sh_dir/src/$1"
        }
        # Emulate a generator already loaded from the old script process.
        sync_runtime_node_outbound_modes() { return 0; }
        update sh v1.55
    ) >"$output" 2>&1
}

run_script_update "$case_dir/update.out" || fail "script update failed: $(<"$case_dir/update.out")"
wait

[[ -f $UPDATE_RELOAD_ARGS ]] || fail "script update did not invoke the newly installed script"
grep -Fxq '__post-update' "$UPDATE_RELOAD_ARGS" || fail "script update invoked the wrong new-script command"
jq -e '.http_clients | any(.tag == "direct-client" and .detour == null)' "$is_config_json" >/dev/null \
    || fail "script update left config.json in the old incompatible format"
[[ ! -s $SERVICE_LOG ]] || fail "update sh must not restart the service: $(<"$SERVICE_LOG")"

rm -f "$UPDATE_RELOAD_ARGS"
jq '.http_clients = [{"tag": "direct-client", "detour": "direct"}]' "$is_config_json" \
    >"$is_config_json.tmp" && mv -f "$is_config_json.tmp" "$is_config_json"
export FAIL_CORE_CHECK=1
if run_script_update "$case_dir/update-failure.out"; then
    fail "script update reported success when post-update migration failed"
fi
grep -Fq '配置迁移失败' "$case_dir/update-failure.out" \
    || fail "script update failure did not explain the migration problem: $(<"$case_dir/update-failure.out")"
! grep -Fq '更新成功' "$case_dir/update-failure.out" \
    || fail "script update printed success after post-update migration failed"

run_update_restart_failure() {
    local target=$1 version=$2 output=$3 service=$4
    : >"$SERVICE_LOG"
    if (
        qrcode_dependency_install() { :; }
        load() {
            [[ $1 == download.sh ]] && {
                download() { :; }
                return 0
            }
            . "$is_sh_dir/src/$1"
        }
        if [[ $target == caddy ]]; then
            is_caddy=1
            is_caddy_ver=v2.7.6
        fi
        migrate_runtime_config() { return 0; }
        export FAIL_SYSTEMCTL=1
        update "$target" "$version"
    ) >"$output" 2>&1; then
        fail "update $target reported success when service restart failed"
    fi
    grep -Fq '服务重启失败' "$output" \
        || fail "update $target failure did not explain the restart problem: $(<"$output")"
    ! grep -Fq '更新成功' "$output" \
        || fail "update $target printed success after service restart failed"
    [[ $(<"$SERVICE_LOG") == "restart $service" ]] \
        || fail "update $target did not attempt exactly one restart of $service: $(<"$SERVICE_LOG")"
}

run_update_restart_failure core v1.15.0 "$case_dir/core-restart-failure.out" "$is_core"
run_update_restart_failure caddy v2.8.0 "$case_dir/caddy-restart-failure.out" caddy

# An older target script without __post-update must be rejected before it replaces installed files.
repo_root=${CORE_FILE%/core.sh}
[[ $repo_root == */src ]] && repo_root=${repo_root%/src}
download_dir="$case_dir/download"
old_archive="$download_dir/old.tar.gz"
supported_archive="$download_dir/supported.tar.gz"
mkdir -p "$download_dir/sh/src" "$download_dir/old/src" "$download_dir/supported/src"
printf 'installed script\n' >"$download_dir/sh/src/core.sh"
printf '# old script without post-update migration\n' >"$download_dir/old/src/core.sh"
printf '# supported script\n' >"$download_dir/supported/src/core.sh"
printf '1\n' >"$download_dir/supported/src/post-update-capable"
tar czf "$old_archive" -C "$download_dir/old" src
tar czf "$supported_archive" -C "$download_dir/supported" src
printf '#!/usr/bin/env bash\n' >"$download_dir/sh/sing-box.sh"
printf '#!/usr/bin/env bash\n' >"$download_dir/sh/sb.sh"

run_script_download() {
    local archive=$1 output=$2
    (
        source "$repo_root/src/download.sh"
        is_arch=amd64
        is_sh_dir="$download_dir/sh"
        is_sh_bin="$download_dir/sh/sing-box.sh"
        is_sh_repo=ouones/one-singbox
        _wget() {
            local output_file=
            while (($#)); do
                case $1 in
                -O) output_file=$2; shift 2 ;;
                *) shift ;;
                esac
            done
            cp "$archive" "$output_file"
        }
        download sh v1.55
    ) >"$output" 2>&1
}

if run_script_download "$old_archive" "$case_dir/old-version.out"; then
    fail "old script version without post-update migration was accepted"
fi
grep -Fq '不支持更新后配置迁移' "$case_dir/old-version.out" \
    || fail "old script version rejection did not explain compatibility: $(<"$case_dir/old-version.out")"
[[ $(<"$download_dir/sh/src/core.sh") == 'installed script' ]] \
    || fail "old script version replaced files before compatibility validation"

run_script_download "$supported_archive" "$case_dir/supported-version.out" \
    || fail "supported script version was rejected: $(<"$case_dir/supported-version.out")"
grep -Fq '# supported script' "$download_dir/sh/src/core.sh" \
    || fail "supported script version was not installed"

echo "PASS: $CORE_FILE reloads the installed script for post-update migration"
CASE
}

run_test_suite "$repo_root/src/core.sh" || fail "test suite failed for src/core.sh"
run_test_suite "$repo_root/core.sh" || fail "test suite failed for core.sh"

# The real entry must clean the legacy root core.sh copy without touching anything else.
run_entry_cleanup_case() {
    local scenario=$1
    local case_dir="$workdir/entry-$scenario"
    local root="$case_dir/root"
    local sh_dir="$root/etc/sing-box/sh"
    local entry="$sh_dir/sing-box.sh"
    local service_log="$case_dir/services.log"
    local output="$case_dir/entry.out"

    mkdir -p "$sh_dir/src" "$root/etc/sing-box/bin" "$root/etc/sing-box/conf" \
        "$root/usr/local/bin" "$root/var/log/sing-box" "$case_dir/bin"
    cp -R "$repo_root/src/." "$sh_dir/src/"
    cp "$repo_root/sing-box.sh" "$entry"
    sed -i "s|^\. /etc/sing-box/sh/src/init.sh$|. $sh_dir/src/init.sh|" "$entry"
    grep -Fq ". $sh_dir/src/init.sh" "$entry" || fail "test fixture did not rewrite the entry script path"
    sed -i \
        -e "s|^is_core_dir=/etc/|is_core_dir=$root/etc/|" \
        -e "s|^is_log_dir=/var/log/|is_log_dir=$root/var/log/|" \
        -e "s|^is_sh_bin=/usr/local/bin/|is_sh_bin=$root/usr/local/bin/|" \
        "$sh_dir/src/init.sh"
    grep -Fq "is_core_dir=$root/etc/" "$sh_dir/src/init.sh" || fail "test fixture did not rewrite init.sh paths"

    printf 'tls certificate\n' >"$root/etc/sing-box/bin/tls.cer"
    printf 'tls key\n' >"$root/etc/sing-box/bin/tls.key"
    printf '200\n' >"$root/etc/sing-box/log-limit-mb"
    printf '{"keep":true}\n' >"$root/etc/sing-box/config.json"
    printf '{"node":"keep"}\n' >"$root/etc/sing-box/conf/node.json"
    printf 'log line\n' >"$root/var/log/sing-box/access.log"
    printf 'sibling\n' >"$sh_dir/core.sh.bak"

    cat >"$root/etc/sing-box/bin/sing-box" <<'FAKE_CORE'
#!/usr/bin/env bash
case $1 in
version) printf 'sing-box version 1.14.4\n' ;;
*) exit 0 ;;
esac
FAKE_CORE
    cat >"$case_dir/bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ENTRY_SERVICE_LOG"
case $1 in
is-active)
    [[ $2 == --quiet ]] && exit 0
    printf 'active\n'
    ;;
esac
exit 0
FAKE_SYSTEMCTL
    chmod +x "$root/etc/sing-box/bin/sing-box" "$case_dir/bin/systemctl" "$entry"

    case $scenario in
    success)
        printf 'legacy root script\n' >"$sh_dir/core.sh"
        ;;
    failure)
        mkdir -p "$sh_dir/core.sh"
        printf 'cannot remove\n' >"$sh_dir/core.sh/keep"
        ;;
    esac

    : >"$service_log"
    if ! ENTRY_SERVICE_LOG="$service_log" PATH="$case_dir/bin:$PATH" bash "$entry" version >"$output" 2>&1; then
        fail "entry version command failed in the $scenario cleanup case: $(<"$output")"
    fi
    grep -Fq 'sing-box 1.14.4' "$output" \
        || fail "entry version command did not complete in the $scenario cleanup case: $(<"$output")"
    ! grep -Fq '配置迁移失败' "$output" \
        || fail "entry cleanup was reported as a config migration failure in the $scenario case: $(<"$output")"
    ! grep -Eq '^(restart|reload|start|stop|enable|disable)( |$)' "$service_log" \
        || fail "entry cleanup changed the service state in the $scenario case: $(<"$service_log")"
    [[ $(<"$root/etc/sing-box/bin/tls.cer") == 'tls certificate' ]] \
        || fail "entry cleanup changed the TLS certificate in the $scenario case"
    [[ $(<"$root/etc/sing-box/bin/tls.key") == 'tls key' ]] \
        || fail "entry cleanup changed the TLS key in the $scenario case"
    [[ $(<"$root/etc/sing-box/config.json") == '{"keep":true}' ]] \
        || fail "entry cleanup changed config.json in the $scenario case"
    [[ $(<"$root/etc/sing-box/conf/node.json") == '{"node":"keep"}' ]] \
        || fail "entry cleanup changed node configuration in the $scenario case"
    [[ $(<"$root/var/log/sing-box/access.log") == 'log line' ]] \
        || fail "entry cleanup changed the log in the $scenario case"
    [[ -f $sh_dir/src/core.sh ]] || fail "entry cleanup removed the managed core script in the $scenario case"
    [[ -f $sh_dir/core.sh.bak ]] || fail "entry cleanup removed a sibling file in the $scenario case"

    case $scenario in
    success)
        [[ ! -e $sh_dir/core.sh ]] || fail "entry did not remove the legacy root core.sh"
        ;;
    missing)
        [[ ! -e $sh_dir/core.sh ]] || fail "missing-file fixture unexpectedly appeared"
        ! grep -Fq '警告' "$output" \
            || fail "entry warned when no legacy root core.sh existed: $(<"$output")"
        ;;
    failure)
        [[ -d $sh_dir/core.sh ]] || fail "failure fixture changed unexpectedly"
        grep -Fq '警告' "$output" || fail "cleanup failure did not use the warning channel: $(<"$output")"
        grep -Fq "$sh_dir/core.sh" "$output" || fail "cleanup failure warning omitted the file path: $(<"$output")"
        grep -Eq '残留|手动删除' "$output" \
            || fail "cleanup failure warning omitted the residual impact: $(<"$output")"
        ;;
    esac
    echo "PASS: entry cleanup $scenario"
}

run_entry_cleanup_case success || fail "legacy root core.sh cleanup failed"
run_entry_cleanup_case missing || fail "missing legacy root core.sh handling failed"
run_entry_cleanup_case failure || fail "legacy root core.sh cleanup failure handling failed"

echo 'PASS: tests-update-script-reload.sh completed successfully.'
