#!/usr/bin/env bash
# by spiritlhl
# from https://github.com/spiritLHLS/ecs but more recommended to use https://github.com/oneclickvirt/ecs

cd /root >/dev/null 2>&1
myvar=$(pwd)
ver="2026.05.08"

# =============== 默认输入设置 ===============
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"
SAVE_CURSOR="\033[s"
RESTORE_CURSOR="\033[u"
HIDE_CURSOR="\033[?25l"
SHOW_CURSOR="\033[?25h"
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
    _yellow "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
    _green "Locale set to $utf8_locale"
fi
menu_mode=true
en_status=false
swhc_mode=true
test_base_status=false
test_cpu_type=""
test_disk_type=""
test_network_type=""
build_text_status=true
multidisk_status=false
target_ipv4=""
route_location=""
enable_speedtest=true
main_menu_option=0
sub_menu_option=0
sub_of_sub_menu_option=0
break_status=true
m_params=()
# 解析命令行选项
while [ "$#" -gt 0 ]; do
    case "$1" in
    -m)
        # 处理 -m 选项，关闭菜单模式
        menu_mode=false
        shift # 移动到下一个参数
        while [ "$#" -gt 0 ] && [[ "$1" != -* ]]; do
            m_params+=("$1")
            shift
        done
        ;;
    -i)
        # 处理 -i 选项，获取IPv4地址
        target_ipv4="$2"
        swhc_mode=false
        shift 2
        ;;
    -r)
        # 处理 -r 选项，选择测试回程路由的目标地址 (三网)
        route_location="$2"
        shift 2
        ;;
    -en)
        # 处理 -en 选项，选择使用英文显示
        en_status=true
        shift
        ;;
    -base)
        # 处理 -base 选项，选择仅测试系统信息
        menu_mode=false
        test_base_status=true
        shift
        ;;
    -ctype)
        # 处理 -ctype 选项，选择测试cpu使用的方式
        test_cpu_type="$2"
        shift 2
        ;;
    -dtype)
        # 处理 -dtype 选项，选择测试磁盘使用的方式
        test_disk_type="$2"
        shift 2
        ;;
    -mdisk)
        # 处理 -mdisk 选项，选择测试多个挂载盘，且含系统盘
        multidisk_status=true
        shift
        ;;
    -stype)
        # 处理 -stype 选项，选择测试网速的数据来源，不指定时默认优先使用.net数据
        test_network_type="$2"
        shift 2
        ;;
    -bansp)
        # 处理 -bansp 选项，禁用测速
        enable_speedtest=false
        shift
        ;;
    -banup)
        # 处理 -banup 选项，禁用分享链接生成
        build_text_status=false
        shift
        ;;
    -h)
        if [ "$en_status" = true ]; then
            echo "Executed using parameter mode:"
            echo "-m     Mandatory, Specify the options in the original menu, support up to three levels of selection"
            echo "       For example, executing bash ecs.sh -m 5 1 1 will select the script execution for sub-option 1 under option 1 of option 5 of the main menu."
            echo "       Can specify only 1~3 parameter by default, e.g. -m 1 or -m 1 0 or -m 1 0 0"
            echo "-en    Optional, Can specify which language is used to display the test, unspecified Chinese is used."
            echo "-i     Optional, Can specify the target IPV4 address in the backhaul routing test."
            echo "-base  Optional, Only basic system information is tested, not CPU, hard disk, streaming, backhaul routing, etc."
            echo "-ctype Optional, Can specify the way to test the cpu, optional gb4 gb5 gb6 corresponds to geekbench version 4, 5, 6 respectively."
            echo "-dtype Optional, Can specify the program to test the IO of the hard disk, you can choose dd or fio, the former test is fast and the latter test is slow."
            echo "-mdisk Optional, Can specify to test the IO of multiple mounted disks."
            echo "-bansp Optional, Can specify not to run speedtest."
            echo "-banup Optional, Can specify to force not to generate the sharing link."
        else
            echo "使用参数模式执行："
            echo "-m     必填项，指定原本menu中的选项，最多支持三层选择"
            echo "       例如执行 bash ecs.sh -m 5 1 1 将选择主菜单第5选项下的第1选项下的子选项1的脚本执行"
            echo "       (可缺省仅指定一个参数，如 -m 1 仅指定执行融合怪完全体，执行 -m 1 0 以及 -m 1 0 0 都是指定执行融合怪完全体)"
            echo "-en    可选项，可指定测试时使用的是哪种语言进行展示，该指令指定为使用英语，未指定时使用中文"
            echo "-i     可选项，可指定回程路由测试中的目标IPV4地址，可通过 ip.sb ipinfo.io 等网站获取本地IPV4地址后指定"
            echo "-r     可选项，可指定回程路由测试中的三网IPV4地址，可选 b g s c 分别对应 北京、广州、上海、成都 的三网地址，如 -r g 指定测试广州地址"
            echo "       可指定仅测试IPV6三网，可选 b6 g6 s6 分别对应 北京、广州、上海 的三网的IPV6地址，如 -r b6 指定测试北京IPV6地址"
            echo "-base  可选项，仅测试基础的系统信息，不测试CPU、硬盘、流媒体、回程路由等内容"
            echo "-ctype 可选项，可指定通过何种方式测试cpu，可选 gb4 gb5 gb6 分别对应geekbench的4、5、6版本，无该指令则默认使用sysbench测试"
            echo "-dtype 可选项，可指定测试硬盘IO的程序，可选 dd 或 fio 前者测试快后者测试慢，无该指令则默认为都使用进行测试"
            echo "-mdisk 可选项，可指定测试多个挂载盘的IO，注意这也会测试系统盘且仅使用fio测试"
            echo "-stype 可选项，可指定测试时使用的是什么平台的测速节点，可选 .cn .com 分别对应 speedtest.cn speedtest.com 数据"
            echo "-bansp 可选项，可指定强制不测试网速，无该指令则默认测试网速"
            echo "-banup 可选项，可指定强制不生成分享链接，无该指令则默认生成分享链接"
        fi
        exit 1
        ;;
    *)
        echo "未知的选项: $1"
        exit 1
        ;;
    esac
done
if [ -n "$target_ipv4" ]; then
    if [ "$en_status" = true ]; then
        test_area_local=("Yor local public IPV4 address")
        test_ip_local=("$target_ipv4")
    else
        test_area_local=("你本地的IPV4地址")
        test_ip_local=("$target_ipv4")
    fi
fi
# 在menu_mode为false时才打印信息
if [ "$menu_mode" = false ]; then
    if [ "$en_status" = true ]; then
        _blue "Parameter is detected, use parameter mode, read the parameter as follows, display for 4 seconds"
    else
        _blue "检测到参数，使用参数模式，读取参数如下，显示4秒"
    fi
    echo "menu_mode: $menu_mode"
    echo "test_base_status: $test_base_status"
    echo "target_ipv4: $target_ipv4"
    echo "route_location: $route_location"
    echo "test_cpu_type: $test_cpu_type"
    echo "test_disk_type: $test_disk_type"
    echo "multidisk_status: $multidisk_status"
    echo "enable_speedtest: $enable_speedtest"
    echo "build_text_status: $build_text_status"
    # 读取 -m 选项后的参数
    main_menu_option=${m_params[0]:-0}
    sub_menu_option=${m_params[1]:-0}
    sub_of_sub_menu_option=${m_params[2]:-0}
    echo "main_menu_option: $main_menu_option"
    echo "sub_menu_option: $sub_menu_option"
    echo "sub_of_sub_menu_option: $sub_of_sub_menu_option"
    sleep 4
fi

# =============== 自定义基础参数 ==============
if [ "$en_status" = true ]; then
    changeLog="VPS Fusion Monster Test From Multi-script"
else
    changeLog="VPS融合怪测试(集百家之长)"
fi
http_short_url=""
https_short_url=""
TEMP_DIR='/tmp/ecs'
PROGRESS_DIR="/tmp/progress"
rm -rf "$PROGRESS_DIR"
mkdir -p "$PROGRESS_DIR"
PID_FILE="/tmp/pids.txt"
rm -rf "$PID_FILE"
temp_file_apt_fix="${TEMP_DIR}/apt_fix.txt"
WorkDir="/tmp/.LemonBench"
ipv6_condition=false
test_area_g=("广州电信" "广州联通" "广州移动")
test_ip_g=("58.60.188.222" "210.21.196.6" "120.196.165.24")
test_area_s=("上海电信" "上海联通" "上海移动")
test_ip_s=("202.96.209.133" "210.22.97.1" "211.136.112.200")
test_area_b=("北京电信" "北京联通" "北京移动")
test_ip_b=("219.141.140.10" "202.106.195.68" "221.179.155.161")
test_area_c=("成都电信" "成都联通" "成都移动")
test_ip_c=("61.139.2.69" "119.6.6.6" "211.137.96.205")
test_area_g6=("广州电信" "广州联通" "广州移动")
test_ip_g6=("240e:97c:2f:3000::44" "2408:8756:f50:1001::c" "2409:8c54:871:1001::12")
test_area_s6=("上海电信" "上海联通" "上海移动")
test_ip_s6=("240e:e1:aa00:4000::24" "2408:80f1:21:5003::a" "2409:8c1e:75b0:3003::26")
test_area_b6=("北京电信" "北京联通" "北京移动")
test_ip_b6=("2400:89c0:1053:3::69" "2400:89c0:1013:3::54" "2409:8c00:8421:1303::55")
BrowserUA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0.4844.74 Safari/537.36"
Speedtest_Go_version="1.7.10"

# =============== 基础信息设置 ===============
REGEX=("debian|astra" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch" "freebsd" "alpine" "openbsd" "opencloudos")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch" "FreeBSD" "Alpine" "OpenBSD" "OpenCloudOS")
PACKAGE_UPDATE=("! apt-get update && apt-get --fix-broken install -y && apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update" "pacman -Sy" "pkg update" "apk update" "pkg_add -qu" "yum -y update")
PACKAGE_INSTALL=("apt-get -y install" "apt-get -y install" "yum -y install" "yum -y install" "yum -y install" "pacman -Sy --noconfirm --needed" "pkg install -y" "apk add --no-cache" "pkg_add -I" "yum -y install")
PACKAGE_REMOVE=("apt-get -y remove" "apt-get -y remove" "yum -y remove" "yum -y remove" "yum -y remove" "pacman -Rsc --noconfirm" "pkg delete" "apk del" "pkg_delete -I" "yum -y remove")
PACKAGE_UNINSTALL=("apt-get -y autoremove" "apt-get -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove" "" "pkg autoremove" "apk autoremove" "pkg_delete -a" "yum -y autoremove")
CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')" "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(uname -s)")
if [ -f /etc/opencloudos-release ]; then
    SYS="opencloudos"
else
    SYS="${CMD[0]}"
fi
[[ -n $SYS ]] || exit 1
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done

# =================== 其他脚本相关设置 ===================
export DEBIAN_FRONTEND=noninteractive
rm -rf test_result.txt >/dev/null 2>&1
if [ ! -d "/tmp" ]; then
    mkdir /tmp
fi
usage_timeout=true
# DISPLAY_RUNNING 已改为使用 $PROGRESS_DIR/display_running 标志文件实现跨进程通信

# =============== 脚本退出执行相关函数 部分 ===============
trap _exit INT QUIT TERM

_exit() {
    # 终止信号捕获 - ctrl+c
    echo -e "\n${Msg_Error}Exiting ..."
    if [ "$en_status" = true ]; then
        _red "An exit operation is detected and the script terminates!"
    else
        _red "检测到退出操作，脚本终止！"
    fi
    global_exit_action
    rm_script
    exit 1
}

global_startup_init_action() {
    # 清理残留, 为新一次的运行做好准备
    echo -e "${Msg_Info}Initializing Running Enviorment, Please wait ..."
    rm -rf "$WorkDir"
    rm -rf /.tmp_LBench/
    mkdir "$WorkDir"/
    echo -e "${Msg_Info}Checking Dependency ..."
    BenchFunc_Systeminfo_GetSysteminfo
    echo -e "${Msg_Info}Starting Test ..."
}

global_exit_action() {
    reset_default_sysctl >/dev/null 2>&1
    echo -en "$SHOW_CURSOR"
    if [ "$build_text_status" = true ]; then
        build_text
        if [ -n "$https_short_url" ] || [ -n "$http_short_url" ]; then
            if [ "$en_status" = true ]; then
                _green "  ShortLink:"
            else
                _green "  短链:"
            fi
            if [ -n "$https_short_url" ]; then
                _blue "    $https_short_url"
            fi
            if [ -n "$http_short_url" ]; then
                _blue "    $http_short_url"
            fi
            if [ "$en_status" = true ]; then
                _yellow "  Every Test Benchmark: https://bash.spiritlhl.net/ecsguide"
            else
                _yellow "  每项测试基准见: https://bash.spiritlhl.net/ecsguide"
            fi
        fi
    fi
    rm -rf ${TEMP_DIR}
    rm -rf ${WorkDir}/
    rm -rf /.tmp_LBench/
    rm -rf *00_00
}

_exists() {
    # 查询对应变量或组件是否存在
    local cmd="$1"
    if eval type type >/dev/null 2>&1; then
        eval type "$cmd" >/dev/null 2>&1
    elif command >/dev/null 2>&1; then
        command -v "$cmd" >/dev/null 2>&1
    else
        which "$cmd" >/dev/null 2>&1
    fi
    local rt=$?
    return ${rt}
}

