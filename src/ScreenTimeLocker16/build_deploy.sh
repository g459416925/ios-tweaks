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
# ⚠️ RootHide 下不要用 /tmp（相对符号链接会解析进 jbroot 影子目录）→ 一律 /var/tmp
scp -q "$PKG.dylib" iphone:/var/tmp/$PKG.dylib
ssh iphone "ldid -S /var/tmp/$PKG.dylib; echo -n '/var/tmp/$PKG.dylib 签名后体积: '; stat -c %s /var/tmp/$PKG.dylib"
SIGNED=$(ssh iphone "stat -c %s /var/tmp/$PKG.dylib")
if [ "$SIGNED" -le "$UNSIGNED" ]; then
  echo "    ✗ 签名未生效（体积未增长 $UNSIGNED -> $SIGNED）！拒绝部署。"; exit 1
fi
echo "    ✓ 签名已生效 ($UNSIGNED -> $SIGNED, +$((SIGNED-UNSIGNED)) B)"

echo "==> 4/5 拉回校验 CodeDirectory"
scp -q iphone:/var/tmp/$PKG.dylib ./$PKG.signed.dylib
codesign -dvvv ./$PKG.signed.dylib 2>&1 | grep -E "CodeDirectory|Hash type|hashes" || true

echo "==> 5/5 打包 DEB 并用 dpkg 部署"
# ⛔⛔ 历史事故（技能 §2.14）：**绝不能 root cp 直写 /usr/lib/TweakInject 的二进制**——
#      RootHide 的 jbroot on-write patch 会改写文件头/尾 → 签名失效 → dyld 以
#      `SIGKILL CODESIGNING / Invalid Page` 杀掉宿主（曾把 SpringBoard 打挂）。
#      必须走 dpkg -i。（plist 无签名，cp 安全，但统一走 deb 更省心。）
/Users/xu/.workbuddy/binaries/python/versions/3.13.12/bin/python3 build_deb.py
DEB=$(ls -t ${PKG}_*_iphoneos-arm64e.deb | head -1)
test -n "$DEB"
scp -q "$DEB" iphone:/var/tmp/$PKG.deb
ssh iphone-root "dpkg -i /var/tmp/$PKG.deb
DL=/usr/lib/TweakInject
echo '    落地:'; ls -la \$DL/$PKG.dylib \$DL/$PKG.plist"

echo "==> 完成。生效需 respring（sbreload）。"
echo "==> 设备侧校验: ssh iphone-root 'wc -c /usr/lib/TweakInject/$PKG.dylib' 应等于 $SIGNED"
