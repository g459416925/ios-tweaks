// ShotFix.m —— 修 Snapper3「截取全屏」把自己的编辑层拍进图里的问题
//
// 现象：编辑界面点相机（全屏/长截图）后，成图里带着 Snapper3 的工具栏、
//       浮动相机按钮与白色选框。
//
// 定位过程（实测数据，别再瞎猜）：
//   · UIScreen -snapshotViewAfterScreenUpdates:          hook 成功但零命中
//   · UIScreen -_snapshotRect:intoImageOfWidth:height:   iOS16 已不存在
//   · UIScreen -_snapshotExcludingWindows:withRect:      hook 成功但零命中
//   · UIWindow -takeFullScreenShot（父类那份）           hook 成功但零命中
//   · UIApplication -captureScreenShot                   hook 成功但零命中
//   · SnapperCropOverlayViewController -sendForScreenshot ← 相机按钮真正走这里（崩溃栈实证）
//
// 崩溃事故（2026-10-18 21:37）：第一版把 sendForScreenshot 的返回值当 id 接，
//   ARC 对返回值 objc_retain → KERN_INVALID_ADDRESS at 0x20。
//   按钮 action 的返回值本来就被忽略，所以这里**一律 void 转发，不碰返回值**。
//
// 注入：com.apple.springboard
// 日志：/var/mobile/Documents/ShotFix.log

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#define SF_VERSION @"1.4.1"
static NSString *const kLog = @"/var/mobile/Documents/ShotFix.log";

static void sflog(NSString *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], m];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    @try {
        if (![fm fileExistsAtPath:kLog]) [d writeToFile:kLog atomically:YES];
        else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLog];
            [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile];
        }
    } @catch (__unused NSException *e) {}
}

#pragma mark - 隐藏 / 恢复 Snapper 窗口

// 用 alpha 而不是 hidden：
//   hidden 会触发 didMoveToWindow / 布局 / 状态回调，长截图多屏流程中途被打断会
//   把下游状态搞坏（std::terminate / abort）。alpha 只影响绘制，不动逻辑状态。
static NSMutableArray<NSArray *> *gSaved;    // [@(origAlpha), window]

static BOOL SFIsSnapperWindow(UIWindow *w)
{
    NSString *cn = NSStringFromClass([w class]);
    if (!cn.length) return NO;
    return [cn containsString:@"Snapper"] || [cn containsString:@"SNP"] ||
           [cn containsString:@"BigShot"];
}

static void SFBegin(void)
{
    if (gSaved) return;                   // 已有一次未恢复的隐藏，复用
    gSaved = [NSMutableArray array];
    CGRect sb = [UIScreen mainScreen].bounds;

    static NSString *const kSystemKeep[] = {
        @"Keyboard", @"StatusBar", @"ControlCenter", @"NotificationCenter",
        @"TextEffects", @"Pasteboard", @"RecordingIndicator"
    };

    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        NSString *cn = NSStringFromClass([w class]);
        BOOL isSnapper = SFIsSnapperWindow(w);

        BOOL isSystem = NO;
        for (int i = 0; i < 7; i++) {
            if ([cn containsString:kSystemKeep[i]]) { isSystem = YES; break; }
        }
        BOOL isScreenshotUI = [cn containsString:@"ScreenshotsWindow"];
        BOOL highLevel = (w.windowLevel >= UIWindowLevelStatusBar);
        BOOL small = (w.frame.size.width < sb.size.width * 0.92) ||
                     (w.frame.size.height < sb.size.height * 0.92);

        if (w.alpha <= 0.01) continue;
        if (isSnapper || isScreenshotUI || (highLevel && small && !isSystem)) {
            [gSaved addObject:@[@(w.alpha), w]];
            w.alpha = 0;
            sflog(@"  alpha->0 %@ (lvl %.0f)", cn, w.windowLevel);
        }
    }

    if (gSaved.count) {
        [CATransaction flush];
        sflog(@"hide %lu window(s) by alpha", (unsigned long)gSaved.count);
    }
}

