// StatusBarScale.m —— 状态栏图标缩放对齐 v1.7.3
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
// ⭐ v1.7.0 新增：leading 区（时间右侧、灵动岛左侧）图标独立缩放
//   许总反馈原实现漏掉这批图标（它们无法按标识枚举）→ 改为运行时按
//   fg 坐标系 frame 区间发现（非 StringView + (时间右缘, 灵动岛左缘)），
//   单独缩放 0.6。命中清单直写 [lead] 日志供核对，详见 sbs_applyLead。
//
// 配置 /var/mobile/Library/Preferences/com.xu.statusbarscale.plist（改后需 respring）：
//   enabled(bool,默认YES)  scale(float,默认0.92)  dy(float,默认1.5)
//   threshold(float,默认312)  verbose(bool,默认NO)
//   leadEnabled(bool,默认YES)  leadScale(float,默认0.60)  leadDy(float,默认0)
//   diag(bool,默认YES) —— 关键事件直写（v1.7.1 起独立于 verbose，默认开）
//
// 日志：/var/mobile/Documents/sbs_log.txt
//   diag=YES：关键事件（[hook]/[lead]/[move]/[heal]/[scan]）直写落盘；
//   verbose=YES：额外输出高频诊断（[pass]/[deny]/层级 dump）
//
// ⚠️ v1.7.1 修复的回归：v1.5.0 曾把 sbs_logNow 也挂上 `if (!gVerbose) return;`，
//   导致设备 verbose=NO 时【完全无日志】—— 故障无法定位（"图标无法枚举"的元凶）。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define SBS_VERSION @"1.7.3"
#define SBS_LOG_PATH @"/var/mobile/Documents/sbs_log.txt"

static BOOL    gEnabled = YES;
static CGFloat gScale   = 0.92f;
static CGFloat gDy      = 1.5f;
static CGFloat gThr     = 312.0f;
static BOOL    gVerbose = NO;
// ⭐ v1.7.1 修复回归：v1.5.0 给 sbs_logNow 加了 `if (!gVerbose) return;`，
//   把"关键事件直写"通道整个关死 → verbose=NO（设备默认）时日志一个字节都不写，
//   直接导致"图标无法枚举/问题无法定位"。现拆分语义：
//     gDiag    = 关键事件直写（[hook]/[lead]/[move]/[heal]/[scan]，默认 YES）
//     gVerbose = 高频/批量诊断（[pass]/[deny]/dump 层，默认 NO）
static BOOL    gDiag    = YES;
static int     gDidDump = 0;
// 辅助图标（系统原生 item 强制启用，参照电话助手排列）
// v1.5.1：辅助条是核心功能。仅在 SpringBoard 内运行，同时覆盖主屏
// UIStatusBarWindow 与 App 前台 SBMainSwitcherWindow；绝不注入普通 App/WebKit。
static BOOL         gAuxEnabled = YES;
static NSArray<NSString *> *gAuxIcons = nil;   // 标识集合（小写）
static BOOL         gAuxStrip = YES;              // 二分开关：条+岛扫描
static BOOL         gAuxData  = YES;              // 二分开关：applyUpdate 数据钩子
// 辅助条外观：灵动岛下方居中，小尺寸不碍眼
static const CGFloat kAuxIconSize = 9.0;        // 图标边长（points）
static const CGFloat kAuxGap      = 4.0;        // 图标间距

// 受管图标视图的弱引用集合：系统/动画改动它们的 transform 时会被 setTransform: hook 拦截
static NSHashTable *gManaged = nil;   // weak objects
// ── v1.7.0 ⭐ leading 区（时间右侧、灵动岛左侧）图标缩放 ──
// 许总反馈：原实现只缩放了灵动岛【右侧】（minX >= threshold）的图标，
// 漏掉了【时间右侧、灵动岛左侧】的那批图标（闹钟/定位/录屏/麦克风等），
// 这批图标无法按标识枚举，必须靠运行时按 frame 区间发现。
static BOOL         gLeadEnabled = YES;   // leading 区缩放总开关
static CGFloat      gLeadScale   = 0.60f; // 许总指定：单独缩小为 0.6 倍
static CGFloat      gLeadDy      = 0.0f;  // 额外下移量（待实机确认，默认不位移）
static NSHashTable *gManagedLead = nil;   // leading 受管视图（与 gManaged 分开，变换值不同）

static CGAffineTransform sbs_targetTransform(void) {
    return CGAffineTransformTranslate(
        CGAffineTransformMakeScale(gScale, gScale), 0, gDy / gScale);
}

// leading 图标的目标变换：绕中心缩放 gLeadScale（+ 可选下移 gLeadDy pt）
// 注：Translate(Scale(s,s),0,dys) 的屏幕位移 = s*dys → dys = dy/s（同 sbs_targetTransform）
static CGAffineTransform sbs_leadTransform(void) {
    CGFloat s = (gLeadScale > 0.05f && gLeadScale < 1.0f) ? gLeadScale : 0.60f;
    return CGAffineTransformTranslate(CGAffineTransformMakeScale(s, s), 0, gLeadDy / s);
}

