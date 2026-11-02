#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

fail() {
  echo "FAIL: $1"
  exit 1
}

# Keep the host qrencode hidden while allowing a fake installed command to appear.
type() {
  if [[ $1 == -P && $2 == qrencode ]]; then
    if [[ -x $QRCODE_TEST_BIN/qrencode ]]; then
      printf '%s\n' "$QRCODE_TEST_BIN/qrencode"
      return 0
    fi
    return 1
  fi
  builtin type "$@"
}

qrcode_test_bin=$workdir/bin
mkdir -p "$qrcode_test_bin"
export QRCODE_TEST_BIN=$qrcode_test_bin
export QRCODE_TEST_PACKAGE_LOG=$workdir/packages.log
export QRCODE_TEST_QR_LOG=$workdir/qr.log
export QRCODE_TEST_INSTALLED_MARKER=$workdir/installed.marker
export PATH="$qrcode_test_bin:$PATH"

cat >"$qrcode_test_bin/package-manager" <<'MANAGER'
#!/usr/bin/env bash
printf '%s %s\n' "$0" "$*" >>"$QRCODE_TEST_PACKAGE_LOG"
case $QRCODE_TEST_MODE in
  fail)
    if [[ $* == *install* || $* == *add* ]]; then exit 23; fi
    ;;
  missing)
    exit 0
    ;;
  success)
    if [[ $* == *install* || $* == *add* ]]; then
      : >"$QRCODE_TEST_INSTALLED_MARKER"
      cat >"$QRCODE_TEST_BIN/qrencode" <<'QR'
#!/usr/bin/env bash
[[ -f $QRCODE_TEST_INSTALLED_MARKER ]] || exit 41
printf '%s\n' "$*" >>"$QRCODE_TEST_QR_LOG"
printf 'QRCODE_RENDERED\n'
QR
      chmod +x "$QRCODE_TEST_BIN/qrencode"
    fi
    ;;
esac
exit 0
MANAGER
chmod +x "$qrcode_test_bin/package-manager"
for manager in apt-get yum zypper apk; do
  ln -s package-manager "$qrcode_test_bin/$manager"
done

if [[ ! -f $repo_root/src/qrcode-deps.sh ]]; then
  fail "src/qrcode-deps.sh has not been added"
fi

# Loading the shared module must only define helpers; it must not install or mark anything.
module_dir=$workdir/module
mkdir -p "$module_dir/etc/sing-box"
is_core_dir=$module_dir/etc/sing-box
is_sh_dir=$module_dir/sh
cmd="$qrcode_test_bin/apt-get"
QRCODE_TEST_MODE=success
export QRCODE_TEST_MODE
source "$repo_root/src/qrcode-deps.sh" || fail "shared module did not load"
[[ ! -f $QRCODE_TEST_PACKAGE_LOG ]] || fail "loading the module must not call a package manager"
[[ ! -e $is_core_dir/qrcode-dependency-checked ]] || fail "loading the module must not mark installation checked"
qrcode_dependency_checked && fail "empty state was reported as checked"

manager_cases=(
  'apt-get|install -y qrencode|apt-get install -y qrencode'
  'yum|install -y qrencode|yum install -y qrencode'
  'zypper|--non-interactive install qrencode|zypper --non-interactive install qrencode'
  'apk|add libqrencode-tools|apk add libqrencode-tools'
)
for entry in "${manager_cases[@]}"; do
  IFS='|' read -r manager expected_args expected_hint <<<"$entry"
  rm -f "$qrcode_test_bin/qrencode" "$QRCODE_TEST_INSTALLED_MARKER" "$QRCODE_TEST_PACKAGE_LOG" "$QRCODE_TEST_QR_LOG"
  QRCODE_TEST_MODE=success
  cmd="$qrcode_test_bin/$manager"
  is_core_dir="$module_dir/$manager/etc/sing-box"
  is_sh_dir="$module_dir/$manager/sh"
  mkdir -p "$is_core_dir" "$is_sh_dir"
  actual_hint=$(qrcode_dependency_install_command) || fail "$manager manual command was not available"
  [[ $actual_hint == "$expected_hint" ]] || fail "$manager manual hint mismatch: $actual_hint"
  qrcode_dependency_install >"$workdir/$manager-success.out" 2>&1 || fail "$manager failed to install qrencode"
  [[ -x $qrcode_test_bin/qrencode ]] || fail "$manager success did not make qrencode executable"
  [[ -f $is_core_dir/qrcode-dependency-checked ]] || fail "$manager success did not mark the check complete"
  [[ ! -e $is_sh_dir/qrcode-dependency-checked ]] || fail "$manager marker was stored inside the script directory"
  grep -Fq "$qrcode_test_bin/$manager $expected_args" "$QRCODE_TEST_PACKAGE_LOG" || fail "$manager install arguments were incorrect"
