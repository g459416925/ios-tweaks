#!/bin/bash
# build_prefs.sh —— 编译 + 签名「状态栏缩放」设置面板（PreferenceBundle）
#
# 产物: ./StatusBarScalePrefs  （已 ldid 签名，供 build_deb.py 打包）
#
# ⚠️ 面板二进制与 tweak 一样必须签名（未签名会让「设置」App 加载时被内核杀掉）；
#    签名后体积需增长约 1KB，脚本会强制校验。
# ⚠️ 用 -undefined dynamic_lookup：PSListController / PSTableCell 由「设置」App 运行时提供，
#    绝不链接 Preferences.framework（零硬符号）。
set -e
cd "$(dirname "$0")"

PKG=StatusBarScalePrefs
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
REMOTE_TMP=/var/tmp          # ⚠️ 设备上 /tmp 不可靠，统一用 /var/tmp
PY=/Users/xu/.workbuddy/binaries/python/versions/3.13.12/bin/python3

echo "==> 1/5 生成图标"
"$PY" make_icon.py

echo "==> 2/5 编译 (arm64e)"
clang -arch arm64e -miphoneos-version-min=14.0 -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -O2 -Wall -Wno-unused-variable \
  -framework Foundation -framework UIKit \
  -undefined dynamic_lookup \
  -install_name @rpath/$PKG \
  -o "$PKG.unsigned" "$PKG.m"
UNSIGNED=$(stat -f%z "$PKG.unsigned")
echo "    未签名体积: $UNSIGNED"

echo "==> 3/5 检查禁用路径字面量（RootHide patch 会改坏签名）"
if strings "$PKG.unsigned" | grep -qE '/System/Library|/var/jb|TweakInject'; then
  echo "    ✗ 含完整系统路径字面量，拒绝部署"; exit 1
fi
echo "    ✓ 无 /System/Library 等完整系统路径"

echo "==> 4/5 上传并在设备上 ldid -S 签名"
ssh iphone-root "rm -f $REMOTE_TMP/$PKG"
scp -q "$PKG.unsigned" iphone:$REMOTE_TMP/$PKG
ssh iphone-root "ldid -S $REMOTE_TMP/$PKG; printf '    签名后体积: '; stat -c %s $REMOTE_TMP/$PKG"
SIGNED=$(ssh iphone-root "stat -c %s $REMOTE_TMP/$PKG")
if [ "$SIGNED" -le "$UNSIGNED" ]; then
  echo "    ✗ 签名未生效（体积未增长 $UNSIGNED -> $SIGNED）！拒绝打包。"; exit 1
fi
echo "    ✓ 签名已生效 (+$((SIGNED-UNSIGNED)) B)"

echo "==> 5/5 拉回签名产物"
scp -q iphone:$REMOTE_TMP/$PKG ./$PKG
codesign -dvvv ./$PKG 2>&1 | grep -E "CodeDirectory" || true
rm -f "$PKG.unsigned"
ls -la "./$PKG"
echo "==> 完成：$(pwd)/$PKG 就绪（供 build_deb.py 打包）"
