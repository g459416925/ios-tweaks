# StatusBarScale — 状态栏图标缩放

**包名** `com.xu.statusbarscale` · **版本** 2.7.0 · **宿主** 仅 SpringBoard

> v2.7.0（2026-10-18）：新增**灵动岛分裂折叠环**（移植 DuoStatusRing，MIT）。
> 灵动岛分裂成两个元素时，右侧信号/Wi-Fi/电池折成岛旁圆环；合回时展开。
> 源码 `fold/`，iOS 16 适配细节见下文 ⑤。

> v2.1.23：实时活动边框改为精确 hook `SBSystemApertureContainerView` 的 key-line，
> 移除状态栏布局中的全窗口/全图层遍历及高频 CALayer 边框、描边、阴影 hook；
> 资源库全树扫描改为启动阶段两次，消除下拉控制中心时的主线程滞后。

> v2.1.24：关闭正式版布局期诊断递归；收紧资源库搜索门禁；修复资源库 Hook
> 部分成功时停止重试的问题；key-line layer 改为弱引用直接匹配，并避免重复属性写入。

> v2.0.0 起本插件**只做状态栏缩放**：不含辅助图标条、不含设置面板、不读取任何配置文件，
> 参数全部硬编码在源码里。

## 解决什么问题

灵动岛机型（iPhone 14 Pro Max / iOS 16.5.1 实测）状态栏右侧图标与左侧时间不对齐：

| 项 | 时间 | 图标 | 差 |
|---|---|---|---|
| 墨迹高度 | 12 px | 13–14 px | 图标偏高 +1 |
| 重心 y | 29.4 | 27.7 | 图标偏高 1.66 px |

观感：图标比时间大一圈且往上飘。

## 原理

hook 私有类 `_UIStatusBarForegroundView` 的 `-layoutSubviews`（运行时 `objc_getClass`
解析，**零链接期私有符号**），在原布局完成后对命中视图施加：

```
transform = Translate(Scale(s, s), 0, dy/s)   // 绕中心缩放 s 倍 + 下移 dy pt
```

- `UIView.transform` 绕 anchorPoint（中心）变换，**不参与 frame 布局计算** → 间距、
  点击区域判定完全不受影响；
- 每次布局后重设同一 transform，幂等；灵动岛展开/收起时自动跟随。

### ① 主缩放（灵动岛右侧）

`frame.minX >= gThr(280)`（按当前屏幕逻辑宽度相对 430pt 基准动态换算） 的状态栏图标（类名含 `StatusBar`/`Battery`）整体按设备分辨率换算比例缩放；18 Pro Max 校准值 **0.9235**。

垂直下移与缩放**绑定**：`dy(s) = K·(1 − s)`，`K = dh / (1 − 0.84847)`。
锚点取自实机调定工作点（`scale=0.84847` 时 `dy=0.6687`）→ 当前 `score=0.9025`
时实际下移 **0.43pt**。「不缩就不必下移」由 `s → 1 ⇒ dy → 0` 自然满足。

实测（scale=0.92 时代）：图标高 13→12（=时间）、重心差 −1.66 → **−0.07 px**。

### ② 时间旁缩放（时间右侧、灵动岛左侧）

这批图标（实测类名 `_UIStatusBarImageView`，如闹钟/定位/录屏/麦克风）无法按标识枚举，
改为**运行时按 fg 坐标系 frame 区间发现**（时间右缘 → 岛左缘），按设备分辨率换算比例单独缩放；18 Pro Max 校准值 **0.5155**：

- 判定：非 StringView + class 含 StatusBar/Battery + 3pt ≤ 宽高且宽 < 200pt
  + `minX > timeMaxX` 且 `maxX ≤ leadLimit`（岛左缘，实测 152.0）；递归深度 3 +
  `convertRect:toView:` 换算，防深层嵌套用错坐标系
- **三道场景门禁**（实机日志暴露的误伤，必须保留）：① 只处理**全屏宽度** fg
  （CC/Spotlight 迷你状态栏宽 361/370，否则左侧信号/WiFi 被误缩）；
  ② 无可视时间（`timeMaxX = 0`）跳过；③ 灵动岛左缘须落在 60~200
- 日志确证：`[leadApply] 缩放前 a=1.000 → 后 a=0.504`

### ③ 撤销 / 复核（必须保留）

状态栏 item 视图会被系统**复用池**（`SBStatusBarReusePoolWindow`）回收后**换身份** ——
同一个 `_UIStatusBarStringView` 既当【时间】(左) 又当【电池百分比/运营商名】(右)。
右侧那份被主缩放登记后送进复用池、再被拿去渲染【时间】，就会「缩时间」
（锁屏日志实证 `a=0.848`）。故：

