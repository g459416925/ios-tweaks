#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pkgmeta.py —— 全部插件的单一元数据源（Description 与 SileoDepiction 同源）

结构（每个包一条）：
    category   功能分类（四类之一）
    name       展示名
    tagline    一句话定位
    features   主要功能点列表（用户视角，写全；不写实现机制/hook 细节/宿主/依赖）
    type       类型（独立应用时填写）
    compat     兼容性

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
        "tagline": "系统动画果冻弹性回弹",
        "features": [
            "全局系统动画加入弹簧回弹：界面推入/退出时冲过头 → 回弹 → 小幅震荡后停下",
            "默认手感 ζ=0.325：约 34% 过冲、0.48s 收敛，弹两下即停",
            "回弹力度可通过偏好键 `kBDamping` / `kBDRatio` 调节",
            "卸载即恢复系统原生动画",
        ],
        "compat": "iOS 16.x · RootHide 无根 · arm64e · ellekit",
    },
    "com.xu.compactorfix": {
        "category": "界面视觉",
        "name": "CompactorFix",
        "tagline": "系统 UI 字体整体切换为 SF Compact",
        "features": [
            "系统 UI 字体整体换成 Apple Watch 的 SF Compact，覆盖全部系统字体类型",
            "英文等拉丁系字符全部生效，观感与 Apple Watch 一致",
            "中文等中日韩字符不受影响（仍回退苹方，属预期）",
            "全部 App 与主屏统一生效",
        ],
        "compat": "iOS 16.x · RootHide 无根 · arm64e",
    },
    "com.xu.keyboardcorner16": {
        "category": "界面视觉",
        "name": "KeyboardCorner16",
        "tagline": "系统键盘圆角 / 候选栏 / OLED / 快捷操作整合",
        "features": [
            "全键盘按键 10pt 圆角增强，字母、数字、拨号键盘全覆盖",
            "候选栏常显：无候选词时也保留候选栏，输入区不再上下跳动",
            "预测栏强制常显",
            "OLED 纯黑键盘背景，深色模式省电",
            "UnderDock 键盘下方快捷操作条",
            "Kayoko 剪贴板整合",
            "数字键盘重影修复、拨号圆点尺寸修正",
        ],
        "compat": "iOS 16.x · RootHide 无根 · arm64e",
    },
    "com.xu.nohomeicons": {
        "category": "界面视觉",
        "name": "NoHomeIcons",
        "tagline": "主屏零图标净空，App 只进资源库",
        "features": [
            "主屏所有页面隐藏全部 App 图标，只留壁纸、小组件与 Dock",
            "新下载的 App 强制「仅 App 资源库」，不会冒回主屏",
            "移除「设置 → 主屏幕」入口，从根上防止改回",
            "卸载即完整恢复原主屏布局",
            "停用开关：`/var/mobile/Library/com.xu.nohomeicons/disabled`",
        ],
        "compat": "iOS 16.x · RootHide 无根 · arm64e",
    },
    "com.xu.rescalefixed": {
        "category": "界面视觉",
        "name": "Re:Scale Fixed 440",
        "tagline": "固定 440×956 分辨率，装完即生效",
        "features": [
            "固定 440×956 显示画布（iPhone 18 Pro Max 6.9\" @3x 档），respring 一次全局生效",
            "无设置面板、无需任何确认，装完即用",
            "自带自检工具 `/usr/bin/rf_check`，`--fix` 一键修复",
            "自愈守护：开机 / 重启自动补齐丢失文件，无需手动干预",
            "与原版 Re:Scale 2 及带面板重打包版互斥，安装时自动替换旧版",
        ],
        "compat": "iOS 14.0+ · RootHide 无根 · arm64e",
    },
    "com.xu.statusbarscale": {
        "category": "界面视觉",
        "name": "StatusBarScale",
        "tagline": "状态栏图标缩放对齐 + 资源库透明 + 控制中心模块",
        "features": [
            "灵动岛右侧状态栏图标缩小，与时间字高精确对齐",
            "时间旁、灵动岛左侧的辅助图标（闹钟/定位/录屏等）单独缩小",
            "App 资源库分类卡片背景板透明，只留图标浮于壁纸",
            "资源库搜索框背景透明",
            "控制中心无 FaceTime 会话时自动合成麦克风模式/视频效果模块（不依赖通话）",
            "灵动岛折叠环处理，可用文件关闭：`fold_disabled`",
            "纯缩放实现，图标间距与点击区域不受影响",
        ],
        "compat": "iOS 16.x · RootHide 无根 · arm64e",
    },

    # ==================== 系统增强 ====================
    "com.xu.screentimelocker16": {
        "category": "系统增强",
        "name": "ScreenTimeLocker16",
        "tagline": "屏幕使用时间 App 限额真正锁得住",
        "features": [
            "禁止「再使用一分钟」，App 限额到期真正锁住",
            "限额可设 0 小时 0 分钟，长期生效",
            "解锁认证优先 Face ID，不可用时回落屏幕使用时间密码",
            "保持系统原生弹窗与「请求更多使用时间」流程不变",
        ],
        "compat": "iOS 16.x · RootHide 无根 · arm64e",
    },
    "chaoge.chargelimiter": {
        "category": "系统增强",
        "name": "ChargeLimiter",
        "tagline": "电池充电上限锁定（AlDente 替代）",
        "features": [
            "设置充电上限百分比，达到阈值自动停止充电",
            "整夜充电 / 长期插电场景保护电池健康度",
            "悬浮窗实时显示充电状态",
            "高温模拟（锁屏时失效）",
            "watchdog 守护：异常掉线自动恢复设置",
            "支持有根/无根越狱与巨魔，iOS 12–17；永久免费无广告",
        ],
        "type": "独立应用",
        "compat": "iOS 12–17 · 有根 / 无根 / 巨魔",
    },
    "com.xu.chevronv3": {
        "category": "系统增强",
        "name": "ChevronV3",
        "tagline": "边缘启动器 + 应用分屏浮窗",
        "features": [
            "屏幕边缘热区快速呼出启动器，点按直达应用",
            "应用分屏浮窗：任意 App 以独立窗口悬浮使用，带独立键盘与键盘避让",
            "浮窗支持移动、缩放、贴边磁吸对齐、多窗等距平铺（Expose）",
            "从启动器拖出 App 图标直接创建分屏；同一 App 复用已有窗口",
            "每个浮窗自动记忆位置与方向，重启后恢复",
            "贴边收纳与一键恢复，收纳时目标 App 转后台不耗资源",
            "视频类内容自动横屏，退出恢复竖屏",
            "浮窗菜单支持截图复制为图片，粘贴到支持图片粘贴的 App",
            "场景断连自动检测与恢复",
        ],
        "compat": "iOS 16.x · RootHide 无根 · arm64e",
    },

    # ==================== 广告拦截 ====================
    "com.xu.adskip": {
        "category": "广告拦截",
        "name": "广告跳过 AdSkip",
        "tagline": "开屏零帧清除 / 激励视频秒收尾 / 信息流拦截",
        "features": [
            "开屏广告零帧清除：广告不显示，直接进入应用",
            "激励视频秒收尾：立即播完并照常发放奖励，不重复发奖、不丢奖",
            "插屏广告命中即自动关闭",
            "微信公众号信息流广告去除（数据层拦截）",
            "微信文章页广告去除：文中 / 底部 / 留言区 / 顶部全覆盖",
            "支持多应用：生效列表由 `AdSkip.plist` 配置",
            "微信模块开关：`Documents/wxadskip_off`",
        ],
        "compat": "iOS 15.0+ · RootHide 无根 · arm64e · ellekit",
    },

    # ==================== 会员解锁 ====================
    "com.xu.leafcrack": {
        "category": "会员解锁",
        "name": "LeafCrack",
        "tagline": "Leaf VPN 高级会员解锁，隧道可用",
        "features": [
            "高级会员状态直写：会员标记 / 积分 / 扣费时间全部置为会员态",
            "RevenueCat 订阅权益恒显示激活",
            "VPN 隧道可用：自动修复默认配置，点 GO 正常建立隧道",
            "后台每 10 分钟巡检，会员标记被覆盖立即重写",
        ],
        "compat": "iOS 16.x · RootHide 无根 · arm64e",
    },
    "com.xu.hgvip": {
        "category": "会员解锁",
        "name": "HGVip",
        "tagline": "黄果短剧会员解锁",
        "features": [
            "会员状态解锁：会员标识 / 等级 / 到期时间全部置为会员态",
            "剧集权限解锁：锁定状态 / 可播 / 访问类型全部放开",
            "付费内容免费：金币消耗归零、价格清零、免费剧集放开",
            "自检与补打：`xnotify com.xu.hgvip.selftest` / `repair`",
        ],
        "compat": "iOS 15.0+ · RootHide 无根 · arm64e · ellekit",
    },
    "com.xu.hgweb": {
        "category": "会员解锁",
        "name": "黄果短剧",
        "tagline": "黄果短剧独立宿主（内置会员解锁）",
        "features": [
            "黄果短剧独立宿主 App：自带浏览器直接看，不依赖系统 PWA 安装流程",
            "内置会员解锁逻辑，开箱即用",
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
    if m.get("type"):
        out.append("【类型】" + m["type"] + "（非 tweak）")
    out.append("【兼容】" + m["compat"])
    return out


def depiction_url(pkg):
    return "%s/depictions/%s.json" % (REPO_BASE, pkg)
