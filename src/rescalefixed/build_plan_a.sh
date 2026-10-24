#!/bin/bash
# plan-a（3.0.0）一键构建：零新二进制 + 固定偏好 + 无面板
#
# 核心原则（2026-10-24 两次看门狗事故后固化）：
#   · 注入器必须是 RootHide 信任缓存里已有的原版二进制，CDHash 一个不能变：
#       ReScale.dylib   CDHash D29EE234…（在信任缓存）
#       ReScaleKB.dylib CDHash 72002A5D…（设备实测受信版；61806419 版不受信）
#   · guard 标记 tf.festival.rescale2.list 用 chflags uchg 锁死（缺了 ReScale 会静默失效）
#   · 分辨率 = postinst 写死的偏好文件（1320×2868 = 440×956pt @3x），不改任何字节
#   · postinst 零重启：backboardd 归 user/501 域，kickstart system/… 只打警告不生效；
#     dpkg 事务里 killall -9 backboardd 会进 spawn 循环 → 看门狗（已两次事故）
#   · 无界面：不打包 ReScalePreferences.bundle / PreferenceLoader 条目，postinst 顺带清理
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"

VER="${VER:-3.1.1}"
PKG=com.xu.rescalefixed
ARCH=iphoneos-arm64e
NAME=ReScale
NAMEKB=ReScaleKB

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

say "0) 原版注入器字节校验（不得改动）"
ORIG=../../merge-kb440/baseline/Library/MobileSubstrate/DynamicLibraries/$NAME.dylib
ORIG_KB=../../merge-kb440/build/ReScaleKB.trusted.dylib
[ -f "$ORIG" ] && [ -f "$ORIG_KB" ] || { echo "!! 缺少原版二进制"; exit 1; }
for f in "$ORIG" "$ORIG_KB"; do
  H=$(codesign -d --verbose=4 "$f" 2>&1 | sed -n 's/^CDHash=//p' | head -1)
  echo "   $(basename "$f") CDHash=$H"
done

say "1) 组装 stage（原样拷贝，不改字节）"
rm -rf stage
mkdir -p stage/DEBIAN stage/Library/MobileSubstrate/DynamicLibraries stage/usr/bin
D=stage/Library/MobileSubstrate/DynamicLibraries
cp -f "$ORIG"    "$D/$NAME.dylib"
cp -f "$ORIG_KB" "$D/$NAMEKB.dylib"
cp -f ../../merge-kb440/baseline/Library/MobileSubstrate/DynamicLibraries/$NAME.plist "$D/$NAME.plist"
printf '{ Filter = { Bundles = ( "com.apple.UIKit" ); }; }\n' > "$D/$NAMEKB.plist"
chmod 755 "$D/"*.dylib; chmod 644 "$D/"*.plist
# 自检脚本：/usr/bin/rf_check（#!/usr/bin/sh —— 设备上 /bin/sh 是悬空软链）
cp -f "$HERE/rf_check.sh" stage/usr/bin/rf_check
chmod 755 stage/usr/bin/rf_check
echo "   stage 载荷："
ls -la "$D"
echo "   /usr/bin/rf_check: $(wc -c < stage/usr/bin/rf_check) 字节"


say "2) 写 control / postinst / postrm"
cat > stage/DEBIAN/control <<EOF
Package: $PKG
Name: Re:Scale Fixed 440
Version: $VER
Architecture: $ARCH
Section: Tweaks
Priority: optional
Maintainer: g459416925
Depends: mobilesubstrate, firmware (>= 14.0)
Conflicts: tf.festival.rescale2, com.xu.rescalekb440fix, com.xu.rescale2plus
Replaces: tf.festival.rescale2, com.xu.rescalekb440fix, com.xu.rescale2plus
Description: 固定 440x956 分辨率（iPhone 18 Pro Max 6.9" @3x），装完即生效
 安装即在系统里写入固定的画布偏好 1320x2868（= 440x956pt @3x），
 并删除设置面板与 PreferenceLoader 条目：没有界面、不需要点确认、
 不需要任何设置，装完 respring 一次就全局生效。
 分辨率注入复用原版 ReScale.dylib（字节未改，签名受信），
 键盘宽度 414 -> 440 的修正内联在 ReScaleKB 里。
 自带自检工具：/usr/bin/rf_check（加 --fix 可修复丢失的标记/偏好）。
 自带自愈守护 com.xu.rescalefixed.heal：开机/userspace reboot 自动补文件，
 respring 后 2 分钟内补齐；仅在确实修复时才重启一次 backboardd 让画布重读。
 与原版 Re:Scale 2 及带面板的重打包版互斥。
Tag: purpose::extension
EOF

cat > stage/DEBIAN/postinst <<'PEOF'
#!/bin/sh
set -e
D=/Library/MobileSubstrate/DynamicLibraries
PREF=/var/mobile/Library/Preferences/tf.festival.rescale.plist

# 1) 写入固定画布偏好（唯一数据源，ReScale.dylib 从这里读 1320x2868）
#    二进制 bplist（base64）：canvas_width=1320, canvas_height=2868,
#    confirmedResolution=true。等价于 plistlib 生成的 110 字节，已验证可回读。
mkdir -p /var/mobile/Library/Preferences
echo 'YnBsaXN0MDDTAQIDBAUGXWNhbnZhc19oZWlnaHRcY2FudmFzX3dpZHRoXxATY29uZmlybWVkUmVzb2x1dGlvbhELNBEFKAkIDx0qQENGAAAAAAAAAQEAAAAAAAAABwAAAAAAAAAAAAAAAAAAAEc=' | base64 -d > "$PREF"
chmod 600 "$PREF"
chown mobile:mobile "$PREF" 2>/dev/null || true

