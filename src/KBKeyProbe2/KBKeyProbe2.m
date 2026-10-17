// KBKeyProbe2 — 键盘按键圆角渲染路径"只读"探针
// 目的：抓出"数字键(直角) vs 字母键(圆角)"在 traits 生成与路径生成阶段的真实差异。
// 原则：所有 hook 均为"调用原实现 + 打印参数"，绝不修改任何值、绝不改变行为。
// 日志：/var/mobile/Documents/kbp2.log（失败时 /var/tmp/kbp2.log）
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdio.h>
#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

extern void MSHookMessageEx(Class cls, SEL sel, IMP newImp, IMP *oldImp);

#define KBP2_LIMIT 1500
#define KBP2_TAG "KBKeyProbe2"

static NSMutableSet *g_seen = nil;
static NSInteger g_count = 0;

static void kbp2_log(NSString *line) {
    NSString *full = [NSString stringWithFormat:@"[kbp2:%d] %@", getpid(), line];
    FILE *fp = fopen("/var/mobile/Documents/kbp2.log", "a");
    if (!fp) fp = fopen("/var/tmp/kbp2.log", "a");
    if (fp) { fprintf(fp, "%s\n", full.UTF8String); fclose(fp); }
}

static BOOL kbp2_should_log(NSString *tag, NSString *cls, NSString *detail) {
    NSString *k = [NSString stringWithFormat:@"%@|%@|%@", tag, cls, detail];
    @synchronized (g_seen) {
        if (!g_seen) g_seen = [NSMutableSet new];
        if ([g_seen containsObject:k]) return NO;
        [g_seen addObject:k];
        g_count++;
        return g_count <= KBP2_LIMIT;
    }
}

static NSString *kbp2_cls(id obj) {
    if (!obj) return @"(nil)";
    return NSStringFromClass([obj class]) ?: @"?";
}

static id kbp2_msg_id(id obj, const char *selName) {
    if (!obj) return nil;
    SEL s = sel_registerName(selName);
    if (![obj respondsToSelector:s]) return nil;
    return ((id(*)(id, SEL))objc_msgSend)(obj, s);
}

static double kbp2_msg_d(id obj, const char *selName, double dflt) {
    if (!obj) return dflt;
    SEL s = sel_registerName(selName);
    if (![obj respondsToSelector:s]) return dflt;
    return ((double(*)(id, SEL))objc_msgSend)(obj, s);
}

static unsigned long long kbp2_msg_ull(id obj, const char *selName, unsigned long long dflt) {
    if (!obj) return dflt;
    SEL s = sel_registerName(selName);
    if (![obj respondsToSelector:s]) return dflt;
    return ((unsigned long long(*)(id, SEL))objc_msgSend)(obj, s);
}

static NSString *kbp2_name_of(id obj) {
    id n = kbp2_msg_id(obj, "name");
    if ([n isKindOfClass:[NSString class]]) return (NSString *)n;
    return kbp2_cls(obj);
}

// ---- traits 阶段：dump traits -> geometry ----
static void kbp2_dump_traits(NSString *tag, id factory, id key, id keyplane, id traits) {
    @autoreleasepool {
        NSString *fcls = kbp2_cls(factory);
        NSString *kn = kbp2_name_of(key);
        if (!kbp2_should_log(tag, fcls, kn)) return;
        NSString *plane = kbp2_name_of(keyplane);
        unsigned long long clip = kbp2_msg_ull(key, "clipCorners", 0xFFEEULL);
        id geom = kbp2_msg_id(traits, "geometry");
        double r  = kbp2_msg_d(geom, "roundRectRadius", -1);
        unsigned long long c = kbp2_msg_ull(geom, "roundRectCorners", 0xFFEEULL);
        double lr = kbp2_msg_d(geom, "layeredBackgroundRoundRectRadius", -2);
        double fr = kbp2_msg_d(geom, "layeredForegroundRoundRectRadius", -2);
        kbp2_log([NSString stringWithFormat:
            @"%@ factory=%@ key=%@ plane=%@ clip=0x%llx geomCls=%@ radius=%g corners=0x%llx layeredBG=%g layeredFG=%g",
            tag, fcls, kn, plane, clip, kbp2_cls(geom), r, c, lr, fr]);
    }
}

// ---- 路径生成阶段：dump geometry（去重键 = 参数组合）----
static void kbp2_dump_geom(id renderer, id geom) {
    @autoreleasepool {
        double r = kbp2_msg_d(geom, "roundRectRadius", -1);
        unsigned long long c = kbp2_msg_ull(geom, "roundRectCorners", 0xFFEEULL);
        NSString *detail = [NSString stringWithFormat:@"r=%g,c=0x%llx", r, c];
        NSString *rcls = kbp2_cls(renderer);
        if (!kbp2_should_log(@"defaultPath", rcls, detail)) return;
        id key = kbp2_msg_id(geom, "key");
        NSString *kn = key ? kbp2_name_of(key) : @"?";
        kbp2_log([NSString stringWithFormat:
            @"defaultPath renderer=%@ geomCls=%@ radius=%g corners=0x%llx key=%@",
            rcls, kbp2_cls(geom), r, c, kn]);
    }
}

static void kbp2_maybe_schedule_window_scan(void);

static IMP sOrig_traitsPub = NULL;
static id kbp2_traitsPub(id self, SEL _cmd, id key, id keyplane) {
    id traits = ((id(*)(id, SEL, id, id))sOrig_traitsPub)(self, _cmd, key, keyplane);
    @try {
        kbp2_dump_traits(@"traitsPub", self, key, keyplane, traits);
        kbp2_maybe_schedule_window_scan();
    } @catch (NSException *e) {}
    return traits;
}

// ===== 第二波：参数监视器（全部只读转发） =====

// -- 调用点定位（dladdr 符号化友好格式）--
static void kbp2_log_call_site(const char *tag, void *ra) {
    Dl_info info;
    if (ra && dladdr(ra, &info) && info.dli_fbase) {
        kbp2_log([NSString stringWithFormat:@"callSite %s from %s + 0x%llx sym=%s",
                  tag, info.dli_fname ? info.dli_fname : "?",
                  (unsigned long long)((uintptr_t)ra - (uintptr_t)info.dli_fbase),
                  info.dli_sname ? info.dli_sname : "-"]);
    } else if (ra) {
        kbp2_log([NSString stringWithFormat:@"callSite %s raw=%p", tag, ra]);
    }
}

// -- UIKBRenderGeometry setters --
static IMP sO_setRRR = NULL;
static void p_setRRR(id self, SEL _cmd, double r) {
    @try {
        if (kbp2_should_log(@"setRRR", kbp2_cls(self), [NSString stringWithFormat:@"%p|%.1f", self, r])) {
            kbp2_log([NSString stringWithFormat:@"setRoundRectRadius geom=%p r=%.1f", self, r]);
            if (r > 0.1) {
                kbp2_log_call_site("ra0", __builtin_return_address(0));
                kbp2_log_call_site("ra1", __builtin_return_address(1));
                kbp2_log_call_site("ra2", __builtin_return_address(2));
            }
        }
    } @catch (NSException *e) {}
    if (sO_setRRR) ((void(*)(id, SEL, double))sO_setRRR)(self, _cmd, r);
}

