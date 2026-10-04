# ScreenTimeLocker16 —— iOS 16.5.1 / RootHide 重写版

> ⚠️ **2026-10-04 11:47 重大更正（v4.4.0）**：本文早期版本判定「宿主 = ScreenTimeAgent」是**错的**。
> 实机证明 **App 限额拦截页由 SpringBoard 以远程视图呈现**，v4.3.0 里那条「绝不进 SpringBoard」的
> 安全守卫把真宿主挡在门外，导致真机 **0 命中且不留痕迹**。
> ✅ v4.4.0 已修正并在真机端到端验证通过（页面从「好 + 请求更多使用时间」→ **只剩「好」**）。
> **完整验证过程与日志见 [`ScreenTimeLocker16-实机拦截验证日志-20261004.md`](./ScreenTimeLocker16-实机拦截验证日志-20261004.md)。**
> 下文第「二、宿主判定四条证据」一节请连同本节一起阅读。

> 为许总的 iPhone 14 Pro Max（`iPhone15,3` / iOS 16.5.1 / relaxin + RootHide / arm64e）重写的
> 「屏幕使用时间 App 限额锁」。原始插件来自 `https://tweak.mario.net.in/`，
> 真名 `DisableOneMoreMinute`（2022-02-19，iOS 15 时代），在 iOS 16 上**必然崩溃**（见下文）。
>
> 本插件：**本地源码编译 → 设备端 ldid 签名 → 打包 .deb**，全流程 2026-10-04 完成并实机验证。

---

## 一、产物清单

| 文件 | 说明 |
|---|---|
| `tweak_stl/build/ScreenTimeLocker16.m` | 源码（**v4.4.0**，单文件，无外部依赖） |
| `tweak_stl/build/ScreenTimeLocker16.plist` | 注入过滤器（**二进制** plist，184 B，含 `com.apple.springboard`） |
| `tweak_stl/build/build_deploy.sh` | 编译→查符号→上传签名→**校验体积增长**→部署 |
| `tweak_stl/build/build_deb.py` | 打 `.deb`（纯 Python，手写 ar 归档；版本号从 `.m` 自动读取） |
| `tweak_stl/build/ScreenTimeLocker16_4.3.0_iphoneos-arm64e.deb` | **最终交付包（16110 B）** |
| 设备 `dpkg` 包名 | `com.xu.screentimelocker16` = `4.3.0` / `iphoneos-arm64e` |

**设备侧落地：**
- `/Library/MobileSubstrate/DynamicLibraries/ScreenTimeLocker16.dylib`（94528 B，已签名）
- `/Library/MobileSubstrate/DynamicLibraries/ScreenTimeLocker16.plist`（158 B）
- `/var/mobile/Documents/ScreenTimeLocker16_4.3.0_iphoneos-arm64e.deb`（Filza 可见，Sileo 可装）

---

## 二、关键结论：宿主进程是 ScreenTimeAgent（不是 SpringBoard）

这是整个项目的**地基**，用四条独立证据钉死：

| # | 证据 | 来源 |
|---|---|---|
| 1 | `ScreenTimeAgent` 的 Mach-O 链接了 **`UIKit`** + `ScreenTimeSettingsUI.framework` + `SpringBoardServices` | 解析 `/rootfs/System/Library/PrivateFrameworks/ScreenTimeCore.framework/ScreenTimeAgent` 的 `LC_LOAD_DYLIB` |
| 2 | 它是 `UserName=mobile` 的 **LaunchDaemon**，且是 `com.apple.ScreenTimeNotifications` 的 **通知代理**（能建 UNUserNotificationCenter） | `/rootfs/System/Library/LaunchDaemons/com.apple.ScreenTimeAgent.plist` |
| 3 | `ScreenTimeCore.framework` 的 `CFBundleIdentifier = com.apple.ScreenTimeCore`，**与插件 plist 的 `Bundles` 首项完全吻合** | framework Info.plist |
| 4 | SpringBoard 的主 bundle id 是 `com.apple.springboard`，**根本不在** plist 的三个 bundle 里 | 推论 |

**推论：** 插件**永远不会**被注入 SpringBoard。所以源码里那条「绝不进 SpringBoard / backboardd / runningboardd」的铁律属于**纯保险**（且天然不触发），可以放心保留。

