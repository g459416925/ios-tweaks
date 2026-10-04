// StatusBarScale.m —— 状态栏右侧图标缩放对齐 v1.0.0
//
// 问题：iPhone 14 Pro Max (iOS 16.5.1) 灵动岛右侧图标与时间不对齐
//   实测基线（_sb_measure.py，1x points）：时间 高12 上沿24 下沿35 重心29.38
//   图标 高13(均值) 上沿22-23 下沿34-35 重心27.71 → 图标偏高 1.66px、偏高 1px
//
// 手法：hook _UIStatusBarForegroundView -layoutSubviews（布局终点，每帧可重入），
//   对右侧（frame.minX >= 阈值，默认 312 = 灵动岛右缘）直接子视图施加
//   transform = 绕中心缩放(scale) + 下移(dy)。transform 不影响 frame 布局，
//   每次布局后重设，幂等。
//   ⚠️ UIView.transform 是绕 anchorPoint(0.5,0.5)=中心 变换；
//      CGAffineTransformTranslate(Scale(s,s),0,dys) 的屏幕位移 = s*dys → dys = dy/s。
//
// 配置 /var/mobile/Library/Preferences/com.xu.statusbarscale.plist（改后需 respring）：
//   enabled(bool,默认YES)  scale(float,默认0.92)  dy(float,默认1.7)
//   threshold(float,默认312)  verbose(bool,默认NO)
//
// 日志：/var/mobile/Documents/sbs_log.txt（含首次布局层级 dump —— 即探针产物）

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define SBS_VERSION @"1.0.0"
#define SBS_LOG_PATH @"/var/mobile/Documents/sbs_log.txt"

static BOOL    gEnabled = YES;
static CGFloat gScale   = 0.92f;
static CGFloat gDy      = 1.7f;
static CGFloat gThr     = 312.0f;
static BOOL    gVerbose = NO;
static int     gDidDump = 0;

