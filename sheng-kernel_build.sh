#!/bin/bash
set -euo pipefail

# ============================================================
# 配置变量
# ============================================================
KERNEL_SOURCE_REPO="map220v/sm8550-mainline"
KERNEL_BRANCH="sheng-${1:-7.1}"

CCACHE_DIR="${CCACHE_DIR:-/home/runner/.ccache}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-10G}"

# 打包目录名（相对于仓库根目录）
PKG_DIR="linux-xiaomi-sheng"

# 需要 trap 清理的临时目录列表
_TEMP_DIRS=()

# ============================================================
# 工具函数
# ============================================================
info()  { echo "[$(date '+%H:%M:%S')] [INFO]  $*"; }
warn()  { echo "[$(date '+%H:%M:%S')] [WARN]  $*" >&2; }
error() { echo "[$(date '+%H:%M:%S')] [ERROR] $*" >&2; exit 1; }

# trap 退出时清理所有临时目录
cleanup() {
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

setup_env() {
    info "初始化编译环境..."
    mkdir -p "$CCACHE_DIR"
    export CCACHE_DIR CCACHE_MAXSIZE
    export CC="ccache clang"
    export CXX="ccache clang++"
    export LLVM=1 ARCH=arm64
    export PATH="/usr/lib/ccache:$PATH"
}

fetch_kernel_source() {
    info "正在拉取内核源码（${KERNEL_SOURCE_REPO}#${KERNEL_BRANCH}）..."
    git clone "https://github.com/${KERNEL_SOURCE_REPO}.git" \
        -b "$KERNEL_BRANCH" --depth 1 linux
    cd linux
    cp ../sm8550.config .config
    info "内核源码就绪"
}

build_kernel() {
    info "开始编译内核..."
    make -j"$(nproc)" ARCH=arm64 LLVM=1 Image

    info "正在压缩内核镜像..."
    gzip -c arch/arm64/boot/Image > arch/arm64/boot/Image.gz

    make -j"$(nproc)" ARCH=arm64 LLVM=1 DTC_FLAGS="-f" qcom/sm8550-xiaomi-sheng.dtb
    make -j"$(nproc)" ARCH=arm64 LLVM=1 modules

    info "产物体检："
    ls -lh arch/arm64/boot/Image arch/arm64/boot/Image.gz \
          arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb

    [[ -f "arch/arm64/boot/Image.gz" ]] || error "Image.gz 不存在，编译失败！"
}

package_modules_and_boot() {
    local kernel_version
    kernel_version="$(make kernelrelease -s)"
    local pkgdir="../${PKG_DIR}"

    info "内核版本：${kernel_version}"
    info "正在导出内核模块..."
    mkdir -p "${pkgdir}/boot"
    make ARCH=arm64 INSTALL_MOD_PATH="${pkgdir}" modules_install

    info "正在安装内核与设备树..."
    install -Dm644 arch/arm64/boot/Image.gz   "${pkgdir}/boot/Image.gz"
    install -Dm644 arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb \
                                              "${pkgdir}/boot/sm8550-xiaomi-sheng.dtb"
    install -Dm644 .config                     "${pkgdir}/boot/config-${kernel_version}"

    info "正在生成 boot.img（单/双系统）..."
    cat arch/arm64/boot/Image.gz \
        arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb > Image.gz-dtb_sheng
    mv Image.gz-dtb_sheng zImage_sheng

    "../mkbootimg" --kernel zImage_sheng \
        --cmdline "root=PARTLABEL=linux rootwait rw" \
        --base 0x00000000 --kernel_offset 0x00008000 \
        --tags_offset 0x01e00000 --pagesize 4096 --id \
        -o ../boot_sheng_dualboot.img

    "../mkbootimg" --kernel zImage_sheng \
        --cmdline "root=PARTLABEL=userdata rootwait rw" \
        --base 0x00000000 --kernel_offset 0x00008000 \
        --tags_offset 0x01e00000 --pagesize 4096 --id \
        -o ../boot_sheng_singleboot.img

    cd ..
    info "boot.img 生成完毕"
}

build_firmware_package() {
    local fw_dir
    fw_dir="$(_mktemp)"

    info "正在拉取固件..."
    git clone https://github.com/lzxcr/linux-firmware-sheng.git \
        --depth 1 "$fw_dir"

    mkdir -p firmware-xiaomi-sheng/usr/lib
    if [[ -d "$fw_dir/lib" ]]; then
        cp -r "$fw_dir/lib/"* firmware-xiaomi-sheng/usr/lib/
    else
        cp -r "$fw_dir/"* firmware-xiaomi-sheng/usr/lib/ 2>/dev/null || true
    fi
    info "固件打包就绪"
}

build_alsa_package() {
    local alsa_dir
    alsa_dir="$(_mktemp)"

    info "正在拉取音频 UCM2 配置..."
    git clone https://github.com/map220v/alsa-ucm-conf.git \
        --depth 1 "$alsa_dir"

    mkdir -p alsa-xiaomi-sheng/usr/share/alsa/ucm2
    if [[ -d "$alsa_dir/ucm2" ]]; then
        cp -r "$alsa_dir/ucm2/"* alsa-xiaomi-sheng/usr/share/alsa/ucm2/
    else
        cp -r "$alsa_dir/"* alsa-xiaomi-sheng/usr/share/alsa/ucm2/ 2>/dev/null || true
    fi
    info "音频配置就绪"
}

build_devauth_package() {
    local sd_dir service_file
    sd_dir="$(_mktemp)"

    info "正在拉取 sheng-devauth 源码..."
    git clone https://github.com/map220v/sheng_devauth.git \
        --depth 1 "$sd_dir"

    info "正在编译 sheng-devauth..."
    make -C "$sd_dir"
    info "sheng-devauth 编译完成"

    mkdir -p sheng-devauth/usr/bin
    chmod 0755 "$sd_dir/xiaomi_devauth"
    cp "$sd_dir/xiaomi_devauth" sheng-devauth/usr/bin/

    # 生成 DEBIAN 维护脚本
    mkdir -p sheng-devauth/DEBIAN

    cat > sheng-devauth/DEBIAN/postinst << 'SCRIPT'
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
  systemctl enable sheng-devauth.service || true
  systemctl start sheng-devauth.service || true
fi
exit 0
SCRIPT
    chmod 0755 sheng-devauth/DEBIAN/postinst

    cat > sheng-devauth/DEBIAN/prerm << 'SCRIPT'
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop sheng-devauth.service || true
  systemctl disable sheng-devauth.service || true
fi
exit 0
SCRIPT
    chmod 0755 sheng-devauth/DEBIAN/prerm

    dpkg-deb --build --root-owner-group sheng-devauth
    info "sheng-devauth.deb 打包完成"
}

usr_merge_and_package() {
    info "正在进行 UsrMerge 路径融合..."
    for pkg in linux-xiaomi-sheng alsa-xiaomi-sheng; do
        if [[ -d "$pkg/lib" ]]; then
            mkdir -p "$pkg/usr/lib"
            cp -r "$pkg/lib/"* "$pkg/usr/lib/" 2>/dev/null || true
            rm -rf "$pkg/lib"
        fi
    done

    info "正在打包 .deb 文件..."
    for pkg in linux-xiaomi-sheng firmware-xiaomi-sheng alsa-xiaomi-sheng; do
        dpkg-deb --build --root-owner-group "$pkg"
    done
}

# ============================================================
# 主流程
# ============================================================
main() {
    setup_env
    fetch_kernel_source
    build_kernel
    package_modules_and_boot

    build_firmware_package
    build_alsa_package
    build_devauth_package

    usr_merge_and_package

    info "全线通关！所有编译产物已就绪。"
}

main
