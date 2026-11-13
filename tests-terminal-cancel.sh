#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
cleanup() {
    rm -rf "$workdir"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*"
    exit 1
}

harness=$workdir/harness.sh
cat >"$harness" <<'HARNESS'
#!/usr/bin/env bash
set -o pipefail

CORE_FILE=$1
LOG_FILE=$2
SCENARIO=$3
case_dir=$4
is_conf_dir=$case_dir/conf
is_core_dir=$case_dir/core
is_log_dir=$case_dir/log
mkdir -p "$is_conf_dir" "$is_core_dir" "$is_log_dir"

source <(sed -n '/^ask() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^confirm_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^confirm_exact_yes() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_system_impact() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_select() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^node_menu_has_nodes() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^node_menu_empty_state() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^node_menu() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu_has_entries() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu_empty_state() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_menu() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^service_menu() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^system_tools_menu() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^update_menu() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^is_main_menu() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^mainmenu=(/,/^)/p' "$CORE_FILE")
source <(sed -n '/^log_set() {/,/^}/p' "$LOG_FILE")
source <(sed -n '/^interactive_read() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^run_interactive_operation() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^menu_action() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^interactive_log_tail() {/,/^}/p' "$LOG_FILE")
source <(sed -n '/^uninstall() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^get() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^del() {/,/^}/p' "$CORE_FILE" | sed '1s/^del()/delete_node_scenario()/')

if ! declare -F interactive_read >/dev/null; then
    interactive_read() { builtin read "$@"; }
fi
if ! declare -F run_interactive_operation >/dev/null; then
    run_interactive_operation() { "$@"; }
fi
if ! declare -F interactive_log_tail >/dev/null; then
    interactive_log_tail() { tail -f "$1"; }
fi

msg() { printf '%b\n' "$*"; }
_green() { printf '%s' "$*"; }
_red() { printf '%s' "$*"; }
show_list() { printf '%s\n' "$@"; }
menu_pause() {
    printf '\n按回车返回菜单。\n'
    interactive_read -r || :
}
load() { :; }
qrcode_dependency_checked() { return 0; }
qrcode_dependency_install() { return 0; }
core_status_read() { is_core_ver=1.50; is_core_status='运行中'; }
log_limit_read() { printf '200'; }
log_usage_read() { printf '0'; }
is_script_name=one-singbox
is_sh_ver=v1.50
author=ouones
is_core_name=sing-box
is_core_ver=1.50
is_core_status='运行中'
is_core=sing-box
is_main_start=1
is_terminal_log_view=

node_menu_has_nodes() { return 0; }
node_menu_empty_state() { return 1; }
info() { printf 'NODE_INFO\n'; }
del() { printf 'NODE_DELETE\n'; }
add() {
    printf 'NODE_ADD_INPUT\n'
    ask string node_name '输入节点名称:'
    printf '%s' "$node_name" >"$case_dir/node-name"
}
change() {
    printf 'NODE_CHANGE_INPUT\n'
    ask string node_name '输入新节点名称:'
    printf '%s' "$node_name" >"$case_dir/change-name"
}
apply_node_config_lifecycle() {
    printf 'deleted' >"$case_dir/node-deleted"
}

relay_list() { printf 'RELAY_LIST\n'; }
relay_info() { printf 'RELAY_INFO\n'; }
relay_menu_has_entries() { return 0; }
relay_menu_empty_state() { return 1; }
relay_add() {
    printf 'RELAY_ADD_INPUT\n'
    ask string local_port '输入监听端口:'
    printf '%s' "$local_port" >"$case_dir/relay-created"
}
relay_delete() {
    printf 'RELAY_CONFIRM_INPUT\n'
    confirm_action '确认删除端口转发' || return 1
    printf 'deleted' >"$case_dir/relay-deleted"
}

service_action_result() { printf '%s' "$1" >"$case_dir/service-applied"; }
update() { printf '%s' "$1" >"$case_dir/update-applied"; }
_try_enable_bbr() { printf 'applied' >"$case_dir/bbr-applied"; }
block_cn_is_enabled() { return 1; }
block_cn_status_text() { printf '未启用'; }
block_cn_menu_toggle() { printf 'applied' >"$case_dir/block-cn-applied"; }
dns_set() {
    printf 'DNS_INPUT\n'
    ask string is_dns_use '请输入 DNS:'
    menu_system_impact "DNS 配置：$is_dns_use" '更新运行时 DNS 配置并重启 sing-box' '是' : || return 1
    printf '%s' "$is_dns_use" >"$case_dir/dns-created"
}

