// NoHomeIcons16.m —— 桌面净空（com.xu.nohomeicons）
//
// 版本：0.5.0
//
// 【功能】
//   ① SpringBoard：桌面不显示任何 App 图标，App 只进 App 资源库；Dock 保留。
//   ② SpringBoard：锁定「新下载的 App = 仅 App 资源库」，改设置也不生效
//      （偏好键 SBHomeAutomaticallyAddsNewApplications 恒读成 NO）。
//   ③ 设置 App：隐藏「设置 → 主屏幕」入口。
//
// 【机制 / 证据】iOS 16.5.1 真机运行时 dump：
//   · SBIconModel(super=SBHIconModel) -isIconVisible:            B24@0:8@16
//   · SBIconModel -shouldAvoidPlacingIconOnFirstPage:            B24@0:8@16
//   · 偏好 com.apple.springboard: SBHomeAutomaticallyAddsNewApplications
//     （0 = 仅 App 资源库，1 = 添加到主屏幕；对应设置面板 com.apple.HomeSettings
//       / NSPrincipalClass HOSSettingsController）
//   · 设置根列表由 PreferenceManifests.bundle 的 Mach-O 生成（无 plist 可改）
//     → 入口只能在 PSListController 的 specifier 层过滤
//
// 【日志】/var/mobile/Documents/NoHomeIcons.log
// 【开关】/var/mobile/Library/com.xu.nohomeicons/disabled 存在 = 停用（真系统路径）
//
// 注入：com.apple.springboard + com.apple.Preferences（见 NoHomeIcons16.plist）

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#define NHI_VERSION @"0.6.0"
#define NHI_LOG     @"/var/mobile/Documents/NoHomeIcons.log"
#define NHI_DISABLE @"/var/mobile/Library/com.xu.nohomeicons/disabled"

// 偏好键：新下载的 App 去哪（0=仅 App 资源库 / 1=添加到主屏幕）
static NSString *const kNewAppKey = @"SBHomeAutomaticallyAddsNewApplications";

#pragma mark - 日志

static NSMutableString *gBuf = nil;
static NSString *gTag = @"?";   // 进程标记：SB / PREFS

static void NHIFlush(void) {
    if (!gBuf || gBuf.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:NHI_LOG]) [fm createFileAtPath:NHI_LOG contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:NHI_LOG];
    if (!fh) { [gBuf setString:@""]; return; }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[gBuf dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (__unused NSException *e) {}
    [fh closeFile];
    [gBuf setString:@""];
}

static void L(NSString *fmt, ...) {
    if (!gBuf) gBuf = [NSMutableString new];
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [gBuf appendFormat:@"[%@] %@\n", gTag, s];
    if (gBuf.length > 8 * 1024) NHIFlush();
}

static NSString *NHIIconName(id icon) {
    if (!icon) return @"(nil)";
    @try {
        id v = [icon valueForKey:@"displayName"];
        if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    } @catch (__unused NSException *e) {}
    @try {
        id v = [icon valueForKey:@"applicationBundleIdentifier"];
        if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    } @catch (__unused NSException *e) {}
    return NSStringFromClass([icon class]);
}

// 只对「返回对象」的私有 getter 做安全调用（标量返回强转成 id 会被 ARC retain → 崩）
static id NHICallObj(id obj, NSString *name) {
    if (!obj) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) return nil;
    Method m = class_getInstanceMethod([obj class], sel);
    const char *t = m ? method_getTypeEncoding(m) : NULL;
    if (!t || t[0] != '@') return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(obj, sel); }
    @catch (__unused NSException *e) { return nil; }
}

#pragma mark - 开关（5 秒缓存）

static BOOL NHIEnabled(void) {
    static NSTimeInterval last = 0;
    static BOOL cached = YES;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - last > 5.0) {
        last = now;
        cached = ![[NSFileManager defaultManager] fileExistsAtPath:NHI_DISABLE];
    }
    return cached;
}

#pragma mark - hook 安装

typedef void (*NHIMSHookMessageExFn)(Class cls, SEL sel, IMP replacement, IMP *original);
typedef void (*NHIMSHookFunctionFn)(void *sym, void *repl, void **result);

