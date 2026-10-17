# ScreenTimeLocker16 — 限额绕过漏洞 & 深度拦截需求分析

> 日期：2026-10-12 · 报告人：Byte
> 触发场景：**ChevronV3 主面板点击"已达限额"的 App → 绕过限制直接打开**
> 用途：供在 ScreenTimeLocker16 上实施"深度拦截"（第 ⑤ 层）使用

---

## 0. 一句话结论

**这不是 STL 的既有 bug，而是 STL 从未拥有的能力缺口。**

STL 目前是"**拦截页出现之后**"的增强层（禁免费绕过 + Face ID），它不管"要不要拦"；
而系统的"拦"目前只被证实覆盖系统自带入口（主屏图标），**不覆盖"直连启动 API"的路径**。
Chevron 面板恰好走的就是直连 API：`[LSApplicationWorkspace openApplicationWithBundleID:]`。

→ 要做"深度拦截"，需新增 **第 ⑤ 层：启动拦截**（在非系统路径上复刻系统的"拦停 + 呈现拦截页"）。

> ⚠️ 状态说明：面板绕过目前是**用户实机报告**（本报告成稿时未做操作复现留档）；
> 系统机制部分均为已实证（见 §1.2）。

---

## 1. 事实链（全部有证据）

### 1.1 Chevron 面板路径（为什么能绕过）

| 项 | 内容 | 证据 |
|---|---|---|
| 入口 | `-[CV3Window launchApp:]`（`CV3Window.inc:869`） | 源码 |
| 执行 | `CV3OpenApplicationFast`（`CV3Window.inc:492`） | 源码 |
| **主 API** | `[LSApplicationWorkspace openApplicationWithBundleID:]`（:503-507） | 源码 |
| **降级 API** | `-[UIApplication launchApplicationWithIdentifier:suspended:]`（:516-531） | 源码 |
| 浮窗全屏 | `CV3FloatingAppWindow.inc:3927` `activateHostedAppFullscreenAndClose`（同两条 API） | 源码 |
| Screen Time 处理 | **全工程 0 处**（无任何限额检查） | grep 证据 |

### 1.2 系统拦截机制（已实证）

- **2026-10-04 实机验证**（"微信 1 分钟限额"真实触发）：主屏点微信 → 拦截页出现；
  同刻 STL 日志（SpringBoard/6702，`stl_log.txt`）：
  ```
  11:46:05.356 [SpringBoard/6702] [hook] STBlockingViewController -viewDidLoad
  11:46:05.359 [SpringBoard/6702] [hook] STBlockingViewController -viewWillAppear:
  ```
  → **拦截页由 SpringBoard 进程创建**（不是被限额的 App、也不是 ScreenTimeAgent）。
- **形态**：远程视图（AX 探针 `visible_point=(-1,-1)`、`ctx` 属目标 App 场景；
  MCP `tap_element` 点不到、`tap_screen` 按坐标能点到 — v5.1 文档坑 4）。
- **覆盖范围现状**：
  - ✅ 已证实被拦：**主屏图标**（10-04 实机验证，多轮可复现）。
  - ❌ 已实锤可绕：**Chevron 面板**（用户报告 + 代码面无任何检查）。
  - ？未测：通知、Spotlight、URL scheme、浮窗全屏、App Switcher、锁屏/控制中心。

### 1.3 STL 5.2.1 现状（当前设备版本）

四层全部是"拦截页出现之后"的事：

| 层 | 对象 | 行为 |
|---|---|---|
| ① 数据层 | `STManagementState -shouldAllowOneMoreMinuteFor*:error:` | 一律 `@NO`（禁"免费再使用一分钟"） |
| ② 设置页 | `STAllowanceDetailListController -hasSetBudgetTime` | 恒 YES（解锁 0/0 限额） |
| ③ 密码入口 | `STBlockingViewController -_enterScreenTimePasscode:` | Face ID 优先，走不通转屏幕使用时间密码 |
| ④ 菜单 | `-presentViewController:animated:completion:` | 只观测不改（v5.2 起不插入） |

**不 hook 任何启动路径** —— 它拦不到"启动"这个动作。

### 1.4 环境约束（决定取证方式）

