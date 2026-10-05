# StatusBarScale — 状态栏图标缩放对齐

**包名** `com.xu.statusbarscale` · **版本** 1.7.2 · **宿主** 仅 SpringBoard

## 解决什么问题

灵动岛机型（iPhone 14 Pro Max / iOS 16.5.1 实测）状态栏右侧图标与左侧时间不对齐：

| 项 | 时间 | 图标 | 差 |
|---|---|---|---|
| 墨迹高度 | 12 px | 13–14 px | 图标偏高 +1 |
| 重心 y | 29.4 | 27.7 | 图标偏高 1.66 px |

观感：图标比时间大一圈且往上飘——即许总说的「极度不舒适」。

## 原理

hook 私有类 `_UIStatusBarForegroundView` 的 `-layoutSubviews`（运行时 `objc_getClass`
解析，**零链接期私有符号**），在原布局完成后对灵动岛右侧（`frame.minX >= threshold`）
的直接子视图施加：

```
transform = Translate(Scale(s, s), 0, dy/s)   // 绕中心缩放 s 倍 + 下移 dy pt
```

- `UIView.transform` 绕 anchorPoint（中心）变换，**不参与 frame 布局计算** → 间距、
  点击区域判定完全不受影响；
- 每次布局后重设同一 transform，幂等；灵动岛展开/收起时自动跟随；
- 实测（scale=0.92, dy=1.7）：图标高 13→12（=时间）、重心差 −1.66→**−0.07 px**。

## 配置

`/var/mobile/Library/Preferences/com.xu.statusbarscale.plist`（改后 respring）：

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `enabled` | bool | YES | 总开关（一键停用） |
| `scale` | float | 0.92 | 右侧图标缩放倍率 |
| `dy` | float | 1.5 | 右侧图标下移量（pt，正=向下） |
| `threshold` | float | 312 | 右侧判定阈值（frame.minX ≥ 该值的子视图） |
| `leadEnabled` | bool | YES | ⭐v1.7 leading 区（时间右侧、灵动岛左侧）缩放开关 |
| `leadScale` | float | 0.60 | ⭐v1.7 leading 图标缩放倍率（许总指定 0.6） |
| `leadDy` | float | 0 | ⭐v1.7 leading 图标额外下移量（默认不位移） |
| `diag` | bool | YES | ⭐v1.7.1 关键事件直写日志（独立于 verbose） |
| `verbose` | bool | NO | 高频诊断日志（[pass]/[deny]/层级 dump） |
| `auxEnabled` | bool | YES | 辅助条总开关 |
| `auxStrip` | bool | YES | 辅助条本体二分开关 |
| `auxData` | bool | YES | applyUpdate 数据钩子二分开关 |
| `auxIcons` | array | 见下 | 辅助图标标识集合 |

⚠️ RootHide 坑：SSH 下部署该文件**必须**走
`/rootfs/private/var/mobile/Library/Preferences/`（不带前缀的是影子目录，插件读不到）。

## 日志

仅当 `verbose=YES` 时写入 `/var/mobile/Documents/sbs_log.txt`。正常模式完全不访问
该文件，避免 SpringBoard/其他进程产生 Sandbox deny 与日志风暴。

## 构建

```
./build_deploy.sh     # 编译→签名→打 DEB→dpkg 安装（禁止直接 cp 到 TweakInject）
python3 build_deb.py  # 打 .deb（版本自动取自源码 #define SBS_VERSION）
```

## 实测记录（2026-10-04）

- 部署后 2 次 sbreload 全成功，`sbs_log` 0 异常，CrashReporter 无新增；
- 基线 vs 修改后 `_sb_measure.py` 对比：高度差 +1.00→−1.00、重心差 −1.66→−0.07；
- v1.4.6 当时仍注入 SpringBoard 与各 App（v1.5.0 已移除该高风险策略）。

## v1.5.0–1.5.1 稳定性修复

- 注入过滤由 `Classes=UIApplication` 收缩为 `Bundles=com.apple.springboard`；普通 App、
  Aweme、WebKit、PosterBoard 不再加载本插件。
- 构造函数增加 SpringBoard 进程白名单，即使设备残留旧过滤文件也不会跨进程 hook。
- v1.5.1 恢复辅助条为默认核心功能，但只在 SpringBoard 中运行；主屏使用
  `UIStatusBarWindow`，App 前台使用 `SBMainSwitcherWindow`，两处均固定在灵动岛下方。
