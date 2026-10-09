#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdio.h>

#define KBC_VERSION "1.0.3"
#define TARGET_RADIUS 10.0
#define TARGET_CORNERS 0xF // UIRectCornerAllCorners

extern void MSHookMessageEx(Class cls, SEL sel, IMP newImp, IMP *oldImp);

#ifdef DEBUG
static void logToFile(const char *msg) {
    FILE *fp = fopen("/var/mobile/Documents/kbc_round.log", "a");
    if (fp) {
        fprintf(fp, "%s\n", msg);
        fclose(fp);
    }
}
#else
#define logToFile(msg) ((void)0)
#endif

static BOOL safeIsSubclassOf(Class cls, Class targetSuper) {
    if (!cls || !targetSuper) return NO;
    Class cur = cls;
    while (cur) {
        if (cur == targetSuper) return YES;
        cur = class_getSuperclass(cur);
    }
    return NO;
}

// -------------------------------------------------------------
// 1. Geometry 强制修正工具
// -------------------------------------------------------------

static void enforceGeometryCorner(id geom) {
    if (!geom) return;
    if ([geom respondsToSelector:@selector(setRoundRectRadius:)]) {
        ((void(*)(id, SEL, double))objc_msgSend)(geom, sel_registerName("setRoundRectRadius:"), TARGET_RADIUS);
    }
    if ([geom respondsToSelector:@selector(setRoundRectCorners:)]) {
        ((void(*)(id, SEL, unsigned long long))objc_msgSend)(geom, sel_registerName("setRoundRectCorners:"), TARGET_CORNERS);
    }
    Class cls = object_getClass(geom);
    if (cls) {
        Ivar rIvar = class_getInstanceVariable(cls, "_roundRectRadius");
        if (rIvar) {
            *(double *)((uintptr_t)geom + ivar_getOffset(rIvar)) = TARGET_RADIUS;
        }
        Ivar cIvar = class_getInstanceVariable(cls, "_roundRectCorners");
        if (cIvar) {
            *(unsigned long long *)((uintptr_t)geom + ivar_getOffset(cIvar)) = TARGET_CORNERS;
        }
    }
}

static void enforceTraitsCorner(id traits) {
    if (!traits) return;
    if ([traits respondsToSelector:@selector(geometry)]) {
        id geom = ((id(*)(id, SEL))objc_msgSend)(traits, sel_registerName("geometry"));
        enforceGeometryCorner(geom);
    }
    if ([traits respondsToSelector:@selector(layeredGeometry)]) {
        id layered = ((id(*)(id, SEL))objc_msgSend)(traits, sel_registerName("layeredGeometry"));
        enforceGeometryCorner(layered);
    }
    if ([traits respondsToSelector:@selector(variantGeometries)]) {
        id vars = ((id(*)(id, SEL))objc_msgSend)(traits, sel_registerName("variantGeometries"));
        if ([vars respondsToSelector:@selector(allValues)]) {
            vars = [vars performSelector:@selector(allValues)];
        }
        if ([vars isKindOfClass:[NSArray class]]) {
            for (id g in vars) {
                enforceGeometryCorner(g);
            }
        }
    }
}

// -------------------------------------------------------------
// 2. UIKBRenderGeometry Hooks
// -------------------------------------------------------------

static IMP sOrig_geom_getRoundRectRadius = NULL;
static IMP sOrig_geom_setRoundRectRadius = NULL;
static IMP sOrig_geom_getRoundRectCorners = NULL;
static IMP sOrig_geom_setRoundRectCorners = NULL;

static double kbc_geom_getRoundRectRadius(id self, SEL _cmd) {
    return TARGET_RADIUS;
}