static IMP sO_setRRC = NULL;
static void p_setRRC(id self, SEL _cmd, unsigned long long c) {
    @try {
        if (kbp2_should_log(@"setRRC", kbp2_cls(self), [NSString stringWithFormat:@"%p|0x%llx", self, c])) {
            kbp2_log([NSString stringWithFormat:@"setRoundRectCorners geom=%p c=0x%llx", self, c]);
            if (c != 0) {
                kbp2_log_call_site("rrc-ra0", __builtin_return_address(0));
                kbp2_log_call_site("rrc-ra1", __builtin_return_address(1));
            }
        }
    } @catch (NSException *e) {}
    if (sO_setRRC) ((void(*)(id, SEL, unsigned long long))sO_setRRC)(self, _cmd, c);
}

static IMP sO_setLBR = NULL;
static void p_setLBR(id self, SEL _cmd, double r) {
    @try {
        if (kbp2_should_log(@"setLBR", kbp2_cls(self), [NSString stringWithFormat:@"%.1f", r]))
            kbp2_log([NSString stringWithFormat:@"setLayeredBGRadius self=%@ r=%.1f", kbp2_cls(self), r]);
    } @catch (NSException *e) {}
    if (sO_setLBR) ((void(*)(id, SEL, double))sO_setLBR)(self, _cmd, r);
}

static IMP sO_setLFR = NULL;
static void p_setLFR(id self, SEL _cmd, double r) {
    @try {
        if (kbp2_should_log(@"setLFR", kbp2_cls(self), [NSString stringWithFormat:@"%.1f", r]))
            kbp2_log([NSString stringWithFormat:@"setLayeredFGRadius self=%@ r=%.1f", kbp2_cls(self), r]);
    } @catch (NSException *e) {}
    if (sO_setLFR) ((void(*)(id, SEL, double))sO_setLFR)(self, _cmd, r);
}

// -- UIKBRenderFactory keyCornerRadius（按运行时类型编码自适应 double/float）--
static IMP sO_kcrD = NULL;
static IMP sO_kcrF = NULL;
static double p_kcrD(id self, SEL _cmd) {
    double v = ((double(*)(id, SEL))sO_kcrD)(self, _cmd);
    @try {
        if (kbp2_should_log(@"kcr", kbp2_cls(self), [NSString stringWithFormat:@"%.2f", v]))
            kbp2_log([NSString stringWithFormat:@"keyCornerRadius self=%@ ret=%.2f", kbp2_cls(self), v]);
    } @catch (NSException *e) {}
    return v;
}
static float p_kcrF(id self, SEL _cmd) {
    float v = ((float(*)(id, SEL))sO_kcrF)(self, _cmd);
    @try {
        if (kbp2_should_log(@"kcrF", kbp2_cls(self), [NSString stringWithFormat:@"%.2f", v]))
            kbp2_log([NSString stringWithFormat:@"keyCornerRadiusF self=%@ ret=%.2f", kbp2_cls(self), v]);
    } @catch (NSException *e) {}
    return v;
}

// -- UIKBRenderGeometry initWithShape: --
static IMP sO_initShape = NULL;
static id p_initShape(id self, SEL _cmd, id shape) {
    id obj = ((id(*)(id, SEL, id))sO_initShape)(self, _cmd, shape);
    @try {
        NSString *desc = @"(no-desc)";
        if ([shape respondsToSelector:@selector(description)]) desc = [shape description];
        if (desc.length > 300) desc = [desc substringToIndex:300];
        if (kbp2_should_log(@"initShape", kbp2_cls(self), kbp2_cls(shape)))
            kbp2_log([NSString stringWithFormat:@"initWithShape self=%@ shapeCls=%@ desc=%@", kbp2_cls(self), kbp2_cls(shape), desc]);
    } @catch (NSException *e) {}
    return obj;
}

// -- UIKBTree shapesForKeys: / setClipCorners: --
static IMP sO_shapesForKeys = NULL;
static id p_shapesForKeys(id self, SEL _cmd, id keys) {
    id r = ((id(*)(id, SEL, id))sO_shapesForKeys)(self, _cmd, keys);
    @try {
        if (kbp2_should_log(@"shapesForKeys", kbp2_cls(self), @"any"))
            kbp2_log([NSString stringWithFormat:@"shapesForKeys self=%@ keysCls=%@ retCls=%@",
                      kbp2_cls(self), kbp2_cls(keys), kbp2_cls(r)]);
    } @catch (NSException *e) {}
    return r;
}

static IMP sO_setClip = NULL;
static void p_setClip(id self, SEL _cmd, unsigned long long c) {
    @try {
        NSString *kn = kbp2_name_of(self);
        if (kbp2_should_log(@"setClip", kn, [NSString stringWithFormat:@"0x%llx", c])) {
            NSString *cls = kbp2_cls(self);
            NSString *gCls = @"?";
            SEL gsel = sel_registerName("geometry");
            if ([self respondsToSelector:gsel]) {
                id g = ((id(*)(id, SEL))objc_msgSend)(self, gsel);
                gCls = kbp2_cls(g);
            }
            kbp2_log([NSString stringWithFormat:@"setClipCorners key=%@ keyCls=%@ geomCls=%@ c=0x%llx", kn, cls, gCls, c]);
        }
    } @catch (NSException *e) {}
    if (sO_setClip) ((void(*)(id, SEL, unsigned long long))sO_setClip)(self, _cmd, c);
}

// -- UIKBTree setGeometry:（建立"键 <-> 几何对象"关联）--
static IMP sO_setGeom = NULL;
static void p_setGeom(id self, SEL _cmd, id geom) {
    @try {
        NSString *kn = kbp2_name_of(self);
        if (kbp2_should_log(@"setGeom", kn, [NSString stringWithFormat:@"%p", geom])) {
            double r = kbp2_msg_d(geom, "roundRectRadius", -1);
            unsigned long long c = kbp2_msg_ull(geom, "roundRectCorners", 0xFFEEULL);
            unsigned long long clip = kbp2_msg_ull(self, "clipCorners", 0xFFEEULL);
            kbp2_log([NSString stringWithFormat:@"setGeometry key=%@ geom=%p rAtSet=%g cAtSet=0x%llx keyClip=0x%llx",
                      kn, geom, r, c, clip]);
        }
    } @catch (NSException *e) {}
    if (sO_setGeom) ((void(*)(id, SEL, id))sO_setGeom)(self, _cmd, geom);
}

// -- UIKBTree geometry getter（关联映射表：key <-> geom）--
static IMP sO_geomGetter = NULL;
static id p_geomGetter(id self, SEL _cmd) {
    id g = ((id(*)(id, SEL))sO_geomGetter)(self, _cmd);
    @try {
        if (g) {
            NSString *kn = kbp2_name_of(self);
            if (kbp2_should_log(@"geomMap", kn, [NSString stringWithFormat:@"%p", g]))
                kbp2_log([NSString stringWithFormat:@"geomMap key=%@ geom=%p", kn, g]);
        }
    } @catch (NSException *e) {}
    return g;
}

