# KeyboardCorner16

iOS 16 系统键盘全按键圆角增强修复版（完美支持字母与数字键盘按键圆角）。

## 修复背景与根因

原第三方插件 `com.liuf.jpyj`（键盘圆角 v0.0.1）在用户切换为数字键盘输入时，按键仍呈现直角矩形，未能保持圆角效果。

### 根因分析（汇编逆向与动态取证）
1. 原版仅 Hook 了 `[UIKBRenderGeometry setRoundRectRadius:]` 将 radius 强制写入 10.0。
2. 数字键盘渲染路径（全键盘 123 数字面、10Key 九宫格数字面、NumberPad）：
   - 系统传入的 `roundRectCorners` 掩码为 `0`（代表不倒角）；
   - 在 `[UIKBRenderer defaultPathForRenderGeometry:]` 中，若 `roundRectCorners == 0`，即使 `roundRectRadius == 10.0`，计算生成的贝塞尔路径依旧退化为无圆角直角矩形；
   - `UIKBRenderFactory10Key` 的 `useRoundCorner` 默认返回 `NO`，`roundCornersForKey:onKeyplane:` 默认返回 `0`；
   - `UIKBTree` 的 `clipCorners` 针对数字键返回 `0`。

## 修复方案

自研 `KeyboardCorner16`（包名 `com.xu.keyboardcorner16`）：
1. **`UIKBRenderGeometry` 全路径拦截**：
   - Hook `setRoundRectRadius:` 强制 10.0；
   - Hook `roundRectRadius` getter 保底 ≥ 10.0；
   - Hook `setRoundRectCorners:`：若传入 0 则强制替换为 `0xF`（`UIRectCornerAllCorners`）；
   - Hook `roundRectCorners` getter：若为 0 强制返回 `0xF`；
   - 补齐 `layeredBackgroundRoundRectRadius` 与 `layeredForegroundRoundRectRadius` 同样为 10.0。
2. **10Key 九宫格数字与面板类适配**：
   - Hook `[UIKBRenderFactory10Key useRoundCorner]` → `YES`；
   - Hook `[UIKBRenderFactory10Key roundCornersForKey:onKeyplane:]` → `0xF`；
   - Hook `[UIKBRenderFactory10Key_Round useRoundCorner]` / `shouldUseRoundCornerForKey:` → `YES`。
3. **按键属性保底**：
   - Hook `[UIKBTree clipCorners]`：返回 `0xF`。
4. **包管理兼容**：
   - 在 control 中声明 `Conflicts: com.liuf.jpyj` 与 `Replaces: com.liuf.jpyj, com.xu.kbprobe`，无缝替换旧包。

## 构建与部署

```bash
./build_deploy.sh
```
包含：
1. Clang arm64e 编译
2. 私有类符号残留检查
3. 远程设备 `ldid -S` 签名与 CodeDirectory 校验
4. 手写 ar/tar.gz 构建 RootHide 标准 deb
5. 自动同步仓库 `debs/` 并生成 `Packages`
6. `dpkg -i` 部署到设备并 `sbreload`