static NHIMSHookMessageExFn gMsgHook = NULL;
static NHIMSHookFunctionFn  gFnHook  = NULL;

static BOOL NHIInstallHook(Class cls, NSString *selName, IMP repl, IMP *orig) {
    if (!cls) { L(@"[hook] SKIP %@ (class nil)", selName); return NO; }
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { L(@"[hook] MISS %@ -%@", NSStringFromClass(cls), selName); return NO; }
    const char *enc = method_getTypeEncoding(m);
    if (!gMsgHook) { L(@"[hook] FAIL %@ (MSHookMessageEx 不可用)", selName); return NO; }
    gMsgHook(cls, sel, repl, orig);
    BOOL ok = (orig && *orig != NULL);
    L(@"[hook] %@ %@ -%@  type=%s", ok ? @"OK  " : @"FAIL",
      NSStringFromClass(cls), selName, enc ?: "?");
    return ok;
}

#pragma mark - 公共：偏好锁（新下载的 App 恒为「仅 App 资源库」）

static NSUInteger gPrefHits = 0;

// 路径 A：NSUserDefaults
static BOOL (*gOrigBoolForKey)(id, SEL, NSString *) = NULL;
static BOOL NHIBoolForKey(id self, SEL _cmd, NSString *key) {
    if ([key isKindOfClass:[NSString class]] && [key isEqualToString:kNewAppKey]) {
        gPrefHits++;
        if (gPrefHits <= 4) L(@"[pref] 拦截 NSUserDefaults boolForKey:%@ → NO", key);
        if (NHIEnabled()) return NO;
    }
    return gOrigBoolForKey ? gOrigBoolForKey(self, _cmd, key) : NO;
}

static id (*gOrigObjectForKey)(id, SEL, NSString *) = NULL;
static id NHIObjectForKey(id self, SEL _cmd, NSString *key) {
    if ([key isKindOfClass:[NSString class]] && [key isEqualToString:kNewAppKey]) {
        if (NHIEnabled()) {
            gPrefHits++;
            if (gPrefHits <= 4) L(@"[pref] 拦截 NSUserDefaults objectForKey:%@ → @NO", key);
            return @NO;
        }
    }
    return gOrigObjectForKey ? gOrigObjectForKey(self, _cmd, key) : nil;
}

// 路径 B：CFPreferences C API（SpringBoard 内部多用这条）
typedef Boolean (*NHICFPrefBoolFn)(CFStringRef key, CFStringRef appID, Boolean *valid);
static NHICFPrefBoolFn gOrigCFPrefBool = NULL;
static Boolean NHICFPrefBool(CFStringRef key, CFStringRef appID, Boolean *valid) {
    if (key && CFStringCompare(key, (__bridge CFStringRef)kNewAppKey, 0) == kCFCompareEqualTo) {
        if (NHIEnabled()) {
            if (valid) *valid = true;
            return false;
        }
    }
    return gOrigCFPrefBool ? gOrigCFPrefBool(key, appID, valid) : false;
}

typedef CFPropertyListRef (*NHICFPrefCopyFn)(CFStringRef key, CFStringRef appID);
static NHICFPrefCopyFn gOrigCFPrefCopy = NULL;
static CFPropertyListRef NHICFPrefCopy(CFStringRef key, CFStringRef appID) {
    if (key && CFStringCompare(key, (__bridge CFStringRef)kNewAppKey, 0) == kCFCompareEqualTo) {
        if (NHIEnabled()) {
            gPrefHits++;
            if (gPrefHits <= 4) L(@"[pref] 拦截 CFPreferencesCopyAppValue:%@ → false", kNewAppKey);
            return (CFPropertyListRef)CFRetain(kCFBooleanFalse);
        }
    }
    return gOrigCFPrefCopy ? gOrigCFPrefCopy(key, appID) : NULL;
}