static void sbs_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void sbs_logNow(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);   // v1.4.6 前向声明
static void sbs_log(NSString *fmt, ...) {
    // 正常运行不做任何文件 I/O。旧版即使 verbose=NO 仍会让所有 UIKit 宿主
    // 读写 /var/mobile/Documents/sbs_log.txt，造成持续 Sandbox deny 和日志风暴。
    if (!gVerbose) return;
    static NSDateFormatter *df = nil;
    static dispatch_once_t dfOnce;
    dispatch_once(&dfOnce, ^{
        df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
    });
    // ⭐ 限流（v1.4.0 血泪教训：探针每秒几千次写日志 → 日志 150MB +
    //    SpringBoard 内存 5.5GB → Jetsam 循环杀进程 = 许总看到的"下拉就 respring"）
    static NSTimeInterval windowStart = 0, lastWrite = 0;
    static int dropped = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (windowStart == 0) windowStart = now;
    if (now - windowStart >= 5.0) {
        if (dropped > 0) {
            // ⭐ v1.4.6 改 append 写：atomically=YES 是整文件覆盖 —— SB 与 App 多进程
            //    共写同一日志文件时互删对方全部行（19:34 Preferences 日志蒸发实锤）
            NSString *s = [NSString stringWithFormat:@"%@ [%@/%d] [限流] 5s 丢弃 %d 条日志\n",
                           [df stringFromDate:[NSDate date]],
                           [[NSProcessInfo processInfo] processName], getpid(), dropped];
            NSFileHandle *fh0 = [NSFileHandle fileHandleForWritingAtPath:SBS_LOG_PATH];
            if (!fh0) {
                [s writeToFile:SBS_LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
            } else {
                [fh0 seekToEndOfFile];
                [fh0 writeData:[s dataUsingEncoding:NSUTF8StringEncoding]];
                [fh0 closeFile];
            }
        }
        windowStart = now; dropped = 0;
    }
    if (now - lastWrite < 0.05) { dropped++; return; }   // ≤20 行/秒
    lastWrite = now;
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
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

// ⭐ v1.4.6 关键事件直写（不限流）：[move]/[heal]/[unhide]/[dmsup] 是定位"条消失"
//   的决定性证据，而 App 启动时的 dump 风暴会把这些行挤进限流丢弃桶。
//   这四类事件本身低频（每次 App 切换至多十几条），直写安全。
static void sbs_logNow(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void sbs_logNow(NSString *fmt, ...) {
    if (!gDiag) return;   // ⭐ v1.7.1：改用独立诊断开关（原为 gVerbose，把直写通道关死了）
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
        // ⭐ v1.7.0 leading 区（时间右侧、灵动岛左侧）图标
        if ((n = d[@"leadEnabled"]) && [n isKindOfClass:[NSNumber class]]) gLeadEnabled = n.boolValue;
        if ((n = d[@"leadScale"])   && [n isKindOfClass:[NSNumber class]]) gLeadScale   = n.floatValue;
        if ((n = d[@"leadDy"])      && [n isKindOfClass:[NSNumber class]]) gLeadDy      = n.floatValue;
        // ⭐ v1.7.1 诊断直写开关（默认 YES：关键事件始终落盘，便于定位）
        if ((n = d[@"diag"])        && [n isKindOfClass:[NSNumber class]]) gDiag        = n.boolValue;
    }
    if (gScale < 0.3f || gScale > 2.0f) gScale = 0.92f;   // 防呆
    if (gLeadScale < 0.2f || gLeadScale > 1.0f) gLeadScale = 0.60f;   // 防呆
    // 辅助图标配置：默认 = 系统状态栏【没有】原生显示的项。
    // ⚠️ location 不放默认集：系统已在时间旁渲染原生定位箭头，重复显示（许总反馈）。
    if (!gAuxIcons) gAuxIcons = @[@"alarm", @"quietMode", @"rotationLock",
                                  @"vpn", @"bluetooth", @"airplane"];
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
static void sbs_auxRelayoutFromData(void);    // ⭐ v1.4.4 data 驱动重排（定义见后）
static void sbs_applyLead(UIView *fg);        // ⭐ v1.7.0 leading 区图标缩放（定义见后）
static CGRect sbs_islandFrameInFG(UIView *fg); // ⭐ v1.7.0 leading 判定要用（定义见后）
// ⭐ v1.4.4/5 全局状态（必须定义在 SBSHelper @implementation 之前，
//   hook 方法 sbs_fgDidMoveToWindow 内要用 gAuxForceRelayout）
static UIView *gActiveFG = nil;                          // 当前活动 fg（强引用，CC 动画期间不失效）
static BOOL gAuxForceRelayout = NO;                      // data/自愈驱动时跳过节流
static dispatch_source_t gHealTimer = nil;               // v1.4.5 定时自愈
static CFRunLoopTimerRef gAuxBootstrapTimer = NULL;       // 等待 UIScreen 真正就绪
static BOOL gAuxInstallBegan = NO;                       // 生命周期回调串行一次性门闩
// ⭐ v1.4.6 见过的合法 fg 表（弱引用）：快速切换后 gActiveFG 可能是已进池的
//   App fg（fgLegal=NO → 自愈失效），从表里找回仍在 UIStatusBarWindow 的 fg
static NSHashTable *gSeenFGs = nil;
static NSHashTable *sbs_seenFGs(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gSeenFGs = [NSHashTable weakObjectsHashTable]; });
    return gSeenFGs;
}

static void sbs_apply(UIView *fg) {
    // ⭐ v1.4.6 上游探针：确认 fg layoutSubviews hook 真的触发（App 内诊断）
    if (gVerbose) {
        static NSTimeInterval lastApply = 0;
        NSTimeInterval nowA = [NSDate date].timeIntervalSince1970;
        if (nowA - lastApply > 0.3) {
            lastApply = nowA;
            sbs_logNow(@"[apply] fg=%p win=%@ sub=%lu",
                    fg, fg.window ? NSStringFromClass(fg.window.class) : @"nil",
                    (unsigned long)fg.subviews.count);
        }
    }
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
    // ⭐ v1.7.0 leading 区（时间右侧、灵动岛左侧）图标独立缩放 0.6 —— 与右侧互斥
    @try { sbs_applyLead(fg); } @catch (NSException *e) { sbs_logNow(@"[exc-lead] %@", e); }
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
static void sbs_installAux(void);
static void sbs_startAuxIfNeeded(void);
static void sbs_registerAuxBootstrapObservers(void);
static void sbs_auxBootstrapTimerFired(CFRunLoopTimerRef timer, void *info);
static void sbs_auxLifecycleTrigger(NSString *source);

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
- (BOOL)sbs_backlightScreenIsOn {
    BOOL on = [self sbs_backlightScreenIsOn];
    @try { sbs_auxLifecycleTrigger(@"SBBacklightController screenIsOn"); }
    @catch (NSException *e) {
        NSLog(@"[StatusBarScale] backlight readiness trigger failed: %@", e);
    }
    return on;
}

- (void)sbs_applicationDidFinishLaunching:(id)arg {
    [self sbs_applicationDidFinishLaunching:arg];
    @try { sbs_auxLifecycleTrigger(@"SpringBoard2 applicationDidFinishLaunching:"); }
    @catch (NSException *e) {
        NSLog(@"[StatusBarScale] launch readiness trigger failed: %@", e);
    }
}

- (void)sbs_statusBarDidFinishPost {
    [self sbs_statusBarDidFinishPost];
    @try { sbs_auxLifecycleTrigger(@"SBStatusBarStateProvider _didFinishPost"); }
    @catch (NSException *e) {
        NSLog(@"[StatusBarScale] status post readiness trigger failed: %@", e);
    }
}

// SpringBoard 的实际状态栏实例由子类覆写布局/搬移方法，基类 hook
// 在 1.6.3 实时日志中未触发。UIApplication sendEvent: 是用户交互的稳定
// 就绪点；先调原实现，再用 UIScreen 实际数据决定是否安装辅助模块。
- (void)sbs_applicationSendEvent:(UIEvent *)event {
    [self sbs_applicationSendEvent:event];
    @try { sbs_auxLifecycleTrigger(@"UIApplication sendEvent:"); }
    @catch (NSException *e) {
        NSLog(@"[StatusBarScale] sendEvent readiness trigger failed: %@", e);
    }
}

// 交换后：此选择子挂在目标类上指向【原实现】；先调原布局，再做缩放
- (void)sbs_fgLayoutSubviews {
    [self sbs_fgLayoutSubviews];          // 原实现
    @try {
        // ctor 期间 dispatch_after 在 SpringBoard 冷启动中存在不执行的时序。
        // 首次真实状态栏布局说明 UIKit 已就绪，此时安装辅助模块最稳定。
        sbs_auxLifecycleTrigger(@"layoutSubviews");
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
    if (!gEnabled) return;
    if (!gManaged && !gManagedLead) return;
    @try {
        UIView *v = (UIView *)self;
        CGAffineTransform want;
        // ⭐ v1.7.0 leading 图标（0.6）与右侧图标（0.92）分属不同受管表
        if (gManaged && [gManaged containsObject:v])           want = sbs_targetTransform();
        else if (gManagedLead && [gManagedLead containsObject:v]) want = sbs_leadTransform();
        else return;
        if (!CGAffineTransformEqualToTransform(t, want)) {
            v.transform = want;       // 重新走 setTransform（值已等于 want，不会死循环）
        }
    } @catch (NSException *e) {
        sbs_log(@"[exc] %@", e);
    }
}

// 状态栏 foreground view 被重新挂到 window（App↔主屏切换/锁屏解锁）时补多次。
- (void)sbs_fgDidMoveToWindow {
    [self sbs_fgDidMoveToWindow];         // 原实现
    @try {
        sbs_auxLifecycleTrigger(@"didMoveToWindow");
        if (gVerbose) sbs_log(@"[didMove] self=%@ win=%@",
            NSStringFromClass(((UIView *)self).class),
            ((UIView *)self).window ? @"有" : @"nil");
        // 挂载后的布局尚未发生时，子视图可能还没建好 → 下一 runloop 补施
        dispatch_async(dispatch_get_main_queue(), ^{
            sbs_apply((UIView *)self);
        });
        // ⭐ v1.4.5 多档补触发（同 data 驱动的重试节奏）：退出 App 回主屏时
        //    主屏 fg 可能不触发 layoutSubviews（实测 home 后零布局），
        //    0.3s 单次触发不够 —— 多档重试覆盖切换动画全周期。
        for (int i = 0; i < 4; i++) {
            NSTimeInterval delay = (i == 0 ? 0.0 : (i == 1 ? 0.3 : (i == 2 ? 0.8 : 1.5)));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    gAuxForceRelayout = YES;
                    sbs_auxLayoutInFG((UIView *)self);
                } @catch (NSException *e) { sbs_log(@"[exc-auxDM] %@", e); }
            });
        }
    } @catch (NSException *e) {
        sbs_log(@"[exc] %@", e);
    }
}