- 主缩放**排除 `_UIStatusBarStringView`**；
- 两张受管表（主缩放 / leading）都带撤销：脱离命中区间**连续 1.5s** 才
  「**先摘登记、再还原**」（先摘是必需的，否则 `setTransform:` hook 会立刻把值改回）；
- 判据**不用 window / hidden**（App 前台主屏 fg 会被系统摘窗），只用类名 + 尺寸 + 位置。

### ③ 资源库背景透明（v2.1.0）

App 资源库（App Library）里每个分类卡片的背景板清成透明，只留应用图标与分类标签。

hook `SBHLibraryCategoryPodBackgroundView` 的 `-layoutSubviews`，递归清子树（深度 4）：

- `MTMaterialView` / `UIVisualEffectView`（毛玻璃材质）→ `hidden = YES`
- 其余非 `UIImageView` / `UILabel` 且 `backgroundColor` 非透明的视图 → `clearColor`
- 应用图标与文字标签一律保留

实机 dump 的层级（iOS 16.5.1）：

```
_SBHLibraryPodIconListView                    (资源库滚动列表)
  _SBHLibraryPodIconView  {170×184}           (每个分类卡片)
    SBHLibraryCategoryPodBackgroundView {170×170}   ← 本 hook 的 self
    SBHLibraryCategoryPodIconListView   {170×170}   (图标层，兄弟节点，不动)
      SBHLibraryCategoryPodIconView ×4
```

- ⚠️ **勿 hook `_SBHLibraryCategoryStackViewBackgroundView`** —— 那是 **Dock 上"App 资源库"
  按钮的图标**（祖先链是 `SBFloatingDockWindow`），不是资源库页面里的卡片
- 门禁：类名必须含 `Library` ⇒ 不误伤主屏 App 文件夹或系统其它 `MTMaterialView`
- 安装时机：ctor 阶段对任意类调 `class_getInstanceMethod` 会触发 `+initialize` 而崩溃
  （v1.1.0 教训）⇒ 延迟 3s 安装 + 0.5s×40 次重试等类就绪

### ④ 资源库搜索框背景透明（v2.1.1）

顶部"App 资源库"搜索框的背景材质（`SBHSearchTextField` 内的 `MTMaterialView`）隐藏，
只留放大镜图标（`UIImageView`）与文字（`UISearchBarTextFieldLabel`）。

实机 dump（`hitTest(215,99)`）：

```
SBHSearchBar {430×147}
  SBHSSearchTextField {33,75,364,48}          ← hook/扫描目标
    MTMaterialView {0,0,364,48}               ← ★ 背景材质 → 隐藏
    UIImageView（放大镜）/ UISearchBarTextFieldLabel（"App 资源库"）→ 保留
```

- ⚠️⚠️ **搜索框是常驻视图**（随 SpringBoard 启动就在树里），进入资源库时**只改可见性、
  不重新布局** ⇒ 仅靠 `-layoutSubviews` 不够。启动阶段执行两次定向兜底扫描，后续由
  `didMoveToWindow` / `setHidden:` / `setBackgroundColor:` hook 持续维持，避免永久轮询。
- 门禁：类名含 `Search` **且** 祖先链含 `Library` ⇒ 不误伤其它搜索框

### ⑤ 灵动岛分裂折叠环（v2.7.0，移植 DuoStatusRing）

灵动岛进入 native mitosis（主岛 + 右侧小气泡，两个可见元素）时，把状态栏右侧的
信号 / Wi-Fi / 电池折叠成岛旁一个圆环：电池压成点再长成 240° 电量弧（充电绿、低电量黄、
低电量模式黄），信号变四点落在环底开口，Wi-Fi 进环心；岛合回一个时反向展开。

- 源码：`fold/`，移植自 **DuoStatusRing 1.0.1**（MIT，OwnGoal Studio），保持 DLI 前缀。
- 桥接层 `fold/SBDFold.m`：hook `_UIStatusBar`（真身）的 `layoutSubviews` /
  `_updateWithAggregatedData:` / `_updateStyleAttributes` / 两个 `setAvoidanceFrame:`，
  外加 `_UIStatusBarForegroundView -layoutSubviews` 兜底注册；全部带类型编码校验。
- ⚠️ **iOS 16 适配（与上游的三处硬差异，勿照抄上游）**
  1. 上游主 hook `SBSystemApertureViewController -_postLayoutDidChangeNotificationIfNecessary`
     与 ivar `_cachedLayoutDidChangeUserInfo` 在 16.5.1 **不存在**（dyld 缓存实证），
     改为订阅 `SBSystemApertureLayoutDidChangeNotification`，读
     `SBSystemApertureFramesKey` / `SBSystemApertureVisibleElementIdentifiersKey`。
  2. `STUIStatusBar` 在 16.5.1 是 0 方法的空壳，真身是 `_UIStatusBar`（243 方法）；
     hook 挂在 `_UIStatusBar` 上，缺失时才退回。
  3. `_UIStatusBarDisplayItem.enabled` 恒为 0（电池/信号也是），上游的 enabled 过滤会
     把图标全丢空 ⇒ 改为物理可见性（在树上 / 未隐藏 / 有尺寸）。
