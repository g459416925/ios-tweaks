#!/bin/bash
# build_deploy.sh —— 编译 + 签名 + 校验 + dpkg 部署 StatusBarScale
#
# 关键：**必须校验签名已生效**（体积需增大约 1KB），否则 dyld 会以
#       CODESIGNING / Invalid Page 杀掉宿主进程（曾把 SpringBoard 打挂）。
#
# 注意：/Library/MobileSubstrate/DynamicLibraries 在 RootHide 下是
#       /usr/lib/TweakInject 的符号链接，两个路径等价。
set -e
cd "$(dirname "$0")"

PKG=StatusBarScale
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
REMOTE_TMP=/var/tmp          # ⚠️ 设备上 /tmp 不可靠，统一用 /var/tmp

echo "==> 1/6 编译 (arm64e, iOS SDK $(basename "$SDK"))"
clang -arch arm64e -miphoneos-version-min=14.0 -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -O2 -Wall -Wno-unused-variable \
  -framework Foundation -framework UIKit -framework CoreGraphics \
  -install_name "/Library/MobileSubstrate/DynamicLibraries/$PKG.dylib" \
  -o "$PKG.dylib" "$PKG.m"

UNSIGNED=$(stat -f%z "$PKG.dylib")
echo "    未签名体积: $UNSIGNED"

echo "==> 2/6 检查私有符号必须为空（否则 dlopen 会整体失败）"
# ⚠️ 只匹配【私有类】符号：_OBJC_CLASS_$__UI*（如 _UIStatusBarForegroundView）
#    或 _OBJC_CLASS_$_UIStatusBar*/SB*。公共类 _OBJC_CLASS_$_UIView / $_UIApplication
#    / $_UIScreen 会正常出现，绝不能被误判（旧正则 _OBJC_CLASS_$_(UI|...) 会命中它们）
#    → 脚本会在这一步无条件 exit 1，部署永远走不完。
if nm -u "$PKG.dylib" | grep -qE "_OBJC_CLASS_\\\$__UI|_OBJC_CLASS_\\\$_(UIStatusBar|SB)"; then
  echo "    ✗ 残留私有类符号，会导致 dlopen 失败！"; exit 1
fi
echo "    ✓ 无私有类符号（_UIStatusBarForegroundView 等全部运行时 objc_getClass）"

echo "==> 3/6 上传并在设备上 ldid -S 签名"
scp -q "$PKG.dylib" iphone:$REMOTE_TMP/$PKG.dylib
ssh iphone "ldid -S $REMOTE_TMP/$PKG.dylib; echo -n \"$REMOTE_TMP/$PKG.dylib 签名后体积: \"; stat -c %s $REMOTE_TMP/$PKG.dylib"
SIGNED=$(ssh iphone "stat -c %s $REMOTE_TMP/$PKG.dylib")
if [ "$SIGNED" -le "$UNSIGNED" ]; then
  echo "    ✗ 签名未生效（体积未增长 $UNSIGNED -> $SIGNED）！拒绝部署。"; exit 1
fi
echo "    ✓ 签名已生效 ($UNSIGNED -> $SIGNED, +$((SIGNED-UNSIGNED)) B)"

echo "==> 4/6 拉回校验 CodeDirectory"
scp -q iphone:$REMOTE_TMP/$PKG.dylib ./$PKG.signed.dylib
codesign -dvvv ./$PKG.signed.dylib 2>&1 | grep -E "CodeDirectory|Hash type|hashes" || true

echo "==> 5/7 编译并签名设置面板（PreferenceBundle）"
if [ -x ../StatusBarScalePrefs/build_prefs.sh ]; then
  ( cd ../StatusBarScalePrefs && ./build_prefs.sh )
else
  echo "    ⚠️ 未找到 ../StatusBarScalePrefs/build_prefs.sh —— 将跳过设置面板打包"
fi

echo "==> 6/7 打包 RootHide DEB（插件 + 设置面板）"
python3 build_deb.py
DEB=$(ls -t "${PKG}"_*_iphoneos-arm64e.deb | head -1)
test -n "$DEB"

echo "==> 7/7 通过 dpkg 部署到设备（禁止 root cp 直写 TweakInject）"
scp -q "$DEB" iphone:$REMOTE_TMP/$PKG.deb
ssh iphone-root "dpkg -i $REMOTE_TMP/$PKG.deb
echo '    落地:'
ls -la /Library/MobileSubstrate/DynamicLibraries/$PKG.dylib
ls -la /Library/PreferenceBundles/StatusBarScalePrefs.bundle/
ls -la /Library/PreferenceLoader/Preferences/$PKG.plist"

echo "==> 完成。生效需 respring（sbreload）；已通过 dpkg 触发 RootHide 完整 patch 流程。"
echo "==> 配置：/rootfs/private/var/mobile/Library/Preferences/com.xu.statusbarscale.plist（SSH 部署必须走 /rootfs 前缀！）"
