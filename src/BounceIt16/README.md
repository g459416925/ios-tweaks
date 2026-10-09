# BounceIt16 — SpringBoard 果冻弹性动画

给系统动画加上**弹簧回弹**：界面冲过头 → 回弹 → 小幅震荡几下后停。

> 这是 2018 年老插件 **Bounce It!**（`com.jakeashacks.bounceit`，iOS 11/12 时代）的**重写版**。
> 原版二进制在 iOS 16 + RootHide 上**无法加载**（详见文末「为什么不用原版」）。

- 包名 `com.xu.bounceit16` ｜ 宿主进程 **SpringBoard** ｜ 架构 `iphoneos-arm64e`
- 依赖 `mobilesubstrate`（ellekit 已 `Provides`）
- 仅注入 `Filter.Bundles = ["com.apple.springboard"]`

## 原理

`SpringBoardFoundation` 里有两个「动画参数容器」类，SpringBoard 的动画都从这里取参数：

| 类 | iOS 16.5.1 | 被 hook 的成员 |
|---|---|---|
| `SBFFluidBehaviorSettings` | ✅ 51 methods | `-setDampingRatio:`（强制写入本插件值） |
| `SBFAnimationSettings` | ✅ 36 methods | `-damping` / `-stiffness` / `-mass` / `-epsilon`（getter 恒返回本插件值） |

两者都继承 `PTSettings`（PrototypeTools），属性通过 getter 访问 ⇒ 劫持 getter 即可改变全局动画手感。

**原版 BounceIt 还有 19 个 hook 点，在 iOS 16 上已全部失效**（探针实测）：

- `SBFluidBehaviorSettings`、`SBAnimationSettings`、`SBFSpringAnimationSettings` —— **类已不存在**
- `SBReachabilitySettings.*`、`SBAppSwitcherSettings.*` —— 这些类还在，但**不再有 damping/stiffness 属性**，
  它们通过 `-animationSettings` 转发到 `SBFAnimationSettings` ⇒ 只 hook 后两个类即可覆盖

## 参数与手感

阻尼比 `zeta = damping / (2*sqrt(stiffness*mass))`，固有频率 `omega = sqrt(stiffness/mass)`。

本插件固定 `stiffness = 1666`、`mass = 2.5` ⇒ `omega = 25.8 rad/s`、`2*sqrt(km) = 129.08`。

| `kBDamping` | `kBDRatio` | ζ | 过冲 | 收敛 | 观感 |
|---|---|---|---|---|---|
| 78 | 0.60 | 0.604 | 9% | 0.26 s | 弹一下就停 |
| 56 | 0.43 | 0.434 | 22% | 0.36 s | 原版 BounceIt 档 |
| **42** | **0.33** | **0.325** | **34%** | **0.48 s** | **当前 v1.0.2：弹 2 下即停** |
| 30 | 0.24 | 0.232 | 47% | 0.67 s | 弹 3~4 下；界面已就位后仍在晃 |
| 22 | 0.17 | 0.170 | 58% | 0.91 s | 很弹，明显拖尾 |

⭐ **调参看「收敛时间」而不是只看过冲**：App 界面视觉就位约 **0.35 s**，
只要 `4/(ζω) > 0.35 s` 就会出现「界面已经加载好了但还在弹」。
既保留弹跳又不拖尾 ⇒ **ζ 取 0.30~0.35**。

- 只改 `damping` / `dampingRatio`，**不动 `stiffness`**（动 stiffness 会改振荡频率＝动画节奏）
- 想「更弹但不拖尾」的另一条路：**提高 stiffness**（ω 变大 ⇒ 收敛变快），但弹跳会变急促

## 构建

```bash
cd src/BounceIt16
./build_deploy.sh          # 编译 → 安全检查 → 设备签名 → 打 deb → 安装 → respring → 打印日志
```

版本号唯一来源是源码里的 `#define BIT16_VERSION`，脚本自动读取。

脚本会做这些安全检查（**必须通过**）：

- `nm -u` 不得出现私有类硬符号 `_OBJC_CLASS_$_SB*`
- `strings` 不得出现 `/System/Library/...` 或 `TweakInject` 路径字面量（RootHide 的 roothidepatch 会改写它们并破坏签名）

产物：`BounceIt16_<版本>_iphoneos-arm64e.deb`

## 验证

插件运行日志（`/rootfs/private/var/mobile/Documents/bounce16.log`）：

```
[BIT16] CTOR pid=42264 proc=SpringBoard
[BIT16] install: SBFFluidBehaviorSettings=SBFFluidBehaviorSettings SBFAnimationSettings=SBFAnimationSettings
[BIT16] hooked SBFFluidBehaviorSettings -setDampingRatio: -> 0.330
[BIT16] hooked SBFAnimationSettings -damping / -stiffness / -mass / -epsilon
[BIT16] install done
```

## 为什么不用原版 BounceIt

`com.jakeashacks.bounceit` 1.0.4（BigBoss 源）是 2018 年的 **universal 二进制（arm64 + arm64e）**，
在 RootHide 下 **`roothidepatch` 处理 arm64e 切片时会破坏签名、且不更新 CodeDirectory 哈希**：

```
$ codesign --verify --verbose=4 landed-bounceit.dylib
landed-bounceit.dylib: invalid signature (code or signature have been modified)
In architecture: arm64e
```

逐字节比对可见 Mach-O 段结构（文件偏移 128-135）被写入了 `.jbroot-<UUID>` 片段。
结果：dyld 拒绝 `dlopen`，**ellekit 静默跳过** —— 无日志、无崩溃、插件"像没装"。

试过瘦身单 arm64e、plist 转 XML、走 `dpkg -i`，全部无效。
⚠️ 但 universal 本身不是问题：本机 `ChevronV3` / `CCSupport` 等 universal 插件都正常 ——
差别在于它们是 **RootHide 工具链新编译**的。
故本插件改为**自己重写编译**，自研链路（clang → ldid → dpkg）从不掉链子。
