# KeyboardCorner16

iOS 16 系统键盘全按键圆角增强修复版，并整合 OLED 深色键盘背景、UnderDock 快捷操作与 Kayoko 剪贴板管理。

## 修复背景与根因

原第三方插件 `com.liuf.jpyj`（键盘圆角 v0.0.1）在用户切换为数字键盘输入时，按键仍呈现直角矩形，未能保持圆角效果。

### v1.0.51 真机日志结论

1. Probe4 对 keyplane 429/430 的只读快照均记录 `keys=32`、`geometries=32`、`geometryDelta=0`，430 的符号键全部是 `visible=1`、`disabled=0`。缺键不是 keyplane 数据丢失，而是下游渲染延迟。
2. 原插件只执行 `[UIKBRenderGeometry setRoundRectRadius:10]`；在 iOS 16.5.1 Truffle 字符键路径上，该值只是未被最终合成图使用的元数据。
3. `UIKBKeyplaneView` 最终层日志证明，普通字符键已烘焙进 `UIKBSplitImageView` 的 `1290×729` 背景 atlas，功能键则由独立 `UIKBKeyView` 的 `_populateLayer:withContents:` 填充。
4. 导出 atlas 的 alpha 通道可直接看到原始小圆角；背景位于第 2 个合成层，第 3 层是字符与底边阴影。
5. 强制 `[UIKBRenderFactory10Key useRoundCorner] -> YES` 和高频逐键同步日志都会阻塞首次渲染，正式版不使用这两条路径。
6. 浅色模式截图与 alpha 导出证明，普通键的合成标签层和功能键的 `flag=2` 均含独立 U 形底部阴影。v1.0.50 仅将阴影轮廓改成 10pt，但仍会在每个键底部中央留下深色横线。
7. v1.0.51 修复前对当前页面 32 个键逐键测量：`y+h-3` 处 32/32 均有连续深色段，普通键长 22–33px，空格键 193px，发送键 87px，与 19px@3x 的 shadow mask 位置和宽度对应。

## 修复方案

自研 `KeyboardCorner16`（包名 `com.xu.keyboardcorner16`）：

1. Hook `UIKBKeyplaneView displayLayer:`，并在调用原实现后处理普通字符键的最终可见层。
2. 对第 2 个 `UIKBSplitImageView` 背景 atlas 做有界连通区检测，只将键尺寸区域裁成 10pt 圆角；保留原 `Always Template` 渲染模式。
3. 对每张独立键图片做 alpha 连通区分类：只有宽高覆盖至少 60%、内部填充率至少 55% 的整键背景才处理；阴影和字符层自动排除，不依赖固定键名或固定 flags。
4. 日志证明独立键最终 backing 是 `8bpp`、无色彩空间的 `CGImageMask`，透明角点字节为 `0`、实心中心约为 `66–77`。实现直接复制原 mask provider 并将 10pt 圆角外字节清零，保留 UIKit 原始着色语义。
5. 对普通键标签 atlas 中每个 `19px@3x`、低填充率的 U 形阴影，以及功能键独立 shadow mask，只清零经几何分类命中的阴影连通区；字符与键帽背景位于其他连通区/图层，不会被清除。
6. 不改 keyplane、键数组、字符 atlas 或 `UIKBRenderGeometry`，不 Hook `useRoundCorner`。
7. 正式版只保留最多 12 条 apply、8 条 atlas transform 和每种独立键背景/阴影各一次的 direct-mask 日志；日志明确区分 `action=rounded` 与 `action=removed`。
8. **包管理兼容**：
   - 与原圆角、OLED、UnderDock、Kayoko 包声明冲突/替换，安装后只保留 `com.xu.keyboardcorner16`。

### v1.0.52 输入法切换瞬态修复