// -- UIKBRenderFactory _customizeGeometry:forKey:contents:（键级几何定制，全 id 参数）--
static IMP sO_custGeom = NULL;
static id p_custGeom(id self, SEL _cmd, id geom, id key, id contents) {
    id outG = sO_custGeom ? ((id(*)(id, SEL, id, id, id))sO_custGeom)(self, _cmd, geom, key, contents) : geom;
    @try {
        NSString *kn = kbp2_name_of(key);
        if (kbp2_should_log(@"custGeom", kbp2_cls(self), kn)) {
            double inR = kbp2_msg_d(geom, "roundRectRadius", -1);
            double outR = kbp2_msg_d(outG, "roundRectRadius", -1);
            unsigned long long outC = kbp2_msg_ull(outG, "roundRectCorners", 0xFFEEULL);
            kbp2_log([NSString stringWithFormat:@"custGeom self=%@ key=%@ inGeom=%p inR=%g outGeom=%p outR=%g outC=0x%llx",
                      kbp2_cls(self), kn, geom, inR, outG, outR, outC]);
        }
    } @catch (NSException *e) {}
    return outG;
}

// -- UIKBTree activeGeometriesList getter（渲染用几何列表）--
static IMP sO_activeGeoms = NULL;
static id p_activeGeoms(id self, SEL _cmd) {
    id r = ((id(*)(id, SEL))sO_activeGeoms)(self, _cmd);
    @try {
        if ([r isKindOfClass:[NSArray class]]) {
            NSArray *arr = (NSArray *)r;
            NSMutableString *ps = [NSMutableString string];
            NSUInteger n = MIN(arr.count, 4);
            for (NSUInteger i = 0; i < n; i++) {
                [ps appendFormat:@"%p,", (__bridge void *)arr[i]];
            }
            NSString *kn = kbp2_name_of(self);
            if (kbp2_should_log(@"geomList", kn, [NSString stringWithFormat:@"%lu", (unsigned long)arr.count])) {
                kbp2_log([NSString stringWithFormat:@"geomList key=%@ n=%lu geoms=[%@]", kn, (unsigned long)arr.count, ps]);
            }
        }
    } @catch (NSException *e) {}
    return r;
}

// -- UIKBRenderTraits.geometry getter（渲染输入包的几何）--
static IMP sO_traitsGeom = NULL;
static id p_traitsGeom(id self, SEL _cmd) {
    id g = ((id(*)(id, SEL))sO_traitsGeom)(self, _cmd);
    @try {
        if (g) {
            double r = kbp2_msg_d(g, "roundRectRadius", -1);
            unsigned long long c = kbp2_msg_ull(g, "roundRectCorners", 0xFFEEULL);
            if (kbp2_should_log(@"traitsGeom", kbp2_cls(self), [NSString stringWithFormat:@"%p", g]))
                kbp2_log([NSString stringWithFormat:@"traitsGeom traits=%p geom=%p r=%g c=0x%llx", self, g, r, c]);
        }
    } @catch (NSException *e) {}
    return g;
}

// -- UIKBRenderer 渲染三兄弟（看"字符键"走哪条渲染路径）--
static void kbp2_dump_render_call(const char *tag, id renderer, id traits, long status) {
    @try {
        NSString *tagS = tag ? @(tag) : @"?";
        id g = kbp2_msg_id(traits, "geometry");
        double r = kbp2_msg_d(g, "roundRectRadius", -1);
        unsigned long long c = kbp2_msg_ull(g, "roundRectCorners", 0xFFEEULL);
        NSString *detail = [NSString stringWithFormat:@"%p", g ?: traits];
        if (kbp2_should_log(tagS, kbp2_cls(renderer), detail))
            kbp2_log([NSString stringWithFormat:@"%@ renderer=%@ traits=%p geom=%p r=%g c=0x%llx status=%ld",
                      tagS, kbp2_cls(renderer), traits, g, r, c, status]);
    } @catch (NSException *e) {}
}

static IMP sO_rkString = NULL;
static void p_rkString(id self, SEL _cmd, id contents, id traits, long status) {
    kbp2_dump_render_call("renderString", self, traits, status);
    if (sO_rkString) ((void(*)(id, SEL, id, id, long))sO_rkString)(self, _cmd, contents, traits, status);
}

static IMP sO_rkImage = NULL;
static void p_rkImage(id self, SEL _cmd, id contents, id traits, long status) {
    kbp2_dump_render_call("renderImage", self, traits, status);
    if (sO_rkImage) ((void(*)(id, SEL, id, id, long))sO_rkImage)(self, _cmd, contents, traits, status);
}

static IMP sO_rkPath = NULL;
static void p_rkPath(id self, SEL _cmd, id contents, id traits) {
    @try {
        id g = kbp2_msg_id(traits, "geometry");
        double r = kbp2_msg_d(g, "roundRectRadius", -1);
        unsigned long long c = kbp2_msg_ull(g, "roundRectCorners", 0xFFEEULL);
        NSString *detail = [NSString stringWithFormat:@"%p", g ?: traits];
        if (kbp2_should_log(@"renderPath", kbp2_cls(self), detail))
            kbp2_log([NSString stringWithFormat:@"renderPath renderer=%@ traits=%p geom=%p r=%g c=0x%llx",
                      kbp2_cls(self), traits, g, r, c]);
    } @catch (NSException *e) {}
    if (sO_rkPath) ((void(*)(id, SEL, id, id))sO_rkPath)(self, _cmd, contents, traits);
}

static IMP sO_rkMain = NULL;
static void p_rkMain(id self, SEL _cmd, id contents, id traits) {
    @try {
        id g = kbp2_msg_id(traits, "geometry");
        double r = kbp2_msg_d(g, "roundRectRadius", -1);
        unsigned long long c = kbp2_msg_ull(g, "roundRectCorners", 0xFFEEULL);
        NSString *detail = [NSString stringWithFormat:@"%p", g ?: traits];
        if (kbp2_should_log(@"renderMain", kbp2_cls(self), detail))
            kbp2_log([NSString stringWithFormat:@"renderMain renderer=%@ traits=%p geom=%p r=%g c=0x%llx",
                      kbp2_cls(self), traits, g, r, c]);
    } @catch (NSException *e) {}
    if (sO_rkMain) ((void(*)(id, SEL, id, id))sO_rkMain)(self, _cmd, contents, traits);
}

static IMP sOrig_traitsPriv = NULL;
static id kbp2_traitsPriv(id self, SEL _cmd, id key, id keyplane) {
    id traits = ((id(*)(id, SEL, id, id))sOrig_traitsPriv)(self, _cmd, key, keyplane);
    @try { kbp2_dump_traits(@"traitsPriv", self, key, keyplane, traits); } @catch (NSException *e) {}
    return traits;
}