// ⭐ v1.4.6 快速切换补漏（三）：fg 的 didMoveToSuperview。
//    快速开关 App 时系统在 UIStatusBarWindow 与备用池间搬 fg，但快速序列下
//    window 可能不变（同窗复用）→ didMoveToWindow 不触发、layoutSubviews 不触发
//    → 主屏 fg 上场后没人把条搬回（自愈 1s 也嫌慢）。superview 变化是fg 进出场
//    必然事件，比 window 更灵敏。
- (void)sbs_fgDidMoveToSuperview {
    [self sbs_fgDidMoveToSuperview];      // 原实现
    @try {
        sbs_auxLifecycleTrigger(@"didMoveToSuperview");
        if (gVerbose) sbs_logNow(@"[dmsup] fg=%p super=%@",
            self, ((UIView *)self).superview ?
            NSStringFromClass(((UIView *)self).superview.class) : @"nil");
        for (int i = 0; i < 4; i++) {
            NSTimeInterval delay = (i == 0 ? 0.0 : (i == 1 ? 0.3 : (i == 2 ? 0.8 : 1.5)));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    gAuxForceRelayout = YES;
                    sbs_auxLayoutInFG((UIView *)self);
                } @catch (NSException *e) { sbs_log(@"[exc-auxDS] %@", e); }
            });
        }
    } @catch (NSException *e) {
        sbs_log(@"[exc] %@", e);
    }
}

// ⭐ v1.4.6 快速切换补漏（四）：fg 的 setHidden:。
//    单实例复用路径：fg 上场 = hidden YES→NO（window/superview 都不变），
//    此时 layoutSubviews/didMove* 都可能不触发。只在变可见时排定重试
//    （YES→NO 不处理，避免 CC/锁屏过渡的高频隐藏写放大）。
- (void)sbs_fgSetHidden:(BOOL)h {
    BOOL wasHidden = ((UIView *)self).hidden;
    [self sbs_fgSetHidden:h];             // 原实现
    @try {
        sbs_auxLifecycleTrigger(@"setHidden:");
        if (wasHidden && !h) {            // YES→NO = 上场
            if (gVerbose) sbs_logNow(@"[unhide] fg=%p", self);
            for (int i = 0; i < 4; i++) {
                NSTimeInterval delay = (i == 0 ? 0.0 : (i == 1 ? 0.3 : (i == 2 ? 0.8 : 1.5)));
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try {
                        gAuxForceRelayout = YES;
                        sbs_auxLayoutInFG((UIView *)self);
                    } @catch (NSException *e) { sbs_log(@"[exc-auxUH] %@", e); }
                });
            }
        }
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
        sbs_auxRelayoutFromData();        // ⭐ v1.4.4 CC 开合后条立即恢复
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
        sbs_auxRelayoutFromData();        // ⭐ v1.4.4 CC 开合后条立即恢复
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
    // class_getInstanceMethod 可能触发任意类 +initialize。1.6.0 真机日志证实
    // 这会在 SpringBoard 启动期触发 mainScreen=nil，随后被 watchdog 终止。
    // class_copyMethodList 只读类自身的元数据，既不走继承也不触发初始化。
    int num = objc_getClassList(NULL, 0);
    if (num <= 0) return nil;
    Class *classes = (Class *)malloc(sizeof(Class) * num);
    num = objc_getClassList(classes, num);
    Class found = nil;
    for (int i = 0; i < num; i++) {
        Class c = classes[i];
        if (!c) continue;
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        for (unsigned int j = 0; j < count; j++) {
            Method m = methods[j];
            const char *enc = method_getTypeEncoding(m);
            if (method_getName(m) == sel && enc && strcmp(enc, wantEnc) == 0) {
                found = c;
                break;
            }
        }
        free(methods);
        if (found) break;
    }
    free(classes);
    return found;
}

// 只基于 class_copyMethodList 的元数据找出真正覆写 selector 的类。
// base!=Nil 时仅限 base 子类；base==Nil 时仅限 SB* 类。
static NSUInteger sbs_hookDefiningClasses(Class base, SEL original, SEL replacement,
                                           const char *encoding, NSString *tag) {
    int num = objc_getClassList(NULL, 0);
    if (num <= 0) return 0;
    Class *classes = (Class *)malloc(sizeof(Class) * num);
    num = objc_getClassList(classes, num);
    NSUInteger hooked = 0;
    for (int i = 0; i < num; i++) {
        Class c = classes[i];
        if (!c || c == base) continue;
        if (base) {
            BOOL isSubclass = NO;
            for (Class p = class_getSuperclass(c); p; p = class_getSuperclass(p)) {
                if (p == base) { isSubclass = YES; break; }
            }
            if (!isSubclass) continue;
        } else {
            const char *cn = class_getName(c);
            if (!cn || strncmp(cn, "SB", 2) != 0) continue;
        }
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        BOOL defines = NO;
        for (unsigned int j = 0; j < count; j++) {
            Method m = methods[j];
            const char *enc = method_getTypeEncoding(m);
            if (method_getName(m) == original && enc && strcmp(enc, encoding) == 0) {
                defines = YES;
                break;
            }
        }
        free(methods);
        if (!defines) continue;
        BOOL ok = SBSHook(c, original, SBSHelper.class, replacement);
        NSLog(@"[StatusBarScale] %@ definer=%s hook=%d", tag, class_getName(c), ok);
        if (ok) hooked++;
    }
    free(classes);
    return hooked;
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
                               @"rotationLockEntry", @"vpnEntry", @"bluetoothEntry",
                               @"airplaneModeEntry"])) {
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

// ⭐ v1.4.4 data 驱动重排：CC 开合/状态变化时，主屏 fg 的 layoutSubviews 可能
//   不再触发（布局没变），导致辅助条 hidden 后迟迟不回来（许总："收回 CC 后
//   辅助条消失，要等好几秒"）。根因实测：CC 关闭过渡动画期间主屏 fg 宽度在
//   430/370 间抖动且 StringView 暂被移除（fgIsLive=NO），动画结束后系统不再
//   触发布局 → 条没人放回。修：data 变化后【多档延迟重试】重排，直到条恢复。
static void sbs_auxRelayoutFromData(void) {
    static NSTimeInterval last = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - last < 0.08) return;      // 去抖 80ms
    last = now;
    // 多档重试：立即 / 0.3s / 0.8s / 1.5s（覆盖 CC 过渡动画 0.5~1s 全周期）
    for (int i = 0; i < 4; i++) {
        NSTimeInterval delay = (i == 0 ? 0.0 : (i == 1 ? 0.3 : (i == 2 ? 0.8 : 1.5)));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *fg = gActiveFG;
            if (!fg) return;
            gAuxForceRelayout = YES;    // 跳过节流
            @try { sbs_auxLayoutInFG(fg); }
            @catch (NSException *e) { sbs_log(@"[exc-auxRD] %@", e); }
        });
    }
}