1. 真机宽键探针证明，稳定空格键使用 `Space-Key`，而点击地球图标切换中英文时，UIKit 会短暂改用 `EnabledLanguageIndicator`。
2. 该瞬态键的最终 backing 为 `8bpc / 16bpp / DeviceGray / kCGImageAlphaPremultipliedLast`；v1.0.51 只接受 8bpp `CGImageMask`，因此明确返回空值，瞬态键显示 UIKit 原始小圆角。
3. v1.0.52 对这一精确图像格式保留原 row bytes、色彩空间、bitmap info、decode、插值和 rendering intent，只将几何分类命中的键帽 10pt 圆角外 gray 与 alpha 两字节清零；不按键名硬编码。
4. 候选版连续点击地球图标 8 次，日志捕获 9 次 `EnabledLanguageIndicator flags=1`，全部为 `transformed=1`；120fps 录屏中间帧显示同时退出和进入的两个空格 backing 均保留圆角。

### v1.0.53 输入法切换矩形朦层修复

1. 用户逐帧截图证明，已圆角的语言提示键帽后仍存在覆盖整个空格键的矩形暗色朦层。
2. 三轮定向探针排除内层 flag 2/4 backing（alpha 全为 0）、低 alpha 铺底、键视图背景色及 presentation layer 动画；层树日志最终定位到外层语言提示容器的 `UIKBBackdropView`。
3. 该 backdrop 与空格键同为 `213×49`，背景是灰度黑、alpha `0.100`，但原始状态为 `corner=0 / masks=0`，与截图中的矩形范围完全一致。
4. v1.0.53 不隐藏系统过渡效果；只对 `UIKBKeyView` 当前层或连续父键容器中、尺寸覆盖至少 90% 的 `UIKBBackdropView` 设置 `cornerRadius=10` 和 `masksToBounds=YES`，不依赖固定键名。
5. 候选版连续切换 5 次均记录 `transition-backdrop ... ratios=1.000/1.000 action=rounded radius=10.0 masks=1`；新录制的 120fps、1346 帧视频中，切换中间帧的暗色朦层沿键帽保持圆角。

### v1.0.54 朦层与键帽边缘精确贴合

1. v1.0.53 将 backdrop 按整个 `213×49pt` 容器裁圆，但运行日志证明语言提示键帽的实际 component 是 `624×138px @3x`，起点为 `(8,3px)`，即 `CGRect(2.667, 1.000, 208.000, 46.000)`；容器与键帽主体之间确实存在非对称空隙。
2. v1.0.54 在 `_populateLayer:` 中保存每张实际键帽的 component rect，并将它传给同一键容器的 `UIKBBackdropView`；使用该动态 rect 创建 10pt 圆角 `CAShapeLayer` mask，不写死 inset。
3. 候选日志连续 5 次记录 `insetsTRBL=(1.000,2.333,2.000,2.667) action=component-mask`；120fps、1353 帧录像的 8 次切换中，暗色朦层与键帽边缘重合，不再出现外圈空隙。

### v1.0.57 OLED 与 UnderDock 整合

1. 对 `byg.iosios.net.oledkeyboard 0.0.3` 的 arm64e 方法体完成静态恢复：保留其 5 个 hook、深色判断、黑色/透明背景分支，以及 Emoji 搜索、AutoFill 和视觉效果视图的原始类筛选。
2. 对 `com.p2kdev.underdock 1.0` 恢复默认 6 个快捷按钮、9 种可配置动作、短按/长按、触觉与左右滑动收起键盘；布局保持左右 72pt、底部 20pt、高 42pt、按钮等宽、间距 10pt、16pt SF Symbol。
3. 继续读取原 UnderDock 的 `/var/mobile/Library/Preferences/com.p2kdev.underdock.plist`；文件不存在时使用二进制中确认的默认快捷键和手势开关。
4. 真机运行日志确认 iOS 16.5.1 上全部 11 个新增 hook 的方法签名匹配；截图确认深色键盘纯黑背景、6 个快捷图标和既有圆角同时生效。
5. 横向滑动收起键盘等动作均由动作日志记录目标输入代理与执行结果。

