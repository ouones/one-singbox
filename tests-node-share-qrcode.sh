#!/usr/bin/env bash
set -o pipefail

repo_root=$(cd "$(dirname "$0")" && pwd)
workdir=$(mktemp -d)
cleanup() {
  local status=$?
  if [[ $status != 0 ]]; then
    for output_file in "$workdir"/*/*.out; do
      [[ -f $output_file ]] || continue
      printf '%s\n' "--- $output_file ---"
      cat "$output_file"
    done
  fi
  rm -rf "$workdir"
}
trap cleanup EXIT

mkdir -p "$workdir/bin"
cat >"$workdir/bin/qrencode" <<'FAKE_QRENCODE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$QR_LOG"
if [[ ${QR_FIXTURE:-} == native ]]; then
  printf '▀ ▄    ▀ ▄      \n    ▀      ▀▄  ▄\n'
  exit "${QR_EXIT:-0}"
fi
if [[ ${2:-} == UTF8 ]]; then
  columns=57
  rows=29
else
  columns=114
  rows=57
fi
for ((row = 0; row < rows; row++)); do
  for ((column = 0; column < columns; column++)); do
    printf '█'
  done
  printf '\n'
done
exit "${QR_EXIT:-0}"
FAKE_QRENCODE
chmod +x "$workdir/bin/qrencode"
cat >"$workdir/bin/apt-get" <<'FAKE_PACKAGE_MANAGER'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$QR_PACKAGE_LOG"
FAKE_PACKAGE_MANAGER
chmod +x "$workdir/bin/apt-get"
fail() {
  echo "FAIL: $1"
  exit 1
}

run_core_case() {
  local core_file=$1 case_name=$2
  CORE_FILE="$core_file" CASE_NAME="$case_name" CASE_DIR="$workdir/$case_name" QR_BIN="$workdir/bin" bash <<'CASE' || exit 1
set -o pipefail

fail() {
  echo "FAIL(${CORE_FILE}): $1"
  exit 1
}

expect_qr_args() {
  local expected_url=$1
  [[ -f $QR_LOG ]] || fail "qrencode was not called"
  local qr_args=()
  mapfile -t qr_args <"$QR_LOG"
  [[ ${#qr_args[@]} == 3 ]] || fail "qrencode expected exactly three arguments, got ${#qr_args[@]}"
  [[ ${qr_args[0]} == -t && ${qr_args[1]} == UTF8 ]] || fail "qrencode options changed: ${qr_args[*]}"
  [[ ${qr_args[2]} == "$expected_url" ]] || fail "qrencode input differs from the displayed URL"
}

stty() {
  [[ ${TEST_TTY_SIZE:-} ]] || return 1
  printf '%s\n' "$TEST_TTY_SIZE"
}

type() {
  if [[ ${QR_MISSING:-} && $1 == -P && $2 == qrencode ]]; then
    return 0
  fi
  builtin type "$@"
}

export PATH="$QR_BIN:$PATH"
export QR_PACKAGE_LOG="$CASE_DIR/packages.log"
source "$CORE_FILE"
full_qr_cell='█'
TEST_TTY_SIZE='40 80'
case_dir=$CASE_DIR
mkdir -p "$case_dir/conf/.quan-meta"
export QR_LOG="$case_dir/qr-args.log"
is_conf_dir="$case_dir/conf"
is_config_json="$case_dir/config.json"
is_core_bin=/bin/true
is_core_ver=1.14.0
is_dont_get_ip=1
is_dont_auto_exit=
is_dont_show_info=
is_gen=
ip=203.0.113.10
is_config_file=
is_config_name=
is_new_protocol=
is_protocol=
net=
is_main_start=
is_change=
manage_log="$case_dir/manage.log"
: >"$manage_log"
manage() { printf '%s\n' "$*" >>"$manage_log"; }
is_port_used() { return 1; }
printf '%s\n' '{"outbounds":[{"tag":"direct","type":"direct"}],"route":{"rules":[]}}' >"$is_config_json"

# Creation and automatic details share the existing add -> info flow.
unset is_config_file is_config_name is_new_protocol is_protocol net port uuid password ss_password ss_method
add ss 41601 'p@ss:#/雪' aes-128-gcm >"$case_dir/add.out" 2>&1 || fail "SS node creation should succeed"
wait
expected_url=$is_url
[[ $expected_url == ss://* ]] || fail "created SS node should expose its original URL"
[[ $(<"$case_dir/add.out") == *"$expected_url"* ]] || fail "creation output should retain the original URL"
expect_qr_args "$expected_url"
[[ $(<"$case_dir/add.out") == *"$full_qr_cell"* ]] || fail "creation should render the QR code"
[[ $(grep -c '^' "$manage_log") == 1 ]] || fail "successful creation should perform its existing single restart"

# QR failures must not turn a successful create into a failure or trigger another restart.
before_restarts=$(grep -c '^' "$manage_log")
rm -f "$QR_LOG"
(
  unset is_config_file is_config_name is_new_protocol is_protocol net net_type port uuid password ss_password ss_method json_str is_url
  QR_EXIT=23 add ss 41604 'test-failure-password' aes-128-gcm || exit 1
  printf '%s\n' "$is_url" >"$case_dir/add-failure-url.txt"
) >"$case_dir/add-failure.out" 2>&1 || fail "qrencode failure must not fail node creation"
wait
failure_url=$(<"$case_dir/add-failure-url.txt")
[[ $(<"$case_dir/add-failure.out") == *"二维码生成失败"* && $(<"$case_dir/add-failure.out") == *"$failure_url"* ]] || fail "creation should report QR failure and retain URL"
[[ -f "$is_conf_dir/Shadowsocks-41604.json" ]] || fail "qrencode failure must not remove the created node"
[[ $(grep -c '^' "$manage_log") == $((before_restarts + 1)) ]] || fail "QR failure must not trigger an extra service operation"

before_restarts=$(grep -c '^' "$manage_log")
rm -f "$QR_LOG"
(
  unset is_config_file is_config_name is_new_protocol is_protocol net net_type port uuid password ss_password ss_method json_str is_url
  QR_MISSING=1 add ss 41605 'test-missing-password' aes-128-gcm || exit 1
  printf '%s\n' "$is_url" >"$case_dir/add-missing-url.txt"
) >"$case_dir/add-missing.out" 2>&1 || fail "missing qrencode must not fail node creation"
wait
missing_url=$(<"$case_dir/add-missing-url.txt")
[[ $(<"$case_dir/add-missing.out") == *"qrencode"* && $(<"$case_dir/add-missing.out") == *"$missing_url"* ]] || fail "creation should show install guidance and retain URL"
[[ ! -f $QR_LOG && -f "$is_conf_dir/Shadowsocks-41605.json" ]] || fail "missing qrencode must not block node creation"
[[ $(grep -c '^' "$manage_log") == $((before_restarts + 1)) ]] || fail "missing qrencode must not trigger an extra service operation"
QR_MISSING=

# A visible info call for a node with special characters and IPv6 passes one exact URL argument.
cat >"$is_conf_dir/special.json" <<'NODE'
{"inbounds":[{"tag":"special.json","type":"shadowsocks","listen":"::","listen_port":41602,"method":"aes-128-gcm","password":"p@ss:#/雪"}]}
NODE
meta_set special.json node_name '二维码%20node'
meta_set special.json entry_addr '2001:db8::10'
rm -f "$QR_LOG"
info special.json >"$case_dir/info.out" 2>&1 || fail "visible info should succeed"
special_url=$is_url
[[ $special_url == *"@[2001:db8::10]:41602#二维码%20node" ]] || fail "special IPv6 URL should preserve existing formatting: $special_url"
[[ $(<"$case_dir/info.out") == *"$special_url"* ]] || fail "info output should include its original URL"
expect_qr_args "$special_url"
[[ $(<"$case_dir/info.out") == *"$full_qr_cell"* ]] || fail "info should render the QR code"

# A narrow terminal must not display a QR code that would wrap across the screen.
TEST_TTY_SIZE='12 20'
rm -f "$QR_LOG"
info special.json >"$case_dir/narrow.out" 2>&1 || fail "info should remain successful when the QR code does not fit"
[[ $(<"$case_dir/narrow.out") != *"$full_qr_cell"* ]] || fail "a QR code that exceeds the terminal size must not be displayed"
[[ $(<"$case_dir/narrow.out") == *"终端空间不足"* && $(<"$case_dir/narrow.out") == *"$special_url"* ]] || fail "small terminal should explain the space limit and retain the share URL"
rm -f "$QR_LOG"
url_qr qr special.json >"$case_dir/narrow-qr-command.out" 2>&1 || fail "the independent QR command should remain successful when the QR does not fit"
[[ $(<"$case_dir/narrow-qr-command.out") != *"$full_qr_cell"* && $(<"$case_dir/narrow-qr-command.out") == *"终端空间不足"* ]] || fail "the independent QR command should skip an oversized QR with a clear message"
[[ $(<"$case_dir/narrow-qr-command.out") == *"https://233boy.github.io/tools/qr.html#$special_url"* ]] || fail "the independent QR command should retain its webpage fallback"
is_dont_show_info=

# A menu's stale COLUMNS value must not override the actual window size.
TEST_TTY_SIZE='40 80'
rm -f "$QR_LOG"
COLUMNS=1 info special.json >"$case_dir/stale-columns.out" 2>&1 || fail "info should succeed when COLUMNS is stale"
expect_qr_args "$special_url"
[[ $(<"$case_dir/stale-columns.out") == *"$full_qr_cell"* ]] || fail "stale COLUMNS must not hide a QR code that fits the terminal"

# Without a readable terminal size, omit the QR code and keep the original link visible.
TEST_TTY_SIZE=
unset -f stty
rm -f "$QR_LOG"
info special.json >"$case_dir/no-tty.out" 2>&1 || fail "info should succeed without a TTY"
[[ ! -f $QR_LOG && $(<"$case_dir/no-tty.out") != *"$full_qr_cell"* ]] || fail "a missing TTY must not invoke or display qrencode"
[[ $(<"$case_dir/no-tty.out") == *"无法读取终端尺寸"* && $(<"$case_dir/no-tty.out") == *"$special_url"* ]] || fail "no-TTY output should explain the skipped QR and retain the share URL"
stty() {
  [[ ${TEST_TTY_SIZE:-} ]] || return 1
  printf '%s\n' "$TEST_TTY_SIZE"
}
TEST_TTY_SIZE='40 80'

# The issue's long VLESS Reality URL fits when the terminal can display the native UTF8 output.
issue16_url='vless://00000000-0000-4000-8000-000000000000@203.0.113.10:40018?encryption=none&security=reality&flow=xtls-rprx-vision&type=tcp&sni=www.example.com&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&fp=chrome#TEST-NODE'
rm -f "$QR_LOG"
render_qrcode "$issue16_url" >"$case_dir/long-fit.out" 2>&1 || fail "the issue QR should fit in an 80x40 terminal"
expect_qr_args "$issue16_url"
[[ $(<"$case_dir/long-fit.out") == *"$full_qr_cell"* ]] || fail "a QR that fits should be displayed"

# A terminal that fits the compact QR but not the native output must be rejected.
TEST_TTY_SIZE='24 40'
rm -f "$QR_LOG"
render_qrcode "$issue16_url" >"$case_dir/long-mobile.out" 2>&1 && fail "the native issue QR should not fit in a 40x24 terminal"
expect_qr_args "$issue16_url"
[[ $(<"$case_dir/long-mobile.out") != *"$full_qr_cell"* && $(<"$case_dir/long-mobile.out") == *"终端空间不足"* ]] || fail "a 40x24 terminal should explain that the native QR does not fit"
# Native UTF8 output must be passed through without converting its block characters.
rm -f "$QR_LOG"
export QR_FIXTURE=native
native_qr_output=$(msg() { :; }; warn() { :; }; render_qrcode 'fixture-url') || fail "a terminal with enough space should render the native QR fixture"
unset QR_FIXTURE
expect_qr_args 'fixture-url'
[[ $native_qr_output == $'▀ ▄    ▀ ▄      \n    ▀      ▀▄  ▄' ]] || fail "render_qrcode should preserve qrencode UTF8 output exactly"

TEST_TTY_SIZE='24 28'
rm -f "$QR_LOG"
render_qrcode "$issue16_url" >"$case_dir/long-narrow.out" 2>&1 || :
[[ $(<"$case_dir/long-narrow.out") != *"$full_qr_cell"* && $(<"$case_dir/long-narrow.out") == *"终端空间不足"* ]] || fail "a terminal smaller than the native QR should omit it with a clear warning"
expect_qr_args "$issue16_url"
TEST_TTY_SIZE='40 80'

# A node without a share URL must not reuse the preceding node's URL.
cat >"$is_conf_dir/relay-41603.json" <<'NODE'
{"inbounds":[{"tag":"relay-41603.json","type":"direct","listen":"::","listen_port":41603,"override_address":"203.0.113.20","override_port":41603}]}
NODE
rm -f "$QR_LOG"
info relay-41603.json >"$case_dir/no-link.out" 2>&1 || fail "info for an unshareable node should succeed"
[[ ! -f $QR_LOG ]] || fail "node without a share URL must not call qrencode"
[[ $is_url ]] && fail "node without a share URL must clear the previous URL"
[[ $(<"$case_dir/no-link.out") != *"$full_qr_cell"* ]] || fail "node without a share URL must not display a QR code"

# Existing quiet and export paths do not invoke qrencode.
rm -f "$QR_LOG"
is_dont_show_info=1
info special.json >"$case_dir/quiet.out" 2>&1 || fail "is_dont_show_info path should succeed"
[[ ! -s "$case_dir/quiet.out" && ! -f $QR_LOG ]] || fail "is_dont_show_info path must stay quiet"
is_dont_show_info=
is_gen=1
info special.json >"$case_dir/gen.out" 2>&1 || fail "is_gen path should succeed"
[[ ! -s "$case_dir/gen.out" && ! -f $QR_LOG ]] || fail "is_gen path must stay quiet"
is_gen=
is_dont_auto_exit=1
info special.json >"$case_dir/no-auto-exit.out" 2>&1 || fail "is_dont_auto_exit path should succeed"
[[ ! -s "$case_dir/no-auto-exit.out" && ! -f $QR_LOG ]] || fail "is_dont_auto_exit path must stay quiet"
is_dont_auto_exit=
url_qr url special.json >"$case_dir/url.out" 2>&1 || fail "URL export should succeed"
[[ ! -f $QR_LOG ]] || fail "URL export must not call qrencode"
[[ $(<"$case_dir/url.out") == *"$special_url"* ]] || fail "URL export should retain the share URL"
[[ $(<"$case_dir/url.out") != *"$full_qr_cell"* ]] || fail "URL export must not display a QR code"

# Independent QR remains available through the same renderer.
rm -f "$QR_LOG"
url_qr qr special.json >"$case_dir/qr.out" 2>&1 || fail "independent QR command should succeed"
expect_qr_args "$special_url"
[[ $(<"$case_dir/qr.out") == *"$full_qr_cell"* ]] || fail "independent QR command should render the QR code"

# Missing and failing qrencode are non-blocking for node details.
rm -f "$QR_LOG"
QR_MISSING=1
is_dont_show_info=
info special.json >"$case_dir/missing.out" 2>&1 || fail "missing qrencode must not fail info"
[[ ! -f $QR_LOG ]] || fail "missing qrencode must not be called"
[[ $(<"$case_dir/missing.out") == *"qrencode"* && $(<"$case_dir/missing.out") == *"$special_url"* ]] || fail "missing qrencode should show install guidance and retain URL: $(<"$case_dir/missing.out")"
expected_install_command=$(qrcode_dependency_install_command)
[[ $(<"$case_dir/missing.out") == *"$expected_install_command"* ]] || fail "missing qrencode should use the system package command: $(<"$case_dir/missing.out")"
[[ ! -f $QR_PACKAGE_LOG ]] || fail "viewing a node with missing qrencode must not run a package manager"
QR_MISSING=
rm -f "$QR_LOG"
is_dont_show_info=
QR_EXIT=23 info special.json >"$case_dir/failing.out" 2>&1 || fail "qrencode failure must not fail info"
[[ -f $QR_LOG ]] || fail "failing qrencode should have been called"
[[ $(<"$case_dir/failing.out") == *"二维码生成失败"* && $(<"$case_dir/failing.out") == *"$special_url"* ]] || fail "qrencode failure should be clear and retain URL"

echo "PASS: QR details behavior for $CASE_NAME core"
CASE
}

run_core_case "$repo_root/core.sh" root || fail "root core QR tests failed"
run_core_case "$repo_root/src/core.sh" src || fail "src core QR tests failed"

if qrencode_bin=$(command -v qrencode); then
  issue16_url='vless://00000000-0000-4000-8000-000000000000@203.0.113.10:40018?encryption=none&security=reality&flow=xtls-rprx-vision&type=tcp&sni=www.example.com&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&fp=chrome#TEST-NODE'
  qr_output=$("$qrencode_bin" -t UTF8 "$issue16_url") || fail "real qrencode failed to render the issue URL"
  qr_width=$(printf '%s\n' "$qr_output" | sed $'s/\033\\[[0-9;]*m//g' | wc -L)
  qr_height=$(printf '%s\n' "$qr_output" | wc -l)
  [[ $qr_width == 57 && $qr_height == 29 ]] || fail "real qrencode UTF8 dimensions changed: ${qr_width}x${qr_height}"
  echo "PASS: real qrencode UTF8 dimensions are ${qr_width} columns x ${qr_height} rows"

  real_qr_output=$(
    CORE_FILE="$repo_root/core.sh" QR_URL="$issue16_url" bash <<'REAL_QR'
source "$CORE_FILE"
msg() { :; }
warn() { :; }
stty() { printf '40 80\n'; }
is_config_name=TEST-NODE
render_qrcode "$QR_URL"
REAL_QR
  ) || fail "real qrencode output should fit in an 80x40 terminal"
  [[ $real_qr_output == "$qr_output" ]] || fail "render_qrcode should preserve the real qrencode output exactly"
  real_qr_width=$(printf '%s\n' "$real_qr_output" | sed -e 's/█/x/g' -e 's/▀/x/g' -e 's/▄/x/g' | wc -L)
  real_qr_height=$(printf '%s\n' "$real_qr_output" | wc -l)
  [[ $real_qr_width == 57 && $real_qr_height == 29 ]] || fail "real native QR dimensions changed: ${real_qr_width}x${real_qr_height}"
  echo "PASS: real qrencode native dimensions are ${real_qr_width} columns x ${real_qr_height} rows"

  if command -v zbarimg >/dev/null && python3 -c 'from PIL import Image, ImageDraw, ImageFont' >/dev/null 2>&1 && [[ -f /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf ]]; then
    qr_image="$workdir/qr-terminal.png"
    printf '%s\n' "$real_qr_output" >"$workdir/qr-terminal.txt"
    python3 - "$workdir/qr-terminal.txt" "$qr_image" <<'RENDER_QR'
import sys
from PIL import Image, ImageDraw, ImageFont

text = open(sys.argv[1], encoding="utf-8").read().rstrip("\n")
font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 18)
probe = Image.new("RGB", (1, 1), "white")
draw = ImageDraw.Draw(probe)
bounds = draw.multiline_textbbox((0, 0), text, font=font, spacing=0)
quiet_zone = 32
origin = (quiet_zone - bounds[0], quiet_zone - bounds[1])
image = Image.new("RGB", (bounds[2] - bounds[0] + quiet_zone * 2, bounds[3] - bounds[1] + quiet_zone * 2), "white")
draw = ImageDraw.Draw(image)
draw.rectangle((origin[0] + bounds[0], origin[1] + bounds[1], origin[0] + bounds[2], origin[1] + bounds[3]), fill="black")
draw.multiline_text(origin, text, font=font, fill="white", spacing=0)
image.save(sys.argv[2])
RENDER_QR
    decoded_url=$(zbarimg --quiet --raw "$qr_image") || fail "the rasterized terminal QR should be decodable"
    [[ $decoded_url == "$issue16_url" ]] || fail "the rasterized terminal QR decoded to a different URL"
    echo "PASS: rendered terminal QR decodes to the original issue URL"
  else
    echo "SKIP: rendered terminal QR decode requires zbarimg, Pillow, and DejaVu Sans Mono"
  fi
fi

bash "$repo_root/tests-qrcode-deps.sh" || fail "QR dependency lifecycle tests failed"

echo "PASS: node share QR tests"
