#!/bin/bash
source "/Users/xu/WorkBuddy/IOS设备处理/device-tools/env.sh"  # 统一设备入口：USB -> LAN -> Tailscale
# build_deploy.sh —— 桌面净空 NoHomeIcons 构建 / 部署
#
#   ./build_deploy.sh build    只编译（本地）
#   ./build_deploy.sh pkg      编译 + 签名 + 设备上组装 deb（不安装）
#   ./build_deploy.sh install  编译 + 打包 + dpkg 安装 + sbreload
#
# RootHide 规则（踩过的坑，别改）：
#   · dylib 用 ldid -S 即可（codesign 签的 dylib ellekit 不注入）
#   · 必须 dpkg -i 安装，禁止 root cp 直写 TweakInject（签名失效 → SIGKILL）
#   · 设备 /tmp 不可用，统一 /var/tmp
set -e
cd "$(dirname "$0")"

PKG=NoHomeIcons16
PKGID=com.xu.nohomeicons
VERSION=$(grep -oE '@"([0-9]+\.[0-9]+\.[0-9]+)"' NoHomeIcons16.m | head -1 | tr -d '@"')
[ -n "$VERSION" ] || VERSION=0.1.0
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
RDEV=/var/tmp/nhi
STAGE=/var/mobile/nhi_build/stage

echo "==> 1/5 编译 dylib (arm64e, $VERSION)"
clang -arch arm64e -miphoneos-version-min=14.0 -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -O2 -Wall \
  -framework Foundation -framework UIKit \
  -install_name "/Library/MobileSubstrate/DynamicLibraries/$PKG.dylib" \
  -o "$PKG.dylib" "$PKG.m"
UNSIGNED=$(stat -f%z "$PKG.dylib")
echo "    未签名体积: $UNSIGNED"

echo "==> 2/5 私有符号检查（dlopen 失败的头号原因）"
if nm -u "$PKG.dylib" | grep -qE "_OBJC_CLASS_\\\$_(SB|_UI)"; then
  echo "    ✗ 残留私有类符号"; nm -u "$PKG.dylib" | grep -E "_OBJC_CLASS_\\\$_(SB|_UI)"; exit 1
fi
echo "    ✓ 无私有类符号"

[ "$1" = "build" ] && { echo "==> 完成（仅编译）"; exit 0; }

echo "==> 3/5 上传并签名"
ssh iphone "rm -rf $RDEV && mkdir -p $RDEV"
scp -q "$PKG.dylib" "$PKG.plist" iphone:$RDEV/
ssh iphone "ldid -S $RDEV/$PKG.dylib; echo -n '    签名后: '; stat -c %s $RDEV/$PKG.dylib"
SIGNED=$(ssh iphone "stat -c %s $RDEV/$PKG.dylib")
[ "$SIGNED" -gt "$UNSIGNED" ] || { echo "    ✗ 签名未生效 $UNSIGNED -> $SIGNED"; exit 1; }
echo "    ✓ 签名生效 (+$((SIGNED-UNSIGNED)) B)"

# control 单一来源：control 模板（__VERSION__ 占位），本地打包脚本共用同一份
sed "s/__VERSION__/$VERSION/" control > /tmp/nhi_control
scp -q /tmp/nhi_control iphone:$RDEV/control

echo "==> 4/5 设备上组装 deb"
ssh iphone-root "set -e
rm -rf $STAGE && mkdir -p $STAGE/Library/MobileSubstrate/DynamicLibraries $STAGE/DEBIAN
cp $RDEV/$PKG.dylib $RDEV/$PKG.plist $STAGE/Library/MobileSubstrate/DynamicLibraries/
cp $RDEV/control $STAGE/DEBIAN/control
chmod 755 $STAGE/Library/MobileSubstrate/DynamicLibraries/$PKG.dylib
chmod 644 $STAGE/Library/MobileSubstrate/DynamicLibraries/$PKG.plist $STAGE/DEBIAN/control
rm -f $RDEV/$PKG.deb
dpkg-deb -b --root-owner-group $STAGE $RDEV/$PKG.deb >/dev/null
echo -n '    deb: '; stat -c %s $RDEV/$PKG.deb; echo -n ' 条目: '; dpkg-deb -c $RDEV/$PKG.deb | wc -l"

[ "$1" = "pkg" ] && { echo "==> 完成（已产出 deb，未安装）"; exit 0; }

echo "==> 5/5 安装 + respring"
ssh iphone-root "dpkg -i $RDEV/$PKG.deb 2>&1 | grep -viE 'warning|Maintainer' | tail -5
echo '--- 落地 ---'
dpkg -s $PKGID | grep -E '^(Status|Version)'
ls -l /Library/MobileSubstrate/DynamicLibraries/$PKG.dylib
sbreload"
echo "==> 完成。日志: /rootfs/private/var/mobile/Documents/NoHomeIcons_probe.log"
