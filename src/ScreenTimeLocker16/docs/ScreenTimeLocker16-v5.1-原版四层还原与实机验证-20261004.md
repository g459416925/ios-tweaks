# ScreenTimeLocker16 v5.1.0 —— 原版四层完整还原 + 实机验证报告

- 日期：2026-10-04
- 设备：iPhone 14 Pro Max / iOS 16.5.1 / relaxin + RootHide / ellekit 1.2-1
- 产物：`ScreenTimeLocker16_5.1.0_iphoneos-arm64e.deb`（20194 B，dylib 97680 B 已签名）
- 依据：对原版 `DisableOneMoreMinute.dylib` 的完整反汇编（arm64 slice）+ 真机日志交叉验证

---

## 结论速览

| 许总指令 | 状态 | 实机证据 |
|---|---|---|
| ① 拦截页**保留**「请求更多使用时间」按钮 | ✅ | 截图确认按钮在；日志 `askForMoreTimeButton … hidden=否`；黑名单已从 14 项缩到 9 项（剔除 `请求更多使用时间`） |
| ② **删掉**旧的「微信 每天 1 分钟」限额 | ✅ | 已进「删除限额 → 你确定要删除此限额吗？ → 删除限额」走完，列表清空 |
| ③ **0 小时 0 分钟**可保存（原生支持，完整实现不改功能） | ✅ | `[Budget] hasSetBudgetTime 原值=NO → 强制 YES`；滚轮 0/0 时右上角「添加」由**灰变蓝**，保存成功 |

原版四层**全部还原并逐层拿到真机日志证据**（见第三节）。v3/v4 我自作聪明加的 UI 层过滤已**全部拆除**。

---

## 一、原版 `DisableOneMoreMinute` 的四层 —— 反汇编依据 + 还原实现

| 层 | 目标 | 原版反汇编证据 | v5.1 实现 | 真机验证日志 |
|---|---|---|---|---|
| ① 数据层 | `STManagementState`<br>`-shouldAllowOneMoreMinuteFor{Bundle,Category,WebDomain}Identifier:error:` | `ldr x0,<NSNumber>; ldr x1,#sel(numberWithInt:); mov w2,#0x0` ⇒ 一律 `@(0)` | 先调原实现记日志，再 `return @(NO)` | `12:18:22.920 [SMS] bundle="com.tencent.xin" 原返回值=1 → 强制 @NO` |
| ② 设置页 | `STAllowanceDetailListController`<br>`-hasSetBudgetTime` | `0x3A20: mov w0,#0x1; ret` ⇒ 恒 YES | `return YES` | `12:17:01.590 [Budget] hasSetBudgetTime 原值=NO → 强制 YES（解锁 0 小时 0 分钟）` |
| ③ 密码入口 | `STBlockingViewController`<br>`-_enterScreenTimePasscode:` | `0x372C` 区块：`LAContext canEvaluatePolicy:1 → evaluatePolicy:… reply:`，成功→`_showPasscodeApprovedOptions`，`code==-2`→直接返回 | 同原版；未设设备密码等不可评估 → 回落原生 | `12:21:24.807 [③] 开始设备认证代替「屏幕使用时间密码」 reason="请求更多使用时间"`<br>`12:21:48.118 [③] 设备认证未通过 code=-2（用户取消）` |
| ④ 菜单弹窗 | `STBlockingViewController`<br>`-presentViewController:animated:completion:` | `0x3444` 区块：alert 首项 == `ApproveFor15MinutesButtonTitle` 时，插入 `OneMoreMinuteButtonTitle` 到 index 0 | 同原版（插入后调原实现） | `12:19:18.793 [present] UIAlertController 共 4 个 action: [0]批准使用15分钟 [1]批准使用一小时 [2]批准全天使用 [3]取消`<br>`12:19:18.793 [present] 已按原版插入「再使用一分钟」到 index 0` |

**四层的关系（原版设计意图）**：
① 禁掉**免费**的「再使用一分钟」；③④ 把它改成「**必须先通过一次身份认证**」才给——即"要解锁先验明正身"的自律锁，而不是死锁。

---

## 二、v5.1.0 相对 v5 的关键改动：拆掉 UI 层过滤

v3/v4 我在 UI 层干了原版**没干**的事：hook `UIAlertController -addAction:` / `+actionWithTitle:style:handler:`，把「批准使用15分钟 / 批准使用一小时 / 再使用一分钟 / 忽略限额」统统 `enabled=NO`。

**实机证明这套过滤和原版 ③④ 直接打架**：

```
12:19:18.793 [present] 已按原版插入「再使用一分钟」到 index 0     ← ④ 刚插入
12:19:18.810 [alert] 禁用 action “再使用一分钟”                  ← 立刻被我自己 disable 掉
12:19:18.810 [alert] 禁用 action “批准使用15分钟”
12:19:18.810 [alert] 禁用 action “批准使用一小时”
```

许总「不要去修改他的功能」。故 v5.1.0：

1. **删除** `UIAlertController -addAction:` 与 `UIAlertAction +actionWithTitle:style:handler:` 两个 hook；
2. `STLStripAlert` 不再禁用 alert 的 action（只保留视图树兜底）；
3. 黑名单 `forbidden titles` 由 **14 项 → 9 项**，只留真正的「免费绕过」：
   `再使用一分钟 / 忽略限额 / 今天忽略限额 / 15分钟后提醒我`（+英文）；
   剔除 `批准使用15分钟 / 批准使用一小时 / 请求更多使用时间`。

