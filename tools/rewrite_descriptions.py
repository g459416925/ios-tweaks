#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
rewrite_descriptions.py —— 统一重写 debs/ 下所有 .deb 的 Description 字段

规范格式（所有包一致，顺序固定，不得随意排列）：
    Description: <功能分类> · <一句话定位>
     【功能】
     · 要点……
     （可选补充节：【范围】/【自检】/【互斥】，位于【功能】之后）
     【宿主】……（独立应用用【类型】）
     【兼容】……

规则：
  - 只替换 control 成员里的 Description 字段；其余字段、字段顺序、
    control.tar 内其它成员（postinst/prerm 等）、压缩格式原样保留
  - data.tar.* 字节零改动（内部 dylib 及签名不受影响），重写后逐包校验
  - 同一包所有历史版本写入同一份规范描述

用法：
    python3 tools/rewrite_descriptions.py          # 执行重写
    python3 tools/rewrite_descriptions.py --check  # 只校验不写入
"""
import copy
import hashlib
import io
import os
import sys
import tarfile
import gzip
import lzma

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEBS = os.path.join(ROOT, "debs")

AR_MAGIC = b"!<arch>\n"

# ---------------------------------------------------------------------------
# 规范描述表：包名 -> (synopsis, [content lines])
# content line 不带 Debian 续行前导空格，由写入器统一加一个空格
# ---------------------------------------------------------------------------
DESCS = {
    # ---- 广告拦截 ----
    "com.xu.adskip": (
        "广告拦截 · 自动跳过开屏/激励/插屏广告并保留奖励权益",
        [
            "【功能】",
            "· 激励视频：play 后立即 seek 到尾部，走 SDK 原生 finish 路径，奖励照常发放",
            "· 开屏广告：倒计时直接清零，补发 splashAdWillClosed / splashAdClosed 完成关闭",
            "· 插屏与信息流：命中即收场，覆盖 GDT / 穿山甲 / 微信公众号信息流等宿主",
            "· 激励回调「原生优先、兜底补发」带幂等标记，不重复发奖、不丢奖",
            "【范围】生效应用由 AdSkip.plist 的 Filter.Bundles 控制",
            "【兼容】iOS 15.0+ · RootHide 无根 · arm64e · ellekit",
        ],
    ),
    # ---- 界面视觉 ----
    "com.xu.bounceit16": (
        "界面动效 · SpringBoard 系统动画果冻弹性回弹（BounceIt 自研重写版）",
        [
            "【功能】",
            "· 界面推入/退出时冲过头 → 回弹 → 小幅震荡后停止，默认 ζ=0.325 弹 2 下即停",
            "· hook SBFFluidBehaviorSettings -setDampingRatio: 强制写入",
            "· hook SBFAnimationSettings 的 damping / stiffness / mass / epsilon，getter 恒返回本插件值",
            "【宿主】SpringBoard",
            "【兼容】iOS 16.x · RootHide 无根 · arm64e · ellekit",
        ],
    ),
    "com.xu.compactorfix": (
        "界面字体 · 系统 UI 字体整体切换为 Apple Watch 的 SF Compact",
        [
            "【功能】",
            "· 在 dyld 构造函数（早于 main）调用 CTFontSetAltTextStyleSpec，解决原版调用时机过晚不生效",
            "· 全部 kCTFontUIFontType 0..24 映射为 .SFCompact-*，实测整屏 13.07% 像素变化",
            "· 拉丁/希腊/西里尔字符生效；中日韩回退苹方 PingFang（预期行为，非缺陷）",
            "【宿主】全部 UIKit 应用 + SpringBoard",
            "【兼容】iOS 16.x · RootHide 无根 · arm64e",
        ],
    ),
    "com.xu.keyboardcorner16": (
        "键盘增强 · 系统键盘圆角 / OLED 深色 / UnderDock 快捷操作整合",
        [
            "【功能】",
            "· 全按键 10pt 圆角矩形增强，覆盖字母、数字与拨号键盘",
            "· OLED 纯黑键盘背景，深色模式省电",
            "· UnderDock 快捷操作条与 Kayoko 剪贴板整合",
            "· 候选栏常显判定：composing / visibleCandidateText / listCandidates",
            "【宿主】系统键盘独立进程",
            "【兼容】iOS 16.x · RootHide 无根 · arm64e",
        ],
    ),
    "com.xu.nohomeicons": (
        "桌面布局 · 主屏零图标净空（App 仅进资源库，Dock 保留）",
        [
            "【功能】",
            "· 纯视图层隐藏（alpha=0 + 禁交互），不写 IconState，卸载即恢复原布局",
            "· 锁定「新下载的 App = 仅 App 资源库」：SBHomeAutomaticallyAddsNewApplications 恒返回 NO",
            "· 移除「设置 → 主屏幕」入口，从根上断掉改设置的可能",
            "【宿主】SpringBoard + 设置",
            "【兼容】iOS 16.x · RootHide 无根 · arm64e",
        ],
    ),
    "com.xu.rescalefixed": (
        "显示分辨率 · 固定 440×956 画布（iPhone 18 Pro Max 6.9\" @3x），装完即生效",
        [
            "【功能】",
            "· 安装即写入固定画布偏好 1320×2868（=440×956pt @3x），无面板、无需确认",
            "· 分辨率注入复用原版 ReScale.dylib（字节未改、签名受信），键盘 414→440 修正内联在 ReScaleKB",
            "· 自带自检 /usr/bin/rf_check（--fix 可修复丢失的标记/偏好）",
            "· 自愈守护 com.xu.rescalefixed.heal：开机 / userspace reboot 自动补文件，仅确实修复时重启一次 backboardd",
            "【互斥】与原版 Re:Scale 2 及带面板重打包版互斥（Conflicts / Replaces 已声明）",
            "【兼容】iOS 14.0+ · RootHide 无根 · arm64e",
        ],
    ),
    "com.xu.statusbarscale": (
        "状态栏修正 · 灵动岛机型状态栏图标缩放对齐 + 资源库背景透明",
        [
            "【功能】",
            "· 灵动岛右侧图标 ×0.9025 绕中心缩放 + 垂直微调，图标墨迹高度 13→12px 与时间对齐",
            "· 时间右侧、岛左侧图标按坐标区间发现，单独 ×0.5038",
            "· App 资源库分类卡片背景板与搜索框背景材质清成透明，只留图标浮于壁纸",
            "· 受管表带撤销：视图脱离命中区间 1.5s 先摘登记再还原，防复用池换身份误伤",
            "· 纯 transform 实现，不参与 frame 布局，间距与点击区域不受影响",
            "【宿主】仅 SpringBoard（App 内状态栏由 SB 远程渲染）",
            "【兼容】iOS 16.x · RootHide 无根 · arm64e",
        ],
    ),
    # ---- 系统增强 ----
    "com.xu.screentimelocker16": (
        "系统限制 · 把「屏幕使用时间」的 App 限额变成一把真正的锁",
        [
            "【功能】",
            "· 数据层：禁止「再使用一分钟」，0/0 限额可长期生效",
            "· 设置页：允许把限额设成 0 小时 0 分钟",
            "· 拦截页：认证优先 Face ID，不可用时回落屏幕使用时间密码",
            "· 菜单弹窗保持系统原样，不注入额外选项，「请求更多使用时间」照常保留",
            "【宿主】SpringBoard",
            "【兼容】iOS 16.x · RootHide 无根 · arm64e",
        ],
    ),
    "chaoge.chargelimiter": (
        "充电管理 · 电池充电上限锁定，保护电池健康",
        [
            "【功能】",
            "· 设置充电上限百分比，达到阈值自动停止充电",
            "· 自带 watchdog 守护进程，异常掉线自动恢复设置",
            "· 独立图形界面应用，安装后桌面即有图标",
            "【类型】独立应用（非 tweak）",
            "【兼容】iOS 16.x · RootHide 无根 · arm64e",
        ],
    ),
    "com.xu.chevronv3": (
        "启动器 · Chevron 启动器第三代（侧滑呼出 + 分屏浮窗）",
        [
            "【功能】",
            "· 屏幕侧边快速呼出应用启动栏，点按直达应用",
            "· 应用分屏浮窗（CV3FloatingAppWindow），横竖屏方向 / 旋转自适应",
            "· 几何与旋转统一收敛单一决策函数，Scene 托管横屏下按 axesDiffer 判定真实方向",
            "【宿主】SpringBoard",
            "【依赖】mobilesubstrate（ellekit）· preferenceloader",
            "【兼容】iOS 16.x · RootHide 无根 · arm64e",
        ],
    ),
    # ---- 会员解锁 ----
    "com.xu.leafcrack": (
        "会员解锁 · Leaf VPN 高级会员状态直写，隧道可用",
        [
            "【功能】",
            "· 写入 LEAF_ENC_IS_PREMIUM_ACTIVATED / TOTAL_POINTS / LAST_DEDUCT_TIME 会员标记",
            "· swizzle NSUserDefaults setBool/setInteger/setDouble:forKey:，标记改不回去",
            "· RevenueCat RCEntitlementInfo(s) 的 isActive / active 系列恒返回 YES",
            "· 自动确保 LEAF_ENC_DEFAULT_CONFIG_KEY 指向有效配置，点 GO 可正常建隧道",
            "· 后台巡检 10 分钟，会员标记被覆盖立刻重写",
            "【宿主】com.kitslabs.production.Leaf",
            "【兼容】iOS 16.x · RootHide 无根 · arm64e",
        ],
    ),
    "com.xu.hgvip": (
        "会员解锁 · 黄果短剧 PWA 会员解锁（WKWebView 脚本注入）",
        [
            "【功能】",
            "· documentStart 注入，接管 /api/app/ 的 JSON 响应与 localStorage.userInfo",
            "· isVip / vipLevel / vipExpireDate 置为会员态",
            "· permission / lockStatus / accessType / canPlay 置为已解锁",
            "· unlockCoins / price 归零，freeEpisode 放开",
            "【自检】xnotify com.xu.hgvip.selftest ｜ 补打 xnotify com.xu.hgvip.repair ｜ 日志 HGVip.log",
            "【兼容】iOS 15.0+ · RootHide 无根 · arm64e · ellekit",
        ],
    ),
    "com.xu.hgweb": (
        "会员解锁 · 黄果短剧独立宿主（内置会员解锁）",
        [
            "【功能】",
            "· 独立 WKWebView 宿主应用，不依赖系统 PWA 安装流程",
            "· 内置 HGVip 同款会员解锁逻辑，开箱即用",
            "【类型】独立应用（非 tweak）",
            "【兼容】iOS 15.0+ · RootHide 无根 · arm64e",
        ],
    ),
}


# ---------------------------------------------------------------------------
# deb (ar 归档) 解析 / 重建
# ---------------------------------------------------------------------------
def split_ar(raw):
    """解析 ar 归档 → [(name, hdr60, data)]"""
    if raw[:8] != AR_MAGIC:
        raise ValueError("不是合法的 ar 归档")
    out, off = [], 8
    while off + 60 <= len(raw):
        hdr = raw[off:off + 60]
        name = hdr[0:16].decode("ascii", "replace").rstrip(" \x00")
        size = int(hdr[48:58].decode("ascii").strip())
        out.append((name, hdr, raw[off + 60:off + 60 + size]))
        off += 60 + size + (size % 2)
    return out


def build_ar(members):
    """members: [(name, hdr60, data)] → ar 字节流；仅更新 size 字段，其余头部字节保留"""
    out = bytearray(AR_MAGIC)
    for _name, hdr, data in members:
        h = bytearray(hdr)
        h[48:58] = b"%10d" % len(data)
        out += h
        out += data
        if len(data) % 2:
            out += b"\n"
    return bytes(out)


# ---------------------------------------------------------------------------
# control.tar 重写
# ---------------------------------------------------------------------------
def rewrite_control_tar(ctl_blob, synopsis, content_lines):
    """解压 control.tar.* → 仅替换 control 成员的 Description → 按原压缩格式重打包"""
    if ctl_blob[:2] == b"\x1f\x8b":
        mode, raw_tar = "w:gz", gzip.decompress(ctl_blob)
    elif ctl_blob[:6] == b"\xfd7zXZ\x00":
        mode, raw_tar = "w:xz", lzma.decompress(ctl_blob)
    else:
        mode, raw_tar = "w", ctl_blob

    src = tarfile.open(fileobj=io.BytesIO(raw_tar))
    members = src.getmembers()
    out = io.BytesIO()
    replaced = False
    with tarfile.open(fileobj=out, mode=mode, format=tarfile.GNU_FORMAT) as dst:
        for m in members:
            f = src.extractfile(m) if m.isreg() else None
            mi = copy.copy(m)
            if f is not None and m.name.rstrip("/").endswith("control"):
                old = f.read().decode("utf-8")
                new = replace_description(old, synopsis, content_lines)
                b = new.encode("utf-8")
                mi.size = len(b)
                dst.addfile(mi, io.BytesIO(b))
                replaced = True
            elif f is not None:
                mi.size = m.size
                dst.addfile(mi, f)
            else:
                dst.addfile(mi)
    if not replaced:
        raise ValueError("control.tar 里没有 control 成员")
    return out.getvalue()


def replace_description(ctl_text, synopsis, content_lines):
    """原位替换 Description 字段（含其续行），其余字段与顺序保持不变"""
    lines = ctl_text.split("\n")
    out, i, replaced = [], 0, False
    while i < len(lines):
        if lines[i].startswith("Description:"):
            out.append("Description: " + synopsis)
            for cl in content_lines:
                out.append(" " + cl)
            i += 1
            # 跳过旧 Description 的续行（以空格开头的行）
            while i < len(lines) and lines[i].startswith(" "):
                i += 1
            replaced = True
            continue
        out.append(lines[i])
        i += 1
    if not replaced:
        raise ValueError("control 里没有 Description 字段")
    # 原样保留尾部结构（含原有空行），只动 Description 块
    return "\n".join(out)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def read_control_text(ctl_blob):
    if ctl_blob[:2] == b"\x1f\x8b":
        raw_tar = gzip.decompress(ctl_blob)
    elif ctl_blob[:6] == b"\xfd7zXZ\x00":
        raw_tar = lzma.decompress(ctl_blob)
    else:
        raw_tar = ctl_blob
    with tarfile.open(fileobj=io.BytesIO(raw_tar)) as tf:
        for m in tf.getmembers():
            if m.name.rstrip("/").endswith("control"):
                return tf.extractfile(m).read().decode("utf-8")
    raise ValueError("control 未找到")


def process_deb(path, check_only=False):
    raw = open(path, "rb").read()
    members = split_ar(raw)
    ctl_idx = next(i for i, (n, _, _) in enumerate(members) if n.startswith("control.tar"))
    ctl_name, _, ctl_blob = members[ctl_idx]

    old_ctl = read_control_text(ctl_blob)
    pkg = None
    for ln in old_ctl.split("\n"):
        if ln.startswith("Package:"):
            pkg = ln.split(":", 1)[1].strip()
            break
    if pkg not in DESCS:
        return ("SKIP", pkg, None)
    synopsis, content = DESCS[pkg]

    if check_only:
        want = ("Description: " + synopsis) + "".join("\n " + c for c in content)
        ok = want in old_ctl
        return ("OK" if ok else "MISMATCH", pkg, None)

    new_ctl_blob = rewrite_control_tar(ctl_blob, synopsis, content)
    new_members = list(members)
    new_members[ctl_idx] = (ctl_name, members[ctl_idx][1], new_ctl_blob)
    new_raw = build_ar(new_members)

    # ---- 校验：data.tar.* 字节必须与原来完全一致 ----
    old_data = {n: d for n, _, d in members if n.startswith("data.tar")}
    new_data = {n: d for n, _, d in split_ar(new_raw) if n.startswith("data.tar")}
    assert old_data == new_data, "%s: data.tar 变了！" % path
    # ---- 校验：新 control 可读回且 Description 已替换 ----
    new_ctl = read_control_text(new_ctl_blob)
    assert ("Description: " + synopsis) in new_ctl, "%s: Description 未替换" % path
    # ---- 校验：其余字段不变（除 Description 块） ----
    old_fields = fields_except_description(old_ctl)
    new_fields = fields_except_description(new_ctl)
    assert old_fields == new_fields, "%s: 其余 control 字段被改动" % path

    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(new_raw)
    os.replace(tmp, path)
    return ("DONE", pkg, (hashlib.sha256(raw).hexdigest()[:12],
                          hashlib.sha256(new_raw).hexdigest()[:12]))


def fields_except_description(ctl_text):
    """提取除 Description 外的全部字段行（供前后一致性比对）"""
    lines = ctl_text.split("\n")
    out, i = [], 0
    while i < len(lines):
        if lines[i].startswith("Description:"):
            i += 1
            while i < len(lines) and lines[i].startswith(" "):
                i += 1
            continue
        out.append(lines[i])
        i += 1
    return out


def main():
    check_only = "--check" in sys.argv
    stats = {}
    for fn in sorted(os.listdir(DEBS)):
        if not fn.endswith(".deb"):
            continue
        p = os.path.join(DEBS, fn)
        try:
            status, pkg, extra = process_deb(p, check_only)
        except Exception as e:
            print("  !! %s: %s" % (fn, e))
            stats.setdefault("FAIL", []).append(fn)
            continue
        stats.setdefault(status, []).append(fn)
        if extra:
            print("  %s %-55s %s %s→%s" % (status, fn, pkg, extra[0], extra[1]))
        elif status in ("MISMATCH", "SKIP"):
            print("  %s %-55s %s" % (status, fn, pkg))
    print("\n== 汇总 ==")
    for k in ("DONE", "OK", "MISMATCH", "SKIP", "FAIL"):
        if k in stats:
            print("  %-8s %d" % (k, len(stats[k])))
    if "FAIL" in stats or "MISMATCH" in stats:
        sys.exit(1)


if __name__ == "__main__":
    main()
