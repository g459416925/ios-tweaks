# ScreenTimeLocker16 实机拦截验证日志

> ## ⚠️ 2026-10-04 12:25 重大更正（v5.1.0）
>
> 本文下方关于「**0 小时 0 分钟是 iOS 系统硬下限、UI 无法绕过**」的结论是**错误的**，已被推翻。
> 许总指出 ScreenTimeLocker 原生支持 0/0。反汇编原版 `DisableOneMoreMinute.dylib` 后确认：
> 原版 hook 了 `STAllowanceDetailListController -hasSetBudgetTime`（原版 `0x3A20: mov w0,#0x1; ret`）
> 使其恒返回 YES，于是设置页认为「时长已设定」，**0/0 时右上角「添加」不再置灰**。
> v5.1.0 已完整还原该层，并在真机验证成功。
>
> 同时更正两处：
> 1. **插件从未失效**——此前"日志 0 行"是因为读错了路径（SSH 的 `/var/mobile/Documents` 是影子目录），
>    真实日志在 `/rootfs/private/var/mobile/Documents/stl_log.txt`。
> 2. **`launchctl kickstart -k` 不是可靠的 respring 方式**（会让 SpringBoard 停在 `spawn scheduled`），
>    应改用 `sbreload`。
>
> 详见 → `ScreenTimeLocker16-v5.1-原版四层还原与实机验证-20261004.md`

- **日期**：2026-10-04
- **设备**：iPhone 14 Pro Max（`iPhone15,3`）/ iOS 16.5.1（20F75）
- **越狱**：relaxin + RootHide（jbroot `BEBDF56C479B6422`）+ ElleKit
- **插件版本**：`com.xu.screentimelocker16` **4.4.0**（arm64e）
- **结论**：✅ **真机端到端跑通**。App 限额拦截页上的全部「免费绕过」入口已被摘除，只留原生「好」。

---

## 一、本次要验证什么

此前插件只在「合成场景」里自检通过，**从未在真实拦截链路上命中过**。
本次由 AI 直接操作设备，亲手造出一个真实的 App 限额触发场景，端到端验证。

---

## 二、操作链路（逐步留痕）

| # | 操作 | 结果 |
|---|---|---|
| 1 | 设置 → 屏幕使用时间 → **App 限额** | 进入限额列表 |
| 2 | **添加限额** | 弹出类别选择 |
| 3 | 点 **社交** | 类别展开，可勾选 App |
| 4 | 勾选 **微信** | 选中 |
| 5 | 点 **下一步** | 进入时长设置页 |
| 6 | 时长滚轮设为 **0 小时 0 分钟** | ⚠️ 见下方「坑」 |
| 7 | 点右上角 **添加** | 密码框（`STPasscodeController`） |
| 8 | 输入密码 **0207** | 限额创建成功 |
| 9 | 回主屏 → 点 **微信** 图标 | 🎯 拦截页出现 |

### 坑：0 小时 0 分钟点不动「添加」

- 在 **0 小时 0 分钟** 时右上角「添加」是**灰色不可点**，点它毫无反应。
- 三轮实验排除「滚轮没被真实触摸」的可能：① 新建页直接 0/0 → 点不动；② 编辑已有限额滚到 0/0 → 被系统**夹回 1 分钟**；③ 新建页先滚到 1 再滚回 0（确保滚轮真实交互过）→ 仍然点不动。
- **判定：这是 iOS 的系统硬下限（App 限额最少 1 分钟）**，UI 层无法绕过；真要 0 时长只能直写 ScreenTimeCore 数据库。
- 本次最终设为 **1 分钟**，限额创建成功（`budget_activation_EFBE259A-8313-41F8-9B0A-CEF8CA1C5E59`，type `usage-limit`）。

---

## 三、拦截页长什么样（iOS 16.5.1 实机）

**插件生效前**（截图①）：

```
              ⏳
            时间限额
      “微信”的使用已达限额。

         [   好   ]          ← 蓝色胶囊按钮
       请求更多使用时间        ← ⚠️ 蓝色文字链，点开是免费绕过菜单
```

**插件生效后**（截图②）：