**实测印证：** `[STL] loaded into ScreenTimeAgent pid=6350` / `真宿主确认 proc=ScreenTimeAgent`。

---

## 三、原始插件为什么崩（`DisableOneMoreMinute`）

原 deb 解包（`插件分析/mario_src/ex/`）：

```
Library/MobileSubstrate/DynamicLibraries/DisableOneMoreMinute.dylib  (100368 B, 通用二进制 arm64+arm64e)
Library/MobileSubstrate/DynamicLibraries/DisableOneMoreMinute.plist
```

其 plist 与我们的**完全一致**（同三个 bundle）：
`com.apple.ScreenTimeCore` / `com.apple.ScreenTimeUI` / `com.apple.ScreenTimeSettingsUI`

**崩溃实据**（`插件分析/mario_src/ScreenTimeAgent_crash.ips`，bug_type 309）：

```
EXC_BAD_ACCESS / SIGBUS   termination: SIGNAL code=10 "Bus error: 10"
栈顶:
  libobjc.A.dylib  objc_msgSend
  DisableOneMoreMinute.dylib   (偏移 14040)
  dyld  _dyld_register_func_for_add_image
  ...
  dyld  dlopen_from
  libinjector.dylib  injection_init        ← ellekit 注入阶段
```

**根因：** 它在 `_dyld_register_func_for_add_image` 回调里对 iOS 16 已改名的对象调 `objc_msgSend`。
它依赖的是 **iOS 15 的 API**：`STScreenTimeUIBundle`、`ApproveFor15MinutesButtonTitle`、
直接操作 `UIAlertController._actions` 并 `insertObject:atIndex:`。
iOS 16 已把拦截页整体重构成 **storyboard + UIButtonConfiguration + UIMenu**，
这些名字/对象全没了 → 无效指针 → SIGBUS。

> 有意思的是：原作者的**机制**（dyld 加图回调）是对的，只是**API 名字**过时了。

---

## 四、iOS 16.5.1 拦截页的真实结构（本轮逆向成果）

### 4.1 界面组成

`ScreenTimeUI.framework`（`CFBundleVersion 3.0` / `502.4.2`，`DTSDKName iphoneos16.5.internal`）：

- Storyboard：`BlockingUI-Translucent-iOS.storyboardc`（入口 `UIViewController-7h6-Wo-zjH`）、`BlockingUI-iOS.storyboardc`、`STPasscodeController.storyboardc`
- 本地化：`BlockingUI-Translucent-iOS.loctable`、`Localizable.loctable`、`STPasscodeController.loctable`
- 另有 `PlugIns/ScreenTimeNotificationContentExtension.appex`（通知内容扩展，**与本插件无关**）

### 4.2 实机 dump 出的四个按钮（`_updateButtons` 之后）

| 控件 | 标题 | 类型 | 处置 |
|---|---|---|---|
| `okButton` | 好 | `UIButton`（filled, systemBlue） | **保留** |
| `askForMoreTimeButton` | 请求更多使用时间 | `STMenuButton` | **隐藏** |
| `ignoreLimitButton` | 忽略限额 | `STMenuButton` | **隐藏** |
| `enterScreenTimePasscodeButton` | 输入屏幕使用时间密码 | `UIButton` | **保留** |

### 4.3 `STBlockingViewController` 真实方法表（96 个，节选关键）

```
绕过入口:
  _showAskForMoreTimeOptions: / _showIgnoreLimitOptions:
  _askForMoreTimeMenuProvider     @?16@0:8   ← 返回 block 的 getter（block 返回 UIMenu）
  _ignoreLimitMenuProvider        @?16@0:8   ← 同上
  _oneMoreMinuteAction / _ignoreForTodayAction / _remindMeIn15MinutesAction  @16@0:8
  _enterScreenTimePasscodeAction / _sendRequestAction                        @16@0:8
  _oneMoreMinute:                      v24@0:8@16
  _ignoreLimitForAdditionalTime:        v24@0:8d16   ← double 参数！
  _showPasscodeApprovedOptions / _hideCustomButtons / _updateButtons
其他:
  _askForTimeResource / _handleCustomButtonResponse:forAction:error:
  _didFinishEnteringScreenTimePasscode: / _updateAddContactButton
  _updateAppearanceForAskPending / _updateAppearanceWithCustomConfiguration:...
  contextMenuWillDisplayForButton: / contextMenuWillEndForButton:
  _primaryButtonConfiguration / _secondaryButtonConfiguration / fullScreenBehavior
  isChangePolicyButtonHidden / setChangePolicyButtonHidden: / isShowingPolicyOptions
  _addContact: / _customButtonPressed: / _newContact / _iCloudContainer
```

