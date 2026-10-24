#!/bin/bash
source "/Users/xu/WorkBuddy/IOS设备处理/device-tools/env.sh"  # 统一设备入口：USB -> LAN -> Tailscale
# KBKeyProbe3 构建部署：编译 → 设备签名 → 打包 deb → 部署
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
NAME=KBKeyProbe3; PKG=com.xu.kbprobe3; ARCH=iphoneos-arm64e; VER=0.1.5
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

echo "== 1) 编译 =="
clang -arch arm64e -miphoneos-version-min=14.0 -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -O2 -Wall -Wno-deprecated-declarations \
  -undefined dynamic_lookup -framework Foundation -framework UIKit -framework QuartzCore \
  -install_name "/Library/MobileSubstrate/DynamicLibraries/$NAME.dylib" \
  -o "$NAME.dylib" "$NAME.m"
echo "   ok $(stat -f%z "$NAME.dylib") bytes"

echo "== 2) 设备签名 =="
ssh iphone-root "rm -f /var/tmp/$NAME.dylib"
scp -q "$NAME.dylib" iphone:/var/tmp/$NAME.dylib
ssh iphone-root "ldid -S /var/tmp/$NAME.dylib && stat -c %s /var/tmp/$NAME.dylib"
scp -q iphone:/var/tmp/$NAME.dylib "$NAME.signed.dylib"

echo "== 3) 打包 deb =="
VER="$VER" NAME="$NAME" PKG="$PKG" ARCH="$ARCH" python3 - <<'PY'
import io,os,tarfile,time,gzip
HERE=os.getcwd()
VER=os.environ["VER"]; NAME=os.environ["NAME"]; PKG=os.environ["PKG"]; ARCH=os.environ["ARCH"]
DYLIB=os.path.join(HERE,NAME+".signed.dylib"); PLIST=os.path.join(HERE,NAME+".plist")
OUT=os.path.join(HERE,"%s_%s_%s.deb"%(NAME,VER,ARCH))
CTRL="\n".join([
 "Package: %s"%PKG,"Name: %s"%NAME,"Version: %s"%VER,"Architecture: %s"%ARCH,
 "Description: KBKeyProbe3 — 键盘键视图 CALayer 圆角专项实验（临时测试包）。",
 "Maintainer: g459416925","Author: xu","Section: Tweaks",
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

echo "== 4) 部署 =="
scp -q "${NAME}_${VER}_${ARCH}.deb" iphone:/var/tmp/
ssh iphone-root "dpkg -i /var/tmp/${NAME}_${VER}_${ARCH}.deb 2>&1 | tail -3"
echo DONE