reset_default_sysctl() {
    # 还原 /etc/security/limits.conf
    if [ -f /etc/security/limits.conf.backup ]; then
        cp /etc/security/limits.conf.backup /etc/security/limits.conf
        rm -f /etc/security/limits.conf.backup
    fi
    # 还原 sysctl 设置
    local conf_files=()
    # 优先 systemd 方式
    if [ -f "/etc/sysctl.d/99-custom.conf" ]; then
        conf_files+=("/etc/sysctl.d/99-custom.conf")
    fi
    # 传统方式
    if [ -f "/etc/sysctl.conf" ]; then
        conf_files+=("/etc/sysctl.conf")
    fi
    for conf in "${conf_files[@]}"; do
        local backup="${conf}.backup"
        local default="${conf}.default"
        if [ -f "$backup" ]; then
            cp "$backup" "$conf"
            rm -f "$backup"
        fi
        if [ -f "$default" ]; then
            cat "$default" >>"$conf"
            rm -f "$default"
        fi
    done
    # 重新加载 sysctl
    if which sysctl >/dev/null 2>&1; then
        sysctl -p 2>/dev/null
    fi
}

next() {
    echo -en "\r"
    [ "${Var_OSRelease}" = "freebsd" ] && printf "%-72s\n" "-" | tr ' ' '-' && return
    printf "%-72s\n" "-" | sed 's/\s/-/g'
}

# =============== 组件预安装及文件预下载 部分 ===============
checkver() {
    check_cdn_file
    running_version=$(sed -n '7s/ver="\(.*\)"/\1/p' "$0")
    curl -L "${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/ecs/main/ecs.sh" -o ecs1.sh || curl -L "https://raw.githubusercontent.com/spiritLHLS/ecs/main/ecs.sh" -o ecs1.sh
    chmod 777 ecs1.sh
    downloaded_version=$(sed -n '7s/ver="\(.*\)"/\1/p' ecs1.sh)
    if [ "$running_version" != "$downloaded_version" ]; then
        if [ "$en_status" = true ]; then
            _yellow "Upgrade script from $ver to $downloaded_version"
        else
            _yellow "更新脚本从 $ver 到 $downloaded_version"
        fi
        mv ecs1.sh "$0"
        exec "$0" "$@"
    else
        if [ "$en_status" = true ]; then
            _green "This script is the lastes version."
        else
            _green "本脚本已是最新脚本无需更新"
        fi
        rm -rf ecs1.sh*
    fi
}

check_root() {
    local root_status=true
    [[ $EUID -ne 0 ]] && root_status=false
    if [ "$en_status" = true ] && [ "$root_status" = false ]; then
        echo -e "${RED}Please use root user to run this script!${PLAIN}" && exit 1
    elif [ "$root_status" = false ]; then
        echo -e "${RED}请使用 root 用户运行本脚本！${PLAIN}" && exit 1
    fi
}

check_update() {
    _yellow "Updating package management sources"
    if command -v apt-get >/dev/null 2>&1; then
        apt_update_output=$(apt-get update 2>&1)
        echo "$apt_update_output" >"$temp_file_apt_fix"
        if grep -q 'NO_PUBKEY' "$temp_file_apt_fix"; then
            public_keys=$(grep -oE 'NO_PUBKEY [0-9A-F]+' "$temp_file_apt_fix" | awk '{ print $2 }')
            joined_keys=$(echo "$public_keys" | paste -sd " ")
            _yellow "No Public Keys: ${joined_keys}"
            apt-key adv --keyserver keyserver.ubuntu.com --recv-keys ${joined_keys}
            apt-get update
            if [ $? -eq 0 ]; then
                _green "Fixed"
            fi
        fi
        rm "$temp_file_apt_fix"
    else
        ${PACKAGE_UPDATE[int]}
    fi
}

check_sudo() {
    _yellow "checking sudo"
    if ! command -v sudo >/dev/null 2>&1; then
        _yellow "Installing sudo"
        ${PACKAGE_INSTALL[int]} sudo >/dev/null 2>&1
    fi
}

check_curl() {
    if ! which curl >/dev/null; then
        _yellow "Installing curl"
        ${PACKAGE_INSTALL[int]} curl
    fi
    if [ $? -ne 0 ]; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get -f install >/dev/null 2>&1
        fi
        ${PACKAGE_INSTALL[int]} curl
    fi
}

check_wget() {
    if ! which wget >/dev/null; then
        _yellow "Installing wget"
        ${PACKAGE_INSTALL[int]} wget
    fi
}

check_free() {
    [ "${Var_OSRelease}" = "freebsd" ] && return
    if ! command -v free >/dev/null 2>&1; then
        _yellow "Installing procps"
        ${PACKAGE_INSTALL[int]} procps
    fi
}

check_lsb_release() {
    [ "${Var_OSRelease}" = "freebsd" ] && return
    if ! command -v lsb_release >/dev/null 2>&1; then
        _yellow "Installing lsb-release"
        ${PACKAGE_INSTALL[int]} lsb-release
    fi
}

check_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        usage_timeout=true
    else
        usage_timeout=false
    fi
}

check_lscpu() {
    if ! command -v lscpu >/dev/null 2>&1; then
        _yellow "Installing lscpu"
        ${PACKAGE_INSTALL[int]} lscpu
    fi
}

check_unzip() {
    if ! command -v unzip >/dev/null 2>&1; then
        _yellow "Installing unzip"
        ${PACKAGE_INSTALL[int]} unzip
    fi
}

check_ip() {
    if ! command -v ip >/dev/null 2>&1; then
        _yellow "Installing iproute2 to use ip command"
        ${PACKAGE_INSTALL[int]} iproute2
    fi
    if ! command -v ifconfig >/dev/null 2>&1; then
        _yellow "Installing net-tools to use ifconfig command"
        ${PACKAGE_INSTALL[int]} net-tools
    fi
}

check_ping() {
    _yellow "checking ping"
    if ! which ping >/dev/null; then
        _yellow "Installing ping"
        ${PACKAGE_INSTALL[int]} iputils-ping >/dev/null 2>&1
        ${PACKAGE_INSTALL[int]} ping >/dev/null 2>&1
    fi
}

check_nc() {
    _yellow "checking nc"
    if ! command -v nc >/dev/null; then
        _yellow "Installing nc"
        if command -v apt >/dev/null; then
            ${PACKAGE_INSTALL[int]} netcat >/dev/null 2>&1
        else
            ${PACKAGE_INSTALL[int]} nc >/dev/null 2>&1
        fi
    fi
}

check_tar() {
    _yellow "checking tar"
    if ! command -v tar &>/dev/null; then
        _yellow "Installing tar"
        ${PACKAGE_INSTALL[int]} tar
    fi
    if [ $? -ne 0 ]; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get -f install >/dev/null 2>&1
        fi
        ${PACKAGE_INSTALL[int]} tar >/dev/null 2>&1
    fi
}

check_lsof() {
    _yellow "checking lsof"
    if ! command -v lsof &>/dev/null; then
        _yellow "Installing lsof"
        ${PACKAGE_INSTALL[int]} lsof
    fi
    if [ $? -ne 0 ]; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get -f install >/dev/null 2>&1
        fi
        ${PACKAGE_INSTALL[int]} lsof >/dev/null 2>&1
    fi
}

check_haveged() {
    [ "${Var_OSRelease}" = "freebsd" ] && return
    _yellow "checking haveged"
    if ! command -v haveged >/dev/null 2>&1; then
        ${PACKAGE_INSTALL[int]} haveged >/dev/null 2>&1
    fi
    if which systemctl >/dev/null 2>&1; then
        systemctl disable --now haveged
        systemctl enable --now haveged
    else
        service haveged stop
        service haveged start
    fi
}

check_dnsutils() {
    _yellow "Installing dnsutils"
    if [ "${Var_OSRelease}" == "centos" ]; then
        yum -y install dnsutils >/dev/null 2>&1
        yum -y install bind-utils >/dev/null 2>&1
    elif [ "${Var_OSRelease}" == "arch" ]; then
        pacman -S --noconfirm --needed bind >/dev/null 2>&1
    else
        ${PACKAGE_INSTALL[int]} dnsutils >/dev/null 2>&1
    fi
}

checkpip() {
    [ "${Var_OSRelease}" = "freebsd" ] && curl -L https://bootstrap.pypa.io/get-pip.py -o get-pip.py && chmod +x get-pip.py && python3 get-pip.py && rm -rf get-pip.py && return
    local pvr="$1"
    local pip_version=$(pip --version 2>&1)
    if [[ $? -eq 0 && $pip_version != *"command not found"* ]]; then
        _blue "$pip_version"
    else
        _yellow "installing python${pvr}-pip"
        ${PACKAGE_INSTALL[int]} python${pvr}-pip
        pip_version=$(pip --version 2>&1)
        if [[ $? -eq 0 ]]; then
            _blue "$pip_version"
        else
            _red "python${pvr}-pip installation failed, please install it manually"
            return
        fi
    fi
}

check_and_cat_file() {
    local file="$1"
    # 检测文件是否存在
    if [[ -f "$file" ]]; then
        # 判断文件内容是否为空或只包含空行
        if [[ -s "$file" ]] && [[ "$(grep -vE '^\s*$' "$file")" ]]; then
            :
        else
            truncate -s 0 "$file"
            return
        fi
    else
        return
    fi
    # 检测文件内容是否包含"error"，如果包含则不打印文件内容
    if grep -q "error" "$file"; then
        return
    fi
    cat "$file"
}

# 移动光标并清除行
move_and_clear() {
    local line=$1
    echo -en "\033[${line};0H\033[K"
}

