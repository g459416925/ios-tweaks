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
| `com.xu.screentimelocker16` | 5.2.0 | **ScreenTimeLocker16** — 让「屏幕使用时间」的 App 限额真正锁得住 |

### ScreenTimeLocker16

还原原版 *DisableOneMoreMinute* 的四层实现，把 App 限额变成真正的锁：

1. **数据层** — 禁止「再使用一分钟」（0/0 限额可长期生效）
2. **设置页** — 允许把限额设成 **0 小时 0 分钟**
3. **拦截页** — 认证优先走 **Face ID**，用不了时回落**屏幕使用时间密码**
4. **菜单弹窗** — 保持系统原样，不注入任何额外选项

不隐藏任何原生按钮，「请求更多使用时间」照常保留。
宿主进程 `SpringBoard`；依赖 `mobilesubstrate`（ellekit 已 `Provides`）。

## 目录结构

```
ios-tweaks/
├── Release / Packages / Packages.bz2   # APT 索引（由 tools/gen_repo.py 生成，勿手改）
├── debs/                               # 实际分发的 .deb
├── src/<包名>/                          # 插件源码 + 构建脚本 + docs
│   ├── ScreenTimeLocker16.m            # 源码（版本号唯一来源：#define STL_VERSION）
│   ├── ScreenTimeLocker16.plist        # 注入过滤（Bundles）
│   ├── build_deploy.sh                 # 交叉编译 + 签名 + 部署到设备
│   ├── build_deb.py                    # 打 .deb（版本号自动取自源码）
│   └── docs/                           # 各版本改动与实机验证记录
└── tools/gen_repo.py                   # 扫描 debs/ 重建 APT 索引
```

## 发布新版本

```bash
# 1. 改 src/<包名>/<包名>.m 里的 #define STL_VERSION
# 2. 交叉编译并签名，产出 <包名>.signed.dylib（同时会部署到手机；见脚本内说明）
cd src/ScreenTimeLocker16 && ./build_deploy.sh && cd ../..
# 3. 打包 deb（版本号自动读取源码，无需手填）
python3 src/ScreenTimeLocker16/build_deb.py
# 4. 把产物丢进 debs/
cp src/ScreenTimeLocker16/<产物>.deb debs/
# 5. 重建 APT 索引
python3 tools/gen_repo.py
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