- SpringBoard 真实二进制在 **dyld shared cache**：磁盘上的 `SpringBoard.app/SpringBoard` 只是 112 KB stub
  （`otool -L` 指向 `SpringBoard.framework`，该 framework 磁盘上无实体）→ **静态挖"检查点"不可行**。
- 设备无 frida / python / strings / nm（仅 file / plutil / find 等基础工具）。
- → **动态探针是唯一快路径**。

---

## 2. 深度拦截要解决的三个问题

### 问题 A：拦哪里（覆盖面）

| # | 路径 | 底层 API 候选 | 现状 |
|---|---|---|---|
| 1 | Chevron 面板 | `LSApplicationWorkspace -openApplicationWithBundleID:` | ❌ 已知可绕 |
| 2 | Chevron 浮窗全屏 | 同上 + `launchApplicationWithIdentifier:` | 待测（预计同漏） |
| 3 | 通知点开 | `SBNCNotificationDispatcherDelegate -launchForegroundApplicationForAction:...` | 待测 |
| 4 | Spotlight 搜索打开 | Spotlight 进程内路径（STL 已注入 Spotlight） | 待测 |
| 5 | URL scheme | `-openApplicationWithURL:` / `-openURL:options:...` 族 | 待测 |
| 6 | App Switcher 切回 | SpringBoard 场景激活路径 | 待测 |
| 7 | 锁屏 / 控制中心 | 各自路径 | 待测 |

> 建议先做**实测矩阵**：同一个限额 App，逐个路径测"系统拦不拦"，**只对系统漏掉的路径补拦**，避免过度 hook。

### 问题 B：拦了之后怎么呈现（最关键）

| 方案 | 做法 | 难点 |
|---|---|---|
| **1. 复用系统入口（首选）** | 找到"系统在主屏路径创建拦截页"的那个入口函数，直接调用它（传 bundleID）→ 得到与系统一致的拦截页（自动兼容 STL 的 ③ 增强） | 函数名未知 → 用"创建调用栈探针"一次性定位（§3） |
| 2. 自建呈现 | 自行实例化 `STBlockingViewController` 并呈现 | STL 已验证**可实例化**（v4 自检 `实例化拦截页 VC = <STBlockingViewController: 0x7ee01ac00>`），但"上下文注入"（bundleID/限额数据）未知，逆向量较大 |

### 问题 C：怎么判定"该拦"

- 候选：`STManagementState` 的**完整方法表**（待 dump）。
- ⚠️ 坑：`shouldAllowOneMoreMinuteFor*` **不能**当"是否限额中"判据
  （限额场景下它原返回值 = YES，语义是"允许再要一分钟"）。

---

## 3. 建议的下一步取证（一次实验拿全关键情报）

**探针方案**（给 STL 加临时探针，小版本，用完即卸）：

1. hook `STBlockingViewController` 的 `-init` / `-initWithCoder:`（storyboard 入口）
   → 命中时打印 `NSThread callStackSymbols`（**直接拿到"谁创建了拦截页"的完整调用链 = 系统检查点**）；
2. `class_copyMethodList` 全量 dump `STManagementState` 方法表（名 + typeEncoding）；
3. （可选）对候选"启动处理"方法打点，先看谁被调、调用序。

**触发步骤**：主屏点一次"限额中"的 App（**只测主屏，单变量**）→ 读 `stl_log.txt`。

**注意事项**：
- 探针版不动 ①-④ 层现有 hook，保持行为不变；
- ChevronV3 有一个静默 hook 别混淆：**目标 App 已有浮窗时**，面板启动会被"聚焦浮窗"吞掉
  （`Tweak.x:4234 / 5164`，与限额无关，测试时避开）；
- ChevronV3 诊断日志哨兵已开（`/rootfs/var/mobile/Library/Logs/ChevronV3_Logs.enabled`），
  面板路径若执行会留 `[Launcher] Fast open` 行，可作对照。

---

## 4. 附：与 ChevronV3 的关系

- 若最终决定"深度拦截放 STL"，**ChevronV3 侧一行都不用改** —— 所有路径由 STL 统一拦。
- 若 STL 暂不做，退路是在 Chevron 启动前自己查限额 + 阻止启动（覆盖不了其它 app/工具路径）。
