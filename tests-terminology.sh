#!/usr/bin/env bash
set -uo pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for file in README.md docs/usage.md src/help.sh core.sh src/core.sh; do
    if legacy=$(grep -n '端口中转' "$repo_root/$file"); then
        fail "$file still contains the deprecated term: $legacy"
    fi
done

for file in README.md docs/usage.md src/help.sh; do
    if legacy=$(grep -n '中转' "$repo_root/$file"); then
        fail "$file still mixes relay wording: $legacy"
    fi
    grep -q '端口转发' "$repo_root/$file" || fail "$file does not describe 端口转发"
done

grep -Fq '**端口转发**' "$repo_root/GLOSSARY.md" || fail 'GLOSSARY.md is missing the 端口转发 definition'

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
[[ $help_output == *'relay add [local-port] [remote-addr] [remote-port]'* ]] || fail 'help is missing the relay add syntax'
[[ $help_output == *'relay list'* && $help_output == *'relay info [local-port]'* && $help_output == *'relay delete [local-port]'* ]] || fail 'help is missing a relay subcommand'
[[ $help_output == *'端口转发'* ]] || fail 'help does not use 端口转发'
[[ $help_output != *'中转'* ]] || fail "help still mixes relay wording: $help_output"

run_cli_case() {
    local core_file=$1
    CORE_FILE="$core_file" bash <<'CASE' || exit 1
set -uo pipefail

fail() {
    echo "FAIL(${CORE_FILE}): $*" >&2
    exit 1
}

source <(sed -n '/^relay_list() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_warn_security() {/,/^}/p' "$CORE_FILE")
source <(sed -n '/^relay_main() {/,/^}/p' "$CORE_FILE")
msg() { printf '%b\n' "$*"; }
err() { printf '%s\n' "$*"; return 1; }
warn() { printf '%s\n' "$*"; }

case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
is_conf_dir=$case_dir/conf
mkdir -p "$is_conf_dir"
is_main_start=
is_core=sb

output=$(relay_main list)
[[ $output == $'\n当前未配置任何中转.' ]] || fail "relay list output changed: $output"
[[ $output != *'按回车返回'* ]] || fail 'relay list CLI must not pause'

error_output=$(relay_main unknown 2>&1)
status=$?
[[ $status != 0 ]] || fail 'unknown relay subcommand must still fail'
[[ $error_output == *'端口转发'* ]] || fail "relay error should use 端口转发: $error_output"
[[ $error_output != *'中转'* ]] || fail "relay error still mixes wording: $error_output"
[[ $error_output == *'relay [add|list|info|delete]'* ]] || fail "relay command syntax changed: $error_output"
[[ $error_output != *'按回车返回'* ]] || fail 'relay error CLI must not pause'

cat >"$is_conf_dir/relay-10000.json" <<'JSON'
{"inbounds":[{"listen_port":10000,"override_address":"203.0.113.60","override_port":20060}]}
JSON

cli_list=$(relay_main list)
[[ $cli_list == *'中转列表'* && $cli_list == *'共 1 个中转'* && $cli_list == *'中转没有身份验证'* ]] || fail "CLI relay list output changed: $cli_list"
[[ $cli_list != *'端口转发'* ]] || fail "CLI relay list output changed to interactive wording: $cli_list"
[[ $cli_list != *'按回车返回'* ]] || fail 'CLI relay list with entries must not pause'

is_main_start=1
interactive_list=$(relay_list)
[[ $interactive_list == *'端口转发列表'* && $interactive_list == *'共 1 个端口转发'* && $interactive_list == *'端口转发没有身份验证'* ]] || fail "interactive relay list still mixes wording: $interactive_list"
[[ $interactive_list != *'中转'* ]] || fail "interactive relay list still contains 中转: $interactive_list"
[[ $interactive_list != *'按回车返回'* ]] || fail 'relay list must not add a new pause'
CASE
}

run_cli_case "$repo_root/core.sh"
run_cli_case "$repo_root/src/core.sh"

printf 'PASS: terminology and relay CLI compatibility\n'
