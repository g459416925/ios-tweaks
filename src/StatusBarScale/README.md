# StatusBarScale — 状态栏图标缩放对齐

**包名** `com.xu.statusbarscale` · **版本** 1.4.5 · **宿主** 全部 UIKit App + SpringBoard

## 解决什么问题

灵动岛机型（iPhone 14 Pro Max / iOS 16.5.1 实测）状态栏右侧图标与左侧时间不对齐：

| 项 | 时间 | 图标 | 差 |
|---|---|---|---|
| 墨迹高度 | 12 px | 13–14 px | 图标偏高 +1 |
| 重心 y | 29.4 | 27.7 | 图标偏高 1.66 px |

观感：图标比时间大一圈且往上飘——即许总说的「极度不舒适」。

## 原理

hook 私有类 `_UIStatusBarForegroundView` 的 `-layoutSubviews`（运行时 `objc_getClass`
解析，**零链接期私有符号**），在原布局完成后对灵动岛右侧（`frame.minX >= threshold`）
的直接子视图施加：

```
transform = Translate(Scale(s, s), 0, dy/s)   // 绕中心缩放 s 倍 + 下移 dy pt
```

- `UIView.transform` 绕 anchorPoint（中心）变换，**不参与 frame 布局计算** → 间距、
  点击区域判定完全不受影响；
- 每次布局后重设同一 transform，幂等；灵动岛展开/收起时自动跟随；
- 实测（scale=0.92, dy=1.7）：图标高 13→12（=时间）、重心差 −1.66→**−0.07 px**。

## 配置

`/var/mobile/Library/Preferences/com.xu.statusbarscale.plist`（改后 respring）：

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `enabled` | bool | YES | 总开关（一键停用） |
| `scale` | float | 0.92 | 缩放倍率 |
| `dy` | float | 1.7 | 下移量（pt，正=向下） |
| `threshold` | float | 280 | 右侧判定阈值（frame.minX ≥ 该值的子视图） |
| `verbose` | bool | NO | 预留 |

⚠️ RootHide 坑：SSH 下部署该文件**必须**走
`/rootfs/private/var/mobile/Library/Preferences/`（不带前缀的是影子目录，插件读不到）。

## 日志

`/var/mobile/Documents/sbs_log.txt`：载入参数、hook 结果、**首次布局层级 dump**
（`_UIStatusBarForegroundView` 全部子视图类名+frame，即状态栏真实结构取证）。

## 构建

```
./build_deploy.sh     # 编译→nm 检查→上传 ldid 签名→体积校验→拉回→部署
python3 build_deb.py  # 打 .deb（版本自动取自源码 #define SBS_VERSION）
```

## 实测记录（2026-10-04）

- 部署后 2 次 sbreload 全成功，`sbs_log` 0 异常，CrashReporter 无新增；
- 基线 vs 修改后 `_sb_measure.py` 对比：高度差 +1.00→−1.00、重心差 −1.66→−0.07；
- hook 同时在 SpringBoard 与 Spotlight/各 App 内生效（Filter.Classes=UIApplication）。

## 辅助条宿主架构（v1.4.x 系列实测）

SpringBoard 有三个状态栏相关窗口，fg 会在其间被搬动：

| 窗口 | level | 可见 | 角色 |
|---|---|---|---|
| `UIStatusBarWindow` | 999 | ✅ | 常驻状态栏总窗口（主屏/App fg 复用） |
| `SBStatusBarReusePoolWindow` | 0 | hidden | 备用 fg 池（切 App 时旧 fg 回池并最后布局一次） |
| `SBControlCenterWindow` | — | CC 期间 | CC 打开时主屏 fg 被**借**进此窗口 |

辅助条为全局单例挂在 `fg.superview`，fg 被搬动条会跟着消失/搬错。三道防线：

1. **前台门禁**：拒绝 hidden 窗口、类名含 `ReusePool`/`ControlCenter` 的窗口、
   宽度≠屏宽（CC/Spotlight 迷你 fg 361≠430，内部是伪居中 Pill 假岛）的 fg；
2. **多档重试**：data 变化 / didMoveToWindow 后 0/0.3/0.8/1.5s 强制重排（`gAuxForceRelayout` 跳节流）；
3. **2s 定时自愈**：判据用**硬编码合法窗口名**（`UIStatusBarWindow`）而非
   `gStrip.window != fg.window` —— CC 期间条和 fg 同在 CC 窗口，旧判据会误判"没丢"。

验证口径：CC 开合全程 `stripWin=UIStatusBarWindow` 纹丝不动；CC 收回 / App 退出回主屏
0.6s 内条已在位。