- 默认显示闹钟、专注/勿扰、旋转锁、VPN、蓝牙和飞行模式；排除时间、Wi‑Fi、
  蜂窝信号/数据、电量与定位，避免和灵动岛两侧系统项目重复。
- `verbose=NO` 时彻底禁用文件日志，停止 `sbs_log.txt` 沙盒拒绝和同步文件 I/O。
- 部署脚本改为打包后 `dpkg -i`，确保 RootHide 完整 patch/签名流程。
- SpringBoard 冷启动时等待 `_UIStatusBarForegroundView` 注册并有限重试，避免构造期
  类尚不存在时整次启动永久漏装缩放和辅助条 hook。

## 辅助条宿主架构（v1.4.x 系列实测终版）

SpringBoard 的状态栏 fg 在四个窗口间被借动，App 内状态栏为 SB 远程渲染：

| 窗口 | 角色 | 门禁 |
|---|---|---|
| `UIStatusBarWindow` (level 999) | 常驻总窗口：主屏/锁屏 fg 复用 | ✅ 放行 |
| `SBMainSwitcherWindow` | **App 前台的正宿主**（App 内状态栏由 SB 远程渲染，App 进程 windows=1 且无 fg 实例） | ✅ 放行 |
| `SBStatusBarReusePoolWindow` (hidden) | 备用 fg 池（切 App 时旧 fg 回池） | ❌ 拒绝 |
| `SBControlCenterWindow` | CC 迷你 fg（宽 361 假岛） | ❌ 拒绝 |

【实测铁证 19:40】App 进程 windows=1、树内无 `_UIStatusBarForegroundView`；App 内 fg
首挂窗早于 dylib ctor → hook 装好后 App 进程内 fg 永不触发布局 → App 进程做 3 轮
主动扫描（0.5/2/5s）兜底。锁屏判定用 `SBLockScreenManager.uiIsLocked`
（StringView.y 判据不可用：主屏与锁屏的 fg 内部坐标相同 y=18.67）。

## v1.4.6 五道防线

1. **门禁进程分流**：SB 内放行 UIStatusBarWindow+MainSwitcher、拒 ReusePool/CC/hidden；
   App 内只拒 hidden；
2. **锁屏隐藏**：`uiIsLocked` → 条 hidden，解锁布局触发自动恢复；
3. **host 同窗防护**：`host.window != fg.window` 不搬家（过渡瞬间容器漂移防护）；
4. **多档重试 ×4 路事件**：data 变化 / didMoveToWindow / didMoveToSuperview /
   setHidden: 各排 0/0.3/0.8/1.5s 强制重排（`gAuxForceRelayout` 跳节流）；
5. **1s 自愈 + 见过表**：gActiveFG 陈旧时从弱引用表找回当前合法 fg 实测 1s 内把条
   从 MainSwitcher/ReusePool 搬回主屏宿主。

## 工程坑（v1.4.6 新增）

- **日志多进程互踩**：限流统计 `writeToFile atomically:YES` 是整文件覆盖 —— SB 与
  App 共写同一 sbs_log 时互删对方全部行 → 改 fileHandle append；
- **ctor 内日志被限流吞**：[载入] 后 50ms 内的 [hook] 行全丢 → install 的 hook 结果
  用 `sbs_logNow` 直写（一次性日志直写安全）；
- **诊断日志分级**：关键事件（[move]/[heal]/[unhide]/[dmsup]/[scan]）直写不限流，
  dump 类走 20 行/秒限流；plist `verbose=YES` 开启。

## v1.7.x — leading 区（时间右侧、灵动岛左侧）图标缩放

### 问题（许总反馈，2026-10-05）
原实现只缩放 `minX >= threshold`（灵动岛右侧）的图标，**时间右侧、灵动岛左侧**那批
图标被整体漏掉；它们无法按标识枚举 → 改为**运行时按 fg 坐标系的 frame 区间发现**。

### 发现机制（判定条件，全部实机可观测）
- `timeMaxX` = 可见 StringView（时间）的最大右缘
- `leadLimit` = 灵动岛左缘（`sbs_islandFrameInFG().origin.x`，实测 152.0）
- 候选 = 非 StringView + 非 Background + class 含 StatusBar/Battery
  + 3pt ≤ 宽高 且 宽 < 200pt（排除全宽容器）+ `minX > timeMaxX` 且 `maxX ≤ leadLimit`
