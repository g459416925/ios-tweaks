# CompactorFix

把系统 UI 字体整体切换成 **Apple Watch 的 SF Compact**。iOS 16.x / RootHide (arm64e)。

- 包名：`com.xu.compactorfix`
- 版本：见 `CompactorFix.m` 里的 `#define CF_VERSION`（唯一来源）
- 宿主：**全部 UIKit App + SpringBoard**（`Filter.Classes = ["UIApplication"]`）
- 依赖：`mobilesubstrate`（ellekit 已 `Provides`）

## 原理

原版 **Compactor 1.0.2** hook `UIKitCore` 的 `_UIApplicationInitialize`，在其中调用
CoreText 私有 API `CTFontSetAltTextStyleSpec()`。实测**该时机太晚**——字体子系统
此时已初始化完毕，改 spec 对本次启动毫无影响，所以插件"看起来没生效"。

本版把调用挪到 **dyld 构造函数**（早于 `main` / `UIApplicationMain`）：

```objc
extern void *CTFontSetAltTextStyleSpec(void) __attribute__((weak_import));

__attribute__((constructor))
static void cf_ctor(void) {
    if (CTFontSetAltTextStyleSpec) CTFontSetAltTextStyleSpec();
}
```

实测结果：`kCTFontUIFontType` 0..24 全部变为 `.SFCompact-*`，
`UIFont.systemFontOfSize:12 → .SFCompact-Regular`，整屏 **13.07%** 像素变化；
移除后再启动精确回到 **0.00%**（说明字体状态是进程内、运行时的）。

## ⚠️ 覆盖范围：SF Compact 是拉丁系字体

SF Compact 共 1358 个码位 / 2509 字形，覆盖：

| 有覆盖 | 无覆盖（全为 0） |
|---|---|
| Latin 基本+扩展 415 · Latin 扩展-B 245 · 西里尔 220 · 希腊 73 · 标点 40 · 箭头/数学 32 · 货币 26 | **CJK 表意 / 假名 / 谚文 / 全角 / CJK 符号 / 希伯来 / 阿拉伯 / Emoji** |

⇒ **中文仍回退苹方 `PingFang.ttc`**，日文走 `HiraginoKakuGothic.ttc`，韩文走
`AppleSDGothicNeo.ttc`。**中文外观不变是预期行为，不是故障。**

## 构建 / 发布

```bash
# 1) 交叉编译 + 签名 + 部署到设备（产出 CompactorFix.signed.dylib）
./build_deploy.sh
# 2) 打 .deb（版本号自动取自 .m）
python3 build_deb.py
# 3) 丢进仓库 debs/ 并重建索引
cp CompactorFix_*_iphoneos-arm64e.deb ../../debs/
python3 ../../tools/gen_repo.py
```

生效需 **respring**（`sbreload`）；单独重启某个 App 只影响该 App。

## 文件

| 文件 | 说明 |
|---|---|
| `CompactorFix.m` | 源码（版本号唯一来源 `CF_VERSION`） |
| `CompactorFix.plist` | 注入过滤（二进制 plist，Classes = UIApplication） |
| `build_deploy.sh` | 编译 + `ldid -S` 签名 + 体积校验 + 部署 |
| `build_deb.py` | 手写 ar 归档打 .deb |
| `docs/` | 功能复现与字体覆盖实测记录 |
