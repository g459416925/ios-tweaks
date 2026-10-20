# 桌面净空 NoHomeIcons（com.xu.nohomeicons）

> iPhone 14 Pro Max · iOS 16.5.1 · RootHide + ellekit · arm64e
> 当前版本 **0.6.0**

## 功能

1. **桌面（主屏所有页）不显示任何 App 图标**，只剩壁纸、小组件、搜索
2. **Dock 保留**（`kHideDock = NO`，许总指定）
3. 所有 App 只在 **App 资源库**里出现，Spotlight 搜索、通知、后台一切照常
4. **锁定「新下载的 App = 仅 App 资源库」**：偏好键 `SBHomeAutomaticallyAddsNewApplications` 恒读成 NO，改 plist / 第三方工具也无效
5. **移除「设置 → 主屏幕」入口**：设置根列表里该项直接不显示，从根上断掉改设置的可能

## 机制（全部真机 dump 实证，非猜测）

### SpringBoard 侧

| Hook | 作用 |
|---|---|
| `SBIconModel -isIconVisible:` | 强制 NO。iOS 14+「仅 App 资源库」的原生判断入口 |
| `SBIconModel -shouldAvoidPlacingIconOnFirstPage:` | YES，新图标不放首页 |
| `SBIconListView -layoutIconsNow` | 只做观测（记录实际渲染图标数） |
| `NSUserDefaults -boolForKey:` / `-objectForKey:` | 命中 `SBHomeAutomaticallyAddsNewApplications` 时返回 NO |
| `CFPreferencesGetAppBooleanValue` / `CFPreferencesCopyAppValue` | 同上，兜住 C API 路径 |

实测签名：

```
SBIconModel -isIconVisible:                      B24@0:8@16
SBIconModel -shouldAvoidPlacingIconOnFirstPage:  B24@0:8@16
```

偏好键实测（`/var/mobile/Library/Preferences/com.apple.springboard.plist`）：

```
SBHomeAutomaticallyAddsNewApplications = 0    # 0 = 仅 App 资源库，1 = 添加到主屏幕
```

### 设置 App 侧

设置根列表**不是 plist**：它由 `/System/Library/PreferenceManifestsInternal/PreferencesManifests.bundle/PreferencesManifests`（Mach-O，34KB）在代码里生成，改文件这条路不存在，只能在 specifier 层过滤。

实测根列表（32 项）里目标条目：

```
<PSSpecifier label=HomeScreenPhone detail=DBSHomeScreenPhoneListController cell=PSLinkCell>
```

**注意它没有 `bundle` 属性**，靠 `detail` 的 `DBSHomeScreen*` 前缀识别（`bundle=HomeSettings` 那条路走不通）。

实现：

| Hook | 作用 |
|---|---|
| `PSUIPrefsListController -specifiers` | 返回前过滤掉 HomeScreen 条目 |
| `PSUIPrefsListController -reloadSpecifiers` | 原实现跑完后立刻再过滤一次（它重建 `_specifiers`，会把过滤结果冲掉） |

注入时机晚于首屏渲染，所以还要补一刀：KVC 写回 `_specifiers` + `[table reloadData]`（**不能调 `reloadSpecifiers`**，那会重建数组）。

## 实测证据（v0.6.0 启动日志）

```
[SB] [hook] OK   SBIconModel -isIconVisible:  type=B24@0:8@16
[SB] [hook] OK   NSUserDefaults -boolForKey:  type=B24@0:8@16
[SB] [hook] OK   CFPreferencesGetAppBooleanValue
[SB] [pref] 拦截 NSUserDefaults boolForKey:SBHomeAutomaticallyAddsNewApplications → NO
[SB] [stats] isIconVisible calls=332 (origVisible=326) | layout calls=13 last=2 max=3 | prefHits=5

[PREFS] [boot] rootCls=PSUIPrefsListController overridesSpecifiers=1
[PREFS] [hook] OK   PSUIPrefsListController -specifiers  type=@16@0:8
[PREFS] [hook] OK   PSUIPrefsListController -reloadSpecifiers  type=v16@0:8
[PREFS] [prefs] PSUIPrefsListController 移除 1 项（剩 31）
```