static void NHIInstallPrefLock(void) {
    Class defaultsCls = objc_getClass("NSUserDefaults");
    NHIInstallHook(defaultsCls, @"boolForKey:", (IMP)NHIBoolForKey, (IMP *)&gOrigBoolForKey);
    NHIInstallHook(defaultsCls, @"objectForKey:", (IMP)NHIObjectForKey, (IMP *)&gOrigObjectForKey);

    void *fn = dlsym(RTLD_DEFAULT, "CFPreferencesGetAppBooleanValue");
    if (fn && gFnHook) {
        gFnHook(fn, (void *)NHICFPrefBool, (void **)&gOrigCFPrefBool);
        L(@"[hook] %@ CFPreferencesGetAppBooleanValue", gOrigCFPrefBool ? @"OK  " : @"FAIL");
    }
    void *fn2 = dlsym(RTLD_DEFAULT, "CFPreferencesCopyAppValue");
    if (fn2 && gFnHook) {
        gFnHook(fn2, (void *)NHICFPrefCopy, (void **)&gOrigCFPrefCopy);
        L(@"[hook] %@ CFPreferencesCopyAppValue", gOrigCFPrefCopy ? @"OK  " : @"FAIL");
    }
}

#pragma mark - SpringBoard 模块

static NSUInteger gVisibleCalls = 0, gVisibleOrigYes = 0;
static NSUInteger gLayoutCalls = 0, gLayoutLast = 0, gLayoutMax = 0;
static NSUInteger gLayoutLogged = (NSUInteger)-1;

static BOOL (*gOrigIsIconVisible)(id, SEL, id) = NULL;

static BOOL NHIIsIconVisible(id self, SEL _cmd, id icon) {
    BOOL orig = gOrigIsIconVisible ? gOrigIsIconVisible(self, _cmd, icon) : YES;
    gVisibleCalls++;
    if (orig) gVisibleOrigYes++;
    BOOL on = NHIEnabled();
    if (gVisibleCalls <= 6) {
        L(@"[isIconVisible] #%lu %@ 原值=%d → %@", (unsigned long)gVisibleCalls,
          NHIIconName(icon), (int)orig, on ? @"强制 NO" : @"放行(停用)");
    }
    return on ? NO : orig;
}

static void (*gOrigLayoutIconsNow)(id, SEL) = NULL;

static void NHILayoutIconsNow(id self, SEL _cmd) {
    if (gOrigLayoutIconsNow) gOrigLayoutIconsNow(self, _cmd);
    gLayoutCalls++;
    id icons = NHICallObj(self, @"icons");
    NSUInteger n = [icons isKindOfClass:[NSArray class]] ? [(NSArray *)icons count] : 0;
    gLayoutLast = n;
    if (n > gLayoutMax) gLayoutMax = n;
    if (gLayoutCalls <= 6 || n != gLayoutLogged) {
        L(@"[layout] #%lu %@ icons=%lu", (unsigned long)gLayoutCalls,
          NSStringFromClass([self class]), (unsigned long)n);
        gLayoutLogged = n;
    }
}

static BOOL (*gOrigAvoidFirstPage)(id, SEL, id) = NULL;

static BOOL NHIAvoidFirstPage(id self, SEL _cmd, id icon) {
    BOOL orig = gOrigAvoidFirstPage ? gOrigAvoidFirstPage(self, _cmd, icon) : NO;
    return NHIEnabled() ? YES : orig;
}

static void NHIBackupIconStateOnce(void) {
    NSString *dst = @"/var/mobile/Documents/NoHomeIcons_IconState.backup.plist";
    NSString *src = @"/var/mobile/Library/SpringBoard/IconState.plist";
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:dst]) return;
    if (![fm fileExistsAtPath:src]) { L(@"[backup] 源 IconState 不存在，跳过"); return; }
    NSError *err = nil;
    if ([fm copyItemAtPath:src toPath:dst error:&err]) L(@"[backup] IconState 已备份 → %@", dst);
    else L(@"[backup] 备份失败: %@", err.localizedDescription);
}

static BOOL gSBInstalled = NO;