done

# Already-installed qrencode skips package operations but records the completed check.
rm -f "$QRCODE_TEST_PACKAGE_LOG" "$module_dir/apt-existing/etc/sing-box/qrcode-dependency-checked"
cmd="$qrcode_test_bin/apt-get"
is_core_dir="$module_dir/apt-existing/etc/sing-box"
mkdir -p "$is_core_dir"
QRCODE_TEST_MODE=success
qrcode_dependency_install || fail "existing qrencode was reported unavailable"
[[ ! -f $QRCODE_TEST_PACKAGE_LOG ]] || fail "existing qrencode triggered package operations"
[[ -f $is_core_dir/qrcode-dependency-checked ]] || fail "existing qrencode did not mark the check complete"

# A failed package install retries after refreshing the index, then reports a manual command.
rm -f "$qrcode_test_bin/qrencode" "$QRCODE_TEST_INSTALLED_MARKER" "$QRCODE_TEST_PACKAGE_LOG"
cmd="$qrcode_test_bin/apt-get"
is_core_dir="$module_dir/apt-failure/etc/sing-box"
mkdir -p "$is_core_dir"
QRCODE_TEST_MODE=fail
if qrcode_dependency_install >"$workdir/install-failure.out" 2>&1; then
  fail "a nonzero package-manager result was reported as success"
fi
[[ -f $is_core_dir/qrcode-dependency-checked ]] || fail "failed install did not mark the check complete"
[[ $(grep -Fc "$qrcode_test_bin/apt-get install -y qrencode" "$QRCODE_TEST_PACKAGE_LOG") == 2 ]] || fail "failed install was not retried after index refresh"
grep -Fq "$qrcode_test_bin/apt-get update" "$QRCODE_TEST_PACKAGE_LOG" || fail "apt-get index was not refreshed after failure"
grep -Fq '二维码' "$workdir/install-failure.out" || fail "failed install did not report QR dependency failure"
grep -Fq 'apt-get install -y qrencode' "$workdir/install-failure.out" || fail "failed install omitted the manual command"
grep -Fq '主动更新脚本' "$workdir/install-failure.out" || fail "failed install omitted the retry path"

# A successful package-manager exit is insufficient if qrencode remains unavailable.
rm -f "$QRCODE_TEST_PACKAGE_LOG"
is_core_dir="$module_dir/apt-missing/etc/sing-box"
mkdir -p "$is_core_dir"
QRCODE_TEST_MODE=missing
if qrcode_dependency_install >"$workdir/install-missing.out" 2>&1; then
  fail "a missing executable after install was reported as success"
fi
[[ -f $is_core_dir/qrcode-dependency-checked ]] || fail "unverified install did not mark the check complete"
grep -Fq '二维码' "$workdir/install-missing.out" || fail "missing executable did not report QR dependency failure"
grep -Fq 'apt-get install -y qrencode' "$workdir/install-missing.out" || fail "missing executable omitted the manual command"

# The release workflow archives all of src, including the shared module.
archive=$workdir/code.tar.gz
tar czf "$archive" -C "$repo_root" install.sh core.sh sing-box.sh src LICENSE README.md || fail "temporary release archive failed"
tar tzf "$archive" | grep -Fx 'src/qrcode-deps.sh' >/dev/null || fail "release archive omitted src/qrcode-deps.sh"

