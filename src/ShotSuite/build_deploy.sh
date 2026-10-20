#!/bin/bash
# build_deploy.sh —— 「截图套件 ShotSuite」构建 / 部署
#
#   一个 deb = Snapper 3 + BigShot 长截图 + 截图标记 + Hammer It + 统一设置入口
#   1.0.1：去掉模块开关与 respring 服务，四模块恒启用，面板只做设置跳转。
#
# 用法:
#   ./build_deploy.sh build    只编译 + 签名
#   ./build_deploy.sh pkg      编译 + 在设备上组装成 deb（不安装）
#   ./build_deploy.sh install  编译 + 打包 + 安装套件 + respring
set -e
cd "$(dirname "$0")"

PKG=ShotSuite
PKGID=com.xu.shotsuite
SSH_HOST="${SSH_HOST:-iphone}"
SSH_ROOT="${SSH_ROOT:-iphone-root}"
VERSION=1.0.5
ARCH=iphoneos-arm64e
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SRC=src
BUILD=build
RDEV=/var/tmp/shotsuite

rm -rf "$BUILD"; mkdir -p "$BUILD"

echo "==> 1/5 编译 ShotSuitePrefs.bundle 可执行文件"
clang -arch arm64e -miphoneos-version-min=14.0 -isysroot "$SDK" \
  -bundle -fobjc-arc -O2 -Wall \
  -framework Foundation -framework UIKit \
  -Wl,-undefined,dynamic_lookup \
  -o "$BUILD/ShotSuitePrefs" "$SRC/ShotSuitePrefs.m"

echo "==> 1.5/5 编译 ShotFix.dylib（截图时排除 SnapperWindow）"
clang -arch arm64e -miphoneos-version-min=14.0 -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -O2 -Wall \
  -framework Foundation -framework UIKit -framework QuartzCore \
  -install_name "/Library/MobileSubstrate/DynamicLibraries/ShotFix.dylib" \
  -o "$BUILD/ShotFix.dylib" "$SRC/ShotFix.m"
ldid -S "$BUILD/ShotFix.dylib"
cp "$SRC/ShotFix.plist" "$BUILD/ShotFix.plist"

echo "==> 2/5 签名（Preferences 严格校验，必须 codesign ad-hoc；ldid 会静默失败）"
codesign -f -s - --timestamp=none "$BUILD/ShotSuitePrefs"
codesign -dvvv "$BUILD/ShotSuitePrefs" 2>&1 | grep -E "CodeDirectory|Signature"
ls -l "$BUILD"

if [ "$1" = "build" ]; then echo "==> 完成（仅编译）"; exit 0; fi

echo "==> 3/5 上传组件到设备"
ssh "$SSH_HOST" "rm -rf $RDEV && mkdir -p $RDEV"
scp -q "$BUILD/ShotSuitePrefs" "$BUILD/ShotFix.dylib" "$BUILD/ShotFix.plist" \
        "$SRC/ShotSuite.plist" "$SRC/Info.plist" \
        "$SRC/Root.plist" "$SRC/postinst" "$SRC/postrm" "$SSH_HOST":$RDEV/

cat > "$BUILD/control" <<EOF
Package: $PKGID
Name: 截图套件 ShotSuite
Version: $VERSION
Architecture: $ARCH
Section: Tweaks
Priority: optional
Depends: mobilesubstrate, preferenceloader, firmware (>= 15.0), com.opa334.ccsupport, com.opa334.altlist, com.opa334.libsandy
Conflicts: com.daodao.snapper3, com.dao.bigshotsnapper3plugin, cn.llld.biaoji, com.lclrc.hammerit
Replaces: com.daodao.snapper3, com.dao.bigshotsnapper3plugin, cn.llld.biaoji, com.lclrc.hammerit
Maintainer: g459416925
Author: g459416925
Description: Snapper 3 + BigShot 长截图 + 截图标记 + Hammer It 四合一。
 一个安装包、一个设置入口，四个模块默认全部启用。
 模块本体原样保留（闭源二进制），面板提供各模块的设置入口。
