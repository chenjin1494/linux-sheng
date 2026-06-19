#!/bin/bash
set -euo pipefail

# ============================================================
# 配置变量
# ============================================================
: <<'KERNEL_COMMENT'
KERNEL_SOURCE_REPO="map220v/sm8550-mainline"
KERNEL_BRANCH="sheng-${1:-7.1}"

CCACHE_DIR="${CCACHE_DIR:-/home/runner/.ccache}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-10G}"

# 打包目录名（相对于仓库根目录）
PKG_DIR="linux-xiaomi-sheng"
KERNEL_COMMENT

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

: <<'KERNEL_COMMENT'
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
KERNEL_COMMENT

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

build_mipps_auth_package() {
    local repo_dir src_dir pkg_src work pkg out
    repo_dir="$(_mktemp)"

    info "正在拉取 xiaomi-mipps-auth 源码..."
    git clone https://github.com/ianchb/xiaomi-mipps-auth.git \
        --depth 1 "$repo_dir"

    info "正在构建 xiaomi-mipps-auth.deb..."
    src_dir="$repo_dir"
    pkg_src="$src_dir"
    work="$repo_dir/deb-work"
    pkg="$work/pkg"
    out="./xiaomi-mipps-auth_0.13_arm64.deb"

    rm -rf "$work"
    mkdir -p "$pkg/DEBIAN"
    mkdir -p "$pkg/usr/libexec"
    mkdir -p "$pkg/usr/lib/systemd/system"
    mkdir -p "$pkg/usr/lib/udev/rules.d"

    cp -a "$pkg_src/DEBIAN/." "$pkg/DEBIAN/"
    install -m 0755 "$src_dir/xiaomi-mipps-auth" "$pkg/usr/libexec/xiaomi-mipps-auth"
    install -m 0644 "$pkg_src/xiaomi-mipps-auth.service" \
        "$pkg/usr/lib/systemd/system/xiaomi-mipps-auth.service"
    install -m 0644 "$pkg_src/90-xiaomi-mipps-auth.rules" \
        "$pkg/usr/lib/udev/rules.d/90-xiaomi-mipps-auth.rules"
    chmod 0755 "$pkg/DEBIAN/postinst" "$pkg/DEBIAN/postrm"

    mkdir -p "$(dirname -- "$out")"
    dpkg-deb --build --root-owner-group "$pkg" "$out"
    info "xiaomi-mipps-auth.deb 打包完成：${out}"
}

build_sensors_package() {
    local repo_dir pkg out
    repo_dir="$(_mktemp)"

    info "正在拉取 sheng-sensors-file..."
    git clone https://github.com/alghiffaryfa19/sheng-sensors-file.git \
        --depth 1 "$repo_dir"

    info "正在构建 sheng-sensors.deb..."
    pkg="$repo_dir/pkg"
    out="./sheng-sensors_1.0_all.deb"

    # 复制整个 usr/ 文件树
    cp -a "$repo_dir/usr" "$pkg/"

    # 生成 DEBIAN/control
    mkdir -p "$pkg/DEBIAN"
    cat > "$pkg/DEBIAN/control" << 'EOF'
Package: sheng-sensors
Version: 1.0
Architecture: all
Maintainer: sheng-builder
Description: Sensor configuration files for Xiaomi Pad 6S Pro (sheng)
EOF

    dpkg-deb --build --root-owner-group "$pkg" "$out"
    info "sheng-sensors.deb 打包完成：${out}"
}

build_libssc_package() {
    local repo_dir
    repo_dir="$(_mktemp)"

    info "正在安装 libssc 构建依赖..."
    sudo apt install -y ninja-build pkg-config python3-pip \
        libglib2.0-dev libprotobuf-c-dev libqmi-glib-dev \
        libmbim-glib-dev protobuf-compiler protobuf-c-compiler
    pip3 install --upgrade meson

    info "正在拉取 libssc 源码..."
    git clone https://codeberg.org/alghiffaryfa19/libssc.git \
        --depth 1 "$repo_dir/source"

    info "正在构建 libssc..."
    cd "$repo_dir/source"
    meson setup build --prefix=/usr
    meson compile -C build
    DESTDIR="$repo_dir/source/stage" meson install -C build
    cd - >/dev/null

    info "正在打包 libssc.deb..."
    local pkg="$repo_dir/deb"
    mkdir -p "$pkg/DEBIAN" "$pkg/usr"
    cp -r "$repo_dir/source/stage/usr/"* "$pkg/usr/"

    PKGNAME=libssc PKGVERSION=0.4.2 PKGREL=1 \
    cat > "$pkg/DEBIAN/control" << CONTROL
Package: libssc
Version: 0.4.2-1
Section: libs
Priority: optional
Architecture: arm64
Maintainer: Fauzan Amir Al Ghiffary <alghiffaryfa19@gmail.com>
Depends: libglib2.0-0, libprotobuf-c1, libqmi-glib5
Description: Library to expose Qualcomm Sensor Core sensors
 libssc userspace library for Qualcomm SSC.
CONTROL

    dpkg-deb --build "$pkg" "./libssc_0.4.2-1_arm64.deb"
    info "libssc.deb 打包完成：libssc_0.4.2-1_arm64.deb"
}