static IMP sOrig_defaultPath = NULL;
static CFTypeRef kbp2_defaultPath(id self, SEL _cmd, id geom) {
    @try { kbp2_dump_geom(self, geom); } @catch (NSException *e) {}
    return ((CFTypeRef(*)(id, SEL, id))sOrig_defaultPath)(self, _cmd, geom);
}

// ---- 名字雷达：dump 类的方法名单（找"谁家在生成 traits"）----
static void kbp2_dump_names_for_class(Class c, BOOL all) {
    if (!c) return;
    unsigned count = 0;
    Method *ms = class_copyMethodList(c, &count);
    NSMutableArray *hits = [NSMutableArray array];
    for (unsigned j = 0; j < count; j++) {
        NSString *n = NSStringFromSelector(method_getName(ms[j]));
        BOOL keep = all;
        if (!keep) {
            for (NSString *kw in @[@"rait", @"eometr", @"orner", @"adius", @"neplane", @"ForKeys"]) {
                if ([n rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) { keep = YES; break; }
            }
        }
        if (keep) [hits addObject:n];
    }
    free(ms);
    if (hits.count) {
        kbp2_log([NSString stringWithFormat:@"@methods %@: %@",
                  NSStringFromClass(c), [hits componentsJoinedByString:@" , "]]);
    }
}

static void kbp2_scan(void) {
    // 1) 全类扫描：谁定义了 traitsForKey 系列
    int n = objc_getClassList(NULL, 0);
    if (n > 0) {
        __unsafe_unretained Class *cs = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)n);
        n = objc_getClassList(cs, n);
        for (int i = 0; i < n; i++) {
            unsigned count = 0;
            Method *ms = class_copyMethodList(cs[i], &count);
            for (unsigned j = 0; j < count; j++) {
                const char *sn = sel_getName(method_getName(ms[j]));
                if (strstr(sn, "raitsForKey") || strstr(sn, "raitsForKeys") || strstr(sn, "raitsForKeyplane")) {
                    kbp2_log([NSString stringWithFormat:@"@traitsImpl %s :: %s", class_getName(cs[i]), sn]);
                }
            }
            free(ms);
        }
        free(cs);
    }
    // 2) 关键类方法名单
    kbp2_dump_names_for_class(objc_getClass("UIKBRenderFactoryiPhoneTruffle"), YES);
    kbp2_dump_names_for_class(objc_getClass("UIKBRenderFactory"), NO);
    kbp2_dump_names_for_class(objc_getClass("UIKBRenderGeometry"), YES);
    kbp2_dump_names_for_class(objc_getClass("UIKBTree"), NO);
    kbp2_log(@"@scan done");
}

// -- 仅当"子类重写"时挂子类（继承的会由父类的 hook 兜住）--
static void kbp2_hook_if_overridden(Class cls, SEL sel, IMP imp, IMP *orig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP cur = method_getImplementation(m);
    Class sup = class_getSuperclass(cls);
    if (sup) {
        Method sm = class_getInstanceMethod(sup, sel);
        if (sm && method_getImplementation(sm) == cur) return; // 继承，跳过
    }
    MSHookMessageEx(cls, sel, imp, orig);
}

// -- 全类扫描：setter 的"真实定义者"（找出可能绕过父类 hook 的重写者）--
static BOOL kbp2_chain_contains(Class c, const char *name) {
    Class cur = c;
    int guard = 0;
    while (cur && guard++ < 300) {
        if (strcmp(class_getName(cur), name) == 0) return YES;
        cur = class_getSuperclass(cur);
    }
    return NO;
}

static BOOL kbp2_defines(Class c, const char *selName) {
    unsigned count = 0;
    Method *ms = class_copyMethodList(c, &count);
    BOOL found = NO;
    for (unsigned i = 0; i < count; i++) {
        if (strcmp(sel_getName(method_getName(ms[i])), selName) == 0) { found = YES; break; }
    }
    free(ms);
    return found;
}

static void kbp2_scan_setter_definers(void) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    __unsafe_unretained Class *cs = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)n);
    n = objc_getClassList(cs, n);
    for (int i = 0; i < n; i++) {
        Class c = cs[i];
        const char *cn = class_getName(c);
        if (kbp2_chain_contains(c, "UIKBRenderGeometry")) {
            if (kbp2_defines(c, "setRoundRectRadius:"))
                kbp2_log([NSString stringWithFormat:@"@definer %s :: setRoundRectRadius:", cn]);
            if (kbp2_defines(c, "setRoundRectCorners:"))
                kbp2_log([NSString stringWithFormat:@"@definer %s :: setRoundRectCorners:", cn]);
        }
        if (kbp2_chain_contains(c, "UIKBTree")) {
            if (kbp2_defines(c, "setClipCorners:"))
                kbp2_log([NSString stringWithFormat:@"@definer %s :: setClipCorners:", cn]);
        }
    }
    free(cs);
    kbp2_log(@"@setterScan done");
}

// -- 0.1.2 全景侦察 --
static void kbp2_dump_all_methods_of(Class c) {
    if (!c) return;
    unsigned count = 0;
    Method *ms = class_copyMethodList(c, &count);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned j = 0; j < count; j++) {
        [names addObject:NSStringFromSelector(method_getName(ms[j]))];
    }
    free(ms);
    kbp2_log([NSString stringWithFormat:@"@allMethods %@: %@", NSStringFromClass(c), [names componentsJoinedByString:@" , "]]);
}

static void kbp2_dump_class_chain(Class c) {
    Class cur = c;
    int guard = 0;
    while (cur && guard++ < 10) {
        kbp2_dump_all_methods_of(cur);
        cur = class_getSuperclass(cur);
    }
}

static void kbp2_dump_uikb_family(void) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    __unsafe_unretained Class *cs = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)n);
    n = objc_getClassList(cs, n);
    NSMutableString *buf = [NSMutableString string];
    for (int i = 0; i < n; i++) {
        const char *cn = class_getName(cs[i]);
        if (strncmp(cn, "UIKB", 4) == 0) {
            [buf appendFormat:@"%s ", cn];
        }
    }
    free(cs);
    kbp2_log([NSString stringWithFormat:@"@uikbFamily: %@", buf]);
}

// -- 0.1.3 UIKBKeyView 键视图侦察 --
static void kbp2_hook_if_overridden(Class cls, SEL sel, IMP imp, IMP *orig);
static BOOL kbp2_chain_contains(Class c, const char *name);

static NSString *kbp2_kv_keyname(id kv) {
    @try {
        SEL ksel = sel_registerName("key");
        if ([kv respondsToSelector:ksel]) {
            id k = ((id(*)(id, SEL))objc_msgSend)(kv, ksel);
            return kbp2_name_of(k);
        }
    } @catch (NSException *e) {}
    return @"?";
}

