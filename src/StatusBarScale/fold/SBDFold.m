// SBDFold.m —— 折叠模块的 hook 安装与 System Aperture 订阅（iOS 16 适配层）。
#import "SBDFold.h"
#import "DLIFoldController.h"
#import "DLIApertureObserver.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <string.h>
#include <sys/stat.h>

typedef void (*SBDMSHookMessageExFn)(Class cls, SEL sel, IMP replacement, IMP *original);

static SBDMSHookMessageExFn SBDSubstrateHook(void) {
    static SBDMSHookMessageExFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (SBDMSHookMessageExFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx"); });
    return fn;
}

// 与上游 tw_hook.h 同一套判据：去掉参数偏移/帧长度数字与 r/n/V 限定符后逐字符比较，
// 不匹配就跳过该 hook（宁可少一个功能，也不要用错 ABI 破坏寄存器）。
static void SBDNormalizeEncoding(const char *encoding, char *out, size_t cap) {
    if (!encoding || !*encoding || cap == 0) { if (cap) out[0] = '\0'; return; }
    size_t j = 0;
    for (const char *p = encoding; *p && j + 1 < cap; p++) {
        if (*p >= '0' && *p <= '9') continue;
        if (*p == 'r' || *p == 'n' || *p == 'V') continue;
        out[j++] = *p;
    }
    out[j] = '\0';
}

static BOOL SBDEncodingMatches(const char *expected, const char *actual) {
    if (!expected || !*expected || !actual || !*actual) return NO;
    char a[256], b[256];
    SBDNormalizeEncoding(expected, a, sizeof(a));
    SBDNormalizeEncoding(actual, b, sizeof(b));
    return a[0] && strcmp(a, b) == 0;
}

#define SBD_ENC(...) ((const char *const[]){ __VA_ARGS__, (const char *)0 })

static const char *SBDJoinEncoding(char *buffer, size_t cap, const char *const *parts) {
    size_t j = 0;
    for (int i = 0; parts[i]; i++) {
        for (const char *p = parts[i]; *p && j + 1 < cap; p++) buffer[j++] = *p;
    }
    if (cap) buffer[j] = '\0';
    return buffer;
}

static BOOL SBDHook(Class cls, SEL selector, IMP replacement, IMP *original,
                    const char *expectedEncoding, const char *name) {
    if (!cls) {
        SBDFoldLog(@"hook %s: 类不存在，跳过", name);
        return NO;
    }
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        SBDFoldLog(@"hook %s: %@ 方法不存在，跳过", name, NSStringFromSelector(selector));
        return NO;
    }
    const char *actual = method_getTypeEncoding(method);
    if (!SBDEncodingMatches(expectedEncoding, actual)) {
        SBDFoldLog(@"hook %s: 编码不匹配（期望 %s 实际 %s），跳过", name, expectedEncoding,
                   actual ?: "(null)");
        return NO;
    }
    SBDMSHookMessageExFn hook = SBDSubstrateHook();
    if (!hook) {
        SBDFoldLog(@"hook %s: MSHookMessageEx 不可用，跳过", name);
        return NO;
    }
    hook(cls, selector, replacement, original);
    BOOL ok = original && *original;
    SBDFoldLog(@"hook %s → %@", name, ok ? @"已安装" : @"失败");
    return ok;
}

#pragma mark - STUIStatusBar

static void (*sbd_origStatusBarLayout)(id, SEL);
static void (*sbd_origForegroundLayout)(id, SEL);
static void (*sbd_origUpdateData)(id, SEL, id);
static void (*sbd_origUpdateStyle)(id, SEL);
static void (*sbd_origAvoidanceAnimated)(id, SEL, CGRect, id, NSUInteger);
static void (*sbd_origAvoidance)(id, SEL, CGRect);
static void (*sbd_origApertureLayout)(id, SEL);

// 两个 avoidance setter 可能互相转发（iOS 上 setAvoidanceFrame: 会转发到三参数版本），
// 已调整过的 frame 不能被记录/再调整一次。
static NSUInteger SBDDepth = 0;

static void sbd_statusBarLayout(id self, SEL _cmd) {
    if (sbd_origStatusBarLayout) sbd_origStatusBarLayout(self, _cmd);
    [[DLIFoldController sharedController] statusBarDidLayout:self];
}

