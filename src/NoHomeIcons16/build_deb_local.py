#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_deb_local.py —— 在 Mac 本地打包 NoHomeIcons16（设备离线时用）

与 build_deploy.sh 的区别：不依赖设备上的 dpkg-deb，纯 Python 手写 Debian ar 归档。
前置：dylib 已由 ldid -S 签名（脚本会自动做并校验体积增长）。

用法：
    python3 build_deb_local.py
产物：
    NoHomeIcons16_<版本>_iphoneos-arm64e.deb
"""
import io, os, re, gzip, tarfile, time, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = "NoHomeIcons16"
PKGID = "com.xu.nohomeicons"
ARCH = "iphoneos-arm64e"
DYN = "Library/MobileSubstrate/DynamicLibraries"


def version():
    src = open(os.path.join(HERE, PKG + ".m"), encoding="utf-8").read()
    m = re.search(r'#define\s+NHI_VERSION\s+@"([^"]+)"', src)
    if not m:
        sys.exit("读不到 NHI_VERSION")
    return m.group(1)


def sign_dylib(path):
    before = os.path.getsize(path)
    subprocess.run(["ldid", "-S", path], check=True)
    after = os.path.getsize(path)
    if after <= before:
        sys.exit("签名未生效（%d -> %d）" % (before, after))
    return before, after


def add_file(tf, arcname, data, mode):
    ti = tarfile.TarInfo(arcname)
    ti.size = len(data)
    ti.mode = mode
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.mtime = int(time.time())
    tf.addfile(ti, io.BytesIO(data))


def tar_gz(files):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        for arcname, data, mode in files:
            add_file(tf, arcname, data, mode)
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


def main():
    ver = version()
    dylib = os.path.join(HERE, PKG + ".dylib")
    plist = os.path.join(HERE, PKG + ".plist")
    ctrl_tpl = os.path.join(HERE, "control")
    for p in (dylib, plist, ctrl_tpl):
        if not os.path.exists(p):
            sys.exit("缺文件: %s" % p)

    before, after = sign_dylib(dylib)
    print("签名: %d -> %d (+%d B)" % (before, after, after - before))

    control = open(ctrl_tpl, encoding="utf-8").read().replace("__VERSION__", ver)
    if not control.endswith("\n"):
        control += "\n"

    files = [
        ("./%s/%s.dylib" % (DYN, PKG), open(dylib, "rb").read(), 0o755),
        ("./%s/%s.plist" % (DYN, PKG), open(plist, "rb").read(), 0o644),
    ]
    data = tar_gz(files)
    ctrl = tar_gz([("./control", control.encode("utf-8"), 0o644)])

    out = os.path.join(HERE, "%s_%s_%s.deb" % (PKG, ver, ARCH))
    ar_write(out, [
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", ctrl),
        ("data.tar.gz", data),
    ])
    print("生成: %s (%d 字节)" % (os.path.basename(out), os.path.getsize(out)))


if __name__ == "__main__":
    main()