### v1.0.58 Kayoko 整合

1. 从真机 `codes.aurora.kayoko 3.6.1` 提取 Core、Helper、设置面板与 libSandy profile，一并打包到 `com.xu.keyboardcorner16`；卸载原包时不删除用户偏好、历史数据库或图片。
2. 真机设置证明 `ActivationMethod=9` 为预测栏 `1` 与编辑菜单 `8` 的位掩码组合，整合包继续读取 `/var/mobile/Library/Preferences/codes.aurora.kayoko.preferences.plist`。
3. 3.6.1 方法体证明编辑菜单的 `UICommand` 使用 `_Kayoko_OpenTools_ab2e39c7`；该 selector 由 Kayoko 动态添加到 `UIResponder`，并在主队列向 Core 发送 `codes.aurora.kayoko.core.show`。
4. UnderDock 的 `text.bubble` 按钮改为通过 `UIApplication sendAction:` 复用上述 Kayoko 真实入口；原 `insertText:withAlternativePredictions:`、`insertTextOnTap`、`insertTextOnLongPress` 和默认演示文本已删除。
5. 真机编辑菜单基线已成功打开 Kayoko 历史面板，证明 Core/Helper、现有历史和激活入口在 iOS 16.5.1 上有效。

### v1.0.59 候选栏全布局与关联词避让

1. 真机四状态日志证明英文与简体拼音字母页都使用 `small-letters-small-display`，数字页都使用 `numbers-and-punctuation`；仅靠 keyplane 无法区分 Kayoko 是否应显示。
2. `UIKeyboardAutocorrectionController setAutocorrectionList:` 日志证明空闲状态传入 `nil`/零候选；英文关联词出现时 `TIAutocorrectionList candidates` 为非零；中文拼音组合则由 `markedTextRange` 和 `TUICandidateView` 候选链路承载。
3. 完整键盘视图树定位共同内容宿主为 `TUISystemInputAssistantPageView`；英文使用三个 `TUIPredictionViewCell`，中文使用 `TUICandidateCollectionView`。正式实现只在该 45pt 内容页内显示 Kayoko 三按钮，不修改远程键盘根层级。
4. 显示规则为：存在系统候选或正在拼音组合时隐藏 Kayoko；两者都不存在时显示“历史 / 拷贝 / 粘贴”。覆盖层使用不透明系统候选栏底色，避免底层标点或旧内容透出。
5. 真机截图验证简体拼音空闲页显示 Kayoko，输入 `ni` 后只显示中文候选；英文关联词出现时只显示系统关联词，无双层文字、无键盘退出、无新增崩溃。
6. 候选页内部会直接提交底层候选，普通覆盖视图的 `hitTest:` 不足以接管触摸；正式版在共同内容页挂载仅于 Kayoko 可见时启用的取消型点击手势。真机点击“历史”记录 `tag=0 executed=1` 与 Kayoko selector `routed=1`，不再误选底层中文标点或关联词。

### v1.0.61 候选内容实时切换

1. 真机日志证明中文输入 `ni` 后已生成“你、尼、泥……”候选，但 `TUISystemInputAssistantPageView layoutSubviews` 和 `UIKeyboardAutocorrectionController setAutocorrectionList:` 都没有再次调用；旧逻辑因此停留在 `hidden=0`，Kayoko 持续覆盖真实候选。
2. 中文候选的实时更新点是 `TUICandidateCollectionView layoutSubviews`，英文预测的更新点是 `TUIPredictionViewStackContentView layoutSubviews`。插件在这两个已验证的内容更新点后延迟一个主队列周期，再检查当前页内实际可见且带文本的 `TUICandidateCell` / `TUIPredictionViewCell`。
3. 真机回归记录：简体拼音 `ni` 时 `visibleText=1 hidden=1 gesture=0`，UI 只显示中文候选；英文 `He` 时列表为 `predictions=3 candidates=4`，UI 只显示 `“He” / Hey / Hello`；清空候选后记录 `visibleText=0 hidden=0 gesture=1`，Kayoko 恢复显示。
4. Kayoko 的点击手势与覆盖栏使用同一实时状态：系统候选出现时两者同时隐藏/禁用，避免候选已显示但触摸仍被 Kayoko 拦截。