static void kbc_geom_setRoundRectRadius(id self, SEL _cmd, double r) {
    if (sOrig_geom_setRoundRectRadius) {
        ((void(*)(id, SEL, double))sOrig_geom_setRoundRectRadius)(self, _cmd, TARGET_RADIUS);
    }
    Class cls = object_getClass(self);
    if (cls) {
        Ivar rIvar = class_getInstanceVariable(cls, "_roundRectRadius");
        if (rIvar) {
            *(double *)((uintptr_t)self + ivar_getOffset(rIvar)) = TARGET_RADIUS;
        }
    }
}

static unsigned long long kbc_geom_getRoundRectCorners(id self, SEL _cmd) {
    return TARGET_CORNERS;
}

static void kbc_geom_setRoundRectCorners(id self, SEL _cmd, unsigned long long c) {
    if (sOrig_geom_setRoundRectCorners) {
        ((void(*)(id, SEL, unsigned long long))sOrig_geom_setRoundRectCorners)(self, _cmd, TARGET_CORNERS);
    }
    Class cls = object_getClass(self);
    if (cls) {
        Ivar cIvar = class_getInstanceVariable(cls, "_roundRectCorners");
        if (cIvar) {
            *(unsigned long long *)((uintptr_t)self + ivar_getOffset(cIvar)) = TARGET_CORNERS;
        }
    }
}

// -------------------------------------------------------------
// 3. UIKBRenderFactory Hooks
// -------------------------------------------------------------

static IMP sOrig_factory_keyCornerRadius = NULL;

static double kbc_factory_keyCornerRadius(id self, SEL _cmd) {
    return TARGET_RADIUS;
}

static IMP sOrig_factory_traitsForKey = NULL;

static id kbc_factory_traitsForKey(id self, SEL _cmd, id key, id keyplane) {
    id traits = nil;
    if (sOrig_factory_traitsForKey) {
        traits = ((id(*)(id, SEL, id, id))sOrig_factory_traitsForKey)(self, _cmd, key, keyplane);
    }
    enforceTraitsCorner(traits);
    return traits;
}

static IMP sOrig_factory_defaultKeyTraits = NULL;

static id kbc_factory_defaultKeyTraits(id self, SEL _cmd, id key, id keyplane) {
    id traits = nil;
    if (sOrig_factory_defaultKeyTraits) {
        traits = ((id(*)(id, SEL, id, id))sOrig_factory_defaultKeyTraits)(self, _cmd, key, keyplane);
    }
    enforceTraitsCorner(traits);
    return traits;
}

static IMP sOrig_factory_geometryWithShape = NULL;

static id kbc_factory_geometryWithShape(id self, SEL _cmd, id shape) {
    id geom = nil;
    if (sOrig_factory_geometryWithShape) {
        geom = ((id(*)(id, SEL, id))sOrig_factory_geometryWithShape)(self, _cmd, shape);
    }
    enforceGeometryCorner(geom);
    return geom;
}

// -------------------------------------------------------------
// 4. Hook 安装
// -------------------------------------------------------------

static void hookGeometryClass(Class geomCls) {
    if (!geomCls) return;
    
    // Getter & Setter for roundRectRadius
    if (class_getInstanceMethod(geomCls, sel_registerName("roundRectRadius"))) {
        MSHookMessageEx(geomCls, sel_registerName("roundRectRadius"),
                        (IMP)kbc_geom_getRoundRectRadius, &sOrig_geom_getRoundRectRadius);
    }
    if (class_getInstanceMethod(geomCls, sel_registerName("setRoundRectRadius:"))) {
        MSHookMessageEx(geomCls, sel_registerName("setRoundRectRadius:"),
                        (IMP)kbc_geom_setRoundRectRadius, &sOrig_geom_setRoundRectRadius);
    }
    
    // Getter & Setter for roundRectCorners
    if (class_getInstanceMethod(geomCls, sel_registerName("roundRectCorners"))) {
        MSHookMessageEx(geomCls, sel_registerName("roundRectCorners"),
                        (IMP)kbc_geom_getRoundRectCorners, &sOrig_geom_getRoundRectCorners);
    }
    if (class_getInstanceMethod(geomCls, sel_registerName("setRoundRectCorners:"))) {
        MSHookMessageEx(geomCls, sel_registerName("setRoundRectCorners:"),
                        (IMP)kbc_geom_setRoundRectCorners, &sOrig_geom_setRoundRectCorners);
    }
    
    logToFile("[KBC] UIKBRenderGeometry hooks installed successfully.");
}

