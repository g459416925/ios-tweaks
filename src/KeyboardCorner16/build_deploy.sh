#!/bin/bash
# KeyboardCorner16 构建部署：编译 → 安全检查 → 设备签名 → 打包 deb → 部署 → sbreload → 读日志
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
NAME=KeyboardCorner16; PKG=com.xu.keyboardcorner16; ARCH=iphoneos-arm64e
VER=$(grep -o '#define KBC_VERSION @"[^"]*"' "$NAME.m" | sed 's/.*"\([^"]*\)".*/\1/')
[ -n "$VER" ] || { echo "!! 读不到 KBC_VERSION"; exit 1; }
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
if nm -u "$NAME.dylib" | grep -E '_OBJC_CLASS_\$_(UIKB|UIKeyboard|SB)'; then echo "!! 残留私有硬符号"; exit 1; fi
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
 "Description: 系统键盘全按键圆角增强修复版（完美支持字母与数字键盘按键圆角）。",
 " 修复原版键盘圆角在切换为数字键盘输入时按键未显示为圆角矩形的问题，",
 " 全面覆盖 UIKBRenderGeometry、10Key 九宫格及数字面板渲染路径。",
 "Conflicts: com.liuf.jpyj",
 "Replaces: com.liuf.jpyj, com.xu.kbprobe",
 "Provides: com.liuf.jpyj",
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

# 同步到仓库 debs/ 目录并重建 Packages 索引
cp -f "${NAME}_${VER}_${ARCH}.deb" "../../debs/"
python3 ../../tools/gen_repo.py

echo "== 5) 部署 =="
ssh iphone-root "rm -f /var/mobile/Documents/kbc_round.log /rootfs/private/var/mobile/Documents/kbc_round.log /var/tmp/${NAME}_${VER}_${ARCH}.deb"
# 如果安装了测试探针包或旧包，先清理
ssh iphone-root "dpkg -r com.xu.kbprobe 2>/dev/null || true"
ssh iphone-root "dpkg -r com.liuf.jpyj 2>/dev/null || true"
scp -q "${NAME}_${VER}_${ARCH}.deb" iphone:/var/tmp/
ssh iphone-root "dpkg -i /var/tmp/${NAME}_${VER}_${ARCH}.deb 2>&1 | tail -5"

echo "== 6) sbreload =="
ssh iphone-root 'sbreload'
sleep 15

echo "== 7) 验证插件生效日志 =="
ssh iphone-root 'cat /var/mobile/Documents/kbc_round.log 2>/dev/null || cat /rootfs/private/var/mobile/Documents/kbc_round.log 2>/dev/null || true'
echo "DONE"
