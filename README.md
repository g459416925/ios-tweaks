# ios-tweaks

个人 iOS 越狱插件源（APT / Sileo）。目标环境：**RootHide 无根越狱 · arm64e · iOS 16.x**。

## 源地址

```
https://g459416925.github.io/ios-tweaks/
```

在 Sileo 里：**软件源 → 右上角 ➕ → 粘贴上面的地址 → 添加 → 搜索插件名 → 安装**。

## 插件列表

| 包名 | 版本 | 说明 |
|---|---|---|
| `com.xu.compactorfix` | 1.0.0 | **CompactorFix** — 把系统 UI 字体整体换成 Apple Watch 的 SF Compact |
| `com.xu.screentimelocker16` | 5.2.0 | **ScreenTimeLocker16** — 让「屏幕使用时间」的 App 限额真正锁得住 |
| `com.xu.statusbarscale` | 1.9.0 | **StatusBarScale** — 状态栏图标缩放对齐（右侧 0.92 / 时间右侧 0.6）+ 灵动岛下方辅助状态条（0.4×）+ **设置 App 可视化面板（滑块实时预览、改动热生效免 respring）** |

### CompactorFix

原版 *Compactor* 在 iOS 16 上"看起来没生效"，根因是**调用时机太晚**：
它在 `_UIApplicationInitialize` 钩子里调用私有 API `CTFontSetAltTextStyleSpec()`，
而此时字体子系统已初始化完毕。本版改在 **dyld 构造函数**（早于 `main`）里调用 → 实测生效。

- 全部 `kCTFontUIFontType` 0..24 变为 `.SFCompact-*`；整屏 **13.07%** 像素变化
- 注入到**全部 UIKit App + SpringBoard**（`Filter.Classes = ["UIApplication"]`）
- ⚠️ **SF Compact 是拉丁系字体**：含拉丁/希腊/西里尔 1358 个码位，
  **不含中日韩** → 中文仍回退**苹方 PingFang**，中文外观不变属**预期行为**

### ScreenTimeLocker16

还原原版 *DisableOneMoreMinute* 的四层实现，把 App 限额变成真正的锁：

1. **数据层** — 禁止「再使用一分钟」（0/0 限额可长期生效）
2. **设置页** — 允许把限额设成 **0 小时 0 分钟**
3. **拦截页** — 认证优先走 **Face ID**，用不了时回落**屏幕使用时间密码**
4. **菜单弹窗** — 保持系统原样，不注入任何额外选项

不隐藏任何原生按钮，「请求更多使用时间」照常保留。
宿主进程 `SpringBoard`；依赖 `mobilesubstrate`（ellekit 已 `Provides`）。

### StatusBarScale

灵动岛机型状态栏右侧图标与左侧时间不对齐（14 Pro Max / iOS 16.5.1 实测：
图标墨迹高 13–14px vs 时间 12px，重心偏高 1.66px）。本插件 hook
`_UIStatusBarForegroundView -layoutSubviews`，对灵动岛右侧图标施加
**绕中心缩放 0.92 + 下移 1.5pt**：

- 实测：图标高度 13→12（=时间），重心差 **−1.66 → −0.07px**
- `transform` 不参与 frame 布局 → 间距、点击区域完全不受影响
- 灵动岛展开/收起自动跟随（每次布局后重设，幂等）
- 配置 `/var/mobile/Library/Preferences/com.xu.statusbarscale.plist`（⭐ v1.9.0 起推荐直接在
  **设置 → Tweaks → 状态栏缩放** 面板里改，滑块拖动实时预览、松手即存、**热生效免 respring**）：
  `enabled` / `scale` / `dy` / `threshold` / `leadEnabled` / `leadScale` / `leadDy` /
  `diag` / `verbose` / `auxEnabled` / `auxStrip` / `auxData` / `auxIcons`，
  以及 v1.9.0 新增的逐图标开关 `auxIcon_alarm|quietMode|rotationLock|location|vpn|bluetooth|airplane`
  （任一出现即优先于 `auxIcons` 数组；未出现的键默认收纳）
- ⭐ v1.9.0 设置面板（PreferenceBundle）：`设置 → Tweaks → 状态栏缩放`，含全部参数
  滑块/开关、辅助条逐图标收纳、恢复默认值、重启桌面；保存后发 Darwin 通知
  `com.xu.statusbarscale/prefsChanged`，插件监听后热重载
