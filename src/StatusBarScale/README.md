# StatusBarScale — 状态栏图标缩放对齐

**包名** `com.xu.statusbarscale` · **版本** 1.8.11 · **宿主** 仅 SpringBoard

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
| `auxBaseSize` | float | 17.0 | ⭐v1.8 系统原图标点尺寸基准 |
| `auxScale` | float | 0.4 | ⭐v1.8 辅助条图标缩放（许总指定 0.4 → 6.8pt） |
| `auxGap` | float | 3.0 | ⭐v1.8 图标间距（pt） |
| `auxDebug` | bool | NO | ⭐v1.8 红底描边调试（直观判定"条是否在屏上"） |
| `auxIcons` | array | 见下 | 辅助图标标识集合 |

默认 `auxIcons`（只放系统**不**显示的）：
`alarm` `quietMode` `rotationLock` `location` `vpn` `bluetooth` `airplane`
——其中 `location` 会在系统自己画出定位箭头时由**信号源**实时剔除。

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

---

## v1.8.x — 辅助条「只放系统不显示的」+ 0.4× + 岛下方居中 + **信号驱动去重**

### 需求（许总 2026-10-05）
1. 只收集**系统不显示**在灵动岛左右的图标（不得与系统重复）；
2. 图标缩到 **0.4×**（基准 = 系统原图标 ~17pt → 6.8pt）；
3. 位置 = 灵动岛正下方、屏幕水平居中；
4. 除锁屏外，所有界面（含 App 内）都随时间一起显示。

### ⭐⭐ 去重机制的演进（本节是重点）

| 版本 | 判据 | 结果 |
|---|---|---|
| v1.8.0 | 扫描 fg 内图标的 `accessibilityIdentifier` 精确名比对 | ❌ 标识名会变（`location.fill` ↔ `location.circle.fill`）→ 落空 |
| v1.8.0 | 加关键词包含 + 抑制表 + **缺席计数 3 次回收** | ❌ 扫描是**时序快照**：某轮没采到就撤销抑制 → 真机**定位图标重复** |
| v1.8.1/2 | hook `viewForIdentifier:` 当信号 | ❌ 本固件**零回调** |
| v1.8.2 | hook `_updateDisplayedItemsWithData:…` 读 `_items` | ❌ `_UIStatusBarItem` 只有 4 个 ivar、**没有 view**；其 `_displayItems` 全是预建视图（`frame 0×0 / win=nil / en=0`）→ 区分不出显示与否 |
| **v1.8.6** | **fg 视图树增删事件 + 数据更新事件 + 每秒巡检 → 实时重算** | ✅ **<5ms 收敛，三场景实测无重复** |
| **v1.8.11** | **读状态栏自己的 item 模型**：`_UIStatusBar._items` → 每项 `_displayItems[]._view` 的实时挂载状态 | ✅ **与字形名彻底解耦；视图树扫描降级为纯日志核对** |

**最终信号源（v1.8.11，许总「不应按图标名判断」的落地）**：

1. **主判据 = item 级状态信号**（不看名字）：
   遍历 `_UIStatusBar._items`，item **类名**即结构身份
   （`_UIStatusBarIndicatorLocationItem` → `location`，7 个候选类名均已实测确认），
   再看该项 `_displayItems[]._view` 是否**已挂载**（`superview`/`window` 非空、未隐藏、alpha>0）
   ⇒ 系统正在显示它。
   > ⚠️ `_items` 的类型**不稳定**：启动瞬间是 `__NSArrayI`，运行期变 `__NSMutableDictionary`
   > （key=`_UIStatusBarIdentifier`，value=`_UIStatusBarItem`）——两种形态都必须接
   > （v1.8.8 首版只判数组 → 全部落空成 `(noItems)`，item 信号一次都没生效）。
   > ⚠️ 「宽>0.5」**不能**写进判据：过渡帧视图已挂载但 `frame` 仍为 0
   > （实测 `location=0{v=1(sup)但hidden/alpha}`），会判成"没显示"→ 闪一下的重复。
   > 已挂载本身即充分判据 + **1.2s 宽限**兜住假阴性。
