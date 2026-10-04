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

#define SBS_VERSION @"1.4.3"
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
static BOOL         gAuxStrip = YES;              // 二分开关：条+岛扫描
static BOOL         gAuxData  = YES;              // 二分开关：applyUpdate 数据钩子
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
    // ⭐ 限流（v1.4.0 血泪教训：探针每秒几千次写日志 → 日志 150MB +
    //    SpringBoard 内存 5.5GB → Jetsam 循环杀进程 = 许总看到的"下拉就 respring"）
    static NSTimeInterval windowStart = 0, lastWrite = 0;
    static int dropped = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (windowStart == 0) windowStart = now;
    if (now - windowStart >= 5.0) {
        if (dropped > 0) {
            NSString *s = [NSString stringWithFormat:@"[限流] 5s 丢弃 %d 条日志\n", dropped];
            [s writeToFile:SBS_LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        windowStart = now; dropped = 0;
    }
    if (now - lastWrite < 0.05) { dropped++; return; }   // ≤20 行/秒
    lastWrite = now;
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
    // 文件超 2MB 归零（保险丝）
    static int writes = 0;
    if ((++writes & 0x3F) == 0) {
        NSDictionary *attr = [NSFileManager.defaultManager
            attributesOfItemAtPath:SBS_LOG_PATH error:nil];
        if ([attr fileSize] > 2 * 1024 * 1024) {
            [NSFileManager.defaultManager removeItemAtPath:SBS_LOG_PATH error:nil];
        }
    }
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
    // 辅助图标配置：默认 = 系统状态栏【没有】原生显示的项。
    // ⚠️ location 不放默认集：系统已在时间旁渲染原生定位箭头，重复显示（许总反馈）。
    if (!gAuxIcons) gAuxIcons = @[@"alarm", @"quietMode",
                                  @"rotationLock", @"vpn", @"bluetooth"];
    if (d) {
        NSNumber *n;
        if ((n = d[@"auxEnabled"]) && [n isKindOfClass:[NSNumber class]])
            gAuxEnabled = n.boolValue;
        if ((n = d[@"auxStrip"]) && [n isKindOfClass:[NSNumber class]])
            gAuxStrip = n.boolValue;
        if ((n = d[@"auxData"]) && [n isKindOfClass:[NSNumber class]])
            gAuxData = n.boolValue;
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
static void sbs_captureSysIcon(NSString *ident, UIView *v);   // v1.4.2 系统图捕获

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
        // ⛔ dump 探针仅 verbose 模式（v1.3.0 血泪教训：控制中心动画时 subviews
        //    每帧变化 → dump 风暴 → 日志 150MB + SB 内存 5.5GB → Jetsam 循环重启）
        if (gVerbose) {
            sbs_dumpOnce((UIView *)self);
            sbs_dumpOnChange((UIView *)self);
        }
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
        // ⭐ v1.4.2 补触发辅助条布局：锁屏→解锁后 fg 被重新挂载，
        //    辅助条全局单例还挂在旧宿主上 → "解锁后条消失"的根因。
        //    延迟 0.3s（等 fgIsLive 内容视图就绪）再劫持回新宿主。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { sbs_auxLayoutInFG((UIView *)self); }
            @catch (NSException *e) { sbs_log(@"[exc-auxDM] %@", e); }
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

// ⭐ v1.4.2 核心增强：捕获系统自己渲染的状态栏 item 视图 image（实现见后）。
- (UIView *)sbs_viewForIdentifier:(id)ident {
    UIView *v = [self sbs_viewForIdentifier:ident];
    @try {
        if ([ident isKindOfClass:[NSString class]])
            sbs_captureSysIcon((NSString *)ident, v);
    } @catch (__unused NSException *e) {}
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
    if (!d) return;
    // ⭐ v1.4.2 保底：锁屏/解锁切换时新 data 的 Entry 可能全为空（锁屏 data），
    //    若直接覆盖会导致辅助图标全隐（条"短暂出现又消失"的根因之一）。
    //    策略：数一数新 data 里非 nil 的 Entry，只有 ≥ 旧 data 才替换。
    id old = sbs_gData();
    if (old && old != d) {
        NSInteger oldN = 0, newN = 0;
        for (NSString *k in (@[@"alarmEntry", @"locationEntry", @"quietModeEntry",
                               @"rotationLockEntry", @"vpnEntry", @"bluetoothEntry"])) {
            @try { if ([old valueForKey:k]) oldN++; } @catch (__unused NSException *e) {}
            @try { if ([d valueForKey:k]) newN++; } @catch (__unused NSException *e) {}
        }
        if (newN < oldN) return;              // 更空 → 不覆盖（防锁屏 data 冲掉主屏 data）
    }
    objc_setAssociatedObject(SBSHelper.class, @selector(sbs_gData), d,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView       *gStrip = nil;                       // 辅助图标条容器
static NSMutableDictionary<NSString *, UIImageView *> *gAuxViews = nil;
static NSMutableDictionary<NSString *, NSString *>   *gAuxKeys  = nil;  // ident→"xxxEntry"（预计算，refresh 零分配）
// ⭐ v1.4.2 系统原生图标捕获表：hook viewForIdentifier: 时记下系统自己渲染的
//   item 视图 image（CC 迷你状态栏/锁屏等场景系统会创建这些视图）。
//   许总要求"用系统自身的图标，参考 CC 状态栏那个"——捕获到的系统图 100% 同款，
//   且 CC 打开时捕获、CC 关闭后辅助条继续用（正是"CC 有、关 CC 也有"）。
static NSMutableDictionary<NSString *, UIImage *>    *gSysImages = nil;

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

// ⭐ v1.4.2 系统原生图标捕获（hook viewForIdentifier: 调进来）。
// 许总要求"用系统自身的图标（参考 CC 状态栏那个），不要自绘"——
// 系统在 CC 迷你状态栏/锁屏/各场景会为 alarm/rotationLock/bluetooth 等标识
// 创建原生 item 视图（UIImageView）。把返回视图的 image 存进 gSysImages，
// 辅助条优先用捕获图 → 图标与系统 100% 同款；CC 打开时捕获，关 CC 后继续用。
static void sbs_captureSysIcon(NSString *ident, UIView *v) {
    if (!ident.length) return;
    sbs_logIdentOnce(@"viewFor", ident);
    if (!v || !gAuxEnabled) return;
    UIImage *img = nil;
    if ([v isKindOfClass:[UIImageView class]]) {
        img = [(UIImageView *)v image];
    } else {
        for (UIView *s in v.subviews) {
            if ([s isKindOfClass:[UIImageView class]] && [(UIImageView *)s image]) {
                img = [(UIImageView *)s image]; break;
            }
        }
    }
    if (!img) return;
    if (!gSysImages) gSysImages = [NSMutableDictionary dictionary];
    NSString *key = ident.lowercaseString;
    if (gSysImages[key]) return;              // 首捕获为准（同 ident 不同状态样式可能不同）
    gSysImages[key] = img;
    sbs_log(@"[sysIcon] 捕获 %@ (%@ %@x%.0f)", key,
            NSStringFromClass(v.class), NSStringFromCGSize(img.size), img.scale);
    // 已建条 → 立即换上系统图（未建条时 sbs_auxEnsureCreated 会优先用捕获图）
    UIImageView *iv = gAuxViews ? gAuxViews[key] : nil;
    if (iv && iv.image != img) {
        iv.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
}

static UIImage *sbs_auxImage(NSString *ident) {
    // ⭐ v1.4.2 优先级 1：系统自己渲染的同款图（viewForIdentifier: 捕获）
    if (gSysImages) {
        UIImage *sys = gSysImages[ident.lowercaseString];
        if (sys) {
            sbs_logIdentOnce(@"icon", [NSString stringWithFormat:@"%@ ← 系统捕获图", ident]);
            return sys;
        }
    }
    // 优先级 2：Assets.car 原生字形；优先级 3：SF Symbol 兜底
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

// 建条：全局只建一次（不挂载——宿主 fg 或其父容器由布局按灵动岛位置决定）
static void sbs_auxEnsureCreated(void) {
    if (!gAuxEnabled || !gAuxIcons.count || gStrip) return;
    gStrip = [[UIView alloc] initWithFrame:CGRectZero];
    gStrip.userInteractionEnabled = NO;
    gStrip.backgroundColor = nil;
    gAuxViews = [NSMutableDictionary dictionary];
    gAuxKeys  = [NSMutableDictionary dictionary];
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
        gAuxKeys[ident.lowercaseString]  = [NSString stringWithFormat:@"%@Entry", ident];
        x += kAuxIconSize + kAuxGap;
    }
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

// ⭐ 灵动岛检测（v1.4.0，许总要求"读取灵动岛的位置和高度"）。
// 灵动岛不是 _UIStatusBarForegroundView 的子视图（dump 证实），是 SystemAperture
// 家族的独立视图。从 fg 向上爬 ≤4 层，在每层兄弟子树里按类名找（深度 ≤2）。
// ⭐⭐ v1.4.2 加水平居中硬校验：实测锁屏/解锁后扫到假岛（宽126高37 恰好匹配但
//    x=117.5 中心 180.5 ≠ 屏幕中心 215）→ 条整体偏左 35pt（许总反馈"位置偏移"）。
//    真岛永远水平居中于状态栏，宽度校验 + 居中校验双条件。
static CGRect sbs_findIslandRect(UIView *v, int depth, UIView *target, CGFloat fgW) {
    if (!v || depth < 0) return CGRectZero;
    NSString *cn = NSStringFromClass(v.class);
    if ([cn containsString:@"Aperture"] || [cn containsString:@"Island"] ||
        [cn containsString:@"Pill"]) {
        CGRect f = [v convertRect:v.bounds toView:target];
        CGFloat w = f.size.width, h = f.size.height;
        BOOL sizeOK  = (w >= 70 && w <= 240 && h >= 20 && h <= 70);
        BOOL centerOK = fgW > 0 && fabs((f.origin.x + w / 2.0) - fgW / 2.0) <= 20.0;
        // ⭐ 双保险：换算到窗口坐标系再验屏幕居中（防异宽 fg 坐标系内的"伪居中"）
        if (sizeOK && centerOK && v.window) {
            CGRect fInWin = [v convertRect:v.bounds toView:v.window];
            CGFloat scrW = v.window.bounds.size.width;
            if (scrW > 0 && fabs((fInWin.origin.x + fInWin.size.width / 2.0) - scrW / 2.0) > 25.0)
                centerOK = NO;                // 窗口坐标系下不居中 → 假岛
        }
        if (sizeOK && centerOK) return f;
    }
    for (UIView *s in v.subviews) {
        CGRect r = sbs_findIslandRect(s, depth - 1, target, fgW);
        if (!CGRectIsEmpty(r)) return r;
    }
    return CGRectZero;
}

static CGRect sbs_islandFrameInFG(UIView *fg) {
    // 缓存 2s（每帧递归扫视图树太贵）；⭐ v1.4.2 缓存绑定 fg 实例（不同 fg 坐标系不同）
    static CGRect cached;
    static NSTimeInterval at;
    static UIView *cachedFG = nil;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (!CGRectIsEmpty(cached) && now - at < 2.0 && cachedFG == fg) return cached;
    CGFloat fgW = fg.bounds.size.width;
    UIView *node = fg;
    CGRect found = CGRectZero;
    for (int up = 0; up < 4 && node.superview && CGRectIsEmpty(found); up++) {
        UIView *parent = node.superview;
        for (UIView *sib in parent.subviews) {
            if (sib == node || sib == gStrip) continue;
            found = sbs_findIslandRect(sib, 2, fg, fgW);
            if (!CGRectIsEmpty(found)) break;
        }
        node = parent;
    }
    if (CGRectIsEmpty(found)) {
        // 兜底：14 Pro Max 已知几何（居中 宽126 top11 高37 → 底缘48）
        found = CGRectMake((fgW - 126.0) / 2.0, 11.0, 126.0, 37.0);
    }
    cached = found; at = now; cachedFG = fg;
    sbs_logIdentOnce(@"island", NSStringFromCGRect(found));
    return found;
}

// Entry → 是否激活。
// 实测语义（v1.4.0 修正）：Entry **关闭时为 nil，开启时才非 nil** 的项：
//   rotationLock / quietMode（KVC enabled 键不适用）；
//   恒存在 + enabled 标志的项：alarm / vpn / location / bluetooth。
// 故：nil → 关；非 nil → 先试已知键，**都不匹配则视为开启**（存在即显示）。
static BOOL sbs_entryActive(id entry, NSString *ident) {
    if (!entry) return NO;
    if ([entry isKindOfClass:[NSNumber class]]) return [(NSNumber *)entry boolValue];
    for (NSString *k in (@[@"enabled", @"visible", @"isVisible", @"showing",
                           @"active", @"on", @"state"])) {
        @try {
            id v = [entry valueForKey:k];
            if ([v isKindOfClass:[NSNumber class]]) {
                sbs_logIdentOnce(@"entry", [NSString stringWithFormat:@"%@.%@=%@",
                    ident, k, v]);
                return [(NSNumber *)v boolValue];
            }
        } @catch (__unused NSException *e) {}
    }
    sbs_logIdentOnce(@"entry", [NSString stringWithFormat:@"%@ 无键匹配→按开启 (%@)",
        ident, NSStringFromClass([entry class])]);
    return YES;   // 非 nil 但没有布尔键 → 存在即激活
}

// 读 _UIStatusBarData 各 Entry → 驱动图标显隐
// ⭐ 被动式：只在 hidden 值真正变化时才写 iv.hidden（防止写操作触发重布局 → 循环）
static void sbs_auxRefresh(void) {
    if (!gAuxEnabled || !gAuxViews.count) return;
    id data = sbs_gData();
    if (!data) return;
    for (NSString *ident in gAuxViews) {
        UIImageView *iv = gAuxViews[ident];
        id entry = nil;
        @try { entry = [data valueForKey:gAuxKeys[ident]]; } @catch (__unused NSException *e) {}
        BOOL active = sbs_entryActive(entry, ident);
        if (iv.hidden == !active) continue;      // 无变化不写
        iv.hidden = !active;
    }
}

// 布局（v1.4.3 ⭐ 回正）：【灵动岛正下方居中】—— 许总澄清：辅助图标条就该在岛正下方；
//  电话助手左右两侧放的是时间/电池/信号这些主要元素（那些系统已原生渲染，不用我们做）。
// 辅助条横向屏幕居中、垂直 = 岛底缘 + 1.5pt，图标 9pt，颜色跟随时间文字。
// ⭐⭐ 全被动写：所有 frame/hidden/host 写入前先比对缓存，无变化不写。
//    血泪教训：拉控制中心时布局回调每帧狂调，任何"写即失效"都会造成
//    同步布局死循环 → autorelease 池不排空 → SB 内存 10 秒涨 4GB → Jetsam。
static void sbs_auxLayoutInFG(UIView *fg) {
    if (!gAuxEnabled || !gAuxStrip) { if (gStrip && !gStrip.hidden) gStrip.hidden = YES; return; }
    if (!sbs_fgIsLive(fg)) return;            // 非活动 fg 不托管不搬动
    // ⭐⭐ v1.4.2 关键修复：只托管【全屏宽度】的 fg。
    //    实测假岛根因：CC/Spotlight 窗口的迷你状态栏 fg 宽 361（≠屏宽 430），
    //    其内部有类名含 Pill 且尺寸恰好 126×37 的居中视图 → 岛检测误命中
    //    （对那个 fg 来说"居中"校验还真通过）→ 条偏移 35pt。
    //    主屏/锁屏 fg 宽度 = 屏幕宽度；窗口化的 fg 一律不托管。
    CGFloat scrW = fg.window ? fg.window.bounds.size.width : [UIScreen mainScreen].bounds.size.width;
    if (scrW > 0 && fabs(fg.bounds.size.width - scrW) > 1.0) return;
    // ⭐ 节流 33ms（CC 动画每帧都调 layoutSubviews，封顶 30fps 防止任何残余循环）
    static NSTimeInterval lastRun = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - lastRun < 0.033) return;
    lastRun = now;
    sbs_auxEnsureCreated();
    if (!gStrip) return;
    sbs_auxRefresh();
    // 颜色跟随时间文字（只在色值变化时写）
    UIColor *tint = nil;
    for (UIView *v in fg.subviews) {
        if ([NSStringFromClass(v.class) containsString:@"StringView"]) {
            UILabel *l = (UILabel *)v;
            if ([l respondsToSelector:@selector(textColor)]) { tint = l.textColor; break; }
        }
    }
    static UIColor *lastTint = nil;
    if (tint != lastTint) {
        for (UIImageView *iv in gAuxViews.allValues) iv.tintColor = tint ?: UIColor.whiteColor;
        lastTint = tint;
    }
    // 可见图标列表（保持 gAuxIcons 声明顺序）
    NSMutableArray<NSString *> *vis = [NSMutableArray array];
    for (NSString *ident in gAuxIcons) {
        UIImageView *iv = gAuxViews[ident.lowercaseString];
        if (iv && !iv.hidden) [vis addObject:ident.lowercaseString];
    }
    CGFloat fgW = fg.bounds.size.width;
    if (!vis.count || fgW <= 0) {
        if (gStrip.superview && !gStrip.hidden) gStrip.hidden = YES;
        return;
    }
    // —— 单条水平居中：总宽 = n*isz + (n-1)*gap，x = (fgW-w)/2 ——
    NSInteger n = vis.count;
    CGRect island = sbs_islandFrameInFG(fg);
    CGFloat gap = kAuxGap, isz = kAuxIconSize;
    CGFloat w = n * isz + (n - 1) * gap;
    // ⭐ 垂直 = 岛底缘 + 1.5pt；水平 = 屏幕居中
    CGFloat x = (fgW - w) / 2.0;
    CGFloat y = CGRectGetMaxY(island) + 1.5;
    // 每个图标的目标 frame（fg 坐标系）；先算好再统一被动写
    NSMutableDictionary<NSString *, NSValue *> *targets = [NSMutableDictionary dictionary];
    CGFloat cx = x;
    for (NSString *ident in vis) {
        targets[ident] = [NSValue valueWithCGRect:CGRectMake(cx, y, isz, isz)];
        cx += isz + gap;
    }
    // ⭐ 宿主恒定 = fg.superview（v1.4.1 二分定位：clipsToBounds 条件换宿主会在
    //    CC 动画中抖动 → 每帧 add/remove → 同步布局死循环 → 内存 4GB → Jetsam）。
    UIView *host = fg.superview ?: fg;
    // —— 被动写：宿主变化才搬家；条 frame = 所有目标的最小包围盒；图标逐个比对 ——
    if (gStrip.superview != host) {
        [gStrip removeFromSuperview];
        [host addSubview:gStrip];
    }
    CGRect unionR = CGRectZero;
    for (NSValue *v in targets.objectEnumerator) unionR = CGRectUnion(unionR, v.CGRectValue);
    CGRect hostF = [fg convertRect:unionR toView:host];
    if (!CGRectEqualToRect(gStrip.frame, hostF)) gStrip.frame = hostF;
    if (gStrip.hidden) gStrip.hidden = NO;
    for (NSString *ident in targets) {
        UIImageView *iv = gAuxViews[ident];
        CGRect t = [targets[ident] CGRectValue];
        CGRect want = CGRectMake(t.origin.x - unionR.origin.x,   // 相对条容器的本地坐标
                                 t.origin.y - unionR.origin.y, isz, isz);
        if (!CGRectEqualToRect(iv.frame, want)) iv.frame = want;
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
        // 二分开关 auxData=NO 时跳过（排查内存问题用）
        if (gAuxData) {
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
