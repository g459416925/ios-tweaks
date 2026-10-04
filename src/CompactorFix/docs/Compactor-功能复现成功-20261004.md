# Compactor 功能「hook 复现」验证报告 —— 成功

> 设备：iPhone 14 Pro Max（iPhone15,3）· iOS 16.5.1（20F75）· RootHide + ellekit 1.2-1
> 日期：2026-10-04 · 结论时间：14:05–14:18

## 一、结论

**能实现。** 原版 `CTFontSetAltTextStyleSpec()` **在 iOS 16.5.1 上完全有效**，我们把系统字体成功切换成了 **SF Compact**（Apple Watch 字体）。

原版 Compactor 1.0.2 失效的**真正原因不是 API 失效，而是「调用时机太晚」**：

| | 调用位置 | 结果 |
|---|---|---|
| 原版 Compactor | `_UIApplicationInitialize` 钩子里 | ❌ 字体不变（UIKit 字体子系统此时已初始化完毕） |
| **本版 CompactorFix** | **dyld 构造函数（早于 main）** | ✅ 全部 UI 字体 → `.SFCompact-*` |

## 二、决定性证据

### 2.1 插桩对比（同一探针，仅调 setter 时机不同）

**对照组（不调用）**：
```
[cp2] [ctor] kCTFontUIFontSystem -> PS=.SFUI-Regular family=.AppleSystemUIFont
[cp2] total PS names=282, matching(SF|Compact)=0
```

**实验组（构造函数里先调 setter，再做本进程第一次字体查询）**：
```
[cp3] CTOR pid=8992 setFirst=1 sym=0x727000019db97ee4
[cp3] >>> setter CALLED at ctor (before any font query)
[cp3] [ctor] 0=Helvetica 1=Menlo-Regular 2=.SFCompact-Regular 3=.SFCompact-Semibold
             4=.SFCompact-Regular ... 24=.SFCompact-Regular      ← 全部 0..24 型全变
[cp3] UIFont.systemFontOfSize:12 -> .SFCompact-Regular
```

### 2.2 像素级对拍（自建截图存盘管线，绕开 MCP 不落盘的限制）

| 对比 | 变化像素 |
|---|---|
| 默认基线 vs SF Compact 生效 | **13.07%**（覆盖 y=110→931 整个内容区） |
| 默认基线 vs 移除探针后重启 | **0.00%**（精确打回） |
| SF Compact vs 移除探针后重启 | 13.07% |

⇒ 字体替换是**真实、可逆、进程内**的。

### 2.3 注入覆盖度

用 `Filter = { Classes = [ "UIApplication" ] }`（凡进程里有 UIApplication 类就注入）：

```
[compactorfix] SF Compact applied pid=9026   ← 设置 (Preferences)
[compactorfix] SF Compact applied pid=9038   ← 时钟 (MobileTimer)
```

⇒ **ellekit 支持 `Classes` 过滤器**，可覆盖全部 UIKit App + SpringBoard，无需枚举 bundle id。

### 2.4 安全性

全程 **CrashReporter 97 → 97，零新增崩溃**（含设置、时钟多次冷启动）。

## 三、交付物

### 3.1 源码 `tweak_stl/build/CompactorFix.m`

```objc
#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import <unistd.h>

extern void *CTFontSetAltTextStyleSpec(void) __attribute__((weak_import));

__attribute__((constructor))          // ★ 关键：dyld 阶段，早于 main/UIApplicationMain
static void cf_ctor(void) {
    if (!CTFontSetAltTextStyleSpec) { NSLog(@"[compactorfix] symbol NULL, skip"); return; }
    CTFontSetAltTextStyleSpec();
    NSLog(@"[compactorfix] SF Compact applied pid=%d", getpid());
}
```

### 3.2 过滤器 `CompactorFix.plist`

```
{ Filter = { Classes = [ "UIApplication" ] } }   // 二进制 plist
```

### 3.3 编译 / 部署