# Install fixture uses the real install.sh flow while rewriting only fixed filesystem roots into a temp root.
rewrite_paths() {
  local file=$1 root=$2
  sed -i \
    -e "s|^is_core_dir=/etc/|is_core_dir=$root/etc/|" \
    -e "s|^is_log_dir=/var/log/|is_log_dir=$root/var/log/|" \
    -e "s|^is_sh_bin=/usr/local/bin/|is_sh_bin=$root/usr/local/bin/|" \
    -e "s|/root/.bashrc|$root/root/.bashrc|g" \
    -e "s|/usr/bin/jq|$root/usr/bin/jq|g" \
    -e "s|/lib/systemd/system|$root/lib/systemd/system|g" \
    -e "s|/etc/init.d|$root/etc/init.d|g" \
    -e "s|/etc/caddy|$root/etc/caddy|g" \
    "$file"
}

run_install_case() {
  local case_name=$1 mode=$2 hide_wget=$3
  local case_dir="$workdir/install-$case_name"
  local app_dir="$case_dir/app"
  local root="$case_dir/root"
  local bin="$case_dir/bin"
  local archive_dir="$case_dir/core"
  local core_archive="$case_dir/sing-box.tar.gz"
  mkdir -p "$app_dir" "$bin" "$archive_dir/sing-box-v1.14.0" "$root/usr/bin" "$root/root" "$root/usr/local/bin" "$root/lib/systemd/system" "$root/etc/init.d"
  cp "$repo_root/install.sh" "$repo_root/core.sh" "$repo_root/sing-box.sh" "$repo_root/README.md" "$repo_root/LICENSE" "$app_dir/"
  cp -R "$repo_root/src" "$app_dir/src"
  rewrite_paths "$app_dir/install.sh" "$root"
  rewrite_paths "$app_dir/core.sh" "$root"
  rewrite_paths "$app_dir/src/core.sh" "$root"
  rewrite_paths "$app_dir/src/systemd.sh" "$root"
  rewrite_paths "$app_dir/src/log.sh" "$root"

  cat >"$archive_dir/sing-box-v1.14.0/sing-box" <<'CORE'
#!/usr/bin/env bash
case $1 in
  version) echo 'sing-box version 1.14.0';;
  generate)
    case $2 in
      reality-keypair) printf 'PrivateKey: test-private\nPublicKey: test-public\n';;
      tls-keypair) printf '%s\n' '-----BEGIN PRIVATE KEY-----' test '-----END PRIVATE KEY-----' '-----BEGIN CERTIFICATE-----' test '-----END CERTIFICATE-----';;
    esac
    ;;
  check) exit 0;;
  *) exit 0;;
esac
CORE
  chmod +x "$archive_dir/sing-box-v1.14.0/sing-box"
  tar czf "$core_archive" -C "$archive_dir" sing-box-v1.14.0

  cat >"$bin/bash-env" <<'ENV'
type() {
  if [[ $# == 2 && $1 == -P ]]; then
    case $2 in
      apt-get|yum|zypper|apk)
        if [[ $2 == $QRCODE_TEST_MANAGER ]]; then
          printf '%s\n' "$QRCODE_TEST_BIN/$2"
          return 0
        fi
        return 1
        ;;
      wget)
        [[ $QRCODE_TEST_HIDE_WGET == 1 ]] && return 1
        ;;
      qrencode)
        if [[ -x $QRCODE_TEST_BIN/qrencode ]]; then
          printf '%s\n' "$QRCODE_TEST_BIN/qrencode"
          return 0
        fi
        return 1
        ;;
    esac
  fi
  builtin type "$@"
}
ENV
  cat >"$bin/package-manager" <<'MANAGER'
#!/usr/bin/env bash
printf '%s %s\n' "$0" "$*" >>"$QRCODE_TEST_PACKAGE_LOG"
case $QRCODE_TEST_MODE in
  fail)
    if [[ $* == *install* || $* == *add* ]]; then exit 23; fi
    ;;
  success)
    if [[ $* == *install* || $* == *add* ]]; then
      : >"$QRCODE_TEST_INSTALLED_MARKER"
      cat >"$QRCODE_TEST_BIN/qrencode" <<'QR'