### 4.4 实机抓到的真实 UIAction 标题（中文环境）

```
再使用一分钟 (oneMoreMinuteAction)
今天忽略限额 (ignoreForTodayAction)
15分钟后提醒我 (remindMeIn15MinutesAction)      ← ignoreLimit 菜单里的第二项，同样是放行！
输入屏幕使用时间密码 (enterScreenTimePasscodeAction)
发送请求 (sendRequestAction)
```

**重要发现：** `ignoreLimitMenuProvider` 返回的菜单含两项 ——「今天忽略限额」**和**「15分钟后提醒我」。
后者会把拦截页关掉（等于白送 15 分钟），必须一并拦截。

---

## 五、实现方案

### 5.1 设计原则

1. **零链接期私有符号**：绝不在编译期引用 `STBlockingViewController` 等私有类，全部走
   `objc_getClass()` + 运行时 `class_addMethod` / `method_exchangeImplementations`。
   （v1 曾用 Category 直接挂私有类，链接期产生 `_OBJC_CLASS_$_STBlockingViewController` 硬符号，
   目标进程没这类 → `dlopen` 整体失败 → 被 ellekit **静默跳过**，极难排查。）
2. **typeEncoding 必须相等才 hook**，否则 SKIP 并打印原因（避免 ABI 不匹配崩栈）。
3. **构造函数绝不碰 UIKit**（历史事故，见 §7）。
4. **真宿主判定**：只有 `objc_getClass("STBlockingViewController")` 存在才 `gActive = YES`。
   **绝不能 dlopen 私有框架把类"硬拉进来"**，否则 `gActive` 变假阳性。

### 5.2 hook 列表（21 个，全部 OK）

```
STBlockingViewController:
  viewDidLoad / viewWillAppear:
  _showAskForMoreTimeOptions: / _showIgnoreLimitOptions:
  _ok: / _enterScreenTimePasscode:                       ← 保留，仅记日志
  _updateButtons                                          ← 主路径：隐藏两个绕过按钮
  _askForMoreTimeMenuProvider / _ignoreLimitMenuProvider   ← 过滤 UIMenu
  _oneMoreMinuteAction / _ignoreForTodayAction / _remindMeIn15MinutesAction
  _enterScreenTimePasscodeAction / _sendRequestAction
  _showPasscodeApprovedOptions / _oneMoreMinute:
  _ignoreLimitForAdditionalTime: / _hideCustomButtons
UIAlertController:
  - addAction:                                            ← 旧式弹窗兜底
UIAlertAction:
  + actionWithTitle:style:handler:                        ← 旧式弹窗兜底（类方法，注意走 object_getClass(src)）
```

### 5.3 双重保险

| 层级 | 手段 | 实测日志 |
|---|---|---|
| 按钮层 | 在 `_updateButtons` 之后把 `askForMoreTimeButton` / `ignoreLimitButton` **hidden + alpha 0 + 禁交互** | `[hook] 已隐藏绕过按钮 askForMoreTimeButton (STMenuButton)` |
| 菜单层 | 包装两个 menu provider，`menuByReplacingChildren:` 剔除黑名单项 | `[menu] 剔除菜单项 “15分钟后提醒我” (UIAction)` |
| 视图层 | 递归遍历视图树，标题命中黑名单的控件隐藏 | `[strip] <STMenuButton> title=“忽略限额” -> 禁用并隐藏` |
| Action 层 | 拦截 `_xxxAction` getter，命中则 `setEnabled:NO` | `[action] 见到 UIAction title=“再使用一分钟”` |
| 旧弹窗层 | hook `UIAlertController.addAction:` / `UIAlertAction.actionWithTitle:` | 兜底 iOS 15 式弹窗 |

