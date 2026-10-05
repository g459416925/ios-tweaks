#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_deb.py —— 把已签名的 StatusBarScale.signed.dylib 打成 RootHide 能装的 .deb
用法: python3 build_deb.py
产物: StatusBarScale_<版本>_iphoneos-arm64e.deb（版本号自动取自 .m 源码）
"""
import io, os, re, tarfile, time, gzip

HERE = os.path.dirname(os.path.abspath(__file__))
PKG      = "StatusBarScale"
DEBNAME  = "com.xu.statusbarscale"


def _ver_from_source():
    """版本号单一来源：从 .m 里读 #define SBS_VERSION，避免打错版本。"""
    src = os.path.join(HERE, PKG + ".m")
    m = re.search(r'#define\s+SBS_VERSION\s+@"([^"]+)"', open(src, encoding="utf-8").read())
    return m.group(1) if m else "0.0.0"


VERSION  = _ver_from_source()
ARCH     = "iphoneos-arm64e"
DYLIB    = os.path.join(HERE, PKG + ".signed.dylib")
PLIST    = os.path.join(HERE, PKG + ".plist")
OUT      = os.path.join(HERE, "%s_%s_%s.deb" % (PKG, VERSION, ARCH))

INSTALL_DIR = "Library/MobileSubstrate/DynamicLibraries"

DESC = ("状态栏图标缩放对齐（灵动岛机型）：右侧 信号/WiFi/电池 图标比左侧时间\n"
        " 略大且重心偏高（实测 14 Pro Max iOS 16.5.1：图标高 13-14px vs 时间 12px，\n"
        " 重心偏高 1.66px），本插件 hook _UIStatusBarForegroundView -layoutSubviews，\n"
        " 每次布局后对灵动岛右侧图标施加 绕中心缩放(默认0.92)+下移(默认1.5pt)，\n"
        " 与时间高度/重心对齐。\n"
        " v1.7.0 新增：时间右侧、灵动岛左侧的图标（闹钟/定位/录屏等，无法按标识枚举）\n"
        " 改为运行时按 frame 区间发现，单独缩放 0.6 倍（leadScale）。\n"
        " v1.8.0 新增「辅助图标条」：把系统不显示在灵动岛左右的图标（闹钟/专注/\n"
        " 旋转锁/定位/VPN/蓝牙/飞行模式）收拢到灵动岛正下方一行显示，缩放 0.4 倍\n"
        " （基准 17pt → 6.8pt），主屏与 App 内跟随时间显示，锁屏隐藏。\n"
        " v1.8.6 去重改为「状态栏变化信号」驱动：hook _UIStatusBarForegroundView 的\n"
        " addSubview:/insertSubview:/willRemoveSubview: + _UIStatusBar 的\n"
        " _updateDisplayedItemsWithData:styleAttributes:extraAnimations:，由状态栏\n"
        " 视图树增删事件实时重算「系统正在显示谁」——系统自己画出定位箭头时，\n"
        " 辅助条同一帧内把定位图标剔除，绝不重复（加立即、减需连续 3 次一致）。\n"
        " v1.8.11 判定不再看图标名：改读状态栏自己的 item 模型\n"
        " （_UIStatusBar._items → 每项 _displayItems[]._view 的实时挂载状态；\n"
        "  _items 在运行期是字典、启动瞬间是数组，两种形态都接），\n"
        " 与 location.fill / location.circle.fill 这类会变的字形名彻底解耦；\n"
        " 视图树扫描降级为纯日志交叉核对；过渡帧（视图已挂载但 frame=0 / 临时 hidden）\n"
        " 用 1.2s 宽限兜住，杜绝闪烁式重复。\n"
        " v1.8.11 修日志不忠实：原「条显示/条隐藏」是进程内永久去重（同组合只记一次、\n"
        " hidden 的 key 固定故一进程仅一条）→ 改为按状态跃迁记录 + 20s 心跳，任何\n"
        " 显/隐切换必留痕。\n"
        " v1.8.11 修宿主 ping-pong：主屏同时存在两个活 fg（UIStatusBarWindow 与\n"
        " SBMainSwitcherWindow）各以 1s 节奏布局 → 条被来回搬家；现加主/次宿主仲裁，\n"
        " UIStatusBarWindow 存活时 MainSwitcher 让位（App 前台主屏 fg 摘窗后自动放行）。\n"
        " transform 不参与布局计算，不影响间距与点击区域判定。\n"
        " 配置 /var/mobile/Library/Preferences/com.xu.statusbarscale.plist：\n"
        " enabled(bool)=YES / scale(float)=0.92 / dy(float)=1.5 / threshold(float)=280 /\n"
        " leadEnabled(bool)=YES / leadScale(float)=0.60 / leadDy(float)=0 /\n"
        " auxEnabled(bool)=YES / auxScale(float)=0.4 / auxBaseSize(float)=17 /\n"
        " auxGap(float)=3 / auxDebug(bool)=NO / diag(bool)=YES / verbose(bool)=NO，\n"
        " 改后 respring 生效。\n"
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
