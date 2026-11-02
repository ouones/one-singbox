# QR dependency helpers shared by install, update, and first-run migration.

qrcode_dependency_available() {
    [[ $(type -P qrencode 2>/dev/null) ]]
}

qrcode_dependency_checked() {
    [[ -f $is_core_dir/qrcode-dependency-checked ]]
}

qrcode_dependency_mark_checked() {
    : >"$is_core_dir/qrcode-dependency-checked"
}

qrcode_dependency_package_manager() {
    local manager manager_path
    case $cmd in
    *apt-get*)
        printf '%s\n' "$cmd"
        return 0
        ;;
    *yum*)
        printf '%s\n' "$cmd"
        return 0
        ;;
    *zypper*)
        printf '%s\n' "$cmd"
        return 0
        ;;
    *apk*)
        printf '%s\n' "$cmd"
        return 0
        ;;
    esac
    for manager in apt-get yum zypper apk; do
        manager_path=$(type -P "$manager") || continue
        printf '%s\n' "$manager_path"
        return 0
    done
    return 1
}

qrcode_dependency_install_command() {
    local manager=$1
    [[ $manager ]] || manager=$(qrcode_dependency_package_manager) || return 1
    case $manager in
    *apt-get*)
        printf 'apt-get install -y qrencode\n'
        ;;
    *yum*)
        printf 'yum install -y qrencode\n'
        ;;
    *zypper*)
        printf 'zypper --non-interactive install qrencode\n'
        ;;
    *apk*)
        printf 'apk add libqrencode-tools\n'
        ;;
    *)
        return 1
        ;;
    esac
}

qrcode_dependency_install_package() {
    case $1 in
    *apt-get* | *yum*)
        "$1" install -y qrencode
        ;;
    *zypper*)
        "$1" --non-interactive install qrencode
        ;;
    *apk*)
        "$1" add libqrencode-tools
        ;;
    *)
        return 1
        ;;
    esac
}

qrcode_dependency_refresh_index() {
    case $1 in
    *apt-get*)
        "$1" update
        ;;
    *yum*)
        "$1" makecache
        ;;
    *zypper*)
        "$1" --non-interactive refresh
        ;;
    *apk*)
        "$1" update
        ;;
    *)
        return 1
        ;;
    esac
}

qrcode_dependency_report_failure() {
    local install_command=$1
    local message='二维码工具 qrencode 自动安装失败，终端二维码暂不可用。查看节点时仍可复制分享链接，或使用显示的网页二维码链接。'
    [[ $install_command ]] && message="$message；也可手动执行：$install_command"
    message="$message；之后可通过主动更新脚本重试。"
    if declare -F warn >/dev/null 2>&1; then
        warn "$message"
    else
        printf '%s\n' "$message"
    fi
}

qrcode_dependency_install() {
    local manager install_command
    if qrcode_dependency_available; then
        qrcode_dependency_mark_checked || :
        return 0
    fi
    if ! manager=$(qrcode_dependency_package_manager); then
        qrcode_dependency_mark_checked || :
        qrcode_dependency_report_failure ''
        return 1
    fi
    if ! qrcode_dependency_install_package "$manager" >/dev/null 2>&1; then
        qrcode_dependency_refresh_index "$manager" >/dev/null 2>&1 || :
        qrcode_dependency_install_package "$manager" >/dev/null 2>&1 || :
    fi
    if qrcode_dependency_available; then
        qrcode_dependency_mark_checked || :
        return 0
    fi
    qrcode_dependency_mark_checked || :
    install_command=$(qrcode_dependency_install_command "$manager")
    qrcode_dependency_report_failure "$install_command"
    return 1
}
