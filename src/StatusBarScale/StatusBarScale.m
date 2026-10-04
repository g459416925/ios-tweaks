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

#define SBS_VERSION @"1.3.0"
#define SBS_LOG_PATH @"/var/mobile/Documents/sbs_log.txt"

static BOOL    gEnabled = YES;
static CGFloat gScale   = 0.92f;
static CGFloat gDy      = 1.5f;
static CGFloat gThr     = 312.0f;
static BOOL    gVerbose = NO;
static int     gDidDump = 0;
// 辅助图标（系统原生 item 强制启用，参照电话助手排列）
static BOOL         gAuxEnabled = YES;
static NSArray<NSString *> *gAuxIcons = nil;   // 标识集合（小写）
// 辅助条外观：灵动岛下方居中，小尺寸不碍眼
static const CGFloat kAuxIconSize = 9.0;        // 图标边长（points）
static const CGFloat kAuxGap      = 4.0;        // 图标间距

// 受管图标视图的弱引用集合：系统/动画改动它们的 transform 时会被 setTransform: hook 拦截
static NSHashTable *gManaged = nil;   // weak objects

static CGAffineTransform sbs_targetTransform(void) {
    return CGAffineTransformTranslate(
        CGAffineTransformMakeScale(gScale, gScale), 0, gDy / gScale);
}

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
    // 辅助图标配置：默认 = 电话助手的辅助图标集合（系统原生标识）
    if (!gAuxIcons) gAuxIcons = @[@"alarm", @"location", @"quietMode",
                                  @"rotationLock", @"vpn", @"bluetooth"];
    if (d) {
        NSNumber *n;
        if ((n = d[@"auxEnabled"]) && [n isKindOfClass:[NSNumber class]])
            gAuxEnabled = n.boolValue;
        NSArray *arr = d[@"auxIcons"];
        if ([arr isKindOfClass:[NSArray class]] && arr.count) {
            NSMutableArray *m = [NSMutableArray array];
            for (id e in arr)
                if ([e isKindOfClass:[NSString class]] && [(NSString *)e length])
                    [m addObject:[(NSString *)e lowercaseString]];
            if (m.count) gAuxIcons = m;
        }
    }
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

// 子视图数量变化时 dump（捕捉灵动岛/辅助图标 item 视图的动态创建）
static void sbs_dumpOnChange(UIView *fg) {
    static NSInteger lastCount = -1;
    NSInteger n = fg.subviews.count;
    if (n == lastCount) return;
    lastCount = n;
    NSMutableString *o = [NSMutableString stringWithFormat:
        @"[dump#] subviews=%lu\n", (unsigned long)n];
    for (UIView *v in fg.subviews) {
        [o appendFormat:@"  %-42s %@  hidden=%d\n",
            class_getName(v.class), NSStringFromCGRect(v.frame), v.hidden];
    }
    sbs_log(@"%@", o);
}

static void sbs_auxLayoutInFG(UIView *fg);   // 辅助图标条布局（定义见后）

static void sbs_apply(UIView *fg) {
    if (!gEnabled) return;
    CGAffineTransform t = sbs_targetTransform();
    if (!gManaged) gManaged = [NSHashTable weakObjectsHashTable];
    for (UIView *v in fg.subviews) {
        // 按类名过滤：只缩放状态栏 item 视图（含辅助图标），
        // 不碰全宽 legibility 象限背景（普通 UIView）
        NSString *cn = NSStringFromClass(v.class);
        BOOL isItem = [cn containsString:@"StatusBar"] || [cn containsString:@"Battery"];
        if (isItem && CGRectGetMinX(v.frame) >= gThr) {
            // 登记为受管视图（弱引用，view 销毁自动剔除）
            [gManaged addObject:v];
            if (!CGAffineTransformEqualToTransform(v.transform, t)) v.transform = t;
        }
    }
    @try { sbs_auxLayoutInFG(fg); } @catch (NSException *e) { sbs_log(@"[exc-auxL] %@", e); }
}

// 标识词表侦查：去重记录 item 标识流
static NSMutableSet *sbs_seenIdent(void) {
    static NSMutableSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}