// ⭐ v1.4.5 定时自愈：兜底所有未知的条丢失场景（App↔主屏切换 fg 不布局、
//   didMove 没触发、任何系统行为导致的条不可见）。每 2s 一次纯状态比较
//   （不 dump 不写布局），极轻；仅在条确实丢失/挂错窗口时才强制重排。
static void sbs_auxSelfHealStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gHealTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_main_queue());
        // ⭐ v1.4.6 间隔 2s→1s：快速 App 切换场景下 2s 兜底太慢（许总实测
        //    "多次快速开关 App 后条要等几秒"），1s 纯状态比较开销可忽略
        dispatch_source_set_timer(gHealTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                                  1 * NSEC_PER_SEC, (int64_t)(0.25 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(gHealTimer, ^{
            @try {
                if (!gAuxEnabled || !gAuxStrip || !gStrip || !gActiveFG) return;
                UIView *fg = gActiveFG;
                // ⭐ v1.4.5 修正判据：条必须挂在 UIStatusBarWindow（常驻状态栏总窗口）。
                //   不能用 gStrip.window != fg.window —— CC 打开时 fg 自身会被"借"进
                //   CC 窗口，旧判据在 CC 期间恒为"没丢"，CC 收起时条跟着宿主销毁。
                NSString *swCls = gStrip.window ? NSStringFromClass(gStrip.window.class) : @"";
                NSString *fwCls = fg.window ? NSStringFromClass(fg.window.class) : @"";
                BOOL noSuper = !gStrip.superview;
                BOOL inBadWin = [swCls containsString:@"ControlCenter"] ||
                                [swCls containsString:@"ReusePool"] ||
                                (![swCls containsString:@"UIStatusBarWindow"] &&
                                 gStrip.superview);
                BOOL stripLost = noSuper || gStrip.hidden || inBadWin;
                // 只在 fg 自己在合法窗口时才重排（fg 被借进 CC 时重排会被门禁拒绝）
                BOOL fgLegal = [fwCls containsString:@"UIStatusBarWindow"] &&
                               !fg.window.isHidden && !fg.isHidden;
                // ⭐ v1.4.6 治本：gActiveFG 陈旧（快速切换后已在池窗口）时，
                //   从见过表里找回仍在 UIStatusBarWindow 的可见 fg 作为重排目标
                if (!fgLegal) {
                    for (UIView *c in sbs_seenFGs()) {
                        if (!c.window || c.isHidden) continue;
                        NSString *cw = NSStringFromClass(c.window.class);
                        if ([cw containsString:@"UIStatusBarWindow"]) {
                            fg = c;
                            gActiveFG = c;
                            fwCls = cw;
                            fgLegal = YES;
                            if (gVerbose)
                                sbs_logNow(@"[heal] gActiveFG 陈旧，从见过表找回 fg=%p", c);
                            break;
                        }
                    }
                }
                if (stripLost && fgLegal) {
                    if (gVerbose) {
                        static NSTimeInterval lastHeal = 0;
                        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
                        if (now - lastHeal > 0.5) {
                            lastHeal = now;
                            sbs_logNow(@"[heal] 触发 noSuper=%d inBadWin=%d(%@) stripHidden=%d fgWin=%@",
                                    noSuper, inBadWin, swCls, gStrip.hidden, fwCls);
                        }
                    }
                    gAuxForceRelayout = YES;         // 强制跳过节流
                    sbs_auxLayoutInFG(fg);
                }
            } @catch (__unused NSException *e) {}
        });
        dispatch_resume(gHealTimer);
        sbs_log(@"[aux] 自愈计时器已启动（2s 间隔）");
    });
}
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
        // 系统数据键大多为 <identifier>Entry；飞行模式是 airplaneModeEntry。
        NSString *entryKey = [ident caseInsensitiveCompare:@"airplane"] == NSOrderedSame
            ? @"airplaneModeEntry" : [NSString stringWithFormat:@"%@Entry", ident];
        gAuxKeys[ident.lowercaseString] = entryKey;
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

// ═══════════════════════════════════════════════════════════════════════════
// ⭐ v1.7.0 leading 区（时间右侧、灵动岛左侧）图标缩放 + 运行时发现探针
//
// 许总反馈：原实现只缩放 minX >= threshold(312，灵动岛右侧) 的图标，
// 【时间右侧、灵动岛左侧】的那批图标被整体漏掉，且它们无法按标识枚举。
// 本模块改为按【fg 坐标系下的 frame 区间】发现它们，并把每次命中直写日志，
// 使"命中清单"可被许总实机核对（不允许凭猜测定类名）。
//
// 区间定义（统一换算到 fg 坐标系，points）：
//   timeMaxX  = 时间视图右缘（所有可见 StringView 的最大 maxX；无时间则 0）
//   leadLimit = 灵动岛左缘（sbs_islandFrameInFG().origin.x，兜底 152）
//   候选 = 非 StringView + 非 Background + class 含 StatusBar/Battery
//          + 宽高 >= 3pt 且宽 < 200pt（排除全宽容器/legibility 背景）
//          + timeMaxX < maxX 区间落在 (timeMaxX, leadLimit)
// ═══════════════════════════════════════════════════════════════════════════

static NSMutableSet *sbs_leadSeen(void) {
    static NSMutableSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}

// 去重直写一条提示（同 key 只写一次）—— 用于记录"为何跳过"，使许总能核对判定。
static void sbs_leadNote(NSString *key, NSString *msg) {
    NSMutableSet *seen = sbs_leadSeen();
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    sbs_logNow(@"[lead] %@", msg);
}

// 时间视图右缘（leading 参照起点）；取所有可见 StringView 的最大右缘
static CGFloat sbs_timeMaxX(UIView *fg) {
    CGFloat mx = 0;
    for (UIView *v in fg.subviews) {
        NSString *cn = NSStringFromClass(v.class);
        if ([cn containsString:@"StringView"] && !v.hidden)
            mx = MAX(mx, CGRectGetMaxX([v convertRect:v.bounds toView:fg]));
    }
    return mx;
}

// 候选判定（坐标一律换算到 fg 坐标系，避免深层嵌套时用到父容器坐标）
static BOOL sbs_isLeadCandidate(UIView *v, UIView *fg, CGFloat timeMaxX, CGFloat leadLimit) {
    NSString *cn = NSStringFromClass(v.class);
    if ([cn containsString:@"StringView"])  return NO;   // 时间是参照物，本身不缩
    if ([cn containsString:@"Background"])  return NO;
    BOOL isItem = [cn containsString:@"StatusBar"] || [cn containsString:@"Battery"];
    if (!isItem) return NO;
    CGRect f = [v convertRect:v.bounds toView:fg];
    if (f.size.width < 3.0 || f.size.height < 3.0) return NO;
    if (f.size.width >= 200.0) return NO;                // 全宽容器/背景
    CGFloat minX = CGRectGetMinX(f);
    return (minX > timeMaxX + 0.5) && (CGRectGetMaxX(f) <= leadLimit + 0.5);
}