免费绕过改由 **①数据层 + 菜单过滤** 负责——这正是原版的做法。

---

## 三、本次排障：我自己踩的四个大坑（务必记住）

### 坑 1 ★★★ 日志路径读错，导致「插件完全失效」的假象

| 路径 | 内容 |
|---|---|
| `/var/mobile/Documents/stl_log.txt`（**SSH/jbroot 视角**） | 0 B（影子目录，我一直在读它） |
| `/rootfs/private/var/mobile/Documents/stl_log.txt`（**真实系统路径**） | 33 KB / 数百行（SpringBoard 一直在这里写） |

RootHide 下 SSH 会话的 `/var/mobile/Documents` 与真实系统的 `/private/var/mobile/Documents` 是**两个不同目录**。
**今后读插件日志一律用 `/rootfs/private/var/mobile/Documents/stl_log.txt`。**

顺带修掉源码里一个真 bug：`STLWrite()` 有 `if (!gActive) return;`，而 `[载入]` 那行写在 `gActive=YES` **之前**——所谓「载入即落盘」其实从没落过。v5 已加 `gForceLog` 强制落盘。

### 坑 2 ★★★ `launchctl kickstart -k` 不能用来重启 SpringBoard

它只做「SIGKILL + 排进 spawn 队列」，实测会让 SpringBoard 长时间停在 `state = spawn scheduled`（launchd 节流），期间 MCP 掉线、黑屏。我一度以为插件把 SpringBoard 打挂了。
**重启 SpringBoard 一律用 `sbreload`（实测 ~20 s 稳定复活）。**

### 坑 3 ★★ 把旧崩溃报告当成新问题

`SpringBoard-2026-10-04-110022.ips` 里的 `CODESIGNING / Invalid Page` 是 **11:00（v3 开发期）**的旧报告（其 mtime 会被系统刷新，极具迷惑性）。当时我据此判定「v5 签名无效」，完全错误。v5/v5.1 的签名一直有效（`ldd -S` 后 +1128 B，CodeDirectory v=20400 / sha256 / embedded）。
**判读崩溃报告先核对文件名里的时间戳与 `procLaunch`/`captureTime`。**

### 坑 4 ★ MCP 对拦截页的点击：`tap_element` 不行，`tap_screen` 按坐标可以

拦截页（`STBlockingViewController`）是 SpringBoard 的**远程视图**：
- `tap_element`（按文本）→ `no_match`，够不到；
- `tap_screen`（**按截图上的 screen-point 坐标**）→ **可以命中**，实测成功触发了「请求更多使用时间」→「输入屏幕使用时间密码」全链路。
- `get_ui_elements` 在弹窗出现时**能看到** action 的 rect（如 `输入屏幕使用时间密码` tap=(215,804.5)）——先用它拿坐标，再 `tap_screen`。

**意外发现**：`STBlockingViewController` 不只在 SpringBoard，**Spotlight 也会加载**（日志里 `Spotlight/xxxx` 同样完成 21 个 hook）。

---

## 四、当前设备状态

| 项 | 值 |
|---|---|
| 插件 | `com.xu.screentimelocker16` v5.1.0（../build/ScreenTimeLocker16_5.1.0_iphoneos-arm64e.deb） |
| 注入宿主 | SpringBoard / Spotlight / Preferences（三者都跑齐四层） |
| plist filter | `com.apple.springboard` / `com.apple.Preferences` / `com.apple.ScreenTimeCore` / `com.apple.ScreenTimeUI` / `com.apple.ScreenTimeSettingsUI` |
| 微信限额 | **已删旧的 1 分钟，改建成 0 小时 0 分钟**（每天 0 分＝直接拦死） |
| 屏幕使用时间密码 | `0207`（设备密码 `989826`） |
| 崩溃 | 12:22 sbreload 后零新增 CrashReporter 记录 |

---

## 五、产物

| 文件 | 说明 |
|---|---|
| `../build/ScreenTimeLocker16_5.1.0_iphoneos-arm64e.deb` | 可安装包（20194 B） |
| `../build/ScreenTimeLocker16.m` | 源码（v5.1.0，含每层反汇编证据注释） |
| `../build/ScreenTimeLocker16.plist` | 5 bundle filter（210 B） |
| `../build/build_deploy.sh` | 编译→签名→体积强校验→部署 流水线 |
| `/rootfs/private/var/mobile/Documents/stl_log.txt` | 设备端运行日志（**读这个路径**） |

---

## 六、待许总确认

1. **③ 的行为变化**：现在点「请求更多使用时间」→「输入屏幕使用时间密码」，校验走 **Face ID / 设备密码**，**不再走屏幕使用时间密码 0207**（原版行为）。若你更想保留 0207 密码方式，把源码里 `#define STL_ENABLE_DEVICE_AUTH` 改 `0` 即可，我一条命令重编。
2. **微信限额现在是 0/0**（等于直接锁死）。如果你只想验证功能、不想留限额，说一声我删。
3. 原版 ④ 会往「认证后」的弹窗插一条「再使用一分钟」；这是原版设计（认证换 1 分钟）。要不要保留同问。
