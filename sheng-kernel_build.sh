#!/bin/bash
set -e

# === 编译环境 ===
export CCACHE_DIR="/home/runner/.ccache"
export CCACHE_MAXSIZE="10G"
mkdir -p "$CCACHE_DIR"
export CC="ccache clang"
export CXX="ccache clang++"
export LLVM=1
export ARCH=arm64

# === 拉取源码 ===
echo "正在拉取内核源码..."
git clone https://github.com/map220v/sm8550-mainline.git -b sheng-7.1 --depth 1 linux
cd linux

# === 应用配置 ===
echo "正在应用配置..."
cp ../sm8550.config .config

# === 编译内核 ===
echo "开始编译..."
make -j$(nproc) ARCH=arm64 LLVM=1 Image

echo "正在压缩内核镜像..."
gzip -c arch/arm64/boot/Image > arch/arm64/boot/Image.gz

make -j$(nproc) ARCH=arm64 LLVM=1 DTC_FLAGS="-f" qcom/sm8550-xiaomi-sheng.dtb

make -j$(nproc) ARCH=arm64 LLVM=1 modules

# === 产物体检 ===
echo "核心产物大小检查："
ls -lh arch/arm64/boot/Image arch/arm64/boot/Image.gz arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb

if [ ! -f "arch/arm64/boot/Image.gz" ]; then
    echo "严重错误：Image.gz 依然不存在！"
    exit 1
fi

# === 打包镜像与模块 ===
echo "正在导出内核模块并生成 boot.img..."
_kernel_version="$(make kernelrelease -s)"
PKGDIR=../linux-xiaomi-sheng
mkdir -p $PKGDIR/boot

make ARCH=arm64 INSTALL_MOD_PATH=$PKGDIR modules_install

install -Dm644 arch/arm64/boot/Image.gz $PKGDIR/boot/Image.gz
install -Dm644 arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb $PKGDIR/boot/sm8550-xiaomi-sheng.dtb
install -Dm644 .config $PKGDIR/boot/config-${_kernel_version}

# mkbootimg：单双系统适配
chmod +x ../mkbootimg
cat arch/arm64/boot/Image.gz arch/arm64/boot/dts/qcom/sm8550-xiaomi-sheng.dtb > Image.gz-dtb_sheng
mv Image.gz-dtb_sheng zImage_sheng

../mkbootimg --kernel zImage_sheng --cmdline "root=PARTLABEL=linux rootwait rw" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096 --id -o ../boot_sheng_dualboot.img
../mkbootimg --kernel zImage_sheng --cmdline "root=PARTLABEL=userdata rootwait rw" --base 0x00000000 --kernel_offset 0x00008000 --tags_offset 0x01e00000 --pagesize 4096 --id -o ../boot_sheng_singleboot.img

# === 构建 DEB 包 ===
cd ..

# 固件
echo "正在从上游拉取最新的固件文件..."
git clone https://github.com/lzxcr/linux-firmware-sheng.git --depth 1 /tmp/temp_fw

echo "正在将固件注入打包目录，并强制转入 /usr/lib..."
mkdir -p firmware-xiaomi-sheng/usr/lib
if [ -d "/tmp/temp_fw/lib" ]; then
    cp -r /tmp/temp_fw/lib/* firmware-xiaomi-sheng/usr/lib/
else
    cp -r /tmp/temp_fw/* firmware-xiaomi-sheng/usr/lib/ 2>/dev/null || true
fi
rm -rf /tmp/temp_fw

# 音频 UCM2
mkdir -p alsa-xiaomi-sheng/usr/share/alsa/ucm2
git clone https://github.com/map220v/alsa-ucm-conf.git --depth 1 /tmp/temp_alsa

if [ -d "/tmp/temp_alsa/ucm2" ]; then
    cp -r /tmp/temp_alsa/ucm2/* alsa-xiaomi-sheng/usr/share/alsa/ucm2/
else
    cp -r /tmp/temp_alsa/* alsa-xiaomi-sheng/usr/share/alsa/ucm2/ 2>/dev/null || true
fi
rm -rf /tmp/temp_alsa

# 键盘认证守护进程
echo "正在拉取 sheng-devauth 源码..."
git clone https://github.com/map220v/sheng_devauth.git --depth 1 /tmp/temp_sd
echo "✓ 源码拉取完成"

echo "正在编译 sheng-devauth 二进制..."
make -C /tmp/temp_sd
echo "✓ 二进制编译完成"

echo "正在打包 sheng-devauth.deb..."
mkdir -p sheng-devauth/usr/bin
chmod 0755 /tmp/temp_sd/xiaomi_devauth
cp /tmp/temp_sd/xiaomi_devauth sheng-devauth/usr/bin/

mkdir -p sheng-devauth/DEBIAN
cat > sheng-devauth/DEBIAN/postinst << 'EOF'
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
  systemctl enable sheng-devauth.service || true
  systemctl start sheng-devauth.service || true
fi
exit 0
EOF
chmod 0755 sheng-devauth/DEBIAN/postinst

cat > sheng-devauth/DEBIAN/prerm << 'EOF'
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop sheng-devauth.service || true
  systemctl disable sheng-devauth.service || true
fi
exit 0
EOF
chmod 0755 sheng-devauth/DEBIAN/prerm

dpkg-deb --build --root-owner-group sheng-devauth
rm -rf /tmp/temp_sd
echo "✓ sheng-devauth 打包完成"

# UsrMerge：/lib -> /usr/lib
echo "正在对内核及音频模块进行安全级 UsrMerge 路径融合..."
for pkg in linux-xiaomi-sheng alsa-xiaomi-sheng; do
    if [ -d "$pkg/lib" ]; then
        echo "正在安全融合 $pkg 中的 /lib 至 /usr/lib..."
        mkdir -p "$pkg/usr/lib"
        cp -r "$pkg/lib"/* "$pkg/usr/lib/" 2>/dev/null || true
        rm -rf "$pkg/lib"
        echo "$pkg 的老式 /lib 目录已安全移除"
    fi
done

# 打包 deb
echo "正在打包其余 .deb 文件..."
dpkg-deb --build --root-owner-group linux-xiaomi-sheng
dpkg-deb --build --root-owner-group firmware-xiaomi-sheng
dpkg-deb --build --root-owner-group alsa-xiaomi-sheng

echo "核心编译、固件注入与音频重组打包全线通关！"