- 递归深度 3（leading item 可能嵌在容器内）；坐标一律 `convertRect:toView:` 换算

### 2026-10-05 实机日志（v1.7.2，SpringBoard/pid 26838）
```
[hook] layoutSubviews → 已安装                          ← 注入确证
[lead] 模块生效 v1.7.2 leadEnabled=1 leadScale=0.60 leadDy=0.00 proc=SpringBoard
[lead] 边界 timeMaxX=95.3 leadLimit=152.0 fgW=430.0
[lead] _UIStatusBarImageView x=101.1 y=24.1 w=10.2 h=10.4 hidden=0 alpha=1.00
       super=_UIStatusBarForegroundView                 ← 目标图标真实类名（实证）
[leadApply] _UIStatusBarImageView 缩放前 a=1.000 → 后 a=0.600（期望 0.600）  ← 缩放确证
```
**目标图标真实身份 = `_UIStatusBarImageView`（`_UIStatusBarForegroundView` 的直接子视图）。**

### ⭐⭐ v1.7.1 修复的严重回归（"没日志"的真正元凶）
v1.5.0 给 `sbs_logNow`（关键事件直写通道）也加了 `if (!gVerbose) return;`，
而设备 `verbose=false` → **日志一个字节都不写** → 故障完全无法定位（"图标无法枚举"的根因）。
现拆成两个语义：
- `diag`（默认 YES）→ `sbs_logNow` 关键事件直写（[hook]/[lead]/[leadApply]/[move]/[heal]/[scan]）
- `verbose`（默认 NO）→ `sbs_log` 高频/批量（[pass]/[deny]/层级 dump）

### 日志安全设计（防 v1.3.0 Jetsam 事故重演）
`[lead]` 报告：① 去重键 = 类名 + 帧坐标量化到 4pt 网格；② 每 0.3s 最多直写 1 条。
`[leadApply]` 仅对新登记视图写一次。高频路径（[pass]/[deny]/[heal]）各自保留
verbose 门控 + 0.15~0.5s 节流。

### ⚠️ 构建脚本 bug（v1.7.0 一并修复）
`build_deploy.sh` 的"私有符号必须为空"检查正则为 `_OBJC_CLASS_$_(UI|SB|UIStatusBar)`，
会**误判公共类** `_OBJC_CLASS_$_UIApplication` / `$_UIView` / `$_UIScreen` → 必然 `exit 1`，
部署永远走不完。已改为只匹配真私有符号：`_OBJC_CLASS_$__UI|$_(UIStatusBar|SB)`。

### v1.7.3 三道门禁（1.7.2 实机日志暴露的误伤，已修）
v1.7.2 上线后日志立刻暴露两处误伤：① `timeMaxX=0`（无可视时间）时判定区间退化成
`(0, leadLimit)`；② CC/Spotlight 迷你状态栏 fg（宽 361/370）也被扫描 →
左侧信号/WiFi 被缩到 0.6。

实机对比（同一次控制中心下拉动作）：

| 版本 | 日志特征 | 误缩信号/WiFi |
|---|---|---|
| v1.7.2 | `_UIStatusBarCellularSignalView 缩放前 a=1.000 → 0.600` | **10 次** |
| v1.7.3 | `跳过：无可视时间视图（timeMaxX=0）` / `跳过：非全屏 fg（宽 361 ≠ 屏宽 430）` | **0 次** |

三道门禁：
1. **只处理全屏宽度 fg**：`|fg.bounds.width − UIScreen.mainScreen.bounds.width| ≤ 1`；
2. **无基准不处理**：`timeMaxX ≤ 0.5`（无可见时间视图）直接跳过；
3. **岛几何合理性**：灵动岛左缘须落在 60~200（真岛实测 152）。

每道门禁都直写一条**去重日志**，使"为何跳过"可被核对。

### 待许总实机确认（本轮唯一未验证项）
`0.6` 缩放**已由日志确证施加**（`transform.a` 1.000→0.600，含门禁修复后的 v1.7.3），
但**视觉观感**需许总实机判断并反馈：
- 0.6 的大小是否合适（`leadScale` 可调）
- 垂直位置是否需要微调（`leadDy` 默认 0，即不额外位移）
- App 内状态栏、CC、锁屏等场景是否都正常
