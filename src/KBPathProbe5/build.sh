#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

NAME=KBPathProbe5
PKG=com.xu.kbpathprobe5
ARCH=iphoneos-arm64e
VER=0.2.0
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

clang -arch arm64e -miphoneos-version-min=14.0 -isysroot "$SDK" \
  -dynamiclib -fobjc-arc -O2 -Wall -Wextra \
  -undefined dynamic_lookup -framework Foundation -framework CoreGraphics \
  -install_name "/Library/MobileSubstrate/DynamicLibraries/$NAME.dylib" \
  -o "$NAME.dylib" "$NAME.m"

ssh iphone-root "rm -f /var/tmp/$NAME.dylib"
scp -q "$NAME.dylib" iphone:/var/tmp/$NAME.dylib
ssh iphone-root "ldid -S /var/tmp/$NAME.dylib"
scp -q iphone:/var/tmp/$NAME.dylib "$NAME.signed.dylib"

VER="$VER" NAME="$NAME" PKG="$PKG" ARCH="$ARCH" python3 - <<'PY'
import gzip, io, os, tarfile, time

name = os.environ["NAME"]
version = os.environ["VER"]
package = os.environ["PKG"]
arch = os.environ["ARCH"]
base = "Library/MobileSubstrate/DynamicLibraries"
dylib = open(name + ".signed.dylib", "rb").read()
plist = open(name + ".plist", "rb").read()
control = "\n".join([
    "Package: " + package,
    "Name: " + name,
    "Version: " + version,
    "Architecture: " + arch,
    "Description: Read-only rounded-path call-site probe for KeyboardCorner16.",
    "Maintainer: g459416925",
    "Author: xu",
    "Section: Tweaks",
    "Depends: mobilesubstrate",
    "Tag: purpose::extension",
    "",
]).encode()

def tar_gz(entries):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w") as tf:
        for path, data, mode in entries:
            ti = tarfile.TarInfo(path)
            ti.size = len(data)
            ti.mode = mode
            ti.uid = ti.gid = 0
            ti.uname = "root"
            ti.gname = "wheel"
            ti.mtime = int(time.time())
            tf.addfile(ti, io.BytesIO(data))
    return gzip.compress(out.getvalue(), 9)

def ar_member(member_name, data):
    header = ("%-16s%-12d%-6d%-6d%-8s%-10d`\n" %
              (member_name, int(time.time()), 0, 0, "100644", len(data))).encode()
    return header + data + (b"\n" if len(data) % 2 else b"")

deb = b"!<arch>\n"
deb += ar_member("debian-binary", b"2.0\n")
deb += ar_member("control.tar.gz", tar_gz([("./control", control, 0o644)]))
deb += ar_member("data.tar.gz", tar_gz([
    (f"./{base}/{name}.dylib", dylib, 0o755),
    (f"./{base}/{name}.plist", plist, 0o644),
]))
output = f"{name}_{version}_{arch}.deb"
open(output, "wb").write(deb)
print(os.path.abspath(output))
PY