build_iio_sensor_proxy_package() {
    local repo_dir pkgver
    repo_dir="$(_mktemp)"
    pkgver="3.9"

    info "正在安装 iio-sensor-proxy 构建依赖..."
    sudo apt install -y ninja-build pkg-config wget \
        libglib2.0-dev libgudev-1.0-dev libpolkit-gobject-1-dev \
        libsystemd-dev libdbus-1-dev systemd \
        libqmi-glib-dev libmbim-glib-dev \
        protobuf-compiler protobuf-c-compiler
    pip3 install --upgrade meson 2>/dev/null || true

    info "正在下载 iio-sensor-proxy 源码..."
    wget -q "https://gitlab.freedesktop.org/hadess/iio-sensor-proxy/-/archive/${pkgver}/iio-sensor-proxy-${pkgver}.tar.gz"
    tar -xf "iio-sensor-proxy-${pkgver}.tar.gz" -C "$repo_dir"
    rm -f "iio-sensor-proxy-${pkgver}.tar.gz"

    info "正在安装 libssc（供 iio-sensor-proxy 链接）..."
    if [[ -f "./libssc_0.4.2-1_arm64.deb" ]]; then
        sudo dpkg -i "./libssc_0.4.2-1_arm64.deb"
        sudo ldconfig
    else
        warn "libssc.deb 未找到，跳过安装（iio-sensor-proxy 构建可能失败）"
    fi

    info "正在构建 iio-sensor-proxy（SSC patched）..."
    cd "$repo_dir/iio-sensor-proxy-${pkgver}"
    meson setup output \
        --prefix=/usr \
        -Db_lto=true \
        -Dssc-support=enabled \
        -Dsystemdsystemunitdir=/usr/lib/systemd/system
    meson compile -C output

    local stage="$repo_dir/iio-sensor-proxy-${pkgver}/stage"
    DESTDIR="$stage" meson install --no-rebuild -C output
    cd - >/dev/null

    info "正在打包 iio-sensor-proxy.deb..."
    local pkg="$repo_dir/deb"
    mkdir -p "$pkg/DEBIAN"
    cp -r "$stage/usr" "$pkg/"

    cat > "$pkg/DEBIAN/control" << CONTROL
Package: iio-sensor-proxy
Version: 9999${pkgver}-6
Section: misc
Priority: optional
Architecture: arm64
Maintainer: Dylan Van Assche <me@dylanvanassche.be>
Depends: dbus, libglib2.0-0, libgudev-1.0-0, libpolkit-gobject-1-0
Description: IIO sensors to D-Bus proxy (SSC patched)
 iio-sensor-proxy with Qualcomm SSC support patches.
CONTROL

    dpkg-deb --build "$pkg" "./iio-sensor-proxy_9999${pkgver}-6_arm64.deb"
    info "iio-sensor-proxy.deb 打包完成：iio-sensor-proxy_9999${pkgver}-6_arm64.deb"
}

build_fastrpc_package() {
    local repo_dir
    repo_dir="$(_mktemp)"

    info "正在安装 fastrpc 构建依赖..."
    sudo apt install -y automake autoconf libtool pkg-config libyaml-dev libbsd-dev

    info "正在拉取 fastrpc 源码..."
    git clone https://github.com/qualcomm/fastrpc.git \
        --depth 1 "$repo_dir"

    info "正在构建 fastrpc..."
    cd "$repo_dir"
    ./gitcompile
    cd - >/dev/null

    info "正在打包 fastrpc.deb..."
    local pkg="$repo_dir/deb"
    mkdir -p "$pkg/DEBIAN" "$pkg/usr/lib" "$pkg/usr/bin"

    # 安装库文件（6 个 .so）
    install -m 0644 "$repo_dir/src/.libs/libadsprpc.so"            "$pkg/usr/lib/libadsprpc.so"
    install -m 0644 "$repo_dir/src/.libs/libadsp_default_listener.so" "$pkg/usr/lib/libadsp_default_listener.so"
    install -m 0644 "$repo_dir/src/.libs/libcdsprpc.so"            "$pkg/usr/lib/libcdsprpc.so"
    install -m 0644 "$repo_dir/src/.libs/libcdsp_default_listener.so" "$pkg/usr/lib/libcdsp_default_listener.so"
    install -m 0644 "$repo_dir/src/.libs/libsdsprpc.so"            "$pkg/usr/lib/libsdsprpc.so"
    install -m 0644 "$repo_dir/src/.libs/libsdsp_default_listener.so" "$pkg/usr/lib/libsdsp_default_listener.so"

    # 安装守护进程（3 个 rpcd）
    install -m 0755 "$repo_dir/src/adsprpcd" "$pkg/usr/bin/adsprpcd"
    install -m 0755 "$repo_dir/src/cdsprpcd" "$pkg/usr/bin/cdsprpcd"
    install -m 0755 "$repo_dir/src/sdsprpcd" "$pkg/usr/bin/sdsprpcd"

    cat > "$pkg/DEBIAN/control" << CONTROL
Package: qualcomm-fastrpc
Version: 1.0-1
Section: libs
Priority: optional
Architecture: arm64
Maintainer: sheng-builder
Depends: libyaml-0-2
Description: Qualcomm FastRPC userspace libraries and daemons
 FastRPC user-space libraries and daemons for ADSP, CDSP, and SDSP
 communication on Qualcomm SoCs.
CONTROL

    dpkg-deb --build --root-owner-group "$pkg" "./qualcomm-fastrpc_1.0-1_arm64.deb"
    info "qualcomm-fastrpc.deb 打包完成：qualcomm-fastrpc_1.0-1_arm64.deb"
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
    # setup_env
    # fetch_kernel_source
    # build_kernel
    # package_modules_and_boot

    build_firmware_package
    build_alsa_package
    build_devauth_package
    build_mipps_auth_package
    build_sensors_package
    build_libssc_package
    build_iio_sensor_proxy_package
    build_fastrpc_package

    usr_merge_and_package

    info "全线通关！所有编译产物已就绪。"
}

main
