#!/bin/bash
# KeyboardCorner16 构建部署：编译 → 安全检查 → 设备签名 → 打包 deb → 部署 → sbreload → 读日志
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
SSH_HOST="${SSH_HOST:-iphone}"
SSH_ROOT="${SSH_ROOT:-iphone-root}"
NAME=KeyboardCorner16; PKG=com.xu.keyboardcorner16; ARCH=iphoneos-arm64e
VER=$(grep -o '#define KBC_VERSION @\{0,1\}"[^"]*"' "$NAME.m" | sed 's/.*"\([^"]*\)".*/\1/')
[ -n "$VER" ] || { echo "!! 读不到 KBC_VERSION"; exit 1; }
echo "   版本: $VER"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

echo "== 1) 编译 =="
clang -arch arm64e -miphoneos-version-min=14.0 -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -O2 -Wall -Wno-deprecated-declarations \
  -undefined dynamic_lookup -framework Foundation -framework UIKit \
  -install_name "/Library/MobileSubstrate/DynamicLibraries/$NAME.dylib" \
  -o "$NAME.dylib" "$NAME.m"
echo "   ok $(stat -f%z "$NAME.dylib") bytes"

echo "== 2) 安全检查 =="
if nm -u "$NAME.dylib" | grep -E '_OBJC_CLASS_\$_(UIKB|UIKeyboard|SB)'; then echo "!! 残留私有硬符号"; exit 1; fi
echo "   clean"

echo "== 3) 设备签名 =="
ssh "$SSH_ROOT" "rm -f /var/tmp/$NAME.dylib"
scp -q "$NAME.dylib" "$SSH_HOST":/var/tmp/$NAME.dylib
ssh "$SSH_ROOT" "ldid -S /var/tmp/$NAME.dylib && stat -c %s /var/tmp/$NAME.dylib"
scp -q "$SSH_HOST":/var/tmp/$NAME.dylib "$NAME.signed.dylib"
codesign -dvvv "$NAME.signed.dylib" 2>&1 | grep CodeDirectory || true

echo "== 4) 打包 deb =="
VER="$VER" NAME="$NAME" PKG="$PKG" ARCH="$ARCH" python3 - <<'PY'
import io,os,tarfile,time,gzip
HERE=os.getcwd()
VER=os.environ["VER"]; NAME=os.environ["NAME"]; PKG=os.environ["PKG"]; ARCH=os.environ["ARCH"]
DYLIB=os.path.join(HERE,NAME+".signed.dylib"); PLIST=os.path.join(HERE,NAME+".plist")
KAYOKO=os.path.join(HERE,"vendor","Kayoko")
OUT=os.path.join(HERE,"%s_%s_%s.deb"%(NAME,VER,ARCH))
payload_size=os.path.getsize(DYLIB)
for root,dirs,files in os.walk(KAYOKO):
    dirs[:] = [d for d in dirs if not d.startswith(".")]
    payload_size += sum(os.path.getsize(os.path.join(root,f)) for f in files if not f.startswith("."))
