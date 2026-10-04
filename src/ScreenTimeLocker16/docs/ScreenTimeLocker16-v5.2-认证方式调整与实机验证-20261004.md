# ScreenTimeLocker16 v5.2.0 —— 认证方式调整 + ④ 层关闭（2026-10-04）

> 承接 `ScreenTimeLocker16-v5.1-原版四层还原与实机验证-20261004.md`。
> 本轮按许总四条指令调整，**未改动任何原版功能**，只调整 ③ 的走向、关掉 ④ 的插入。

---

## 一、许总四条指令与执行结果

| # | 指令 | 执行结果 | 真机证据 |
|---|---|---|---|
| 1 | 认证「走 Face ID 和屏幕使用时间密码」 | ✅ 定为 **Face ID 优先，走不通转密码** | `[③] Face ID 可用 → 开始面容认证` → 通过时 `[③] Face ID 通过 → _showPasscodeApprovedOptions`；失败时 `[③] Face ID 未通过 code=-4 → 回落屏幕使用时间密码` |
| 2 | 微信限额「后面我来删除，我要测试实际情况」 | ⏸ **保留不动**（0 小时 0 分钟） | 拦截页实时可触发 |
| 3 | 删掉「再使用一分钟」，保留其他 15 / 30 / 全天 | ✅ ④ 开关置 0，不再插入 | 菜单只剩 `输入屏幕使用时间密码` / `取消`；认证后弹窗为 `批准使用15分钟` / `批准使用一小时` / `批准全天使用` / `取消` |
| 4 | 装 deb 刷新 dpkg 记录 | ✅ `ii com.xu.screentimelocker16 **5.2.0** iphoneos-arm64e` | dpkg 从 `4.4.0` → `5.2.0` |

> 📌 实际原生弹窗的时长项是 **15 分钟 / 一小时 / 全天**（许总口述的「30」对应的是「批准使用一小时」那一档）。

---

## 二、代码改动（v5.1.0 → v5.2.0）

### 1. ③ `-_enterScreenTimePasscode:` —— Face ID 优先，走不通转密码

| 情形 | v5.1.0（旧） | v5.2.0（新） |
|---|---|---|
| Face ID 可用 → 弹面容 → **通过** | `_showPasscodeApprovedOptions` | 同左（不变） |
| Face ID 可用 → 弹面容 → **取消/失败** | **什么都不做**（用户卡在拦截页） | **回落**到「输入屏幕使用时间密码」 |
| Face ID **不可用**（未录面容等） | 回落原生 | 同左（不变） |

回落实现要点（**关键坑**）：

```objc
SEL sel = @selector(stl_enterScreenTimePasscode:);   // ← swizzle 后此名挂的才是「原实现」
if ([s respondsToSelector:sel]) {
    IMP imp = [s methodForSelector:sel];
    ((void (*)(id, SEL, id))imp)(s, sel, nil);
}
```

- ⚠️ **绝不能**回落时调 `_enterScreenTimePasscode:` —— 那个名字已被换成**我们自己的钩子**，会无限递归弹面容。
- `STLHook()` 用 `method_exchangeImplementations` 互换 IMP，所以 `stl_` 名字上挂的是原生实现，`_` 名字上挂的是钩子。

### 2. ④ 关闭插入

```objc
#define STL_ENABLE_PRESENT_HOOK  0   // v5.2：不再插入「再使用一分钟」
```

钩子仍在（只出观测日志），但不再往 alert 里塞任何 action。原生 15 分钟 / 一小时 / 全天 **原样保留**。

### 3. 清理 v3/v4 死代码

删除（已无任何调用点）：`-stl_addAction:`、`+stl_actionWithTitle:style:handler:`、`STLNeutralizeAction()`。编译警告从 2 个降到 1 个（剩下的 `tick` retain cycle 是按设计如此）。

### 4. 其他

- 版本 `5.1.0` → `5.2.0`
- 新增测试开关 `STL_TEST_FORCE_FALLBACK`（发布版 = 0）