# 显示进度条
display_progress() {
    local use_tput=false
    if command -v tput >/dev/null 2>&1; then
        use_tput=true
    fi
    local progress_height=$((${#dfiles[@]} + 2)) # 进度显示所需的行数
    # 保存光标位置并隐藏光标
    echo -en "$SAVE_CURSOR$HIDE_CURSOR"
    while [ -f "$PROGRESS_DIR/display_running" ]; do
        # 将光标移动到保存的位置
        echo -en "$RESTORE_CURSOR"
        if [ "$en_status" = true ]; then
            echo "Download progress:"
        else
            echo "下载进度："
        fi
        local all_completed=true
        for dfile in "${dfiles[@]}"; do
            if [ -f "$PROGRESS_DIR/$dfile" ]; then
                local percentage=$(cat "$PROGRESS_DIR/$dfile")
                if [[ "$percentage" =~ ^[0-9]+$ ]]; then
                    percentage=$((percentage > 100 ? 100 : percentage))
                    printf "%-20s [%-50s] %3d%%\n" "$dfile" "$(printf '#%.0s' $(seq 1 $((percentage / 2))))" "$percentage"
                    if [ "$percentage" -lt 100 ]; then
                        all_completed=false
                    fi
                else
                    printf "%-20s [%-50s] ???\n" "$dfile" ""
                    all_completed=false
                fi
            else
                printf "%-20s [%-50s] ???\n" "$dfile" ""
                all_completed=false
            fi
        done
        if [ "$all_completed" = true ]; then
            break
        fi
        sleep 3.5
    done
    # 显示光标
    echo -en "$SHOW_CURSOR"
    echo ""
}

# 开始整体并发下载并显示进度条
start_downloads() {
    local dfiles=("$@") # 接收文件列表作为参数
    # 初始化进度
    for dfile in "${dfiles[@]}"; do
        echo "0" >"$PROGRESS_DIR/$dfile"
    done
    # 获取当前光标位置
    local current_line=$(tput lines)
    # 创建标志文件，通知 display_progress 子进程可以继续运行
    touch "$PROGRESS_DIR/display_running"
    # 启动后台进程来更新显示
    display_progress $current_line &
    local display_pid=$!
    # 并发下载并跟踪PID
    for dfile in "${dfiles[@]}"; do
        main_download "$dfile" &
        echo $! >>"$PID_FILE"
    done
    wait
    # 删除标志文件，通知 display_progress 子进程停止
    rm -f "$PROGRESS_DIR/display_running"
    wait "$display_pid" 2>/dev/null
}

download_file() {
    local url=$1
    local output=$2
    local progress_file=$3
    # 获取文件总大小
    local total_size
    total_size=$(curl -sIkL "$url" | grep -i Content-Length | awk '{print $2}' | tr -d '\r\n' | grep -o '[0-9]*' | head -1)
    total_size=${total_size:-0}
    # 去掉前导零，避免被当作八进制
    total_size=$((10#$total_size))
    # 确保 total_size 是纯数字
    if ! [[ "$total_size" =~ ^[0-9]+$ ]]; then
        total_size=0
    fi
    if [ "$total_size" -eq 0 ]; then
        echo "无法获取 $url 的文件大小,将使用 0 作为默认值。" >&2
    fi

    # 后台进度监控：轮询输出文件大小并写入进度文件，直到下载进程退出
    _dl_monitor() {
        local mon_output="$1"
        local mon_total="$2"
        local mon_pfile="$3"
        local mon_pid="$4"
        while kill -0 "$mon_pid" 2>/dev/null; do
            if [ -f "$mon_output" ]; then
                local cur_size
                cur_size=$(stat -c%s "$mon_output" 2>/dev/null || stat -f%z "$mon_output" 2>/dev/null)
                cur_size=$(echo "$cur_size" | tr -d '\r\n' | grep -o '[0-9]*' | head -1)
                cur_size=${cur_size:-0}
                cur_size=$((10#$cur_size))
                if ! [[ "$cur_size" =~ ^[0-9]+$ ]]; then cur_size=0; fi
                local prog=0
                if [ "$mon_total" -gt 0 ] && [ "$cur_size" -gt 0 ]; then
                    prog=$((cur_size * 100 / mon_total))
                fi
                echo "$prog" >"$mon_pfile"
            fi
            sleep 1
        done
    }

    local download_failed=0
    # 尝试 curl 下载（后台运行，配合独立监控进程更新进度）
    curl -Lk "$url" -o "$output" >/dev/null 2>&1 &
    local dl_pid=$!
    _dl_monitor "$output" "$total_size" "$progress_file" "$dl_pid" &
    local monitor_pid=$!
    wait "$dl_pid"
    local curl_exit=$?
    wait "$monitor_pid" 2>/dev/null

    if [ $curl_exit -ne 0 ]; then
        download_failed=$((download_failed + 1))
        echo "curl 下载失败,切换到 wget 下载。" >&2
        rm -f "$output"
        # 尝试 wget 下载
        wget -O "$output" "$url" >/dev/null 2>&1 &
        dl_pid=$!
        _dl_monitor "$output" "$total_size" "$progress_file" "$dl_pid" &
        monitor_pid=$!
        wait "$dl_pid"
        local wget_exit=$?
        wait "$monitor_pid" 2>/dev/null
        if [ $wget_exit -ne 0 ]; then
            download_failed=$((download_failed + 1))
            echo "curl 和 wget 下载都失败,退出下载。" >&2
        fi
    fi

    # 确保最终进度被写入
    if [ -f "$output" ]; then
        local final_size
        final_size=$(stat -f%z "$output" 2>/dev/null || stat -c%s "$output" 2>/dev/null)
        local final_progress=0
        if [ "$total_size" -gt 0 ]; then
            final_progress=$((final_size * 100 / total_size))
        fi
        echo "$final_progress" >"$progress_file"
    fi
    # 如果下载失败两次则返回错误码
    [ "$download_failed" -ge 2 ] && error_exit && return 1 || return 0
}

main_download() {
    local file=$1
    case $file in
    sysbench)
        local url="${cdn_success_url}https://github.com/akopytov/sysbench/archive/1.0.20.zip"
        local output="$TEMP_DIR/sysbench.zip"
        download_file "$url" "$output" "$PROGRESS_DIR/$file"
        chmod +x "$output"
        unzip "$output" -d ${TEMP_DIR}
        echo "100" >"$PROGRESS_DIR/$file"
        ;;
    UnlockTests)
        local url="${cdn_success_url}https://github.com/oneclickvirt/UnlockTests/releases/download/output/${UnlockTests_FILE}"
        local output="$TEMP_DIR/UnlockTests"
        download_file "$url" "$output" "$PROGRESS_DIR/$file"
        chmod +x "$output"
        echo "100" >"$PROGRESS_DIR/$file"
        ;;
    nexttrace)
        NEXTTRACE_VERSION=$(curl -m 6 -sSL "https://api.github.com/repos/nxtrace/Ntrace-core/releases/latest" | awk -F \" '/tag_name/{print $4}')
        if [ -z "$NEXTTRACE_VERSION" ]; then
            NEXTTRACE_VERSION=$(curl -m 6 -sSL "https://fd.spiritlhl.top/https://api.github.com/repos/nxtrace/Ntrace-core/releases/latest" | awk -F \" '/tag_name/{print $4}')
        fi
        if [ -z "$NEXTTRACE_VERSION" ]; then
            NEXTTRACE_VERSION=$(curl -m 6 -sSL "https://githubapi.spiritlhl.top/repos/nxtrace/Ntrace-core/releases/latest" | awk -F \" '/tag_name/{print $4}')
        fi
        local url="${cdn_success_url}https://github.com/nxtrace/Ntrace-core/releases/download/${NEXTTRACE_VERSION}/${NEXTTRACE_FILE}"
        local output="$TEMP_DIR/$NEXTTRACE_FILE"
        download_file "$url" "$output" "$PROGRESS_DIR/$file"
        chmod +x "$output"
        echo "100" >"$PROGRESS_DIR/$file"
        ;;
    backtrace)
        local url="${cdn_success_url}https://github.com/oneclickvirt/backtrace/releases/download/output/$BACKTRACE_FILE"
        local output="$TEMP_DIR/backtrace"
        download_file "$url" "$output" "$PROGRESS_DIR/$file"
        echo "100" >"$PROGRESS_DIR/$file"
        ;;
    gostun)
        local url="${cdn_success_url}https://github.com/oneclickvirt/gostun/releases/download/output/$GOSTUN_FILE"
        local output="$TEMP_DIR/gostun"
        download_file "$url" "$output" "$PROGRESS_DIR/$file"
        echo "100" >"$PROGRESS_DIR/$file"
        ;;
    securityCheck)
        local url="${cdn_success_url}https://github.com/oneclickvirt/securityCheck/releases/download/output/$SecurityCheck_FILE"
        local output="$TEMP_DIR/securityCheck"
        download_file "$url" "$output" "$PROGRESS_DIR/$file"
        echo "100" >"$PROGRESS_DIR/$file"
        ;;
    portchecker)
        local url="${cdn_success_url}https://github.com/oneclickvirt/portchecker/releases/download/output/$PortChecker_FILE"
        local output="$TEMP_DIR/pck"
        download_file "$url" "$output" "$PROGRESS_DIR/$file"
        echo "100" >"$PROGRESS_DIR/$file"
        ;;
    yabs)
        local url="${cdn_success_url}https://raw.githubusercontent.com/masonr/yet-another-bench-script/master/yabs.sh"
        local output="$TEMP_DIR/yabs.sh"
        download_file "$url" "$output" "$PROGRESS_DIR/$file"
        chmod +x "$output"
        sed -i '/# gather basic system information (inc. CPU, AES-NI\/virt status, RAM + swap + disk size)/,/^echo -e "IPv4\/IPv6  : $ONLINE"/d' "$output"
        echo "100" >"$PROGRESS_DIR/$file"
        ;;
    ecsspeed_ping)
        local url="${cdn_success_url}https://raw.githubusercontent.com/spiritLHLS/ecsspeed/main/script/ecsspeed-ping.sh"
        local output="$TEMP_DIR/ecsspeed-ping.sh"
        download_file "$url" "$output" "$PROGRESS_DIR/$file"
        chmod +x "$output"
        echo "100" >"$PROGRESS_DIR/$file"
        ;;
    *)
        echo "Invalid file: $file"
        echo "0" >"$PROGRESS_DIR/$file"
        ;;
    esac
}

# =============== 其他相关信息查询 部分 ===============
declare -A sysctl_vars=(
    ["fs.file-max"]=1024000
    ["net.core.rmem_max"]=134217728
    ["net.core.wmem_max"]=134217728
    ["net.core.netdev_max_backlog"]=250000
    ["net.core.somaxconn"]=1024000
    ["net.ipv4.conf.all.rp_filter"]=0
    ["net.ipv4.conf.default.rp_filter"]=0
    ["net.ipv4.conf.lo.arp_announce"]=2
    ["net.ipv4.conf.all.arp_announce"]=2
    ["net.ipv4.conf.default.arp_announce"]=2
    ["net.ipv4.ip_forward"]=1
    ["net.ipv4.ip_local_port_range"]="1024 65535"
    ["net.ipv4.neigh.default.gc_stale_time"]=120
    ["net.ipv4.tcp_syncookies"]=1
    ["net.ipv4.tcp_tw_reuse"]=1
    ["net.ipv4.tcp_low_latency"]=1
    ["net.ipv4.tcp_fin_timeout"]=10
    ["net.ipv4.tcp_window_scaling"]=1
    ["net.ipv4.tcp_keepalive_time"]=10
    ["net.ipv4.tcp_timestamps"]=0
    ["net.ipv4.tcp_sack"]=1
    ["net.ipv4.tcp_fack"]=1
    ["net.ipv4.tcp_syn_retries"]=3
    ["net.ipv4.tcp_synack_retries"]=3
    ["net.ipv4.tcp_max_syn_backlog"]=16384
    ["net.ipv4.tcp_max_tw_buckets"]=8192
    ["net.ipv4.tcp_fastopen"]=3
    ["net.ipv4.tcp_mtu_probing"]=1
    ["net.ipv4.tcp_rmem"]="8192 262144 536870912"
    ["net.ipv4.tcp_wmem"]="4096 16384 536870912"
    ["net.ipv4.tcp_adv_win_scale"]=-2
    ["net.ipv4.tcp_collapse_max_bytes"]=6291456
    ["net.ipv4.tcp_notsent_lowat"]=131072
    ["net.ipv4.udp_rmem_min"]=16384
    ["net.ipv4.udp_wmem_min"]=16384
    ["net.ipv6.conf.all.forwarding"]=1
    ["net.ipv6.conf.default.forwarding"]=1
    ["net.nf_conntrack_max"]=25000000
    ["net.netfilter.nf_conntrack_max"]=25000000
    ["net.netfilter.nf_conntrack_tcp_timeout_time_wait"]=30
    ["net.netfilter.nf_conntrack_tcp_timeout_established"]=180
    ["net.netfilter.nf_conntrack_tcp_timeout_close_wait"]=30
    ["net.netfilter.nf_conntrack_tcp_timeout_fin_wait"]=30
)
sysctl_conf="/etc/sysctl.conf"
sysctl_conf_backup="/etc/sysctl.conf.backup"
sysctl_default="${TEMP_DIR}/sysctl_backup.txt"
sysctl_path=$(which sysctl)

variable_exists() {
    local variable="$1"
    grep -q "^$variable=" "$sysctl_conf"
}

optimized_kernel() {
    _yellow "优化资源限制"
    # 优化 limits.conf
    if [ -f /etc/security/limits.conf ]; then
        cp /etc/security/limits.conf /etc/security/limits.conf.backup
        cat >/etc/security/limits.conf <<EOF
* soft nofile 512000
* hard nofile 512000
* soft nproc 512000
* hard nproc 512000
root soft nofile 512000
root hard nofile 512000
root soft nproc 512000
root hard nproc 512000
EOF
    fi
    # 优化 sysctl
    _yellow "优化 sysctl 配置"
    declare -A default_values
    sysctl_conf="/etc/sysctl.d/99-custom.conf"
    sysctl_conf_backup="${sysctl_conf}.backup"
    sysctl_default="${sysctl_conf}.default"
    # 兼容老系统 /etc/sysctl.conf
    if [ ! -f "$sysctl_conf" ] && [ -f /etc/sysctl.conf ]; then
        sysctl_conf="/etc/sysctl.conf"
        sysctl_conf_backup="${sysctl_conf}.backup"
        sysctl_default="${sysctl_conf}.default"
    fi
    if [ -f "$sysctl_conf" ]; then
        if [ ! -f "$sysctl_conf_backup" ]; then
            cp "$sysctl_conf" "$sysctl_conf_backup"
        fi
        # 获取系统默认值
        while IFS= read -r line; do
            variable="${line%%=*}"
            variable="${variable%%[[:space:]]*}"
            default_value="${line#*=}"
            default_values["$variable"]="$default_value"
        done < <(sysctl -a)
        echo "" >"$sysctl_default"
        # 更新或添加变量
        for variable in "${!sysctl_vars[@]}"; do
            value="${sysctl_vars[$variable]}"
            if grep -q "^$variable" "$sysctl_conf"; then
                sed -i "s|^$variable.*|$variable=$value|" "$sysctl_conf"
            else
                echo "$variable=$value" >>"$sysctl_conf"
                default_value="${default_values[$variable]}"
                echo "$variable=$default_value" >>"$sysctl_default"
            fi
        done
        sysctl -p "$sysctl_conf" 2>/dev/null
    else
        # 配置文件不存在时直接创建并写入所有优化参数（无需备份原文件）
        _yellow "sysctl 配置文件不存在，创建 $sysctl_conf 并写入优化参数"
        touch "$sysctl_conf"
        for variable in "${!sysctl_vars[@]}"; do
            value="${sysctl_vars[$variable]}"
            echo "$variable=$value" >>"$sysctl_conf"
        done
        sysctl -p "$sysctl_conf" 2>/dev/null
    fi
}

