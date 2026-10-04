// CompactorFix.m —— Compactor 的「正确时机」重写版
//
// 原版 Compactor 1.0.2 的做法：hook UIKitCore 的 _UIApplicationInitialize，
//   在其中调用 CoreText 私有 API CTFontSetAltTextStyleSpec()。
//   → 实测：**太晚**。等 _UIApplicationInitialize 被调用时，UIKit/字体子系统
//     已经初始化完毕，此时改 spec 对本次启动的字体**没有任何影响**。
//
// 本版做法：在 **dyld 构造函数**（早于 main / UIApplicationMain）里直接调用。
//   → 实测（iPhone 14 Pro Max / iOS 16.5.1）：
//       [ctor] 0=Helvetica ... 2=.SFCompact-Regular 3=.SFCompact-Semibold ...
//              ... 全部 UI 字体类型 0..24 均变为 .SFCompact-*
//       UIFont.systemFontOfSize:12 -> .SFCompact-Regular
//     像素级对比：整屏 13.07% 像素变化；移除后再启动精确回到 0.00%（运行时、进程内生效）。
//
// ⚠️ 因为 CoreText 的字体状态是**进程内**的，所以必须注入到**每一个 UI 进程**
//    （全部 App + SpringBoard）才能做到「系统级」换字体。
//    → 过滤器用 Filter.Classes = [ "UIApplication" ]（ellekit 支持），
//      凡进程里有 UIApplication 类就注入，一次覆盖全部 UIKit App + SpringBoard。
//
// ⚠️ 字体覆盖范围：SF Compact 是**拉丁系**字体（拉丁/希腊/西里尔），
//    不含任何中日韩字形 → 中文仍回退苹方 PingFang，日文/韩文同理。
//    详见 docs/CompactorFix-字体覆盖实测.md
//
#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import <unistd.h>

// 版本号唯一来源（build_deb.py 从这里读取，勿重复填写）
#define CF_VERSION @"1.0.0"

extern void *CTFontSetAltTextStyleSpec(void) __attribute__((weak_import));

__attribute__((constructor))
static void cf_ctor(void) {
    if (!CTFontSetAltTextStyleSpec) {
        NSLog(@"[compactorfix] v%@ symbol NULL, skip", CF_VERSION);
        return;
    }
    // 必须早于该进程任何字体创建 —— 构造函数是 dyld 阶段，满足条件
    CTFontSetAltTextStyleSpec();
    NSLog(@"[compactorfix] v%@ SF Compact applied pid=%d", CF_VERSION, getpid());
}
