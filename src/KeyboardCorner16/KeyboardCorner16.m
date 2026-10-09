// ============================================================
// KeyboardCorner16 —— iOS 16 系统键盘按键圆角增强修复版
// Author: xu
// 包名: com.xu.keyboardcorner16
// 宿主: UIApplication (SpringBoard + 全量 UIKit App)
//
// 根因分析与修复：
// 原版 com.liuf.jpyj 仅 Hook [UIKBRenderGeometry setRoundRectRadius:] 强制赋 10.0。
// 但数字键盘（包括 10Key 九宫格数字面、全键盘 123 数字面、NumberPad）：
// 1. [UIKBRenderGeometry roundRectCorners] 默认或系统判定为 0（无圆角掩码）；
//    UIKBRenderer defaultPathForRenderGeometry 绘制时若 corners==0，即使 radius==10
//    也会退化为无圆角直角矩形！
// 2. UIKBRenderFactory10Key useRoundCorner 默认返回 NO，roundCornersForKey: 返回 0。
// 3. UIKBTree clipCorners 针对数字内联键返回 0。
//
// 本插件全面覆盖并拦截上述路径，使所有字母键与数字键均一致呈现圆角矩形质感。
// ============================================================

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdio.h>

#define KBC_VERSION @"1.0.0"
#define TARGET_RADIUS 10.0
#define ALL_CORNERS   0xFULL // UIRectCornerAllCorners (15)

// ellekit 动态解析
extern void MSHookMessageEx(Class cls, SEL sel, IMP newImp, IMP *oldImp);

// 原始方法指针
static IMP sOrig_setRoundRectRadius = NULL;
static IMP sOrig_roundRectRadius = NULL;
static IMP sOrig_setRoundRectCorners = NULL;
static IMP sOrig_roundRectCorners = NULL;
static IMP sOrig_setLayeredBgRadius = NULL;
static IMP sOrig_layeredBgRadius = NULL;
static IMP sOrig_setLayeredFgRadius = NULL;
static IMP sOrig_layeredFgRadius = NULL;

static IMP sOrig_10Key_useRound = NULL;
static IMP sOrig_10Key_roundCorners = NULL;
static IMP sOrig_10KeyRound_useRound = NULL;
static IMP sOrig_10KeyRound_shouldRound = NULL;
static IMP sOrig_10KeyRound_roundCorners = NULL;
static IMP sOrig_tree_clipCorners = NULL;

static void logToFile(const char *msg) {
    FILE *fp = fopen("/var/mobile/Documents/kbc_round.log", "a");
    if (fp) {
        fprintf(fp, "[%d] %s\n", getpid(), msg);
        fclose(fp);
    }
}

// ------------------------------------------------------------
// 1. UIKBRenderGeometry 钩子
// ------------------------------------------------------------
static void kbc_setRoundRectRadius(id self, SEL _cmd, double r) {
    if (sOrig_setRoundRectRadius) {
        ((void(*)(id, SEL, double))sOrig_setRoundRectRadius)(self, _cmd, TARGET_RADIUS);
    }
}

static double kbc_roundRectRadius(id self, SEL _cmd) {
    double r = 0;
    if (sOrig_roundRectRadius) {
        r = ((double(*)(id, SEL))sOrig_roundRectRadius)(self, _cmd);
    }
    return (r < TARGET_RADIUS) ? TARGET_RADIUS : r;
}

static void kbc_setRoundRectCorners(id self, SEL _cmd, uint64_t corners) {
    if (sOrig_setRoundRectCorners) {
        // 若系统传入 0（无圆角，如数字键盘内联键），强制替换为全圆角
        ((void(*)(id, SEL, uint64_t))sOrig_setRoundRectCorners)(self, _cmd, (corners == 0) ? ALL_CORNERS : corners);
    }
}

static uint64_t kbc_roundRectCorners(id self, SEL _cmd) {
    uint64_t c = 0;
    if (sOrig_roundRectCorners) {
        c = ((uint64_t(*)(id, SEL))sOrig_roundRectCorners)(self, _cmd);
    }
    return (c == 0) ? ALL_CORNERS : c;
}

static void kbc_setLayeredBgRadius(id self, SEL _cmd, double r) {
    if (sOrig_setLayeredBgRadius) {
        ((void(*)(id, SEL, double))sOrig_setLayeredBgRadius)(self, _cmd, TARGET_RADIUS);
    }
}

static double kbc_layeredBgRadius(id self, SEL _cmd) {
    return TARGET_RADIUS;
}

static void kbc_setLayeredFgRadius(id self, SEL _cmd, double r) {
    if (sOrig_setLayeredFgRadius) {
        ((void(*)(id, SEL, double))sOrig_setLayeredFgRadius)(self, _cmd, TARGET_RADIUS);
    }
}

static double kbc_layeredFgRadius(id self, SEL _cmd) {
    return TARGET_RADIUS;
}