check_cdn() {
    local o_url=$1
    for cdn_url in "${cdn_urls[@]}"; do
        if curl -sL -k "$cdn_url$o_url" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

check_cdn_file() {
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        _yellow "CDN available, using CDN"
    else
        _yellow "No CDN available, using original links"
        export cdn_success_url=""
    fi
}

check_time_zone() {
    _yellow "adjusting the time"
    if command -v ntpd >/dev/null 2>&1; then
        if which systemctl >/dev/null 2>&1; then
            systemctl stop chronyd
            systemctl stop ntpd
        else
            service chronyd stop
            service ntpd stop
        fi
        if lsof -i:123 | grep -q "ntpd"; then
            echo "Port 123 is already in use. Skipping ntpd command."
        else
            # 最多对准时长进行60秒，避免对准时间这个过程耗时过长
            if [ "$usage_timeout" = true ]; then
                timeout 60s ntpd -gq
            else
                ntpd -gq
            fi
            if which systemctl >/dev/null 2>&1; then
                systemctl start ntpd
            else
                service ntpd start
            fi
        fi
        sleep 0.5
        return
    fi
    if ! command -v chronyd >/dev/null 2>&1; then
        ${PACKAGE_INSTALL[int]} chrony >/dev/null 2>&1
    fi
    if which systemctl >/dev/null 2>&1; then
        systemctl stop chronyd
        chronyd -q -t 30
        systemctl start chronyd
    else
        service chronyd stop
        chronyd -q -t 30
        service chronyd start
    fi
    sleep 0.5
}

check_nat_type() {
    _yellow "NAT Type being detected ......"
    if [[ ! -z "$IPV4" ]]; then
        if [ -f "$TEMP_DIR/gostun" ]; then
            chmod 777 $TEMP_DIR/gostun
            output=$($TEMP_DIR/gostun | tail -n 1)
            if [[ $output == *"NAT Type"* ]]; then
                nat_type_r=$(echo "$output" | awk -F ':' '{print $NF}' | awk '{$1=$1;print}')
            else
                if [ "$en_status" = true ]; then
                    nat_type_r="The query fails, please try other architectures of https://github.com/oneclickvirt/gostun by yourself"
                else
                    nat_type_r="查询失败，请自行尝试 https://github.com/oneclickvirt/gostun 的其他架构"
                fi
            fi
        fi
    fi
}

check_china() {
    _yellow "IP area being detected ......"
    if [[ -z "${CN}" ]]; then
        if [[ $(curl -m 6 -s https://ipapi.co/json | grep 'China') != "" ]]; then
            if [ "$en_status" = true ]; then
                _yellow "According to ipapi.co, current IP may be in China"
            else
                _yellow "根据ipapi.co提供的信息，当前IP可能在中国"
            fi
            # 非交互（参数）模式下自动使用中国镜像，避免永久挂起等待输入
            if [ "$menu_mode" = false ]; then
                CN=true
                return
            fi
            if [ "$en_status" = true ]; then
                read -e -r -p "Use Chinese mirror to install components? ([y]/n) " input
            else
                read -e -r -p "是否选用中国镜像完成相关组件安装? ([y]/n) " input
            fi
            case $input in
            [yY][eE][sS] | [yY])
                if [ "$en_status" = true ]; then echo "Using Chinese mirror"; else echo "使用中国镜像"; fi
                CN=true
                ;;
            [nN][oO] | [nN])
                if [ "$en_status" = true ]; then echo "Not using Chinese mirror"; else echo "不使用中国镜像"; fi
                ;;
            *)
                if [ "$en_status" = true ]; then echo "Using Chinese mirror"; else echo "使用中国镜像"; fi
                CN=true
                ;;
            esac
        fi
    fi
}

statistics_of_run_times() {
    COUNT=$(curl -ksm10 "https://hits.spiritlhl.net/ecs?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false" 2>/dev/null)
    if [ -z "$COUNT" ]; then
        TODAY="N/A"
        TOTAL="N/A"
    else
        TODAY=$(echo "$COUNT" | grep -oP '"daily":\s*[0-9]+' | sed 's/"daily":\s*\([0-9]*\)/\1/')
        TOTAL=$(echo "$COUNT" | grep -oP '"total":\s*[0-9]+' | sed 's/"total":\s*\([0-9]*\)/\1/')
        [ -z "$TODAY" ] && TODAY="N/A"
        [ -z "$TOTAL" ] && TOTAL="N/A"
    fi
}

# =============== 基础系统信息 部分 ===============
systemInfo_get_os_release() {
    local regex_size=${#REGEX[@]}
    for ((i = 0; i < regex_size; i++)); do
        local pattern="${REGEX[i]}"
        if [ -f "/etc/debian_version" ] && [[ "$pattern" == "debian|astra" ]]; then
            Var_OSRelease="debian"
            break
        elif [ -f "/etc/lsb-release" ] && [[ "$pattern" == "ubuntu" ]]; then
            Var_OSRelease="ubuntu"
            break
        elif [ -f "/etc/redhat-release" ] && [[ "$pattern" == "centos|red hat|kernel|oracle linux|alma|rocky" ]]; then
            Var_OSRelease="centos"
            break
        elif [ -f "/etc/amazon-linux-release" ] && [[ "$pattern" == "'amazon linux'" ]]; then
            Var_OSRelease="centos"
            break
        elif [ -f "/etc/fedora-release" ] && [[ "$pattern" == "fedora" ]]; then
            Var_OSRelease="fedora"
            break
        elif [ -f "/etc/arch-release" ] && [[ "$pattern" == "arch" ]]; then
            Var_OSRelease="arch"
            break
        elif [ -f "/etc/freebsd-update.conf" ] && [[ "$pattern" == "freebsd" ]]; then
            Var_OSRelease="freebsd"
            break
        elif [ -f "/etc/alpine-release" ] && [[ "$pattern" == "alpine" ]]; then
            Var_OSRelease="alpinelinux"
            break
        elif [ -f "/etc/openbsd.conf" ] && [[ "$pattern" == "openbsd" ]]; then
            Var_OSRelease="openbsd"
            break
        elif [ -f "/etc/opencloudos-release" ] && [[ "$pattern" == "opencloudos" ]]; then
            Var_OSRelease="opencloudos"
            break
        fi
    done
    if [ -z "$Var_OSRelease" ]; then
        Var_OSRelease="unknown"
    fi
    if [ -f /etc/os-release ]; then
        DISTRO=$(grep 'PRETTY_NAME' /etc/os-release | cut -d '"' -f 2)
    fi
}

get_system_bit() {
    local sysarch="$(uname -m)"
    if [ "${sysarch}" = "unknown" ] || [ "${sysarch}" = "" ]; then
        local sysarch="$(arch)"
    fi
    # 根据架构信息设置系统位数并下载文件,其余 * 包括了 x86_64
    case "${sysarch}" in
    "i386" | "i686")
        LBench_Result_SystemBit_Short="32"
        LBench_Result_SystemBit_Full="i386"
        GOSTUN_FILE=gostun-linux-386
        # BESTTRACE_FILE=besttracemac
        UnlockTests_FILE=ut-linux-386
        SecurityCheck_FILE=securityCheck-linux-386
        PortChecker_FILE=portchecker-linux-386
        BACKTRACE_FILE=backtrace-linux-386
        NEXTTRACE_FILE=nexttrace_linux_386
        ;;
    "armv7l" | "armv8" | "armv8l" | "aarch64" | "arm64")
        LBench_Result_SystemBit_Short="arm"
        LBench_Result_SystemBit_Full="arm"
        GOSTUN_FILE=gostun-linux-arm64
        # BESTTRACE_FILE=besttracearm
        UnlockTests_FILE=ut-linux-arm64
        SecurityCheck_FILE=securityCheck-linux-arm64
        PortChecker_FILE=portchecker-linux-arm64
        BACKTRACE_FILE=backtrace-linux-arm64
        NEXTTRACE_FILE=nexttrace_linux_arm64
        ;;
    *)
        LBench_Result_SystemBit_Short="64"
        LBench_Result_SystemBit_Full="amd64"
        GOSTUN_FILE=gostun-linux-amd64
        # BESTTRACE_FILE=besttrace
        UnlockTests_FILE=ut-linux-amd64
        SecurityCheck_FILE=securityCheck-linux-amd64
        PortChecker_FILE=portchecker-linux-amd64
        BACKTRACE_FILE=backtrace-linux-amd64
        NEXTTRACE_FILE=nexttrace_linux_amd64
        ;;
    esac
}

