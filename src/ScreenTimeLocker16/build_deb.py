#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_deb.py —— 把已签名的 ScreenTimeLocker16.dylib 打成 RootHide 能装的 .deb
用法: python3 build_deb.py
产物: ScreenTimeLocker16_<版本>_iphoneos-arm64e.deb（版本号自动取自 .m 源码）
"""
import io, os, tarfile, time, gzip

HERE = os.path.dirname(os.path.abspath(__file__))
PKG      = "ScreenTimeLocker16"
DEBNAME  = "com.xu.screentimelocker16"


def _ver_from_source():
    """版本号单一来源：从 .m 里读 #define STL_VERSION，避免打错版本。"""
    import re
    src = os.path.join(HERE, PKG + ".m")
    m = re.search(r'#define\s+STL_VERSION\s+@"([^"]+)"', open(src, encoding="utf-8").read())
    return m.group(1) if m else "0.0.0"


VERSION  = _ver_from_source()
ARCH     = "iphoneos-arm64e"
DYLIB    = os.path.join(HERE, PKG + ".signed.dylib")
PLIST    = os.path.join(HERE, PKG + ".plist")
OUT      = os.path.join(HERE, "%s_%s_%s.deb" % (PKG, VERSION, ARCH))

INSTALL_DIR = "Library/MobileSubstrate/DynamicLibraries"

DESC = ("把「屏幕使用时间」的 App 限额变成一把真正的锁。\n"
        " 完整还原原版 DisableOneMoreMinute 的四层实现：\n"
        " ① 数据层 — 禁止「再使用一分钟」；\n"
        " ② 设置页 — 允许设定 0 小时 0 分钟的限额；\n"
        " ③ 拦截页 — 认证优先走 Face ID，用不了时回落屏幕使用时间密码；\n"
        " ④ 菜单弹窗 — 保持原样，不注入任何额外选项。\n"
        " 不隐藏任何原生按钮（「请求更多使用时间」照常保留）。\n"
        " 适用 iOS 16.x / RootHide (arm64e)，宿主进程 SpringBoard。")

CONTROL = "\n".join([
    "Package: %s" % DEBNAME,
    "Name: ScreenTimeLocker16",
    "Version: %s" % VERSION,
    "Architecture: %s" % ARCH,
    "Description: %s" % DESC,
    "Maintainer: g459416925",
    "Author: g459416925 (iOS 16.5.1 / RootHide 重写版)",
    "Section: Tweaks",
    "Depends: mobilesubstrate",
    "Installed-Size: %d" % (os.path.getsize(DYLIB) // 1024),
    "Tag: purpose::extension",
    "",
])


def add_file(tf, arcname, data, mode):
    ti = tarfile.TarInfo(arcname)
    ti.size = len(data)
    ti.mode = mode
    ti.uid = ti.gid = 0
    ti.uname = "root"
    ti.gname = "wheel"
    ti.mtime = int(time.time())
    tf.addfile(ti, io.BytesIO(data))


def tar_gz(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        for arcname, data, mode in entries:
            add_file(tf, arcname, data, mode)
    return gzip.compress(buf.getvalue(), 9)


def ar_write(path, members):
    """members: [(name, bytes)] —— 手写 Debian ar 归档"""
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
    for p in (DYLIB, PLIST):
        if not os.path.exists(p):
            raise SystemExit("缺文件: %s" % p)

    data = tar_gz([
        ("./%s/%s.dylib" % (INSTALL_DIR, PKG), open(DYLIB, "rb").read(), 0o755),
        ("./%s/%s.plist" % (INSTALL_DIR, PKG), open(PLIST, "rb").read(), 0o644),
    ])
    ctrl = tar_gz([
        ("./control", CONTROL.encode("utf-8"), 0o644),
    ])

    ar_write(OUT, [
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", ctrl),
        ("data.tar.gz", data),
    ])
    print("生成: %s  (%d 字节)" % (OUT, os.path.getsize(OUT)))
    print("  arch=%s  pkg=%s  ver=%s" % (ARCH, DEBNAME, VERSION))
    print("  dylib=%d B (已签名)  plist=%d B" % (
        os.path.getsize(DYLIB), os.path.getsize(PLIST)))


if __name__ == "__main__":
    main()
