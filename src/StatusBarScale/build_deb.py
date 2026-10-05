#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_deb.py —— 打包 StatusBarScale（插件本体 + 设置面板）为 RootHide 可装的 .deb

用法: python3 build_deb.py
产物: StatusBarScale_<版本>_iphoneos-arm64e.deb（版本号自动取自 StatusBarScale.m）

⚠️ 前置：设置面板二进制必须已编译并签名
   （先跑 ../StatusBarScalePrefs/build_prefs.sh，产出 StatusBarScalePrefs.signed）
"""
import io, os, re, tarfile, time, gzip, plistlib

HERE  = os.path.dirname(os.path.abspath(__file__))      # .../src/StatusBarScale
SRC   = os.path.dirname(HERE)                           # .../src
PREFS = os.path.join(SRC, "StatusBarScalePrefs")

PKG          = "StatusBarScale"
DEBNAME      = "com.xu.statusbarscale"
PREFS_BUNDLE = "StatusBarScalePrefs"                    # bundle 目录名（不含 .bundle）
ARCH         = "iphoneos-arm64e"

DYLIB    = os.path.join(HERE, PKG + ".signed.dylib")
PLIST    = os.path.join(HERE, PKG + ".plist")
PREFS_BIN = os.path.join(PREFS, PREFS_BUNDLE)           # 已签名的面板可执行文件
INFO_IN   = os.path.join(PREFS, "Info.plist")           # XML 源
ENTRY_IN  = os.path.join(PREFS, "entry.plist")          # XML 源
ROOT_IN   = os.path.join(PREFS, "Root.plist")           # XML 源（面板条目定义）
ICONS     = [("icon.png", 58), ("icon@2x.png", 116), ("icon@3x.png", 174)]


def _ver_from_source():
    """版本号单一来源：从 .m 里读 #define SBS_VERSION。"""
    src = os.path.join(HERE, PKG + ".m")
    m = re.search(r'#define\s+SBS_VERSION\s+@"([^"]+)"',
                  open(src, encoding="utf-8").read())
    return m.group(1) if m else "0.0.0"


VERSION = _ver_from_source()
OUT = os.path.join(HERE, "%s_%s_%s.deb" % (PKG, VERSION, ARCH))

DYNLIB_DIR  = "Library/MobileSubstrate/DynamicLibraries"
BUNDLE_DIR  = "Library/PreferenceBundles/%s.bundle" % PREFS_BUNDLE
ENTRY_DIR   = "Library/PreferenceLoader/Preferences"

DESC = ("状态栏图标缩放对齐 + 辅助图标条（灵动岛机型），含可视化设置面板。\n"
        " 需求：iPhone 14 Pro Max 灵动岛右侧（信号/WiFi/电池）图标比左侧时间略大、\n"
        " 重心偏高。本插件 hook _UIStatusBarForegroundView -layoutSubviews，每次布局后\n"
        " 对灵动岛右侧图标施加 绕中心缩放(默认0.92)+下移(默认1.5pt)，与时间高度/重心对齐。\n"
        " v1.7.0 新增时间右侧、灵动岛左侧图标（闹钟/定位/录屏等，无法按标识枚举）的\n"
        " 运行时按位置发现 + 单独缩放（默认 0.6 倍）。\n"
        " v1.8.0 新增「辅助图标条」：把系统未在灵动岛左右显示的图标（闹钟/专注/旋转锁/\n"
        " 定位/VPN/蓝牙/飞行模式）收拢到灵动岛正下方一行居中显示，默认缩至 0.4 倍\n"
        " （基准 17pt → 6.8pt），主屏与 App 内跟随时间显示，锁屏隐藏。\n"
        " ⭐ v1.9.0 新增「设置」App 可视化面板：\n"
        " · 分组展示全部可调参数，滑块拖动实时预览、松手即保存；\n"
        " · 开关类：总开关 / 时间旁缩放 / 辅助条 / 辅助条逐个图标收纳 / 日志级别；\n"
        " · 数值类：右侧缩放·垂直微调 / 时间旁缩放·微调 / 辅助条大小·基准尺寸·间距；\n"
        " · 操作类：恢复默认值、重启桌面；\n"
        " · 改动即时生效（Darwin 通知热重载，无需 respring）。\n"
        " 配置域 com.xu.statusbarscale（/var/mobile/Library/Preferences/）。\n"
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
    "Depends: mobilesubstrate, preferenceloader",
    "Installed-Size: %d" % max(1, os.path.getsize(DYLIB) // 1024),
    "Tag: purpose::extension",
    "",
])


def _binary_plist(src_path, extra=None):
    """读 XML plist → 覆盖版本号 → 输出二进制 plist 字节"""
    with open(src_path, "rb") as f:
        d = plistlib.load(f)
    if extra:
        d.update(extra)
    return plistlib.dumps(d, fmt=plistlib.FMT_BINARY)


# ⚠️ RootHide 下「设置」App 的 CFPreferences 落在影子目录 /var/mobile/...，
#    而插件读的是真实文件 /rootfs/private/var/mobile/...，两边不是同一份
#    ⇒ 开关类 cell 也必须走面板自己的读写函数，否则改设置对插件完全无效。
#    这里在打包时统一给开关/只读文本条目注入 get/set（并去掉 CFPreferences 的 defaults 键）。
HOOKED_CELLS = {"PSSwitchCell", "PSTitleValueCell", "PSEditTextCell"}


