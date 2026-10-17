// BounceIt16.m —— 「果冻弹性动画」自研版（替代 2018 年的 com.jakeashacks.bounceit）
//
// 原版原理（已完整逆向 + 探针验证）：
//   劫持 SpringBoard 的动画参数类，让 getter/setter 返回硬编码弹簧参数。
//   iOS 16.5.1 上真实存在的目标只有两个类（探针实测）：
//     SBFFluidBehaviorSettings : -setDampingRatio:      (SpringBoardFoundation, 51 methods)
//     SBFAnimationSettings     : -damping/-stiffness/-mass/-epsilon (SpringBoardFoundation, 36 methods)
//   下面这些在原版里存在但在 iOS 16 已消失，故不再挂：
//     SBFluidBehaviorSettings / SBAnimationSettings / SBFSpringAnimationSettings
//     SBReachabilitySettings.* / SBAppSwitcherSettings.*（它们改用 -animationSettings 转发到 SBFAnimationSettings）
//
// 阻尼比 zeta = damping / (2*sqrt(stiffness*mass))，omega = sqrt(stiffness/mass)
//   v1.0.1: 30 / (2*sqrt(1666*2.5)) = 0.232 → 过冲 47%、震荡 ~2.7 次、收敛 ~0.67s
//   v1.0.2: 42 / (2*sqrt(1666*2.5)) = 0.325 → 过冲 34%、震荡 ~2.0 次、收敛 ~0.48s
//           （许总反馈：界面已就位后仍在晃 = 收敛时间 > 视觉就位时间，故回调 zeta）
//   观感参考：0.60≈弹一下就停 | 0.43(原版)≈1~2 下 | 0.33≈弹 2 下即停 | 0.23≈弹 3~4 下(略拖尾)
// 保持 stiffness/mass 不变 ⇒ 只改"弹多猛/弹几下"，不改动画节奏（改 stiffness 会改频率）。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <unistd.h>

// ellekit 在运行时提供（不链接 CydiaSubstrate，避免 RootHide 下依赖/签名问题）
extern void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result);

// —— 版本（唯一来源；build_deploy.sh 从这里读，发布时勿手填）——
#define BIT16_VERSION @"1.1.10"

// —— 可调参数 ——
static const double kBDRatio   = 0.33;    // SBFFluidBehaviorSettings.dampingRatio（越小越弹）
static const double kBDamping  = 42.0;    // SBFAnimationSettings.damping（越小越弹）
static const double kBSness     = 1666.0;  // SBFAnimationSettings.stiffness
static const double kBMass      = 2.5;     // SBFAnimationSettings.mass
static const double kBEpsilon   = 0.0;     // SBFAnimationSettings.epsilon
static void blog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

// 临时放大验证值：让控制中心和通知中心的命中肉眼清晰可辨。
static const CGFloat kCenterBounceOffset = 100.0;
// 仅用于控制中心/通知中心；降低阻尼以增大过冲和回弹次数，不改变全局动画。
static const CGFloat kCenterBounceDamping = 18.0;
static const CFTimeInterval kCenterBounceDuration = 2.2;

#define BLOG_PATH "/var/mobile/Documents/bounce16.log"

static void blog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen(BLOG_PATH, "a");
    if (!f) return;
    fprintf(f, "%s\n", s.UTF8String);
    fclose(f);
}

// —— hook 实现 ——
static void (*orig_setDampingRatio)(id, SEL, double) = NULL;

static void my_setDampingRatio(id self, SEL _cmd, double v) {
    if (orig_setDampingRatio) orig_setDampingRatio(self, _cmd, kBDRatio);
}
static double my_damping(id self, SEL _cmd)   { return kBDamping; }
static double my_stiffness(id self, SEL _cmd) { return kBSness; }
static double my_mass(id self, SEL _cmd)      { return kBMass; }
static double my_epsilon(id self, SEL _cmd)   { return kBEpsilon; }

static UIView *findViewOfClassName(UIView *root, NSString *className) {
    if (!root) return nil;
    if ([NSStringFromClass(root.class) isEqualToString:className]) return root;
    for (UIView *child in root.subviews) {
        UIView *match = findViewOfClassName(child, className);
        if (match) return match;
    }
    return nil;
}

static void applyPanelBounce(id controller, NSString *target) {
    // 转场方法返回后再加动画，确保根视图的模型层已经位于最终位置。
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *rootView = [(UIViewController *)controller view];
        UIView *view = [target isEqualToString:@"CoverSheet"]
            ? findViewOfClassName(rootView, @"SBCoverSheetPositionView")
            : rootView;
        if (!view || view.hidden || view.alpha <= 0.01) {
            blog(@"[BIT16-CENTER] %@ bounce skipped (target view unavailable)", target);
            return;
        }
        CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:@"transform.translation.y"];
        spring.mass = kBMass;
        spring.stiffness = kBSness;
        spring.damping = kCenterBounceDamping;
        spring.initialVelocity = 0;
        spring.fromValue = @(-kCenterBounceOffset);
        spring.toValue = @0;
        spring.additive = YES;
        spring.duration = kCenterBounceDuration;
        [view.layer addAnimation:spring forKey:@"com.xu.bounceit16.center-presentation"];
        blog(@"[BIT16-CENTER] %@ bounce applied view=%@ frame=%@ offset=%.1f duration=%.3f mass=%.2f stiffness=%.1f damping=%.1f",
             target, NSStringFromClass(view.class), NSStringFromCGRect(view.frame),
             kCenterBounceOffset, spring.duration,
             kBMass, kBSness, kCenterBounceDamping);
    });
}