#!/usr/bin/env bash
[[ -f $QRCODE_TEST_INSTALLED_MARKER ]] || exit 41
printf '%s\n' "$*" >>"$QRCODE_TEST_QR_LOG"
printf 'QRCODE_RENDERED\n'
QR
      chmod +x "$QRCODE_TEST_BIN/qrencode"
    fi
    ;;
esac
exit 0
MANAGER
  chmod +x "$bin/package-manager"
  ln -s package-manager "$bin/apt-get"
  cat >"$bin/wget" <<'WGET'
#!/usr/bin/env bash
if [[ $* == *cdn-cgi/trace* ]]; then
  printf 'ip=203.0.113.10\n'
  exit 0
fi
exit 1
WGET
  cat >"$bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$QRCODE_TEST_SERVICE_LOG"
exit 0
SYSTEMCTL
  cat >"$bin/timedatectl" <<'NOOP'
#!/usr/bin/env bash
exit 0
NOOP
  cat >"$bin/clear" <<'NOOP'
#!/usr/bin/env bash
exit 0
NOOP
  cat >"$bin/stty" <<'STTY'
#!/usr/bin/env bash
[[ $1 == size ]] && printf '40 80\n'
STTY
  cat >"$bin/sleep" <<'NOOP'
#!/usr/bin/env bash
exit 0
NOOP
  chmod +x "$bin/wget" "$bin/systemctl" "$bin/timedatectl" "$bin/clear" "$bin/stty" "$bin/sleep"

  if ! command -v jq >/dev/null 2>&1; then
    fail "jq is required to run the real installer entry fixture"
  fi
  cp "$(command -v jq)" "$root/usr/bin/jq"
  : >"$root/root/.bashrc"

  QRCODE_TEST_MODE=$mode
  QRCODE_TEST_HIDE_WGET=$hide_wget
  QRCODE_TEST_MANAGER=apt-get
  QRCODE_TEST_BIN=$bin
  QRCODE_TEST_PACKAGE_LOG=$case_dir/packages.log
  QRCODE_TEST_QR_LOG=$case_dir/qr.log
  QRCODE_TEST_SERVICE_LOG=$case_dir/services.log
  QRCODE_TEST_INSTALLED_MARKER=$case_dir/package-installed.marker
  BASH_ENV=$bin/bash-env
  export QRCODE_TEST_MODE QRCODE_TEST_HIDE_WGET QRCODE_TEST_MANAGER QRCODE_TEST_BIN QRCODE_TEST_PACKAGE_LOG QRCODE_TEST_QR_LOG QRCODE_TEST_SERVICE_LOG QRCODE_TEST_INSTALLED_MARKER BASH_ENV
  PATH="$bin:$PATH"
  export PATH
  (cd "$app_dir" && bash ./install.sh -l -f "$core_archive") >"$case_dir/install.out" 2>&1
  if [[ $case_name == mandatory-failure ]]; then
    grep -Fq "安装过程出现错误" "$case_dir/install.out" || fail "mandatory dependency failure was not reported"
    grep -Fq "install -y wget" "$QRCODE_TEST_PACKAGE_LOG" || fail "mandatory dependency install was not attempted"
    grep -Fq "install -y qrencode" "$QRCODE_TEST_PACKAGE_LOG" && fail "QR failure handling masked the mandatory dependency failure"
    [[ ! -e $root/etc/sing-box/qrcode-dependency-checked ]] || fail "QR marker was written before mandatory dependencies succeeded"
    [[ ! -d $root/etc/sing-box/conf ]] || fail "mandatory dependency failure continued into node creation"
    echo "PASS: mandatory dependency failure remains visible before QR handling"
    return 0
  fi
  # The existing installer exits with the status of its false "no error" condition; inspect its result and artifacts.
  [[ $(<"$case_dir/install.out") != *"安装过程出现错误"* ]] || fail "$case_name body install reported failure: $(cat "$case_dir/install.out")"
  [[ -f $root/etc/sing-box/qrcode-dependency-checked ]] || fail "$case_name install did not write the checked marker"
  compgen -G "$root/etc/sing-box/conf/*.json" >/dev/null || fail "$case_name install did not create its first node"
  if [[ $mode == success ]]; then
    [[ -f $QRCODE_TEST_PACKAGE_LOG ]] || fail "$case_name install did not attempt to install qrencode"
    [[ -f $QRCODE_TEST_QR_LOG ]] || fail "$case_name first node detail did not render qrencode"
    grep -Fq 'install -y qrencode' "$QRCODE_TEST_PACKAGE_LOG" || fail "$case_name install used the wrong package command"
  else
    grep -Fq '二维码' "$case_dir/install.out" || fail "$case_name install did not report QR dependency failure"
    grep -Fq 'apt-get install -y qrencode' "$case_dir/install.out" || fail "$case_name install omitted manual install guidance"
    grep -Fq '203.0.113.10' "$case_dir/install.out" || fail "$case_name install failure did not retain the node URL"
    [[ ! -f $QRCODE_TEST_QR_LOG ]] || fail "$case_name failed install unexpectedly rendered qrencode"
  fi
  echo "PASS: new install QR dependency path ($case_name)"
}