2. **纯日志交叉核对**（不参与判定）：`sbs_rescanFG` 扫 fg 子树的
   `image.accessibilityIdentifier`，只打印对比用。
3. **纯加性兜底**：像素指纹（同一位图本轮出现在系统树）。
4. **触发时机仍是变化信号**：hook `_UIStatusBarForegroundView` 的
   `addSubview:` / `insertSubview:atIndex:` / `willRemoveSubview:` +
   `_UIStatusBar._updateDisplayedItemsWithData:styleAttributes:extraAnimations:`
   → 任一事件触发重算。

**触发（v1.8.6 起保留）**：事件到达瞬间视图 `frame` 还是 `0×0` → 采用**两段式**
（立即 + 0.25s 后各一次）＋ 布局完成后同步巡检，才能稳定采到标识名。

### ⭐⭐ 日志不忠实（v1.8.11 修，直接导致"按日志修复"无从下手）

`条显示 / 条隐藏 / 效果核对` 原用 `sbs_auxLogOnce` —— 那是**进程内永久去重集**
（`sbs_auxSeen()` 只增不减）：
- `条显示` 的 key 含「宿主窗 + 可见集 + 颜色 + 尺寸」，**同组合只记一次**；
- `条隐藏` 的 key 固定为 `"empty"`，**一个 SB 进程只记一条**。

⇒ 11:15:00 之后再无「条显示」，**并不能证明条没显示，只证明组合没变**。
修法：改用 `sbs_auxLogState` —— **任何状态跃迁必留痕** + 同类目 **20s 心跳**兜底
（可证明"此刻仍是这个状态"）。

### ⭐⭐ 宿主 ping-pong（v1.8.11 修，条"时隐时现"的真凶）

日志实证（11:25:20~23）：主屏上**同时存在两个活 fg** —— `UIStatusBarWindow` 与
`SBMainSwitcherWindow`，二者各以 ~1s 节奏各自走布局 → 单例 `gStrip` 被**来回搬家**
→ `条显示 宿主窗=` 在两条日志间交替 ⇒ 条有近一半时间挂在非当前显示的那个状态栏上。
修法：主/次宿主仲裁 —— `UIStatusBarWindow` 的 fg 只要存活就让 MainSwitcher 让位
（App 前台时主屏 fg 被摘窗 → 自然放行，App 内继续由 MainSwitcher 承载）。

### ⭐ 血泪坑（四条，都在本轮踩到）

1. **非对象 ivar 绝不能 `object_getIvar`**：`_UIStatusBarDisplayItem` 有 32 个 ivar
   （`_alpha(d)` `_enabled(B)` `_centerOffset(d)`…），把它们当对象 `objc_retain`
   → `EXC_BAD_ACCESS @0x3000000000000000` → **SpringBoard SIGSEGV**。
   读 ivar 前必须判 `type_encoding[0] == '@'`，或干脆只用 KVC。
2. **异步 block 绝不要捕获状态栏视图**（v1.8.7 修复）：早期把 `(UIView *)self`
   传进 `dispatch_async` → block 捕获 fg 并 `objc_retain`；而
   `willRemoveSubview:` **会在 fg 自身销毁 / 被复用池回收的过程中触发**
   → retain 将死对象 → `EXC_BAD_ACCESS@0x20` → SpringBoard SIGSEGV（11:11 连崩两次
   → ellekit 写安全模式标记 → 插件全停）。
   修法：block 只捕获**字符串原因**，执行时从全局强引用 `gActiveFG` 现取 fg，
   并校验 `fg.window && !fg.isHidden`。**代价是零，可靠性是全部。**
3. **ellekit 安全模式标记在 `/var/mobile/.eksafemode`**，**不是**
   `/rootfs/private/var/mobile/.eksafemode` —— 后者不存在，删了等于没删，
   插件会一直不注入（表现为"日志一个字节都没有"）。删对路径 + `sbreload` 即恢复。