// iOS 16.5.1 实测：STUIStatusBar 自身 0 个方法，真实实例类在子类里（覆写 layoutSubviews），
// 直接 hook STUIStatusBar 的 layoutSubviews 不会触发。_UIStatusBarForegroundView 的
// layoutSubviews 是现网已验证的可靠入口（状态栏缩放模块就靠它），这里从 fg 向上找状态栏。
static UIView *SBDStatusBarAncestor(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v respondsToSelector:NSSelectorFromString(@"foregroundView")]) return v;
    }
    return nil;
}

static void sbd_foregroundLayout(id self, SEL _cmd) {
    if (sbd_origForegroundLayout) sbd_origForegroundLayout(self, _cmd);
    UIView *statusBar = SBDStatusBarAncestor((UIView *)self);
    if (!statusBar) return;
    [[DLIFoldController sharedController] statusBarDidLayout:statusBar];
}

static void sbd_updateData(id self, SEL _cmd, id data) {
    if (sbd_origUpdateData) sbd_origUpdateData(self, _cmd, data);
    [[DLIFoldController sharedController] statusBarDidUpdateContent:self];
}

static void sbd_updateStyle(id self, SEL _cmd) {
    if (sbd_origUpdateStyle) sbd_origUpdateStyle(self, _cmd);
    [[DLIFoldController sharedController] statusBarDidUpdateContent:self];
}

static void sbd_avoidanceAnimated(id self, SEL _cmd, CGRect frame, id settings, NSUInteger options) {
    if (!sbd_origAvoidanceAnimated) return;
    if (SBDDepth > 0) {
        sbd_origAvoidanceAnimated(self, _cmd, frame, settings, options);
        return;
    }
    DLIFoldController *controller = [DLIFoldController sharedController];
    [controller statusBar:self didRequestAvoidanceFrame:frame settings:settings options:options animated:YES];
    SBDDepth++;
    sbd_origAvoidanceAnimated(self, _cmd, [controller adjustedAvoidanceFrame:frame forStatusBar:self],
                              [controller livelierAvoidanceSettings:settings], options);
    SBDDepth--;
}

static void sbd_avoidance(id self, SEL _cmd, CGRect frame) {
    if (!sbd_origAvoidance) return;
    if (SBDDepth > 0) {
        sbd_origAvoidance(self, _cmd, frame);
        return;
    }
    DLIFoldController *controller = [DLIFoldController sharedController];
    [controller statusBar:self didRequestAvoidanceFrame:frame settings:nil options:0 animated:NO];
    SBDDepth++;
    sbd_origAvoidance(self, _cmd, [controller adjustedAvoidanceFrame:frame forStatusBar:self]);
    SBDDepth--;
}

// iOS 17+ 才有：布局结束点读缓存的 userInfo。
static void sbd_apertureLayout(id self, SEL _cmd) {
    if (sbd_origApertureLayout) sbd_origApertureLayout(self, _cmd);
    [[DLIFoldController sharedController] apertureDidLayout:self];
}

#pragma mark - install

static BOOL SBDKillSwitchPresent(void) {
    struct stat st;
    return stat("/var/mobile/Library/com.xu.statusbarscale/fold_disabled", &st) == 0;
}

