#!/usr/bin/env bash
set -uo pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

layout_dir=$(mktemp -d)
trap 'rm -rf "$layout_dir"' EXIT

# Repository layout: only src/core.sh may remain as the management script source.
if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tracked_paths=$(git -C "$repo_root" ls-files)
else
    # The isolated test environment receives a source archive without .git metadata.
    tracked_paths=$(cd "$repo_root" && find . -type f -not -path './.git/*' | sed 's|^\./||')
fi
grep -Fxq 'core.sh' <<<"$tracked_paths" && fail 'repository root core.sh is still tracked'
grep -Fxq 'code.tar.gz' <<<"$tracked_paths" && fail 'stale repository root code.tar.gz is still tracked'
core_paths=$(grep -E '(^|/)core\.sh$' <<<"$tracked_paths" || true)
[[ $core_paths == 'src/core.sh' ]] || fail "management script source must be uniquely src/core.sh (found: ${core_paths:-none})"
if backup_paths=$(grep -E '(^|/)core\.sh\.(bak|orig|old|save)$' <<<"$tracked_paths"); then
    fail "management script backup copies are still present: $backup_paths"
fi
if checksum_paths=$(grep -E '(^|/)(core\.sha256|core\.sh\.sha256|core\.sh\.md5)$' <<<"$tracked_paths"); then
    fail "dual-file checksum artifacts are still present: $checksum_paths"
fi