// 递归收集候选（灵动岛机型 leading item 可能嵌在容器里而非 fg 直接子视图；深度上限 3）
static void sbs_collectLead(UIView *v, UIView *fg, int depth,
                            CGFloat timeMaxX, CGFloat leadLimit,
                            NSMutableArray<UIView *> *out) {
    if (!v || depth > 3) return;
    if (sbs_isLeadCandidate(v, fg, timeMaxX, leadLimit)) [out addObject:v];
    for (UIView *s in v.subviews)
        sbs_collectLead(s, fg, depth + 1, timeMaxX, leadLimit, out);
}

// 发现探针：把"边界参数 + 每个候选的真实类名/帧/父类"直写日志。
// ⚠️ 双重防护（v1.3.0 Jetsam 事故：每帧写日志 → 150MB → 内存爆 → 重启循环）：
//    ① 去重键 = 类名 + 帧坐标量化到 4pt 网格（防动画期逐帧抖动产生无限新键）；
//    ② 每 0.3s 最多直写 1 条。
static void sbs_leadReport(UIView *fg, NSArray<UIView *> *cands,
                           CGFloat timeMaxX, CGFloat leadLimit) {
    NSMutableSet *seen = sbs_leadSeen();
    static NSTimeInterval lastWrite = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    BOOL canWrite = (now - lastWrite >= 0.3);

    NSMutableDictionary<NSString *, NSString *> *uniq = [NSMutableDictionary dictionary];
    uniq[[NSString stringWithFormat:@"b|%.1f|%.1f|%.1f",
          timeMaxX, leadLimit, fg.bounds.size.width]] =
        [NSString stringWithFormat:@"边界 timeMaxX=%.1f leadLimit=%.1f fgW=%.1f",
         timeMaxX, leadLimit, fg.bounds.size.width];
    for (UIView *v in cands) {
        CGRect f = [v convertRect:v.bounds toView:fg];
        NSString *key = [NSString stringWithFormat:@"i|%@|%.0f|%.0f|%.0f|%.0f",
                         NSStringFromClass(v.class),
                         round(f.origin.x / 4.0) * 4.0, round(f.origin.y / 4.0) * 4.0,
                         round(f.size.width / 4.0) * 4.0, round(f.size.height / 4.0) * 4.0];
        uniq[key] = [NSString stringWithFormat:
            @"%@ x=%.1f y=%.1f w=%.1f h=%.1f hidden=%d alpha=%.2f super=%s",
            NSStringFromClass(v.class), f.origin.x, f.origin.y, f.size.width, f.size.height,
            v.hidden, v.alpha, v.superview ? class_getName(v.superview.class) : "nil"];
    }
    for (NSString *key in uniq) {
        if ([seen containsObject:key]) continue;
        if (!canWrite) break;                 // 本轮配额用完，剩余留到下帧继续报
        [seen addObject:key];
        sbs_logNow(@"[lead] %@", uniq[key]);
        lastWrite = [NSDate date].timeIntervalSince1970;
        canWrite = NO;
    }
}

// leading 区主流程：发现 → 上报 → 施加 0.6 变换
static void sbs_applyLead(UIView *fg) {
    if (!gLeadEnabled || !fg || fg.subviews.count == 0) return;
    // 一次性直写：确证 leading 模块真的执行（避免"无日志当成功"）
    static BOOL announced = NO;
    if (!announced) {
        announced = YES;
        sbs_logNow(@"[lead] 模块生效 v%@ leadEnabled=%d leadScale=%.2f leadDy=%.2f proc=%@",
                   SBS_VERSION, gLeadEnabled, gLeadScale, gLeadDy,
                   [[NSProcessInfo processInfo] processName]);
    }
    // ⭐⭐ v1.7.3 三道门禁 —— 由 2026-10-05 实机日志实证的必要修复：
    //   ① 只处理【全屏宽度】fg：CC/Spotlight 的迷你状态栏 fg 宽 361/370，
    //      其左侧信号/WiFi（日志实测 _UIStatusBarCellularSignalView x=6.0、
    //      _UIStatusBarWifiSignalView x=110.1）会被误判为"时间右侧图标"缩到 0.6。
    //   ② 无时间基准（timeMaxX=0，日志实测出现）时不缩：否则区间退化成 (0, leadLimit)，
    //      整条左半屏的 item 全部命中。
    //   ③ 灵动岛左缘必须落在合理区间（真岛实测 152）。
    CGFloat scrW = UIScreen.mainScreen.bounds.size.width;
    if (scrW > 0 && fabs(fg.bounds.size.width - scrW) > 1.0) {
        sbs_leadNote(@"skipFg", [NSString stringWithFormat:
            @"跳过：非全屏 fg（宽 %.0f ≠ 屏宽 %.0f）—— CC/Spotlight 迷你状态栏",
            fg.bounds.size.width, scrW]);
        return;
    }
    CGFloat timeMaxX = sbs_timeMaxX(fg);
    if (timeMaxX <= 0.5) {
        sbs_leadNote(@"skipTime", @"跳过：无可视时间视图（timeMaxX=0），无判定基准");
        return;
    }
    CGRect island = sbs_islandFrameInFG(fg);
    CGFloat leadLimit = CGRectIsEmpty(island) ? 152.0 : island.origin.x;
    if (leadLimit < 60.0 || leadLimit > 200.0) {
        sbs_leadNote(@"skipIsland", [NSString stringWithFormat:
            @"跳过：灵动岛左缘异常（%.1f 不在 60~200）", leadLimit]);
        return;
    }

    NSMutableArray<UIView *> *cands = [NSMutableArray array];
    for (UIView *s in fg.subviews)
        sbs_collectLead(s, fg, 0, timeMaxX, leadLimit, cands);

    sbs_leadReport(fg, cands, timeMaxX, leadLimit);     // 探针（去重 + 节流，安全）

    if (cands.count == 0) return;
    if (!gManagedLead) gManagedLead = [NSHashTable weakObjectsHashTable];
    CGAffineTransform lt = sbs_leadTransform();
    for (UIView *v in cands) {
        BOOL isNew = ![gManagedLead containsObject:v];
        [gManagedLead addObject:v];
        CGAffineTransform before = v.transform;
        if (!CGAffineTransformEqualToTransform(before, lt)) v.transform = lt;
        // ⭐ v1.7.2 施加确证：打印【同一个可观测值】transform.a 的前后变化
        //   （a=缩放系数）。只对新登记的视图写一次，避免刷屏。
        if (isNew) {
            sbs_logNow(@"[leadApply] %s 缩放前 a=%.3f → 后 a=%.3f（期望 %.3f）",
                       class_getName(v.class), before.a, v.transform.a, lt.a);
        }
    }
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
// ⭐ v1.4.6 进程判定：SpringBoard 与普通 App 的状态栏窗口架构完全不同
static BOOL sbs_isSpringBoard(void) {
    static BOOL v = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        v = [[[NSProcessInfo processInfo] processName]
             isEqualToString:@"SpringBoard"];
    });
    return v;
}

// ⭐ v1.4.6 锁屏判定（许总要求锁屏不显示条）：用系统锁屏状态 API。
//    【实测教训】StringView.y 判据不可用 —— 19:28 dump 实锤主屏 fg 的
//    StringView.y=18.67 与锁屏完全相同（fg 内部坐标系非屏幕坐标）。
//    SBLockScreenManager.uiIsLocked 是 iOS 老牌锁屏状态（16.5.1 实测存在）。
#import <objc/message.h>
static BOOL sbs_sbLocked(void) {
    if (!sbs_isSpringBoard()) return NO;
    Class m = objc_getClass("SBLockScreenManager");
    if (!m) return NO;
    id inst = ((id (*)(id, SEL))objc_msgSend)((id)m, @selector(sharedInstance));
    if (!inst) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(inst, @selector(uiIsLocked));
    } @catch (__unused NSException *e) { return NO; }
}