EOF
scp -q "$BUILD/control" "$SSH_HOST":$RDEV/control

echo "==> 4/5 设备上组装 deb"
ssh "$SSH_ROOT" 'sh -s' <<'EOS'
set -e
BUILD=/var/mobile/shotsuite_build
STAGE=$BUILD/stage
SRC=/var/tmp/shotsuite

[ -f /var/mobile/shotsuite_backup/payload_all.tar ] || { echo "缺备份 tar"; exit 1; }

rm -rf "$BUILD"; mkdir -p "$STAGE"
cd "$STAGE"
tar -xpf /var/mobile/shotsuite_backup/payload_all.tar

# --- 新组件 ---
mkdir -p Library/PreferenceBundles/ShotSuitePrefs.bundle
cp "$SRC/ShotSuitePrefs" "$SRC/Info.plist" "$SRC/Root.plist" \
   Library/PreferenceBundles/ShotSuitePrefs.bundle/
cp Library/ControlCenter/Bundles/Snapper3CCSupportNormal.bundle/icon.png \
   Library/PreferenceBundles/ShotSuitePrefs.bundle/icon.png
cp "$SRC/ShotSuite.plist" Library/PreferenceLoader/Preferences/
cp "$SRC/ShotFix.dylib" "$SRC/ShotFix.plist" Library/MobileSubstrate/DynamicLibraries/

# --- 统一入口：移除原两个根列表条目 ---
rm -f Library/PreferenceLoader/Preferences/Snapper3Preferences.plist
rm -f Library/PreferenceLoader/Preferences/HammerItPrefs.plist

# --- DEBIAN ---
mkdir -p DEBIAN
cp "$SRC/control" DEBIAN/control
cp "$SRC/postinst" "$SRC/postrm" DEBIAN/
chmod 755 DEBIAN/postinst DEBIAN/postrm

# --- 权限 ---
chmod 755 Library/PreferenceBundles/ShotSuitePrefs.bundle/ShotSuitePrefs
chmod 644 Library/PreferenceBundles/ShotSuitePrefs.bundle/Info.plist
chmod 644 Library/PreferenceBundles/ShotSuitePrefs.bundle/Root.plist
chmod 644 Library/PreferenceLoader/Preferences/ShotSuite.plist
chmod 755 Library/MobileSubstrate/DynamicLibraries/ShotFix.dylib
chmod 644 Library/MobileSubstrate/DynamicLibraries/ShotFix.plist

VER=$(grep "^Version:" DEBIAN/control | awk '{print $2}')
OUT=/var/tmp/shotsuite/com.xu.shotsuite_${VER}_iphoneos-arm64e.deb
dpkg-deb -b --root-owner-group "$STAGE" "$OUT" >/dev/null
echo "deb: $(stat -c %s $OUT) 字节 / $(dpkg-deb -c $OUT | wc -l) 条目"
EOS

if [ "$1" != "install" ]; then
  echo "==> 完成（已产出 deb，未安装）"
  ssh "$SSH_ROOT" 'ls -l /var/tmp/shotsuite/*.deb'
  exit 0
fi

echo "==> 5/5 安装并 respring"
ssh "$SSH_ROOT" 'DEB=$(ls -t /var/tmp/shotsuite/com.xu.shotsuite_*.deb | head -1); echo "安装 $DEB"; dpkg -i "$DEB" 2>&1 | grep -viE "warning|Maintainer" | tail -6
echo "----- 校验 -----"
dpkg -s com.xu.shotsuite | grep -E "^(Status|Version)"
echo "--- 过滤 plist 应为实体文件 ---"
for f in Snapper3.plist biaoji.plist HammerIt.plist BigShotSnapper3Plugin.plist; do
  printf "%-32s " $f; [ -L /usr/lib/TweakInject/$f ] && echo "符号链接(异常)" || echo "实体 ✓"
done
echo "--- Core 应已移除 ---"
ls /usr/lib/TweakInject/ShotSuiteCore.dylib 2>/dev/null || echo "ShotSuiteCore 已不存在 ✓"
sbreload; echo "respring 已触发"'
