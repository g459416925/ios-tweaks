# 桌面净空 NoHomeIcons（com.xu.nohomeicons）

> iPhone 14 Pro Max · iOS 16.5.1 · RootHide + ellekit · arm64e
> 当前版本 **0.7.1**

## 功能

1. **桌面（主屏所有页）不显示任何 App 图标**，只剩壁纸、小组件、搜索
2. **Dock 保留**（`kHideDock = NO`，许总指定）
3. 所有 App 只在 **App 资源库**里出现，Spotlight 搜索、通知、**多任务后台**一切照常
4. **锁定「新下载的 App = 仅 App 资源库」**：偏好键 `SBHomeAutomaticallyAddsNewApplications` 恒读成 NO，改 plist / 第三方工具也无效
5. **移除「设置 → 主屏幕」入口**：设置根列表里该项直接不显示，从根上断掉改设置的可能
6. **不写 IconState**：纯视图层隐藏，卸载/停用插件后桌面图标立刻回来

## ⚠️ v0.6.0 事故：不能用 `isIconVisible:`

0.6.0 走的是 `SBIconModel -isIconVisible:` 恒 NO（iOS 14+「仅 App 资源库」的 model 层入口）。桌面确实空了，但**把多任务一起废了**：

```
症状：上滑 App Switcher 永远只剩 1 个卡片
证据：/var/mobile/Library/SpringBoard/RecentAppLayouts.pb.lzfse 停在 12 字节
      开 Safari + 微信（进程 6 个）后仍然是 12 字节，一条都不累积
对照：卸掉插件后同样操作，12 → 291 → 401 字节，卡片正常
原因：SBRecentAppLayouts 记录 App 时同样查 isIconVisible:
      → 全返回 NO 等于告诉系统「这些 App 不该出现在界面」
      → 后台卡片全部被拒收
```

**结论：`isIconVisible:` 是会连坐多任务 / 界面的全局可见性判断，不能拿来当"隐藏桌面图标"用。**

## 机制（v0.7.1，全部真机实证）

### SpringBoard 侧：纯视图层

| Hook | 作用 |
|---|---|
| `SBIconListView -layoutIconsNow` | 布局完成后隐藏本列表内的图标视图 |
| `SBIconListView -layoutSubviews` | 兜底：翻页 / 拖动 / 复用时可能重新显示，再压一次 |
| `NSUserDefaults -boolForKey:` / `-objectForKey:` | 命中 `SBHomeAutomaticallyAddsNewApplications` 时返回 NO |
| `CFPreferencesGetAppBooleanValue` / `CFPreferencesCopyAppValue` | 同上，兜住 C API 路径 |

隐藏动作（对每个图标）：

```objc
view.alpha = 0;                    // 视觉消失
view.userInteractionEnabled = NO;  // 不可点击
view.accessibilityElementsHidden = YES;
```

Dock 判定：类名含 `Dock`（`SBDockIconListView` / `SBDockSuggestionsIconListView` / `SBFloatingDockIconListView`）直接跳过 → Dock 完整保留。

**关键 API 差异（v0.7.0 踩过）**：`SBIconListView -icons` 返回的是 **`SBIcon` 模型对象**，不是视图。要对视图操作必须走 `-iconViewForIcon:` 拿 `SBIconView`。v0.7.0 把 `alpha` 设到了数据对象上，`hiddenViews=0`，界面毫无变化。

### 设置 App 侧

设置根列表**不是 plist**：由 `/System/Library/PreferenceManifestsInternal/PreferencesManifests.bundle/PreferencesManifests`（Mach-O，34KB）在代码里生成，只能运行时过滤。

实测根列表（32 项）里目标条目：

```
<PSSpecifier label=HomeScreenPhone detail=DBSHomeScreenPhoneListController cell=PSLinkCell>
```

**它没有 `bundle` 属性**，靠 `detail` 的 `DBSHomeScreen*` 前缀识别（按 `bundle=HomeSettings` 匹配一条都命中不了）。

| Hook | 作用 |
|---|---|
| `PSUIPrefsListController -specifiers` | 返回前过滤掉 HomeScreen 条目 |
| `PSUIPrefsListController -reloadSpecifiers` | 原实现跑完后立刻再过滤一次（它重建 `_specifiers`） |

注入时机晚于首屏渲染，所以还要补一刀：KVC 写回 `_specifiers` + `[table reloadData]`（**不能调 `reloadSpecifiers`**，那会重建数组）。

偏好键实测（`/var/mobile/Library/Preferences/com.apple.springboard.plist`）：

```
SBHomeAutomaticallyAddsNewApplications = 0    # 0 = 仅 App 资源库，1 = 添加到主屏幕
```

## 实测证据（v0.7.1）

```
[SB] [hook] OK   SBIconListView -layoutIconsNow  type=v16@0:8
[SB] [hook] OK   SBIconListView -layoutSubviews  type=v16@0:8
[SB] [hook] OK   NSUserDefaults -boolForKey:  type=B24@0:8@16
[SB] [hook] OK   CFPreferencesGetAppBooleanValue
[SB] [layout] #1 SBIconListView iconViews=1
[SB] [stats] layout calls=1 last=1 hiddenViews=1 | prefHits=5     ← 测试布局里塞了 1 个图标，被隐藏

[PREFS] [boot] rootCls=PSUIPrefsListController overridesSpecifiers=1
[PREFS] [hook] OK   PSUIPrefsListController -specifiers  type=@16@0:8
[PREFS] [hook] OK   PSUIPrefsListController -reloadSpecifiers  type=v16@0:8
[PREFS] [prefs] PSUIPrefsListController 移除 1 项（剩 31）
```