static void hookSingleFactoryClass(Class cls) {
    if (!cls) return;
    const char *cname = class_getName(cls);
    
    if (class_getInstanceMethod(cls, sel_registerName("keyCornerRadius"))) {
        IMP dummy = NULL;
        MSHookMessageEx(cls, sel_registerName("keyCornerRadius"),
                        (IMP)kbc_factory_keyCornerRadius, &dummy);
    }
    if (class_getInstanceMethod(cls, sel_registerName("_traitsForKey:onKeyplane:"))) {
        IMP dummy = NULL;
        MSHookMessageEx(cls, sel_registerName("_traitsForKey:onKeyplane:"),
                        (IMP)kbc_factory_traitsForKey, &dummy);
    }
    if (class_getInstanceMethod(cls, sel_registerName("defaultKeyTraitsForKey:onKeyplane:"))) {
        IMP dummy = NULL;
        MSHookMessageEx(cls, sel_registerName("defaultKeyTraitsForKey:onKeyplane:"),
                        (IMP)kbc_factory_defaultKeyTraits, &dummy);
    }
    if (class_getInstanceMethod(cls, sel_registerName("geometryWithShape:"))) {
        IMP dummy = NULL;
        MSHookMessageEx(cls, sel_registerName("geometryWithShape:"),
                        (IMP)kbc_factory_geometryWithShape, &dummy);
    }
    
    char buf[128];
    snprintf(buf, sizeof(buf), "[KBC] Hooked Factory class: %s", cname);
    logToFile(buf);
}

static void hookAllFactoryClasses(void) {
    Class baseFactoryCls = objc_getClass("UIKBRenderFactory");
    if (!baseFactoryCls) {
        logToFile("[KBC] UIKBRenderFactory not found!");
        return;
    }
    // Hook base
    hookSingleFactoryClass(baseFactoryCls);

    // 显式指定已知常见工厂类（快速保底）
    const char *knownFactories[] = {
        "UIKBRenderFactoryiPhone",
        "UIKBRenderFactoryiPhoneChoco",
        "UIKBRenderFactoryiPhoneLandscape",
        "UIKBRenderFactory10Key",
        "UIKBRenderFactory10Key_Round",
        "UIKBRenderFactory10Key_Landscape",
        "UIKBRenderFactoryNumberPad",
        "UIKBRenderFactoryNumberPadLandscape",
        "UIKBRenderFactoryLayoutConfig",
        NULL
    };
    for (int k = 0; knownFactories[k] != NULL; k++) {
        Class fcls = objc_getClass(knownFactories[k]);
        if (fcls) {
            hookSingleFactoryClass(fcls);
        }
    }

    // 动态安全遍历其余继承自 UIKBRenderFactory 的子类
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses > 0) {
        Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
        numClasses = objc_getClassList(classes, numClasses);
        for (int i = 0; i < numClasses; i++) {
            Class cls = classes[i];
            if (cls != baseFactoryCls && safeIsSubclassOf(cls, baseFactoryCls)) {
                hookSingleFactoryClass(cls);
            }
        }
        free(classes);
    }
    
    logToFile("[KBC] All UIKBRenderFactory classes hooked!");
}

static void installHooks(void) {
    logToFile("[KBC] Initializing KeyboardCorner16 v" KBC_VERSION " ...");
    hookGeometryClass(objc_getClass("UIKBRenderGeometry"));
    hookAllFactoryClasses();
    logToFile("[KBC] KeyboardCorner16 initialization complete!");
}

__attribute__((constructor)) static void kbc_ctor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        installHooks();
    });
}