static void sbs_auxLayoutInFG(UIView *fg) {
    if (!gAuxEnabled || !gAuxStrip) { if (gStrip && !gStrip.hidden) gStrip.hidden = YES; return; }
    // ⭐⭐ v1.4.6 门禁按进程分流（第一优先）：
    //    【实测架构（19:40 铁证）】SBMainSwitcherWindow 不是敌人而是【App 前台的正宿主】——
    //    iOS App 内状态栏由 SB 经 MainSwitcher 窗口远程渲染（App 进程 windows=1 且无 fg
    //    实例，App 内状态栏根本不在 App 进程）。v1.4.2–1.4.5 黑名单不拒它 → App 内条
    //    正常；白名单一刀切把它拒了 → App 内条消失（许总 19:28 反馈）。
    //    ∴ SB 内放行 UIStatusBarWindow（主屏/锁屏）+ MainSwitcher（App 前台），
    //      继续拒 ReusePool（备用池）/ControlCenter（CC 迷你 fg 361 宽假岛）/hidden 窗口。
    //    快速 Home 回主屏条不回来 = 主屏 fg 零布局没人搬回 —— 由 1s 自愈 + 见过表
    //    + didMoveToSuperview 多档重试兜底（v1.4.6 已建）。
    UIWindow *sbWin = fg.window;
    NSString *winCls = sbWin ? NSStringFromClass(sbWin.class) : @"";
    BOOL legal;
    if (sbs_isSpringBoard()) {
        legal = sbWin && !sbWin.isHidden && !fg.isHidden &&
                ([winCls containsString:@"UIStatusBarWindow"] ||
                 [winCls containsString:@"MainSwitcher"]);
    } else {
        legal = sbWin && !sbWin.isHidden && !fg.isHidden;
    }
    if (!legal) {
        // ⭐ v1.4.6 门禁诊断（verbose）：直写不限流（App 内 fg 布局低频，
        //    限流会把启动窗口内的关键证据全部吞掉 —— 19:30 Preferences 零 [pass] 教训）
        if (gVerbose) {
            static NSTimeInterval lastDeny = 0;
            NSTimeInterval now = [NSDate date].timeIntervalSince1970;
            if (now - lastDeny > 0.15) {
                lastDeny = now;
                sbs_logNow(@"[deny] fg=%p win=%@ winHidden=%d fgHidden=%d fgW=%.0f",
                        fg, winCls, sbWin ? sbWin.isHidden : -1, fg.isHidden,
                        fg.bounds.size.width);
            }
        }
        return;
    }
    // ⭐ v1.4.6 锁屏不显示（许总要求）：SB 进程内读系统锁屏状态，锁屏时条隐藏。
    //    解锁后主屏布局触发 → locked=NO → 条恢复。
    if (sbs_sbLocked()) {
        if (gStrip && !gStrip.hidden) gStrip.hidden = YES;
        return;
    }
    // ⭐ v1.4.6 放行快照（verbose）：直写不限流，与 [deny] 配对重建门禁序列
    if (gVerbose) {
        static NSTimeInterval lastPass = 0;
        NSTimeInterval now2 = [NSDate date].timeIntervalSince1970;
        if (now2 - lastPass > 0.15) {
            lastPass = now2;
            sbs_logNow(@"[pass] fg=%p win=%@ fgW=%.0f live=%d",
                    fg, winCls, fg.bounds.size.width, sbs_fgIsLive(fg) ? 1 : 0);
        }
    }
    // ⭐⭐ v1.4.2 关键修复：只托管【全屏宽度】的 fg。
    //    实测假岛根因：CC/Spotlight 窗口的迷你状态栏 fg 宽 361（≠屏宽 430），
    //    其内部有类名含 Pill 且尺寸恰好 126×37 的居中视图 → 岛检测误命中。
    CGFloat scrW = sbWin.bounds.size.width;
    if (scrW > 0 && fabs(fg.bounds.size.width - scrW) > 1.0) return;
    // ⭐ v1.4.4 关键：合法 fg 先记录（强引用），
    //    即使下面 fgIsLive 暂时失败（CC 动画期间 StringView 被移除），
    //    多档重试也能在动画结束后把它劫持回来。
    gActiveFG = fg;
    [sbs_seenFGs() addObject:fg];          // ⭐ v1.4.6 记入见过表（弱引用）
    if (!sbs_fgIsLive(fg)) return;
    // ⭐ 节流 33ms（CC 动画每帧都调 layoutSubviews，封顶 30fps 防止任何残余循环）
    //    data 驱动（sbs_auxRelayoutFromData）会先置 gAuxForceRelayout 跳过节流。
    static NSTimeInterval lastRun = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (!gAuxForceRelayout && now - lastRun < 0.033) return;
    gAuxForceRelayout = NO;
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
    // ⭐ v1.4.6 同窗防护：host 必须与 fg 同窗口。快速 Home 时系统会把 UIStatusBarWindow
    //    里的宿主容器整体借进 SBMainSwitcherWindow（App 切换器动画），过渡瞬间存在
    //    fg.window 仍读旧值而 host 已在切换器的窗口期 —— 此时绝不搬家，等下一次布局。
    if (host.window && fg.window && host.window != fg.window) {
        if (gVerbose) {
            static NSTimeInterval lastSkip = 0;
            NSTimeInterval now3 = [NSDate date].timeIntervalSince1970;
            if (now3 - lastSkip > 0.5) {
                lastSkip = now3;
                sbs_logNow(@"[skipHost] fg=%p fgWin=%@ hostWin=%@",
                        fg, NSStringFromClass(fg.window.class),
                        NSStringFromClass(host.window.class));
            }
        }
        return;
    }
    // —— 被动写：宿主变化才搬家；条 frame = 所有目标的最小包围盒；图标逐个比对 ——
    if (gStrip.superview != host) {
        // ⭐ v1.4.6 搬家取证（verbose）：条宿主变化是"条消失"的直接现场
        if (gVerbose) {
            NSString *fromWin = gStrip.superview.window ?
                NSStringFromClass(gStrip.superview.window.class) : @"nil";
            NSString *toWin = host.window ?
                NSStringFromClass(host.window.class) : @"nil";
            sbs_logNow(@"[move] fg=%p fgWin=%@ | %@(%@) → %@(%@)",
                    fg, NSStringFromClass(fg.window.class),
                    NSStringFromClass(gStrip.superview.class) ?: @"nil", fromWin,
                    NSStringFromClass(host.class), toWin);
        }
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

// ⭐ v1.4.6 App 进程 fg 主动扫描：递归遍历 App 窗口树找 _UIStatusBarForegroundView。
//   App 内 fg 首布局早于 ctor（hook 错过，见 sbs_installAux 注释），hook 永不再触发。
//   App 进程视图树可遍历（SB 里 [UIApplication windows] subviews 全空的教训不适用）。
static void sbs_appScanFG(int round) {
    if (!gEnabled && !gAuxEnabled) return;
    if (gStrip && gStrip.superview) return;      // 条已挂好 → 扫描完成
    Class FGC = objc_getClass("_UIStatusBarForegroundView");
    if (!FGC) return;
    @try {
        NSArray *wins = [[UIApplication sharedApplication] windows];
        __block UIView *found = nil;
        NSMutableArray *stack = [NSMutableArray array];
        for (UIWindow *w in wins) [stack addObject:w];
        while (stack.count && !found) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            if ([v isKindOfClass:FGC]) { found = v; break; }
            for (UIView *c in v.subviews) [stack addObject:c];
        }
        if (found) {
            if (gVerbose)
                sbs_logNow(@"[scan#%d] 找到 fg=%p win=%@ fgW=%.0f",
                        round, found,
                        found.window ? NSStringFromClass(found.window.class) : @"nil",
                        found.bounds.size.width);
            gAuxForceRelayout = YES;
            sbs_auxLayoutInFG(found);
            // 跟进多档重试（fg 内容稳定后 frame 可能才定）
            for (int k = 0; k < 3; k++) {
                NSTimeInterval d = (k == 0 ? 0.3 : (k == 1 ? 0.8 : 1.5));
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try {
                        gAuxForceRelayout = YES;
                        sbs_auxLayoutInFG(found);
                    } @catch (NSException *e) { sbs_log(@"[exc-scanR] %@", e); }
                });
            }
        } else if (gVerbose) {
            sbs_logNow(@"[scan#%d] 未找到 fg（windows=%lu）", round,
                    (unsigned long)wins.count);
        }
    } @catch (NSException *e) {
        sbs_log(@"[exc-scan] %@", e);
    }
}