```sh
clang -arch arm64e -miphoneos-version-min=14.0 \
  -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
  -dynamiclib -fobjc-arc -O2 -framework Foundation -framework CoreText \
  -undefined dynamic_lookup \
  -install_name /Library/MobileSubstrate/DynamicLibraries/CompactorFix.dylib \
  -o CompactorFix.dylib CompactorFix.m
# ⇒ 49528 B（未签名）→ 50288 B（ldid -S 后，+760 B）
# 部署：cp 到 /usr/lib/TweakInject/ + chmod 755 / chown root:wheel
```

设备现状：`/usr/lib/TweakInject/CompactorFix.dylib` + `.plist` **已部署并生效**（见对比图 `CompactorFix-字体对比.jpg`）。

## 四、✅ respring 后「系统级」验证 —— 已全量切换（2026-10-04 14:23–14:26）

许总要求「全都要切换 → respring」。执行结果：

| 步骤 | 结果 |
|---|---|
| `sbreload` | rc=0；SpringBoard PID **7856 → 9084 → 9196**（三次都立即复活，未黑屏） |
| MCP 断线 | 约 10–20 s 后自动恢复 |
| **SpringBoard 字体** | ✅ **`.SFCompact-Regular`**（见下） |
| Spotlight 字体 | ✅ `.SFCompact-Regular` |
| 真实崩溃 | **0**（计数 97→98，唯一新增是 `WiFiLQMMetrics-*.ips`，`bug_type=221` = WiFi 链路质量**指标报告，非崩溃**） |

### 4.1 SpringBoard 切换的**决定性证据**

`compile-time` 探针在**构造期写文件**（respring 会掐断 syslog 流，写文件不会）：

```
CTOR  font12=.SFCompact-Regular    pid=9196 proc=SpringBoard
LATER font37.5=.SFCompact-Regular  pid=9196 proc=SpringBoard
CTOR  font12=.SFCompact-Regular    pid=9212 proc=Spotlight
```

- `LATER font37.5` 用的是**未被缓存的字号**，排除了字体缓存造成的假阴性，且与加载顺序无关
- ⇒ `Classes = ["UIApplication"]` **确实覆盖 SpringBoard**；CompactorFix 在其中生效

### 4.2 ⚠️ 一个反例：状态栏时间**不能**用来判定字体

状态栏时间是 **SpringBoard 渲染**的，本以为可用它判断，结果：
前后两图时间字形宽度 **完全一致**（"4"=10px、"2"=9px/8px、"1"=2px）——
因为状态栏时钟用的是**等宽（tabular）数字**，对字体族不敏感。
⇒ **别用状态栏时间判断字体是否切换**（我一度被放大截图的观感误导）。

## 五、遗留与注意

1. ⚠️ **CoreText 字体状态是「进程内、运行时」的** → 已有 0.00% 回退实验证明：**杀掉进程即失效**。
   - 重启设备后：**所有进程都会重新注入并生效**（注入发生在进程启动时），所以「重启后失效」的说法**不成立**；
     但**已经开着的旧进程**不会自动变，需重启该 App。
2. ⚠️ **respring 时 `mcp-logreader` 必被杀**（实测 3 次：起 nohup 后台抓取 → respring → 文件停止增长）。
   ⇒ 想抓 respring 期间的日志，**唯一可靠办法是让探针写文件**，或把读取器做成 launchd 常驻。
3. ⚠️ SF Compact 比 SF Pro 更窄，个别 App 版式可能显得更紧凑（不崩，仅观感）。
4. 本版**未**做 Sileo 打包（可直接 `dpkg-deb` 打包，或仅保留文件级部署）。

## 六、方法论沉淀（本次新增）

- **`CTFontSetAltTextStyleSpec` 必须在构造函数调用**：hook `_UIApplicationInitialize` 太晚。
  一般化教训：**「设置类」私有 API 往往要在目标子系统初始化之前设置**，`%ctor` 才是安全窗口。
- **之前两次误判的根因**：
  1. `UIFont.systemFontOfSize:` **有进程内缓存** → 同一进程内「调用前/调用后」查询必然相同，**是假阴性**；
     正确做法是**跨进程对比**（不同进程各查一次）。
  2. hook `_UIApplicationInitialize` 的时机本身就不对。