run_install_case install-success success 0
run_install_case install-failure fail 0
run_install_case mandatory-failure fail 1

update_workdir=$workdir/update
update_root=$update_workdir/root
update_core=$update_root/etc/sing-box/sh/core.sh
update_runner=$update_workdir/run-update.sh
update_archive=$update_workdir/code.tar.gz
update_package_dir=$update_workdir/release
update_package_log=$update_workdir/packages.log
update_service_log=$update_workdir/services.log

prepare_update_fixture() {
  mkdir -p "$update_root/etc/sing-box/bin" "$update_root/etc/sing-box/sh" \
    "$update_root/etc/sing-box/conf" "$update_root/usr/local/bin" \
    "$update_root/var/log/sing-box" "$update_package_dir"
  cp "$repo_root/core.sh" "$update_core"
  cp -R "$repo_root/src" "$update_root/etc/sing-box/sh/src"
  rewrite_paths "$update_core" "$update_root"

  cat >"$update_root/etc/sing-box/bin/sing-box" <<'CORE'
#!/usr/bin/env bash
[[ $1 == version ]] && printf 'sing-box version 1.14.0\n'
CORE
  cat >"$update_root/usr/local/bin/sing-box" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
  cp "$update_root/usr/local/bin/sing-box" "$update_root/usr/local/bin/sb"
  chmod +x "$update_root/etc/sing-box/bin/sing-box" "$update_root/usr/local/bin/sing-box" "$update_root/usr/local/bin/sb"
  printf '%s\n' '{"keep":true}' >"$update_root/etc/sing-box/conf/keep.json"
  printf '100\n' >"$update_root/etc/sing-box/log-limit-mb"
  : >"$update_service_log"

  cat >"$qrcode_test_bin/wget" <<'WGET'
#!/usr/bin/env bash
if [[ $* == *api.github.com/repos/ouones/one-singbox/releases/latest* ]]; then
  printf '{"tag_name":"%s"}\n' "$QRCODE_TEST_LATEST_VERSION"
  exit 0
fi
if [[ $* == */releases/download/*/code.tar.gz* ]]; then
  while (($#)); do
    if [[ $1 == -O ]]; then
      cp "$QRCODE_TEST_UPDATE_ARCHIVE" "$2"
      exit $?
    fi
    shift
  done
fi
exit 55
WGET
  chmod +x "$qrcode_test_bin/wget"

  cat >"$qrcode_test_bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$QRCODE_TEST_SERVICE_LOG"
exit 0
SYSTEMCTL
  chmod +x "$qrcode_test_bin/systemctl"

  cat >"$update_runner" <<'RUNNER'
#!/usr/bin/env bash
source "$QRCODE_TEST_CORE"
is_sh_ver=v1.34
is_caddy=1
is_caddy_ver=v2.8.0
ask() {
  case $1 in
    mainmenu) REPLY=6 ;;
    list)
      REPLY=2
      [[ ! $2 ]] || printf -v "$2" '%s' 2
      ;;
  esac
}
main "$@"
RUNNER
  chmod +x "$update_runner"

  printf 'new script release\n' >"$update_package_dir/update.marker"
  tar czf "$update_archive" -C "$update_package_dir" update.marker || fail "could not create update fixture archive"
}

run_active_update() {
  local latest=$1 mode=$2
  shift 2
  QRCODE_TEST_LATEST_VERSION=$latest \
    QRCODE_TEST_MODE=$mode \
    QRCODE_TEST_CORE=$update_core \
    QRCODE_TEST_UPDATE_ARCHIVE=$update_archive \
    QRCODE_TEST_PACKAGE_LOG=$update_package_log \
    QRCODE_TEST_SERVICE_LOG=$update_service_log \
    QRCODE_TEST_INSTALLED_MARKER=$QRCODE_TEST_INSTALLED_MARKER \
    QRCODE_TEST_BIN=$qrcode_test_bin \
    PATH="$qrcode_test_bin:$PATH" \
    bash "$update_runner" "$@"
}

prepare_update_fixture
rm -f "$qrcode_test_bin/qrencode" "$QRCODE_TEST_INSTALLED_MARKER" "$update_root/etc/sing-box/sh/qrcode-dependency-checked"
: >"$update_package_log"
run_active_update v1.34 success update sh v1.34 >"$update_workdir/same-version.out" 2>&1 || fail "same-version update command failed"
[[ -f $update_root/etc/sing-box/sh/qrcode-dependency-checked ]] && fail "QR marker was stored in the script directory"
[[ -f $update_root/etc/sing-box/qrcode-dependency-checked ]] || fail "same-version script update did not mark the check complete"
[[ $(grep -Fc "$qrcode_test_bin/apt-get install -y qrencode" "$update_package_log") == 1 ]] || fail "update sh with the current version skipped dependency installation"
grep -Fq '版本一样' "$update_workdir/same-version.out" || fail "same-version update did not retain its normal result"

rm -f "$qrcode_test_bin/qrencode"
: >"$update_package_log"
run_active_update v1.34 success U >"$update_workdir/latest.out" 2>&1 || fail "U update command failed"
[[ $(grep -Fc "$qrcode_test_bin/apt-get install -y qrencode" "$update_package_log") == 1 ]] || fail "already-latest U update skipped dependency installation"
grep -Fq '当前已经是最新版本' "$update_workdir/latest.out" || fail "already-latest U update did not retain its normal result"

rm -f "$qrcode_test_bin/qrencode"
: >"$update_package_log"
run_active_update v1.35 success update.sh >"$update_workdir/new-version.out" 2>&1 || fail "update.sh command failed"
[[ $(grep -Fc "$qrcode_test_bin/apt-get install -y qrencode" "$update_package_log") == 1 ]] || fail "new-version update.sh skipped dependency installation"
grep -Fq '更新成功' "$update_workdir/new-version.out" || fail "new-version update.sh did not finish the script update"
[[ $(<"$update_root/etc/sing-box/sh/update.marker") == 'new script release' ]] || fail "new-version update.sh did not extract the release"

rm -f "$qrcode_test_bin/qrencode"
: >"$update_package_log"
run_active_update v1.36 success main >"$update_workdir/menu.out" 2>&1 || fail "homepage script update menu failed"
[[ $(grep -Fc "$qrcode_test_bin/apt-get install -y qrencode" "$update_package_log") == 1 ]] || fail "homepage script update menu skipped dependency installation"
grep -Fq '更新成功' "$update_workdir/menu.out" || fail "homepage script update menu did not finish the script update"

rm -f "$qrcode_test_bin/qrencode"
: >"$update_package_log"
run_active_update v1.37 fail update.sh >"$update_workdir/qr-failure.out" 2>&1 || fail "QR package failure stopped the script update"
[[ -f $update_root/etc/sing-box/qrcode-dependency-checked ]] || fail "failed active update did not mark the check complete"
grep -Fq '二维码依赖 qrencode 自动补齐失败' "$update_workdir/qr-failure.out" || fail "failed active update omitted the QR failure result"
grep -Fq 'apt-get install -y qrencode' "$update_workdir/qr-failure.out" || fail "failed active update omitted manual package guidance"
grep -Fq '更新成功' "$update_workdir/qr-failure.out" || fail "QR failure overwrote the script update result"
[[ $(<"$update_root/etc/sing-box/sh/update.marker") == 'new script release' ]] || fail "QR failure prevented the script release from being extracted"

# A later explicit update retries even when the marker already exists.
: >"$update_package_log"
run_active_update v1.34 success U >"$update_workdir/retry.out" 2>&1 || fail "active update retry after QR failure failed"
[[ -x $qrcode_test_bin/qrencode ]] || fail "active update did not retry after the failed attempt marker"
[[ $(grep -Fc "$qrcode_test_bin/apt-get install -y qrencode" "$update_package_log") == 1 ]] || fail "active update marker prevented retry"

: >"$update_package_log"
run_active_update v1.34 success U >"$update_workdir/already-installed.out" 2>&1 || fail "active update with qrencode present failed"
[[ ! -s $update_package_log ]] || fail "active update reinstalled an existing qrencode command"

# A package manager may exit successfully without making qrencode available.
rm -f "$qrcode_test_bin/qrencode"
: >"$update_package_log"
run_active_update v1.38 missing update.sh >"$update_workdir/install-unverified.out" 2>&1 || fail "unverified QR install stopped the script update"
grep -Fq '二维码依赖 qrencode 自动补齐失败' "$update_workdir/install-unverified.out" || fail "unverified QR install did not report failure"
grep -Fq 'apt-get install -y qrencode' "$update_workdir/install-unverified.out" || fail "unverified QR install omitted manual guidance"
grep -Fq '更新成功' "$update_workdir/install-unverified.out" || fail "unverified QR install overwrote the script update result"
[[ ! -x $qrcode_test_bin/qrencode ]] || fail "unverified QR install unexpectedly created the command"

# The checked marker still cannot prevent a later active retry.
: >"$update_package_log"
run_active_update v1.34 success U >"$update_workdir/retry-after-unverified.out" 2>&1 || fail "active retry after unverified install failed"
[[ -x $qrcode_test_bin/qrencode ]] || fail "active update did not retry after an unverified install"
[[ $(grep -Fc "$qrcode_test_bin/apt-get install -y qrencode" "$update_package_log") == 1 ]] || fail "checked marker prevented retry after unverified install"

# Removing the command after a successful attempt also remains repairable by update.
rm -f "$qrcode_test_bin/qrencode"
: >"$update_package_log"
run_active_update v1.34 success update sh v1.34 >"$update_workdir/removed-command.out" 2>&1 || fail "active update after qrencode removal failed"
[[ -x $qrcode_test_bin/qrencode ]] || fail "active update did not repair a removed qrencode command"
[[ $(grep -Fc "$qrcode_test_bin/apt-get install -y qrencode" "$update_package_log") == 1 ]] || fail "removed qrencode command did not trigger package installation"

rm -f "$qrcode_test_bin/qrencode"
rm -f "$update_root/etc/sing-box/qrcode-dependency-checked"
: >"$update_package_log"
run_active_update v1.14.0 success update core v1.14.0 >"$update_workdir/core-update.out" 2>&1 || fail "same-version core update failed"
run_active_update v2.8.0 success update caddy v2.8.0 >"$update_workdir/caddy-update.out" 2>&1 || fail "same-version Caddy update failed"
[[ ! -s $update_package_log ]] || fail "core or Caddy update triggered QR package operations"
[[ ! -f $update_root/etc/sing-box/qrcode-dependency-checked ]] || fail "core or Caddy update consumed the QR check marker"

[[ $(<"$update_root/etc/sing-box/conf/keep.json") == '{"keep":true}' ]] || fail "script update changed node configuration"
[[ $(<"$update_root/etc/sing-box/log-limit-mb") == 100 ]] || fail "script update changed log limit settings"
if grep -Eq '^restart ' "$update_service_log"; then
  fail "script update triggered a core service restart"
fi
echo 'PASS: active script update aliases, version branches, nonblocking failures, and retries'

echo 'PASS: QR dependency lifecycle tests'
