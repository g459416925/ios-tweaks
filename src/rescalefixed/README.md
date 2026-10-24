# src/rescalefixed — Re:Scale Fixed 440（com.xu.rescalefixed）

固定 iPhone 18 Pro Max（6.9"）逻辑分辨率 **440×956pt @3x** 的重打包方案，
装完即生效、无设置界面，并自带自愈守护。

> 完整设计文档、失效矩阵、踩坑记录在私有工作区
> `rescale2/README-440patch.md`；本目录只放**能公开的构建脚本与源码快照**。

> **2026-10-24 状态**：当前设备与发布包为 `com.xu.rescalefixed 3.1.1`。
> 本目录是发布源快照；与私有工作区 `rescale2/repo-fixed|merge-kb440` 共享的 6 个文件
> 用 `rescale2/check-sync.sh` 校验，不要只改一边。


## 文件

| 路径 | 说明 |
|---|---|
| `build_plan_a.sh` | 一键构建（校验 CDHash → 组 stage → 打包 → 自检），产出 `.deb` |
| `rf_check.sh` | 自检/自愈脚本：装到 `/usr/bin/rf_check`，支持 `--fix` / `--heal` |
| `tools/debbuild.py` | 纯 Python 的 ar + xz deb 打包器（macOS 无 dpkg-deb 时用） |
| `ReScaleKB/ReScaleKB.m` | 键盘 414→440 修正源码（1.0.6 行为级重写） |
| `ReScaleKB/kb440_math.h` | 纯函数层（可在 Mac 上单测，不含 UIKit） |

## 方案要点

1. **零新二进制**：分辨率注入复用原作者 Sniper_GER 的 `ReScale.dylib`（`1.0.5-1`），
   **一个字节都不改**——RootHide 的 trustcache 只认已登记 CDHash，
   自编译/重签的 dylib 注入 backboardd 会被 amfid 拒绝 → 崩溃循环 → 看门狗。
2. **固定值**：`postinst` 写入 110 字节 bplist（`canvas_width=1320`、
   `canvas_height=2868`、`confirmedResolution=true`）。原版 dylib 会 hook
   `CFPreferencesGetAppIntegerValueWithContainer`，把画布相关读取重定向到
   `tf.festival.rescale` 域，所以"写死偏好 = 写死分辨率"。
3. **无界面**：不打包 `ReScalePreferences.bundle` 与 PreferenceLoader 条目，
   安装时顺带清理。
4. **零重启**：`postinst` 绝不 kill/restart 系统进程（`backboardd` 归 `user/501` 域，
   dpkg 事务里 kill 会进 spawn 循环 → 看门狗，踩过两次）。
5. **guard 标记**：原版 `ReScale.dylib` 靠 `/Library/dpkg/info/tf.festival.rescale2.list`
   判断是否装 hook；缺了会**静默失效**。`postinst` 建它，并 `chflags uchg` 锁死。
6. **自愈守护**（3.1.1+）：`com.xu.rescalefixed.heal`（system 域 LaunchDaemon，
   `RunAtLoad` + 每 120 秒）跑 `rf_check --heal`：正常静默退出；发现文件缺失就重写；
   只有修了"标记/偏好"才 `launchctl kickstart` 重启一次 backboardd 让画布重读（10 分钟防抖）。

## 构建

```bash
# 需要同源的 merge-kb440/ 与 baseline 原版 dylib（私有工作区布局）
cd repo-fixed/plan-a && ./build_plan_a.sh
# 覆盖版本号
VER=3.1.2 ./build_plan_a.sh
```

构建脚本内置门禁：`ReScale.dylib` CDHash 必须 `d29ee234…`、
`ReScaleKB.dylib` CDHash 必须 `72002a5d…`（均为设备实测受信版本），
外加 `postinst` 语法检查与产物条目自检。

## 安装后自检

```bash
sudo rf_check          # 15 项体检
sudo rf_check --fix    # 修复丢失的 guard 标记/偏好/注入软链（不重启进程）
tail -20 /var/log/rfheal.log   # 自愈日志
```

## 部署注意（RootHide 特有）

- LaunchDaemon 的 `ProgramArguments[0]` 写**原生路径**（`/bin/sh`）：
  RootHide 的 dpkg 触发器会把它前缀成 jbroot 路径；自己再写 jbroot 前缀会被重复前缀。
- 脚本 shebang 必须 `#!/usr/bin/sh`：设备上 `/bin/sh` 是悬空软链，`#!/bin/sh` 会静默不执行。
- system 域 launchd 运行在真实根命名空间，看不到 `/usr/bin`，
  直接 `Program=/usr/bin/xxx` 会得到 `EX_CONFIG (78)`。