// CCUIModularControlCenterOverlayViewController 的真实 ABI：
// v64@0:8{CGPoint=dd}16{CGPoint=dd}32{CGPoint=dd}48
static void (*orig_ccEndPresentation)(id, SEL, CGPoint, CGPoint, CGPoint) = NULL;
static void my_ccEndPresentation(id self, SEL cmd, CGPoint location,
                                 CGPoint translation, CGPoint velocity) {
    blog(@"[BIT16-CENTER] ControlCenter settle begin velocity={%.1f,%.1f}",
         velocity.x, velocity.y);
    orig_ccEndPresentation(self, cmd, location, translation, velocity);
    applyPanelBounce(self, @"ControlCenter");
}

static void (*orig_coverFinish)(id, SEL, BOOL, BOOL, id) = NULL;
static void my_coverFinish(id self, SEL cmd, BOOL presented, BOOL animated, id completion) {
    blog(@"[BIT16-CENTER] CoverSheet finish presented=%d animated=%d",
         presented, animated);
    orig_coverFinish(self, cmd, presented, animated, completion);
    if (presented && animated) {
        applyPanelBounce(self, @"CoverSheet");
    }
}

static void hookInstanceMethod(Class cls, NSString *selectorName, IMP replacement,
                               IMP *original, NSString *label) {
    SEL sel = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        blog(@"[BIT16-CENTER] SKIP %@ -%@ (missing)", label, selectorName);
        return;
    }
    MSHookMessageEx(cls, sel, replacement, original);
    blog(@"[BIT16-CENTER] hooked %@ -%@ type=%s", label, selectorName,
         method_getTypeEncoding(method));
}

static void installHooks(void) {
    Class c1 = objc_getClass("SBFFluidBehaviorSettings");
    Class c2 = objc_getClass("SBFAnimationSettings");
    blog(@"[BIT16] install: SBFFluidBehaviorSettings=%@ SBFAnimationSettings=%@",
         c1 ? NSStringFromClass(c1) : @"(nil)", c2 ? NSStringFromClass(c2) : @"(nil)");

    if (c1) {
        Method m = class_getInstanceMethod(c1, @selector(setDampingRatio:));
        if (m) {
            MSHookMessageEx(c1, @selector(setDampingRatio:), (IMP)my_setDampingRatio, (IMP *)&orig_setDampingRatio);
            blog(@"[BIT16] hooked SBFFluidBehaviorSettings -setDampingRatio: -> %.3f", kBDRatio);
        } else {
            blog(@"[BIT16] SKIP SBFFluidBehaviorSettings -setDampingRatio: (no method)");
        }
    }
    if (c2) {
        SEL sels[4] = { @selector(damping), @selector(stiffness), @selector(mass), @selector(epsilon) };
        IMP imps[4] = { (IMP)my_damping, (IMP)my_stiffness, (IMP)my_mass, (IMP)my_epsilon };
        const char *names[4] = { "damping", "stiffness", "mass", "epsilon" };
        for (int i = 0; i < 4; i++) {
            Method m = class_getInstanceMethod(c2, sels[i]);
            if (m) {
                MSHookMessageEx(c2, sels[i], imps[i], NULL);
                blog(@"[BIT16] hooked SBFAnimationSettings -%s", names[i]);
            } else {
                blog(@"[BIT16] SKIP SBFAnimationSettings -%s (no method)", names[i]);
            }
        }
    }

    Class control = objc_getClass("CCUIModularControlCenterOverlayViewController");
    hookInstanceMethod(control, @"endPresentationWithLocation:translation:velocity:",
                       (IMP)my_ccEndPresentation, (IMP *)&orig_ccEndPresentation,
                       @"CCUIModularControlCenterOverlayViewController");

    Class cover = objc_getClass("SBCoverSheetSlidingViewController");
    hookInstanceMethod(cover, @"_finishTransitionToPresented:animated:withCompletion:",
                       (IMP)my_coverFinish, (IMP *)&orig_coverFinish,
                       @"SBCoverSheetSlidingViewController");
    blog(@"[BIT16] install done");
}

__attribute__((constructor)) static void bit16_ctor(void) {
    @autoreleasepool {
        blog(@"[BIT16] CTOR pid=%d proc=%@", getpid(),
             [[NSProcessInfo processInfo] processName]);
        // 延到主队列，避开 dyld 早期（ctor 里对私有类取 Method 可能触发 +initialize）
        dispatch_async(dispatch_get_main_queue(), ^{
            installHooks();
        });
    }
}
