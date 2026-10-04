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
| `com.xu.statusbarscale` | 1.4.3 | **StatusBarScale** — 状态栏右侧图标缩放对齐 + 系统辅助图标条（灵动岛正下方居中） |

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
**绕中心缩放 0.92 + 下移 1.7pt**：

- 实测：图标高度 13→12（=时间），重心差 **−1.66 → −0.07px**
- `transform` 不参与 frame 布局 → 间距、点击区域完全不受影响
- 灵动岛展开/收起自动跟随（每次布局后重设，幂等）
- 配置 `/var/mobile/Library/Preferences/com.xu.statusbarscale.plist`：
  `enabled` / `scale` / `dy` / `threshold` / `auxEnabled` / `auxIcons`（改后 respring）
- 注入全部 UIKit App + SpringBoard（`Filter.Classes = ["UIApplication"]`）
- ⚠️ RootHide 坑：SSH 部署该配置**必须**走
  `/rootfs/private/var/mobile/Library/Preferences/`（不带前缀是影子目录）

**v1.1–1.4 新增：系统辅助图标**

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
├── src/StatusBarScale/                 # 状态栏图标缩放对齐（宿主 全 UIKit App）
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