static void NHIInstallSpringBoard(void) {
    if (gSBInstalled) return;
    Class modelCls = objc_getClass("SBIconModel");
    Class listViewCls = objc_getClass("SBIconListView");
    if (!modelCls || !listViewCls) {
        L(@"[boot] SpringBoardHome 未就绪，1s 后重试");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ @autoreleasepool { NHIInstallSpringBoard(); } });
        return;
    }
    NHIInstallHook(modelCls, @"isIconVisible:", (IMP)NHIIsIconVisible, (IMP *)&gOrigIsIconVisible);
    NHIInstallHook(listViewCls, @"layoutIconsNow", (IMP)NHILayoutIconsNow, (IMP *)&gOrigLayoutIconsNow);
    NHIInstallHook(modelCls, @"shouldAvoidPlacingIconOnFirstPage:",
                   (IMP)NHIAvoidFirstPage, (IMP *)&gOrigAvoidFirstPage);
    NHIInstallPrefLock();
    gSBInstalled = YES;
    L(@"[boot] SpringBoard hooks installed, enabled=%d", (int)NHIEnabled());
    NHIFlush();
}

static void NHIReportSpringBoard(void) {
    L(@"[stats] isIconVisible calls=%lu (origVisible=%lu) | layout calls=%lu last=%lu max=%lu | prefHits=%lu",
      (unsigned long)gVisibleCalls, (unsigned long)gVisibleOrigYes,
      (unsigned long)gLayoutCalls, (unsigned long)gLayoutLast, (unsigned long)gLayoutMax,
      (unsigned long)gPrefHits);
    Class ctrlCls = objc_getClass("SBIconController");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    id ctrl = (ctrlCls && [ctrlCls respondsToSelector:shared])
        ? ((id (*)(id, SEL))objc_msgSend)((id)ctrlCls, shared) : nil;
    id lists = NHICallObj(NHICallObj(NHICallObj(ctrl, @"iconManager"), @"rootFolder"), @"lists");
    if ([lists isKindOfClass:[NSArray class]]) {
        NSArray *arr = lists;
        L(@"[stats] pages=%lu", (unsigned long)arr.count);
        for (NSUInteger i = 0; i < MIN((NSUInteger)3, arr.count); i++) {
            id icons = NHICallObj(arr[i], @"icons");
            L(@"[stats]   page[%lu] icons=%lu", (unsigned long)i,
              (unsigned long)([icons isKindOfClass:[NSArray class]] ? [(NSArray *)icons count] : 0));
        }
    }
    NHIFlush();
}

#pragma mark - 设置 App 模块（隐藏「主屏幕」入口）

static NSUInteger gSpecCalls = 0, gSpecDumped = 0;

static NSString *NHISpecDesc(id sp) {
    if (!sp) return @"(nil)";
    NSMutableString *s = [NSMutableString stringWithFormat:@"<%@", NSStringFromClass([sp class])];
    for (NSString *k in @[@"label", @"identifier", @"bundle", @"detail", @"cell", @"name"]) {
        @try {
            id v = [sp propertyForKey:k];
            if (v) [s appendFormat:@" %@=%@", k, v];
        } @catch (__unused NSException *e) {}
    }
    [s appendString:@">"];
    return s;
}