# https://github.com/LemonBench/LemonBench/blob/main/LemonBench.sh
# ===========================================================================
# -> 系统信息模块 (Entrypoint) -> 执行
function BenchFunc_Systeminfo_GetSysteminfo() {
    BenchAPI_Systeminfo_GetCPUinfo
    BenchAPI_Systeminfo_GetVMMinfo
    BenchAPI_Systeminfo_GetMemoryinfo
    BenchAPI_Systeminfo_GetDiskinfo
    BenchAPI_Systeminfo_GetOSReleaseinfo
    # BenchAPI_Systeminfo_GetLinuxKernelinfo
}
#
# -> 系统信息模块 (Collector) -> 获取CPU信息
function BenchAPI_Systeminfo_GetCPUinfo() {
    # CPU 基础信息检测
    local r_modelname && r_modelname="$(lscpu -B 2>/dev/null | grep -oP -m1 "(?<=Model name:).*(?=)" | sed -e 's/^[ ]*//g')"
    local r_cachesize_l1d_b && r_cachesize_l1d_b="$(lscpu -B 2>/dev/null | grep -oP "(?<=L1d cache:).*(?=)" | sed -e 's/^[ ]*//g')"
    local r_cachesize_l1i_b && r_cachesize_l1i_b="$(lscpu -B 2>/dev/null | grep -oP "(?<=L1i cache:).*(?=)" | sed -e 's/^[ ]*//g')"
    local r_cachesize_l1_b && r_cachesize_l1_b="$(echo "$r_cachesize_l1d_b" "$r_cachesize_l1i_b" | awk '{printf "%d\n",$1+$2}')"
    local r_cachesize_l1_k && r_cachesize_l1_k="$(echo "$r_cachesize_l1_b" | awk '{printf "%.2f\n",$1/1024}')"
    local t_cachesize_l1_k && t_cachesize_l1_k="$(echo "$r_cachesize_l1_b" | awk '{printf "%d\n",$1/1024}')"
    if [ "$t_cachesize_l1_k" -ge "1024" ]; then
        local r_cachesize_l1_m && r_cachesize_l1_m="$(echo "$r_cachesize_l1_k" | awk '{printf "%.2f\n",$1/1024}')"
        local r_cachesize_l1="$r_cachesize_l1_m MB"
    else
        local r_cachesize_l1="$r_cachesize_l1_k KB"
    fi
    local r_cachesize_l2_b && r_cachesize_l2_b="$(lscpu -B 2>/dev/null | grep -oP "(?<=L2 cache:).*(?=)" | sed -e 's/^[ ]*//g')"
    local r_cachesize_l2_k && r_cachesize_l2_k="$(echo "$r_cachesize_l2_b" | awk '{printf "%.2f\n",$1/1024}')"
    local t_cachesize_l2_k && t_cachesize_l2_k="$(echo "$r_cachesize_l2_b" | awk '{printf "%d\n",$1/1024}')"
    if [ "$t_cachesize_l2_k" -ge "1024" ]; then
        local r_cachesize_l2_m && r_cachesize_l2_m="$(echo "$r_cachesize_l2_k" | awk '{printf "%.2f\n",$1/1024}')"
        local r_cachesize_l2="$r_cachesize_l2_m MB"
    else
        local r_cachesize_l2="$r_cachesize_l2_k KB"
    fi
    local r_cachesize_l3_b && r_cachesize_l3_b="$(lscpu -B 2>/dev/null | grep -oP "(?<=L3 cache:).*(?=)" | sed -e 's/^[ ]*//g')"
    local r_cachesize_l3_k && r_cachesize_l3_k="$(echo "$r_cachesize_l3_b" | awk '{printf "%.2f\n",$1/1024}')"
    local t_cachesize_l3_k && t_cachesize_l3_k="$(echo "$r_cachesize_l3_b" | awk '{printf "%d\n",$1/1024}')"
    if [ "$t_cachesize_l3_k" -ge "1024" ]; then
        local r_cachesize_l3_m && r_cachesize_l3_m="$(echo "$r_cachesize_l3_k" | awk '{printf "%.2f\n",$1/1024}')"
        local r_cachesize_l3="$r_cachesize_l3_m MB"
    else
        local r_cachesize_l3="$r_cachesize_l3_k KB"
    fi
    local r_sockets && r_sockets="$(lscpu -B 2>/dev/null | grep -oP "(?<=Socket\(s\):).*(?=)" | sed -e 's/^[ ]*//g')"
    local is_hybrid_cpu=0
    if grep -q "Intel" /proc/cpuinfo 2>/dev/null; then
        local cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | sed 's/.*: //')
        # 检测混合架构CPU
        local cpu_types=$(grep "model name" /proc/cpuinfo 2>/dev/null | sort -u | wc -l)
        if [ "$cpu_types" -gt 1 ]; then
            # 如果存在多种CPU型号名称，很可能是混合架构
            is_hybrid_cpu=1
        elif echo "$cpu_model" | grep -qE "(1[2-5]th Gen)"; then
            # 明确已知的混合架构：12代(Alder Lake), 13代(Raptor Lake), 14代(Raptor Lake Refresh), 15代(Meteor Lake)
            is_hybrid_cpu=1
        elif [ -d "/sys/devices/system/cpu/cpu0/cache" ]; then
            # 检查是否存在不同大小的L2缓存（P核和E核的L2缓存大小通常不同）
            local l2_sizes=$(find /sys/devices/system/cpu/cpu*/cache/index2/size 2>/dev/null | xargs cat 2>/dev/null | sort -u | wc -l)
            if [ "$l2_sizes" -gt 1 ]; then
                is_hybrid_cpu=1
            fi
        fi
    fi
    local actual_cores=$(grep -c "^core id" /proc/cpuinfo 2>/dev/null || echo "0")
    local actual_threads=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "0")
    if [ "$r_sockets" -ge "2" ]; then
        local r_cores && r_cores="$(lscpu -B 2>/dev/null | grep -oP "(?<=Core\(s\) per socket:).*(?=)" | sed -e 's/^[ ]*//g')"
        r_cores="$(echo "$r_sockets" "$r_cores" | awk '{printf "%d\n",$1*$2}')"
        local r_threadpercore && r_threadpercore="$(lscpu -B 2>/dev/null | grep -oP "(?<=Thread\(s\) per core:).*(?=)" | sed -e 's/^[ ]*//g')"
        local r_threads && r_threads="$(echo "$r_cores" "$r_threadpercore" | awk '{printf "%d\n",$1*$2}')"
        r_threads="$(echo "$r_threadpercore" "$r_cores" | awk '{printf "%d\n",$1*$2}')"
    else
        local r_cores && r_cores="$(lscpu -B 2>/dev/null | grep -oP "(?<=Core\(s\) per socket:).*(?=)" | sed -e 's/^[ ]*//g')"
        local r_threadpercore && r_threadpercore="$(lscpu -B 2>/dev/null | grep -oP "(?<=Thread\(s\) per core:).*(?=)" | sed -e 's/^[ ]*//g')"
        local r_threads && r_threads="$(echo "$r_cores" "$r_threadpercore" | awk '{printf "%d\n",$1*$2}')"
    fi
    if [ "$is_hybrid_cpu" -eq 1 ] && [ "$actual_threads" -gt 0 ]; then
        local unique_cores=$(awk -F': ' '/core id/{print $2}' /proc/cpuinfo 2>/dev/null | sort -u | wc -l)
        if [ "$unique_cores" -gt 0 ]; then
            r_cores="$unique_cores"
        fi
        r_threads="$actual_threads"
        # 对于混合架构，线程数/核心数的比例可能不是整数（因为P核有超线程，E核没有）
        # 所以不可简单地用 cores * threadpercore 来计算，这块覆写修复原计算问题
    fi
    # CPU AES能力检测
    # local t_aes && t_aes="$(awk -F ': ' '/flags/{print $2}' /proc/cpuinfo 2>/dev/null | grep -oE "\baes\b" | sort -u)"
    # [[ "${t_aes}" = "aes" ]] && Result_Systeminfo_CPUAES="1" || Result_Systeminfo_CPUAES="0"
    # CPU AVX能力检测
    # local t_avx && t_avx="$(awk -F ': ' '/flags/{print $2}' /proc/cpuinfo 2>/dev/null | grep -oE "\bavx\b" | sort -u)"
    # [[ "${t_avx}" = "avx" ]] && Result_Systeminfo_CPUAVX="1" || Result_Systeminfo_CPUAVX="0"
    # CPU AVX512能力检测
    # local t_avx512 && t_avx512="$(awk -F ': ' '/flags/{print $2}' /proc/cpuinfo 2>/dev/null | grep -oE "\bavx512\b" | sort -u)"
    # [[ "${t_avx512}" = "avx" ]] && Result_Systeminfo_CPUAVX512="1" || Result_Systeminfo_CPUAVX512="0"
    # CPU 虚拟化能力检测
    local t_vmx_vtx && t_vmx_vtx="$(awk -F ': ' '/flags/{print $2}' /proc/cpuinfo 2>/dev/null | grep -oE "\bvmx\b" | sort -u)"
    local t_vmx_svm && t_vmx_svm="$(awk -F ': ' '/flags/{print $2}' /proc/cpuinfo 2>/dev/null | grep -oE "\bsvm\b" | sort -u)"
    if [ "$t_vmx_vtx" = "vmx" ]; then
        Result_Systeminfo_VirtReady="1"
        Result_Systeminfo_CPUVMX="Intel VT-x"
    elif [ "$t_vmx_svm" = "svm" ]; then
        Result_Systeminfo_VirtReady="1"
        Result_Systeminfo_CPUVMX="AMD-V"
    else
        if [ -c "/dev/kvm" ]; then
            Result_Systeminfo_VirtReady="1"
            Result_Systeminfo_CPUVMX="unknown"
        else
            Result_Systeminfo_VirtReady="0"
            Result_Systeminfo_CPUVMX="unknown"
        fi
    fi
    # 输出结果
    Result_Systeminfo_CPUModelName="$r_modelname"
    Result_Systeminfo_CPUSockets="$r_sockets"
    Result_Systeminfo_CPUCores="$r_cores"
    Result_Systeminfo_CPUThreads="$r_threads"
    Result_Systeminfo_CPUCacheSizeL1="$r_cachesize_l1"
    Result_Systeminfo_CPUCacheSizeL2="$r_cachesize_l2"
    Result_Systeminfo_CPUCacheSizeL3="$r_cachesize_l3"
}
#
# -> 系统信息模块 (Collector) -> 获取内存及Swap信息
function BenchAPI_Systeminfo_GetMemoryinfo() {
    # 内存信息
    local r_memtotal_kib && r_memtotal_kib="$(awk '/MemTotal/{print $2}' /proc/meminfo | head -n1)"
    local r_memtotal_mib && r_memtotal_mib="$(echo "$r_memtotal_kib" | awk '{printf "%.2f\n",$1/1024}')"
    local r_memtotal_gib && r_memtotal_gib="$(echo "$r_memtotal_kib" | awk '{printf "%.2f\n",$1/1048576}')"
    local r_meminfo_memfree_kib && r_meminfo_memfree_kib="$(awk '/MemFree/{print $2}' /proc/meminfo | head -n1)"
    local r_meminfo_buffers_kib && r_meminfo_buffers_kib="$(awk '/Buffers/{print $2}' /proc/meminfo | head -n1)"
    local r_meminfo_cached_kib && r_meminfo_cached_kib="$(awk '/^Cached:/{print $2}' /proc/meminfo | head -n1)"
    local r_memfree_kib && r_memfree_kib="$(echo "$r_meminfo_memfree_kib" "$r_meminfo_buffers_kib" "$r_meminfo_cached_kib" | awk '{printf $1+$2+$3}')"
    local r_memfree_mib && r_memfree_mib="$(echo "$r_memfree_kib" | awk '{printf "%.2f\n",$1/1024}')"
    local r_memfree_gib && r_memfree_gib="$(echo "$r_memfree_kib" | awk '{printf "%.2f\n",$1/1048576}')"
    local r_memused_kib && r_memused_kib="$(echo "$r_memtotal_kib" "$r_memfree_kib" | awk '{printf $1-$2}')"
    local r_memused_mib && r_memused_mib="$(echo "$r_memused_kib" | awk '{printf "%.2f\n",$1/1024}')"
    local r_memused_gib && r_memused_gib="$(echo "$r_memused_kib" | awk '{printf "%.2f\n",$1/1048576}')"
    # 交换信息
    local r_swaptotal_kib && r_swaptotal_kib="$(awk '/SwapTotal/{print $2}' /proc/meminfo | head -n1)"
    local r_swaptotal_mib && r_swaptotal_mib="$(echo "$r_swaptotal_kib" | awk '{printf "%.2f\n",$1/1024}')"
    local r_swaptotal_gib && r_swaptotal_gib="$(echo "$r_swaptotal_kib" | awk '{printf "%.2f\n",$1/1048576}')"
    local r_swapfree_kib && r_swapfree_kib="$(awk '/SwapFree/{print $2}' /proc/meminfo | head -n1)"
    local r_swapfree_mib && r_swapfree_mib="$(echo "$r_swapfree_kib" | awk '{printf "%.2f\n",$1/1024}')"
    local r_swapfree_gib && r_swapfree_gib="$(echo "$r_swapfree_kib" | awk '{printf "%.2f\n",$1/1048576}')"
    local r_swapused_kib && r_swapused_kib="$(echo "$r_swaptotal_kib" "${r_swapfree_kib}" | awk '{printf $1-$2}')"
    local r_swapused_mib && r_swapused_mib="$(echo "$r_swapused_kib" | awk '{printf "%.2f\n",$1/1024}')"
    local r_swapused_gib && r_swapused_gib="$(echo "$r_swapused_kib" | awk '{printf "%.2f\n",$1/1048576}')"
    # 数据加工
    if [ "$r_memused_kib" -lt "1024" ] && [ "$r_memtotal_kib" -lt "1048576" ]; then
        Result_Systeminfo_Memoryinfo="$r_memused_kib KiB / $r_memtotal_mib MiB"
    elif [ "$r_memused_kib" -lt "1048576" ] && [ "$r_memtotal_kib" -lt "1048576" ]; then
        Result_Systeminfo_Memoryinfo="$r_memused_mib MiB / $r_memtotal_mib MiB"
    elif [ "$r_memused_kib" -lt "1048576" ] && [ "$r_memtotal_kib" -lt "1073741824" ]; then
        Result_Systeminfo_Memoryinfo="$r_memused_mib MiB / $r_memtotal_gib GiB"
    else
        Result_Systeminfo_Memoryinfo="$r_memused_gib GiB / $r_memtotal_gib GiB"
    fi
    if [ "$r_swaptotal_kib" -eq "0" ]; then
        Result_Systeminfo_Swapinfo="[ no swap partition or swap file detected ]"
    elif [ "$r_swapused_kib" -lt "1024" ] && [ "$r_swaptotal_kib" -lt "1048576" ]; then
        Result_Systeminfo_Swapinfo="$r_swapused_kib KiB / $r_swaptotal_mib MiB"
    elif [ "$r_swapused_kib" -lt "1024" ] && [ "$r_swaptotal_kib" -lt "1073741824" ]; then
        Result_Systeminfo_Swapinfo="$r_swapused_kib KiB / $r_swaptotal_gib GiB"
    elif [ "$r_swapused_kib" -lt "1048576" ] && [ "$r_swaptotal_kib" -lt "1048576" ]; then
        Result_Systeminfo_Swapinfo="$r_swapused_mib MiB / $r_swaptotal_mib MiB"
    elif [ "$r_swapused_kib" -lt "1048576" ] && [ "$r_swaptotal_kib" -lt "1073741824" ]; then
        Result_Systeminfo_Swapinfo="$r_swapused_mib MiB / $r_swaptotal_gib GiB"
    else
        Result_Systeminfo_Swapinfo="$r_swapused_gib GiB / $r_swaptotal_gib GiB"
    fi
}
#
# -> 系统信息模块 (Collector) -> 获取磁盘信息
function BenchAPI_Systeminfo_GetDiskinfo() {
    # 磁盘信息
    local r_diskpath_root && r_diskpath_root="$(df -x tmpfs / | awk "NR>1" | sed ":a;N;s/\\n//g;ta" | awk '{print $1}')"
    local r_disktotal_kib && r_disktotal_kib="$(df -x tmpfs / | grep -oE "[0-9]{4,}" | awk 'NR==1 {print $1}')"
    local r_disktotal_mib && r_disktotal_mib="$(echo "$r_disktotal_kib" | awk '{printf "%.2f\n",$1/1024}')"
    local r_disktotal_gib && r_disktotal_gib="$(echo "$r_disktotal_kib" | awk '{printf "%.2f\n",$1/1048576}')"
    local r_disktotal_tib && r_disktotal_tib="$(echo "$r_disktotal_kib" | awk '{printf "%.2f\n",$1/1073741824}')"
    local r_diskused_kib && r_diskused_kib="$(df -x tmpfs / | grep -oE "[0-9]{4,}" | awk 'NR==2 {print $1}')"
    local r_diskused_mib && r_diskused_mib="$(echo "$r_diskused_kib" | awk '{printf "%.2f\n",$1/1024}')"
    local r_diskused_gib && r_diskused_gib="$(echo "$r_diskused_kib" | awk '{printf "%.2f\n",$1/1048576}')"
    local r_diskused_tib && r_diskused_tib="$(echo "$r_diskused_kib" | awk '{printf "%.2f\n",$1/1073741824}')"
    local r_diskfree_kib && r_diskfree_kib="$(df -x tmpfs / | grep -oE "[0-9]{4,}" | awk 'NR==3 {print $1}')"
    local r_diskfree_mib && r_diskfree_mib="$(echo "$r_diskfree_kib" | awk '{printf "%.2f\n",$1/1024}')"
    local r_diskfree_gib && r_diskfree_gib="$(echo "$r_diskfree_kib" | awk '{printf "%.2f\n",$1/1048576}')"
    local r_diskfree_tib && r_diskfree_tib="$(echo "$r_diskfree_kib" | awk '{printf "%.2f\n",$1/1073741824}')"
    # 数据加工
    Result_Systeminfo_DiskRootPath="$r_diskpath_root"
    if [ "$r_diskused_kib" -lt "1048576" ] && [ "$r_disktotal_kib" -lt "1048576" ]; then
        Result_Systeminfo_Diskinfo="$r_diskused_mib MiB / $r_disktotal_mib MiB"
    elif [ "$r_diskused_kib" -lt "1048576" ] && [ "$r_disktotal_kib" -lt "1073741824" ]; then
        Result_Systeminfo_Diskinfo="$r_diskused_mib MiB / $r_disktotal_gib GiB"
    elif [ "$r_diskused_kib" -lt "1073741824" ] && [ "$r_disktotal_kib" -lt "1073741824" ]; then
        Result_Systeminfo_Diskinfo="$r_diskused_gib GiB / $r_disktotal_gib GiB"
    elif [ "$r_diskused_kib" -lt "1073741824" ] && [ "$r_disktotal_kib" -ge "1073741824" ]; then
        Result_Systeminfo_Diskinfo="$r_diskused_gib GiB / $r_disktotal_tib TiB"
    else
        Result_Systeminfo_Diskinfo="$r_diskused_tib TiB / $r_disktotal_tib TiB"
    fi
}
#
# -> 系统信息模块 (Collector) -> 获取虚拟化信息
function BenchAPI_Systeminfo_GetVMMinfo() {
    if [ -f "/usr/bin/systemd-detect-virt" ]; then
        local r_vmmtype && r_vmmtype="$(/usr/bin/systemd-detect-virt 2>/dev/null)"
        case "${r_vmmtype}" in
        kvm)
            Result_Systeminfo_VMMType="KVM"
            Result_Systeminfo_VMMTypeShort="kvm"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        xen)
            Result_Systeminfo_VMMType="Xen Hypervisor"
            Result_Systeminfo_VMMTypeShort="xen"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        microsoft)
            Result_Systeminfo_VMMType="Microsoft Hyper-V"
            Result_Systeminfo_VMMTypeShort="microsoft"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        vmware)
            Result_Systeminfo_VMMType="VMware"
            Result_Systeminfo_VMMTypeShort="vmware"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        oracle)
            Result_Systeminfo_VMMType="Oracle VirtualBox"
            Result_Systeminfo_VMMTypeShort="oracle"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        parallels)
            Result_Systeminfo_VMMType="Parallels"
            Result_Systeminfo_VMMTypeShort="parallels"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        qemu)
            Result_Systeminfo_VMMType="QEMU"
            Result_Systeminfo_VMMTypeShort="qemu"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        amazon)
            Result_Systeminfo_VMMType="Amazon Virtualization"
            Result_Systeminfo_VMMTypeShort="amazon"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        docker)
            Result_Systeminfo_VMMType="Docker"
            Result_Systeminfo_VMMTypeShort="docker"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        openvz)
            Result_Systeminfo_VMMType="OpenVZ (Virutozzo)"
            Result_Systeminfo_VMMTypeShort="openvz"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        lxc)
            Result_Systeminfo_VMMTypeShort="lxc"
            Result_Systeminfo_VMMType="LXC"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        lxc-libvirt)
            Result_Systeminfo_VMMType="LXC (Based on libvirt)"
            Result_Systeminfo_VMMTypeShort="lxc-libvirt"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        uml)
            Result_Systeminfo_VMMType="User-mode Linux"
            Result_Systeminfo_VMMTypeShort="uml"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        systemd-nspawn)
            Result_Systeminfo_VMMType="Systemd nspawn"
            Result_Systeminfo_VMMTypeShort="systemd-nspawn"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        bochs)
            Result_Systeminfo_VMMType="BOCHS"
            Result_Systeminfo_VMMTypeShort="bochs"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        rkt)
            Result_Systeminfo_VMMType="RKT"
            Result_Systeminfo_VMMTypeShort="rkt"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        zvm)
            Result_Systeminfo_VMMType="S390 Z/VM"
            Result_Systeminfo_VMMTypeShort="zvm"
            Result_Systeminfo_isPhysical="0"
            return 0
            ;;
        none)
            Result_Systeminfo_VMMType="Dedicated"
            Result_Systeminfo_VMMTypeShort="none"
            Result_Systeminfo_isPhysical="1"
            if test -f "/sys/class/iommu/dmar0/uevent"; then
                Result_Systeminfo_IOMMU="1"
            else
                Result_Systeminfo_IOMMU="0"
            fi
            return 0
            ;;
        *)
            echo -e "${Msg_Error} BenchAPI_Systeminfo_GetVirtinfo(): invalid result (${r_vmmtype}), please check parameter!"
            ;;
        esac
    fi
    if [ -f "/.dockerenv" ]; then
        Result_Systeminfo_VMMType="Docker"
        Result_Systeminfo_VMMTypeShort="docker"
        Result_Systeminfo_isPhysical="0"
        return 0
    elif [ -c "/dev/lxss" ]; then
        Result_Systeminfo_VMMType="Windows Subsystem for Linux"
        Result_Systeminfo_VMMTypeShort="wsl"
        Result_Systeminfo_isPhysical="0"
        return 0
    else
        if [ -f "/proc/1/cgroup" ] && grep -q "docker" /proc/1/cgroup 2>/dev/null; then
            Result_Systeminfo_VMMType="Docker"
            Result_Systeminfo_VMMTypeShort="docker"
            Result_Systeminfo_isPhysical="0"
            return 0
        fi
        Result_Systeminfo_VMMType="Dedicated"
        Result_Systeminfo_VMMTypeShort="none"
        if test -f "/sys/class/iommu/dmar0/uevent"; then
            Result_Systeminfo_IOMMU="1"
        else
            Result_Systeminfo_IOMMU="0"
        fi
        return 0
    fi
}
#
# -> 系统信息模块 (Collector) -> 获取Linux发行版信息
function BenchAPI_Systeminfo_GetOSReleaseinfo() {
    local r_arch && r_arch="$(arch)"
    Result_Systeminfo_OSArch="$r_arch"
    # CentOS/Red Hat 判断
    if [ -f "/etc/centos-release" ] || [ -f "/etc/redhat-release" ]; then
        Result_Systeminfo_OSReleaseNameShort="centos"
        local r_prettyname && r_prettyname="$(grep -oP '(?<=\bPRETTY_NAME=").*(?=")' /etc/os-release)"
        local r_elrepo_version && r_elrepo_version="$(rpm -qa | grep -oP "el[0-9]+" | sort -ur | head -n1)"
        case "$r_elrepo_version" in
        9 | el9)
            Result_Systeminfo_OSReleaseVersionShort="9"
            Result_Systeminfo_OSReleaseNameFull="$r_prettyname ($r_arch)"
            return 0
            ;;
        8 | el8)
            Result_Systeminfo_OSReleaseVersionShort="8"
            Result_Systeminfo_OSReleaseNameFull="$r_prettyname ($r_arch)"
            return 0
            ;;
        7 | el7)
            Result_Systeminfo_OSReleaseVersionShort="7"
            Result_Systeminfo_OSReleaseNameFull="$r_prettyname ($r_arch)"
            return 0
            ;;
        6 | el6)
            Result_Systeminfo_OSReleaseVersionShort="6"
            Result_Systeminfo_OSReleaseNameFull="$r_prettyname ($r_arch)"
            return 0
            ;;
        *)
            echo -e "${Msg_Error} BenchAPI_Systeminfo_GetOSReleaseinfo(): unknown CentOS/Redhat version ($r_prettyname), using fallback"
            Result_Systeminfo_OSReleaseVersionShort="unknown"
            Result_Systeminfo_OSReleaseNameFull="$r_prettyname ($r_arch)"
            return 0
            ;;
        esac
    elif [ -f "/etc/lsb-release" ]; then # Ubuntu
        Result_Systeminfo_OSReleaseNameShort="ubuntu"
        local r_prettyname && r_prettyname="$(grep -oP '(?<=\bPRETTY_NAME=").*(?=")' /etc/os-release)"
        Result_Systeminfo_OSReleaseVersion="$(grep -oP '(?<=\bVERSION=").*(?=")' /etc/os-release)"
        Result_Systeminfo_OSReleaseVersionShort="$(grep -oP '(?<=\bVERSION_ID=").*(?=")' /etc/os-release)"
        Result_Systeminfo_OSReleaseNameFull="$r_prettyname ($r_arch)"
        return 0
    elif [ -f "/etc/debian_version" ]; then # Debian
        Result_Systeminfo_OSReleaseNameShort="debian"
        local r_prettyname && r_prettyname="$(grep -oP '(?<=\bPRETTY_NAME=").*(?=")' /etc/os-release)"
        Result_Systeminfo_OSReleaseVersion="$(grep -oP '(?<=\bVERSION=").*(?=")' /etc/os-release)"
        Result_Systeminfo_OSReleaseVersionShort="$(grep -oP '(?<=\bVERSION_ID=").*(?=")' /etc/os-release)"
        Result_Systeminfo_OSReleaseNameFull="$r_prettyname ($r_arch)"
        return 0
    else
        echo -e "${Msg_Error} BenchAPI_Systeminfo_GetOSReleaseinfo(): invalid result ($r_prettyname ($r_arch)), please check parameter!"
    fi
}
#
# -> 系统信息模块 (Collector) -> 获取Linux内核版本信息
# function BenchAPI_Systeminfo_GetLinuxKernelinfo() {
#     # 获取原始数据
#     Result_Systeminfo_LinuxKernelVersion="$(uname -r)"
# }
# ===========================================================================