static void sbs_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void sbs_log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSDateFormatter *df = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString *line = [NSString stringWithFormat:@"%@ [%@/%d] %@\n",
                      [df stringFromDate:[NSDate date]],
                      [[NSProcessInfo processInfo] processName], getpid(), body];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:SBS_LOG_PATH];
    if (!fh) {
        [line writeToFile:SBS_LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static void sbs_loadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.xu.statusbarscale.plist"];
    if (d) {
        NSNumber *n;
        if ((n = d[@"enabled"])   && [n isKindOfClass:[NSNumber class]]) gEnabled = n.boolValue;
        if ((n = d[@"scale"])     && [n isKindOfClass:[NSNumber class]]) gScale   = n.floatValue;
        if ((n = d[@"dy"])        && [n isKindOfClass:[NSNumber class]]) gDy      = n.floatValue;
        if ((n = d[@"threshold"]) && [n isKindOfClass:[NSNumber class]]) gThr     = n.floatValue;
        if ((n = d[@"verbose"])   && [n isKindOfClass:[NSNumber class]]) gVerbose = n.boolValue;
    }
    if (gScale < 0.3f || gScale > 2.0f) gScale = 0.92f;   // 防呆
}

// 首次布局 dump（等效探针产物：真实类名 + frame）
static void sbs_dumpOnce(UIView *fg) {
    if (gDidDump) return;
    gDidDump = 1;
    NSMutableString *o = [NSMutableString stringWithFormat:
        @"[dump] %@ subviews=%lu  self.frame=%@\n",
        NSStringFromClass(fg.class), (unsigned long)fg.subviews.count,
        NSStringFromCGRect(fg.frame)];
    for (UIView *v in fg.subviews) {
        [o appendFormat:@"  %-42s %@\n",
            class_getName(v.class), NSStringFromCGRect(v.frame)];
        for (UIView *s in v.subviews) {
            [o appendFormat:@"      %-40s %@\n",
                class_getName(s.class), NSStringFromCGRect(s.frame)];
        }
    }
    sbs_log(@"%@", o);
}

static void sbs_apply(UIView *fg) {
    if (!gEnabled) return;
    // 绕中心缩放 + 下移 dy（transform 的平移发生在缩放坐标系 → 除以 s）
    CGAffineTransform t = CGAffineTransformTranslate(
        CGAffineTransformMakeScale(gScale, gScale), 0, gDy / gScale);
    for (UIView *v in fg.subviews) {
        if (CGRectGetMinX(v.frame) >= gThr) {
            if (!CGAffineTransformEqualToTransform(v.transform, t)) v.transform = t;
        }
    }
    if (gVerbose && gDidDump) { /* verbose 帧级日志默认关，避免刷盘 */ }
}

// ===========================================================================
#pragma mark - 运行时 hook（STL 同款模式）
// ===========================================================================

static BOOL SBSHook(Class target, SEL origSel, Class src, SEL implSel) {
    if (!target) return NO;
    Method mo = class_getInstanceMethod(target, origSel);
    Method mi = class_getInstanceMethod(src, implSel);
    if (!mo) { sbs_log(@"[hook] SKIP %@ (目标类无此方法)", NSStringFromSelector(origSel)); return NO; }
    if (!mi) { sbs_log(@"[hook] SKIP %@ (实现缺失)",     NSStringFromSelector(origSel)); return NO; }
    const char *eo = method_getTypeEncoding(mo);
    const char *ei = method_getTypeEncoding(mi);
    if (!eo || !ei || strcmp(eo, ei) != 0) {
        sbs_log(@"[hook] SKIP %@ (%s != %s)", NSStringFromSelector(origSel), eo ?: "?", ei ?: "?");
        return NO;
    }
    IMP origIMP = method_getImplementation(mo);
    IMP myIMP   = method_getImplementation(mi);
    if (!class_addMethod(target, implSel, myIMP, ei)) {
        Method e = class_getInstanceMethod(target, implSel);
        if (e) method_setImplementation(e, myIMP);
    }
    if (!class_addMethod(target, origSel, origIMP, eo)) { /* 已在本类 */ }
    Method m1 = class_getInstanceMethod(target, origSel);
    Method m2 = class_getInstanceMethod(target, implSel);
    if (!m1 || !m2) return NO;
    method_exchangeImplementations(m1, m2);
    sbs_log(@"[hook] OK    %@  %s", NSStringFromSelector(origSel), eo);
    return YES;
}

@interface SBSHelper : NSObject
@end
@implementation SBSHelper
// 交换后：此选择子挂在目标类上指向【原实现】；先调原布局，再做缩放
- (void)sbs_fgLayoutSubviews {
    [self sbs_fgLayoutSubviews];          // 原实现
    @try {
        sbs_dumpOnce((UIView *)self);
        sbs_apply((UIView *)self);
    } @catch (NSException *e) {
        sbs_log(@"[exc] %@", e);
    }
}
@end

static void sbs_install(void) {
    Class FG = objc_getClass("_UIStatusBarForegroundView");
    if (!FG) { sbs_log(@"[hook] FAIL _UIStatusBarForegroundView 不存在"); return; }
    BOOL ok = SBSHook(FG, @selector(layoutSubviews),
                      SBSHelper.class, @selector(sbs_fgLayoutSubviews));
    sbs_log(@"[hook] _UIStatusBarForegroundView.layoutSubviews → %@",
            ok ? @"已安装" : @"失败");
}

__attribute__((constructor))
static void sbs_ctor(void) {
    sbs_loadConfig();
    sbs_log(@"[载入] v%@ proc=%@ pid=%d enabled=%d scale=%.3f dy=%.2f thr=%.0f",
            SBS_VERSION, [[NSProcessInfo processInfo] processName], getpid(),
            gEnabled, gScale, gDy, gThr);
    sbs_install();
}