// 只过滤「设置 → 主屏幕」那一项。
// 实测（v0.5.0 dump）：label=HomeScreenPhone detail=DBSHomeScreenPhoneListController cell=PSLinkCell
// —— 该条没有 bundle 属性，靠 detail 的 DBSHomeScreen* 前缀识别。
static BOOL NHIIsHomeSettingsSpec(id sp) {
    @try {
        id detail = [sp propertyForKey:@"detail"];
        if ([detail isKindOfClass:[NSString class]] &&
            [detail rangeOfString:@"HomeScreen"].location != NSNotFound) return YES;
    } @catch (__unused NSException *e) {}

    @try {
        id label = [sp propertyForKey:@"label"];
        if ([label isKindOfClass:[NSString class]] &&
            ([label isEqualToString:@"HomeScreenPhone"] || [label isEqualToString:@"HomeScreeniPad"])) {
            return YES;
        }
    } @catch (__unused NSException *e) {}

    for (NSString *k in @[@"bundle", @"identifier"]) {
        @try {
            id v = [sp propertyForKey:k];
            if ([v isKindOfClass:[NSString class]] && [v rangeOfString:@"HomeSettings"].location != NSNotFound) {
                return YES;
            }
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

// 两个 original 指针必须分开：基类与 PSUIPrefsListController 各自一条实现，
// 共用会互相覆盖 → 调用跳层甚至递归。
static NSArray *(*gOrigSpecRoot)(id, SEL) = NULL;
static NSArray *(*gOrigSpecBase)(id, SEL) = NULL;

static NSArray *NHIFilterSpecs(id self, NSArray *arr) {
    if (![arr isKindOfClass:[NSArray class]]) return arr;

    gSpecCalls++;
    // 首次调用把整个根列表打出来（用于确认入口的准确定位键）
    if (gSpecDumped < 1 && arr.count > 5) {
        gSpecDumped++;
        L(@"[prefs] specifiers from %@ count=%lu", NSStringFromClass([self class]), (unsigned long)arr.count);
        for (id sp in arr) L(@"[prefs]   %@", NHISpecDesc(sp));
        NHIFlush();
    }

    if (!NHIEnabled()) return arr;

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:arr.count];
    for (id sp in arr) {
        if (NHIIsHomeSettingsSpec(sp)) {
            if (gSpecCalls <= 6) L(@"[prefs] 过滤入口 %@", NHISpecDesc(sp));
            continue;
        }
        [out addObject:sp];
    }
    return out;
}

static NSArray *NHISpecifiersRoot(id self, SEL _cmd) {
    return NHIFilterSpecs(self, gOrigSpecRoot ? gOrigSpecRoot(self, _cmd) : nil);
}

static NSArray *NHISpecifiersBase(id self, SEL _cmd) {
    return NHIFilterSpecs(self, gOrigSpecBase ? gOrigSpecBase(self, _cmd) : nil);
}

static BOOL gPrefsInstalled = NO;

#pragma mark 设置根列表定位 + 就地改写

// 根列表在注入时已渲染完，specifiers getter 不会再被调 → 必须直接改 ivar 再刷新
static UIViewController *NHIFindListController(UIViewController *vc) {
    if (!vc) return nil;
    Class psCls = objc_getClass("PSListController");
    if (psCls && [vc isKindOfClass:psCls]) return vc;

    UIViewController *r = NHIFindListController(vc.presentedViewController);
    if (r) return r;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        r = NHIFindListController([(UINavigationController *)vc topViewController]);
        if (r) return r;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        r = NHIFindListController([(UITabBarController *)vc selectedViewController]);
        if (r) return r;
    }
    for (UIViewController *c in vc.childViewControllers) {
        r = NHIFindListController(c);
        if (r) return r;
    }
    return nil;
}

static UIWindow *NHIKeyWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in [(UIWindowScene *)scene windows]) {
            if (!fallback) fallback = w;
            if (w.isKeyWindow) return w;
        }
    }
    return fallback;
}

static NSUInteger gPatchRuns = 0;

// 直接改写 _specifiers + 只刷新表格。
// ⚠️ 绝对不能在 patch 里调 reloadSpecifiers：它会重建 _specifiers 把过滤结果覆盖掉。
static BOOL NHIPatchListNow(UIViewController *listVC) {
    if (!NHIEnabled() || !listVC) return NO;
    NSArray *arr = nil;
    @try { arr = [listVC valueForKey:@"_specifiers"]; } @catch (__unused NSException *e) {}
    if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) return NO;

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:arr.count];
    for (id sp in arr) {
        if (NHIIsHomeSettingsSpec(sp)) continue;
        [out addObject:sp];
    }
    if (out.count == arr.count) return NO;      // 已经干净，不重复写

    @try { [listVC setValue:out forKey:@"_specifiers"]; } @catch (__unused NSException *e) {}
    UITableView *tv = nil;
    @try { tv = [listVC valueForKey:@"table"]; } @catch (__unused NSException *e) {}
    if ([tv isKindOfClass:[UITableView class]]) [tv reloadData];

    gPatchRuns++;
    L(@"[prefs] %@ 移除 %lu 项（剩 %lu）", NSStringFromClass([listVC class]),
      (unsigned long)(arr.count - out.count), (unsigned long)out.count);
    NHIFlush();
    return YES;
}

static void NHIPatchRootList(void) {
    if (!NHIEnabled()) return;
    NHIPatchListNow(NHIFindListController(NHIKeyWindow().rootViewController));
}