# =============== sysbench组件检测 部分 ===============
get_sysbench_os_release() {
    local OS_TYPE
    case "${Var_OSRelease}" in
    centos | rhel | almalinux | opencloudos) OS_TYPE="redhat" ;;
    ubuntu) OS_TYPE="ubuntu" ;;
    debian) OS_TYPE="debian" ;;
    fedora) OS_TYPE="fedora" ;;
    alpinelinux) OS_TYPE="alpinelinux" ;;
    arch) OS_TYPE="arch" ;;
    freebsd) OS_TYPE="freebsd" ;;
    openbsd) OS_TYPE="openbsd" ;;
    *) OS_TYPE="unknown" ;;
    esac
    echo "${OS_TYPE}"
}

InstallSysbench() {
    local os_release=$1
    case "$os_release" in
    ubuntu)
        apt-get -y install sysbench || {
            apt-get --fix-broken install -y
            apt-get --no-install-recommends -y install sysbench
        }
        ;;
    debian)
        apt-get -y install sysbench || {
            apt-get --fix-broken install -y
            apt-get --no-install-recommends -y install sysbench
        }
        ;;
    redhat)
        yum -y install epel-release && yum -y install sysbench || {
            cleanup_epel
            dnf install epel-release -y && dnf install sysbench -y || {
                _red "Sysbench installation failed!"
                return 1
            }
        }
        ;;
    fedora)
        dnf -y install sysbench || {
            _red "Sysbench installation failed!"
            return 1
        }
        ;;
    arch)
        pacman -S --needed --noconfirm sysbench libaio && ldconfig || {
            _red "Sysbench installation failed!"
            return 1
        }
        ;;
    freebsd)
        pkg install -y sysbench || {
            _red "Sysbench installation failed!"
            return 1
        }
        ;;
    openbsd)
        pkg_add -I sysbench || {
            _red "Sysbench installation failed!"
            return 1
        }
        ;;
    alpinelinux)
        echo -e "${Msg_Warning}SysBench not supported on Alpine Linux, skipping..."
        Var_Skip_SysBench="1"
        ;;
    *)
        echo "Error: Unknown OS release: $os_release"
        exit 1
        ;;
    esac
}

Check_SysBench() {
    if [ ! -f "/usr/bin/sysbench" ] && [ ! -f "/usr/local/bin/sysbench" ]; then
        local os_release=$(get_sysbench_os_release)
        if [ "$os_release" = "alpinelinux" ]; then
            Var_Skip_SysBench="1"
        else
            InstallSysbench "$os_release"
        fi
    fi
    # 尝试编译安装
    if [ ! -f "/usr/bin/sysbench" ] && [ ! -f "/usr/local/bin/sysbench" ]; then
        echo -e "${Msg_Warning}Sysbench Module install Failure, trying compile modules ..."
        Check_Sysbench_InstantBuild
    fi
    source ~/.bashrc
    # 最终检测
    if [ "$(command -v sysbench)" ] || [ -f "/usr/bin/sysbench" ] || [ -f "/usr/local/bin/sysbench" ]; then
        _yellow "Install sysbench successfully!"
    else
        _red "SysBench Moudle install Failure! Try Restart Bench or Manually install it! (/usr/bin/sysbench)"
        _blue "Will try to test with geekbench5 instead later on"
        error_exit
        test_cpu_type="gb5"
    fi
    sleep 3
}

Check_Sysbench_InstantBuild() {
    # 检查是否支持编译安装
    local supported_systems="centos|rhel|almalinux|opencloudos|ubuntu|debian|fedora|arch"
    if [[ ! ${Var_OSRelease} =~ $supported_systems ]]; then
        echo -e "${Msg_Warning}Unsupported operating system: ${Var_OSRelease}"
        return
    fi
    # 使用包管理器对应关系
    local os_type=${Var_OSRelease}
    case "$os_type" in
    "opencloudos") os_type="centos" ;;
    "rhel") os_type="centos" ;;
    "almalinux") os_type="centos" ;;
    esac
    echo -e "${Msg_Info}Release Detected: ${os_type}"
    echo -e "${Msg_Info}Preparing compile environment..."
    prepare_compile_env "${os_type}"
    echo -e "${Msg_Info}Downloading Source code (Version 1.0.20)..."
    mkdir -p /tmp/_LBench/src/
    dfiles=(sysbench)
    start_downloads "${dfiles[@]}"
    mv ${TEMP_DIR}/sysbench-1.0.20 /tmp/_LBench/src/
    echo -e "${Msg_Info}Compiling Sysbench Module..."
    cd /tmp/_LBench/src/sysbench-1.0.20
    ./autogen.sh && ./configure --without-mysql && make -j8 && make install
    echo -e "${Msg_Info}Cleaning up..."
    cd /tmp
    rm -rf /tmp/_LBench/src/sysbench*
}