- ⚠️⭐ RootHide 双目录坑（面板因此不能用 CFPreferences）：「设置」App 的
  CFPreferences 读写落在**影子目录** `/var/mobile/Library/Preferences/`（内容可能是旧快照），
  而插件读硬编码 `/var/mobile/...` 实际解析到**真实文件**
  `/rootfs/private/var/mobile/Library/Preferences/` —— 两份不是同一文件。
  面板因此**直写真实路径**（`/rootfs/...` 前缀优先 + 影子路径兜底双写）
- 仅注入 SpringBoard（`Filter.Bundles = ["com.apple.springboard"]`）；App 内状态栏由
  SpringBoard 远程渲染，无需向普通 App、WebKit 或 PosterBoard 注入
- ⚠️ RootHide 坑：SSH 手工部署该配置**必须**走
  `/rootfs/private/var/mobile/Library/Preferences/`（不带前缀是影子目录）

**时间右侧（灵动岛左侧）图标缩放 —— v1.7.3**

原实现只处理 `minX >= threshold`（岛右侧），**时间右侧、灵动岛左侧**那批图标
（实测类名 `_UIStatusBarImageView`）被整体漏掉。它们无法按标识枚举，故改为
**运行时按 fg 坐标系 frame 区间发现**（时间右缘 → 岛左缘），单独缩放 **0.6**：

- 判定：非 StringView + class 含 StatusBar/Battery + 3pt≤宽高且宽<200pt
  + `minX > timeMaxX` 且 `maxX ≤ leadLimit`（岛左缘，实测 152.0）；递归深度 3 +
  `convertRect:toView:` 换算，防深层嵌套用错坐标系
- **三道场景门禁**（1.7.2 实机日志暴露的误伤，必须保留）：① 只处理全屏宽度 fg
  （CC/Spotlight 迷你状态栏宽 361/370，否则左侧信号/WiFi 被误缩）；
  ② 无可视时间（`timeMaxX=0`）跳过；③ 岛左缘须落在 60~200
- 日志确证：`[leadApply] 缩放前 a=1.000 → 后 a=0.600`；门禁修复前后对比
  **误缩信号/WiFi 10 次 → 0 次**

**系统辅助图标条（v1.5.1 默认启用）**

- 图标 = **系统原生字形**：优先用 hook `viewForIdentifier:` 捕获的系统 item 视图
  渲染图（与系统 100% 同款），兜底 UIKitCore `Artwork.bundle/Assets.car` 的
  `Black_Alarm` / `Black_QuietMode` / `Black_RotationLock` / `Black_VPN` /
  `Black_Bluetooth`（系统状态栏渲染用的就是这批原始字形）
- 状态源 = `_UIStatusBarData`：hook `applyUpdate:` / `_applyUpdate:keys:`
  捕获数据对象（含保底：锁屏空 Entry 的 data 不覆盖主屏 data），实时驱动显隐
- 位置：**灵动岛正下方居中**（岛底缘 +1.5pt，岛位置运行时动态检测），
  横向屏幕居中，9pt 小图标
- 仅显示激活项：闹钟/勿扰/旋转锁/VPN/蓝牙（无状态时整条隐藏）；
  默认不显示定位（系统原生定位箭头已存在，避免重复）
- 图标显隐与系统一致：蓝牙未连接设备时 Entry 不激活 → 不显示
- **v1.4.0**：岛位置动态检测（类名 Aperture/Island/Pill + 尺寸/居中校验）；
  日志限流；默认去重 location
- **v1.4.1**：修复 CC 开合触发 Jetsam —— 全被动写 + 33ms 节流 + 宿主恒定
- **v1.4.2**：修复锁屏解锁后辅助条消失/位置偏移（布局机制加固）——
  ①只托管全屏宽度的 fg（CC/Spotlight 窗口 fg 宽 361≠屏宽 430，其内部"伪居中"
  的 Pill 视图曾误判为岛 → 偏移 35pt）②岛候选再验窗口坐标居中（双保险）
  ③fg didMoveToWindow 补触发布局（解锁后劫持条回新宿主）
  ④data 保底 ⑤改 dpkg 安装（root cp 直写 TweakInject 会触发不完整 patch → 签名失效）
