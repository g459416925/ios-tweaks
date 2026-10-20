# ShotSuite 截图套件

Snapper 3 + BigShot 长截图 + 截图标记 + Hammer It 四合一，一个 deb、一个设置页。

- 包名 `com.xu.shotsuite` · v1.0.3 · iphoneos-arm64e
- 宿主：iPhone 14 Pro Max / iOS 16.5.1 / RootHide + ElleKit
- 四个模块内置即全启用；设置项**平铺在同一页**，只保留 7 个必要项

## 设置页（1.0.3）

```
SNAPPER 3
  Activation methods    截图触发方式（音量+ + 电源）
  OCR settings          OCR 精度 / 算法 / 语言
  Snap history          历史入口 + 保存上限
  Plugins               与 Hammer It / Imgur 的联动
HAMMER IT
  主要功能设置           取词模式 / 复制行为 / 搜索引擎
  翻译服务设置           翻译源与百度 API Key
  编辑菜单设置           长按菜单里的分词/翻译/搜索/链接按钮
截图套件 1.0.3 — 版本 footer
```

**已剔除**（白名单机制，见 `SSKeepList`）：Advanced（阴影/延迟/兼容保存）、Support & License、
启用插件开关、使用说明、悬浮球设置、界面相关设置（模糊/隐藏原文框/全屏）、
注销设备生效、重置所有设置、关于我（公众号/Q群/打赏）。这些项在子面板里仍然存在，
只是不在套件面板暴露；需要时可临时把 label 加回白名单。

## 结构

```
src/
  ShotSuitePrefs.m       面板控制器（白名单过滤 + 官方 API 插入子面板 specifier）
  Root.plist             UI 骨架：2 个分组 + 版本 footer
  ShotSuite.plist        PreferenceLoader 注册
  Info.plist             bundle 描述（NSPrincipalClass）
  postinst / postrm      清理 1.0.0 遗留托管目录
payload/                 4 个原插件全部文件（含 .roothidepatch 链接）
build_deploy.sh          build | pkg | install
```

## 构建 / 部署

```bash
./build_deploy.sh build     # 编译 + codesign ad-hoc
./build_deploy.sh pkg       # 设备上 dpkg-deb 组装
./build_deploy.sh install   # 安装 + respring
```

**签名必须用 `codesign -f -s - --timestamp=none`**：ldid 对 PreferenceBundle 会静默失败
（`code object is not signed at all`），设置 App 加载时直接 `CODESIGNING / Invalid Page` 崩。
面板 bundle 还必须带 `ShotSuitePrefs.roothidepatch -> /usr/lib/DynamicPatches/AutoPatches.dylib`。

## 面板实现要点（改代码前先看）

1. `PSListController` **不会自动加载** bundle 里的 Root.plist → 必须
   `loadSpecifiersFromPlistName:@"Root" target:self`。
2. 它渲染的是私有 ivar `_specifiers` → 必须 `[self setValue:s forKey:@"_specifiers"]`。
3. **子面板 specifier 必须用 `insertContiguousSpecifiers:afterSpecifier:animated:` 插入**。
   直接改数组（哪怕数组内容完全正确、日志显示 10 项）界面也只会显示本 bundle 的 group，
   子项一律不渲染 —— 官方 API 会补 cell 元数据与索引登记。
4. 子控制器实例必须强引用（`_kids`），specifier 的 target 就是它。
5. 过滤用 label 匹配，取法要兼容两种：先 `propertyForKey:@"label"`，为空再走 `-name`。
6. 第三方 bundle 实体在 jbroot 内，真系统视图看不到 → glob
   `/var/containers/Bundle/Application/.jbroot-*` 定位后再 `NSBundle bundleWithPath`。

## 回滚

```bash
ssh iphone-root 'dpkg -r com.xu.shotsuite'
ssh iphone-root 'dpkg -i /var/mobile/shotsuite_backup/com.daodao.snapper3.deb \
  /var/mobile/shotsuite_backup/com.dao.bigshotsnapper3plugin.deb \
  /var/mobile/shotsuite_backup/cn.llld.biaoji.deb \
  /var/mobile/shotsuite_backup/com.lclrc.hammerit.deb && sbreload'
```
原始文件全量备份：`/var/mobile/shotsuite_backup/payload_all.tar`

## 已知

- 长截图 / 截图标记没有独立设置项，入口都在 Snapper 3 里。
- 诊断日志：`/var/mobile/Documents/ShotSuitePrefs.log`（每次开面板记各子面板原始/保留项数）。
