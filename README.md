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
| `com.xu.screentimelocker16` | 5.2.1 | **ScreenTimeLocker16** — 让「屏幕使用时间」的 App 限额真正锁得住 |
| `com.xu.statusbarscale` | 2.0.0 | **StatusBarScale** — 状态栏图标缩放：灵动岛右侧图标 0.90× 对齐时间，时间旁/岛左图标 0.50× |

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
`_UIStatusBarForegroundView -layoutSubviews`，每次布局后对命中图标施加
**绕中心缩放 + 垂直微调**（`transform` 不参与 frame 布局 → 间距、点击区域完全不受影响；
每次布局后重设，幂等）。

**① 主缩放（灵动岛右侧）**：`frame.minX ≥ 280` 的状态栏图标 × **0.9025**；
垂直下移按绑定曲线 `dy(s) = K·(1−s)` 实时推算（锚点 `dy=0.6687 @ scale=0.84847`
⇒ 当前 0.43pt）。实测：图标高度 13→12（=时间），重心差 **−1.66 → −0.07px**。

**② 时间旁缩放（时间右侧、灵动岛左侧，v1.7.3）**：这批图标（实测类名
`_UIStatusBarImageView`）无法按标识枚举，改为**运行时按 fg 坐标系 frame 区间发现**
（时间右缘 → 岛左缘），单独缩放 **0.5038**：

- 判定：非 StringView + class 含 StatusBar/Battery + 3pt≤宽高且宽<200pt
  + `minX > timeMaxX` 且 `maxX ≤ leadLimit`（岛左缘，实测 152.0）；递归深度 3 +
  `convertRect:toView:` 换算，防深层嵌套用错坐标系
- **三道场景门禁**（1.7.2 实机日志暴露的误伤，必须保留）：① 只处理全屏宽度 fg
  （CC/Spotlight 迷你状态栏宽 361/370，否则左侧信号/WiFi 被误缩）；
  ② 无可视时间（`timeMaxX=0`）跳过；③ 岛左缘须落在 60~200
- 日志确证：`[leadApply] 缩放前 a=1.000 → 后 a=0.5038`

**③ 撤销/复核（必须保留）**：状态栏 item 视图会被系统复用池
（`SBStatusBarReusePoolWindow`）回收后**换身份**（同一个 `_UIStatusBarStringView`
既当【时间】又当【电池百分比/运营商名】）⇒ 只"登记 + 粘滞"必出错（症状＝主屏正常、
进 App/锁屏「时间被缩放」）。故主缩放**排除 StringView**，两张受管表都带撤销：
脱离命中区间连续 1.5s 才「**先摘登记、再还原**」；判据**不用 window/hidden**
（App 前台主屏 fg 会被系统摘窗）。

**④ 参数硬编码（v2.0.0）**：不含设置面板、不读取任何配置文件。
参数（`scale=0.9025 / dy=0.6687(锚点) / threshold=280 / leadScale=0.5038`）
直接写在源码顶部 `#define`/静态变量处。

- 仅注入 SpringBoard（`Filter.Bundles = ["com.apple.springboard"]`）；App 内状态栏由
  SpringBoard 远程渲染，无需向普通 App、WebKit 或 PosterBoard 注入
- ⚠️ RootHide 部署坑：dylib 内**绝不能出现完整 `/System/Library/...` 路径字面量**；
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
├── src/StatusBarScale/                 # 状态栏图标缩放（宿主仅 SpringBoard）
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