### v1.0.62 Spotlight 重复 Hook 崩溃修复

1. 真机录屏异常帧显示 Spotlight 下拉过渡态在壁纸与搜索页之间闪烁；20 秒实时日志中 Spotlight PID 从 `14870` 连续变化到 `14894`，SpringBoard 同期反复记录场景前后台切换，确认是 Spotlight 崩溃重启循环。
2. 崩溃报告为主线程 `EXC_BAD_ACCESS / SIGSEGV`，故障地址位于栈保护页，栈帧连续重复 `kbc_kayokoPageLayout`。根因是构造阶段与 `setKeyplaneName:` 延迟阶段对同一 `TUISystemInputAssistantPageView.layoutSubviews` 重复 Hook，第二次安装把插件自身存成了“原方法”，导致无限递归。
3. 立即安装与延迟安装现在统一经过 `kbc_installKayokoPageHooksIfAvailable`，只有成功安装 `layoutSubviews` 和 `hitTest:` 后才设置全局安装状态，每个进程最多安装一次。
4. 修复后全新 Spotlight 进程 PID `15139` 持续稳定，日志中 `kayoko-pagebar-once source=constructor` 恰好一次，旧的重复安装路径为零；英文预测和简体拼音候选回归也均保持 `visibleText=1 hidden=1 gesture=0`。

### v1.0.85 双击文案重影根治（Kayoko 原版预测栏注入）

1. 现象：123 数字页上「历史」显示成「厝臾」状的错位字形，字母页正常。放大 3 倍后确认不是两种文字，而是**同一个「历史」被渲染两遍、相差数像素**。
2. 探针证据（1.0.84，bar 已挂到键盘窗口、page 内已无自绘视图）：`TUIPredictionViewCell text=历史 / 拷贝 / 粘贴` 只在 `numbers-and-punctuation` 出现，字母页为空 → 这三个词来自**系统预测栏的数据源**，不是 accessibility 借用。
3. 根因：Kayoko 原版 `KayokoHelper` 的「预测栏」激活方式（其 Root.plist 原话：`displays custom suggestions on the "More Keyboard Keyplane" (123)`）会把 历史/拷贝/粘贴 作为候选注入系统预测栏。它与本插件自绘的同名三按钮重叠渲染，形成双影。
4. 对照实验：把 `KayokoHelper.plist` 临时改名后，数字页立即变清晰；恢复后复现 → 锁定该注入源。
5. 修复：插件构造时把 `ActivationMethod` 的预测栏位清零（`9 -> 8`，`method & ~1`），面板入口（编辑菜单）与自动粘贴不受影响；bar 同时改为挂在 `UIRemoteKeyboardWindow`，彻底脱离预测栏层级，按 `[page convertRect:...]` 同步位置。
6. 真机回归：抖音评论框字母页/数字页「历史/拷贝/粘贴」均无重影；点击「历史」正常拉起 Kayoko 面板；`kayoko pagebars count=0`（page 内零自绘视图）、`super=UIRemoteKeyboardWindow`。

### v1.0.82 Kayoko 栏跨键盘布局字体/位置统一（自指误判根治）