static void sbs_install(void) {
    static BOOL installed = NO;
    static int classWaitAttempt = 0;
    if (installed) return;
    Class FG = objc_getClass("_UIStatusBarForegroundView");
    if (!FG) {
        // SpringBoard 冷启动时 ctor 可能早于 UIKit 私有状态栏类注册。旧代码在这里
        // 永久返回，导致辅助条和缩放 hook 整次启动都不生效。有限重试等待类出现。
        if (classWaitAttempt == 0)
            NSLog(@"[StatusBarScale] waiting for _UIStatusBarForegroundView");
        if (classWaitAttempt++ < 10) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ sbs_install(); });
        } else {
            NSLog(@"[StatusBarScale] status bar class unavailable after retries");
        }
        return;
    }
    installed = YES;
    NSLog(@"[StatusBarScale] status bar class ready; installing core hooks");
    BOOL layoutOK = SBSHook(FG, @selector(layoutSubviews),
                            SBSHelper.class, @selector(sbs_fgLayoutSubviews));
    // ⭐ v1.4.6 直写：ctor 里 [载入] 后 50ms 内的 [hook] 行全被限流吞掉，
    //    App 内 hook 是否装上无法从日志判断 —— install 是一次性的，直写安全
    sbs_logNow(@"[hook] layoutSubviews → %@", layoutOK ? @"已安装" : @"失败");

    // 全局 hook UIView.setTransform: 拦截受管图标被系统重置（关键修复）
    BOOL transformOK = SBSHook([UIView class], @selector(setTransform:),
                               SBSHelper.class, @selector(sbs_viewSetTransform:));
    sbs_logNow(@"[hook] UIView.setTransform: → %@", transformOK ? @"已安装" : @"失败");

    BOOL windowOK = SBSHook(FG, @selector(didMoveToWindow),
                            SBSHelper.class, @selector(sbs_fgDidMoveToWindow));
    sbs_logNow(@"[hook] didMoveToWindow → %@", windowOK ? @"已安装" : @"失败");

    // ⭐ v1.4.6 快速切换补漏：fg 进出场的另外两条必经路径
    BOOL superviewOK = SBSHook(FG, @selector(didMoveToSuperview),
                               SBSHelper.class, @selector(sbs_fgDidMoveToSuperview));
    sbs_logNow(@"[hook] didMoveToSuperview → %@", superviewOK ? @"已安装" : @"失败");

    BOOL hiddenOK = SBSHook(FG, @selector(setHidden:),
                            SBSHelper.class, @selector(sbs_fgSetHidden:));
    sbs_logNow(@"[hook] fg setHidden: → %@", hiddenOK ? @"已安装" : @"失败");
    NSLog(@"[StatusBarScale] core hooks layout=%d transform=%d window=%d superview=%d hidden=%d",
          layoutOK, transformOK, windowOK, superviewOK, hiddenOK);
    NSUInteger layoutSubs = sbs_hookDefiningClasses(FG, @selector(layoutSubviews),
        @selector(sbs_fgLayoutSubviews), method_getTypeEncoding(class_getInstanceMethod(FG, @selector(layoutSubviews))), @"layout subclass");
    NSUInteger windowSubs = sbs_hookDefiningClasses(FG, @selector(didMoveToWindow),
        @selector(sbs_fgDidMoveToWindow), method_getTypeEncoding(class_getInstanceMethod(FG, @selector(didMoveToWindow))), @"window subclass");
    NSUInteger superSubs = sbs_hookDefiningClasses(FG, @selector(didMoveToSuperview),
        @selector(sbs_fgDidMoveToSuperview), method_getTypeEncoding(class_getInstanceMethod(FG, @selector(didMoveToSuperview))), @"superview subclass");
    NSUInteger hiddenSubs = sbs_hookDefiningClasses(FG, @selector(setHidden:),
        @selector(sbs_fgSetHidden:), method_getTypeEncoding(class_getInstanceMethod(FG, @selector(setHidden:))), @"hidden subclass");
    NSLog(@"[StatusBarScale] status bar subclass hooks layout=%lu window=%lu superview=%lu hidden=%lu",
          (unsigned long)layoutSubs, (unsigned long)windowSubs,
          (unsigned long)superSubs, (unsigned long)hiddenSubs);

    BOOL eventOK = SBSHook(UIApplication.class, @selector(sendEvent:),
                           SBSHelper.class, @selector(sbs_applicationSendEvent:));
    NSLog(@"[StatusBarScale] readiness hook UIApplication sendEvent=%d", eventOK);
    Class springBoard2 = objc_getClass("safemode_ui.SpringBoard2");
    BOOL launchOK = SBSHook(springBoard2, @selector(applicationDidFinishLaunching:),
                            SBSHelper.class, @selector(sbs_applicationDidFinishLaunching:));
    Class statusProvider = objc_getClass("SBStatusBarStateProvider");
    BOOL postOK = SBSHook(statusProvider, @selector(_didFinishPost),
                          SBSHelper.class, @selector(sbs_statusBarDidFinishPost));
    // screenIsOn 只走定义类扫描这一条路径；禁止先指定类 hook
    // 再扫描 hook，否则同一 Method 交换两次会在首次调用时递归。
    NSUInteger screenDefiners = sbs_hookDefiningClasses(nil, @selector(screenIsOn),
        @selector(sbs_backlightScreenIsOn), "B16@0:8", @"screenIsOn");
    NSLog(@"[StatusBarScale] readiness hooks launch=%d statusPost=%d",
          launchOK, postOK);
    NSLog(@"[StatusBarScale] screenIsOn defining-class hooks=%lu",
          (unsigned long)screenDefiners);

    // —— 辅助图标：强制启用系统原生 item ——
    // ⛔ 崩溃教训（v1.1.0，2026-10-04 16:25 SIGABRT）：构造期对任意类调
    //    class_getInstanceMethod 会触发该类 +initialize，早期启动时会抛异常
    //    （栈：sbs_ctor → class_getInstanceMethod → initializeNonMetaClass → rethrow）。
    //    ⇒ ctor 中的 GCD 延迟任务和 pthread 在这台真机的注入时期均不可靠。
    //       改用 UIKit 启动完成/进入活跃态通知，此时私有状态栏类已安全初始化。
    if (gAuxEnabled) sbs_registerAuxBootstrapObservers();
}