static IMP sO_kvInit = NULL;
static id p_kvInit(id self, SEL _cmd, struct CGRect frame, id keyplane, id key) {
    id r = sO_kvInit ? ((id(*)(id, SEL, struct CGRect, id, id))sO_kvInit)(self, _cmd, frame, keyplane, key) : nil;
    @try {
        NSString *kn = kbp2_name_of(key);
        if (kbp2_should_log(@"kvInit", kbp2_cls(self), kn))
            kbp2_log([NSString stringWithFormat:@"kvInit cls=%@ key=%@ frame=(%.0f,%.0f,%.0f,%.0f)",
                      kbp2_cls(self), kn, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]);
    } @catch (NSException *e) {}
    return r;
}

static IMP sO_kvInitST = NULL;
static id p_kvInitST(id self, SEL _cmd, struct CGRect frame, id keyplane, id key, id screenTraits) {
    id r = sO_kvInitST ? ((id(*)(id, SEL, struct CGRect, id, id, id))sO_kvInitST)(self, _cmd, frame, keyplane, key, screenTraits) : nil;
    @try {
        NSString *kn = kbp2_name_of(key);
        if (kbp2_should_log(@"kvInitST", kbp2_cls(self), kn))
            kbp2_log([NSString stringWithFormat:@"kvInitST cls=%@ key=%@ frame=(%.0f,%.0f,%.0f,%.0f)",
                      kbp2_cls(self), kn, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]);
    } @catch (NSException *e) {}
    return r;
}

static IMP sO_rfFlags = NULL;
static unsigned long long p_rfFlags(id self, SEL _cmd, id traits) {
    unsigned long long v = sO_rfFlags ? ((unsigned long long(*)(id, SEL, id))sO_rfFlags)(self, _cmd, traits) : 0;
    @try {
        NSString *kn = kbp2_kv_keyname(self);
        if (kbp2_should_log(@"rfFlags", kbp2_cls(self), kn))
            kbp2_log([NSString stringWithFormat:@"rfFlags cls=%@ key=%@ flags=0x%llx", kbp2_cls(self), kn, v]);
    } @catch (NSException *e) {}
    return v;
}

static IMP sO_setHash = NULL;
static void p_setHash(id self, SEL _cmd, id hash) {
    @try {
        NSString *kn = kbp2_kv_keyname(self);
        NSString *hs = @"?";
        if ([hash isKindOfClass:[NSString class]]) hs = (NSString *)hash;
        if (kbp2_should_log(@"setHash", kbp2_cls(self), kn))
            kbp2_log([NSString stringWithFormat:@"setHash cls=%@ key=%@ hash=%@", kbp2_cls(self), kn, hs]);
    } @catch (NSException *e) {}
    if (sO_setHash) ((void(*)(id, SEL, id))sO_setHash)(self, _cmd, hash);
}

static IMP sO_canDraw = NULL;
static BOOL p_canDraw(id self, SEL _cmd) {
    BOOL v = sO_canDraw ? ((BOOL(*)(id, SEL))sO_canDraw)(self, _cmd) : NO;
    @try {
        NSString *kn = kbp2_kv_keyname(self);
        if (kbp2_should_log(@"canDraw", kbp2_cls(self), kn))
            kbp2_log([NSString stringWithFormat:@"canDraw cls=%@ key=%@ ret=%d", kbp2_cls(self), kn, (int)v]);
    } @catch (NSException *e) {}
    return v;
}

// -- 0.1.4 追加侦察 --
static IMP sO_kvUpdate = NULL;
static void p_kvUpdate(id self, SEL _cmd, id keyplane, id key) {
    if (sO_kvUpdate) ((void(*)(id, SEL, id, id))sO_kvUpdate)(self, _cmd, keyplane, key);
    @try {
        NSString *kn = kbp2_name_of(key);
        if (kbp2_should_log(@"kvUpdate", kbp2_cls(self), kn))
            kbp2_log([NSString stringWithFormat:@"kvUpdate cls=%@ key=%@", kbp2_cls(self), kn]);
    } @catch (NSException *e) {}
}

static IMP sO_kvPrepare = NULL;
static void p_kvPrepare(id self, SEL _cmd) {
    @try {
        NSString *kn = kbp2_kv_keyname(self);
        if (kbp2_should_log(@"kvPrepare", kbp2_cls(self), kn))
            kbp2_log([NSString stringWithFormat:@"kvPrepare cls=%@ key=%@", kbp2_cls(self), kn]);
    } @catch (NSException *e) {}
    if (sO_kvPrepare) ((void(*)(id, SEL))sO_kvPrepare)(self, _cmd);
}

static IMP sO_kvDrawR = NULL;
static void p_kvDrawR(id self, SEL _cmd, id renderers) {
    if (sO_kvDrawR) ((void(*)(id, SEL, id))sO_kvDrawR)(self, _cmd, renderers);
    @try {
        NSString *kn = kbp2_kv_keyname(self);
        if (kbp2_should_log(@"kvDrawR", kbp2_cls(self), kn)) {
            NSMutableString *rs = [NSMutableString string];
            if ([renderers isKindOfClass:[NSArray class]]) {
                for (id r in (NSArray *)renderers) [rs appendFormat:@"%@,", kbp2_cls(r)];
            } else {
                [rs appendString:kbp2_cls(renderers)];
            }
            kbp2_log([NSString stringWithFormat:@"kvDrawR cls=%@ key=%@ renderers=[%@]", kbp2_cls(self), kn, rs]);
        }
    } @catch (NSException *e) {}
}

static IMP sO_preferStr = NULL;
static void p_preferStr(id self, SEL _cmd, BOOL v) {
    @try {
        if (kbp2_should_log(@"preferStr", kbp2_cls(self), @(v).stringValue))
            kbp2_log([NSString stringWithFormat:@"preferStringKeycap self=%@ v=%d", kbp2_cls(self), (int)v]);
    } @catch (NSException *e) {}
    if (sO_preferStr) ((void(*)(id, SEL, BOOL))sO_preferStr)(self, _cmd, v);
}

static IMP sO_boldTxt = NULL;
static id p_boldTxt(id self, SEL _cmd, id content, id key) {
    id r = sO_boldTxt ? ((id(*)(id, SEL, id, id))sO_boldTxt)(self, _cmd, content, key) : content;
    @try {
        NSString *kn = kbp2_name_of(key);
        if (kbp2_should_log(@"boldTxt", kbp2_cls(self), kn))
            kbp2_log([NSString stringWithFormat:@"boldTxt self=%@ key=%@ retCls=%@", kbp2_cls(self), kn, kbp2_cls(r)]);
    } @catch (NSException *e) {}
    return r;
}