manage() {
    printf '%s\n' "$*" >>"$case_dir/manage-effects"
}
log_limit_remove() {
    printf 'removed\n' >"$case_dir/logs-removed"
}
is_caddy=
is_core=sing-box
is_systemd=
is_openrc=
is_sh_dir=$case_dir/apps
installer_marker=$case_dir/installer-ran
mkdir -p "$is_sh_dir/core" "$is_sh_dir/log"
printf 'core\n' >"$is_sh_dir/sing-box"
printf '#!/usr/bin/env bash\nprintf installed > %q\n' "$installer_marker" >"$is_sh_dir/install.sh"

case $SCENARIO in
node-inputs)
    node_menu
    ;;
node-free-text)
    add
    printf 'NODE_ADD_RETURNED\n'
    ;;
node-delete-confirm)
    printf 'NODE_DELETE_CONFIRM_INPUT\n'
    is_config_file=node.json
    is_config_name=测试节点
    mkdir -p "$is_conf_dir"
    printf '{}\n' >"$is_conf_dir/$is_config_file"
    run_interactive_operation delete_node_scenario
    printf 'NODE_DELETE_RETURNED\n'
    ;;
relay-add)
    relay_menu
    ;;
relay-confirm)
    relay_menu
    ;;
uninstall-confirm)
    printf 'UNINSTALL_CONFIRM_INPUT\n'
    is_core_dir=$is_sh_dir/core
    is_log_dir=$is_sh_dir/log
    is_sh_bin=$is_sh_dir/sing-box
    run_interactive_operation uninstall
    printf 'UNINSTALL_RETURNED\n'
    ;;
reinstall-confirm)
    printf 'REINSTALL_CONFIRM_INPUT\n'
    is_core_dir=$is_sh_dir/core
    is_log_dir=$is_sh_dir/log
    is_sh_bin=$is_sh_dir/sing-box
    run_interactive_operation get reinstall
    printf 'REINSTALL_RETURNED\n'
    ;;
kernel-log)
    touch "$is_log_dir/access.log"
    service_menu
    ;;
system-input)
    system_tools_menu
    ;;
system-impact-bbr)
    system_tools_menu
    ;;
system-impact-dns)
    system_tools_menu
    ;;
system-impact-update)
    is_caddy=1
    update_menu
    ;;
system-impact-stop)
    service_menu
    ;;
system-impact-restart)
    service_menu
    ;;
started-operation)
    write_operation() {
        printf 'WRITE_START\n'
        sleep 0.5
        printf 'WRITE_DONE\n'
        printf 'written' >"$case_dir/write-complete"
    }
    run_interactive_operation write_operation
    printf 'OPERATION_RETURNED\n'
    ;;
cli-ask)
    printf 'CLI_ASK\n'
    ask string cli_name '输入节点名称:'
    printf 'CLI_AFTER\n'
    ;;
main-menu)
    is_main_menu
    ;;
timeout-cleanup)
    trap '' TERM
    while :; do
        sleep 0.01
    done
    ;;
*)
    printf 'UNKNOWN_SCENARIO\n' >&2
    exit 64
    ;;
esac
HARNESS
chmod +x "$harness"

for core_file in "$repo_root/core.sh" "$repo_root/src/core.sh"; do
    [ -f "$core_file" ] || fail "missing implementation: $core_file"
done

python3 - "$harness" "$repo_root" "$workdir" <<'PY' || exit 1
import errno
import os
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time

harness, repo_root, workdir = sys.argv[1:]
OUTPUT_LIMIT = 64 * 1024
RUN_TIMEOUT = 8.0
ANSI_RE = __import__("re").compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]")


