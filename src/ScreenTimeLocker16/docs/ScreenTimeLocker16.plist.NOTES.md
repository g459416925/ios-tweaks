# ScreenTimeLocker16 注入过滤收窄 —— 根因与证据（2026-10-05）

## 结论
`Filter.Bundles` **不能写框架级 bundle id**。ellekit 是拿**进程内已加载的全部 bundle**去匹配的，
不是只比"本进程自己的 bundle id"。写了框架 id 就等于"任何加载该框架的进程都注入"。

## 旧名单（v5.2.0，已废弃）
```
com.apple.springboard
com.apple.Preferences
com.apple.ScreenTimeCore          ← 框架 id ← 元凶
com.apple.ScreenTimeUI            ← 框架 id ← 元凶
com.apple.ScreenTimeSettingsUI    ← 框架 id ← 元凶
```

## 实机证据（2026-10-05，全部来自插件自写日志，非推测）
| 证据 | 内容 |
|---|---|
| 被注入进程数 | **36**（28 个 App 容器 + 8 个 PluginKit 扩展） |
| 名单外进程举例 | WeChat、Aweme(抖音)、Twitter、Telegram、Siri、Health、MobileSMS、MobileMail、PosterBoard、InCallService、StoreKitUIService、Authenticator、LizhiFM、ColorfulCloudsPro、CPUDasher、NorthStatus、Runner、MediaRemoteUI、PassbookUIService、ScreenTimeUnlock、SleepLockScreen、Photos*/WeatherPoster/Books*/Sleep*/ProductPage* 扩展 |
| 证据来源 | 每个容器 `tmp/stl_log.txt` 里的 `[载入] v5.2.0 proc=<进程名> pid=<pid>`（构造期强制落盘） |
| **判定性证据** | **36/36** 个被注入进程的日志里都有 `[①数据层] 真宿主` 行；该行只在 `objc_getClass("STManagementState")` 非空时才打印 ⇒ 36 个进程**全部**真的加载了 ScreenTimeCore ⇒ 它们正是"加载框架"而非"名单命中" |
| 反面例证 | StatusBarScale 名单只有 `com.apple.springboard`（应用级 id）⇒ 从未越界；GPSTravellerTweakProX 名单含 `com.apple.UIKit`（框架 id）⇒ 越界最广（同一机制） |

## 危害
- 在非宿主进程里装 hook（Aweme/PosterBoard/InCallService 日志里都有 `初始化完成`），
  每个进程还起 3s/15s 轮询定时器。
- 与 `suggestd` 两次堆损坏崩溃（`_PASMemoryHeavyOperationLock-Low` → `_szone_free`）
  的时间线一致：suggestd 也加载 ScreenTimeCore ⇒ 旧名单必然注入它。

## 新名单（v5.2.1）
```
com.apple.springboard    # ①②③④ 层宿主（实测 proc=SpringBoard 全装）
com.apple.Preferences    # ②设置页宿主（STAllowanceDetailListController）
com.apple.Spotlight      # 实测 proc=Spotlight 亦装 ①③④，保留覆盖
```
框架（ScreenTimeCore/UI/SettingsUI）会随宿主进程一起进来，**不需要**写进名单。

## 回滚
旧 plist 备份：`build/ScreenTimeLocker16.plist.bak-bplist-5bundles`
设备侧备份：`/usr/lib/TweakInject/ScreenTimeLocker16.plist.bak-v520`