```
              ⏳
            时间限额
      “微信”的使用已达限额。

         [   好   ]          ← 只剩这一个，「请求更多使用时间」消失
```

---

## 四、插件命中日志（设备端 `/var/mobile/Documents/stl_log.txt`）

```
11:45:38.563 [SpringBoard/6702] ==============================================================
11:45:38.563 [SpringBoard/6702] ScreenTimeLocker16 4.4.0 真宿主确认 proc=SpringBoard pid=6702
11:45:38.564 [SpringBoard/6702] [hook] OK    viewDidLoad  v16@0:8
11:45:38.564 [SpringBoard/6702] [hook] OK    viewWillAppear:  v20@0:8B16
11:45:38.564 [SpringBoard/6702] [hook] OK    _updateButtons  v16@0:8
11:45:38.564 [SpringBoard/6702] [hook] OK    _askForMoreTimeMenuProvider  @?16@0:8
11:45:38.564 [SpringBoard/6702] [hook] OK    _ignoreLimitMenuProvider  @?16@0:8
   ……（共 21 个 hook，全部 OK，无一 SKIP）……
11:45:38.566 [SpringBoard/6702] [cfg] forbidden titles(14): 再使用一分钟 | 批准使用15分钟 | …| 15分钟后提醒我 | Remind Me in 15 minutes
11:45:38.566 [SpringBoard/6702] 初始化完成

── 点微信图标触发拦截页 ——

11:46:05.356 [SpringBoard/6702] [hook] STBlockingViewController -viewDidLoad
11:46:05.356 [SpringBoard/6702] [strip] <STMenuButton> title=“忽略限额” -> 禁用并隐藏
11:46:05.356 [SpringBoard/6702] [strip] <STMenuButton> title=“请求更多使用时间” -> 禁用并隐藏
11:46:05.356 [SpringBoard/6702] [hook] -_hideCustomButtons 命中
11:46:05.356 [SpringBoard/6702] [hook] -_updateButtons 命中
11:46:05.356 [SpringBoard/6702] [hook] 已隐藏绕过按钮 askForMoreTimeButton (STMenuButton)
11:46:05.357 [SpringBoard/6702] [hook] 已隐藏绕过按钮 ignoreLimitButton (STMenuButton)
11:46:05.359 [SpringBoard/6702] [hook] STBlockingViewController -viewWillAppear:
```

同一场景再触发一次（11:46:56）表现一致 —— 稳定命中，非偶然。

**关键点**：
- `_ok:`（「好」）**0 次命中** → 插件完全没碰原生「好」按钮。
- 全程无 `nil` / `异常` / `失败` 记录。

---

## 五、本次排障：为什么之前一直 0 命中

### 症状
限额已建、微信已超时，但拦截页上什么也没变，日志里连一行 `[STL]` 都没有。

### 逐步定位

| 步骤 | 探针 | 得到的事实 |
|---|---|---|
| 1 | `launchctl list \| grep ScreenTime` | `ScreenTimeAgent=6350`、`SpringBoard=5829`、`UIKitApplication:com.apple.Spotlight=6406` |
| 2 | 插件日志 | 唯一注入记录是 `Spotlight/6406`，**不是** SpringBoard 也不是 ScreenTimeAgent |
| 3 | 拦截页出现后立刻看日志 | **零新增** → 呈现页面的进程不是被注入的那个 |
| 4 | `get_element_at_point(215,822)` | 元素 `id=pid:6521\|ctx:2012533904`，`bundleId=com.tencent.xin`，`visible_point=(-1,-1)` → 典型**远程视图**特征 |
| 5 | `ls ScreenTimeUI.framework` | 有 `BlockingUI-iOS.loctable` → 拦截页 UI 归属该框架 |
| 6 | 读源码 | 🔥 **第 750-756 行有一条我自己写的守卫：`if (proc == "SpringBoard") return;`** ——把真正的宿主挡在门外，且 `return` 在日志之前，所以连一行痕迹都不留 |