4. **判据别写死容器的类型 / 别要求过渡帧的几何**（v1.8.8→1.8.11 两连坑）：
   `_UIStatusBar._items` 启动瞬间是数组、运行期是字典；`_view` 在过渡帧
   「已挂载但 `frame=0` / 临时 `hidden`」。凡是把这两点写死进判据的做法，
   都会得到"要么全落空、要么闪一下"的结果。**认结构身份 + 认挂载状态，不认类型/尺寸。**

### ⭐ 方法论：日志必须先忠实，才谈得上"按日志修复"

许总铁律「日志先行」的前提是**日志本身不能骗人**。本轮真正的第一性缺陷不是判定逻辑，
而是 `sbs_auxLogOnce` 的**永久去重**让关键状态"只记一次"。任何"状态类"日志都应当是
**跃迁即记 + 心跳兜底**，而不是 once。

### 实机验证（2026-10-05 11:08–11:11，SpringBoard pid 29804/29638）

```
11:08:54.073 [aux] 巡检layout 可见图标标识名=location.fill 候选命中=location 健康=1
11:08:54.073 [aux] 【信号】系统正在显示=location ｜ 触发=layout 本次+[location]
11:08:54.073 [aux] 图标显隐 location hidden=1（entry激活=1 被系统显示抑制=1）   ← 真去重
11:08:54.075 [aux] 条显示 可见=rotationlock 边长=6.80pt 起点=(211.6,49.5)
11:08:54.075 [aux] 效果核对 条hidden=0 图标hidden[alarm=1 quietMode=1 rotationLock=0 location=1 vpn=1 bluetooth=1 airplane=1]
```

| 场景 | 结果 |
|---|---|
| 主屏 | 时钟右侧 = 系统自己的定位箭头；岛下方只有闹钟+方向锁定 → **不重复** ✅ |
| App 内（计算器，纯黑底） | 条显示、图标为白色可读、不重复 ✅（`宿主窗=SBMainSwitcherWindow 颜色=白`） |
| 锁屏 | 条隐藏 ✅ |

### 实机验证（2026-10-05 11:24–11:27，v1.8.11，SpringBoard pid 30270 / 30412）

item 级信号生效（**没有再读图标名做判定**）：

```
11:27:00.021 [aux] 系统侧比对 airplane：item信号=0(即时0/宽限0) 指纹=0 ｜ 名扫描=0（仅核对，不判定）
                   ｜ item集=[rotationlock=0{-} vpn=0{-} bluetooth=0{-} quietmode=0{-}
                              location=1{sup=_UIStatusBarForegroundView win=UIStatusBarWindow
                                         f={{98.07, 24.13}, {10.20, 10.40}}}
                              alarm=0{-} airplane=0{-}] 名集=location ⇒ 系统已显示:0
11:27:05.199 [aux] 系统侧比对 location：item信号=1(即时0/宽限1) … ⇒ 系统已显示:1   ← 宽限兜住过渡假阴性
```

- `location=1{sup=… win=UIStatusBarWindow f=非零}`：定位项的 `_view` 真的挂在状态栏上
  ⇒ 系统在显示 → 辅助条剔除。**与 `location.fill`/`location.circle.fill` 无关。**
- `alarm=0{-}` / `rotationlock=0{-}`：这两项**根本没有 `_view`** ⇒ 系统没显示
  ⇒ 辅助条收下它们（正是需求）。
- 宿主仲裁（ping-pong 消失）：
  `宿主仲裁：MainSwitcher fg(0x832a38960) 让位于存活的 UIStatusBarWindow fg(0x832a234f0)`，
  `条显示 宿主窗=` 全部为 `UIStatusBarWindow`（此前为两窗交替）。
- 日志忠实性：80 KB 日志里 `条显示/条隐藏` 仅 4 条（跃迁 + 20s 心跳），
  无 ping-pong 噪声；`exc`/`deny` 计数 0；无新 `.ips`，无 `.eksafemode`。
