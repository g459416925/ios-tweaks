#!/bin/bash
# build_deploy.sh —— 编译 + 签名 + 校验 + 部署 CompactorFix
#
# 关键：**必须校验签名已生效**（体积需增大约 1KB），否则 dyld 会以
#       CODESIGNING / Invalid Page 杀掉宿主进程（曾把 SpringBoard 打挂）。
#
# 注意：/Library/MobileSubstrate/DynamicLibraries 在 RootHide 下是
#       /usr/lib/TweakInject 的符号链接，两个路径等价。
set -e
cd "$(dirname "$0")"

PKG=CompactorFix
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
REMOTE_TMP=/var/tmp          # ⚠️ 设备上 /tmp 不可靠，统一用 /var/tmp

echo "==> 1/5 编译 (arm64e, iOS SDK $(basename "$SDK"))"
clang -arch arm64e -miphoneos-version-min=14.0 -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -O2 -Wall -Wno-unused-variable \
  -framework Foundation -framework CoreText \
  -undefined dynamic_lookup \
  -install_name "/Library/MobileSubstrate/DynamicLibraries/$PKG.dylib" \
  -o "$PKG.dylib" "$PKG.m"

UNSIGNED=$(stat -f%z "$PKG.dylib")
echo "    未签名体积: $UNSIGNED"

echo "==> 2/5 检查私有符号必须为 weak（否则 dlopen 会整体失败）"
nm -m "$PKG.dylib" | grep -i "CTFontSetAltTextStyleSpec" || echo "    （未在符号表中出现，靠 dlopen 运行时解析，亦可）"
if nm -u "$PKG.dylib" | grep -qE "_OBJC_CLASS_\\\$_(ST|SBS|SB)"; then
  echo "    ✗ 残留私有类符号，会导致 dlopen 失败！"; exit 1
fi
echo "    ✓ 无私有类符号"

echo "==> 3/5 上传并在设备上 ldid -S 签名"
scp -q "$PKG.dylib" iphone:$REMOTE_TMP/$PKG.dylib
ssh iphone "ldid -S $REMOTE_TMP/$PKG.dylib; echo -n \"$REMOTE_TMP/$PKG.dylib 签名后体积: \"; stat -c %s $REMOTE_TMP/$PKG.dylib"
SIGNED=$(ssh iphone "stat -c %s $REMOTE_TMP/$PKG.dylib")
if [ "$SIGNED" -le "$UNSIGNED" ]; then
  echo "    ✗ 签名未生效（体积未增长 $UNSIGNED -> $SIGNED）！拒绝部署。"; exit 1
fi
echo "    ✓ 签名已生效 ($UNSIGNED -> $SIGNED, +$((SIGNED-UNSIGNED)) B)"

echo "==> 4/5 拉回校验 CodeDirectory"
scp -q iphone:$REMOTE_TMP/$PKG.dylib ./$PKG.signed.dylib
codesign -dvvv ./$PKG.signed.dylib 2>&1 | grep -E "CodeDirectory|Hash type|hashes" || true

echo "==> 5/5 部署到设备"
scp -q ./$PKG.signed.dylib iphone:$REMOTE_TMP/
scp -q ./$PKG.plist        iphone:$REMOTE_TMP/
ssh iphone-root "DL=/Library/MobileSubstrate/DynamicLibraries
cp $REMOTE_TMP/$PKG.signed.dylib \$DL/$PKG.dylib
cp $REMOTE_TMP/$PKG.plist        \$DL/$PKG.plist
chmod 755 \$DL/$PKG.dylib; chown root:wheel \$DL/$PKG.dylib
chmod 644 \$DL/$PKG.plist; chown root:wheel \$DL/$PKG.plist
echo '    落地:'; ls -la \$DL/$PKG.dylib \$DL/$PKG.plist"

echo "==> 完成。生效需 respring（sbreload）；核实签名：ssh iphone \"stat -c %s /usr/lib/TweakInject/$PKG.dylib\" 应等于 $SIGNED"