cleanup_epel() {
    _yellow "Cleaning up EPEL repositories..."
    rm -f /etc/yum.repos.d/*epel*
    yum clean all
}

prepare_compile_env() {
    local system="$1"
    case "${system}" in
    redhat)
        yum install -y epel-release || {
            cleanup_epel
            _yellow "EPEL installation failed, continuing..."
        }
        yum install -y wget curl make gcc gcc-c++ make automake libtool pkgconfig libaio-devel || {
            _red "Failed to install build dependencies!"
            return 1
        }
        ;;
    debian | ubuntu)
        apt-get update || {
            apt-get --fix-broken install -y && apt-get update
        }
        apt-get -y install --no-install-recommends wget curl make automake libtool pkg-config libaio-dev unzip || {
            apt-get --fix-broken install -y
            apt-get -y install --no-install-recommends wget curl make automake libtool pkg-config libaio-dev unzip
        }
        ;;
    fedora)
        dnf install -y wget curl gcc gcc-c++ make automake libtool pkgconfig libaio-devel || {
            _red "Failed to install build dependencies!"
            return 1
        }
        ;;
    arch)
        pacman -S --needed --noconfirm wget curl gcc gcc make automake libtool pkgconfig libaio lib32-libaio || {
            _red "Failed to install build dependencies!"
            return 1
        }
        ;;
    freebsd)
        pkg install -y wget curl gcc gmake autoconf automake libtool pkgconf || {
            _red "Failed to install build dependencies!"
            return 1
        }
        ;;
    openbsd)
        pkg_add -I wget curl gcc gmake autoconf automake libtool pkgconf || {
            _red "Failed to install build dependencies!"
            return 1
        }
        ;;
    *)
        _red "Unsupported operating system: ${system}"
        return 1
        ;;
    esac
}

# =============== CPU性能测试 部分 ===============
Run_SysBench_CPU() {
    # 调用方式: Run_SysBench_CPU "线程数" "测试时长(s)" "测试遍数" "说明"
    # 变量初始化
    maxtestcount="$3"
    local count="1"
    local TestScore="0"
    local TotalScore="0"
    # 运行测试
    while [ $count -le $maxtestcount ]; do
        echo -e "\r ${Font_Yellow}$4: ${Font_Suffix}\t\t$count/$maxtestcount \c"
        sysbench_version=$(sysbench --version 2>&1 | awk '{print $2}')
        local target_version="1.0.20"
        if [ "${Var_OSRelease}" == "freebsd" ]; then
            # freebsd系统下测不准待官方修复，故而设置为0
            local TestResult="events per second: 0"
        # elif [ "$sysbench_version" == "$target_version" ]; then
        elif [ "$(printf '%s\n' "$sysbench_version" "$target_version" | sort -V | head -n 1)" == "$target_version" ]; then
            # 版本号大于或等于1.0.20使用新命令检测否则使用旧命令检测
            local TestResult="$(sysbench cpu --threads=$1 --cpu-max-prime=10000 --events=1000000 --time=$2 run 2>&1)"
        else
            local TestResult="$(sysbench --test=cpu --num-threads=$1 --cpu-max-prime=10000 --max-requests=1000000 --max-time=$2 run 2>&1)"
        fi
        local TestScore="$(echo ${TestResult} | grep -oE "events per second: [0-9]+" | grep -oE "[0-9]+")"
        if [ -z "$TestScore" ]; then
            TestScore=$(echo "${TestResult}" | grep -oE "total number of events:\s+[0-9]+" | awk '{print $NF}' | awk -v time="$(echo "${TestResult}" | grep -oE "total time:\s+[0-9.]+[a-z]*" | awk '{print $NF}')" '{printf "%.2f\n", $0 / time}')
        fi
        local TotalScore="$(echo "${TotalScore} ${TestScore}" | awk '{printf "%d",$1+$2}')"
        let count=count+1
        local TestResult=""
        local TestScore="0"
    done
    local ResultScore="$(echo "${TotalScore} ${maxtestcount}" | awk '{printf "%d",$1/$2}')"
    if [ "$1" = "1" ]; then
        if [ "$ResultScore" -eq "0" ] || ([ "$1" -lt "2" ] && [ "$ResultScore" -gt "100000" ]); then
            if [ "$en_status" = true ]; then
                echo -e "\r ${Font_Yellow}$4: ${Font_Suffix}\t\t${Font_Red}sysbench test failed, please use this script option '-ctype gb5' to test${Font_Suffix}"
            else
                echo -e "\r ${Font_Yellow}$4: ${Font_Suffix}\t\t${Font_Red}sysbench测试失效，请使用本脚本选项 '-ctype gb5' 进行测试${Font_Suffix}"
            fi
        else
            echo -e "\r ${Font_Yellow}$4: ${Font_Suffix}\t\t${Font_SkyBlue}${ResultScore}${Font_Suffix} ${Font_Yellow}Scores${Font_Suffix}"
        fi
    elif [ "$1" -ge "2" ]; then
        if [ "$ResultScore" -eq "0" ] || ([ "$1" -lt "2" ] && [ "$ResultScore" -gt "100000" ]); then
            if [ "$en_status" = true ]; then
                echo -e "\r ${Font_Yellow}$4: ${Font_Suffix}\t\t${Font_Red}sysbench test failed, please use this script option '-ctype gb5' to test${Font_Suffix}"
            else
                echo -e "\r ${Font_Yellow}$4: ${Font_Suffix}\t\t${Font_Red}sysbench测试失效，请使用本脚本选项5中的gb4或gb5测试${Font_Suffix}"
            fi
        else
            echo -e "\r ${Font_Yellow}$4: ${Font_Suffix}\t\t${Font_SkyBlue}${ResultScore}${Font_Suffix} ${Font_Yellow}Scores${Font_Suffix}"
        fi
    fi
}

Function_SysBench_CPU_Fast() {
    cd $myvar >/dev/null 2>&1
    if [ "$en_status" = true ]; then
        echo -e " ${Font_Yellow}-> CPU test in progress (Fast Mode, 1-Pass @ 5sec)${Font_Suffix}"
        Run_SysBench_CPU "1" "5" "1" "1 Thread(s) Test"
        sleep 1
        if [ -n "${Result_Systeminfo_CPUThreads}" ] && [ "${Result_Systeminfo_CPUThreads}" -ge "2" ] >/dev/null 2>&1; then
            Run_SysBench_CPU "${Result_Systeminfo_CPUThreads}" "5" "1" "${Result_Systeminfo_CPUThreads} Thread(s) Test"
        elif [ -n "${Result_Systeminfo_CPUCores}" ] && [ "${Result_Systeminfo_CPUCores}" -ge "2" ] >/dev/null 2>&1; then
            Run_SysBench_CPU "${Result_Systeminfo_CPUCores}" "5" "1" "${Result_Systeminfo_CPUCores} Thread(s) Test"
        elif [ -n "${cores}" ] && [ "${cores}" -ge "2" ] >/dev/null 2>&1; then
            Run_SysBench_CPU "${cores}" "5" "1" "${cores} Thread(s) Test"
        fi
    else
        echo -e " ${Font_Yellow}-> CPU 测试中 (Fast Mode, 1-Pass @ 5sec)${Font_Suffix}"
        Run_SysBench_CPU "1" "5" "1" "1 线程测试(单核)得分"
        sleep 1
        if [ -n "${Result_Systeminfo_CPUThreads}" ] && [ "${Result_Systeminfo_CPUThreads}" -ge "2" ] >/dev/null 2>&1; then
            Run_SysBench_CPU "${Result_Systeminfo_CPUThreads}" "5" "1" "${Result_Systeminfo_CPUThreads} 线程测试(多核)得分"
        elif [ -n "${Result_Systeminfo_CPUCores}" ] && [ "${Result_Systeminfo_CPUCores}" -ge "2" ] >/dev/null 2>&1; then
            Run_SysBench_CPU "${Result_Systeminfo_CPUCores}" "5" "1" "${Result_Systeminfo_CPUCores} 线程测试(多核)得分"
        elif [ -n "${cores}" ] && [ "${cores}" -ge "2" ] >/dev/null 2>&1; then
            Run_SysBench_CPU "${cores}" "5" "1" "${cores} 线程测试(多核)得分"
        fi
    fi
}

# =============== 网速测试及延迟测试 部分 ===============
download_speedtest_file() {
    cd $myvar >/dev/null 2>&1
    file="./speedtest-cli/speedtest"
    if [[ -e "$file" ]]; then
        # _green "speedtest found"
        return
    fi
    file="./speedtest-cli/speedtest-go"
    if [[ -e "$file" ]]; then
        # _green "speedtest-go found"
        return
    fi
    local sys_bit="$1"
    # Create directory if it doesn't exist
    if [ ! -d "./speedtest-cli" ]; then
        mkdir -p "./speedtest-cli"
    fi
    # Modified to try speedtest-go first
    if [ "$sys_bit" = "aarch64" ]; then
        sys_bit_go="arm64"
    else
        sys_bit_go="$sys_bit"
    fi
    local url3="https://github.com/showwin/speedtest-go/releases/download/v${Speedtest_Go_version}/speedtest-go_${Speedtest_Go_version}_Linux_${sys_bit_go}.tar.gz"
    if [[ -z "${CN}" || "${CN}" != true ]]; then
        curl --fail -sL -m 10 -o speedtest.tar.gz "${url3}" || curl --fail -sL -m 15 -o speedtest.tar.gz "${url3}"
        if [[ $? -eq 0 ]]; then
            # _green "Successfully downloaded speedtest-go"
            tar -zxf speedtest.tar.gz -C ./speedtest-cli
            chmod 777 ./speedtest-cli/speedtest-go
            rm -rf speedtest.tar.gz*
            return
        else
            # _yellow "Failed to download speedtest-go, falling back to official speedtest-cli"
            rm -rf speedtest.tar.gz*
        fi
        if [ "$speedtest_ver" = "1.2.0" ]; then
            local url1="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${sys_bit}.tgz"
            local url2="https://dl.lamp.sh/files/ookla-speedtest-1.2.0-linux-${sys_bit}.tgz"
        else
            local url1="https://filedown.me/Linux/Tool/speedtest_cli/ookla-speedtest-1.0.0-${sys_bit}-linux.tgz"
            local url2="https://bintray.com/ookla/download/download_file?file_path=ookla-speedtest-1.0.0-${sys_bit}-linux.tgz"
        fi
        curl --fail -sL -m 10 -o speedtest.tgz "${url1}" || curl --fail -sL -m 10 -o speedtest.tgz "${url2}"
        if [[ $? -eq 0 ]]; then
            tar -zxf speedtest.tgz -C ./speedtest-cli
            chmod 777 ./speedtest-cli/speedtest
            rm -rf speedtest.tgz*
            return
        else
            rm -rf speedtest.tgz*
        fi
    else
        curl -o speedtest.tar.gz "${cdn_success_url}${url3}" || curl -o speedtest.tar.gz "${url3}"
        if [[ $? -eq 0 ]]; then
            # _green "Used unofficial speedtest-go"
            tar -zxf speedtest.tar.gz -C ./speedtest-cli
            chmod 777 ./speedtest-cli/speedtest-go
            rm -rf speedtest.tar.gz*
            return
        else
            rm -rf speedtest.tar.gz*
        fi
    fi
    _red "Error: Failed to download any speedtest tool."
    exit 1
}

install_speedtest() {
    sys_bit=""
    local sysarch="$(uname -m)"
    case "${sysarch}" in
    "x86_64" | "x86" | "amd64" | "x64") sys_bit="x86_64" ;;
    "i386" | "i686") sys_bit="i386" ;;
    "aarch64" | "armv7l" | "armv8" | "armv8l") sys_bit="aarch64" ;;
    "s390x") sys_bit="s390x" ;;
    "riscv64") sys_bit="riscv64" ;;
    "ppc64le") sys_bit="ppc64le" ;;
    "ppc64") sys_bit="ppc64" ;;
    *) sys_bit="x86_64" ;;
    esac
    download_speedtest_file "${sys_bit}"
}

get_string_length() {
    local nodeName="$1"
    local length
    local converted
    converted=$(echo -n "$nodeName" | iconv -f utf8 -t gb2312 2>/dev/null)
    if [[ $? -eq 0 && -n "$converted" ]]; then
        length=$(echo -n "$converted" | wc -c)
        echo $length
        return
    fi
    converted=$(echo -n "$nodeName" | iconv -f utf8 -t big5 2>/dev/null)
    if [[ $? -eq 0 && -n "$converted" ]]; then
        length=$(echo -n "$converted" | wc -c)
        echo $length
        return
    fi
    length=$(echo -n "$nodeName" | awk '{len=0; for(i=1;i<=length($0);i++){c=substr($0,i,1);if(c~/[^\x00-\x7F]/){len+=2}else{len++}}; print len}')
    echo $length
}

speed_test() {
    cd $myvar >/dev/null 2>&1
    local nodeName="$2"
    local cmd_status=0
    if [ -f "./speedtest-cli/speedtest-go" ]; then
        if [ -z "$1" ]; then
            if [ "$usage_timeout" = true ]; then
                timeout 70s ./speedtest-cli/speedtest-go --ua="${BrowserUA}" >./speedtest-cli/speedtest.log 2>&1
            else
                ./speedtest-cli/speedtest-go --ua="${BrowserUA}" >./speedtest-cli/speedtest.log 2>&1
            fi
        else
            if [ "$usage_timeout" = true ]; then
                timeout 70s ./speedtest-cli/speedtest-go --server=$1 --ua="${BrowserUA}" >./speedtest-cli/speedtest.log 2>&1
            else
                ./speedtest-cli/speedtest-go --server=$1 --ua="${BrowserUA}" >./speedtest-cli/speedtest.log 2>&1
            fi
        fi
        cmd_status=$?
        if [ $cmd_status -eq 0 ]; then
            local dl_speed=$(grep -oP 'Download: \K[\d\.]+' ./speedtest-cli/speedtest.log)
            local up_speed=$(grep -oP 'Upload: \K[\d\.]+' ./speedtest-cli/speedtest.log)
            local latency=$(grep -oP 'Latency: \K[\d\.]+' ./speedtest-cli/speedtest.log | head -1)
            if [[ -n "${latency}" && "${latency}" == *.* ]]; then
                latency=$(awk '{printf "%.2f", $1}' <<<"${latency}")
            fi
            if [[ -n "${dl_speed}" || -n "${up_speed}" || -n "${latency}" ]]; then
                if [[ $selection =~ ^[1-5]$ ]]; then
                    echo -e "${nodeName}\t ${up_speed}Mbps\t ${dl_speed}Mbps\t ${latency}ms\t"
                else
                    length=$(get_string_length "$nodeName")
                    if [ $length -ge 8 ]; then
                        echo -e "${nodeName}\t ${up_speed}Mbps\t ${dl_speed}Mbps\t ${latency}ms\t"
                    else
                        echo -e "${nodeName}\t\t ${up_speed}Mbps\t ${dl_speed}Mbps\t ${latency}ms\t"
                    fi
                fi
            fi
        fi
    else
        if [ -z "$1" ]; then
            ./speedtest-cli/speedtest --progress=no --accept-license --accept-gdpr >./speedtest-cli/speedtest.log 2>&1
        else
            ./speedtest-cli/speedtest --progress=no --server-id=$1 --accept-license --accept-gdpr >./speedtest-cli/speedtest.log 2>&1
        fi
        cmd_status=$?
        if grep -i "aborted" ./speedtest-cli/speedtest.log >/dev/null 2>&1 ||
            grep -i "core dumped" ./speedtest-cli/speedtest.log >/dev/null 2>&1 ||
            [ $cmd_status -ne 0 ]; then
            # 设置全局错误标记
            export SPEEDTEST_ERROR=true
            if [ "$en_status" = true ]; then
                echo "Error detected: Aborted or core dumped, terminate speed test"
            else
                echo "检测到错误：Aborted或core dumped，终止测速"
            fi
            return 1
        fi
        if [ $cmd_status -eq 0 ]; then
            local dl_speed=$(awk '/Download/{print $3" "$4}' ./speedtest-cli/speedtest.log)
            local up_speed=$(awk '/Upload/{print $3" "$4}' ./speedtest-cli/speedtest.log)
            if [ "$speedtest_ver" = "1.2.0" ]; then
                local latency=$(grep -oP 'Idle Latency:\s+\K[\d\.]+' ./speedtest-cli/speedtest.log | head -1)
            else
                local latency=$(grep -oP 'Latency:\s+\K[\d\.]+' ./speedtest-cli/speedtest.log | head -1)
            fi
            local packet_loss=$(awk -F': +' '/Packet Loss/{if($2=="Not available."){print "NULL"}else{print $2}}' ./speedtest-cli/speedtest.log)
            if [[ -n "${dl_speed}" || -n "${up_speed}" || -n "${latency}" ]]; then
                if [[ $selection =~ ^[1-5]$ ]]; then
                    echo -e "${nodeName}\t ${up_speed}\t ${dl_speed}\t ${latency}\t  $packet_loss"
                else
                    length=$(get_string_length "$nodeName")
                    if [ $length -ge 8 ]; then
                        echo -e "${nodeName}\t ${up_speed}\t ${dl_speed}\t ${latency}\t  $packet_loss"
                    else
                        echo -e "${nodeName}\t\t ${up_speed}\t ${dl_speed}\t ${latency}\t  $packet_loss"
                    fi
                fi
            fi
        fi
    fi
}

is_ipv4() {
    local ip=$1
    local regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    if [[ $ip =~ $regex ]]; then
        return 0 # 符合IPv4格式
    else
        return 1 # 不符合IPv4格式
    fi
}

test_list() {
    local list=("$@")
    if [ ${#list[@]} -eq 0 ]; then
        echo "列表为空，程序退出"
        return
    fi
    export SPEEDTEST_ERROR=false
    for ((i = 0; i < ${#list[@]}; i++)); do
        if [ "$SPEEDTEST_ERROR" = true ]; then
            if [ "$en_status" = true ]; then
                echo "Previous error detected, stopping further tests"
            else
                echo "检测到之前的错误，停止后续测试"
            fi
            error_exit
            break
        fi
        id=$(echo "${list[i]}" | cut -d',' -f1)
        name=$(echo "${list[i]}" | cut -d',' -f2)
        speed_test "$id" "$name" || {
            error_exit
            break
        }
    done
}

temp_head() {
    if [ "$en_status" = true ]; then
        echo "--------------------------------Speedtest--------------------------------"
        if [[ $selection =~ ^[1-5]$ ]]; then
            if [ -f "./speedtest-cli/speedtest" ]; then
                echo -e "Location\t     Upload\t\t  Download\t Delay\t  Loss"
            else
                echo -e "Location\t     Upload\t\t Download\t Delay"
            fi
        else
            if [ -f "./speedtest-cli/speedtest" ]; then
                echo -e "Location\t Upload\t\t Download\t Delay\t Loss"
            else
                echo -e "Location\t Upload\t\t  Download\t Delay"
            fi
        fi
        else
            echo "---------------------自动更新测速节点列表--本脚本原创----------------------"
        if [[ $selection =~ ^[1-5]$ ]]; then
            if [ -f "./speedtest-cli/speedtest" ]; then
                echo -e "位置\t         上传速度\t 下载速度\t 延迟\t  丢包率"
            else
                echo -e "位置\t         上传速度\t 下载速度\t 延迟"
            fi
        else
            if [ -f "./speedtest-cli/speedtest" ]; then
                echo -e "位置\t\t 上传速度\t 下载速度\t 延迟\t  丢包率"
            else
                echo -e "位置\t\t 上传速度\t 下载速度\t 延迟"
            fi
        fi
    fi
}

ping_test() {
    local ip="$1"
    local result="$(ping -c1 -w3 "$ip" 2>/dev/null | awk -F '/' 'END {print $5}')"
    echo "$ip,$result"
}

get_nearest_data() {
    local url="$1"
    local data=()
    local response
    if [[ -z "${CN}" || "${CN}" != true ]]; then
        local retries=0
        while [[ $retries -lt 2 ]]; do
            response=$(curl -sL -m 2 "$url")
            if [[ $? -eq 0 ]]; then
                break
            else
                retries=$((retries + 1))
                sleep 1
            fi
        done
        if [[ $retries -eq 2 ]]; then
            url="${cdn_success_url}${url}"
            response=$(curl -sL -m 6 "$url")
        fi
    else
        url="${cdn_success_url}${url}"
        response=$(curl -sL -m 8 "$url")
    fi
    while read line; do
        if [[ -n "$line" ]]; then
            local id=$(echo "$line" | awk -F ',' '{print $1}')
            local city=$(echo "$line" | sed 's/ //g' | awk -F ',' '{print $4}')
            local ip=$(echo "$line" | awk -F ',' '{print $5}')
            if [[ "$id,$city,$ip" == "id,city,ip" ]]; then
                continue
            fi
            if [[ $url == *"Mobile"* ]]; then
                city="移动${city}"
            elif [[ $url == *"Telecom"* ]]; then
                city="电信${city}"
            elif [[ $url == *"Unicom"* ]]; then
                city="联通${city}"
            fi
            if [ "$en_status" = true ]; then
                city=$(echo "$city" | sed 's/洛杉矶/US_LosAngeles/g')
                city=$(echo "$city" | sed 's/法兰克福/DE_Frankfurt/g')
                city=$(echo "$city" | sed 's/新加坡/SG_Singapore/g')
                city=$(echo "$city" | sed 's/中国香港/HK_HongKong/g')
                city=$(echo "$city" | sed 's/日本东京/JP_Tokyo/g')
            fi
            data+=("$id,$city,$ip")
        fi
    done <<<"$response"
    rm -f /tmp/pingtest
    # 并行ping测试所有IP
    for ((i = 0; i < ${#data[@]}; i++)); do
        {
            ip=$(echo "${data[$i]}" | awk -F ',' '{print $3}')
            ping_test "$ip" >>/tmp/pingtest
        } &
    done
    wait
    # 取IP顺序列表results
    output=$(cat /tmp/pingtest)
    rm -f /tmp/pingtest
    IFS=$'\n' read -rd '' -a lines <<<"$output"
    results=()
    for line in "${lines[@]}"; do
        field=$(echo "$line" | cut -d',' -f1)
        results+=("$field")
    done

    # 比对data取IP对应的数组
    sorted_data=()
    for result in "${results[@]}"; do
        for item in "${data[@]}"; do
            if [[ "$item" == *"$result"* ]]; then
                id=$(echo "$item" | cut -d',' -f1)
                name=$(echo "$item" | cut -d',' -f2)
                sorted_data+=("$id,$name")
            fi
        done
    done
    sorted_data=("${sorted_data[@]:0:2}")

    # 返回结果
    echo "${sorted_data[@]}"
}

checknslookup() {
    _yellow "checking nslookup"
    if ! command -v nslookup &>/dev/null; then
        _yellow "Installing dnsutils"
        ${PACKAGE_INSTALL[int]} dnsutils
    fi
}

get_ip_from_url() {
    nslookup -querytype=A $1 2>/dev/null | awk '/^Name:/ {next;} /^Address: / { print $2 }'
}

get_nearest_data2() {
    local url="$1"
    local data=()
    local response
    if [[ -z "${CN}" || "${CN}" != true ]]; then
        local retries=0
        while [[ $retries -lt 2 ]]; do
            response=$(curl -sL -m 2 "$url")
            if [[ $? -eq 0 ]]; then
                break
            else
                retries=$((retries + 1))
                sleep 1
            fi
        done
        if [[ $retries -eq 2 ]]; then
            url="${cdn_success_url}${url}"
            response=$(curl -sL -m 6 "$url")
        fi
    else
        url="${cdn_success_url}${url}"
        response=$(curl -sL -m 8 "$url")
    fi
    ip_list=()
    city_list=()
    while read line; do
        if [[ -n "$line" ]]; then
            # local id=$(echo "$line" | awk -F ',' '{print $1}')
            local city=$(echo "$line" | sed 's/ //g' | awk -F ',' '{print $9}')
            city=${city/市/}
            city=${city/中国/}
            local host=$(echo "$line" | awk -F ',' '{print $6}')
            local host_url=$(echo $host | sed 's/:.*//')
            if [[ "$host,$city" == "host,city" || "$city" == *"香港"* || "$city" == *"台湾"* ]]; then
                continue
            fi
            if is_ipv4 "$host_url"; then
                local ip="$host_url"
            else
                local ip=$(get_ip_from_url ${host_url})
            fi
            if [[ $url == *"mobile"* ]]; then
                city="移动${city}"
            elif [[ $url == *"telecom"* ]]; then
                city="电信${city}"
            elif [[ $url == *"unicom"* ]]; then
                city="联通${city}"
            fi
            if [ "$en_status" = true ]; then
                city=$(echo "$city" | sed 's/洛杉矶/US_LosAngeles/g')
                city=$(echo "$city" | sed 's/法兰克福/DE_Frankfurt/g')
                city=$(echo "$city" | sed 's/新加坡/SG_Singapore/g')
                city=$(echo "$city" | sed 's/中国香港/HK_HongKong/g')
                city=$(echo "$city" | sed 's/日本东京/JP_Tokyo/g')
            fi
            if [[ ! " ${ip_list[@]} " =~ " ${ip} " ]] && [[ ! " ${city_list[@]} " =~ " ${city} " ]]; then
                data+=("$host,$city,$ip")
                ip_list+=("$ip")
                city_list+=("$city")
            fi
        fi
    done <<<"$response"

    rm -f /tmp/pingtest
    for ((i = 0; i < ${#data[@]}; i++)); do
        {
            ip=$(echo "${ip_list[$i]}")
            ping_test "$ip" >>/tmp/pingtest
        } &
    done
    wait

    output=$(cat /tmp/pingtest)
    rm -f /tmp/pingtest
    IFS=$'\n' read -rd '' -a lines <<<"$output"
    results=()
    for line in "${lines[@]}"; do
        field=$(echo "$line" | cut -d',' -f1)
        results+=("$field")
    done

    sorted_data=()
    for result in "${results[@]}"; do
        for item in "${data[@]}"; do
            if [[ "$(echo "$item" | cut -d ',' -f 3)" == "$result" ]]; then
                # 	      if [[ "$item" == *"$result"* ]]; then
                host=$(echo "$item" | cut -d',' -f1)
                name=$(echo "$item" | cut -d',' -f2)
                sorted_data+=("$host,$name")
            fi
        done
    done
    sorted_data=("${sorted_data[@]:0:2}")

    echo "${sorted_data[@]}"
}

speed_test2() {
    local nodeName="$2"
    if [ ! -f "./speedtest-cli/speedtest" ]; then
        if [ -z "$1" ]; then
            if [ "$usage_timeout" = true ]; then
                timeout 70s ./speedtest-cli/speedtest-go >./speedtest-cli/speedtest.log 2>&1
            else
                ./speedtest-cli/speedtest-go >./speedtest-cli/speedtest.log 2>&1
            fi
        else
            if [ "$usage_timeout" = true ]; then
                timeout 70s ./speedtest-cli/speedtest-go --custom-url=http://"$1"/upload.php >./speedtest-cli/speedtest.log 2>&1
            else
                ./speedtest-cli/speedtest-go --custom-url=http://"$1"/upload.php >./speedtest-cli/speedtest.log 2>&1
            fi
        fi
        if [ $? -eq 0 ]; then
            local dl_speed=$(grep -oP 'Download: \K[\d\.]+' ./speedtest-cli/speedtest.log)
            local up_speed=$(grep -oP 'Upload: \K[\d\.]+' ./speedtest-cli/speedtest.log)
            local latency=$(grep -oP 'Latency: \K[\d\.]+' ./speedtest-cli/speedtest.log)
            if [[ -n "${latency}" && "${latency}" == *.* ]]; then
                latency=$(awk '{printf "%.2f", $1}' <<<"${latency}")
            fi
            if [[ -n "${dl_speed}" || -n "${up_speed}" || -n "${latency}" ]]; then
                if [[ $selection =~ ^[1-5]$ ]]; then
                    echo -e "\r${nodeName}\t ${up_speed} Mbps\t ${dl_speed} Mbps\t ${latency}\t"
                else
                    length=$(get_string_length "$nodeName")
                    if [ $length -ge 8 ]; then
                        echo -e "\r${nodeName}\t ${up_speed} Mbps\t ${dl_speed} Mbps\t ${latency}\t"
                    else
                        echo -e "\r${nodeName}\t\t ${up_speed} Mbps\t ${dl_speed} Mbps\t ${latency}\t"
                    fi
                fi
            fi
        fi
    fi
}

check_to_cn_test() {
    local provider_list="$1"
    local use_all="$2"
    shift 2
    local data_array=("$@")
    if [ "$test_network_type" == ".cn" ]; then
        data_array=($(get_nearest_data2 "${SERVER_BASE_URL2}/${provider_list}")) >/dev/null 2>&1
        wait
        if [ ${#data_array[@]} -eq 0 ]; then
            return
        else
            unset -f speed_test
            speed_test() { speed_test2 "$@"; }
            echo -en "\r测速中                                                        \r"
            if [ "$use_all" = "true" ]; then
                test_list "${data_array[@]}"
            else
                test_list "${data_array[0]}"
            fi
        fi
    elif [ ${#data_array[@]} -eq 0 ] && [ -z "$test_network_type" ]; then
        echo -n "该运营商.net的节点列表为空，正在替换为.cn的节点列表。。。"
        CN=true
        if [ -f "./speedtest-cli/speedtest" ]; then
            rm -rf ./speedtest-cli/speedtest
            (install_speedtest >/dev/null 2>&1)
        fi
        data_array=($(get_nearest_data2 "${SERVER_BASE_URL2}/${provider_list}")) >/dev/null 2>&1
        wait
        if [ ${#data_array[@]} -eq 0 ]; then
            return
        else
            unset -f speed_test
            speed_test() { speed_test2 "$@"; }
            echo -en "\r测速中                                                        \r"
            if [ "$use_all" = "true" ]; then
                test_list "${data_array[@]}"
            else
                test_list "${data_array[0]}"
            fi
        fi
    else
        if [ "$use_all" = "true" ]; then
            test_list "${data_array[@]}"
        else
            test_list "${data_array[0]}"
        fi
    fi
}

speed() {
    [ "${Var_OSRelease}" = "freebsd" ] && return
    local ip4=$(echo "$IPV4" | tr -d '\n' | tr -d '[:space:]')
    if [[ -z "${ip4}" ]]; then
        return
    fi
    temp_head
    if [ "$test_network_type" != ".cn" ]; then
        speed_test '' 'Speedtest.net'
    fi
    test_list "${ls_sg_hk_jp[@]}"
    if [ "$en_status" = false ]; then
        check_to_cn_test "unicom.csv" "true" "${CN_Unicom[@]}"
        check_to_cn_test "telecom.csv" "true" "${CN_Telecom[@]}"
        check_to_cn_test "mobile.csv" "true