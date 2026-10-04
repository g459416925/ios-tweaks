# StatusBarScale — 状态栏图标缩放对齐

**包名** `com.xu.statusbarscale` · **版本** 1.4.6 · **宿主** 全部 UIKit App + SpringBoard

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

## 辅助条宿主架构（v1.4.x 系列实测终版）

SpringBoard 的状态栏 fg 在四个窗口间被借动，App 内状态栏为 SB 远程渲染：

| 窗口 | 角色 | 门禁 |
|---|---|---|
| `UIStatusBarWindow` (level 999) | 常驻总窗口：主屏/锁屏 fg 复用 | ✅ 放行 |
| `SBMainSwitcherWindow` | **App 前台的正宿主**（App 内状态栏由 SB 远程渲染，App 进程 windows=1 且无 fg 实例） | ✅ 放行 |
| `SBStatusBarReusePoolWindow` (hidden) | 备用 fg 池（切 App 时旧 fg 回池） | ❌ 拒绝 |
| `SBControlCenterWindow` | CC 迷你 fg（宽 361 假岛） | ❌ 拒绝 |

【实测铁证 19:40】App 进程 windows=1、树内无 `_UIStatusBarForegroundView`；App 内 fg
首挂窗早于 dylib ctor → hook 装好后 App 进程内 fg 永不触发布局 → App 进程做 3 轮
主动扫描（0.5/2/5s）兜底。锁屏判定用 `SBLockScreenManager.uiIsLocked`
（StringView.y 判据不可用：主屏与锁屏的 fg 内部坐标相同 y=18.67）。

## v1.4.6 五道防线

1. **门禁进程分流**：SB 内放行 UIStatusBarWindow+MainSwitcher、拒 ReusePool/CC/hidden；
   App 内只拒 hidden；
2. **锁屏隐藏**：`uiIsLocked` → 条 hidden，解锁布局触发自动恢复；
3. **host 同窗防护**：`host.window != fg.window` 不搬家（过渡瞬间容器漂移防护）；
4. **多档重试 ×4 路事件**：data 变化 / didMoveToWindow / didMoveToSuperview /
   setHidden: 各排 0/0.3/0.8/1.5s 强制重排（`gAuxForceRelayout` 跳节流）；
5. **1s 自愈 + 见过表**：gActiveFG 陈旧时从弱引用表找回当前合法 fg 实测 1s 内把条
   从 MainSwitcher/ReusePool 搬回主屏宿主。

## 工程坑（v1.4.6 新增）

- **日志多进程互踩**：限流统计 `writeToFile atomically:YES` 是整文件覆盖 —— SB 与
  App 共写同一 sbs_log 时互删对方全部行 → 改 fileHandle append；
- **ctor 内日志被限流吞**：[载入] 后 50ms 内的 [hook] 行全丢 → install 的 hook 结果
  用 `sbs_logNow` 直写（一次性日志直写安全）；
- **诊断日志分级**：关键事件（[move]/[heal]/[unhide]/[dmsup]/[scan]）直写不限流，
  dump 类走 20 行/秒限流；plist `verbose=YES` 开启。