static void kbp2_install_more_hooks(void) {
    static BOOL done2 = NO;
    Class kvCls = objc_getClass("UIKBKeyView");
    if (kvCls && !done2) {
        done2 = YES;
        const char *kvClasses[] = {
            "UIKBKeyView", "UIKBViewBackedKeyView", "UIKBContainerKeyView",
            "UIKBFloatingKeyView", "UIKBBlurredKeyView", NULL
        };
        for (int i = 0; kvClasses[i]; i++) {
            Class c = objc_getClass(kvClasses[i]);
            if (!c) continue;
            kbp2_hook_if_overridden(c, sel_registerName("updateForKeyplane:key:"), (IMP)p_kvUpdate, &sO_kvUpdate);
            kbp2_hook_if_overridden(c, sel_registerName("prepareForDisplay"), (IMP)p_kvPrepare, &sO_kvPrepare);
            kbp2_hook_if_overridden(c, sel_registerName("drawContentsOfRenderers:"), (IMP)p_kvDrawR, &sO_kvDrawR);
        }
    }
    Class fCls = objc_getClass("UIKBRenderFactory");
    if (fCls) {
        static BOOL done3 = NO;
        if (!done3) {
            done3 = YES;
            kbp2_hook_if_overridden(fCls, sel_registerName("setPreferStringKeycapOverImage:"), (IMP)p_preferStr, &sO_preferStr);
            kbp2_hook_if_overridden(fCls, sel_registerName("applyBoldTextForContent:withKey:"), (IMP)p_boldTxt, &sO_boldTxt);
        }
    }
    kbp2_log(@"more hooks done");
}

static IMP sO_kvAlloc = NULL;
static id p_kvAlloc(id self, SEL _cmd) {
    id r = sO_kvAlloc ? ((id(*)(id, SEL))sO_kvAlloc)(self, _cmd) : nil;
    @try {
        NSString *cn = NSStringFromClass((Class)self);
        if (kbp2_should_log(@"kvAlloc", cn, @"x")) {
            kbp2_log([NSString stringWithFormat:@"kvAlloc cls=%@", cn]);
            kbp2_log_call_site("alloc-ra1", __builtin_return_address(1));
            kbp2_log_call_site("alloc-ra2", __builtin_return_address(2));
        }
    } @catch (NSException *e) {}
    return r;
}

static void kbp2_install_keyview_hooks(void) {
    static BOOL done = NO;
    if (done) return;
    Class kvCls = objc_getClass("UIKBKeyView");
    if (!kvCls) return;
    done = YES;
    // 枚举所有 UIKBKeyView 子类
    int n = objc_getClassList(NULL, 0);
    NSMutableArray *all = [NSMutableArray array];
    if (n > 0) {
        __unsafe_unretained Class *cs = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)n);
        n = objc_getClassList(cs, n);
        for (int i = 0; i < n; i++) {
            if (kbp2_chain_contains(cs[i], "UIKBKeyView")) {
                [all addObject:NSStringFromClass(cs[i])];
                Class c = cs[i];
                kbp2_hook_if_overridden(c, sel_registerName("initWithFrame:keyplane:key:"), (IMP)p_kvInit, &sO_kvInit);
                kbp2_hook_if_overridden(c, sel_registerName("initWithFrame:keyplane:key:screenTraits:"), (IMP)p_kvInitST, &sO_kvInitST);
                kbp2_hook_if_overridden(c, sel_registerName("renderFlagsForTraits:"), (IMP)p_rfFlags, &sO_rfFlags);
                kbp2_hook_if_overridden(c, sel_registerName("setCachedTraitsHashString:"), (IMP)p_setHash, &sO_setHash);
                kbp2_hook_if_overridden(c, sel_registerName("_canDrawContent"), (IMP)p_canDraw, &sO_canDraw);
            }
        }
        free(cs);
    }
    kbp2_log([NSString stringWithFormat:@"kvSubclasses(%lu): %@", (unsigned long)all.count, [all componentsJoinedByString:@" , "]]);
    // hook alloc（挂 UIKBKeyView 本类的元类即可覆盖子类继承调用）
    Class meta = object_getClass(kvCls);
    if (meta && !sO_kvAlloc) {
        MSHookMessageEx(meta, sel_registerName("alloc"), (IMP)p_kvAlloc, &sO_kvAlloc);
    }
    kbp2_log(@"kv hooks done");
}

// -- 0.1.7 KeyplaneView cornerMask / viewForKey --
static IMP sO_cornerMask = NULL;
static unsigned long long p_cornerMask(id self, SEL _cmd, id key, BOOL recursive) {
    unsigned long long v = sO_cornerMask ? ((unsigned long long(*)(id, SEL, id, BOOL))sO_cornerMask)(self, _cmd, key, recursive) : 0;
    @try {
        NSString *kn = kbp2_name_of(key);
        if (kbp2_should_log(@"cornerMask", kbp2_cls(self), [NSString stringWithFormat:@"%@|%d|%llu", kn, recursive, v]))
            kbp2_log([NSString stringWithFormat:@"cornerMask key=%@ recursive=%d ret=0x%llx", kn, recursive ? 1 : 0, v]);
    } @catch (NSException *e) {}
    return v;
}

static IMP sO_viewForKeyState = NULL;
static id p_viewForKeyState(id self, SEL _cmd, id key, long state) {
    id v = sO_viewForKeyState ? ((id(*)(id, SEL, id, long))sO_viewForKeyState)(self, _cmd, key, state) : nil;
    @try {
        NSString *kn = kbp2_name_of(key);
        if (kbp2_should_log(@"viewForKey", kbp2_cls(self), [NSString stringWithFormat:@"%@|%ld|%@", kn, state, kbp2_cls(v)]))
            kbp2_log([NSString stringWithFormat:@"viewForKey key=%@ state=%ld viewCls=%@ view=%p", kn, state, kbp2_cls(v), v]);
    } @catch (NSException *e) {}
    return v;
}

static IMP sO_viewForKey = NULL;
static id p_viewForKey(id self, SEL _cmd, id key) {
    id v = sO_viewForKey ? ((id(*)(id, SEL, id))sO_viewForKey)(self, _cmd, key) : nil;
    @try {
        NSString *kn = kbp2_name_of(key);
        if (kbp2_should_log(@"viewForKey1", kbp2_cls(self), [NSString stringWithFormat:@"%@|%@", kn, kbp2_cls(v)]))
            kbp2_log([NSString stringWithFormat:@"viewForKey key=%@ viewCls=%@ view=%p", kn, kbp2_cls(v), v]);
    } @catch (NSException *e) {}
    return v;
}

// -- 0.1.9 窗口树扫描 + layer 实验（从 traitsPub 触发）--
static void kbp2_window_experiment(void) {
    @try {
        NSArray *wins = [UIApplication sharedApplication].windows;
        NSMutableString *buf = [NSMutableString string];
        int totalKV = 0, changed = 0;
        for (UIWindow *w in wins) {
            int keyviews = 0;
            NSMutableArray *stack = [NSMutableArray arrayWithArray:w.subviews];
            while (stack.count > 0) {
                UIView *v = [stack lastObject];
                [stack removeLastObject];
                if (kbp2_chain_contains([v class], "UIKBKeyView")) {
                    keyviews++;
                    v.layer.cornerRadius = 9.0;
                    v.layer.masksToBounds = YES;
                    SEL mcs = NSSelectorFromString(@"setMaskedCorners:");
                    if ([v.layer respondsToSelector:mcs]) {
                        ((void(*)(id, SEL, unsigned long long))objc_msgSend)(v.layer, mcs, 0xFull);
                    }
                    changed++;
                }
                [stack addObjectsFromArray:v.subviews];
            }
            totalKV += keyviews;
            if (keyviews > 0 || w.subviews.count > 0) {
                [buf appendFormat:@"[%@ lvl=%.0f subs=%lu kv=%d] ",
                  NSStringFromClass([w class]), w.windowLevel, (unsigned long)w.subviews.count, keyviews];
            }
        }
        kbp2_log([NSString stringWithFormat:@"windowScan keyviewTotal=%d changed=%d :: %@", totalKV, changed, buf]);
    } @catch (NSException *e) {
        kbp2_log([NSString stringWithFormat:@"windowExperiment exception: %@", e]);
    }
}