### 5.4 黑名单（14 条，本地化读取 + 硬编码兜底，已去重）

```
再使用一分钟 | 批准使用15分钟 | 批准使用一小时 | 忽略限额 | 今天忽略限额 | 请求更多使用时间
15分钟后提醒我
One More Minute | Approve for 15 minutes | Approve for an hour
Ignore Limit | Ignore Limit For Today | Remind Me in 15 minutes | Remind Me in 15 Minutes
```

来源 key：`OneMoreMinuteButtonTitle` / `ApproveFor15MinutesButtonTitle` / `ApproveForHourButtonTitle` /
`IgnoreLimitButtonTitle` / `IgnoreLimitForTodayButtonTitle` / `AskForMoreTimeButtonTitle`，
经 `[NSBundle bundleForClass:STBlockingViewController] localizedStringForKey:` 取当前语言真实标题。

### 5.5 注入过滤器

```python
plistlib.dump({'Filter': {'Bundles': ['com.apple.ScreenTimeCore',
                                      'com.apple.ScreenTimeUI',
                                      'com.apple.ScreenTimeSettingsUI']}},
              open('ScreenTimeLocker16.plist','wb'), fmt=plistlib.FMT_BINARY)
```

> ⚠️ 必须是 **FMT_BINARY**。ellekit 按「磁盘上的 .plist 文件」加载 tweak，
> 不是按 Sileo 数据库 —— 手工放 dylib+plist 完全有效。

---

## 六、实机验证结果（2026-10-04 11:22–11:24）

打开 `#define STL_SELFTEST 1` 后，插件在 ScreenTimeAgent 里自建拦截页 VC 并 dump 全流程：

```
[STL] loaded into ScreenTimeAgent pid=6209
[STL] ScreenTimeLocker16 4.3.0-test 真宿主确认 proc=ScreenTimeAgent pid=6209
[STL] [probe] STBlockingViewController 自有方法 96 个:
[STL] [hook] OK  viewDidLoad / _updateButtons / _askForMoreTimeMenuProvider(@?16@0:8)
              / _ignoreLimitForAdditionalTime:(v24@0:8d16) ...   ← 21 个全部 OK，零 SKIP
[STL] [cfg] forbidden titles(14): ...
[STL] [test] 实例化拦截页 VC = <STBlockingViewController: 0x7ee01ac00>
[STL] [hook] -_hideCustomButtons 命中
[STL] [hook] -_updateButtons 命中
[STL] [hook] 已隐藏绕过按钮 askForMoreTimeButton (STMenuButton)
[STL] [hook] 已隐藏绕过按钮 ignoreLimitButton (STMenuButton)
[STL] [strip] <STMenuButton> title=“忽略限额” -> 禁用并隐藏
[STL] [strip] <STMenuButton> title=“请求更多使用时间” -> 禁用并隐藏
[STL] [menu] 剔除菜单项 “15分钟后提醒我” (UIAction)
[STL] [menu] 剔除菜单项 “今天忽略限额” (UIAction)

最终状态:
  askForMoreTimeButton ... hidden = YES; alpha = 0; userInteractionEnabled = NO
  ignoreLimitButton     ... hidden = YES; alpha = 0; userInteractionEnabled = NO
  ignoreLimitMenu 过滤后 → 子项 0（空）
  askForMoreTimeMenu 过滤后 → 子项 1 = “输入屏幕使用时间密码”（保留）
```

**崩溃检查：** 11:19 之后 CrashReporter **零新增**；ScreenTimeAgent 持续运行（PID 6350）。

---

## 七、血泪教训（务必别再犯）

### 7.1 未签名 dylib = 直接把宿主打挂

`clang` 产出物 **"code object is not signed at all"**。未签名 dylib 进 TweakInject 后，
dyld 在 `compatibleSlice` 读页时被内核以 **CODESIGNING / Invalid Page** 杀死宿主进程：

```
EXC_BAD_ACCESS / SIGKILL - CODESIGNING
termination: {code: 2, namespace: "CODESIGNING", indicator: "Invalid Page"}
栈: dyld3::MachOFile::compatibleSlice ← dyld4::JustInTimeLoader::makeJustInTimeLoaderDisk
    ← SyscallDelegate::withReadOnlyMappedFile ← dlopen_from ← libinjector injection_init
```