### 根因
> **宿主就是 SpringBoard**（iOS 16.5.1 用远程视图把 `STBlockingViewController` 呈现进目标 App 的场景）。
> 而 v4.3.0 出于「怕 SpringBoard 崩会黑屏」的安全考虑写死了「绝不进 SpringBoard」——
> 结果是把宿主拒之门外，真机 0 命中。

顺带纠正：`get_frontmost_app(debug)` / `get_element_at_point` 里出现的 `pid:5829` **是 ios-mcp 自己的宿主进程（SpringBoard）**，属解析器噪声，不能当宿主证据用。

---

## 六、v4.4.0 的三处修改

1. **解除 SpringBoard 守卫**：只保留 `backboardd` / `runningboardd` 两个真正底层进程的黑名单。
2. **过滤器补 `com.apple.springboard`**（`ScreenTimeLocker16.plist`），并保留原三个 ScreenTime bundle。
3. **注入时机三重保险**（SpringBoard 是懒加载 `ScreenTimeUI` 的）：
   - ① 启动时类已在 → 立即装；
   - ② `_dyld_register_func_for_add_image` 回调 —— 框架被 dlopen 的**毫秒级**捕获（回调内只做「判断 + 异步派发」，绝不碰 ObjC/UIKit，否则复现 mario 原插件的 SIGBUS）；
   - ③ 每 3 秒轮询，**不设上限**，装上即停。

另加：**载入即落盘**（`[载入] v4.4.0 proc=… pid=…`），这样"哪个进程被注入"一眼可见——本次就是靠它才敢确认 SpringBoard 真的进去了。

### 又一次踩到的坑（记下来）
本次部署后第一版 v4.4.0 用 `sbreload` 重载 → **SpringBoard 被杀了没自动起来**（`launchctl list` 里 PID 显示 `-`），整机黑屏、MCP 断线。
自检：CrashReporter 里**没有**对应的 SpringBoard 崩溃报告（唯一那份是 11:00 的旧 CODESIGNING 事故），所以不是插件打挂的，是 sbreload 之后没被拉起。
✅ **恢复方式**：`launchctl kickstart -k user/foreground/com.apple.SpringBoard`（8 秒内 SpringBoard 复活，MCP 自动回线）。
👉 **今后重载 SpringBoard 一律用 kickstart，不用 sbreload。**

---

## 七、产物

| 文件 | 说明 |
|---|---|
| `tweak_stl/build/ScreenTimeLocker16.m` | v4.4.0 源码 |
| `tweak_stl/build/ScreenTimeLocker16.plist` | 过滤器（184 B，含 `com.apple.springboard`） |
| `tweak_stl/build/ScreenTimeLocker16.signed.dylib` | 已签名产物（95056 B，CodeDirectory v=20400 hashes=23+2） |
| `tweak_stl/build/ScreenTimeLocker16_4.4.0_iphoneos-arm64e.deb` | 正式安装包（16510 B） |
| 设备 `/Library/MobileSubstrate/DynamicLibraries/` | dylib + plist 已落地 |
| `dpkg -l \| grep screentimelocker` | `ii com.xu.screentimelocker16 4.4.0 iphoneos-arm64e` |

---

## 八、遗留 / 待确认

1. **「好」按钮的合成点击打不中**：MCP 的 `tap_screen`/`tap_element` 对 SpringBoard 远程视图上的按钮无效（`_ok:` 命中数 0），但 **Home 键可正常退出**，页面不会卡死。需许总用手指实测一次「好」。
2. **绕过与合法出口的取舍**：当前把「请求更多使用时间」整条按钮也藏了 → 微信在限额期内**完全无法解锁**（连输密码都不行，要等次日重置）。
   代码注释里写的设计目标其实是「只保留『好』与『输入屏幕使用时间密码』」，两者目前不一致，等许总定夺。
   - 方案 A（现状）：全锁，最狠，但工作群也进不去。
   - 方案 B：保留「请求更多使用时间」按钮，只把它的菜单过滤成仅剩「输入屏幕使用时间密码」→ 保留密码出口。
3. 本次限额是「微信 每天 1 分钟」，验证完建议删掉，否则影响正常使用
   （限额 → 删除限额 → 确认弹窗「你确定要删除此限额吗？」→ 再点「删除限额」）。