- 桌面：主屏 `icons=0`，332 次可见性判定、326 个原本可见的图标全部隐藏
- 资源库：建议 / 最近添加 / 社交 / 创意 / 工具 / 商业 分类完整
- 设置：根列表 32 → 31 项，「主屏幕」不再出现；点「显示与亮度」跳转正确（索引未错位）
- 点「添加到主屏幕」后主屏仍 0 图标

## ⚠️ 必须知道的副作用

`isIconVisible:` 返回 NO **不是纯视图过滤**：SpringBoard 会把图标真正移出 `iconLists` 并写进 `IconState.plist` 的 `ignored`。

- 桌面布局会被改写成 `iconLists = [[]]`
- 卸载插件后图标**不会自动回到桌面**（等同于手动「从主屏幕移除」）
- 恢复：用备份还原，或从资源库长按 App →「添加到主屏幕」

插件每次启动在 ctor 阶段自动备份一份：

```
/var/mobile/Documents/NoHomeIcons_IconState.backup.plist
```

## 回滚

| 目的 | 操作 |
|---|---|
| 临时停用（不卸载） | `touch /rootfs/private/var/mobile/Library/com.xu.nohomeicons/disabled` 后 respring |
| 重新启用 | `rm /rootfs/private/var/mobile/Library/com.xu.nohomeicons/disabled` 后 respring |
| 恢复桌面布局 | 停用后把备份覆盖回 `/rootfs/private/var/mobile/Library/SpringBoard/IconState.plist`（`chown mobile:mobile`, `chmod 644`），删 `DesiredIconState.plist`，`killall -9 SpringBoard` |
| 卸载 | `dpkg -r com.xu.nohomeicons` + respring |

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
```

构建链固定套路（踩过的坑）：

- `clang -arch arm64e -miphoneos-version-min=14.0 -isysroot $(xcrun --sdk iphoneos --show-sdk-path)`
- dylib 用 **`ldid -S`** 签名（codesign 签的 dylib ellekit 不注入），并校验体积增长
- 编译后必须 `nm -u` 检查无 `_OBJC_CLASS_$_SB*` 私有符号（否则 dlopen 整体失败）
- 部署只能 `dpkg -i`，禁止 root cp 直写 TweakInject（签名失效 → SIGKILL）

## 文件

| 文件 | 说明 |
|---|---|
| `NoHomeIcons16.m` | 全部源码（单文件，含 SpringBoard + 设置两套模块） |
| `NoHomeIcons16.plist` | Filter.Bundles = `com.apple.springboard`、`com.apple.Preferences` |
| `build_deploy.sh` | 编译 / 签名 / 打包 / 部署 |
| `probe-classes.txt` | v0.1.0 运行时类 dump（4957 行，方法表原始证据） |

## 排查备忘（本轮踩过的坑）

1. **只 hook 基类 `PSListController` 无效** —— 根列表真实类是 `PSUIPrefsListController` 且 override 了 `-specifiers`。必须先比对 `method_getImplementation` 确认子类真 override，否则两次 hook 同一 Method 会把 original 覆盖成自己的 hook → 递归。
2. **patch 里不能调 `reloadSpecifiers`** —— 它会重建 `_specifiers`，过滤白做。正确姿势：改 ivar + `[table reloadData]`；同时在 `-reloadSpecifiers` 之后补删一次。
3. **入口条目没有 `bundle` 属性** —— 最初按 `bundle=HomeSettings` 匹配，一条也没命中；实际靠 `detail=DBSHomeScreenPhoneListController`。
4. **`PreferencesManifests` 是 Mach-O** —— 不是 plist，没有可改的静态清单。