# 2) 兼容原版各 dylib 的 guard 标记
#    ⚠️ 这个文件决定 ReScale 是否装 hook：不存在 → 静默不生效（分辨率回落原生 430×932）。
#    历史上被旧包 purge 时的 postrm 删过一次，导致 440 无声失效。
#    这里加 chflags uchg 锁死，别的包的 rm -f 会失败，标记就不会被误删。
M=/Library/dpkg/info/tf.festival.rescale2.list
mkdir -p /Library/dpkg/info
chflags nouchg "$M" 2>/dev/null || true
: > "$M"
chmod 644 "$M"
chflags uchg "$M" 2>/dev/null || true

# 3) RootHide：注入器需要 .roothidepatch 才走 jbroot 视图
ln -sf /usr/lib/DynamicPatches/AutoPatches.dylib "$D/ReScale.dylib.roothidepatch" 2>/dev/null || true
ln -sf /usr/lib/DynamicPatches/AutoPatches.dylib "$D/ReScaleKB.dylib.roothidepatch" 2>/dev/null || true

# 4) 无界面：删掉设置面板与入口
rm -rf "/Library/PreferenceBundles/ReScalePreferences.bundle"
rm -f  "/Library/PreferenceLoader/Preferences/ReScalePreferences.plist"

# 5) 清掉不需要的旁支 dylib（带弹窗/手势的那些）
rm -f "$D/ReScaleUIKit.dylib" "$D/ReScaleUIKit.plist" "$D/ReScaleUIKit.dylib.roothidepatch"
rm -f "$D/ReScaleActivator.dylib" "$D/ReScaleActivator.plist" "$D/ReScaleActivator.dylib.roothidepatch"
rm -f "$D/ReScaleFixed.dylib" "$D/ReScaleFixed.plist" "$D/ReScaleFixed.dylib.roothidepatch"

# 6) 自检脚本权限（脚本已由 dpkg 落到 /usr/bin/rf_check）
chmod 755 /usr/bin/rf_check 2>/dev/null || true

# 6.1) 生成并加载自愈守护
#      RootHide 的 dpkg 触发器会自动把 plist 里 ProgramArguments[0] 前缀成 jbroot 路径，
#      所以这里必须写"原生路径"（/bin/sh），写死 jbroot 前缀会被再前缀一次。
#      daemon 自身不注入任何进程，只跑文件修复；必要时用 launchctl kickstart 让
#      backboardd 重读画布（10 分钟防抖）。
mkdir -p /var/log
OUT=/Library/LaunchDaemons/com.xu.rescalefixed.heal.plist
launchctl bootout system/com.xu.rescalefixed.heal 2>/dev/null || true
rm -f "$OUT"
cat > "$OUT" <<HEALEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.xu.rescalefixed.heal</string>
<key>ProgramArguments</key><array>
<string>/bin/sh</string><string>/usr/bin/rf_check</string><string>--heal</string>
</array>
<key>RunAtLoad</key><true/>
<key>StartInterval</key><integer>120</integer>
<key>ThrottleInterval</key><integer>60</integer>
<key>ProcessType</key><string>Background</string>
<key>StandardOutPath</key><string>/var/log/rfheal.log</string>
<key>StandardErrorPath</key><string>/var/log/rfheal.log</string>
</dict></plist>
HEALEOF
chmod 644 "$OUT"
launchctl bootstrap system "$OUT" 2>/dev/null || true

# 7) 绝不重启任何系统进程（见 build_plan_a.sh 头部事故记录）
exit 0
PEOF

cat > stage/DEBIAN/postrm <<'PEOF'
#!/bin/sh
set -e
D=/Library/MobileSubstrate/DynamicLibraries
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    chflags nouchg "/Library/dpkg/info/tf.festival.rescale2.list" 2>/dev/null || true
    rm -f "/Library/dpkg/info/tf.festival.rescale2.list"
    rm -f "$D/ReScale.dylib.roothidepatch" "$D/ReScaleKB.dylib.roothidepatch"
    launchctl bootout system/com.xu.rescalefixed.heal 2>/dev/null || true
    rm -f /Library/LaunchDaemons/com.xu.rescalefixed.heal.plist
    rm -f /var/run/rf_heal.last
fi
exit 0
PEOF

chmod 755 stage/DEBIAN/postinst stage/DEBIAN/postrm
sh -n stage/DEBIAN/postinst && echo "   postinst 语法 OK"

say "3) 打包"
mkdir -p build
rm -f "build/${PKG}_${VER}_${ARCH}.deb"
python3 ../tools/debbuild.py stage "build/${PKG}_${VER}_${ARCH}.deb"

say "4) 产物自检"
python3 - <<PY
import tarfile, io
d=open('build/${PKG}_${VER}_${ARCH}.deb','rb').read()
assert d[:8]==b'!<arch>\n'
off=8; m={}
while off<len(d)-4:
    h=d[off:off+60]; n=h[:16].decode().strip()
    try: sz=int(h[48:58].decode().strip())
    except: break
    m[n]=d[off+60:off+60+sz]; off+=60+sz+(sz&1)
ct=tarfile.open(fileobj=io.BytesIO(m['control.tar.xz']))
dt=tarfile.open(fileobj=io.BytesIO(m['data.tar.xz']))
print("   control:", [x.name for x in ct.getmembers()])
for l in ct.extractfile('./control').read().decode().splitlines():
    if l.startswith(('Package:','Version:','Architecture:')): print("   "+l)
for x in dt.getmembers():
    if x.isfile():
        print(f"   data: {x.name:60s} {x.size:7d}")
PY

say "构建完成：build/${PKG}_${VER}_${ARCH}.deb"