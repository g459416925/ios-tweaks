#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_deb.py —— 打包 StatusBarScale（仅插件本体）为 RootHide 可装的 .deb

用法: python3 build_deb.py
产物: StatusBarScale_<版本>_iphoneos-arm64e.deb（版本号自动取自 StatusBarScale.m）

⚠️ 前置：StatusBarScale.signed.dylib 必须已编译并签名
   （先跑 build_deploy.sh 的前 4 步，或手动 clang + ldid -S）
"""
import io, os, re, tarfile, time, gzip

HERE = os.path.dirname(os.path.abspath(__file__))      # .../src/StatusBarScale

PKG     = "StatusBarScale"
DEBNAME = "com.xu.statusbarscale"
ARCH    = "iphoneos-arm64e"

DYLIB = os.path.join(HERE, PKG + ".signed.dylib")
PLIST = os.path.join(HERE, PKG + ".plist")


def _ver_from_source():
    """版本号单一来源：从 .m 里读 #define SBS_VERSION。"""
    src = os.path.join(HERE, PKG + ".m")
    m = re.search(r'#define\s+SBS_VERSION\s+@"([^"]+)"',
                  open(src, encoding="utf-8").read())
    return m.group(1) if m else "0.0.0"


VERSION = _ver_from_source()
OUT = os.path.join(HERE, "%s_%s_%s.deb" % (PKG, VERSION, ARCH))

DYNLIB_DIR = "Library/MobileSubstrate/DynamicLibraries"

DESC = ("状态栏图标缩放 + 资源库背景透明。\n"
        " · 状态栏缩放：hook _UIStatusBarForegroundView -layoutSubviews，每次布局后\n"
        "   对灵动岛右侧（minX >= 阈值）的图标施加 绕中心缩放 + 垂直微调，与时间对齐；\n"
        "   时间右侧、灵动岛左侧的图标（闹钟/定位/录屏等，无法按标识枚举）按 fg 坐标系\n"
        "   frame 区间运行时发现，单独缩放。\n"
        " · 资源库背景透明：App 资源库分类卡片的背景板清成透明，只留图标与标签。\n"
        " 参数已硬编码进源码，不含设置面板/配置文件读取。\n"
        " 仅注入 SpringBoard（Filter.Bundles = com.apple.springboard）。\n"
        " 适用 iOS 16.x / RootHide (arm64e)。")

CONTROL = "\n".join([
    "Package: %s" % DEBNAME,
    "Name: StatusBarScale",
    "Version: %s" % VERSION,
    "Architecture: %s" % ARCH,
    "Description: %s" % DESC,
    "Maintainer: g459416925",
    "Author: g459416925 (iOS 16.5.1 / RootHide)",
    "Section: Tweaks",
    "Depends: mobilesubstrate",
    "Installed-Size: %d" % max(1, os.path.getsize(DYLIB) // 1024),
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


def tar_gz(files):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        for arcname, data, mode in files:
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

    files = [
        ("./%s/%s.dylib" % (DYNLIB_DIR, PKG), open(DYLIB, "rb").read(), 0o755),
        ("./%s/%s.plist" % (DYNLIB_DIR, PKG), open(PLIST, "rb").read(), 0o644),
    ]

    data = tar_gz(files)
    ctrl = tar_gz([("./control", CONTROL.encode("utf-8"), 0o644)])

    ar_write(OUT, [
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", ctrl),
        ("data.tar.gz", data),
    ])
    print("生成: %s  (%d 字节)" % (OUT, os.path.getsize(OUT)))
    print("  arch=%s  pkg=%s  ver=%s" % (ARCH, DEBNAME, VERSION))
    print("   dylib=%d B (已签名)" % os.path.getsize(DYLIB))


if __name__ == "__main__":
    main()
