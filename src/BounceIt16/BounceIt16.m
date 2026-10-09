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
#import <objc/runtime.h>
#include <stdio.h>
#include <unistd.h>

// ellekit 在运行时提供（不链接 CydiaSubstrate，避免 RootHide 下依赖/签名问题）
extern void MSHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result);

// —— 版本（唯一来源；build_deploy.sh 从这里读，发布时勿手填）——
#define BIT16_VERSION @"1.0.2"

// —— 可调参数 ——
static const double kBDRatio   = 0.33;    // SBFFluidBehaviorSettings.dampingRatio（越小越弹）
static const double kBDamping  = 42.0;    // SBFAnimationSettings.damping（越小越弹）
static const double kBSness     = 1666.0;  // SBFAnimationSettings.stiffness
static const double kBMass      = 2.5;     // SBFAnimationSettings.mass
static const double kBEpsilon   = 0.0;     // SBFAnimationSettings.epsilon

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