static void sbs_registerAuxBootstrapObservers(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSArray<NSNotificationName> *names = @[
        UIApplicationDidFinishLaunchingNotification,
        UIApplicationDidBecomeActiveNotification
    ];
    for (NSNotificationName name in names) {
        [center addObserverForName:name object:nil queue:nil
                        usingBlock:^(NSNotification *note) {
            NSLog(@"[StatusBarScale] auxiliary bootstrap notification: %@", note.name);
            sbs_startAuxIfNeeded();
        }];
    }
    NSLog(@"[StatusBarScale] auxiliary bootstrap observers registered");
    // 不根据延迟时间猜测 UIKit 是否就绪。用主 RunLoop 定时探针读取
    // UIScreen.screens，只有实际出现 screen 后才安装辅助模块。
    if (!gAuxBootstrapTimer) {
        CFRunLoopTimerContext ctx = {0, NULL, NULL, NULL, NULL};
        gAuxBootstrapTimer = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                                  CFAbsoluteTimeGetCurrent() + 0.1,
                                                  0.5, 0, 0,
                                                  sbs_auxBootstrapTimerFired, &ctx);
        CFRunLoopAddTimer(CFRunLoopGetMain(), gAuxBootstrapTimer, kCFRunLoopCommonModes);
        CFRunLoopWakeUp(CFRunLoopGetMain());
        NSLog(@"[StatusBarScale] UIScreen readiness probe registered");
    }
}

static void sbs_auxBootstrapTimerFired(CFRunLoopTimerRef timer, __unused void *info) {
    static NSUInteger tick = 0;
    tick++;
    @try {
        NSUInteger screenCount = UIScreen.screens.count;
        if (tick == 1 || screenCount > 0)
            NSLog(@"[StatusBarScale] UIScreen readiness tick=%lu screens=%lu",
                  (unsigned long)tick, (unsigned long)screenCount);
        if (screenCount == 0) return;
        CFRunLoopTimerInvalidate(timer);
        if (gAuxBootstrapTimer) {
            CFRelease(gAuxBootstrapTimer);
            gAuxBootstrapTimer = NULL;
        }
        sbs_startAuxIfNeeded();
    } @catch (NSException *e) {
        NSLog(@"[StatusBarScale] UIScreen readiness probe failed: %@", e);
    }
}

static void sbs_startAuxIfNeeded(void) {
    if (!gAuxEnabled || gAuxInstallBegan) return;
    @try {
        if (UIScreen.screens.count == 0) {
            NSLog(@"[StatusBarScale] auxiliary install deferred: no UIScreen yet");
            return;
        }
    } @catch (NSException *e) {
        NSLog(@"[StatusBarScale] auxiliary readiness check failed: %@", e);
        return;
    }
    gAuxInstallBegan = YES;
    NSLog(@"[StatusBarScale] starting auxiliary hook install");
    sbs_installAux();
}

static void sbs_auxLifecycleTrigger(NSString *source) {
    if (!gAuxEnabled || gAuxInstallBegan) return;
    NSLog(@"[StatusBarScale] auxiliary lifecycle trigger: %@", source);
    sbs_startAuxIfNeeded();
}

static void sbs_installAux(void) {
    @try {
        NSLog(@"[StatusBarScale] auxiliary stage 1: runtime discovery");
        // —— API 面侦查：状态数据从哪来 ——
        // ⭐ v1.4.6：侦查 dump 挂 verbose 门控（每个 App 首次启动都打 ~80 行，
        //    会把限流窗口占满、挤掉关键时序日志；侦查结论已固化在注释里）
        if (gVerbose) {
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
        }   // ⭐ v1.4.6 end if (gVerbose) —— 侦查 dump 门控结束
        SEL ce = @selector(canEnableDisplayItem:fromData:);
        Class owner = sbs_findDefiner(ce, "B32@0:8@16@24");
        NSLog(@"[StatusBarScale] auxiliary stage 1 complete: owner=%@",
              owner ? NSStringFromClass(owner) : @"(none)");
        sbs_log(@"[canEnable] 实现类 = %@", owner ? NSStringFromClass(owner) : @"(未找到)");
        if (owner) {
            BOOL ok = SBSHook(owner, ce, SBSHelper.class,
                              @selector(sbs_canEnableDisplayItem:fromData:));
            sbs_log(@"[hook] canEnableDisplayItem:fromData: → %@",
                    ok ? @"已安装" : @"失败");
        }
        // 侦查 hook：item 视图 / display item 创建流
        Class IT = objc_getClass("_UIStatusBarItem");
        NSLog(@"[StatusBarScale] auxiliary stage 2: item hooks class=%@",
              IT ? NSStringFromClass(IT) : @"(none)");
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
            NSLog(@"[StatusBarScale] auxiliary stage 3: data hooks class=%@",
                  D ? NSStringFromClass(D) : @"(none)");
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
        // ⭐ v1.4.5 启动定时自愈（兜底一切条丢失场景）
        NSLog(@"[StatusBarScale] auxiliary stage 4: self-heal timer");
        sbs_auxSelfHealStart();

        // ⭐⭐ v1.4.6 App 进程主动扫描 fg（App 内条显示的生命线）：
        //    【实测 19:38 铁证】App 内 fg 的创建/挂窗/首布局全部发生在 ctor 之前
        //    （[apply]/[pass]/[deny]/[didMove] 直写全 0，5 个 hook 却"已安装"）——
        //    hook 装好后再无触发点，条永远没人放。App 进程的视图树【可遍历】
        //    （v1.0 "SB 里 [UIApplication windows] subviews 全空"的教训不适用于 App 进程），
        //    主动扫窗口找 fg 实例 → 记录 gActiveFG → 触发布局。
        //    3 轮扫描（0.5s/2s/5s）覆盖 fg 创建时序差异。
        if (!sbs_isSpringBoard()) {
            for (int i = 0; i < 3; i++) {
                NSTimeInterval d = (i == 0 ? 0.5 : (i == 1 ? 2.0 : 5.0));
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try { sbs_appScanFG(i); } @catch (NSException *e) {
                        sbs_log(@"[exc-scan] %@", e);
                    }
                });
            }
        }
        // 一次性 unified log 健康标记，不写文件、不在布局热路径执行。
        NSLog(@"[StatusBarScale] v%@ auxiliary status bar ready (home + app hosts)",
              SBS_VERSION);
    } @catch (NSException *e) {
        NSLog(@"[StatusBarScale] auxiliary install failed: %@", e);
        sbs_log(@"[exc-aux] %@", e);
    }
}

__attribute__((constructor))
static void sbs_ctor(void) {
    // v1.5.0 防御性白名单：即使用户残留了旧版 Classes=UIApplication 过滤文件，
    // 也绝不在 Aweme/WebKit/PosterBoard/普通 App 中安装任何全局 swizzle。
    if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"])
        return;
    sbs_loadConfig();
    NSLog(@"[StatusBarScale] v%@ loaded in SpringBoard; aux=%d verbose=%d",
          SBS_VERSION, gAuxEnabled, gVerbose);
    sbs_log(@"[载入] v%@ proc=%@ pid=%d enabled=%d scale=%.3f dy=%.2f thr=%.0f lead=%d/%.2f",
            SBS_VERSION, [[NSProcessInfo processInfo] processName], getpid(),
            gEnabled, gScale, gDy, gThr, gLeadEnabled, gLeadScale);
    sbs_install();
}