- ⚠️ **ReScale2 坐标**：状态栏 foreground 带 1.0232 缩放（逻辑 440pt），岛坐标必须
  `[foreground convertRect:fromView:nil]` 换算进 fg 坐标空间，否则环位置与半径都偏。
- 关闭开关：`/var/mobile/Library/com.xu.statusbarscale/fold_disabled`（存在即不安装折叠环，
  状态栏缩放不受影响）；编译期总开关 `SBD_FOLD_ENABLED`。
- 日志：`[fold] hook …` / `[fold] phase=…` / `[fold] items=…` / `[fold] attach …`（低频）。

## 参数（硬编码，v2.0.0）

| 变量 | 值 | 说明 |
|---|---|---|
| `gScale` | 0.9235 | 18 Pro Max 校准基准，运行时按渲染比例补偿 |
| `gDy` | 0.6687 | 垂直微调「锚点强度」（实际 dy 由 `sbs_dyForScale` 推算） |
| `gThr` | 280 | 430pt 基准右侧判定阈值，按当前逻辑宽度动态换算 |
| `gLeadScale` | 0.5155 | 18 Pro Max 校准基准，运行时按渲染比例补偿 |
| `gLeadDy` | 0.0 | leading 图标额外下移（默认不位移） |
| `gEnabled` | YES | 总开关 |
| `gDiag` | YES | 关键事件直写日志 |
| `gVerbose` | NO | 高频诊断日志 |

## 日志

`/var/mobile/Documents/sbs_log.txt`

- `gDiag=YES`：关键事件直写 —— `[hook]` / `[lead]` / `[leadApply]` / `[scaled]` /
  `[bind]` / `[undo]` / `[leadUndo]`
- `gVerbose=YES`：额外高频诊断（`[apply]` / 层级 dump）

## 构建

```
./build_deploy.sh     # 编译→签名→校验→打 DEB→dpkg 安装（禁止直接 cp 到 TweakInject）
python3 build_deb.py  # 只打 .deb（版本自动取自源码 #define SBS_VERSION）
```

## 实测记录

### v2.0.0（2026-10-07）—— 精简为只保留缩放

- 源码 **3839 → 794 行**：删除辅助图标条、设置面板（`src/StatusBarScalePrefs/`）、
  热重载、plist 读取；保留主缩放 + leading + 两张撤销表 + 3 个 hook
  （FG `layoutSubviews` / UIView `setTransform:` / FG `didMoveToWindow`）+ FG 子类补 hook
- 日志确证：`[hook] layoutSubviews / UIView.setTransform: / didMoveToWindow` 全装；
  `[bind] 缩放 0.9025 → 垂直微调 0.43 pt`；`[lead] 模块生效 v2.0.0`
- `[scaled]` 实证：`_UIBatteryView a=0.902`（主缩放）、`_UIStatusBarImageView a=0.504`（leading）
- `[aux]` 日志 = **0** ⇒ 辅助条彻底移除；本次 respring **零崩溃**

### v1.x（历史）

- 部署后 2 次 sbreload 全成功，`sbs_log` 0 异常，CrashReporter 无新增；
- 基线 vs 修改后 `_sb_measure.py` 对比：高度差 +1.00→−1.00、重心差 −1.66→−0.07；
- v1.5.0 起注入过滤由 `Classes=UIApplication` 收缩为 `Bundles=com.apple.springboard`；
- 部署脚本改为打包后 `dpkg -i`，确保 RootHide 完整 patch/签名流程；
- SpringBoard 冷启动时等待 `_UIStatusBarForegroundView` 注册并有限重试。

## 环境

- 越狱：relaxin + **RootHide**（无根）；注入框架 ellekit
- 架构 `iphoneos-arm64e`；宿主进程 `SpringBoard`
- ⚠️ dylib 内**绝不能出现完整 `/System/Library/...` 路径字面量**（RootHide patch 会破坏签名）
- ⚠️ 部署**必须走 `dpkg -i`**（直接 cp 到 TweakInject 会被 jbroot 不完整 patch → dyld `Invalid Page`）

### v2.6.0（2026-10-13）—— 18 Pro Max 渲染适配

- 由 `UIScreen.nativeBounds / UIScreen.bounds` 实时计算像素/点比例。
- 右侧与 leading 图标变换、撤销复核使用同一有效缩放值，避免缩放撤销判据错位。
- 主缩放右侧阈值按逻辑宽度相对 430pt 基准同比例换算。
- `[scale]` 日志记录渲染比例、有效缩放值、leading 值及动态阈值。