// reloadSpecifiers 会重建 _specifiers → 在它之后立刻再删一次，保证任何刷新路径都不回退
static void (*gOrigReloadSpec)(id, SEL) = NULL;
static void NHIReloadSpecifiers(id self, SEL _cmd) {
    if (gOrigReloadSpec) gOrigReloadSpec(self, _cmd);
    if (NHIEnabled()) NHIPatchListNow(self);
}

static void NHIInstallPreferences(void) {
    if (gPrefsInstalled) return;
    Class psCls = objc_getClass("PSListController");
    if (!psCls) {
        L(@"[boot] PSListController 未就绪，1s 后重试");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ @autoreleasepool { NHIInstallPreferences(); } });
        return;
    }
    // ⚠️ 根列表真实类是 PSUIPrefsListController。它对 -specifiers 是真 override 时才
    //    能 hook 子类；否则 class_getInstanceMethod 拿到的是基类同一个 Method，
    //    装两次会把 original 覆盖成自己的 hook → 递归。
    Class rootCls = objc_getClass("PSUIPrefsListController");
    SEL specSel = NSSelectorFromString(@"specifiers");
    Method mBase = class_getInstanceMethod(psCls, specSel);
    Method mRoot = rootCls ? class_getInstanceMethod(rootCls, specSel) : NULL;
    BOOL rootOverridesSpec = (mRoot && mBase &&
                              method_getImplementation(mRoot) != method_getImplementation(mBase));
    L(@"[boot] rootCls=%@ overridesSpecifiers=%d", rootCls ? NSStringFromClass(rootCls) : @"nil",
      (int)rootOverridesSpec);
    if (rootOverridesSpec) {
        NHIInstallHook(rootCls, @"specifiers", (IMP)NHISpecifiersRoot, (IMP *)&gOrigSpecRoot);
    } else {
        NHIInstallHook(psCls, @"specifiers", (IMP)NHISpecifiersBase, (IMP *)&gOrigSpecBase);
    }

    SEL reloadSel = NSSelectorFromString(@"reloadSpecifiers");
    Method rBase = class_getInstanceMethod(psCls, reloadSel);
    Method rRoot = rootCls ? class_getInstanceMethod(rootCls, reloadSel) : NULL;
    BOOL rootOverridesReload = (rRoot && rBase &&
                                method_getImplementation(rRoot) != method_getImplementation(rBase));
    NHIInstallHook((rootOverridesReload ? rootCls : psCls), @"reloadSpecifiers",
                   (IMP)NHIReloadSpecifiers, (IMP *)&gOrigReloadSpec);
    gPrefsInstalled = YES;
    L(@"[boot] Preferences hooks installed, enabled=%d", (int)NHIEnabled());
    NHIFlush();

    // 注入时根列表已渲染完 → 延迟补丁若干次（覆盖初次加载、后台回来、重新进入）
    for (int i = 1; i <= 4; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ @autoreleasepool { NHIPatchRootList(); } });
    }
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ @autoreleasepool { NHIPatchRootList(); } });
    }];
}

#pragma mark - 入口

__attribute__((constructor)) static void NHIInit(void) {
    @autoreleasepool {
        gBuf = [NSMutableString new];
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        BOOL isSB = [bid isEqualToString:@"com.apple.springboard"];
        BOOL isPrefs = [bid isEqualToString:@"com.apple.Preferences"];
        gTag = isSB ? @"SB" : (isPrefs ? @"PREFS" : bid);

        gMsgHook = (NHIMSHookMessageExFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
        gFnHook  = (NHIMSHookFunctionFn)dlsym(RTLD_DEFAULT, "MSHookFunction");

        L(@"");
        L(@"### NoHomeIcons %@ injected  pid=%d  bundle=%@  %@",
          NHI_VERSION, getpid(), bid, [NSDate date]);
        NHIFlush();

        if (isSB) {
            NHIBackupIconStateOnce();
            NHIFlush();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ @autoreleasepool { NHIInstallSpringBoard(); } });
            for (int i = 1; i <= 2; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 14.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ @autoreleasepool { NHIReportSpringBoard(); } });
            }
        } else if (isPrefs) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ @autoreleasepool { NHIInstallPreferences(); } });
        } else {
            L(@"[boot] 非目标进程，跳过");
            NHIFlush();
        }
    }
}