- ⚠️ RootHide 坑：dylib 内**绝不能出现完整 `/System/Library/...` 路径字面量**；
  部署**必须走 dpkg -i**（直接 cp 到 TweakInject 目录会被 jbroot 不完整 patch
  破坏签名 → dyld `Invalid Page` 杀 SpringBoard）

## 目录结构

```
ios-tweaks/
├── index.html                          # 源首页（Sileo 添加源步骤 + 插件说明）
├── Release / Packages / Packages.bz2   # APT 索引（由 tools/gen_repo.py 生成，勿手改）
├── debs/                               # 实际分发的 .deb
├── src/<包名>/                          # 插件源码 + 构建脚本 + docs
│   ├── <包名>.m                        # 源码（版本号唯一来源：#define *_VERSION）
│   ├── <包名>.plist                    # 注入过滤
│   ├── build_deploy.sh                 # 交叉编译 + 签名 + 部署到设备
│   ├── build_deb.py                    # 打 .deb（版本号自动取自源码）
│   ├── README.md                       # 该插件的原理与构建说明
│   └── docs/                           # 各版本改动与实机验证记录
├── src/ScreenTimeLocker16/             # 屏幕使用时间锁（宿主 SpringBoard）
├── src/CompactorFix/                   # 系统字体换 SF Compact（宿主 全 UIKit App）
├── src/StatusBarScale/                 # 状态栏图标缩放对齐（宿主仅 SpringBoard）
└── tools/gen_repo.py                   # 扫描 debs/ 重建 APT 索引
```

## 发布新版本

```bash
# 以 <包名> 为 ScreenTimeLocker16 / CompactorFix / StatusBarScale 之一
# 1. 改 src/<包名>/<包名>.m 里的版本宏（ScreenTimeLocker16=STL_VERSION；CompactorFix=CF_VERSION；StatusBarScale=SBS_VERSION）
# 2. 交叉编译并签名，产出 <包名>.signed.dylib（同时会部署到手机；见脚本内说明）
cd src/<包名> && ./build_deploy.sh && cd ../..
# 3. 打包 deb（版本号自动读取源码，无需手填）
/Users/xu/.workbuddy/binaries/python/versions/3.13.12/bin/python3 src/<包名>/build_deb.py
# 4. 把产物丢进 debs/
cp src/<包名>/<包名>_*_iphoneos-arm64e.deb debs/
# 5. 重建 APT 索引
/Users/xu/.workbuddy/binaries/python/versions/3.13.12/bin/python3 tools/gen_repo.py
# 6. 提交推送
git add -A && git commit -m "release: <包名> <版本>" && git push
```

> ⚠️ macOS APFS 默认大小写不敏感，仓库根目录**不能**同时有 `Packages`（索引文件）和 `packages/`（目录），故源码目录命名为 `src/`。

## 环境要求

- 越狱：relaxin + **RootHide**（无根）
- 注入框架：ellekit（`Provides: mobilesubstrate`）
- 架构：`iphoneos-arm64e`
- 系统：iOS 16.x（在 iPhone 14 Pro Max / iOS 16.5.1 实测通过）

## 免责声明

个人自用插件源，未经全面测试，仅供学习与自用。安装前请自行评估风险，刷机/变砖后果自负。

- **v1.4.3**：布局回正 —— 辅助图标条固定在**灵动岛正下方居中**
  （许总澄清：电话助手左右两侧放的是时间/电池/信号等主要元素，
  那些由系统原生渲染；辅助条本体就该在岛正下方）

- **v1.4.4**：修复 CC 收起后辅助条要等几秒才显示 —— 实测根因：CC 关闭过渡动画
  期间主屏 fg 宽度在 430/370 间抖动且 StringView 暂被移除（fgIsLive=NO），
  动画结束后系统不再触发布局 → 条没人放回。修：记录活动 fg（强引用）+
  data 变化驱动多档延迟重试（0/0.3/0.8/1.5s），条跟随 data 恢复立即回来
- **v1.4.5**：修复退出 App 回主屏后辅助条延迟数秒 —— 实测架构：UIStatusBarWindow
  (level 999) 是常驻状态栏总窗口（主屏/App 的 fg 复用），SBStatusBarReusePoolWindow
  (hidden=1) 是备用 fg 池，切 App 时旧 fg 被放回池里并最后布局一次，条被搬进
  隐藏窗口跟着消失；回主屏后 fg 又不触发布局 → 没人搬回。修：前台门禁
  （拒绝隐藏窗口/ReusePool 池的 fg 托管条）+ didMoveToWindow 多档重试 +
  2s 定时自愈（条丢失/挂错窗口自动强制重排）

