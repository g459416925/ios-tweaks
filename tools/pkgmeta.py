#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pkgmeta.py —— 全部插件的单一元数据源（Description 与 SileoDepiction 同源）

结构（每个包一条）：
    category   功能分类（四类之一）
    name       展示名
    tagline    一句话定位
    features   功能要点列表
    host       宿主进程（tweak）
    type       类型（独立应用时填写，与 host 二选一）
    scope      生效范围（可选）
    compat     兼容性
    extra      [(label, value)] 追加表格行（可选）
    notes      备注（可选）

被以下脚本消费：
    rewrite_descriptions.py  → 写入 deb control 的 Description + SileoDepiction
    gen_depictions.py        → 生成 depictions/<pkg>.json
    build_index.py           → 生成 index.html
"""

REPO_BASE = "https://g459416925.github.io/ios-tweaks"

# 分类顺序与说明（决定 index.html 与详情页的分组顺序）
CATEGORIES = [
    ("界面视觉", "动效 / 字体 / 键盘 / 桌面 / 分辨率 / 状态栏"),
    ("系统增强", "限制锁定 / 充电管理 / 启动器"),
    ("广告拦截", "开屏 / 激励 / 插屏 / 信息流"),
    ("会员解锁", "VPN / 短剧 PWA / 独立宿主"),
]

PKGS = {
    # ==================== 界面视觉 ====================
    "com.xu.bounceit16": {
        "category": "界面视觉",
        "name": "BounceIt16",
        "tagline": "SpringBoard 系统动画果冻弹性回弹",
        "features": [
            "界面推入/退出时冲过头 → 回弹 → 小幅震荡后停止",
            "默认 ζ=0.325，弹 2 下即停，约 0.48s 收敛",
            "hook `SBFFluidBehaviorSettings -setDampingRatio:` 强制写入",
            "hook `SBFAnimationSettings` 的 damping / stiffness / mass / epsilon，getter 恒返回本插件值",
        ],
        "host": "SpringBoard",
        "compat": "iOS 16.x · RootHide 无根 · arm64e · ellekit",
        "notes": "原版 BounceIt 的 arm64e 切片会被 roothidepatch 改坏签名（dyld 拒绝加载、静默失效），故自行重写",
    },
    "com.xu.compactorfix": {
        "category": "界面视觉",
        "name": "CompactorFix",
        "tagline": "系统 UI 字体整体切换为 Apple Watch 的 SF Compact",
        "features": [
            "在 dyld 构造函数（早于 main）调用 `CTFontSetAltTextStyleSpec`，解决原版调用时机过晚不生效",
            "全部 `kCTFontUIFontType` 0..24 映射为 `.SFCompact-*`，实测整屏 13.07% 像素变化",
            "拉丁/希腊/西里尔字符生效；中日韩回退苹方 PingFang（预期行为，非缺陷）",
        ],
        "host": "全部 UIKit 应用 + SpringBoard",
        "compat": "iOS 16.x · RootHide 无根 · arm64e",
    },
    "com.xu.keyboardcorner16": {
        "category": "界面视觉",
        "name": "KeyboardCorner16",
        "tagline": "系统键盘圆角 / OLED 深色 / UnderDock 快捷操作整合",
        "features": [
            "全按键 10pt 圆角矩形增强，覆盖字母、数字与拨号键盘",
            "OLED 纯黑键盘背景，深色模式省电",
            "UnderDock 快捷操作条与 Kayoko 剪贴板整合",
            "候选栏常显判定：composing / visibleCandidateText / listCandidates",
        ],
        "host": "系统键盘独立进程",
        "compat": "iOS 16.x · RootHide 无根 · arm64e",
    },
    "com.xu.nohomeicons": {
        "category": "界面视觉",
        "name": "NoHomeIcons",
        "tagline": "主屏零图标净空，App 仅进资源库，Dock 保留",
        "features": [
            "纯视图层隐藏（alpha=0 + 禁交互），不写 IconState，卸载即恢复原布局",
            "锁定「新下载的 App = 仅 App 资源库」：`SBHomeAutomaticallyAddsNewApplications` 恒返回 NO",
            "移除「设置 → 主屏幕」入口，从根上断掉改设置的可能",
        ],
        "host": "SpringBoard + 设置",
        "compat": "iOS 16.x · RootHide 无根 · arm64e",
        "notes": "停用开关：`/var/mobile/Library/com.xu.nohomeicons/disabled`",
    },
    "com.xu.rescalefixed": {
        "category": "界面视觉",
        "name": "Re:Scale Fixed 440",
        "tagline": "固定 440×956 画布（iPhone 18 Pro Max 6.9\" @3x），装完即生效",
        "features": [
            "安装即写入固定画布偏好 1320×2868（=440×956pt @3x），无面板、无需确认",
            "分辨率注入复用原版 `ReScale.dylib`（字节未改、签名受信），键盘 414→440 修正内联在 ReScaleKB",
            "自带自检 `/usr/bin/rf_check`（--fix 可修复丢失的标记/偏好）",
            "自愈守护 `com.xu.rescalefixed.heal`：开机 / userspace reboot 自动补文件，仅确实修复时重启一次 backboardd",
        ],
        "host": "backboardd",
        "compat": "iOS 14.0+ · RootHide 无根 · arm64e",
        "extra": [("互斥", "原版 Re:Scale 2 及带面板重打包版（Conflicts / Replaces 已声明）")],
        "notes": "postinst 绝不重启系统进程；自愈守护修复文件时屏幕闪一下属预期",
    },
    "com.xu.statusbarscale": {
        "category": "界面视觉",
        "name": "StatusBarScale",
        "tagline": "灵动岛机型状态栏图标缩放对齐 + 资源库背景透明",
        "features": [
            "灵动岛右侧图标 ×0.9025 绕中心缩放 + 垂直微调，墨迹高度 13→12px 与时间对齐",
            "时间右侧、岛左侧图标按坐标区间发现，单独 ×0.5038",
            "App 资源库分类卡片背景板与搜索框背景材质清成透明，只留图标浮于壁纸",
            "受管表带撤销：视图脱离命中区间 1.5s 先摘登记再还原，防复用池换身份误伤",
            "纯 transform 实现，不参与 frame 布局，间距与点击区域不受影响",
        ],
        "host": "仅 SpringBoard（App 内状态栏由 SB 远程渲染）",
        "compat": "iOS 16.x · RootHide 无根 · arm64e",
    },

    # ==================== 系统增强 ====================
    "com.xu.screentimelocker16": {
        "category": "系统增强",
        "name": "ScreenTimeLocker16",
        "tagline": "把「屏幕使用时间」的 App 限额变成一把真正的锁",
        "features": [
            "数据层：禁止「再使用一分钟」，0/0 限额可长期生效",
            "设置页：允许把限额设成 0 小时 0 分钟",
            "拦截页：认证优先 Face ID，不可用时回落屏幕使用时间密码",
            "菜单弹窗保持系统原样，不注入额外选项，「请求更多使用时间」照常保留",
        ],
        "host": "SpringBoard",
        "compat": "iOS 16.x · RootHide 无根 · arm64e",
    },
    "chaoge.chargelimiter": {
        "category": "系统增强",
        "name": "ChargeLimiter",
        "tagline": "电池充电上限锁定，保护电池健康",
        "features": [
            "设置充电上限百分比，达到阈值自动停止充电",
            "自带 watchdog 守护进程，异常掉线自动恢复设置",
            "独立图形界面应用，安装后桌面即有图标",
        ],
        "type": "独立应用",
        "compat": "iOS 16.x · RootHide 无根 · arm64e",
    },
    "com.xu.chevronv3": {
        "category": "系统增强",
        "name": "ChevronV3",
        "tagline": "侧滑呼出启动器 + 应用分屏浮窗",
        "features": [
            "屏幕侧边快速呼出应用启动栏，点按直达应用",
            "应用分屏浮窗（CV3FloatingAppWindow），横竖屏方向 / 旋转自适应",
            "几何与旋转统一收敛单一决策函数，Scene 托管横屏下按 axesDiffer 判定真实方向",
        ],
        "host": "SpringBoard",
        "compat": "iOS 16.x · RootHide 无根 · arm64e",
        "extra": [("依赖", "mobilesubstrate（ellekit）· preferenceloader")],
    },

    # ==================== 广告拦截 ====================
    "com.xu.adskip": {
        "category": "广告拦截",
        "name": "广告跳过 AdSkip",
        "tagline": "自动跳过开屏/激励/插屏广告并保留奖励权益",
        "features": [
            "激励视频：play 后立即 seek 到尾部，走 SDK 原生 finish 路径，奖励照常发放",
            "开屏广告：倒计时直接清零，补发 splashAdWillClosed / splashAdClosed 完成关闭",
            "插屏与信息流：命中即收场，覆盖 GDT / 穿山甲 / 微信公众号信息流等宿主",
            "激励回调「原生优先、兜底补发」带幂等标记，不重复发奖、不丢奖",
        ],
        "scope": "生效应用由 `AdSkip.plist` 的 Filter.Bundles 控制",
        "compat": "iOS 15.0+ · RootHide 无根 · arm64e · ellekit",
    },

    # ==================== 会员解锁 ====================
    "com.xu.leafcrack": {
        "category": "会员解锁",
        "name": "LeafCrack",
        "tagline": "Leaf VPN 高级会员状态直写，隧道可用",
        "features": [
            "写入 `LEAF_ENC_IS_PREMIUM_ACTIVATED` / `TOTAL_POINTS` / `LAST_DEDUCT_TIME` 会员标记",
            "swizzle `NSUserDefaults` setBool/setInteger/setDouble:forKey:，标记改不回去",
            "RevenueCat `RCEntitlementInfo(s)` 的 isActive / active 系列恒返回 YES",
            "自动确保 `LEAF_ENC_DEFAULT_CONFIG_KEY` 指向有效配置，点 GO 可正常建隧道",
            "后台巡检 10 分钟，会员标记被覆盖立刻重写",
        ],
        "host": "`com.kitslabs.production.Leaf`",
        "compat": "iOS 16.x · RootHide 无根 · arm64e",
    },
    "com.xu.hgvip": {
        "category": "会员解锁",
        "name": "HGVip",
        "tagline": "黄果短剧 PWA 会员解锁（WKWebView 脚本注入）",
        "features": [
            "documentStart 注入，接管 `/api/app/` 的 JSON 响应与 `localStorage.userInfo`",
            "isVip / vipLevel / vipExpireDate 置为会员态",
            "permission / lockStatus / accessType / canPlay 置为已解锁",
            "unlockCoins / price 归零，freeEpisode 放开",
        ],
        "compat": "iOS 15.0+ · RootHide 无根 · arm64e · ellekit",
        "extra": [("自检", "`xnotify com.xu.hgvip.selftest` ｜ 补打 `xnotify com.xu.hgvip.repair`")],
    },
    "com.xu.hgweb": {
        "category": "会员解锁",
        "name": "黄果短剧",
        "tagline": "黄果短剧独立宿主（内置会员解锁）",
        "features": [
            "独立 WKWebView 宿主应用，不依赖系统 PWA 安装流程",
            "内置 HGVip 同款会员解锁逻辑，开箱即用",
        ],
        "type": "独立应用",
        "compat": "iOS 15.0+ · RootHide 无根 · arm64e",
    },
}

# 包名 → 源内最新版本（gen 脚本会与实际 debs/ 交叉校验）
LATEST = {
    "com.xu.bounceit16": "1.1.10",
    "com.xu.compactorfix": "1.0.0",
    "com.xu.keyboardcorner16": "1.0.93",
    "com.xu.nohomeicons": "0.7.5",
    "com.xu.rescalefixed": "3.1.1",
    "com.xu.statusbarscale": "2.8.7",
    "com.xu.screentimelocker16": "5.2.1",
    "chaoge.chargelimiter": "1.7.2",
    "com.xu.chevronv3": "1.0.18-227+env-fast-1+debug",
    "com.xu.adskip": "1.4.24",
    "com.xu.leafcrack": "1.2.1",
    "com.xu.hgvip": "1.0.0",
    "com.xu.hgweb": "1.0.0",
}


# ---------------------------------------------------------------------------
# 派生：Description（纯文本，供不支持 depiction 的客户端 / 搜索结果显示）
# ---------------------------------------------------------------------------
def synopsis(pkg):
    m = PKGS[pkg]
    return "%s · %s" % (m["category"], m["tagline"])


def description_lines(pkg):
    m = PKGS[pkg]
    out = ["【功能】"]
    out += ["· " + f for f in m["features"]]
    if m.get("scope"):
        out.append("【范围】" + m["scope"])
    if m.get("type"):
        out.append("【类型】" + m["type"] + "（非 tweak）")
    if m.get("host"):
        out.append("【宿主】" + m["host"])
    for label, val in m.get("extra", []):
        out.append("【%s】%s" % (label, val))
    out.append("【兼容】" + m["compat"])
    return out


def depiction_url(pkg):
    return "%s/depictions/%s.json" % (REPO_BASE, pkg)


def markdown_features(pkg):
    return "\n".join("- " + f for f in PKGS[pkg]["features"])
