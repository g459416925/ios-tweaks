#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_deb_local.py —— 在 Mac 本地打包 LeafCrack（设备离线时用）

纯 Python 手写 Debian ar 归档，不依赖 dpkg-deb。
前置：dylib 由 ldid -S 签名（脚本自动做并校验体积增长）。

RootHide 特殊点：
  · 注入目录是 /usr/lib/TweakInject/（不是 /Library/MobileSubstrate/DynamicLibraries，
    后者在 RootHide 上只是个软链）
  · 每个 tweak 必须有 <name>.dylib.roothidepatch 软链指向
    /usr/lib/DynamicPatches/AutoPatches.dylib，否则不会注入
  · 签名必须在 Mac 上做，设备上跑 ldid -S 会破坏 Mach-O，
    表现为「注入成功但 constructor 不执行」

用法：
    python3 build_deb_local.py
产物：
    LeafCrack_<版本>_iphoneos-arm64e.deb
"""
import io, os, re, gzip, tarfile, time, subprocess, sys

HERE   = os.path.dirname(os.path.abspath(__file__))
PKG    = "LeafCrack"
PKGID  = "com.xu.leafcrack"
ARCH   = "iphoneos-arm64e"

INJECT = "usr/lib/TweakInject"
PATCH  = "/usr/lib/DynamicPatches/AutoPatches.dylib"


def version():
    src = open(os.path.join(HERE, PKG + ".m"), encoding="utf-8").read()
    m = re.search(r'#define\s+LC_VERSION\s+@?"([^"]+)"', src)
    if not m:
        sys.exit("读不到 LC_VERSION")
    return m.group(1)


def sign_dylib(path):
    before = os.path.getsize(path)
    subprocess.run(["ldid", "-S", path], check=True)
    after = os.path.getsize(path)
    if after <= before:
        sys.exit("签名未生效（%d -> %d），设备上会加载失败" % (before, after))
    return before, after


def add_bytes(tf, arcname, data, mode):
    ti = tarfile.TarInfo(arcname)
    ti.size = len(data)
    ti.mode = mode
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.mtime = int(time.time())
    tf.addfile(ti, io.BytesIO(data))


def add_symlink(tf, arcname, target):
    ti = tarfile.TarInfo(arcname)
    ti.type = tarfile.SYMTYPE
    ti.linkname = target
    ti.mode = 0o777
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.mtime = int(time.time())
    tf.addfile(ti)


def tar_gz(build):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        build(tf)
    return gzip.compress(buf.getvalue(), 9)


def ar_write(path, members):
    def hdr(name, size):
        return ("%-16s%-12d%-6d%-6d%-8s%-10d`\n" % (
            name, int(time.time()), 0, 0, "100644", size)).encode("ascii")

    out = b"!<arch>\n"
    for name, data in members:
        out += hdr(name, len(data)) + data
        if len(data) % 2:
            out += b"\n"
    with open(path, "wb") as f:
        f.write(out)


POSTINST = """#!/bin/sh
set -e
D=/%(inject)s

# RootHide 注入补丁软链（deb 里已带一个，这里兜底重建）
if [ -f "%(patch)s" ]; then
    ln -sf "%(patch)s" "$D/%(pkg)s.dylib.roothidepatch" 2>/dev/null || true
fi

chown root:wheel "$D/%(pkg)s.dylib" "$D/%(pkg)s.plist" 2>/dev/null || true
chmod 755 "$D/%(pkg)s.dylib" 2>/dev/null || true
chmod 644 "$D/%(pkg)s.plist" 2>/dev/null || true

# 给已存在的 AppGroup 写入一次会员状态，首次启动即生效
for G in /var/mobile/Containers/Shared/AppGroup/*/Library/Preferences/group.com.kitslabs.production.Leaf.plist; do
    [ -f "$G" ] || continue
    plutil -key LEAF_ENC_IS_PREMIUM_ACTIVATED -value 1 -type int "$G" >/dev/null 2>&1 || true
    plutil -key TOTAL_POINTS -value 2147483647 -type int "$G" >/dev/null 2>&1 || true
done

killall -9 Leaf 2>/dev/null || true
exit 0
"""


def main():
    ver    = version()
    dylib  = os.path.join(HERE, PKG + ".dylib")
    plist  = os.path.join(HERE, PKG + ".plist")
    ctrl_t = os.path.join(HERE, "control")
    for p in (dylib, plist, ctrl_t):
        if not os.path.exists(p):
            sys.exit("缺文件: %s" % p)

    before, after = sign_dylib(dylib)
    print("签名: %d -> %d (+%d B)" % (before, after, after - before))

    control = open(ctrl_t, encoding="utf-8").read().replace("__VERSION__", ver).rstrip() + "\n"
    postinst = POSTINST % {"inject": INJECT, "patch": PATCH, "pkg": PKG}

    dy_bytes = open(dylib, "rb").read()
    pl_bytes = open(plist, "rb").read()

    def build_data(tf):
        add_bytes(tf, "./%s/%s.dylib" % (INJECT, PKG), dy_bytes, 0o755)
        add_bytes(tf, "./%s/%s.plist" % (INJECT, PKG), pl_bytes, 0o644)
        add_symlink(tf, "./%s/%s.dylib.roothidepatch" % (INJECT, PKG), PATCH)

    def build_ctrl(tf):
        add_bytes(tf, "./control", control.encode("utf-8"), 0o644)
        add_bytes(tf, "./postinst", postinst.encode("utf-8"), 0o755)

    data = tar_gz(build_data)
    ctrl = tar_gz(build_ctrl)

    out = os.path.join(HERE, "%s_%s_%s.deb" % (PKG, ver, ARCH))
    ar_write(out, [
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", ctrl),
        ("data.tar.gz", data),
    ])
    print("生成: %s (%d 字节)" % (os.path.basename(out), os.path.getsize(out)))


if __name__ == "__main__":
    main()
