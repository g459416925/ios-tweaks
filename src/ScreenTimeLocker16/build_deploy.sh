#!/bin/bash
# build_deploy.sh —— 编译 + 签名 + 校验 + 部署 ScreenTimeLocker16
# 关键：**必须校验签名已生效**（体积需增大约 1KB），否则 dyld 会以
#       CODESIGNING / Invalid Page 杀掉宿主进程（曾把 SpringBoard 打挂）。
set -e
cd "$(dirname "$0")"

PKG=ScreenTimeLocker16
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

echo "==> 1/5 编译 (arm64e, iOS SDK $(basename "$SDK"))"
clang -arch arm64e -miphoneos-version-min=14.0 -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -O2 -Wall -Wno-unused-variable \
  -Wno-unguarded-availability-new \
  -framework Foundation -framework UIKit -framework LocalAuthentication \
  -install_name "/Library/MobileSubstrate/DynamicLibraries/$PKG.dylib" \
  -o "$PKG.dylib" "$PKG.m"

UNSIGNED=$(stat -f%z "$PKG.dylib")
echo "    未签名体积: $UNSIGNED"

echo "==> 2/5 检查是否残留私有类符号（应为空）"
if nm -u "$PKG.dylib" | grep -E "_OBJC_CLASS_\\\$_(ST|SBS|SB)" ; then
  echo "    ✗ 仍有私有类符号，会导致 dlopen 失败！"; exit 1
fi
echo "    ✓ 无私有类符号"

echo "==> 3/5 上传并在设备上 ldid -S 签名"
scp -q "$PKG.dylib" iphone:/tmp/$PKG.dylib
ssh iphone "ldid -S /tmp/$PKG.dylib; echo -n '/tmp/$PKG.dylib 签名后体积: '; stat -c %s /tmp/$PKG.dylib"
SIGNED=$(ssh iphone "stat -c %s /tmp/$PKG.dylib")
if [ "$SIGNED" -le "$UNSIGNED" ]; then
  echo "    ✗ 签名未生效（体积未增长 $UNSIGNED -> $SIGNED）！拒绝部署。"; exit 1
fi
echo "    ✓ 签名已生效 ($UNSIGNED -> $SIGNED, +$((SIGNED-UNSIGNED)) B)"

echo "==> 4/5 拉回校验 CodeDirectory"
scp -q iphone:/tmp/$PKG.dylib ./$PKG.signed.dylib
codesign -dvvv ./$PKG.signed.dylib 2>&1 | grep -E "CodeDirectory|Hash type|hashes" || true

echo "==> 5/5 部署到设备"
scp -q ./$PKG.signed.dylib iphone:/var/mobile/Documents/
scp -q ./$PKG.plist        iphone:/var/mobile/Documents/
ssh iphone-root "DL=/Library/MobileSubstrate/DynamicLibraries
cp /var/mobile/Documents/$PKG.signed.dylib \$DL/$PKG.dylib
cp /var/mobile/Documents/$PKG.plist        \$DL/$PKG.plist
chmod 755 \$DL/$PKG.dylib; chown root:wheel \$DL/$PKG.dylib
chmod 644 \$DL/$PKG.plist; chown root:wheel \$DL/$PKG.plist
echo '    落地:'; ls -la \$DL/$PKG.dylib \$DL/$PKG.plist
echo \"    DynamicLibraries 计数: \$(ls \$DL/*.dylib | wc -l)\""

echo "==> 完成。设备侧自行验证签名：ssh iphone \"stat -c %s /Library/MobileSubstrate/DynamicLibraries/$PKG.dylib\" 应等于 $SIGNED"
