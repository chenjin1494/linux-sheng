#!/bin/bash
set -euo pipefail

# ============================================================
# 配置变量
# ============================================================
IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

UBUNTU_SUITE="noble"
UBUNTU_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"

# 需要 trap 清理的挂载/目录列表
_TEMP_DIRS=()

# ============================================================
# 工具函数
# ============================================================
info()  { echo "[$(date '+%H:%M:%S')] [INFO]  $*"; }
warn()  { echo "[$(date '+%H:%M:%S')] [WARN]  $*" >&2; }
error() { echo "[$(date '+%H:%M:%S')] [ERROR] $*" >&2; exit 1; }

# trap 退出时卸载并清理所有临时路径
cleanup() {
    # 按挂载顺序反向卸载
    umount -q rootdir/dev/pts 2>/dev/null || true
    umount -q rootdir/dev     2>/dev/null || true
    umount -q rootdir/proc    2>/dev/null || true
    umount -q rootdir/sys     2>/dev/null || true
    umount -q rootdir         2>/dev/null || true

    for dir in "${_TEMP_DIRS[@]}"; do
        [[ -d "$dir" ]] && rm -rf "$dir"
    done
}
trap cleanup EXIT

_mktemp() {
    local d
    d="$(mktemp -d)"
    _TEMP_DIRS+=("$d")
    echo "$d"
}

# ============================================================
# 阶段函数
# ============================================================

usage() {
    echo "用法: $0 <kernel_version> <desktop_environment> <root_passwd> <user_name> <user_passwd> <hostname>"
    echo "desktop_environment: tty, gnome 或 kde"
    exit 1
}