def _root_plist_bytes(src_path):
    with open(src_path, "rb") as f:
        root = plistlib.load(f)
    for item in root.get("items", []):
        if not isinstance(item, dict):
            continue
        if item.get("cell") in HOOKED_CELLS and item.get("key"):
            item["get"] = "sbsReadPref:"
            item["set"] = "sbsWritePref:specifier:"
            item.pop("defaults", None)
        # 滑块由自定义 SBSSliderCell 自行读写，不需要（也不该有）get/set
        if item.get("cellClass") == "SBSSliderCell":
            item.pop("defaults", None)
    return plistlib.dumps(root, fmt=plistlib.FMT_BINARY)


def add_file(tf, arcname, data, mode):
    ti = tarfile.TarInfo(arcname)
    ti.size = len(data)
    ti.mode = mode
    ti.uid = ti.gid = 0
    ti.uname = "root"
    ti.gname = "wheel"
    ti.mtime = int(time.time())
    tf.addfile(ti, io.BytesIO(data))


def add_symlink(tf, arcname, target):
    ti = tarfile.TarInfo(arcname)
    ti.type = tarfile.SYMTYPE
    ti.linkname = target
    ti.mode = 0o777
    ti.uid = ti.gid = 0
    ti.uname = "root"
    ti.gname = "wheel"
    ti.mtime = int(time.time())
    tf.addfile(ti)


def add_dir(tf, arcname):
    """⚠️ dpkg 不会为缺失的中间目录自动 mkdir —— 新建目录必须在 tar 里显式列出，
       否则报 `unable to create '.../x.dpkg-new': No such file or directory`。"""
    ti = tarfile.TarInfo(arcname)
    ti.type = tarfile.DIRTYPE
    ti.mode = 0o755
    ti.uid = ti.gid = 0
    ti.uname = "root"
    ti.gname = "wheel"
    ti.mtime = int(time.time())
    tf.addfile(ti)


def tar_gz(files, links=(), dirs=()):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        for d in dirs:
            add_dir(tf, d)
        for arcname, data, mode in files:
            add_file(tf, arcname, data, mode)
        for arcname, target in links:
            add_symlink(tf, arcname, target)
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
    need = [DYLIB, PLIST, PREFS_BIN, INFO_IN, ENTRY_IN, ROOT_IN]
    for p in need:
        if not os.path.exists(p):
            raise SystemExit("缺文件: %s" % p)
    for n, _ in ICONS:
        if not os.path.exists(os.path.join(PREFS, n)):
            raise SystemExit("缺图标: %s（先跑 make_icon.py）" % n)

    ver_extra = {"CFBundleShortVersionString": VERSION, "CFBundleVersion": VERSION}

    files = [
        # ── 插件本体 ──
        ("./%s/%s.dylib" % (DYNLIB_DIR, PKG), open(DYLIB, "rb").read(), 0o755),
        ("./%s/%s.plist" % (DYNLIB_DIR, PKG), open(PLIST, "rb").read(), 0o644),
        # ── 设置面板 bundle ──
        ("./%s/Info.plist" % BUNDLE_DIR, _binary_plist(INFO_IN, ver_extra), 0o644),
        ("./%s/%s" % (BUNDLE_DIR, PREFS_BUNDLE), open(PREFS_BIN, "rb").read(), 0o755),
        # ⚠️ Root.plist 是面板条目的定义来源（loadSpecifiersFromPlistName:@"Root"），
        #    漏了它 → 设置里只显示一个空列表，不报任何错。
        ("./%s/Root.plist" % BUNDLE_DIR, _root_plist_bytes(ROOT_IN), 0o644),
        # ── 设置 App 入口 ──
        ("./%s/%s.plist" % (ENTRY_DIR, PKG), _binary_plist(ENTRY_IN), 0o644),
    ]
    for n, _ in ICONS:
        files.append(("./%s/%s" % (BUNDLE_DIR, n),
                      open(os.path.join(PREFS, n), "rb").read(), 0o644))

    # RootHide 约定：bundle 内的 .jbroot 是指向 / 的符号链接
    links = [("./%s/.jbroot" % BUNDLE_DIR, "/")]

    # ⚠️ 新建的 bundle 目录必须显式列进 tar（dpkg 不自动 mkdir，见 add_dir 注释）
    dirs = ["./%s/" % BUNDLE_DIR]

    data = tar_gz(files, links, dirs)
    ctrl = tar_gz([("./control", CONTROL.encode("utf-8"), 0o644)])

    ar_write(OUT, [
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", ctrl),
        ("data.tar.gz", data),
    ])
    print("生成: %s  (%d 字节)" % (OUT, os.path.getsize(OUT)))
    print("  arch=%s  pkg=%s  ver=%s" % (ARCH, DEBNAME, VERSION))
    print("   dylib=%d B (已签名)" % os.path.getsize(DYLIB))
    print("   prefs=%d B (已签名)  bundle=%s" % (os.path.getsize(PREFS_BIN), BUNDLE_DIR))
    print("   bundle 内容: %s" % ", ".join(
        sorted(os.path.basename(a) for a, _, _ in files if BUNDLE_DIR in a)))


if __name__ == "__main__":
    main()