验证清单：

- **桌面**：手工把 `com.ss.iphone.ugc.Aweme` 写进 `iconLists[0]` 再 respring → 界面看不到图标，`hiddenViews=1`
- **Dock**：6 个图标完整，不含被隐藏项
- **多任务**：`RecentAppLayouts.pb.lzfse` 12 → 291 → 401 字节，正常累积
- **资源库**：建议 / 最近添加 / 社交 / 创意 / 工具 / 商业 分类完整
- **设置**：根列表 32 → 31 项，「主屏幕」不再出现；点「显示与亮度」跳转正确

## 关于布局与备份

v0.7.1 起**不再改写 `IconState.plist`**，桌面布局原样保留（图标只是不可见），停用/卸载即恢复。

历史备份（0.6.0 期间造成过真实清空，记录在此备查）：

```
/var/mobile/Documents/NoHomeIcons_IconState.backup.plist
```

如果曾被 0.6.0 清空过桌面，恢复方式：停用插件 → 把备份覆盖回
`/rootfs/private/var/mobile/Library/SpringBoard/IconState.plist`（`chown mobile:mobile`, `chmod 644`）→ 删 `DesiredIconState.plist` → `killall -9 SpringBoard`。

## 回滚

| 目的 | 操作 |
|---|---|
| 临时停用（不卸载） | `touch /rootfs/private/var/mobile/Library/com.xu.nohomeicons/disabled` 后 respring |
| 重新启用 | `rm /rootfs/private/var/mobile/Library/com.xu.nohomeicons/disabled` 后 respring |
| 卸载 | `dpkg -r com.xu.nohomeicons` + respring（图标立刻回来，布局本就未改） |

> 开关路径的两个视图别搞混：SpringBoard 读真系统路径（`/rootfs/private/var/mobile/...`），
> 而 `ssh iphone-root` 的 `/var/mobile/...` 属于 jbroot 视图，写那边等于没写。

## 日志

```
/var/mobile/Documents/NoHomeIcons.log
```

SpringBoard 段前缀 `[SB]`，设置 App 段前缀 `[PREFS]`。

## 构建 / 部署

```bash
./build_deploy.sh build     # 只编译
./build_deploy.sh pkg       # 编译 + 签名 + 设备上组装 deb
./build_deploy.sh install   # 编译 + 打包 + dpkg 安装 + sbreload

python3 build_deb_local.py  # 设备离线时：Mac 本地 ldid + 手写 ar 打包
```

构建链固定套路（踩过的坑）：

- `clang -arch arm64e -miphoneos-version-min=14.0 -isysroot $(xcrun --sdk iphoneos --show-sdk-path)`
- dylib 用 **`ldid -S`** 签名（codesign 签的 dylib ellekit 不注入），并校验体积增长
- 编译后必须 `nm -u` 检查无 `_OBJC_CLASS_$_SB*` 私有符号（否则 dlopen 整体失败）
- 部署只能 `dpkg -i`，禁止 root cp 直写 TweakInject（签名失效 → SIGKILL）

## 文件

| 文件 | 说明 |
|---|---|
| `NoHomeIcons16.m` | 全部源码（单文件，SpringBoard + 设置两套模块） |
| `NoHomeIcons16.plist` | Filter.Bundles = `com.apple.springboard`、`com.apple.Preferences` |
| `control` | control 模板（`__VERSION__`），两个打包脚本共用 |
| `build_deploy.sh` | 设备在线时的编译 / 签名 / 打包 / 部署 |
| `build_deb_local.py` | 设备离线时的本地打包 |
| `probe-classes.txt` | v0.1.0 运行时类 dump（4957 行，方法表原始证据） |

## 排查备忘（踩过的坑）

1. **`isIconVisible:` 会连坐多任务** —— 它不只是桌面可见性，`SBRecentAppLayouts` 也查它。全返回 NO → App Switcher 只剩 1 个卡片。
2. **`SBIconListView -icons` 返回模型不是视图** —— 要操作视图必须 `-iconViewForIcon:`。
3. **只 hook 基类 `PSListController` 无效** —— 根列表真实类是 `PSUIPrefsListController` 且 override 了 `-specifiers`。必须先比对 `method_getImplementation` 确认子类真 override，否则两次 hook 同一 Method 会把 original 覆盖成自己的 hook → 递归。
4. **patch 里不能调 `reloadSpecifiers`** —— 它会重建 `_specifiers`，过滤白做。正确姿势：改 ivar + `[table reloadData]`；同时在 `-reloadSpecifiers` 之后补删一次。
5. **入口条目没有 `bundle` 属性** —— 靠 `detail=DBSHomeScreenPhoneListController` 识别。
6. **`PreferencesManifests` 是 Mach-O** —— 不是 plist，没有可改的静态清单。

## 诊断速查

| 现象 | 先看 |
|---|---|
| 后台卡片只剩一个 | `RecentAppLayouts.pb.lzfse` 体积（232B≈1 条，400B+ 正常）+ `launchctl list \| grep -c UIKitApplication` |
| 桌面图标没消失 | 日志里 `hiddenViews` 是否为 0（进了 Dock 分支，或 `icons` 拿到的是模型对象） |