void SBDFoldInstall(void) {
    static BOOL finished = NO;
    static int tries = 0;
    if (finished) return;
#if !SBD_FOLD_ENABLED
    finished = YES;
    SBDFoldLog(@"编译期关闭（SBD_FOLD_ENABLED=0），不安装");
    return;
#else
    if (SBDKillSwitchPresent()) {
        finished = YES;
        SBDFoldLog(@"发现 fold_disabled 标记，不安装");
        return;
    }
    // iOS 16.5.1 实测：STUIStatusBar 自身 0 个方法，真身是 _UIStatusBar（243 个方法，
    // 含 _updateWithAggregatedData:/_updateStyleAttributes/regions/setAvoidanceFrame:）。
    // 优先 hook 真身，缺失时才退回 STUIStatusBar（其他 iOS 版本）。
    Class statusBar = objc_getClass("_UIStatusBar") ?: objc_getClass("STUIStatusBar");
    if (!statusBar) {
        if (tries++ < 40) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ SBDFoldInstall(); });
        } else {
            SBDFoldLog(@"_UIStatusBar/STUIStatusBar 等待超时，折叠模块不安装");
            finished = YES;
        }
        return;
    }
    finished = YES;
    SBDFoldLog(@"状态栏目标类=%@", NSStringFromClass(statusBar));

    char encoding[256];
    SBDHook(statusBar, @selector(layoutSubviews), (IMP)sbd_statusBarLayout,
            (IMP *)&sbd_origStatusBarLayout,
            SBDJoinEncoding(encoding, sizeof(encoding), SBD_ENC(@encode(void), "@:")),
            "STUIStatusBar.layoutSubviews");
    SBDHook(statusBar, NSSelectorFromString(@"_updateWithAggregatedData:"), (IMP)sbd_updateData,
            (IMP *)&sbd_origUpdateData,
            SBDJoinEncoding(encoding, sizeof(encoding), SBD_ENC(@encode(void), "@:", @encode(id))),
            "STUIStatusBar._updateWithAggregatedData:");
    SBDHook(statusBar, NSSelectorFromString(@"_updateStyleAttributes"), (IMP)sbd_updateStyle,
            (IMP *)&sbd_origUpdateStyle,
            SBDJoinEncoding(encoding, sizeof(encoding), SBD_ENC(@encode(void), "@:")),
            "STUIStatusBar._updateStyleAttributes");
    SBDHook(statusBar, NSSelectorFromString(@"setAvoidanceFrame:animationSettings:options:"),
            (IMP)sbd_avoidanceAnimated, (IMP *)&sbd_origAvoidanceAnimated,
            SBDJoinEncoding(encoding, sizeof(encoding),
                            SBD_ENC(@encode(void), "@:", @encode(CGRect), @encode(id), @encode(NSUInteger))),
            "STUIStatusBar.setAvoidanceFrame:animationSettings:options:");
    SBDHook(statusBar, NSSelectorFromString(@"setAvoidanceFrame:"), (IMP)sbd_avoidance,
            (IMP *)&sbd_origAvoidance,
            SBDJoinEncoding(encoding, sizeof(encoding), SBD_ENC(@encode(void), "@:", @encode(CGRect))),
            "STUIStatusBar.setAvoidanceFrame:");

    // 可靠入口：状态栏 foreground 的每次布局（状态栏缩放模块的同一入口）。
    Class foreground = objc_getClass("_UIStatusBarForegroundView");
    SBDHook(foreground, @selector(layoutSubviews), (IMP)sbd_foregroundLayout,
            (IMP *)&sbd_origForegroundLayout,
            SBDJoinEncoding(encoding, sizeof(encoding), SBD_ENC(@encode(void), "@:")),
            "FG.layoutSubviews");

    // iOS 17+ 的布局 hook：16.5.1 上方法不存在，SBDHook 会记一行跳过，不影响通知路径。
    Class aperture = objc_getClass("SBSystemApertureViewController");
    SBDHook(aperture, NSSelectorFromString(@"_postLayoutDidChangeNotificationIfNecessary"),
            (IMP)sbd_apertureLayout, (IMP *)&sbd_origApertureLayout,
            SBDJoinEncoding(encoding, sizeof(encoding), SBD_ENC(@encode(void), "@:")),
            "SBSystemAperture._postLayoutDidChangeNotificationIfNecessary");

    // iOS 16.5.1 的正式路径（dyld 缓存实证存在）：
    //   SBSystemApertureLayoutDidChangeNotification + FramesKey/IdentifiersKey。
    [[NSNotificationCenter defaultCenter] addObserverForName:@"SBSystemApertureLayoutDidChangeNotification"
                                                     object:nil
                                                      queue:[NSOperationQueue mainQueue]
                                                 usingBlock:^(NSNotification *note) {
        [[DLIFoldController sharedController] apertureDidLayoutWithNotification:note];
    }];
    SBDFoldLog(@"已订阅 SBSystemApertureLayoutDidChangeNotification（iOS 16 路径）");
    SBDFoldLog(@"安装完成 statusBar=%p aperture=%p", statusBar, aperture);
#endif
}

BOOL SBDFoldIsActive(void) {
    return [[DLIFoldController sharedController] isActive];
}