---

## 三、真机验证记录（iPhone 14 Pro Max / iOS 16.5.1）

### 3.1 载入（12:38:17）

```
[载入] v5.2.0 proc=SpringBoard pid=7856 可写日志=/var/mobile/Documents/stl_log.txt
ScreenTimeLocker16 5.2.0 [①数据层] 真宿主 proc=SpringBoard pid=7856
[hook] OK    21 个（含 presentViewController:animated:completion:）
[cfg] forbidden titles(9): 再使用一分钟 | 忽略限额 | …（9 项）
初始化完成
```

### 3.2 拦截页 + ④ 验证（12:33）

```
[btn] askForMoreTimeButton = STMenuButton 标题=“-” hidden=否      ← 按钮保留 ✓
[hook] -_showAskForMoreTimeOptions: 命中
[SMS] bundle=“com.tencent.xin” 原返回值=1 → 强制 @NO              ← ① 数据层
[present] UIAlertController 共 2 个 action:
    [0] “输入屏幕使用时间密码”
    [1] “取消”                                                    ← 无「再使用一分钟」✓
```

### 3.3 ③ Face ID 成功路径（12:33:31）

```
[hook] -_enterScreenTimePasscode: 命中
[③] Face ID 可用 → 开始面容认证 reason=“请求更多使用时间”
[③] Face ID 通过 → _showPasscodeApprovedOptions
[present] UIAlertController 共 4 个 action:
    [0] “批准使用15分钟”  [1] “批准使用一小时”  [2] “批准全天使用”  [3] “取消”
```

### 3.4 ③ 回落路径（12:36:55，用 `STL_TEST_FORCE_FALLBACK=1` 强制触发）

```
[③][测试] 强制模拟 Face ID 失败 → 走回落
[③] Face ID 未通过 code=-4（-2=用户取消）→ 回落屏幕使用时间密码
```

**判定依据**（两条反向证据）：
- **没有** `[③] 回落失败：对象不响应 stl_enterScreenTimePasscode:` ⇒ `respondsToSelector` 为 YES，IMP 调用**已执行**；
- **没有**第二次 `[hook] -_enterScreenTimePasscode: 命中` ⇒ 调的是**原生实现**、**未递归**。

> 熄屏中断导致密码输入界面未能截图确认；原生实现本身即「弹出屏幕使用时间密码输入」，逻辑闭环。

### 3.5 稳定性

12:38 重载后零插件相关崩溃。CrashReporter 最近三条均为 `*.wakeups_resource` / `*Metrics`（资源与指标报告，非崩溃）。

---

## 四、产物

| 文件 | 说明 |
|---|---|
| `tweak_stl/build/ScreenTimeLocker16.m` | 源码 v5.2.0 |
| `tweak_stl/build/ScreenTimeLocker16.signed.dylib` | 已签名 96960 B |
| `tweak_stl/build/ScreenTimeLocker16_5.2.0_iphoneos-arm64e.deb` | 19400 B |
| `tweak_stl/build/ScreenTimeLocker16_5.1.0.signed.dylib.bak` | v5.1.0 回滚点 |

设备现状：`com.xu.screentimelocker16` **5.2.0**；plist 5 个 bundle（springboard / Preferences / ScreenTimeCore / ScreenTimeUI / ScreenTimeSettingsUI）；微信限额 0/0 保留待许总自测。

---

## 五、注意

1. **③ 走的是 Face ID，不是屏幕使用时间密码**（0207）。Face ID 用不了时才轮到 0207 —— 这是许总选定的「Face ID 优先，走不通转密码」。
2. 想改成「只走 0207」：把 `#define STL_ENABLE_DEVICE_AUTH` 置 `0` 重编即可。
3. 拦截页上的「忽略限额」按钮仍被隐藏（v5.1 起的既有行为，属真正的免费绕过路径）；许总若要求原样显示，需另行确认。