// ------------------------------------------------------------
// 2. UIKBRenderFactory10Key 钩子（九宫格数字键盘）
// ------------------------------------------------------------
static BOOL kbc_10Key_useRound(id self, SEL _cmd) {
    return YES;
}

static uint64_t kbc_10Key_roundCorners(id self, SEL _cmd, id key, id keyplane) {
    return ALL_CORNERS;
}

// ------------------------------------------------------------
// 3. UIKBRenderFactory10Key_Round 钩子
// ------------------------------------------------------------
static BOOL kbc_10KeyRound_useRound(id self, SEL _cmd) {
    return YES;
}

static BOOL kbc_10KeyRound_shouldRound(id self, SEL _cmd, id key) {
    return YES;
}

static uint64_t kbc_10KeyRound_roundCorners(id self, SEL _cmd, id key, id keyplane) {
    return ALL_CORNERS;
}

// ------------------------------------------------------------
// 4. UIKBTree 钩子
// ------------------------------------------------------------
static uint64_t kbc_tree_clipCorners(id self, SEL _cmd) {
    uint64_t c = 0;
    if (sOrig_tree_clipCorners) {
        c = ((uint64_t(*)(id, SEL))sOrig_tree_clipCorners)(self, _cmd);
    }
    return (c == 0) ? ALL_CORNERS : c;
}

static void installHooks(void) {
    int count = 0;

    Class geomCls = objc_getClass("UIKBRenderGeometry");
    if (geomCls) {
        MSHookMessageEx(geomCls, sel_registerName("setRoundRectRadius:"), (IMP)kbc_setRoundRectRadius, &sOrig_setRoundRectRadius);
        MSHookMessageEx(geomCls, sel_registerName("roundRectRadius"), (IMP)kbc_roundRectRadius, &sOrig_roundRectRadius);
        MSHookMessageEx(geomCls, sel_registerName("setRoundRectCorners:"), (IMP)kbc_setRoundRectCorners, &sOrig_setRoundRectCorners);
        MSHookMessageEx(geomCls, sel_registerName("roundRectCorners"), (IMP)kbc_roundRectCorners, &sOrig_roundRectCorners);
        MSHookMessageEx(geomCls, sel_registerName("setLayeredBackgroundRoundRectRadius:"), (IMP)kbc_setLayeredBgRadius, &sOrig_setLayeredBgRadius);
        MSHookMessageEx(geomCls, sel_registerName("layeredBackgroundRoundRectRadius"), (IMP)kbc_layeredBgRadius, &sOrig_layeredBgRadius);
        MSHookMessageEx(geomCls, sel_registerName("setLayeredForegroundRoundRectRadius:"), (IMP)kbc_setLayeredFgRadius, &sOrig_setLayeredFgRadius);
        MSHookMessageEx(geomCls, sel_registerName("layeredForegroundRoundRectRadius"), (IMP)kbc_layeredFgRadius, &sOrig_layeredFgRadius);
        count += 8;
    }

    Class f10Cls = objc_getClass("UIKBRenderFactory10Key");
    if (f10Cls) {
        MSHookMessageEx(f10Cls, sel_registerName("useRoundCorner"), (IMP)kbc_10Key_useRound, &sOrig_10Key_useRound);
        MSHookMessageEx(f10Cls, sel_registerName("roundCornersForKey:onKeyplane:"), (IMP)kbc_10Key_roundCorners, &sOrig_10Key_roundCorners);
        count += 2;
    }

    Class f10RCls = objc_getClass("UIKBRenderFactory10Key_Round");
    if (f10RCls) {
        MSHookMessageEx(f10RCls, sel_registerName("useRoundCorner"), (IMP)kbc_10KeyRound_useRound, &sOrig_10KeyRound_useRound);
        MSHookMessageEx(f10RCls, sel_registerName("shouldUseRoundCornerForKey:"), (IMP)kbc_10KeyRound_shouldRound, &sOrig_10KeyRound_shouldRound);
        MSHookMessageEx(f10RCls, sel_registerName("roundCornersForKey:onKeyplane:"), (IMP)kbc_10KeyRound_roundCorners, &sOrig_10KeyRound_roundCorners);
        count += 3;
    }

    Class treeCls = objc_getClass("UIKBTree");
    if (treeCls) {
        MSHookMessageEx(treeCls, sel_registerName("clipCorners"), (IMP)kbc_tree_clipCorners, &sOrig_tree_clipCorners);
        count += 1;
    }

    char buf[128];
    snprintf(buf, sizeof(buf), "KeyboardCorner16 v%s 生效 (%d hooks) proc=%s",
             [KBC_VERSION UTF8String], count, [[[NSProcessInfo processInfo] processName] UTF8String]);
    logToFile(buf);
}

__attribute__((constructor)) static void kbc_ctor(void) {
    // 放入主队列异步，等待 UIKit 及其私有类加载完毕，规避 dyld 早期锁
    dispatch_async(dispatch_get_main_queue(), ^{
        installHooks();
    });
}