- **截图像素对拍管线**（解决 MCP 截图不落盘）：
  直连 `http://192.168.1.5:8090/mcp` 发 `tools/call {"name":"screenshot"}`，取 `result.content[0].data` base64 解码存盘 → Pillow 比对。
  脚本 `_mcp_shot.py`。
- **`Filter.Classes = ["UIApplication"]` 可用**（ellekit 支持），是「全 App 生效」类插件的最省事过滤器。

## 七、SF Compact 到底覆盖哪些文字？（2026-10-04 补充）

> 许总问：「他是不是只包含英文字体，因为我感觉除了英文，其他的好像没有变化」

**答案：对，SF Compact 是「拉丁系」字体——它不含一整个中日韩字形，所以中文照旧走苹方（PingFang）回退，视觉上"没变"。**

### 7.1 客观取证

把设备字体拉到本机解析 cmap（`fontTools`）：

```sh
scp iphone-root:/rootfs/System/Library/Fonts/Watch/SFCompact.ttf ./_SFCompact.ttf   # 1,733,808 B
```

| 属性 | 值 |
|---|---|
| family / PostScript | `.SF Compact` / `.SFCompact-Black` |
| mapped codepoints | **1358** |
| 字形数 | **2509** |

### 7.2 Unicode 区段覆盖表

| 区段 | 码位数 | 结论 |
|---|---|---|
| Latin Basic+Ext　U+0020–024F | **415** | ✅ 主体 |
| Latin Ext-B　U+1E00–1EFF | **245** | ✅ |
| Cyrillic　U+0400–04FF | **220** | ✅ |
| Greek　U+0370–03FF | **73** | ✅ |
| 标点　U+2000–206F | 40 | ✅ |
| 货币　U+20A0–20CF | 26 | ✅（含泰铢 ฿ U+0E3F） |
| 箭头　U+2190–21FF | 14 | ✅ |
| 数学运算　U+2200–22FF | 18 | ✅ |
| **CJK 符号　U+3000–303F** | **0** | ❌ |
| **平假名　U+3040–309F** | **0** | ❌ |
| **片假名　U+30A0–30FF** | **0** | ❌ |
| **CJK 统一表意　U+4E00–9FFF** | **0** | ❌ |
| **CJK 扩展 A　U+3400–4DBF** | **0** | ❌ |
| **谚文音节　U+AC00–D7AF** | **0** | ❌ |
| **全角形式　U+FF00–FFEF** | **0** | ❌ |
| 希伯来/阿拉伯/Emoji | **0** | ❌ |

> 注：除上表外还有约 250 个「杂项符号」码位（带圈数字 ①、方框箭头、几何图形、商标 ™、发丝空格 F8FF 等），仍属拉丁/符号体系，与中日韩无关。

### 7.3 回退链（为什么中文没变）

系统对「SF Compact 没有的字形」按语言回退到下列设备字体（均为 iOS 16 原始版，2023-06-15）：

| 文字 | 回退字体 | 路径 | 体积 |
|---|---|---|---|
| 中文 | PingFang（苹方） | `/System/Library/Fonts/LanguageSupport/PingFang.ttc` | 77.9 MB |
| 日文 | Hiragino Kaku Gothic | `/System/Library/Fonts/Core/HiraginoKakuGothic.ttc` | 23.7 MB |
| 韩文 | Apple SD Gothic Neo | `/System/Library/Fonts/Core/AppleSDGothicNeo.ttc` | 22.3 MB |

⇒ 换字体后**只有拉丁/希腊/西里尔字形变了**，中日韩仍旧由苹方等渲染，**这就是「除了英文其他没变化」的原因**，属预期行为、非故障。

### 7.4 附：Apple Watch 字体族（均在 `Watch/`）

`SFCompact.ttf`、`SFCompactItalic.ttf`、`SFCompactRounded.ttf`、`SFCompactSoft.ttc` —— 全部同为拉丁覆盖，若换成 Rounded/Soft 也一样不含中文。