static void kbp2_maybe_schedule_window_scan(void) {
    static BOOL did = NO;
    if (did) return;
    did = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        kbp2_window_experiment();
    });
}

static void kbp2_install_kpv_hooks(void) {
    static BOOL done = NO;
    Class c = objc_getClass("UIKBKeyplaneView");
    if (!c || done) return;
    done = YES;
    kbp2_hook_if_overridden(c, sel_registerName("cornerMaskForKey:recursive:"), (IMP)p_cornerMask, &sO_cornerMask);
    kbp2_hook_if_overridden(c, sel_registerName("viewForKey:state:"), (IMP)p_viewForKeyState, &sO_viewForKeyState);
    kbp2_hook_if_overridden(c, sel_registerName("viewForKey:"), (IMP)p_viewForKey, &sO_viewForKey);
    kbp2_log(@"kpv hooks done");
}

// -- 0.1.8 layer 圆角兜底实验 --
static void kbp2_layer_experiment(id keyplaneView);

static IMP sO_activateKeys = NULL;
static void p_activateKeys(id self, SEL _cmd) {
    if (sO_activateKeys) ((void(*)(id, SEL))sO_activateKeys)(self, _cmd);
    @try {
        if (kbp2_should_log(@"activateKeys", kbp2_cls(self), @"x")) {
            kbp2_log(@"activateKeys called; schedule layer experiment");
            id kpv = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                kbp2_layer_experiment(kpv);
            });
        }
    } @catch (NSException *e) {}
}

static void kbp2_layer_experiment(id keyplaneView) {
    @try {
        NSMutableArray *stack = [NSMutableArray array];
        if ([keyplaneView isKindOfClass:[UIView class]]) [stack addObject:keyplaneView];
        int cnt = 0, total = 0;
        while (stack.count > 0 && total < 2000) {
            UIView *v = [stack lastObject];
            [stack removeLastObject];
            total++;
            if (kbp2_chain_contains([v class], "UIKBKeyView")) {
                v.layer.cornerRadius = 9.0;
                v.layer.masksToBounds = YES;
                SEL mcs = NSSelectorFromString(@"setMaskedCorners:");
                if ([v.layer respondsToSelector:mcs]) {
                    ((void(*)(id, SEL, unsigned long long))objc_msgSend)(v.layer, mcs, 0xFull);
                }
                cnt++;
            }
            if ([v isKindOfClass:[UIView class]]) {
                [stack addObjectsFromArray:v.subviews];
            }
        }
        kbp2_log([NSString stringWithFormat:@"layerExperiment done: keyviews=%d visited=%d", cnt, total]);
    } @catch (NSException *e) {
        kbp2_log([NSString stringWithFormat:@"layerExperiment exception: %@", e]);
    }
}

static void kbp2_install_layer_experiment(void) {
    static BOOL done = NO;
    Class c = objc_getClass("UIKBKeyplaneView");
    if (!c || done) return;
    done = YES;
    kbp2_hook_if_overridden(c, sel_registerName("activateKeys"), (IMP)p_activateKeys, &sO_activateKeys);
    kbp2_log(@"layer experiment hooks done");
}

// geometry copy 追踪
static void kbp2_dump_copy(const char *tag, id self, id ret) {
    @try {
        double r = kbp2_msg_d(ret, "roundRectRadius", -1);
        unsigned long long c = kbp2_msg_ull(ret, "roundRectCorners", 0xFFEEULL);
        double srcR = kbp2_msg_d(self, "roundRectRadius", -1);
        unsigned long long srcC = kbp2_msg_ull(self, "roundRectCorners", 0xFFEEULL);
        NSString *kn = [NSString stringWithFormat:@"%p", self];
        if (kbp2_should_log(@(tag), kbp2_cls(self), kn))
            kbp2_log([NSString stringWithFormat:@"%@ src=%p (r=%g c=0x%llx) -> out=%p (r=%g c=0x%llx)",
                      @(tag), self, srcR, srcC, ret, r, c]);
    } @catch (NSException *e) {}
}

static IMP sO_copyZone = NULL;
static id p_copyZone(id self, SEL _cmd, void *zone) {
    id r = sO_copyZone ? ((id(*)(id, SEL, void *))sO_copyZone)(self, _cmd, zone) : nil;
    kbp2_dump_copy("copyZone", self, r);
    return r;
}

static IMP sO_copyPopup = NULL;
static id p_copyPopup(id self, SEL _cmd, long dir, double scale) {
    id r = sO_copyPopup ? ((id(*)(id, SEL, long, double))sO_copyPopup)(self, _cmd, dir, scale) : nil;
    kbp2_dump_copy("copyPopup", self, r);
    return r;
}

static IMP sO_copyFlick = NULL;
static id p_copyFlick(id self, SEL _cmd, long dir, double scale) {
    id r = sO_copyFlick ? ((id(*)(id, SEL, long, double))sO_copyFlick)(self, _cmd, dir, scale) : nil;
    kbp2_dump_copy("copyFlick", self, r);
    return r;
}

static void kbp2_scan_full(void) {
    kbp2_dump_class_chain(objc_getClass("UIKBRenderFactory"));
    kbp2_dump_all_methods_of(objc_getClass("UIKBRenderTraits"));
    kbp2_dump_all_methods_of(objc_getClass("UIKBShape"));
    kbp2_dump_all_methods_of(objc_getClass("UIKBKeyView"));
    kbp2_dump_all_methods_of(objc_getClass("UIKBKeyplaneView"));
    kbp2_dump_uikb_family();
    kbp2_log(@"@fullScan done");
}