那一次直接打挂 **SpringBoard（黑屏，`runs=50`）+ ScreenTimeAgent**。

➜ **对策：** `build_deploy.sh` 第 3 步**强制校验签名后体积增长**（`ldid -S` 约 +950~1130 B），
不增长就 `exit 1` 拒绝部署。

```
94296 -> 95424 (+1128 B)   ✓
CodeDirectory v=20400 size=945 flags=0x0(none) hashes=24+2 location=sha256
```

### 7.2 构造函数（dyld 构造期）绝不能碰 UIKit

`__attribute__((constructor))` 里调 `[UIStoryboard storyboardWithName:]`
→ ScreenTimeAgent **卡死**（PID 存在、不崩溃、不再产出任何日志）。
必须改成安装完成后 `dispatch_after` 到**主队列**再执行。

### 7.3 `dispatch_source_t` 存局部变量会被 ARC 静默回收

`dispatch_source_t t = dispatch_source_create(...)` 出了作用域就被 release，
定时器**永不触发、无任何报错**。改用自递归 `dispatch_after`。

### 7.4 `sbreload` 会顺带打挂 MCP 服务

`ios-mcp.plist` 的 `Filter/Bundles = ['com.apple.springboard']` → 宿主就是 SpringBoard。
本插件调试期一律用 `launchctl kickstart -k system/com.apple.ScreenTimeAgent`，不要 `sbreload`。

### 7.5 App 走 `.prelib` 重打包，daemon 走 TweakInject 扫描

所以验证「新插件是否被加载」**要用 daemon（ScreenTimeAgent）当靶子**，
拿 App（如 Preferences）测会得到误导性结论。

### 7.6 沙箱让 daemon 写不了盘 → 只能靠 NSLog / syslog

`/var/mobile/Documents/`、`NSTemporaryDirectory()`、`/tmp` 全部写不进去。
`NSLog` 走 `os_log`，用 MCP `get_syslog(process:"ScreenTimeAgent")` 抓。
**注意：syslog 是「实时流」，必须让触发动作发生在捕获窗口内**；
`max_lines` 截断的是**最前面**的 N 条，所以要等启动噪声落定（≈30 s 后）再抓。

### 7.7 `.wakeups_resource.ips` 不是崩溃

`bug_type 142` 是资源日志。`stat` 是 **GNU coreutils 版** → 用 `stat -c "%s"`。

---

## 八、已知边界与后续

- **未在真实「限额触发」场景下走一遍**：本次验证是插件在宿主进程内自建拦截页 VC 并驱动
  `_updateButtons` / menu provider，**逻辑全部命中且日志可证**；但「真机上某个 App 真的用超时」
  这条端到端链路需要许总自己在「设置 → 屏幕使用时间 → App 限额」里配一条限额来触发。
  → 触发后若「好 / 输入密码」也被藏了，说明 `_updateButtons` 在该策略下走了别的分支，需要补 hook。
- **深色/浅色两套 storyboard** 未分别验证（`BlockingUI-Translucent-iOS` 与 `BlockingUI-iOS`）。
- **英文环境下**的黑名单兜底文本已备好，但未在英文语言下实测。
- 若 iOS 小版本升级导致 `STBlockingViewController` 方法表变化，`STLHook` 会打印 `SKIP` 并说明原因，
  查 `get_syslog` 即可定位，不需要重新逆向。

---

## 九、维护操作速查

```bash
# 改完源码后重新编译 + 签名 + 部署（自动校验签名）
cd /Users/xu/WorkBuddy/IOS设备处理/tweak_stl/build
./build_deploy.sh

# 重新打包 .deb
python3 build_deb.py
#  → ScreenTimeLocker16_4.3.0_iphoneos-arm64e.deb

# 让宿主重新加载插件
ssh iphone-root 'launchctl kickstart -k system/com.apple.ScreenTimeAgent'

# 抓插件日志（在捕获窗口内触发动作）
#   MCP: get_syslog(process="ScreenTimeAgent", last_seconds=8, max_lines=150)
```