static void sbs_logIdentOnce(NSString *tag, NSString *ident) {
    if (![ident isKindOfClass:[NSString class]] || !ident.length) return;
    NSString *key = [NSString stringWithFormat:@"%@:%@", tag, ident];
    if ([sbs_seenIdent() containsObject:key]) return;
    [sbs_seenIdent() addObject:key];
    sbs_log(@"[%@] %@", tag, ident);
}

// 辅助图标条模块前向声明（定义见 SBSHelper 之后）
static id   sbs_gData(void);
static void sbs_setGData(id d);
static void sbs_auxRefresh(void);

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
        sbs_dumpOnChange((UIView *)self);
        sbs_apply((UIView *)self);
    } @catch (NSException *e) {
        sbs_log(@"[exc] %@", e);
    }
}

// ⭐ 核心修复：hook UIView 的 setTransform:。
// 灵动岛过渡动画会直接改写【图标子视图】的 transform（复原/过渡），
// 而这不触发父视图 layoutSubviews。此处拦截：只要 self 是被登记的受管图标，
// 就把系统改动的 transform 立即改回我们的缩放值，消除「复原→二次缩放」空窗。
- (void)sbs_viewSetTransform:(CGAffineTransform)t {
    [self sbs_viewSetTransform:t];        // 原实现
    if (!gEnabled || !gManaged) return;
    @try {
        UIView *v = (UIView *)self;
        if ([gManaged containsObject:v]) {
            CGAffineTransform want = sbs_targetTransform();
            if (!CGAffineTransformEqualToTransform(t, want)) {
                v.transform = want;       // 重新走 setTransform（值已等于 want，不会死循环）
            }
        }
    } @catch (NSException *e) {
        sbs_log(@"[exc] %@", e);
    }
}

// 状态栏 foreground view 被重新挂到 window（灵动岛过渡重建）时补一次。
- (void)sbs_fgDidMoveToWindow {
    [self sbs_fgDidMoveToWindow];         // 原实现
    @try {
        if (gVerbose) sbs_log(@"[didMove] self=%@ win=%@",
            NSStringFromClass(((UIView *)self).class),
            ((UIView *)self).window ? @"有" : @"nil");
        // 挂载后的布局尚未发生时，子视图可能还没建好 → 下一 runloop 补施
        dispatch_async(dispatch_get_main_queue(), ^{
            sbs_apply((UIView *)self);
        });
    } @catch (NSException *e) {
        sbs_log(@"[exc] %@", e);
    }
}

// ⭐ 辅助图标核心：hook 系统的 canEnableDisplayItem:fromData:。
// 刘海/灵动岛机型的状态栏管理器默认对 alarm/location/quietMode/rotationLock/vpn
// 等 item 返回 NO（不启用）→ 图标根本不创建。这里对辅助标识强制返回 YES，
// 让系统自己创建并管理这些 item 视图（状态/染色/动画全原生）。
// 标识取自 displayItem（KVC identifier，构造期已 dump 过 ivar 名）。
- (BOOL)sbs_canEnableDisplayItem:(id)item fromData:(id)data {
    BOOL orig = [self sbs_canEnableDisplayItem:item fromData:data];
    @try {
        if (!gAuxEnabled || !gAuxIcons.count) return orig;
        NSString *ident = nil;
        for (NSString *k in (@[@"identifier", @"_identifier", @"_itemIdentifier"])) {
            @try { ident = [item valueForKey:k]; } @catch (__unused NSException *e) {}
            if ([ident isKindOfClass:[NSString class]]) break;
            ident = nil;
        }
        if (!ident) return orig;
        sbs_logIdentOnce(@"canEnable", ident);
        // 顺带捕获 data 对象（辅助图标条的状态源）
        if (data && !sbs_gData()) sbs_setGData(data);
        BOOL want = [gAuxIcons containsObject:ident.lowercaseString];
        if (want) sbs_log(@"[canEnable] %@ orig=%d → 强制 YES", ident, orig);
        return want ? YES : orig;
    } @catch (NSException *e) {
        sbs_log(@"[exc] %@", e);
        return orig;
    }
}