setup_env() {
    info "检查参数..."
    if [[ $# -ne 6 ]]; then
        usage
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        error "请使用 root 权限运行"
    fi

    if [[ ! "$2" =~ ^(tty|gnome|kde)$ ]]; then
        error "desktop_environment 必须是 tty, gnome 或 kde"
    fi
}

build_rootfs() {
    local kernel_ver="$1"
    local desktop_env="$2"
    local root_passwd="$3"
    local user_name="$4"
    local user_passwd="$5"
    local hostname="$6"
    local timestamp dm

    timestamp="$(date +"%Y%m%d_%H%M%S")"
    local rootfs_img="ubuntu24_${desktop_env}_${timestamp}.img"

    info "=========================================="
    info "开始构建 Ubuntu 24.04 LTS (Noble) RootFS"
    info "桌面环境: ${desktop_env}"
    info "内核版本: ${kernel_ver}"
    info "ROOT 密码: ${root_passwd}"
    info "用户名:   ${user_name}"
    info "用户密码: ${user_passwd}"
    info "主机名:   ${hostname}"
    info "=========================================="

    # --------------------------------------------------
    # 创建空白根文件系统镜像
    # --------------------------------------------------
    info "创建 ${IMAGE_SIZE} 空白镜像..."
    rm -rf rootdir
    truncate -s "$IMAGE_SIZE" "$rootfs_img"
    mkfs.ext4 "$rootfs_img"
    mkdir rootdir
    _TEMP_DIRS+=("$PWD/rootdir")

    info "挂载镜像并执行 debootstrap..."
    mount -o loop "$rootfs_img" rootdir
    debootstrap --arch=arm64 "$UBUNTU_SUITE" rootdir "$UBUNTU_MIRROR"

    # --------------------------------------------------
    # 挂载虚拟文件系统
    # --------------------------------------------------
    mount --bind /dev     rootdir/dev
    mount --bind /dev/pts rootdir/dev/pts
    mount -t proc proc    rootdir/proc
    mount -t sysfs sys    rootdir/sys

    # --------------------------------------------------
    # 配置 apt 源
    # --------------------------------------------------
    {
        printf "deb %s %s main restricted universe multiverse\n" \
            "$UBUNTU_MIRROR" "$UBUNTU_SUITE"
        printf "deb %s %s-updates main restricted universe multiverse\n" \
            "$UBUNTU_MIRROR" "$UBUNTU_SUITE"
        printf "deb %s %s-backports main restricted universe multiverse\n" \
            "$UBUNTU_MIRROR" "$UBUNTU_SUITE"
        printf "deb %s %s-security main restricted universe multiverse\n" \
            "$UBUNTU_MIRROR" "$UBUNTU_SUITE"
    } > rootdir/etc/apt/sources.list

    # --------------------------------------------------
    # 安装系统核心依赖
    # --------------------------------------------------
    info "安装系统核心依赖..."
    chroot rootdir apt update
    chroot rootdir apt install -y --no-install-recommends \
        systemd sudo vim-tiny wget curl \
        network-manager openssh-server \
        wpasupplicant dbus kmod initramfs-tools

    # --------------------------------------------------
    # 安装内核 .deb 包
    # --------------------------------------------------
    info "安装内核包..."
    if ls *.deb 1> /dev/null 2>&1; then
        cp *.deb rootdir/tmp/
        chroot rootdir bash -c "apt install -y /tmp/*.deb || true"
        info "正在强制更新内核模块依赖..."
        local kernel_module_dir
        kernel_module_dir="$(ls rootdir/lib/modules/ | head -n 1)"
        if [[ -n "$kernel_module_dir" ]]; then
            info "动态识别到真实内核版本目录: ${kernel_module_dir}"
            chroot rootdir /sbin/depmod -a "$kernel_module_dir" || true
        fi
    fi

    # --------------------------------------------------
    # 设置英文语言环境
    # --------------------------------------------------
    info "设置语言环境..."
    chroot rootdir bash -c "echo 'LANG=en_US.UTF-8' > /etc/default/locale"
    chroot rootdir locale-gen en_US.UTF-8

    # --------------------------------------------------
    # root 用户初始化
    # --------------------------------------------------
    info "初始化 root 用户..."
    chroot rootdir bash -c "echo -e '${root_passwd}\n${root_passwd}' | passwd root"
    echo "$hostname" > rootdir/etc/hostname

    # --------------------------------------------------
    # 桌面环境分支流转
    # --------------------------------------------------
    info "安装桌面环境: ${desktop_env}..."
    case "$desktop_env" in
        gnome)
            chroot rootdir apt install -y --no-install-recommends \
                ubuntu-desktop-minimal gnome-terminal firefox gdm3
            dm="gdm3"
            ;;
        kde)
            chroot rootdir apt install -y --no-install-recommends \
                plasma-desktop sddm konsole firefox \
                plasma-workspace systemsettings discover packagekit
            dm="sddm"
            ;;
        tty)
            dm=""  # 无桌面环境
            ;;
    esac

    # --------------------------------------------------
    # 创建普通用户
    # --------------------------------------------------
    info "创建普通用户 ${user_name}..."
    chroot rootdir useradd -m -s /bin/bash "$user_name"
    echo "${user_name}:${user_passwd}" | chroot rootdir chpasswd
    chroot rootdir usermod -aG sudo,audio,video,render,input,plugdev "$user_name"

    # --------------------------------------------------
    # 系统配置
    # --------------------------------------------------
    info "配置系统服务..."
    chroot rootdir bash -c "echo 'ttyMSM0' >> /etc/securetty"
    ln -sf /lib/systemd/system/getty@.service \
        rootdir/etc/systemd/system/getty.target.wants/getty@ttyMSM0.service
    chroot rootdir systemctl enable systemd-resolved
    ln -sf /run/systemd/resolve/stub-resolv.conf rootdir/etc/resolv.conf

    mkdir -p rootdir/etc/udev/rules.d/
    printf 'ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0 0 0 1"\n' \
        > rootdir/etc/udev/rules.d/99-touchscreen-sheng.rules

    # --------------------------------------------------
    # 高通 WiFi 固件修复与驱动适配
    # --------------------------------------------------
    info "正在预配置高通 WiFi 固件修复与驱动适配..."
    local fw_dir="rootdir/lib/firmware/ath12k/WCN7850/hw2.0"
    if [[ -f "$fw_dir/board-2.bin" ]]; then
        cp "$fw_dir/board-2.bin" "$fw_dir/board.bin"
        info "board.bin 伪装成功！"
    fi
    chroot rootdir apt install -y qrtr-tools || true
    chroot rootdir systemctl enable qrtr-ns || true

    # --------------------------------------------------
    # 自动登录与桌面加固配置
    # --------------------------------------------------
    case "$dm" in
        gdm3)
            mkdir -p rootdir/etc/gdm3
            printf "[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=luser\n" \
                > rootdir/etc/gdm3/daemon.conf
            chroot rootdir systemctl enable gdm3
            ;;
        sddm)
            mkdir -p rootdir/etc/sddm.conf.d
            printf "[General]\nDisplayServer=x11\nInputMethod=\n" \
                > rootdir/etc/sddm.conf.d/ubuntu-defaults.conf
            printf "[Autologin]\nUser=luser\nSession=plasma\n" \
                > rootdir/etc/sddm.conf.d/autologin.conf

            if chroot rootdir id -u sddm >/dev/null 2>&1; then
                chroot rootdir usermod -aG video,render,input sddm || true
            fi

            mkdir -p rootdir/etc/xdg
            printf "[PowerManagement]\nScreenBlanking=false\nDisplaySleep=0\n" \
                > rootdir/etc/xdg/plasmarc
            chroot rootdir systemctl enable sddm
            ;;
    esac

    # 统一进入图形层级（无桌面环境也保持 multi-user.target）
    if [[ -n "$dm" ]]; then
        chroot rootdir systemctl set-default graphical.target
    fi

    # --------------------------------------------------
    # 文件系统挂载对齐
    # --------------------------------------------------
    printf "PARTLABEL=linux / ext4 defaults,noatime,errors=remount-ro 0 1\n" \
        > rootdir/etc/fstab

    # --------------------------------------------------
    # 清理缓存
    # --------------------------------------------------
    info "清理缓存..."
    chroot rootdir apt clean
    chroot rootdir rm -rf /tmp/*.deb

    # --------------------------------------------------
    # 卸载并收尾
    # --------------------------------------------------
    info "卸载文件系统..."
    umount rootdir/dev/pts
    umount rootdir/dev
    umount rootdir/proc
    umount rootdir/sys
    umount rootdir
    rm -rf rootdir

    tune2fs -U "$FILESYSTEM_UUID" "$rootfs_img"
    info "原始镜像生成完成: ${rootfs_img}"

    # --------------------------------------------------
    # 转换为稀疏镜像并压缩
    # --------------------------------------------------
    info "正在转换为 Fastboot 专用的稀疏镜像 (Sparse Image)..."
    local sparse_img="sparse_${rootfs_img}"
    img2simg "$rootfs_img" "$sparse_img"

    info "正在生成最终 7z 压缩包..."
    7z a "ubuntu24_${desktop_env}_${timestamp}.7z" "$sparse_img"

    rm -f "$rootfs_img" "$sparse_img"
    info "Ubuntu Rootfs 构建成功！"
}

# ============================================================
# 主流程
# ============================================================
main() {
    setup_env "$@"
    build_rootfs "$@"
}

main "$@"
