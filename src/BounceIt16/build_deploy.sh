#!/bin/bash
# BounceIt16 构建部署：编译 → 安全检查 → 设备签名 → 打包 deb → 安装 → respring → 读日志
# 用法: ./build_deploy.sh [版本号]     默认 1.0.1
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
NAME=BounceIt16; PKG=com.xu.bounceit16; ARCH=iphoneos-arm64e
# 版本号唯一来源：源码里的 #define BIT16_VERSION（不手填）
VER=$(grep -o '#define BIT16_VERSION @"[^"]*"' "$NAME.m" | sed 's/.*"\([^"]*\)".*/\1/')
[ -n "$VER" ] || { echo "!! 读不到 BIT16_VERSION"; exit 1; }
echo "   版本: $VER"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

echo "== 1) 编译 =="
clang -arch arm64e -miphoneos-version-min=14.0 -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -O2 -Wall -Wno-deprecated-declarations \
  -undefined dynamic_lookup -framework Foundation \
  -install_name "/Library/MobileSubstrate/DynamicLibraries/$NAME.dylib" \
  -o "$NAME.dylib" "$NAME.m"
echo "   ok $(stat -f%z "$NAME.dylib") bytes"

echo "== 2) 安全检查 =="
if nm -u "$NAME.dylib" | grep -E '_OBJC_CLASS_\$_(SB|ST)'; then echo "!! 私有硬符号"; exit 1; fi
if strings "$NAME.dylib" | grep -E '/System/Library|TweakInject'; then echo "!! 系统路径字面量"; exit 1; fi
echo "   clean"

echo "== 3) 设备签名 =="
ssh iphone-root "rm -f /var/tmp/$NAME.dylib"
scp -q "$NAME.dylib" iphone:/var/tmp/$NAME.dylib
ssh iphone-root "ldid -S /var/tmp/$NAME.dylib && stat -c %s /var/tmp/$NAME.dylib"
scp -q iphone:/var/tmp/$NAME.dylib "$NAME.signed.dylib"
codesign -dvvv "$NAME.signed.dylib" 2>&1 | grep CodeDirectory || true

echo "== 4) 打包 deb =="
VER="$VER" NAME="$NAME" PKG="$PKG" ARCH="$ARCH" python3 - <<'PY'
import io,os,tarfile,time,gzip
HERE=os.getcwd()
VER=os.environ["VER"]; NAME=os.environ["NAME"]; PKG=os.environ["PKG"]; ARCH=os.environ["ARCH"]
DYLIB=os.path.join(HERE,NAME+".signed.dylib"); PLIST=os.path.join(HERE,NAME+".plist")
OUT=os.path.join(HERE,"%s_%s_%s.deb"%(NAME,VER,ARCH))
CTRL="\n".join([
 "Package: %s"%PKG,"Name: %s"%NAME,"Version: %s"%VER,"Architecture: %s"%ARCH,
 "Description: SpringBoard 果冻弹性动画（BounceIt 自研替代版）。",
 " 劫持 SBFFluidBehaviorSettings.setDampingRatio: 与 SBFAnimationSettings 的",
 " damping/stiffness/mass/epsilon，让系统动画带弹簧回弹（阻尼比约 0.23）。",
 "Maintainer: g459416925","Author: g459416925","Section: Tweaks",
 "Depends: mobilesubstrate","Installed-Size: %d"%(os.path.getsize(DYLIB)//1024),
 "Tag: purpose::extension",""])
def tg(es):
    b=io.BytesIO()
    with tarfile.open(fileobj=b,mode="w") as tf:
        for n,d,m in es:
            ti=tarfile.TarInfo(n); ti.size=len(d); ti.mode=m; ti.uid=ti.gid=0
            ti.uname="root"; ti.gname="wheel"; ti.mtime=int(time.time()); tf.addfile(ti,io.BytesIO(d))
    return gzip.compress(b.getvalue(),9)
def arw(p,ms):
    def h(n,s): return ("%-16s%-12d%-6d%-6d%-8s%-10d`\n"%(n,int(time.time()),0,0,"100644",s)).encode()
    out=b"!<arch>\n"
    for n,d in ms:
        out+=h(n,len(d))+d
        if len(d)%2: out+=b"\n"
    open(p,"wb").write(out)
ID="Library/MobileSubstrate/DynamicLibraries"
arw(OUT,[("debian-binary",b"2.0\n"),
 ("control.tar.gz",tg([("./control",CTRL.encode(),0o644)])),
 ("data.tar.gz",tg([("./%s/%s.dylib"%(ID,NAME),open(DYLIB,"rb").read(),0o755),
                    ("./%s/%s.plist"%(ID,NAME),open(PLIST,"rb").read(),0o644)]))])
print("   deb: %s (%d bytes)"%(OUT,os.path.getsize(OUT)))
PY

echo "== 5) 部署 =="
ssh iphone-root "rm -f /rootfs/private/var/mobile/Documents/bounce16.log /var/tmp/${NAME}_${VER}_${ARCH}.deb"
scp -q "${NAME}_${VER}_${ARCH}.deb" iphone:/var/tmp/
ssh iphone-root "dpkg -i /var/tmp/${NAME}_${VER}_${ARCH}.deb 2>&1 | tail -3"

echo "== 6) respring =="
ssh iphone-root 'sbreload'
sleep 32

echo "== 7) 插件日志 =="
ssh iphone-root 'cat /rootfs/private/var/mobile/Documents/bounce16.log 2>&1'
echo "DONE"