// ⭐ 状态源：_UIStatusBarData 每次状态更新都走 applyUpdate（底层 _applyUpdate:keys:）。
// 捕获 data（弱引用）并刷新辅助图标条 —— location/alarm/vpn/bluetooth/quietMode/
// rotationLock 状态变化实时驱动图标显隐，与 CallAssist 同源（它也读这些 Entry）。
- (void)sbs_dataApplyUpdate:(id)u {
    [self sbs_dataApplyUpdate:u];         // 原实现
    @try {
        sbs_setGData((id)self);
        sbs_auxRefresh();
    } @catch (NSException *e) {
        sbs_log(@"[exc] %@", e);
    }
}

- (void)sbs_dataApplyUpdateKeys:(id)u keys:(id)keys {
    [self sbs_dataApplyUpdateKeys:u keys:keys];   // 原实现
    @try {
        sbs_setGData((id)self);
        if (gVerbose) sbs_log(@"[dataU] keys=%@", keys);
        sbs_auxRefresh();
    } @catch (NSException *e) {
        sbs_log(@"[exc] %@", e);
    }
}

// 侦查：item 视图创建流（词表 + aux 标识是否被问到）
- (UIView *)sbs_viewForIdentifier:(id)ident {
    UIView *v = [self sbs_viewForIdentifier:ident];
    @try { sbs_logIdentOnce(@"viewFor", [ident isKindOfClass:NSString.class] ? ident : nil); }
    @catch (__unused NSException *e) {}
    return v;
}

// 侦查：display item 创建流
- (id)sbs_createDisplayItemForIdentifier:(id)ident {
    id r = [self sbs_createDisplayItemForIdentifier:ident];
    @try { sbs_logIdentOnce(@"createDI", [ident isKindOfClass:NSString.class] ? ident : nil); }
    @catch (__unused NSException *e) {}
    return r;
}
@end

// 运行时扫描「selector 的实现定义类」（排除继承得来的），要求方法签名完全匹配。
// ⚠️ 设备上存在同名不同签名的干扰方法（如 UIKeyboardCandidateViewStyle 的 v@: 版本），
//    必须按 encoding 过滤，否则 hook 到错误方法直接 SKIP。
static Class sbs_findDefiner(SEL sel, const char *wantEnc) {
    // 1) 先试已知候选类（确定性好）
    for (NSString *name in (@[@"_UIStatusBarManager", @"_UIStatusBar",
                              @"UIStatusBar", @"_UIStatusBarData"])) {
        Class c = objc_getClass(name.UTF8String);
        if (!c) continue;
        Method m = class_getInstanceMethod(c, sel);
        if (m && method_getTypeEncoding(m) &&
            strcmp(method_getTypeEncoding(m), wantEnc) == 0) return c;
    }
    // 2) 全类扫描兜底
    int num = objc_getClassList(NULL, 0);
    if (num <= 0) return nil;
    Class *classes = (Class *)malloc(sizeof(Class) * num);
    num = objc_getClassList(classes, num);
    Class found = nil;
    for (int i = 0; i < num; i++) {
        Class c = classes[i];
        if (!c) continue;
        Method m = class_getInstanceMethod(c, sel);
        if (!m) continue;
        const char *enc = method_getTypeEncoding(m);
        if (!enc || strcmp(enc, wantEnc) != 0) continue;   // 签名不符 → 跳过
        Class sup = class_getSuperclass(c);
        Method mSup = sup ? class_getInstanceMethod(sup, sel) : NULL;
        if (m != mSup) { found = c; break; }               // 自己定义了该方法
    }
    free(classes);
    return found;
}

// ===========================================================================
#pragma mark - 辅助图标条（系统字形 + _UIStatusBarData 状态镜像）
// ===========================================================================