CTRL="\n".join([
 "Package: %s"%PKG,"Name: %s"%NAME,"Version: %s"%VER,"Architecture: %s"%ARCH,
 "Description: iOS 16 系统键盘圆角、OLED、UnderDock 与 Kayoko 剪贴板整合。",
 " 直接修正最终键背景合成蒙版，覆盖字母、数字和特殊符号布局；",
 " 同时集成 byg.iosios.net.oledkeyboard、com.p2kdev.underdock 与 codes.aurora.kayoko 的已验证功能。",
 "Conflicts: com.liuf.jpyj, byg.iosios.net.oledkeyboard, com.p2kdev.underdock, codes.aurora.kayoko, com.restiveconch.actionbar, com.udevs.dockx",
 "Replaces: com.liuf.jpyj, com.xu.kbprobe, byg.iosios.net.oledkeyboard, com.p2kdev.underdock, codes.aurora.kayoko",
 "Provides: com.liuf.jpyj, byg.iosios.net.oledkeyboard, com.p2kdev.underdock, codes.aurora.kayoko",
 "Maintainer: g459416925","Author: xu","Section: Tweaks",
 "Depends: mobilesubstrate, preferenceloader, com.opa334.libsandy","Installed-Size: %d"%(payload_size//1024),
 "Tag: purpose::extension",""])
def tg(es):
    b=io.BytesIO()
    with tarfile.open(fileobj=b,mode="w") as tf:
        for n,d,m in es:
            ti=tarfile.TarInfo(n); ti.mode=m; ti.uid=ti.gid=0
            ti.uname="root"; ti.gname="wheel"; ti.mtime=int(time.time())
            if n.endswith("/"):
                ti.type=tarfile.DIRTYPE; ti.size=0; tf.addfile(ti)
            else:
                ti.size=len(d); tf.addfile(ti,io.BytesIO(d))
    return gzip.compress(b.getvalue(),9)
def arw(p,ms):
    def h(n,s): return ("%-16s%-12d%-6d%-6d%-8s%-10d`\n"%(n,int(time.time()),0,0,"100644",s)).encode()
    out=b"!<arch>\n"
    for n,d in ms:
        out+=h(n,len(d))+d
        if len(d)%2: out+=b"\n"
    open(p,"wb").write(out)
ID="Library/MobileSubstrate/DynamicLibraries"
data_entries=[("./%s/%s.dylib"%(ID,NAME),open(DYLIB,"rb").read(),0o755),
              ("./%s/%s.plist"%(ID,NAME),open(PLIST,"rb").read(),0o644)]
for root,dirs,files in os.walk(KAYOKO):
    dirs[:] = sorted(d for d in dirs if not d.startswith("."))
    files = sorted(f for f in files if not f.startswith("."))
    relative_root=os.path.relpath(root,KAYOKO)
    if relative_root != ".":
        data_entries.append(("./"+relative_root+"/",b"",0o755))
    for filename in files:
        source=os.path.join(root,filename)
        relative=os.path.relpath(source,KAYOKO)
        mode=os.stat(source).st_mode & 0o777
        data_entries.append(("./"+relative,open(source,"rb").read(),mode))
arw(OUT,[("debian-binary",b"2.0\n"),
 ("control.tar.gz",tg([("./control",CTRL.encode(),0o644)])),
 ("data.tar.gz",tg(data_entries))])
print("   deb: %s (%d bytes)"%(OUT,os.path.getsize(OUT)))
PY

if [ "${BUILD_ONLY:-0}" = "1" ]; then
  echo "   build-only: skip repo sync and device deployment"
  exit 0
fi

# 同步到仓库 debs/ 目录并重建 Packages 索引
cp -f "${NAME}_${VER}_${ARCH}.deb" "../../debs/"
python3 ../../tools/gen_repo.py

echo "== 5) 部署 =="
ssh "$SSH_ROOT" "rm -f /var/mobile/Documents/kbc_round.log /rootfs/private/var/mobile/Documents/kbc_round.log /var/tmp/${NAME}_${VER}_${ARCH}.deb"
# 如果安装了测试探针包或旧包，先清理
ssh "$SSH_ROOT" "dpkg -r com.xu.kbprobe 2>/dev/null || true"
ssh "$SSH_ROOT" "dpkg -r com.liuf.jpyj 2>/dev/null || true"
ssh "$SSH_ROOT" "dpkg -r byg.iosios.net.oledkeyboard com.p2kdev.underdock codes.aurora.kayoko 2>/dev/null || true"
scp -q "${NAME}_${VER}_${ARCH}.deb" "$SSH_HOST":/var/tmp/
ssh "$SSH_ROOT" "dpkg -i /var/tmp/${NAME}_${VER}_${ARCH}.deb 2>&1 | tail -5"

echo "== 6) sbreload =="
ssh "$SSH_ROOT" 'sbreload'
sleep 15

echo "== 7) 验证插件生效日志 =="
ssh "$SSH_ROOT" 'cat /var/mobile/Documents/kbc_round.log 2>/dev/null || cat /rootfs/private/var/mobile/Documents/kbc_round.log 2>/dev/null || true'
echo "DONE"