- **v1.4.5 补**：修复主屏下拉 CC 再收回后条延迟数秒（复发）—— 日志实锤第二个窗口架构：
  CC 打开时主屏 fg 被**借**进 `SBControlCenterWindow`，条（挂在 fg.superview）跟着
  搬进 CC 窗口；CC 收起时该宿主被销毁 → 条消失，等几秒才被搬回 UIStatusBarWindow。
  旧自愈判据 `gStrip.window != fg.window` 失效（CC 期间条和 fg 同在 CC 窗口，误判
  "没丢"）。修：门禁加拒绝 `ControlCenter` 窗口（与 ReusePool 同待遇）；自愈判据改
  硬编码合法窗口（`UIStatusBarWindow`）+ fg 合法性检查。实测 CC 开合全程
  `stripWin=UIStatusBarWindow` 纹丝不动，收回 0.6s 内条已在位

- **v1.4.6**：三项修复（许总反馈：主屏显示 / **App 内也要显示** / **锁屏不显示**）：
  1. **App 内显示**：实测铁证 —— App 进程 windows=1 且**无 fg 实例**（App 内状态栏由
     SpringBoard 经 `SBMainSwitcherWindow` 远程渲染，fg 首挂窗早于 dylib ctor，hook 装好
     后再无触发）。修：SB 门禁**放行 MainSwitcher**（App 前台的正宿主，v1.2–1.4.5
     时代 App 内条可见的真正机制）；App 进程加 3 轮主动扫描（0.5/2/5s，App 进程视图
     树可遍历）兜底；
  2. **锁屏不显示**：`SBLockScreenManager.uiIsLocked` 判定（StringView.y 判据不可用 ——
     实测主屏与锁屏的 fg 内部坐标系相同 y=18.67）；解锁后布局触发自动恢复；
  3. **快速开关 App 条消失**（上一轮遗留）：条被搬进 MainSwitcher 后主屏 fg 零布局
     没人搬回 —— 1s 自愈 + 见过表 + didMoveToSuperview 多档重试兜底（实测搬回成功）。
  另修两个工程坑：日志多进程互踩（限流统计 atomically 覆盖写 → 改 append）；
  ctor 内 [hook] 日志被限流吞（install 改 sbs_logNow 直写）。实测：主屏/App 内/
  锁屏不显示/解锁恢复/快速切换自愈 1s 内全链路通过

- **v1.5.0–1.5.1**（稳定性）：注入过滤由 `Classes=UIApplication` 收缩为
  `Bundles=com.apple.springboard`（普通 App / WebKit / PosterBoard 不再加载本插件）；
  构造函数加 SpringBoard 进程白名单；辅助条恢复为默认核心功能（仅 SB 内运行）；
  `verbose=NO` 时禁用文件日志

- **v1.7.1**：修复**诊断日志回归** —— v1.5.0 误给"关键事件直写"函数 `sbs_logNow`
  也加上了 `if (!gVerbose) return;`，导致设备 `verbose=false` 时**日志一个字节都不写**，
  故障完全无法定位（这正是"图标无法枚举 / 问题定位不了"的元凶）。
  现拆为两级：`diag`(默认 YES) 管关键事件直写，`verbose`(默认 NO) 管高频批量

- **v1.7.3**：新增**时间右侧（灵动岛左侧）图标缩放 0.6**（详见上文），
  并修三处问题：① 1.7.2 上线日志暴露的误伤（CC/Spotlight 迷你状态栏被扫 + 无时间基准时
  区间退化 → 误缩左侧信号/WiFi，加三道门禁后 10 次 → 0 次）；
  ② `build_deploy.sh` 私有符号检查正则 bug —— 旧写法 `_OBJC_CLASS_$_(UI|...)`
  会误判公共类 `$_UIApplication` / `$_UIView` / `$_UIScreen`，导致脚本无条件 `exit 1`、
  部署永远走不完；③ README/注释与代码不一致的默认值（dy 1.5、threshold 312）