class PtyProcess:
    def __init__(self, scenario, core_file, timeout=RUN_TIMEOUT):
        self.scenario = scenario
        self.timeout = timeout
        self.case_dir = tempfile.mkdtemp(prefix="tests-terminal-case-", dir=workdir)
        env = os.environ.copy()
        env.update({"TERM": "xterm", "LC_ALL": "C.UTF-8", "SCENARIO": scenario})
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe(
                "bash",
                ["bash", harness, core_file, f"{repo_root}/src/log.sh", scenario, self.case_dir],
                env,
            )
        self.pid = pid
        self.fd = fd
        self.pgid = pid
        self.output = bytearray()
        self.cursor = 0
        self.deadline = time.monotonic() + timeout

    def _read(self, wait):
        ready, _, _ = select.select([self.fd], [], [], max(0, wait))
        if not ready:
            return False
        try:
            chunk = os.read(self.fd, 4096)
        except OSError as exc:
            if exc.errno == errno.EIO:
                return False
            raise
        if not chunk:
            return False
        self.output.extend(chunk)
        if len(self.output) > OUTPUT_LIMIT:
            raise AssertionError(f"{self.scenario}: output exceeded {OUTPUT_LIMIT} bytes")
        return True

    def text(self):
        return ANSI_RE.sub(b"", bytes(self.output)).decode(errors="replace")

    def expect(self, needle):
        encoded = needle.encode()
        while True:
            found = bytes(self.output).find(encoded, self.cursor)
            if found >= 0:
                self.cursor = found + len(encoded)
                return self
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"{self.scenario}: timed out waiting for {needle!r}\n{self.text()}")
            if not self._read(min(remaining, 0.1)):
                done, status = os.waitpid(self.pid, os.WNOHANG)
                if done:
                    raise AssertionError(
                        f"{self.scenario}: process exited before {needle!r} (status {os.waitstatus_to_exitcode(status)})\n{self.text()}"
                    )
        return self

    def send(self, value):
        if value == b"\x03":
            time.sleep(0.05)
        os.write(self.fd, value)
        return self

    def expect_exit(self):
        while True:
            done, status = os.waitpid(self.pid, os.WNOHANG)
            if done:
                self.assert_group_clean()
                return os.waitstatus_to_exitcode(status)
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"{self.scenario}: timed out waiting for process exit\n{self.text()}")
            self._read(min(remaining, 0.1))

    def assert_group_clean(self):
        try:
            os.killpg(self.pgid, 0)
        except ProcessLookupError:
            return
        except PermissionError:
            pass
        members = []
        for name in os.listdir("/proc"):
            if not name.isdigit():
                continue
            try:
                with open(f"/proc/{name}/stat", encoding="ascii") as stream:
                    fields = stream.read().split()
            except OSError:
                continue
            if len(fields) > 4 and fields[4] == str(self.pgid):
                members.append(f"{name}:{' '.join(fields[1:5])}")
        raise AssertionError(f"{self.scenario}: process group {self.pgid} leaked after exit ({members})")

    def cleanup(self):
        try:
            os.killpg(self.pgid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.pid, os.WNOHANG)
            time.sleep(0.05)
        except ChildProcessError:
            pass
        try:
            os.killpg(self.pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass


def run_case(name, core_file, steps):
    proc = PtyProcess(name, core_file)
    try:
        for step in steps:
            if isinstance(step, str):
                proc.expect(step)
            else:
                proc.send(step)
        status = proc.expect_exit()
        proc.close()
        return proc, status
    except BaseException:
        proc.cleanup()
        raise


def assert_no_file(path, message):
    if os.path.exists(path):
        raise AssertionError(message)


def assert_file_value(path, value, message):
    try:
        with open(path, encoding="utf-8") as stream:
            actual = stream.read()
    except FileNotFoundError:
        raise AssertionError(message + " (file missing)")
    if actual != value:
        raise AssertionError(message + f" (expected {value!r}, got {actual!r})")


def probe_timeout_cleanup(core_file):
    proc = PtyProcess("timeout-cleanup", core_file, timeout=0.35)
    try:
        try:
            proc.expect_exit()
        except AssertionError:
            pass
        else:
            raise AssertionError("timeout-cleanup: stubborn process unexpectedly exited")
    finally:
        proc.cleanup()
    if os.path.isdir(f"/proc/{proc.pid}"):
        raise AssertionError("timeout-cleanup: process remained after process-group cleanup")


def verify_system_impact_cancel(name, core_file, choice, page_text, menu_prompt, effect_name, send_before_page=None):
    steps = [menu_prompt, choice]
    if send_before_page is not None:
        steps.extend(send_before_page)
    steps.extend([page_text, b"\x03", "已取消当前操作", "按回车返回菜单。", b"\n", menu_prompt, b"0\n"])
    proc, status = run_case(name, core_file, steps)
    if status not in (0, 2):
        raise AssertionError(f"{name}: confirmation cancellation did not return to the menu (status {status})\n{proc.text()}")
    assert_no_file(os.path.join(proc.case_dir, effect_name), f"{name}: Ctrl+C executed the confirmed action")


def verify(core_file):
    case = os.path.join(workdir, os.path.basename(os.path.dirname(core_file)) + "-" + os.path.basename(core_file))
    proc, status = run_case(
        "node-inputs",
        core_file,
        ["请选择节点操作", b"1\n", "NODE_ADD_INPUT", "输入节点名称:", b"\x03", "已取消当前操作", b"\n", "请选择节点操作", b"2\n", "NODE_CHANGE_INPUT", "输入新节点名称:", b"\x03", "已取消当前操作", b"\n", "请选择节点操作", b"0\n"],
    )
    if status != 0:
        raise AssertionError(f"node-inputs: menu did not exit normally after return (status {status})\n{proc.text()}")
    assert_no_file(os.path.join(proc.case_dir, "node-name"), "node-inputs: Ctrl+C created a node name")
    assert_no_file(os.path.join(proc.case_dir, "change-name"), "node-inputs: Ctrl+C modified a node name")

    proc, status = run_case(
        "relay-add",
        core_file,
        ["请选择端口转发操作", b"1\n", "RELAY_ADD_INPUT", "输入监听端口:", b"\x03", "已取消当前操作", b"\n", "请选择端口转发操作", b"0\n"],
    )
    if status != 0:
        raise AssertionError(f"relay-add: menu did not exit normally after return (status {status})\n{proc.text()}")
    assert_no_file(os.path.join(proc.case_dir, "relay-created"), "relay-add: Ctrl+C created a forwarding rule")

    proc, status = run_case(
        "relay-confirm",
        core_file,
        ["请选择端口转发操作", b"4\n", "RELAY_CONFIRM_INPUT", "确认删除端口转发", b"\x03", "已取消当前操作", b"\n", "请选择端口转发操作", b"0\n"],
    )
    if status != 0:
        raise AssertionError(f"relay-confirm: menu did not exit normally after return (status {status})\n{proc.text()}")
    assert_no_file(os.path.join(proc.case_dir, "relay-deleted"), "relay-confirm: Ctrl+C executed the confirmed action")

    proc, status = run_case(
        "node-delete-confirm",
        core_file,
        ["NODE_DELETE_CONFIRM_INPUT", "测试节点", "node.json", "删除范围包括该节点的配置", b"\x03", "已取消当前操作", b"\n", "NODE_DELETE_RETURNED"],
    )
    if status != 0:
        raise AssertionError(f"node-delete-confirm: process did not return normally (status {status})\n{proc.text()}")
    assert_no_file(os.path.join(proc.case_dir, "node-deleted"), "node-delete-confirm: Ctrl+C deleted the node")

    proc, status = run_case(
        "uninstall-confirm",
        core_file,
        ["UNINSTALL_CONFIRM_INPUT", "sing-box 程序、服务和配置", "Caddy 未安装", b"\x03", "已取消当前操作", b"\n", "UNINSTALL_RETURNED"],
    )
    if status != 0:
        raise AssertionError(f"uninstall-confirm: process did not return normally (status {status})\n{proc.text()}")
    assert_no_file(os.path.join(proc.case_dir, "manage-effects"), "uninstall-confirm: Ctrl+C changed service state")
    assert_no_file(os.path.join(proc.case_dir, "logs-removed"), "uninstall-confirm: Ctrl+C removed logs")
    if not os.path.isdir(os.path.join(proc.case_dir, "apps", "core")):
        raise AssertionError("uninstall-confirm: Ctrl+C removed the core directory")

    proc, status = run_case(
        "reinstall-confirm",
        core_file,
        ["REINSTALL_CONFIRM_INPUT", "sing-box 程序、服务和配置", b"\x03", "已取消当前操作", b"\n", "REINSTALL_RETURNED"],
    )
    if status != 0:
        raise AssertionError(f"reinstall-confirm: process did not return normally (status {status})\n{proc.text()}")
    assert_no_file(os.path.join(proc.case_dir, "installer-ran"), "reinstall-confirm: Ctrl+C ran the installer")
    assert_no_file(os.path.join(proc.case_dir, "manage-effects"), "reinstall-confirm: Ctrl+C changed service state")

    proc, status = run_case(
        "kernel-log",
        core_file,
        ["请选择服务操作", b"5\n", "按 Ctrl+C", b"\x03", "请选择服务操作", b"0\n"],
    )
    if status != 0:
        raise AssertionError(f"kernel-log: panel did not return to the kernel menu (status {status})\n{proc.text()}")

    proc, status = run_case(
        "system-input",
        core_file,
        ["请选择系统设置", b"2\n", "DNS_INPUT", "请输入 DNS:", b"\x03", "已取消当前操作", b"\n", "请选择系统设置", b"0\n"],
    )
    if status != 0:
        raise AssertionError(f"system-input: menu did not exit normally after return (status {status})\n{proc.text()}")
    assert_no_file(os.path.join(proc.case_dir, "dns-created"), "system-input: Ctrl+C changed DNS")

    verify_system_impact_cancel(
        "system-impact-bbr",
        core_file,
        b"1\n",
        "操作对象：系统内核拥塞控制（BBR）",
        "请选择系统设置",
        "bbr-applied",
    )
    verify_system_impact_cancel(
        "system-impact-dns",
        core_file,
        b"2\n",
        "操作对象：DNS 配置：1.1.1.1",
        "请选择系统设置",
        "dns-created",
        send_before_page=["请输入 DNS:", b"1.1.1.1\n"],
    )
    verify_system_impact_cancel(
        "system-impact-update",
        core_file,
        b"1\n",
        "操作对象：sing-box 内核",
        "请选择要更新的软件",
        "update-applied",
    )
    verify_system_impact_cancel(
        "system-impact-stop",
        core_file,
        b"3\n",
        "操作对象：sing-box 内核服务（停止）",
        "请选择服务操作",
        "service-applied",
    )
    verify_system_impact_cancel(
        "system-impact-restart",
        core_file,
        b"4\n",
        "操作对象：sing-box 内核服务（重启）",
        "请选择服务操作",
        "service-applied",
    )

    proc, status = run_case(
        "started-operation",
        core_file,
        ["WRITE_START", b"\x03", "WRITE_DONE", "OPERATION_RETURNED"],
    )
    if status != 0:
        raise AssertionError(f"started-operation: write process was interrupted (status {status})\n{proc.text()}")
    assert_file_value(
        os.path.join(proc.case_dir, "write-complete"),
        "written",
        "started-operation: Ctrl+C interrupted an operation that had started writing",
    )
    if "已取消当前操作" in proc.text():
        raise AssertionError(f"started-operation: Ctrl+C incorrectly reported cancellation\n{proc.text()}")

    proc, status = run_case(
        "cli-ask",
        core_file,
        ["CLI_ASK", "输入节点名称:", b"\x03"],
    )
    if status not in (130, -signal.SIGINT):
        raise AssertionError(f"cli-ask: CLI input should keep default SIGINT behavior, got status {status}\n{proc.text()}")
    if "已取消当前操作" in proc.text():
        raise AssertionError(f"cli-ask: CLI input unexpectedly enabled menu cancellation\n{proc.text()}")

    proc, status = run_case(
        "node-free-text",
        core_file,
        ["NODE_ADD_INPUT", "输入节点名称:", b"0\n", "NODE_ADD_RETURNED"],
    )
    if status != 0:
        raise AssertionError(f"node-free-text: process failed (status {status})\n{proc.text()}")
    assert_file_value(os.path.join(proc.case_dir, "node-name"), "0", "node-free-text: 0 must remain a valid node name")

    proc, status = run_case(
        "main-menu",
        core_file,
        ["q 退出", b"\x03"],
    )
    if status not in (130, -signal.SIGINT):
        raise AssertionError(f"main-menu: Ctrl+C should exit the panel, got status {status}\n{proc.text()}")

    probe_timeout_cleanup(core_file)


for core_file in (f"{repo_root}/core.sh", f"{repo_root}/src/core.sh"):
    verify(core_file)

print("PASS: PTY Ctrl+C cancellation, system confirmations, started work, CLI SIGINT, free text, log return, main exit, timeout, and process-group cleanup")
PY

echo 'PASS: terminal Ctrl+C process tests'