1. 现象：切换数字页与字母页，上方 Kayoko 三按钮字号和位置跳动。像素测量：数字页「历史」46px@3x（15.3pt）、字母页 40px（13.3pt）。
2. 先排除多实例：日志 `kayoko pagebars count=1 subviews=3`、`bar create` 全程仅 1 次、跨 keyplane 的 `page` 与 `bar` 指针不变 —— 每页始终只有一个 bar。
3. 字体真因：`UIButtonTypeSystem` 在 iOS 15+ 的标题样式由 `UIButtonConfiguration` 管理，`titleLabel.font` 会在 keyplane 切换/页面重建时被系统覆盖。改为 `UIButtonTypeCustom` + `systemFontOfSize:17 weight:Regular` + `adjustsFontSizeToFitWidth=NO`，并在 `layoutSubviews` 中强制校验回写。
4. 位置真因（自指误判）：`TUIPredictionViewCell` 会通过 accessibility 把覆盖其上的按钮标签借用为自己的 `accessibilityLabel`（真机日志：cell `text=历史 / 拷贝 / 粘贴`）。候选检测因此把我们自己的按钮当成系统候选，`hidden` 在 0/1 之间反复抖动，表现为文字忽上忽下。
5. 修复：候选统计排除 bar 自身的三个标题文本；隐藏时 `removeFromSuperview` 彻底摘除，显示时挂回 page 顶层并置顶，保证任一时刻只有一套渲染来源。
6. 排除 Kayoko 原版注入：临时禁用 `KayokoHelper.plist`、以及把 `ActivationMethod` 从 9 改 8，现象均不变，确认与 Kayoko 的 Prediction Bar 激活方式无关。
7. 探针实证：临时把标题改成 `AAA/BBB/CCC`，数字页显示的正是 `AAA/BBB/CCC`，证明屏幕上那三个词始终来自我们的 bar。
8. 真机回归：数字页与字母页「历史」包围盒 `x=57..88 / y=625..639` 一致（误差 ≤2px@3x），连拍无跳动；背景保持 clear，直接露出键盘原生材质。

### v1.0.76 Kayoko 栏字体统一（数字页/字母页一致）

1. 真机截图逐像素测量：数字符号页「历史」字高 46px（15.3pt），字母页 40px（13.3pt），同一切换动作字号会变。
2. 根因是 `UIButtonTypeSystem`：iOS 15+ 该类型的标题样式归 `UIButtonConfiguration` 管理，`titleLabel.font` 在 keyplane 切换、页面重建时会被系统配置覆盖，纯设 `systemFontOfSize:15` 并不稳定。
3. 改为 `UIButtonTypeCustom`，显式 `systemFontOfSize:17 weight:Regular`、`adjustsFontSizeToFitWidth=NO`、水平/垂直居中，字重与基线一并锁定。
4. 背景维持 `clearColor` + `opaque=NO`，不合成任何自定义底色，直接露出 `TUISystemInputAssistantPageView` 的原生键盘材质（浅色/深色跟随系统）。
5. 真机复测：字母页与数字页「历史 / 拷贝 / 粘贴」字号、字重、行高一致；日志记录 `kayoko bar create background=inherit(clear) ... type=custom font=17.0`。

### v1.0.75 中文候选判据修复（TUICandidateLabel）

1. 抖音评论框实测复现：中文键盘空闲候选栏（我/你/好/可爱/那/哈哈哈）与 Kayoko 三按钮（历史/拷贝/粘贴）文字重叠同屏。
2. 真机日志（抖音 PID 3671）证明系统候选存在，但插件记录 `composing=0 list=0 visibleText=0 hidden=0`：`TUICandidateCell` 的 `accessibilityLabel/Value` 为空（`text=-`），真实文字挂在子视图 `TUICandidateLabel` 上（`text=我 / 一 / 不是`）；旧判据只认类名含 `CandidateCell` / `PredictionViewCell` 的节点，导致中文候选恒判为无候选。
3. 判据扩展为 `CandidateCell` / `PredictionViewCell` / `CandidateLabel`，并对 Candidate、Prediction 子树内的 UILabel 做文本兜底；可见性仍走 `kbc_viewIsVisibleInPage` 的祖先链校验，被隐藏的历史 cell 不会误判。
4. 修复日志配额吞掉功能的问题：`text-change` 回调原先 `if (sequence >= 80) return;` 会连 `kbc_updateKayokoPage` 一起跳过，第 80 次输入后该刷新路径彻底失效；现在配额只限制详细诊断输出，超出配额仍执行状态刷新。
5. 真机回归（iPhone15,3 / iOS 16.5.1）：中文候选 `ni` 与空闲常用词均记录 `visibleText=1 hidden=1 gesture=0`，候选栏只剩系统候选；英文预测（posted/got/a）同样隐藏；无候选空闲态记录 `visibleText=0 hidden=0`，历史/拷贝/粘贴 正常显示；点击完成收起键盘无残留。