// _UIStatusBarData 弱引用（状态源；由 applyUpdate / canEnable hook 捕获）
static id sbs_gData(void) {
    return objc_getAssociatedObject(SBSHelper.class, @selector(sbs_gData));
}
static void sbs_setGData(id d) {
    objc_setAssociatedObject(SBSHelper.class, @selector(sbs_gData), d,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView       *gStrip = nil;                       // 辅助图标条容器
static NSMutableDictionary<NSString *, UIImageView *> *gAuxViews = nil;

// 标识 → (car 字形候选[], SF Symbol 兜底)
static NSArray *sbs_auxSpec(NSString *ident) {
    NSDictionary *m = @{
        @"alarm":        @[@[@"Black_Alarm", @"LockScreen_Alarm"], @"alarm.fill"],
        @"location":     @[@[@"Black_Location", @"Split_Location", @"LockScreen_Location"], @"location.fill"],
        @"quietmode":    @[@[@"Black_QuietMode", @"LockScreen_QuietMode"], @"moon.fill"],
        @"rotationlock": @[@[@"Black_RotationLock", @"LockScreen_RotationLock"], @"lock.rotation"],
        @"vpn":          @[@[@"Black_VPN", @"LockScreen_VPN", @"SystemUpdate_VPN"], @"lock.shield.fill"],
        @"bluetooth":    @[@[@"Black_Bluetooth", @"LockScreen_Bluetooth", @"SystemUpdate_Bluetooth"], @"bluetooth"],
        @"airplane":     @[@[@"Black_Airplane", @"LockScreen_Airplane"], @"airplane"],
    };
    NSArray *spec = m[ident.lowercaseString];
    return spec ?: @[@[], @"questionmark.circle"];
}

// ⚠️ RootHide 的 roothidepatch 会扫描 dylib 里的路径字符串，把 /System/Library/...
//   这类系统路径重定向到 jbroot 并做 patch；patch 后不重签 → dyld 报 Invalid Page
//   直接杀掉宿主。故此处【绝不能】出现完整 /System/... 路径字面量，必须运行时拼接。
static NSBundle *sbs_auxArtworkBundle(void) {
    static NSBundle *b = nil;
    if (b) return b;
    // "/System" + "/Library" + "/PrivateFrameworks" + "/UIKitCore.framework" + "/Artwork.bundle"
    NSString *p = [@[@"/System", @"/Library", @"/PrivateFrameworks",
                     @"/UIKitCore.framework", @"/Artwork.bundle"] componentsJoinedByString:@""];
    b = [NSBundle bundleWithPath:p];
    return b;
}
static NSBundle *sbs_auxUIKitBundle(void) {
    static NSBundle *b = nil;
    if (b) return b;
    NSString *p = [@[@"/System", @"/Library", @"/PrivateFrameworks",
                     @"/UIKitCore.framework"] componentsJoinedByString:@""];
    b = [NSBundle bundleWithPath:p];
    return b;
}

static UIImage *sbs_auxImage(NSString *ident) {
    NSArray *spec = sbs_auxSpec(ident);
    NSArray *cars = spec.count > 0 ? spec[0] : @[];
    NSString *sf  = spec.count > 1 ? spec[1] : nil;
    NSBundle *aw = sbs_auxArtworkBundle();
    NSBundle *uk = sbs_auxUIKitBundle();
    NSArray *bundleCandidates = aw ? @[aw, uk] : (uk ? @[uk] : @[]);
    for (NSString *n in cars) {
        for (NSBundle *b in bundleCandidates) {
            UIImage *im = [UIImage imageNamed:n inBundle:b compatibleWithTraitCollection:nil];
            if (im) { sbs_logIdentOnce(@"icon", [NSString stringWithFormat:@"%@ ← car:%@", ident, n]); return im; }
        }
    }
    if (sf) {
        UIImage *im = [UIImage systemImageNamed:sf];
        if (im) { sbs_logIdentOnce(@"icon", [NSString stringWithFormat:@"%@ ← SF:%@", ident, sf]); return im; }
    }
    sbs_logIdentOnce(@"icon", [NSString stringWithFormat:@"%@ ← 加载失败", ident]);
    return nil;
}

// 建条：全局只建一次；fg 重建时把同一条移过去（不重建，避免 0.2s 内重建 16 次的抖动）
static void sbs_auxEnsureInFG(UIView *fg) {
    if (!gAuxEnabled || !gAuxIcons.count) return;
    if (gStrip) {
        if (gStrip.superview == fg) return;
        [gStrip removeFromSuperview];
        [fg addSubview:gStrip];               // 移动复用，图标/状态全保留
        return;
    }
    gStrip = [[UIView alloc] initWithFrame:CGRectZero];
    gStrip.userInteractionEnabled = NO;
    gStrip.backgroundColor = nil;
    gAuxViews = [NSMutableDictionary dictionary];
    CGFloat x = 0;
    for (NSString *ident in gAuxIcons) {
        UIImage *im = sbs_auxImage(ident);
        UIImageView *iv = [[UIImageView alloc] initWithFrame:
            CGRectMake(x, 0, kAuxIconSize, kAuxIconSize)];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        if (im) {
            iv.image = [im imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
        iv.hidden = YES;
        [gStrip addSubview:iv];
        gAuxViews[ident.lowercaseString] = iv;
        x += kAuxIconSize + kAuxGap;
    }
    [fg addSubview:gStrip];
    sbs_log(@"[aux] 条已创建 icons=%lu size=%.0f", (unsigned long)gAuxViews.count, kAuxIconSize);
}

// 只有"活的"状态栏（有时间文字/电池等内容视图）才托管辅助条。
// SpringBoard 里存在多个 _UIStatusBarForegroundView 实例（主屏/锁屏等），
// 不加此门禁会在多个 fg 间反复搬条 → 0.2s 内"条已创建"刷 16 次。
static BOOL sbs_fgIsLive(UIView *fg) {
    for (UIView *v in fg.subviews) {
        NSString *cn = NSStringFromClass(v.class);
        if ([cn containsString:@"StringView"] || [cn containsString:@"Battery"]) return YES;
    }
    return NO;
}

// Entry → 是否激活（多形态兼容；未知形态打一次样本日志）
static BOOL sbs_entryActive(id entry, NSString *ident) {
    if (!entry) return NO;
    if ([entry isKindOfClass:[NSNumber class]]) return [(NSNumber *)entry boolValue];
    for (NSString *k in (@[@"visible", @"isVisible", @"shown", @"active", @"enabled"])) {
        @try {
            id v = [entry valueForKey:k];
            if ([v isKindOfClass:[NSNumber class]]) {
                sbs_logIdentOnce(@"entry", [NSString stringWithFormat:@"%@.%@=%@",
                    ident, k, v]);
                return [(NSNumber *)v boolValue];
            }
        } @catch (__unused NSException *e) {}
    }
    sbs_logIdentOnce(@"entry", [NSString stringWithFormat:@"%@ 样本 %@(%@)",
        ident, NSStringFromClass([entry class]), entry]);
    return NO;
}

// 读 _UIStatusBarData 各 Entry → 驱动图标显隐
static void sbs_auxRefresh(void) {
    if (!gAuxEnabled || !gAuxViews.count) return;
    id data = sbs_gData();
    if (!data) return;
    for (NSString *ident in gAuxViews) {
        NSString *key = [NSString stringWithFormat:@"%@Entry", ident];
        id entry = nil;
        @try { entry = [data valueForKey:key]; } @catch (__unused NSException *e) {}
        UIImageView *iv = gAuxViews[ident];
        iv.hidden = !sbs_entryActive(entry, ident);
    }
}

// 布局：条放灵动岛正下方居中（许总指定），图标缩小到 9pt，颜色跟随时间文字
static void sbs_auxLayoutInFG(UIView *fg) {
    if (!gAuxEnabled) { if (gStrip) gStrip.hidden = YES; return; }
    if (!sbs_fgIsLive(fg)) return;            // 非活动 fg 不托管不搬动
    sbs_auxEnsureInFG(fg);
    if (!gStrip || gStrip.superview != fg) return;
    sbs_auxRefresh();
    // 颜色跟随时间文字
    UIColor *tint = nil;
    for (UIView *v in fg.subviews) {
        if ([NSStringFromClass(v.class) containsString:@"StringView"]) {
            UILabel *l = (UILabel *)v;
            if ([l respondsToSelector:@selector(textColor)]) { tint = l.textColor; break; }
        }
    }
    for (UIImageView *iv in gAuxViews.allValues) iv.tintColor = tint ?: UIColor.whiteColor;
    // 统计可见图标 → 总宽
    NSInteger n = 0;
    for (NSString *ident in gAuxIcons) {
        UIImageView *iv = gAuxViews[ident.lowercaseString];
        if (iv && !iv.hidden) n++;
    }
    CGFloat fgW = fg.bounds.size.width;
    CGFloat fgH = fg.bounds.size.height;
    if (n <= 0 || fgW <= 0) { gStrip.hidden = YES; return; }
    gStrip.hidden = NO;
    CGFloat w = n * kAuxIconSize + (n - 1) * kAuxGap;
    CGFloat x = (fgW - w) / 2.0;              // 水平居中
    CGFloat y = fgH - kAuxIconSize - 1.0;     // 贴底 = 灵动岛正下方（fg 高 54 → y=44）
    gStrip.frame = CGRectMake(x, y, w, kAuxIconSize);
    // 从左往右排可见图标（保持 gAuxIcons 声明顺序）
    CGFloat cx = 0;
    for (NSString *ident in gAuxIcons) {
        UIImageView *iv = gAuxViews[ident.lowercaseString];
        if (!iv || iv.hidden) continue;
        iv.frame = CGRectMake(cx, 0, kAuxIconSize, kAuxIconSize);
        cx += kAuxIconSize + kAuxGap;
    }
}

static void sbs_installAux(void);   // 辅助模块延迟安装（见 sbs_install 内注释）

static void sbs_install(void) {
    Class FG = objc_getClass("_UIStatusBarForegroundView");
    if (!FG) { sbs_log(@"[hook] FAIL _UIStatusBarForegroundView 不存在"); return; }
    BOOL ok = SBSHook(FG, @selector(layoutSubviews),
                      SBSHelper.class, @selector(sbs_fgLayoutSubviews));
    sbs_log(@"[hook] layoutSubviews → %@", ok ? @"已安装" : @"失败");

    // 全局 hook UIView.setTransform: 拦截受管图标被系统重置（关键修复）
    ok = SBSHook([UIView class], @selector(setTransform:),
                 SBSHelper.class, @selector(sbs_viewSetTransform:));
    sbs_log(@"[hook] UIView.setTransform: → %@", ok ? @"已安装" : @"失败");

    ok = SBSHook(FG, @selector(didMoveToWindow),
                 SBSHelper.class, @selector(sbs_fgDidMoveToWindow));
    sbs_log(@"[hook] didMoveToWindow → %@", ok ? @"已安装" : @"失败");

    // —— 辅助图标：强制启用系统原生 item ——
    // ⛔ 崩溃教训（v1.1.0，2026-10-04 16:25 SIGABRT）：构造期对任意类调
    //    class_getInstanceMethod 会触发该类 +initialize，早期启动时会抛异常
    //    （栈：sbs_ctor → class_getInstanceMethod → initializeNonMetaClass → rethrow）。
    //    ⇒ 整个辅助模块延迟到主队列 3 秒后（UIKit 完全就绪）再装。
    if (gAuxEnabled) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           sbs_installAux();
                       });
        sbs_log(@"[aux] 已排定 3s 后安装（避开构造期类初始化）");
    }
}

static void sbs_installAux(void) {
    @try {
        // —— API 面侦查：状态数据从哪来 ——
        for (NSString *cn in (@[@"_UIStatusBarData", @"_UIStatusBarManager",
                                @"_UIStatusBarItem", @"_UIStatusBar"])) {
            Class c = objc_getClass(cn.UTF8String);
            if (!c) continue;
            unsigned int n = 0;
            Method *ms = class_copyMethodList(object_getClass(c) ?: c, &n); // 类方法
            NSMutableString *o = [NSMutableString stringWithFormat:
                @"[%@ classMethods] ", cn];
            for (unsigned int i = 0; i < n; i++)
                [o appendFormat:@"%s ", sel_getName(method_getName(ms[i]))];
            free(ms);
            sbs_log(@"%@", o.length > 2000 ? [o substringToIndex:2000] : o);
        }
        for (NSString *cn in (@[@"_UIStatusBarData", @"_UIStatusBarItem"])) {
            Class c = objc_getClass(cn.UTF8String);
            if (!c) continue;
            unsigned int n = 0;
            Method *ms = class_copyMethodList(c, &n);                       // 实例方法
            NSMutableString *o = [NSMutableString stringWithFormat:
                @"[%@ instMethods] ", cn];
            for (unsigned int i = 0; i < n; i++)
                [o appendFormat:@"%s ", sel_getName(method_getName(ms[i]))];
            free(ms);
            sbs_log(@"%@", o.length > 2400 ? [o substringToIndex:2400] : o);
        }
        // 先 dump _UIStatusBarDisplayItem 的 ivar 名（确定标识字段）
        Class DI = objc_getClass("_UIStatusBarDisplayItem");
        if (DI) {
            unsigned int n = 0;
            Ivar *iv = class_copyIvarList(DI, &n);
            NSMutableString *o = [NSMutableString stringWithString:@"[DisplayItem ivars] "];
            for (unsigned int i = 0; i < n; i++)
                [o appendFormat:@"%s ", ivar_getName(iv[i])];
            free(iv);
            sbs_log(@"%@", o);
        }
        SEL ce = @selector(canEnableDisplayItem:fromData:);
        Class owner = sbs_findDefiner(ce, "B32@0:8@16@24");
        sbs_log(@"[canEnable] 实现类 = %@", owner ? NSStringFromClass(owner) : @"(未找到)");
        if (owner) {
            BOOL ok = SBSHook(owner, ce, SBSHelper.class,
                              @selector(sbs_canEnableDisplayItem:fromData:));
            sbs_log(@"[hook] canEnableDisplayItem:fromData: → %@",
                    ok ? @"已安装" : @"失败");
        }
        // 侦查 hook：item 视图 / display item 创建流
        Class IT = objc_getClass("_UIStatusBarItem");
        if (IT) {
            BOOL ok1 = SBSHook(IT, @selector(viewForIdentifier:),
                               SBSHelper.class, @selector(sbs_viewForIdentifier:));
            BOOL ok2 = SBSHook(IT, @selector(createDisplayItemForIdentifier:),
                               SBSHelper.class, @selector(sbs_createDisplayItemForIdentifier:));
            sbs_log(@"[hook] viewFor/createDI → %d/%d", ok1, ok2);
        }

        // ⭐ 状态源 hook：_UIStatusBarData 的 applyUpdate 系列。
        // 这是状态栏数据每次更新的真实入口，必须 hook 它来捕获 data 并驱动辅助条刷新。
        // （此前只 hook canEnableDisplayItem 但该路径 SpringBoard 不常走 → data 一直为空）
        Class D = objc_getClass("_UIStatusBarData");
        if (D) {
            // 探测签名（applyUpdate: 与 _applyUpdate:keys:）
            Method m1 = class_getInstanceMethod(D, @selector(applyUpdate:));
            Method m2 = class_getInstanceMethod(D, @selector(_applyUpdate:keys:));
            sbs_log(@"[dataU] applyUpdate: 签名 = %s",
                    m1 ? method_getTypeEncoding(m1) : "(无)");
            sbs_log(@"[dataU] _applyUpdate:keys: 签名 = %s",
                    m2 ? method_getTypeEncoding(m2) : "(无)");
            // 优先 hook 底层 _applyUpdate:keys:（每次状态更新必调，签名 v32@0:8@16@24）
            if (m2) {
                BOOL ok = SBSHook(D, @selector(_applyUpdate:keys:),
                                  SBSHelper.class, @selector(sbs_dataApplyUpdateKeys:keys:));
                sbs_log(@"[hook] _applyUpdate:keys: → %@", ok ? @"已安装" : @"失败");
            }
            // 兜底 hook applyUpdate:
            if (m1) {
                BOOL ok = SBSHook(D, @selector(applyUpdate:),
                                  SBSHelper.class, @selector(sbs_dataApplyUpdate:));
                sbs_log(@"[hook] applyUpdate: → %@", ok ? @"已安装" : @"失败");
            }
        }
    } @catch (NSException *e) {
        sbs_log(@"[exc-aux] %@", e);
    }
}

__attribute__((constructor))
static void sbs_ctor(void) {
    sbs_loadConfig();
    sbs_log(@"[载入] v%@ proc=%@ pid=%d enabled=%d scale=%.3f dy=%.2f thr=%.0f",
            SBS_VERSION, [[NSProcessInfo processInfo] processName], getpid(),
            gEnabled, gScale, gDy, gThr);
    sbs_install();
}