static void kbp2_install_hooks(void) {
    Class fCls = objc_getClass("UIKBRenderFactory");
    if (fCls) {
        if (!sOrig_traitsPub) {
            MSHookMessageEx(fCls, sel_registerName("traitsForKey:onKeyplane:"),
                            (IMP)kbp2_traitsPub, &sOrig_traitsPub);
        }
        if (!sOrig_traitsPriv) {
            MSHookMessageEx(fCls, sel_registerName("_traitsForKey:onKeyplane:"),
                            (IMP)kbp2_traitsPriv, &sOrig_traitsPriv);
        }
        // keyCornerRadius（类型自适应）
        if (!sO_kcrD && !sO_kcrF) {
            Method m = class_getInstanceMethod(fCls, sel_registerName("keyCornerRadius"));
            const char *enc = m ? method_getTypeEncoding(m) : NULL;
            kbp2_log([NSString stringWithFormat:@"keyCornerRadius enc=%s", enc ? enc : "(null)"]);
            if (enc && enc[0] == 'd') {
                MSHookMessageEx(fCls, sel_registerName("keyCornerRadius"), (IMP)p_kcrD, &sO_kcrD);
            } else if (enc && enc[0] == 'f') {
                MSHookMessageEx(fCls, sel_registerName("keyCornerRadius"), (IMP)p_kcrF, &sO_kcrF);
            }
        }
    }
    Class gCls = objc_getClass("UIKBRenderGeometry");
    if (gCls) {
        if (!sO_setRRR) MSHookMessageEx(gCls, sel_registerName("setRoundRectRadius:"), (IMP)p_setRRR, &sO_setRRR);
        if (!sO_setRRC) MSHookMessageEx(gCls, sel_registerName("setRoundRectCorners:"), (IMP)p_setRRC, &sO_setRRC);
        if (!sO_setLBR) MSHookMessageEx(gCls, sel_registerName("setLayeredBackgroundRoundRectRadius:"), (IMP)p_setLBR, &sO_setLBR);
        if (!sO_setLFR) MSHookMessageEx(gCls, sel_registerName("setLayeredForegroundRoundRectRadius:"), (IMP)p_setLFR, &sO_setLFR);
        if (!sO_initShape) MSHookMessageEx(gCls, sel_registerName("initWithShape:"), (IMP)p_initShape, &sO_initShape);
    }
    Class tCls = objc_getClass("UIKBTree");
    if (tCls) {
        if (!sO_shapesForKeys) MSHookMessageEx(tCls, sel_registerName("shapesForKeys:"), (IMP)p_shapesForKeys, &sO_shapesForKeys);
        if (!sO_setClip) MSHookMessageEx(tCls, sel_registerName("setClipCorners:"), (IMP)p_setClip, &sO_setClip);
        if (!sO_setGeom) MSHookMessageEx(tCls, sel_registerName("setGeometry:"), (IMP)p_setGeom, &sO_setGeom);
        if (!sO_geomGetter) MSHookMessageEx(tCls, sel_registerName("geometry"), (IMP)p_geomGetter, &sO_geomGetter);
        if (!sO_activeGeoms) MSHookMessageEx(tCls, sel_registerName("activeGeometriesList"), (IMP)p_activeGeoms, &sO_activeGeoms);
    }
    Class rCls = objc_getClass("UIKBRenderer");
    if (rCls && !sOrig_defaultPath) {
        MSHookMessageEx(rCls, sel_registerName("defaultPathForRenderGeometry:"),
                        (IMP)kbp2_defaultPath, &sOrig_defaultPath);
    }
    if (rCls) {
        if (!sO_rkString) MSHookMessageEx(rCls, sel_registerName("renderKeyStringContents:withTraits:status:"), (IMP)p_rkString, &sO_rkString);
        if (!sO_rkImage) MSHookMessageEx(rCls, sel_registerName("renderKeyImageContents:withTraits:status:"), (IMP)p_rkImage, &sO_rkImage);
        if (!sO_rkPath) MSHookMessageEx(rCls, sel_registerName("renderKeyPathContents:withTraits:status:"), (IMP)p_rkPath, &sO_rkPath);
        if (!sO_rkMain) MSHookMessageEx(rCls, sel_registerName("renderKeyContents:withTraits:"), (IMP)p_rkMain, &sO_rkMain);
    }
    Class trCls = objc_getClass("UIKBRenderTraits");
    if (trCls && !sO_traitsGeom) {
        MSHookMessageEx(trCls, sel_registerName("geometry"), (IMP)p_traitsGeom, &sO_traitsGeom);
    }
    // _customizeGeometry:forKey:contents:（对"重写它的"工厂类安装）
    static BOOL didCust = NO;
    if (!didCust && fCls) {
        didCust = YES;
        Class custClasses[] = {
            objc_getClass("UIKBRenderFactory"),
            objc_getClass("UIKBRenderFactoryiPhone"),
            objc_getClass("UIKBRenderFactoryiPhoneTruffle"),
            objc_getClass("UIKBRenderFactory10Key"),
            objc_getClass("UIKBRenderFactory10Key_Round"),
        };
        for (int i = 0; i < 5; i++) {
            if (custClasses[i])
                kbp2_hook_if_overridden(custClasses[i], sel_registerName("_customizeGeometry:forKey:contents:"),
                                        (IMP)p_custGeom, &sO_custGeom);
        }
    }
    kbp2_log([NSString stringWithFormat:@"classes traits=%d", trCls ? 1 : 0]);
    static BOOL scanned = NO;
    if (!scanned && fCls) {
        scanned = YES;
        @try { kbp2_scan(); } @catch (NSException *e) {
            kbp2_log([NSString stringWithFormat:@"scan exception: %@", e]);
        }
        @try { kbp2_scan_setter_definers(); } @catch (NSException *e) {
            kbp2_log([NSString stringWithFormat:@"setterScan exception: %@", e]);
        }
        @try { kbp2_scan_full(); } @catch (NSException *e) {
            kbp2_log([NSString stringWithFormat:@"fullScan exception: %@", e]);
        }
    }
    // copy 系列追踪
    Class g2Cls = objc_getClass("UIKBRenderGeometry");
    if (g2Cls) {
        if (!sO_copyZone) MSHookMessageEx(g2Cls, sel_registerName("copyWithZone:"), (IMP)p_copyZone, &sO_copyZone);
        if (!sO_copyPopup) MSHookMessageEx(g2Cls, sel_registerName("copyForPopupDirection:scale:"), (IMP)p_copyPopup, &sO_copyPopup);
        if (!sO_copyFlick) MSHookMessageEx(g2Cls, sel_registerName("copyForFlickDirection:scale:"), (IMP)p_copyFlick, &sO_copyFlick);
    }
    @try { kbp2_install_keyview_hooks(); } @catch (NSException *e) {};
    @try { kbp2_install_more_hooks(); } @catch (NSException *e) {};
    @try { kbp2_install_kpv_hooks(); } @catch (NSException *e) {};
    @try { kbp2_install_layer_experiment(); } @catch (NSException *e) {};
    kbp2_log([NSString stringWithFormat:@"installed factory=%d renderer=%d",
              fCls ? 1 : 0, rCls ? 1 : 0]);
}

__attribute__((constructor)) static void kbp2_ctor(void) {
    kbp2_log(@"ctor start");
    // 尽最大努力：ctor 阶段同步安装一次（若类已就绪）
    @try { kbp2_install_hooks(); } @catch (NSException *e) {}
    // 主队列 + 多轮重试兜底（类晚加载时）
    dispatch_async(dispatch_get_main_queue(), ^{
        __block int tries = 0;
        __block void (^retry)(void);
        retry = ^{
            tries++;
            kbp2_install_hooks();
            if ((!objc_getClass("UIKBRenderFactory") || !objc_getClass("UIKBKeyView")) && tries < 60) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), retry);
            }
        };
        retry();
    });
}