### v1.0.74 Kayoko 双向横屏与底部动画修复

1. 真机日志证明横屏键盘窗口为 `932×430`，而 Kayoko 原面板固定为 `430×400` 并挂在 `430×932` 的竖屏 `UIStatusBarWindow`。v1.0.70 将 bounds 扩成 `932×400`，导致列表内容重新排版、图片放大和模糊；该做法已完全移除。
2. 面板现在保持原始 `430×400` bounds 和 identity transform，临时挂到已经正确旋转的 `UITextEffectsWindow` 内容视图并水平居中。因此不再手工猜测正负 90 度，`landscapeRight=4` 与 `landscapeLeft=3` 共用同一窗口坐标路径。
3. v1.0.72 动画取证记录旧版展开的 presentation frame X 为 `-114→-43→-8→0`，确认原动画经旋转后从左侧进入；旧版关闭还会把 transform 从旋转矩阵改回 identity。正式版关闭原动画，在横屏键盘窗口中沿 Y 轴执行 0.25 秒底部进出。
4. 右横屏展开日志为 `x=251` 恒定、`y=392→324→244→135→35→30`，收回为 `y=30→47→91→192→374→430`；左横屏同样记录 `orientation=3`、X 恒定、Y 从 `401→309→183→61→30`，无倒置或侧向移动。
5. v1.0.73 首次关闭后没有恢复 Kayoko 原父窗口，第二次打开触发 KayokoCore 窗口坐标换算的 `doesNotRecognizeSelector`，崩溃报告为 `SpringBoard-2026-10-12-001441.ips`。v1.0.74 在退场完成后恢复原 `UIStatusBarWindow` 父子关系，再执行原关闭逻辑；左右横屏均通过重复展开/收回/再展开，未产生新崩溃。
6. 左横屏点击历史项 `https://4kvm.site` 后面板正常关闭并将文本插入信息输入框，确认重新挂载没有破坏列表命中和插入功能。

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

## v1.0.51 真机验证

- 设备：iPhone15,3 / iOS 16.5.1 / RootHide / arm64e。
- 字母页 `compositeKeys=26 directKeys=6`；数字页 `compositeKeys=22 directKeys=10`；`#+=` 页 `compositeKeys=23 directKeys=9`。
- 使用 AX 中每个按键的 frame 对截图逐键测量顶部 `y+1` 左右 inset：字母、数字和 `#+=` 三页各 32 键，合计 96/96 均达到 10pt 判定，`unchanged=0`。
- 三页最低 inset 分数均为 8.0，普通键中位数为 9.5；之前遗漏的 shift、删除、模式切换、表情、空格、搜索及独立符号键均已覆盖。
- v1.0.51 日志分别记录字母/数字/特殊符号页 `compositeShadowsRemoved=26/22/23`，独立功能键均记录 `kind=shadow action=removed`，其背景仍单独记录 `action=rounded`。
- 浅色模式三页各 32 键逐键测量：修复前底部深色长线 32/32；修复后共 96/96 键的该长线为 0，且键帽顶部圆角 inset 仍为 9–11px。
- 在抖音浅色评论键盘中连续切换 3 轮，每个布局始终暴露完整 32 键，SpringBoard PID 保持不变，无新增抖音崩溃报告。