# Release package layout: build a temporary archive from the workflow's own file list.
package_command=$(sed -n 's/^[[:space:]]*tar zcvf \.release-artifacts\/code\.tar\.gz \(.*\)$/\1/p' "$repo_root/.github/workflows/release.yml")
[[ -n $package_command ]] || fail 'release workflow is missing the code.tar.gz packaging command'
read -r -t 1 -a package_files <<<"$package_command"
for package_file in "${package_files[@]}"; do
    [[ ${package_file#./} == 'core.sh' ]] && fail 'release packaging still includes the legacy root core.sh'
done
tar czf "$layout_dir/code.tar.gz" -C "$repo_root" "${package_files[@]}" || fail 'temporary release archive failed'
package_members=$(tar tzf "$layout_dir/code.tar.gz")
grep -Fxq 'src/core.sh' <<<"$package_members" || fail 'release archive omitted src/core.sh'
package_core_members=$(grep -E '(^|/)core\.sh$' <<<"$package_members" || true)
[[ $package_core_members == 'src/core.sh' ]] || fail "release archive management script must be uniquely src/core.sh (found: ${package_core_members:-none})"
grep -Fq 'files: .release-artifacts/code.tar.gz' "$repo_root/.github/workflows/release.yml" || fail 'release asset is no longer named code.tar.gz'

# The local-install integrity check must keep requiring src/core.sh and the entry script only.
grep -Fq '[[ ! -f ${PWD}/src/core.sh || ! -f ${PWD}/$is_core.sh ]]' "$repo_root/install.sh" || fail 'install.sh local-install integrity check changed'
if grep -Fq '${PWD}/core.sh' "$repo_root/install.sh"; then
    fail 'install.sh local-install still requires the legacy root core.sh'
fi

for file in README.md docs/usage.md src/help.sh src/core.sh src/relay.sh skills/devops/singbox-noninteractive-operations/scripts/singbox_inventory.sh; do
    if legacy=$(grep -n '端口中转' "$repo_root/$file"); then
        fail "$file still contains the deprecated term: $legacy"
    fi
done

for file in README.md docs/usage.md src/help.sh src/core.sh src/relay.sh skills/devops/singbox-noninteractive-operations/scripts/singbox_inventory.sh; do
    if legacy=$(grep -n '中转' "$repo_root/$file"); then
        fail "$file still mixes relay wording: $legacy"
    fi
    grep -q '端口转发' "$repo_root/$file" || fail "$file does not describe 端口转发"
done

grep -Fq '**端口转发**' "$repo_root/GLOSSARY.md" || fail 'GLOSSARY.md is missing the 端口转发 definition'
grep -Fq 'Title: "节点出站与端口转发"' "$repo_root/assets/readme/source/imagegen-prompts.md" || fail 'capabilities prompt title is missing 端口转发'
grep -Fq 'Lower lane heading: "端口转发"' "$repo_root/assets/readme/source/imagegen-prompts.md" || fail 'capabilities prompt lane heading is missing 端口转发'
if legacy=$(grep -n '中转' "$repo_root/assets/readme/source/imagegen-prompts.md"); then
    fail "capabilities prompt still contains the deprecated term: $legacy"
fi

technical_doc="$repo_root/docs/adr/0002-node-default-outbound-and-block-cn.md"
first_term=$(grep -nE '端口转发|端口中转' "$technical_doc" | head -n 1)
[[ $first_term == *'端口转发（Relay）'* ]] || fail "technical document must introduce 端口转发（Relay） first: $first_term"
[[ $(grep -c '端口转发（Relay）' "$technical_doc") == 1 ]] || fail 'technical document must use Relay only at the first mention'
if legacy=$(grep -n '端口中转' "$technical_doc"); then
    fail "technical document still contains the deprecated term: $legacy"
fi

help_output=$(
    cd "$repo_root" || exit 1
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
    set +u
    show_help ''
)
[[ $help_output == *'relay add [local-port] [remote-addr] [remote-port] [note]'* ]] || fail 'help is missing the relay add syntax'
[[ $help_output == *'relay list'* && $help_output == *'relay info [local-port]'* && $help_output == *'relay note [local-port] [备注内容 | --clear]'* && $help_output == *'relay delete [local-port]'* ]] || fail 'help is missing a relay subcommand'
[[ $help_output == *'端口转发'* ]] || fail 'help does not use 端口转发'
[[ $help_output != *'中转'* ]] || fail "help still mixes relay wording: $help_output"

run_cli_case() {
    local repo_dir=$1
    REPO_ROOT="$repo_dir" bash <<'CASE' || exit 1
set -uo pipefail

fail() {
    echo "FAIL(entry): $*" >&2
    exit 1
}

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
root="$case_dir/root"
sh_dir="$root/etc/sing-box/sh"
entry="$sh_dir/sing-box.sh"

mkdir -p "$sh_dir/src" "$root/etc/sing-box/bin" "$root/etc/sing-box/conf/.quan-meta" \
    "$root/usr/local/bin" "$root/var/log/sing-box" "$case_dir/bin"
cp -R "$REPO_ROOT/src/." "$sh_dir/src/"
cp "$REPO_ROOT/sing-box.sh" "$entry"
sed -i "s|^\. /etc/sing-box/sh/src/init.sh$|. $sh_dir/src/init.sh|" "$entry"
sed -i \
    -e "s|^is_core_dir=/etc/|is_core_dir=$root/etc/|" \
    -e "s|^is_log_dir=/var/log/|is_log_dir=$root/var/log/|" \
    -e "s|^is_sh_bin=/usr/local/bin/|is_sh_bin=$root/usr/local/bin/|" \
    -e "s|^is_caddy_dir=/etc/caddy$|is_caddy_dir=$root/etc/caddy|" \
    "$sh_dir/src/init.sh"
chmod +x "$entry"

cat >"$root/etc/sing-box/bin/sing-box" <<'FAKE_CORE'
#!/usr/bin/env bash
[[ $1 == version ]] && printf 'sing-box version 1.14.4\n'
exit 0
FAKE_CORE
cat >"$case_dir/bin/apt-get" <<'FAKE_APT'
#!/usr/bin/env bash
exit 0
FAKE_APT
cat >"$case_dir/bin/systemctl" <<'FAKE_SYS'
#!/usr/bin/env bash
[[ $1 == is-active ]] && printf 'active\n'
exit 0
FAKE_SYS
chmod +x "$root/etc/sing-box/bin/sing-box" "$case_dir/bin/apt-get" "$case_dir/bin/systemctl"
touch "$root/etc/sing-box/qrcode-dependency-checked" "$root/etc/sing-box/bin/tls.cer" "$root/etc/sing-box/bin/tls.key"
printf '200\n' >"$root/etc/sing-box/log-limit-mb"

is_conf_dir="$root/etc/sing-box/conf"

output=$(PATH="$case_dir/bin:$PATH" bash "$entry" relay list)
[[ $output == $'\n当前未配置任何端口转发.' ]] || fail "empty relay list output changed: $output"
[[ $output != *'中转'* ]] || fail "empty relay list still mixes wording: $output"
[[ $output != *'按回车返回'* ]] || fail 'relay list CLI must not pause'

error_output=$(PATH="$case_dir/bin:$PATH" bash "$entry" relay unknown 2>&1)
status=$?
[[ $status != 0 ]] || fail 'unknown relay subcommand must still fail'
[[ $error_output == *'端口转发'* ]] || fail "relay error should use 端口转发: $error_output"
[[ $error_output != *'中转'* ]] || fail "relay error still mixes wording: $error_output"
[[ $error_output == *'relay [add|list|info|note|delete]'* ]] || fail "relay command syntax changed: $error_output"
[[ $error_output != *'按回车返回'* ]] || fail 'relay error CLI must not pause'

cat >"$is_conf_dir/relay-10000.json" <<'JSON'
{"inbounds":[{"tag":"relay-10000.json","type":"direct","listen_port":10000,"override_address":"203.0.113.60","override_port":20060}]}
JSON
jq -e '.inbounds[0] | .tag == "relay-10000.json" and .type == "direct" and .listen_port == 10000 and .override_address == "203.0.113.60" and .override_port == 20060' "$is_conf_dir/relay-10000.json" >/dev/null || fail 'relay compatibility fields changed'

cli_list=$(PATH="$case_dir/bin:$PATH" bash "$entry" relay list)
[[ $cli_list == *'端口转发列表'* && $cli_list == *'共 1 个端口转发'* && $cli_list == *'端口转发没有身份验证'* ]] || fail "CLI relay list wording changed: $cli_list"
[[ $cli_list == *'监听端口 10000 -> 目标 203.0.113.60:20060 (TCP/UDP)'* ]] || fail "CLI relay list machine fields changed: $cli_list"
[[ $cli_list != *'中转'* ]] || fail "CLI relay list still mixes wording: $cli_list"
[[ $cli_list != *'按回车返回'* ]] || fail 'CLI relay list with entries must not pause'

cli_info=$(PATH="$case_dir/bin:$PATH" bash "$entry" relay info 10000)
[[ $cli_info == *'端口转发配置信息'* && $cli_info == *'类型: TCP/UDP 端口转发'* && $cli_info == *'监听端口: 10000'* && $cli_info == *'目标地址: 203.0.113.60'* && $cli_info == *'目标端口: 20060'* ]] || fail "CLI relay info compatibility fields changed: $cli_info"
[[ $cli_info != *'中转'* ]] || fail "CLI relay info still mixes wording: $cli_info"
[[ $cli_info != *'按回车返回'* ]] || fail 'CLI relay info must not pause'

interactive_list=$(printf '2\n2\n1\n\n0\nq\n' | PATH="$case_dir/bin:$PATH" bash "$entry" 2>&1)
[[ $interactive_list == *'请选择要查看的端口转发'* && $interactive_list == *'监听端口 10000 -> 目标 203.0.113.60:20060 (TCP/UDP)'* && $interactive_list == *'端口转发没有身份验证'* ]] || fail "interactive relay view wording changed: $interactive_list"
[[ $interactive_list != *'中转'* ]] || fail "interactive relay view still contains 中转: $interactive_list"
CASE
}

run_cli_case "$repo_root"

printf 'PASS: terminology and relay CLI compatibility\n'