static void SFEnd(void)
{
    if (!gSaved) return;
    for (NSArray *pair in gSaved) {
        UIWindow *w = pair[1];
        w.alpha = [pair[0] doubleValue];
    }
    if (gSaved.count) [CATransaction flush];
    sflog(@"restore %lu window(s)", (unsigned long)gSaved.count);
    gSaved = nil;
}

#pragma mark - Hook（只此一个，且 void 转发）

typedef void (*SFVoidFn)(id, SEL);
static SFVoidFn gOrigSendShot;

// ⚠️ 必须是 void：原方法返回值类型未知，按 id 接会被 ARC retain 成野指针崩溃
//
// 恢复必须延迟：sendForScreenshot 只是"发起请求"，真正取帧在之后的异步流程里。
// 立即恢复会让 ActionView（相机+X 快捷条）重新画回去，正好被拍到。
// 这也是"编辑界面里点相机没问题、桌面快捷条点相机有问题"的原因。
static void SFMySendShot(id self, SEL _cmd)
{
    sflog(@"sendForScreenshot 命中 (%@)", NSStringFromClass([self class]));
    SFBegin();
    if (gOrigSendShot) gOrigSendShot(self, _cmd);
    // 长截图要滚动多屏，可能持续好几秒；固定延时不能太短，
    // 否则会在流程中途恢复窗口。这里给 8 秒，并被下一次请求续期。
    static NSUInteger gen = 0;
    NSUInteger my = ++gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (my != gen) return;            // 期间又有新请求，让它继续持有
        SFEnd();
    });
}

// 长截图（滚动截屏）走的是 SnapperWindow 自己的 takeFullScreenShot，
// 与普通全屏的 sendForScreenshot 是两条路。父类 UIWindow 那份拦不到（子类覆盖）。
// takeFullScreenShot 的 encoding 是 @16@0:8 —— **返回对象**，不能用 void 转发，
// 否则调用方读到垃圾寄存器值。用 __bridge 原样透传，不增不减引用计数。
typedef void *(*SFObjFn)(id, SEL);
static SFObjFn gOrigTakeFull;

static id SFMyTakeFull(id self, SEL _cmd)
{
    sflog(@"takeFullScreenShot 命中 (%@)", NSStringFromClass([self class]));
    SFBegin();
    void *r = gOrigTakeFull ? gOrigTakeFull(self, _cmd) : NULL;
    static NSUInteger gen2 = 0;
    NSUInteger my = ++gen2;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (my != gen2) return;
        SFEnd();
    });
    return (__bridge id)r;
}

#pragma mark - 安装

static BOOL SFHookInstance(Class cls, SEL sel, IMP repl, IMP *orig)
{
    if (!cls || !sel) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (orig) *orig = method_getImplementation(m);
    sflog(@"  %s -%s encoding=%s", class_getName(cls), sel_getName(sel),
          method_getTypeEncoding(m));
    method_setImplementation(m, repl);
    return YES;
}

static void SFInstall(void)
{
    // 关键：这方法定义在 Snapper3 自己的类上，拦 UIWindow/UIScreen 的父类版本无效
    Class cls = objc_getClass("SnapperCropOverlayViewController");
    if (!cls) { sflog(@"找不到 SnapperCropOverlayViewController"); return; }
    BOOL ok = SFHookInstance(cls, sel_registerName("sendForScreenshot"),
                             (IMP)SFMySendShot, (IMP *)&gOrigSendShot);
    sflog(@"hook sendForScreenshot = %d", ok);

    Class sw = objc_getClass("SnapperWindow");
    if (sw) {
        BOOL ok2 = SFHookInstance(sw, sel_registerName("takeFullScreenShot"),
                                  (IMP)SFMyTakeFull, (IMP *)&gOrigTakeFull);
        sflog(@"hook SnapperWindow -takeFullScreenShot = %d", ok2);
    } else {
        sflog(@"找不到 SnapperWindow");
    }
}

__attribute__((constructor)) static void SFInit(void)
{
    sflog(@"ShotFix %@ 注入 %@", SF_VERSION,
          [[NSProcessInfo processInfo] processName]);
    // Snapper3 的 category 方法可能在更晚才注册
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SFInstall(); });
}
