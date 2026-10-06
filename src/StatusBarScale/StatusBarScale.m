// StatusBarScale.m —— 状态栏图标缩放对齐 v1.8.0
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
// ⭐ v1.8.0 辅助条定位变更（许总 2026-10-05 需求）：
//   ① 辅助条【只收纳系统不在状态栏左右两侧显示的图标】（系统已显示的自动剔除，不重复）；
//   ② 图标尺寸 = 系统原图标(约 17pt) × 0.4 ≈ 6.8pt（许总确认的基准）；
//   ③ 位置 = 灵动岛正下方屏幕水平居中；④ 锁屏不显示，主屏 + App 内跟随时间显示。
//   判定"系统是否已显示"的唯一证据 = canEnableDisplayItem:fromData: 的 orig 返回值
//   （orig==YES 说明系统本来就会渲染它 → 辅助条跳过）。全程直写日志供许总核对。
//
// 配置 /var/mobile/Library/Preferences/com.xu.statusbarscale.plist（改后需 respring）：
//   enabled(bool,默认YES)  scale(float,默认0.92)  dy(float,默认1.5)
//   threshold(float,默认312)  verbose(bool,默认NO)
//   leadEnabled(bool,默认YES)  leadScale(float,默认0.60)  leadDy(float,默认0)
//   diag(bool,默认YES) —— 关键事件直写（v1.7.1 起独立于 verbose，默认开）
//   auxEnabled(bool,默认YES)  auxStrip(bool)  auxData(bool)  auxIcons(array)
//   auxBaseSize(float,默认17) —— 系统原图标点尺寸基准
//   auxScale(float,默认0.4)   —— 相对基准的缩放（许总指定 0.4）
//   auxGap(float,默认3)       —— 图标间距
//
// 日志：/var/mobile/Documents/sbs_log.txt
//   diag=YES：关键事件（[hook]/[lead]/[aux]/[canEnable]/[auxVis]/[move]/[heal]/[scan]）直写落盘；
//   verbose=YES：额外输出高频诊断（[pass]/[deny]/层级 dump）
//
// ⚠️ v1.7.1 修复的回归：v1.5.0 曾把 sbs_logNow 也挂上 `if (!gVerbose) return;`，
//   导致设备 verbose=NO 时【完全无日志】—— 故障无法定位（"图标无法枚举"的元凶）。
// ⚠️ v1.8.0 同类修复：aux 全链路日志原本走 sbs_log（verbose 门控）→ 设备上
//   一个字节都看不到，辅助条"没显示"无法定位（2026-10-05 截图实证条不在屏上）。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define SBS_VERSION @"1.9.6"
#define SBS_LOG_PATH @"/var/mobile/Documents/sbs_log.txt"

static BOOL    gEnabled = YES;
static CGFloat gScale   = 0.92f;
static CGFloat gDy      = 0.67f;  // ⭐ v1.9.5 语义＝「锚点强度」：scale=0.84847 时的下移量（实机调定值）；
                                  //    实际 dy 由 sbs_dyForScale(gScale) 实时推算（面板不再暴露 dy）
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
static BOOL         gAuxDebug = NO;               // ⭐ v1.8.0 调试：红底描边直观判定"条是否在屏上"
// 辅助条外观（v1.8.0）：灵动岛正下方居中；图标边长 = 系统原尺寸 × auxScale
static CGFloat      gAuxBaseSize = 17.0;        // 系统原图标点尺寸基准（状态栏 item 实测 17.3pt）
static CGFloat      gAuxScale    = 0.4;         // 许总指定：相对系统原图标缩小为 0.4 倍
static CGFloat      gAuxGap      = 3.0;         // 图标间距
// ⭐ v1.8.0「只放系统不显示的」判定表（证据 = canEnableDisplayItem 的 orig 返回值）：
//   gSysShown  : orig==YES → 系统本就会在状态栏显示该图标 → 辅助条跳过（不重复）
//   gSysHidden : orig==NO  → 系统不显示 → 辅助条负责收纳
static NSMutableSet *gSysShown  = nil;
static NSMutableSet *gSysHidden = nil;
// ⭐ v1.8.0 当次布局快照：本次扫描 fg 时反查到的「系统正在显示」的 ident。
//   每次布局前清空重建（不累积）—— 累积会误伤只在该场景出现的图标。
static NSMutableSet *gSysShownNow = nil;
// ⭐ v1.8.0 动态回收计数：某 ident 在【可信快照】里连续缺席的次数。
//   满 3 次才从抑制表移除（迟滞），避免"系统图标稍晚建立"被误判为"系统不再显示"。
static NSMutableDictionary<NSString *, NSNumber *> *gSysAbsent = nil;
// ⭐⭐ v1.8.1 真·信号源（许总指正：不许按图标名称判断，要监听状态栏变化信号）
//   `_UIStatusBar -_updateDisplayedItemsWithData:styleAttributes:extraAnimations:`
//   是状态栏的**显示决策入口**（每次状态更新都会走）→ 在那里读 `_items` 容器，
//   拿到"系统此刻真的给哪些 item 建了视图"= 系统正在显示谁。这是实时状态，不是快照。
static BOOL          gSignalSeen  = NO;   // 信号源是否已工作（有信号事件到达）
static NSUInteger    gSignalCount = 0;    // 信号事件计数
static NSMutableSet *gSysNameHit  = nil;  // 名称兜底命中表（只增不减：保守加项）

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

// ⭐⭐ v1.9.5 垂直微调与缩放**绑定**（许总要求：缩放一变，微调实时推算；面板只留"缩放"滑块）。
//   绑定曲线取线性 dy(s) = K · (1 − s)：
//     · s → 1（不缩）时 dy → 0 —— 符合"不缩就不必下移"的直觉；
//     · K 由**许总实机调定的工作点**标定：锚点强度 = 配置键 `dy` 的值，配锚点缩放 0.84847
//       （实测 dy=0.6687、scale=0.84847 ⇒ K ≈ 4.41）⇒ 在该点推算值与原值相等，**视觉零变化**；
//     · 面板已不再暴露 dy；改配置即改绑定曲线的陡峭程度。
#define SBS_DY_ANCHOR_SCALE     0.84847f
#define SBS_DY_ANCHOR_DY_DEFAULT 0.67f
static CGFloat sbs_dyForScale(CGFloat s) {
    CGFloat anchor = (gDy > 0.0f && gDy <= 20.0f) ? gDy : SBS_DY_ANCHOR_DY_DEFAULT;
    CGFloat k = anchor / (1.0f - SBS_DY_ANCHOR_SCALE);
    return k * (1.0f - s);
}

static CGAffineTransform sbs_targetTransform(void) {
    return CGAffineTransformTranslate(
        CGAffineTransformMakeScale(gScale, gScale), 0, sbs_dyForScale(gScale) / gScale);
}

// leading 图标的目标变换：绕中心缩放 gLeadScale（+ 可选下移 gLeadDy pt）
// 注：Translate(Scale(s,s),0,dys) 的屏幕位移 = s*dys → dys = dy/s（同 sbs_targetTransform）
static CGAffineTransform sbs_leadTransform(void) {
    CGFloat s = (gLeadScale > 0.05f && gLeadScale < 1.0f) ? gLeadScale : 0.60f;
    return CGAffineTransformTranslate(CGAffineTransformMakeScale(s, s), 0, gLeadDy / s);
}

static void sbs_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void sbs_logNow(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);   // v1.4.6 前向声明

// ⭐⭐ v1.9.2 撤销/复核（治「状态栏 item 视图被复用池拿去渲染别的东西后，
//    我们的变换还黏在同一对象上」）。2026-10-06 锁屏日志实证：
//      `_UIStatusBarStringView` 既用于【时间】(左, x≈57)，也用于【电池百分比/运营商名】
//      (右, x≥280)。右侧那份被主缩放登记+缩到 0.848 后，视图进入 SBStatusBarReusePoolWindow
//      复用池，随后被拿去渲染【时间】—— 对象没变、变换还在，`sbs_viewSetTransform:` 还会
//      把系统的复原动作强行改回 0.848 ⇒ 主屏时间正常、进 App/锁屏「时间被缩放」。
//    判据一律取视图**此刻**的状态（类名/frame/窗口/可见性），不依赖任何历史 fg 归属，
//    因此跨窗口、跨进程复用的场景同样能纠正。
//    连续 SBS_RV_GRACE 秒不合格才撤销 —— 防"布局尚未完成的瞬间（frame=0）"被误还原。
#define SBS_RV_GRACE 1.5
static void sbs_revalidateManaged(CGAffineTransform want) {
    if (!gManaged || gManaged.count == 0) return;
    static NSMutableDictionary *stamp = nil;      // 视图地址 → 首次不合格时刻
    if (!stamp) stamp = [NSMutableDictionary dictionary];
    if (stamp.count > 400) [stamp removeAllObjects];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    for (UIView *v in gManaged.allObjects) {
        NSString *cn = NSStringFromClass(v.class);
        BOOL isItem = ([cn containsString:@"StatusBar"] || [cn containsString:@"Battery"])
                      && ![cn containsString:@"StringView"];      // 文字视图永不参与
        // ⚠️ 判据只用「类名 + 自身尺寸 + 父坐标系位置」，**绝不看 window/hidden**：
        //    主屏 fg 在 App 前台会被系统摘窗（实测 window=nil），若据此判不合格，
        //    App 切换瞬间会把右侧图标误还原（22:52:03 实测 minX=305~361 仍被判"不合格"），
        //    切回来又重缩 → 每切一次图标闪一下。位置/尺寸足以表达"是否还在右侧"。
        BOOL ok = isItem && v.bounds.size.width > 0.5 && CGRectGetMinX(v.frame) >= gThr;
        NSString *k = [NSString stringWithFormat:@"%p", (__bridge void *)v];
        if (ok) { [stamp removeObjectForKey:k]; continue; }
        NSNumber *f = stamp[k];
        if (!f) { stamp[k] = @(now); continue; }                  // 首个不合格轮 → 只记时间
        if (now - f.doubleValue < SBS_RV_GRACE) continue;
        [stamp removeObjectForKey:k];
        // ⚠️ 必须【先摘登记、再还原】：否则 sbs_viewSetTransform: 会立刻把值改回来
        [gManaged removeObject:v];
        if (CGAffineTransformEqualToTransform(v.transform, want))
            v.transform = CGAffineTransformIdentity;              // 只还原"确实是我们设的值"
        sbs_logNow(@"[undo] %@ %p minX=%.1f 已不合格 → 还原变换（防复用黏连）",
                   cn, (__bridge void *)v, CGRectGetMinX(v.frame));
    }
}

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

// ⭐⭐ v1.8.0 API 探针（一次性）：定位"状态栏前景色/风格"的可靠来源。
//   背景：`_UIStatusBarStringView.textColor` 实测与**实际渲染取反**
//   （主屏渲染黑字却报白、Calculator 渲染白字却报黑）→ 不足以定色。
//   需要找 style / legibility 这类真实来源（状态栏前景色由 legibility 决定）。
static void sbs_probeAPIs(UIView *fg) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    NSArray *cls = @[@"_UIStatusBarStringView", @"_UIStatusBarForegroundView",
                     @"_UIStatusBar", @"UIStatusBar_Modern", @"_UIStatusBarData"];
    for (NSString *cn in cls) {
        Class C = objc_getClass(cn.UTF8String);
        if (!C) { sbs_logNow(@"[capi] %@ 不存在", cn); continue; }
        unsigned int n = 0;
        Method *ms = class_copyMethodList(C, &n);
        NSMutableString *s = [NSMutableString string];
        for (unsigned int i = 0; i < n; i++) {
            NSString *sn = @(sel_getName(method_getName(ms[i])));
            if ([sn rangeOfString:@"tyle"].location != NSNotFound ||
                [sn rangeOfString:@"olor"].location != NSNotFound ||
                [sn rangeOfString:@"ore"].location != NSNotFound ||
                [sn rangeOfString:@"egib"].location != NSNotFound ||
                [sn rangeOfString:@"ontent"].location != NSNotFound)
                [s appendFormat:@"%@ ", sn];
        }
        free(ms);
        sbs_logNow(@"[capi] %@(%u): %@", cn, n, s);
    }
    // 运行时：沿 fg → superview（≤4 层）KVC 取值
    UIView *v = fg;
    for (int i = 0; i < 4 && v; i++) {
        for (NSString *k in @[@"style", @"legibilityStyle", @"foregroundColor",
                              @"contentStyle", @"statusBarStyle"]) {
            @try {
                id val = [v valueForKey:k];
                if (val) sbs_logNow(@"[capi] %@.%@ = %@",
                                    NSStringFromClass(v.class), k, val);
            } @catch (__unused NSException *e) {}
        }
        v = v.superview;
    }
    @try { sbs_logNow(@"[capi] app.statusBarStyle = %@",
                      [[UIApplication sharedApplication] valueForKey:@"statusBarStyle"]); }
    @catch (__unused NSException *e) {}
    // ⭐ v1.8.0 找「系统当前显示哪些 item」的**信号容器**（许总要求：不要靠图标名称判断）：
    //   `_UIStatusBar` 的 item 对象自带 identifier，且 item.view != nil 即"正在显示"。
    Class C2 = objc_getClass("_UIStatusBar");
    if (C2) {
        unsigned int ic = 0;
        Ivar *ivs = class_copyIvarList(C2, &ic);
        NSMutableString *s2 = [NSMutableString string];
        for (unsigned int i = 0; i < ic; i++)
            [s2 appendFormat:@"%s(%s) ", ivar_getName(ivs[i]), ivar_getTypeEncoding(ivs[i])];
        free(ivs);
        sbs_logNow(@"[capi] _UIStatusBar ivars(%u): %@", ic, s2);
    }
    // 运行时 KVC：找 items 容器
    UIView *bar = fg.superview;
    for (int i = 0; i < 2 && bar; i++) {
        if ([NSStringFromClass(bar.class) isEqualToString:@"_UIStatusBar"]) {
            for (NSString *k in @[@"items", @"displayItems", @"displayedItems",
                                  @"_items", @"itemViews", @"partStyles"]) {
                @try {
                    id val = [bar valueForKey:k];
                    if (val) sbs_logNow(@"[capi] _UIStatusBar.%@ = %@(%@) count=%lu",
                        k, NSStringFromClass([val class]), val,
                        (unsigned long)([val respondsToSelector:@selector(count)]
                                        ? (unsigned long)[val count] : 0));
                } @catch (__unused NSException *e) {}
            }
            break;
        }
        bar = bar.superview;
    }
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
    // ⭐ v1.8.0 辅助条尺寸防呆（默认 0.4 × 17 ≈ 6.8pt）
    if (gAuxBaseSize < 8.0f || gAuxBaseSize > 40.0f) gAuxBaseSize = 17.0f;
    if (gAuxScale <= 0.05f || gAuxScale > 2.0f)      gAuxScale    = 0.4f;
    if (gAuxGap < 0.0f || gAuxGap > 20.0f)           gAuxGap      = 3.0f;
    // 辅助图标配置：默认 = 系统状态栏【没有】原生显示的项。
    // ⚠️ location 不放默认集：系统已在时间旁渲染原生定位箭头，重复显示（许总反馈）。
    // ⭐⭐ v1.8.0 默认名单 = 许总要求的「系统不显示在灵动岛左/右两侧的图标」全集。
    //   ⚠️ 2026-10-05 实机修正：早前误以为 alarm/rotationLock 会被系统显示而移出名单 ——
    //      日志实证系统侧只有 `location.fill` 一个图标（时间旁那个是**定位箭头**，不是闹钟），
    //      即灵动岛机型上闹钟/旋转锁/静音等并未被系统渲染，本就应该交给辅助条收纳。
    //   location 也纳入名单：系统显示它时由运行期剔除逻辑自动跳过（见 sbs_identShownBySystem），
    //      系统不显示时才由辅助条补上 —— 无论哪种情况都不会重复。
    if (!gAuxIcons) gAuxIcons = @[@"alarm", @"quietMode", @"rotationLock", @"location",
                                  @"vpn", @"bluetooth", @"airplane"];
    if (d) {
        NSNumber *n;
        if ((n = d[@"auxEnabled"]) && [n isKindOfClass:[NSNumber class]])
            gAuxEnabled = n.boolValue;
        if ((n = d[@"auxStrip"]) && [n isKindOfClass:[NSNumber class]])
            gAuxStrip = n.boolValue;
        if ((n = d[@"auxData"]) && [n isKindOfClass:[NSNumber class]])
            gAuxData = n.boolValue;
        // ⭐ v1.8.0 辅助条尺寸/间距
        if ((n = d[@"auxBaseSize"]) && [n isKindOfClass:[NSNumber class]]) gAuxBaseSize = n.floatValue;
        if ((n = d[@"auxScale"])    && [n isKindOfClass:[NSNumber class]]) gAuxScale    = n.floatValue;
        if ((n = d[@"auxGap"])      && [n isKindOfClass:[NSNumber class]]) gAuxGap      = n.floatValue;
        // ⭐ v1.8.0 调试红底（默认 NO；开=条红底描边，肉眼判定"条是否真的在屏上"）
        if ((n = d[@"auxDebug"])    && [n isKindOfClass:[NSNumber class]]) gAuxDebug    = n.boolValue;
        // ⭐ v1.9.0 设置面板逐图标开关（auxIcon_<ident>）优先：
        //   面板任一 auxIcon_* 键出现 ⇒ 以这组布尔为准重建名单；
        //   面板从未写过且配置里也没有 auxIcons 数组 ⇒ 同样用这组（默认全开，
        //   结果与 v1.8.x 内置默认名单一致）；只有"显式写了数组但没用面板"
        //   才回落数组，保证老配置零行为变化。
        NSArray *pairs = @[@[@"auxIcon_alarm",        @"alarm"],
                           @[@"auxIcon_quietMode",    @"quietMode"],
                           @[@"auxIcon_rotationLock", @"rotationLock"],
                           @[@"auxIcon_location",     @"location"],
                           @[@"auxIcon_vpn",          @"vpn"],
                           @[@"auxIcon_bluetooth",    @"bluetooth"],
                           @[@"auxIcon_airplane",     @"airplane"]];
        NSMutableArray *fromUI = [NSMutableArray array];
        BOOL uiKeys = NO;
        for (NSArray *p in pairs) {
            NSNumber *iv  = d[p[0]];
            BOOL      has = (iv && [iv isKindOfClass:[NSNumber class]]);
            if (has) uiKeys = YES;
            BOOL on = has ? iv.boolValue : YES;      // 未设置的项默认收纳
            if (on) [fromUI addObject:p[1]];
        }
        NSArray *arr   = d[@"auxIcons"];
        BOOL     hasArr = ([arr isKindOfClass:[NSArray class]] && arr.count > 0);
        if (uiKeys || !hasArr) {
            gAuxIcons = fromUI;
        } else {
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
static BOOL sbs_fgIsLive(UIView *fg);         // ⭐ v1.8.0 App 兜底扫描取证要用（定义见后）
static void sbs_colorTick(void);              // ⭐ v1.8.0 配色巡检（定义见后）
static void sbs_auxRelayoutFromData(void);    // ⭐ v1.4.4 data 驱动重排（定义见后）
static void sbs_applyLead(UIView *fg);        // ⭐ v1.7.0 leading 区图标缩放（定义见后）
static CGRect sbs_islandFrameInFG(UIView *fg); // ⭐ v1.7.0 leading 判定要用（定义见后）
static void sbs_dumpScaled(UIView *fg, NSString *by);  // ⭐ v1.9.1 探针（定义见后）
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
    sbs_dumpScaled(fg, @"apply");     // ⭐ v1.9.1 探针：此刻 fg 内谁带着缩放过（变更即记+60s 心跳）
    // ⭐ v1.9.5 绑定取证：缩放一变就打印实时推算的垂直微调（变更即记，许总可核对联动）
    {
        static CGFloat lastS = -1.0f, lastD = -1.0f;
        CGFloat dyNow = sbs_dyForScale(gScale);
        if (fabs(lastS - gScale) > 0.0005f || fabs(lastD - dyNow) > 0.005f) {
            lastS = gScale; lastD = dyNow;
            sbs_logNow(@"[bind] 缩放 %.4f → 垂直微调 %.2f pt（锚点 %.2fpt@%.5f）",
                       gScale, dyNow, gDy, SBS_DY_ANCHOR_SCALE);
        }
    }
    CGAffineTransform t = sbs_targetTransform();
    if (!gManaged) gManaged = [NSHashTable weakObjectsHashTable];
    for (UIView *v in fg.subviews) {
        // 按类名过滤：只缩放状态栏 item 视图（含辅助图标），
        // 不碰全宽 legibility 象限背景（普通 UIView）
        NSString *cn = NSStringFromClass(v.class);
        // ⭐⭐ v1.9.2 根因修复：文字视图（`_UIStatusBarStringView`）不参与主缩放。
        //    它同时承担【时间】(左) 与【电池百分比/运营商名】(右, x≥280) 两种身份，
        //    被登记后一旦被复用池拿去渲染时间，就会「缩时间」（锁屏日志实证 a=0.848）。
        BOOL isItem = ([cn containsString:@"StatusBar"] || [cn containsString:@"Battery"])
                      && ![cn containsString:@"StringView"];
        if (isItem && CGRectGetMinX(v.frame) >= gThr) {
            // 登记为受管视图（弱引用，view 销毁自动剔除）
            [gManaged addObject:v];
            if (!CGAffineTransformEqualToTransform(v.transform, t)) v.transform = t;
        }
    }
    // ⭐ v1.9.2 撤销：已登记但此刻已不合格（被复用/被搬走/已变成时间）的，还原
    sbs_revalidateManaged(t);
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

// ⭐ v1.8.0 辅助条图标边长 = 系统原图标尺寸 × 缩放倍数（默认 17 × 0.4 ≈ 6.8pt）
static CGFloat sbs_auxIconSize(void) { return gAuxBaseSize * gAuxScale; }

// ⭐ v1.8.0「系统是否已显示」判定表（懒初始化）
//    证据源：canEnableDisplayItem:fromData: 的 orig 返回值 —— orig==YES 即系统
//    本来就会渲染该图标，辅助条必须跳过（许总需求：只放系统不显示的）。
static NSMutableSet *sbs_sysShown(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gSysShown = [NSMutableSet set]; });
    return gSysShown;
}
static NSMutableSet *sbs_sysHidden(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gSysHidden = [NSMutableSet set]; });
    return gSysHidden;
}
// ⭐⭐ v1.8.0 状态栏**实时信号源**（许总指正：不应靠图标名称比对）：
//   hook `_UIStatusBar -viewForIdentifier:` —— 系统**只为要显示的 item** 索要视图，
//   故该回调 = "系统正在显示这个图标"的实时变化信号（定位/免打扰这种实时状态最准）。
static NSMutableSet *gSysRendered = nil;
static NSMutableSet *sbs_sysRendered(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gSysRendered = [NSMutableSet set]; });
    return gSysRendered;
}
// hook 回调时记一笔（线程安全：主线程调用，加锁兜底）
static void sbs_noteRendered(NSString *ident) {
    if (!ident.length) return;
    @synchronized (sbs_sysRendered()) {
        [sbs_sysRendered() addObject:[ident lowercaseString]];
    }
}

// ⭐⭐ v1.8.4 名称兜底命中表（保留：仅作身份映射的关键词命中记录，供日志追溯）
static void sbs_auxLogOnce(NSString *key, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void sbs_auxRefresh(void);
static void sbs_rescanSchedule(NSString *why);   // ⭐ v1.8.4 视图树信号（定义见后）
static NSArray<NSString *> *sbs_auxKeyWords(NSString *ident); // ⭐ v1.8.4 身份映射关键词（定义见后）
static NSMutableSet *sbs_sysNameHit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gSysNameHit = [NSMutableSet set]; });
    return gSysNameHit;
}

// ⭐⭐ v1.8.1 发布"系统正在显示"的信号集 → 覆写抑制表。
//   语义：抑制表 = 信号集 ∪ 名称兜底集（后者保守、只增）。
//   与旧实现的区别（本次修复的核心）：
//     · 旧：抑制表单向累积 + "缺席计数连续 3 次就撤销" → 扫描是时序快照，
//       某一轮没采到系统图标就把之前的正确抑制撤销 → 定位图标回到辅助条
//       （2026-10-05 10:51 日志实证：22.972 那轮 location withdrawn，真机复现重复）。
//     · 新：以**信号集全量覆写**为准（系统此刻显示谁，抑制表就是谁）——
//       信号是状态栏自己的显示决策，不受扫描时机影响。名称集只做加项。
// ⭐⭐ v1.8.4 信号发布（**重写**）：抑制表 = 实时信号集（实时重算，非快照累积）。
//   语义（许总需求：图标不重复，且要随状态实时变化）：
//     · 加：立即生效
//     · 减：需连续 2 次"健康巡检"一致缺席（防过渡态/单次漏扫把抑制误撤）
//   与旧实现（v1.8.0「缺席计数 3 次」）的区别：现在的巡检是**事件驱动**的
//   （状态栏视图树变更即触发），不是靠 layout 时序碰运气 → 漏扫概率极低。
static void sbs_publishRescan(NSSet *now, BOOL healthy, NSString *why) {
    NSMutableSet *cur = sbs_sysRendered();
    NSMutableSet *added = [NSMutableSet set];
    NSMutableSet *removed = [NSMutableSet set];
    @synchronized (cur) {
        for (id o in now) {
            NSString *k = [o lowercaseString];
            if (![cur containsObject:k]) { [cur addObject:k]; [added addObject:k]; }
            if (gSysAbsent) [gSysAbsent removeObjectForKey:k];
        }
        if (healthy) {
            for (NSString *k in [cur allObjects]) {
                if ([now containsObject:k]) continue;
                NSInteger n = [gSysAbsent[k] integerValue] + 1;
                if (n >= 3) { [cur removeObject:k]; [removed addObject:k]; }
                else gSysAbsent[k] = @(n);
            }
        }
    }
    NSMutableSet *s = sbs_sysShown();
    [s removeAllObjects];
    @synchronized (cur) { [s unionSet:cur]; }
    NSArray *sorted = [s.allObjects sortedArrayUsingSelector:@selector(compare:)];
    NSString *setStr = sorted.count ? [sorted componentsJoinedByString:@","] : @"(空)";
    sbs_auxLogOnce([NSString stringWithFormat:@"rsig:%@:%@:%d", setStr, why ?: @"?",
                    healthy ? 1 : 0],
        @"【信号】系统正在显示=%@ ｜ 触发=%@ 巡检健康=%d 本次+[%@] -[%@]",
        setStr, why ?: @"?", healthy ? 1 : 0,
        added.count ? [[added.allObjects sortedArrayUsingSelector:@selector(compare:)]
                       componentsJoinedByString:@","] : @"-",
        removed.count ? [[removed.allObjects sortedArrayUsingSelector:@selector(compare:)]
                         componentsJoinedByString:@","] : @"-");
    if (added.count || removed.count) {
        gSignalSeen = YES;
        gSignalCount++;
        sbs_auxRefresh();                       // ① 立即驱动图标显隐
        // ② 显隐变了 → 条要重排（否则位置不移）。⭐ 异步执行：避免在 gInRescan
        //    保护区内同步回调 sbs_auxLayoutInFG → 后者又会触发 fg 视图写入 → 递归。
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *fg = gActiveFG;
            if (!fg) return;
            gAuxForceRelayout = YES;
            @try { sbs_auxLayoutInFG(fg); } @catch (__unused NSException *e) {}
        });
    }
}

// ⭐ v1.8.0 aux 诊断日志：去重 + 直写（走 sbs_logNow，受 diag 门控、不受 verbose 影响）。
//    用途：证明辅助条「真的建了 / 真的显示了 / 为什么没显示」。
//    ⚠️ 2026-10-05 教训：aux 日志原本全走 sbs_log（verbose 门控），设备 verbose=false
//       → 一个字节都看不到，辅助条没显示时无法定位是卡在哪一步。
static NSMutableSet *sbs_auxSeen(void) {
    static NSMutableSet *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}
static void sbs_auxLogOnce(NSString *key, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void sbs_auxLogOnce(NSString *key, NSString *fmt, ...) {
    if (![key isKindOfClass:[NSString class]] || !key.length) return;
    if ([sbs_auxSeen() containsObject:key]) return;
    [sbs_auxSeen() addObject:key];
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    sbs_logNow(@"[aux] %@", body);
}

// ⭐⭐⭐ v1.8.8 忠实状态日志（修「条显示/条隐藏」被永久去重吞掉的缺陷）
//   旧 `sbs_auxLogOnce` = 进程内**永久**去重集（只增不减）→ 同一状态组合只记一次，
//   导致 11:15:00 之后日志再无「条显示」，「条隐藏」的 key 固定为 `"empty"` 一个
//   SB 进程只记一次 ⇒ **日志无法证明"此刻条到底显不显示"**（违背许总铁律：日志必须
//   反映真机；也是"按日志修复"无从下手的原因）。
//   新语义（按类目分桶）：
//     · **任何跃迁必留痕**（stateKey 变化 → 立即写）；
//     · 状态未变 → 心跳兜底，同类目最长静默 60s 写一条（可证明"此刻仍是这个状态"）。
//   ⭐ v1.8.13 心跳 20s → 60s：20s × 每类目 ⇒ 稳态仍有 ~13 行/分钟（≈1.9 万行/天）
//      的纯"无变化"噪声。跃迁是精确的，心跳只用于证明"仍在态"，60s 足够。
#define SBS_STATE_HEARTBEAT 60.0
static NSMutableDictionary<NSString *, NSString *> *gStateLastKey = nil;
static NSMutableDictionary<NSString *, NSNumber *> *gStateLastT   = nil;
static void sbs_auxLogState(NSString *cat, NSString *stateKey, NSString *fmt, ...)
        NS_FORMAT_FUNCTION(3, 4);
static void sbs_auxLogState(NSString *cat, NSString *stateKey, NSString *fmt, ...) {
    if (!cat.length || !stateKey.length) return;
    if (!gStateLastKey) gStateLastKey = [NSMutableDictionary dictionary];
    if (!gStateLastT)   gStateLastT   = [NSMutableDictionary dictionary];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSString *prev = gStateLastKey[cat];
    NSTimeInterval pt = [gStateLastT[cat] doubleValue];
    BOOL changed = ![stateKey isEqualToString:prev];
    if (!changed && now - pt < SBS_STATE_HEARTBEAT) return;   // 状态未变 → 仅心跳
    gStateLastKey[cat] = [stateKey copy];
    gStateLastT[cat]   = @(now);
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    sbs_logNow(@"[aux] %@", body);
}

// 辅助图标条模块前向声明（定义见 SBSHelper 之后）
static id   sbs_gData(void);
static void sbs_setGData(id d);
static void sbs_auxRefresh(void);
static void sbs_signalFromBar(id bar, id data);   // ⭐ v1.8.1 真·信号源（定义见后）
static void sbs_probeSignal(UIView *fg);          // ⭐ v1.8.1 信号容器探针（定义见后）
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
        // ⭐⭐ v1.8.1 关键回退：**不再强制 YES**。
        //   旧实现 `return want ? YES : orig;` 会替系统启用这些 item → 系统自己就会
        //   把它们画到状态栏上 → ①违反许总"只放系统不显示的"需求；②污染我们自己的
        //   "系统显示了谁"信号（自证伪）。现在一律**原样放行**，让系统保持原生行为，
        //   我们的信号才干净。辅助条用自备 Assets.car 字形渲染，不依赖系统建 item。
        //   （注：本固件实测该回调一次都不触发 —— 留着只作观测/回归保险。）
        if ([gAuxIcons containsObject:ident.lowercaseString]) {
            NSString *k = ident.lowercaseString;
            if (orig) [sbs_sysShown() addObject:k];
            sbs_auxLogOnce([NSString stringWithFormat:@"ce:%@:%d", k, orig ? 1 : 0],
                @"canEnable %@ orig=%d → 原样放行（不再强制）", ident, orig);
        }
        return orig;
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

// ⭐⭐ v1.4.2 核心增强 / v1.8.0 改为**实时信号源**（许总要求）：
//   系统**只为要显示的 item** 调 viewForIdentifier: → 这是"系统正在显示该图标"的
//   实时信号，比事后按名称嗅探渲染结果可靠得多（定位/免打扰等实时变化的项尤其明显）。
//   ⚠️ 实测参数**不是 NSString**（是 `_UIStatusBarIdentifier` 之类），旧实现直接跳过
//      → 信号全漏（日志零条）。现在统一解析：字符串 / `identifier` 键 / description。
- (UIView *)sbs_viewForIdentifier:(id)ident {
    UIView *v = [self sbs_viewForIdentifier:ident];
    @try {
        NSString *s = nil;
        if ([ident isKindOfClass:[NSString class]]) {
            s = (NSString *)ident;
        } else if (ident) {
            @try {
                id iv = [ident valueForKey:@"identifier"];
                if ([iv isKindOfClass:[NSString class]]) s = (NSString *)iv;
            } @catch (__unused NSException *e) {}
            if (!s.length) {
                @try {
                    NSString *d = [ident description];
                    // description 形如 `<前缀: 值>` → 取冒号后的部分
                    NSRange r = [d rangeOfString:@":"];
                    s = (r.location != NSNotFound && r.location + 1 <= d.length)
                        ? [d substringFromIndex:r.location + 1] : d;
                } @catch (__unused NSException *e) {}
            }
            // 取证：打印参数真实类型（一次性/类型）
            sbs_auxLogOnce([@"vfiT:" stringByAppendingString:NSStringFromClass([ident class])],
                @"viewForIdentifier 参数类=%@ 原样=%@ 解析=%@",
                NSStringFromClass([ident class]),
                [ident description] ?: @"(nil)", s ?: @"(nil)");
        } else {
            // nil 参数：系统在"清理/重置"item 视图树 → 清空信号（当前无显示项）
            @synchronized (sbs_sysRendered()) { [sbs_sysRendered() removeAllObjects]; }
            sbs_auxLogOnce(@"vfi:nil", @"viewForIdentifier(nil) → 清空状态栏显示信号");
        }
        if (s.length) {
            // 去掉包裹的空白与引号
            s = [s stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            sbs_noteRendered(s);
            sbs_captureSysIcon(s, v);
            sbs_auxLogOnce([@"vfi:" stringByAppendingString:s],
                @"状态栏信号 viewForIdentifier → 「%@」(视图=%@)", s,
                v ? NSStringFromClass(v.class) : @"nil");
        }
    } @catch (__unused NSException *e) {}
    return v;
}

// ⭐⭐⭐ v1.8.1 **真·信号源**（许总指正后的核心改动）
//   许总原话："你不应该根据图标名称来判断，而是要去监听状态栏的变化信号，
//   像免打扰和定位这种是实时变化的。"
//   实现：hook `_UIStatusBar -_updateDisplayedItemsWithData:styleAttributes:
//   extraAnimations:` —— 这是状态栏每次数据更新时的**显示决策入口**（探针实证
//   该方法在 `_UIStatusBar` 自身方法表里存在，见 [capi] `_UIStatusBar(243)`）。
//   在它之后读 `_items` 容器 → 拿到"系统此刻为哪些 item 建了视图"= 系统正在显示谁。
//   ⚠️ 不再用 `viewForIdentifier:`：该 hook 在本固件零回调（整份日志无一条 vfi:）。
- (void)sbs_updateDisplayedItemsWithData:(id)data styleAttributes:(id)sa
                         extraAnimations:(id)ea {
    [self sbs_updateDisplayedItemsWithData:data styleAttributes:sa extraAnimations:ea];
    @try {
        sbs_signalFromBar((id)self, data);          // ① 记录 item 级状态（诊断）
        // ② ⭐ v1.8.4 数据变化 = 状态栏变化信号 → 立刻重算"系统正在显示谁"
        //    ⚠️ 只传原因字符串，**不传任何视图**（见 sbs_fgAddSubview: 的崩溃教训）
        sbs_rescanSchedule(@"data");
    }
    @catch (__unused NSException *e) {}
}

// ⭐⭐⭐ v1.8.4 **真·状态栏变化信号**（许总指正的核心落地）
//   许总原话："你不应该根据图标名称来判断，而是要去监听状态栏的变化信号，
//   像免打扰和定位这种是实时变化的。"
//   实现：给 `_UIStatusBarForegroundView` 挂**视图树变更事件**——
//     `addSubview:` / `insertSubview:atIndex:` / `willRemoveSubview:`
//   系统要显示某图标 → 把它的图标视图加进 fg；不再显示 → 移除。
//   每一次增删都是一次"信号"，我们立刻重算「系统正在显示谁」。
//   ⚠️⚠️ v1.8.7 **致命教训**：早期版本把 `(UIView *)self` 传进 `dispatch_async`
//     block → block 捕获这个 fg 视图并在执行时 `objc_retain`。
//     而 `willRemoveSubview:` **会在 fg 自身销毁/被状态栏复用池回收的过程中触发**
//     → retain 一个将死对象 → `EXC_BAD_ACCESS@0x20` → SpringBoard SIGSEGV
//     （2026-10-05 11:11 连崩两次，ellekit 写安全模式标记）。
//     ∴ 现在**绝不捕获任何视图**：只传一个字符串原因，执行时从全局强引用
//     `gActiveFG` 现取 fg 并校验存活（window 非空、未隐藏）。
- (void)sbs_fgAddSubview:(UIView *)v {
    [self sbs_fgAddSubview:v];
    @try { sbs_rescanSchedule(@"add"); } @catch (__unused NSException *e) {}
}
- (void)sbs_fgInsertSubview:(UIView *)v atIndex:(NSInteger)idx {
    [self sbs_fgInsertSubview:v atIndex:idx];
    @try { sbs_rescanSchedule(@"ins"); } @catch (__unused NSException *e) {}
}
- (void)sbs_fgWillRemoveSubview:(UIView *)v {
    [self sbs_fgWillRemoveSubview:v];
    @try { sbs_rescanSchedule(@"rem"); } @catch (__unused NSException *e) {}
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

// ⭐⭐ v1.8.0 辅助 hook 提前安装（本轮最关键修复）
//   教训（2026-10-05 09:30 日志实证）：辅助 hook 原在 sbs_installAux 里安装，而它要等
//   UIScreen 就绪（启动后 ~0.5s）才跑 —— 那时 SB 的状态栏 item 早已创建完毕，hook 装好
//   后再无 canEnableDisplayItem 调用（日志零条）→ 永远拿不到"系统本来是否启用该图标"
//   的 orig 证据，「只放系统不显示的」判定无从下手。
//   修：把 canEnable / item / data 三类 hook 提到 ctor 阶段的 sbs_install 里装，
//   带类等待重试（每 0.1s × 最多 60 次 ≈ 6s），确保赶在状态栏 item 创建之前挂上。
static BOOL gAuxHooksInstalled = NO;
static int  gAuxHookTries = 0;

static void sbs_installAuxHooksEarly(void);

static void sbs_installAuxDataHooks(void) {
    if (!gAuxData) return;
    Class D = objc_getClass("_UIStatusBarData");
    if (!D) return;
    Method m1 = class_getInstanceMethod(D, @selector(applyUpdate:));
    Method m2 = class_getInstanceMethod(D, @selector(_applyUpdate:keys:));
    sbs_auxLogOnce(@"sig:applyUpdate", @"安装③ applyUpdate: 签名 = %s",
                   m1 ? method_getTypeEncoding(m1) : "(无)");
    sbs_auxLogOnce(@"sig:applyUpdateKeys", @"安装③ _applyUpdate:keys: 签名 = %s",
                   m2 ? method_getTypeEncoding(m2) : "(无)");
    if (m2) {
        BOOL ok = SBSHook(D, @selector(_applyUpdate:keys:), SBSHelper.class,
                          @selector(sbs_dataApplyUpdateKeys:keys:));
        sbs_auxLogOnce(@"hook:aug", @"hook _applyUpdate:keys: → %@", ok ? @"已安装" : @"失败");
    }
    if (m1) {
        BOOL ok = SBSHook(D, @selector(applyUpdate:), SBSHelper.class,
                          @selector(sbs_dataApplyUpdate:));
        sbs_auxLogOnce(@"hook:aum", @"hook applyUpdate: → %@", ok ? @"已安装" : @"失败");
    }
}

static void sbs_installAuxHooksEarly(void) {
    if (gAuxHooksInstalled || !gAuxEnabled) return;
    Class IT = objc_getClass("_UIStatusBarItem");
    Class D  = objc_getClass("_UIStatusBarData");
    SEL ce = @selector(canEnableDisplayItem:fromData:);
    Class owner = IT ? sbs_findDefiner(ce, "B32@0:8@16@24") : nil;
    if (!owner || !IT || !D) {
        if (gAuxHookTries == 0)
            sbs_auxLogOnce(@"early-wait",
                @"辅助 hook 早期安装：等待类就绪（canEnable 实现类=%@ item=%@ data=%@）",
                owner ? NSStringFromClass(owner) : @"无", IT ? @"有" : @"无", D ? @"有" : @"无");
        if (gAuxHookTries++ < 60)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ sbs_installAuxHooksEarly(); });
        else
            sbs_auxLogOnce(@"early-fail", @"辅助 hook 早期安装失败：类等待超时（%d 次）", gAuxHookTries);
        return;
    }
    gAuxHooksInstalled = YES;
    BOOL ok1 = SBSHook(owner, ce, SBSHelper.class, @selector(sbs_canEnableDisplayItem:fromData:));
    BOOL ok2 = SBSHook(IT, @selector(viewForIdentifier:), SBSHelper.class,
                       @selector(sbs_viewForIdentifier:));
    BOOL ok3 = SBSHook(IT, @selector(createDisplayItemForIdentifier:), SBSHelper.class,
                       @selector(sbs_createDisplayItemForIdentifier:));
    sbs_installAuxDataHooks();
    // ⭐⭐⭐ v1.8.1 真·信号源钩子：`_UIStatusBar` 的显示决策入口。
    //   装不上也要把**真实签名**打进日志（方便下一轮定位）——故先读 encoding 再挂。
    Class Bar = objc_getClass("_UIStatusBar");
    SEL uds = @selector(_updateDisplayedItemsWithData:styleAttributes:extraAnimations:);
    Method mud = Bar ? class_getInstanceMethod(Bar, uds) : NULL;
    sbs_auxLogOnce(@"sig:hook-enc",
        @"信号钩子 _updateDisplayedItemsWithData:styleAttributes:extraAnimations: 签名=%s 目标类=%@",
        mud ? method_getTypeEncoding(mud) : "(无)", Bar ? @"有" : @"无");
    BOOL ok4 = SBSHook(Bar, uds, SBSHelper.class,
                       @selector(sbs_updateDisplayedItemsWithData:styleAttributes:extraAnimations:));
    sbs_auxLogOnce(@"sig:hook",
        @"信号源 hook _updateDisplayedItemsWithData:... → %@", ok4 ? @"已安装" : @"失败/签名不符");
    sbs_auxLogOnce(@"early-ok",
        @"安装①②③④ 辅助 hook 早期安装完成 canEnable=%@ item=%@/%@ 信号源=%@（第 %d 次尝试）",
        ok1 ? @"已安装" : @"失败", ok2 ? @"1" : @"0", ok3 ? @"1" : @"0",
        ok4 ? @"已安装" : @"失败", gAuxHookTries);
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

// ⭐ v1.8.0 App 前台兜底扫描（许总需求④：主屏 + App 内都要显示）。
//   根因（2026-10-05 09:45 日志实证）：进入 App 后主屏 fg 被摘窗（`布局拒绝 win=nil
//   fgW=430`），而 App 内的状态栏 fg 挂在 SBMainSwitcherWindow 上、其首次布局早于 hook
//   安装 → 两条路径都不会触发我们的布局 → App 内条消失。
//   修：主动遍历 SB 的窗口，在 MainSwitcher 窗口里找回 fg 并触发布局。
static void sbs_scanMainSwitcherFG(void) {
    if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) return;
    Class FGC = objc_getClass("_UIStatusBarForegroundView");
    if (!FGC) return;
    @try {
        NSArray *wins = [[UIApplication sharedApplication] windows];
        // ⭐ 取证①：SB 窗口清单（架构真相：类名/隐藏/尺寸/层级/透明度）
        //   ⚠️ 不截断：分段打印（App 前台时真正的状态栏窗口可能排在数组后段）
        NSMutableArray<NSString *> *wchunks = [NSMutableArray array];
        NSMutableString *wcur = [NSMutableString string];
        for (UIWindow *w in wins) {
            [wcur appendFormat:@"%@(hid=%d,lv=%.0f,w=%.0f) ", NSStringFromClass(w.class),
                w.isHidden, w.windowLevel, w.bounds.size.width];
            if (wcur.length > 420) { [wchunks addObject:[wcur copy]];
                                     wcur = [NSMutableString string]; }
        }
        if (wcur.length) [wchunks addObject:[wcur copy]];
        NSString *wsig = [NSString stringWithFormat:@"%lu|%@", (unsigned long)wins.count,
                          wchunks.count ? wchunks[0] : @""];
        sbs_auxLogOnce([@"winsn:" stringByAppendingString:wsig],
            @"SB 窗口 %lu 个（%lu 段）", (unsigned long)wins.count,
            (unsigned long)wchunks.count);
        for (NSUInteger ci = 0; ci < wchunks.count; ci++)
            sbs_auxLogOnce([NSString stringWithFormat:@"wins%d:%@", (int)ci, wsig],
                @"SB窗口段%d: %@", (int)ci, wchunks[ci]);
        // ⭐ 取证②：窗口树内所有状态栏相关视图（App 内状态栏的真身在哪）
        NSMutableString *fnd = [NSMutableString string];
        NSMutableArray *all = [NSMutableArray array];
        for (UIWindow *w in wins) [all addObject:w];
        int guard = 0;
        while (all.count && guard++ < 5000) {
            UIView *v = all.lastObject;
            [all removeLastObject];
            NSString *cn = NSStringFromClass(v.class);
            if ([cn containsString:@"UIStatusBar"])
                [fnd appendFormat:@"%@(w=%.0f,win=%@); ", cn, v.bounds.size.width,
                    v.window ? NSStringFromClass(v.window.class) : @"nil"];
            for (UIView *c in v.subviews) [all addObject:c];
        }
        sbs_auxLogOnce([@"sbfind:" stringByAppendingString:fnd],
            @"窗口树内状态栏视图: %@",
            fnd.length ? (fnd.length > 900 ? [fnd substringToIndex:900] : (NSString *)fnd) : @"(无)");
        // ⭐ 原有逻辑：MainSwitcher 窗口里找 fg 并接回
        for (UIWindow *w in wins) {
            NSString *cn = NSStringFromClass(w.class);
            if (![cn containsString:@"MainSwitcher"]) continue;
            if (w.isHidden) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:(id)w];
            while (stack.count) {
                UIView *v = stack.lastObject;
                [stack removeLastObject];
                if ([v isKindOfClass:FGC]) {
                    if (v.bounds.size.width > 0) {
                        gActiveFG = v;
                        [sbs_seenFGs() addObject:v];
                        gAuxForceRelayout = YES;
                        NSMutableString *sv = [NSMutableString string];
                        for (UIView *c in v.subviews)
                            [sv appendFormat:@"%@(%.0f) ", NSStringFromClass(c.class),
                                c.bounds.size.width];
                        sbs_auxLogOnce([NSString stringWithFormat:@"msw:%@", cn],
                            @"App 内扫描：MainSwitcher(%@) 中找到 fg=%p fgW=%.0f live=%d 子视图=[%@] → 触发布局",
                            cn, v, v.bounds.size.width, sbs_fgIsLive(v) ? 1 : 0,
                            sv.length > 300 ? [sv substringToIndex:300] : (NSString *)sv);
                        sbs_auxLayoutInFG(v);
                    }
                    return;
                }
                for (UIView *c in v.subviews) [stack addObject:c];
            }
        }
    } @catch (__unused NSException *e) {}
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
                // ⭐ v1.8.0 App 前台兜底：无条件扫描（函数内按窗口签名去重，只在架构变化时直写），
                //    避免"自愈把条挂到 UIStatusBarWindow 里不可见的 fg"时永远不触发。
                sbs_scanMainSwitcherFG();
                // ⭐ v1.8.4 每秒巡检一次「系统正在显示谁」—— 事件驱动之外的兜底，
                //    保证任何漏掉变化事件的情况下，抑制状态最多 1 秒内收敛。
                sbs_rescanSchedule(@"tick");
                sbs_colorTick();          // ⭐ v1.8.0 配色巡检（每秒，值变化才写）
            } @catch (__unused NSException *e) {}
        });
        dispatch_resume(gHealTimer);
        sbs_auxLogOnce(@"heal", @"自愈计时器已启动（1s 间隔）");
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
    sbs_auxLogOnce([@"sys:" stringByAppendingString:key],
        @"捕获系统图 %@ ← %@ %.0fx%.0f pt", key,
        NSStringFromClass(v.class), img.size.width, img.size.height);
    // 已建条 → 立即换上系统图（未建条时 sbs_auxEnsureCreated 会优先用捕获图）
    UIImageView *iv = gAuxViews ? gAuxViews[key] : nil;
    if (iv && iv.image != img) {
        iv.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
}

static UIImage *sbs_auxImage(NSString *ident) {
    NSString *lk = ident.lowercaseString;
    // ⭐ v1.4.2 优先级 1：系统自己渲染的同款图（viewForIdentifier: 捕获）
    if (gSysImages) {
        UIImage *sys = gSysImages[lk];
        if (sys) {
            sbs_auxLogOnce([@"img:" stringByAppendingString:lk],
                @"图标 %@ ← 系统捕获图 %.0fx%.0f", ident, sys.size.width, sys.size.height);
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
            if (im) {
                sbs_auxLogOnce([@"img:" stringByAppendingString:lk],
                    @"图标 %@ ← car:%@", ident, n);
                return im;
            }
        }
    }
    if (sf) {
        UIImage *im = [UIImage systemImageNamed:sf];
        if (im) {
            sbs_auxLogOnce([@"img:" stringByAppendingString:lk],
                @"图标 %@ ← SF Symbol:%@", ident, sf);
            return im;
        }
    }
    sbs_auxLogOnce([@"img:" stringByAppendingString:lk],
        @"图标 %@ ← 加载失败（捕获图/Assets.car/SF 全部无图）", ident);
    return nil;
}

// 建条：全局只建一次（不挂载——宿主 fg 或其父容器由布局按灵动岛位置决定）
static void sbs_auxEnsureCreated(void) {
    if (!gAuxEnabled || !gAuxIcons.count || gStrip) return;
    CGFloat isz = sbs_auxIconSize();
    gStrip = [[UIView alloc] initWithFrame:CGRectZero];
    gStrip.userInteractionEnabled = NO;
    gStrip.backgroundColor = nil;
    // ⭐ v1.8.0 调试红底：条红底 —— 肉眼判定"条是否真的渲染在屏上"
    if (gAuxDebug) {
        gStrip.backgroundColor = [UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:1.0];
        gStrip.clipsToBounds = NO;
    }
    gAuxViews = [NSMutableDictionary dictionary];
    gAuxKeys  = [NSMutableDictionary dictionary];
    CGFloat x = 0;
    for (NSString *ident in gAuxIcons) {
        UIImage *im = sbs_auxImage(ident);
        UIImageView *iv = [[UIImageView alloc] initWithFrame:
            CGRectMake(x, 0, isz, isz)];
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
        x += isz + gAuxGap;
    }
    // ⭐ v1.8.0 直写（原走 sbs_log，设备 verbose=false 时完全不可见）
    sbs_auxLogOnce(@"created", @"条已创建 icons=%lu 图标边长=%.2fpt (基准%.1f × 缩放%.2f) 间距=%.1f",
                   (unsigned long)gAuxViews.count, isz, gAuxBaseSize, gAuxScale, gAuxGap);
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
// ⭐ v1.9.1 探针：把「贡献 timeMaxX 的那个 StringView」带出来。
//   背景（2026-10-06 日志实证）：同一台机同一个"时间"，timeMaxX 在
//   52.8 / 94.7 / 95.0 / 104.7 之间漂移 —— 说明基准不是稳定的"时间右缘"，
//   而是"fg 直接子视图里所有可见 StringView 的最大右缘"。谁是那个视图必须可观测。
static CGFloat sbs_timeMaxXDbg(UIView *fg, UIView **outBest, CGRect *outRect) {
    CGFloat mx = 0; UIView *best = nil; CGRect bestR = CGRectZero;
    for (UIView *v in fg.subviews) {
        NSString *cn = NSStringFromClass(v.class);
        if ([cn containsString:@"StringView"] && !v.hidden) {
            CGRect f = [v convertRect:v.bounds toView:fg];
            if (CGRectGetMaxX(f) > mx) { mx = CGRectGetMaxX(f); best = v; bestR = f; }
        }
    }
    if (outBest) *outBest = best;
    if (outRect) *outRect = bestR;
    return mx;
}

// ⭐⭐ v1.9.1 探针（许总铁律：先取证再改逻辑）：列出 fg 子树内**所有当前带非单位变换**
//   的视图 —— 即"此刻屏幕上到底有什么被缩过"。带实例地址，用于识别状态栏 item 视图
//   是否被系统复用池回收后拿去渲染了别的 item（ReusePool 真实存在：SBStatusBarReusePoolWindow）。
static void sbs_collectScaled(UIView *v, int depth, NSMutableString *o, int *n) {
    if (!v || depth > 5) return;
    CGAffineTransform t = v.transform;
    if (fabs(t.a - 1.0) > 0.001 || fabs(t.d - 1.0) > 0.001) {
        (*n)++;
        [o appendFormat:@"\n      %s %p a=%.3f d=%.3f tx=%.1f ty=%.1f f=%@ hid=%d sup=%s",
            class_getName(v.class), (__bridge void *)v, t.a, t.d, t.tx, t.ty,
            NSStringFromCGRect(v.frame), v.hidden,
            v.superview ? class_getName(v.superview.class) : "nil"];
    }
    for (UIView *s in v.subviews) sbs_collectScaled(s, depth + 1, o, n);
}

static void sbs_dumpScaled(UIView *fg, NSString *by) {
    if (!gDiag || !fg) return;
    NSMutableString *o = [NSMutableString string];
    int n = 0;
    sbs_collectScaled(fg, 0, o, &n);
    // ⭐ 变更即记 + 60s 心跳（本项目教训：任何"每次布局都写"的探针都会变成日志泛洪，
    //    旧版 `巡检tick` 曾 2 行/秒 ≈ 23 万行/天）。此探针只在集合真正变化时落盘。
    NSString *sig = [NSString stringWithFormat:@"%d|%@", n, o];
    static NSString *lastSig = nil;
    static NSTimeInterval lastT = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    BOOL changed = ![sig isEqualToString:lastSig];
    if (!changed && now - lastT < 60.0) return;
    lastSig = sig;                                // ARC：static 强引用自动持有
    lastT = now;
    sbs_logNow(@"[scaled] 触发=%@ win=%@ fgW=%.0f 带变换视图 %d 个:%@",
        by, fg.window ? NSStringFromClass(fg.window.class) : @"nil",
        fg.bounds.size.width, n, o.length ? (NSString *)o : @" (无)");
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

// ⭐ v1.9.2 leading 撤销：候选集会随布局变化（时间的宽度/位置一变，区间左右边界就变），
//   而 transform 是黏在视图对象上的 —— 不再命中的必须还原，否则「该缩的不缩、
//   不该缩的一直缩」；同时防「视图被复用池拿去渲染别的 item 后仍带着 0.504」。
//   与主缩放一致：连续 SBS_RV_GRACE 秒脱离候选集才还原（防边界抖动导致来回闪）。
static void sbs_leadRevalidate(UIView *fg, NSArray<UIView *> *cands, CGAffineTransform lt) {
    if (!gManagedLead || gManagedLead.count == 0) return;
    static NSMutableDictionary *stamp = nil;      // 视图地址 → 首次脱离候选集时刻
    if (!stamp) stamp = [NSMutableDictionary dictionary];
    if (stamp.count > 400) [stamp removeAllObjects];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSHashTable *hit = [NSHashTable weakObjectsHashTable];
    for (UIView *v in cands) [hit addObject:v];
    for (UIView *v in gManagedLead.allObjects) {
        NSString *k = [NSString stringWithFormat:@"%p", (__bridge void *)v];
        BOOL inFG = (v == fg || [v isDescendantOfView:fg]);
        if (inFG && [hit containsObject:v]) { [stamp removeObjectForKey:k]; continue; }
        // ⚠️ 不按 window/hidden 还原：App 前台时主屏 fg 被系统摘窗（实测 window=nil），
        //    据此还原会让 leading 图标反复"还原→重缩"（22:52:25→35 实测 10s 一次闪烁）。
        //    只有「仍在同一 fg 子树内、却持续脱离候选集」才还原 —— 被复用/被搬走必然先脱离候选集。
        if (!inFG) continue;                      // 属于别的 fg → 由那个 fg 处理
        if (v.bounds.size.width <= 0.5) continue; // 布局尚未完成，本轮不判
        NSNumber *f = stamp[k];
        if (!f) { stamp[k] = @(now); continue; }  // 首轮脱离 → 宽限
        if (now - f.doubleValue < SBS_RV_GRACE) continue;
        [stamp removeObjectForKey:k];
        [gManagedLead removeObject:v];            // 先摘登记再还原
        if (CGAffineTransformEqualToTransform(v.transform, lt))
            v.transform = CGAffineTransformIdentity;
        sbs_logNow(@"[leadUndo] %s %p → 还原（持续脱离候选集 %.1fs）",
                   class_getName(v.class), (__bridge void *)v, SBS_RV_GRACE);
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
    UIView *timeV = nil; CGRect timeR = CGRectZero;
    CGFloat timeMaxX = sbs_timeMaxXDbg(fg, &timeV, &timeR);
    // ⭐ v1.9.1 基准取证：把"谁是时间基准"直写出来（许总可核对）
    sbs_leadNote([NSString stringWithFormat:@"base:%p:%.0f", (void *)timeV, timeMaxX],
        [NSString stringWithFormat:@"时间基准 %p %s f=%@ maxX=%.1f win=%@",
         (void *)timeV, timeV ? class_getName(timeV.class) : "nil",
         NSStringFromCGRect(timeR), timeMaxX,
         fg.window ? NSStringFromClass(fg.window.class) : @"nil"]);
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
    sbs_leadRevalidate(fg, cands, lt);    // ⭐ v1.9.2 撤销：脱离候选集的还原
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

// ⭐⭐⭐ v1.8.1 信号源实现（许总指正后新增）
// ---------------------------------------------------------------------------
// 把任意"标识对象"转成可读字符串（`_UIStatusBarItem.identifier` 是 `_UIStatusBarIdentifier`
// 之类的私有对象，description 形如 `<...: object=_UIStatusBarIndicatorLocationItem>`）。
static NSString *sbs_identString(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    for (NSString *k in (@[@"identifier", @"itemIdentifier", @"_identifier", @"name"])) {
        @try {
            id v = [obj valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return (NSString *)v;
        } @catch (__unused NSException *e) {}
    }
    NSString *d = nil;
    @try { d = [obj description]; } @catch (__unused NSException *e) {}
    if (!d.length) return nil;
    NSRange r = [d rangeOfString:@"item="];
    if (r.location != NSNotFound) {
        NSString *t = [d substringFromIndex:r.location + 5];
        NSRange end = [t rangeOfCharacterFromSet:
                       [NSCharacterSet characterSetWithCharactersInString:@";> "]];
        if (end.location != NSNotFound) t = [t substringToIndex:end.location];
        return t.length ? t : nil;
    }
    return d;
}

// ⭐⭐⭐ v1.8.1 真·item 身份判定：**用 item 的类名**（唯一稳定标识）。
//   探针实证（2026-10-05）：`_UIStatusBar._items` 的 value 是 `_UIStatusBarItem` 子类，
//   类名直接就是 item 身份：`_UIStatusBarIndicatorLocationItem` / `..AlarmItem` /
//   `..QuietModeItem` / `..RotationLockItem` / `_UIStatusBarBluetoothItem` /
//   `..AirplaneModeItem` / `_UIStatusBarIndicatorVPNItem`。
static NSString *sbs_itemIdentFromClass(NSString *cls) {
    if (!cls.length) return nil;
    static NSDictionary *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{
            @"_UIStatusBarIndicatorAlarmItem":        @"alarm",
            @"_UIStatusBarIndicatorLocationItem":     @"location",
            @"_UIStatusBarIndicatorQuietModeItem":    @"quietmode",
            @"_UIStatusBarIndicatorRotationLockItem": @"rotationlock",
            @"_UIStatusBarIndicatorVPNItem":          @"vpn",
            @"_UIStatusBarBluetoothItem":             @"bluetooth",
            @"_UIStatusBarIndicatorAirplaneModeItem": @"airplane",
        };
    });
    return m[cls];
}

// display item 的视图（`_UIStatusBarDisplayItem._view`）
static UIView *sbs_displayItemView(id di) {
    if (!di) return nil;
    for (NSString *k in (@[@"_view", @"view"])) {
        @try {
            id v = [di valueForKey:k];
            if ([v isKindOfClass:[UIView class]]) return (UIView *)v;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

// ⭐⭐⭐ v1.8.2 某 item 是否"正被系统显示"（**真信号判据**）
//   探针实证（2026-10-05 10:58，崩溃前已取到字段面）：
//     `_UIStatusBarItem ivars(4)`: _needsUpdate _identifier **_displayItems** _statusBar
//       → item 上**没有 view**（旧实现读 item.view 恒 nil → 信号集恒空，这才是
//         "信号源没工作"的真相，而不是 hook 没挂上）
//     `_UIStatusBarDisplayItem ivars(32)`: **_enabled(B)** **_dynamicallyHidden(B)**
//       **_view** _item _identifier _alpha _viewAlpha …
//   判据：该 item 的任一 display item 满足 `_enabled==YES && _dynamicallyHidden==NO`
//         → 系统此刻正在状态栏显示它。
//   ⚠️ 全程 @try 包裹 + 只用 KVC（绝不 object_getIvar 取非对象 ivar ——
//      10:58 的 SpringBoard SIGSEGV 就是把 double/bool ivar 当对象 retain 造成的）。
static BOOL sbs_itemIsDisplayed(id item, NSMutableString *detail) {
    if (!item) return NO;
    id dis = nil;
    @try { dis = [item valueForKey:@"_displayItems"]; } @catch (__unused NSException *e) {}
    if (![dis isKindOfClass:[NSDictionary class]]) return NO;
    BOOL any = NO;
    NSUInteger i = 0;
    for (id dk in (NSDictionary *)dis) {
        id di = [(NSDictionary *)dis objectForKey:dk];
        BOOL en = NO, dyn = NO;
        @try { en  = [[di valueForKey:@"_enabled"] boolValue]; } @catch (__unused NSException *e) {}
        @try { dyn = [[di valueForKey:@"_dynamicallyHidden"] boolValue]; } @catch (__unused NSException *e) {}
        UIView *v = sbs_displayItemView(di);
        BOOL vis = v && v.window && !v.isHidden && v.alpha > 0.01 && v.frame.size.width > 0.5;
        if (detail && i < 6)
            [detail appendFormat:@"[%@ en=%d dyn=%d v=%d vis=%d]", sbs_identString(dk) ?: @"?", en, dyn, v ? 1 : 0, vis];
        if (en && !dyn) any = YES;
        i++;
    }
    return any;
}

// ⭐⭐⭐ v1.8.4 从 `_UIStatusBar` 的 item 容器记录 item 级状态（**仅诊断**）。
//   探针已证（2026-10-05 11:02）：`_UIStatusBarItem` 的 `_displayItems` 里视图是
//   **预建的**（frame 0x0 / win=nil / en=0，7 个候选全一样）→ item 内部状态
//   区分不出"系统到底显示没显示"。故本函数只把事实记进日志，**不再据此发布抑制表**；
//   真正的判据交给 `sbs_rescanFG`（视图树是否真的挂了该图标视图）。
static void sbs_signalFromBar(id bar, id data) {
    if (!bar) return;
    NSMutableString *detail = [NSMutableString string];
    id items = nil;
    @try { items = [bar valueForKey:@"_items"]; } @catch (__unused NSException *e) {}
    NSUInteger itemCount = [items respondsToSelector:@selector(count)] ? [items count] : 0;
    NSUInteger displayItemCount = 0;
    if ([items isKindOfClass:[NSDictionary class]]) {
        for (id key in (NSDictionary *)items) {
            id item = [(NSDictionary *)items objectForKey:key];
            NSString *cls = item ? NSStringFromClass([item class]) : nil;
            NSString *ident = sbs_itemIdentFromClass(cls);
            id dis = nil;
            @try { dis = [item valueForKey:@"_displayItems"]; } @catch (__unused NSException *e) {}
            if ([dis respondsToSelector:@selector(count)]) displayItemCount += [dis count];
            if (!ident) continue;
            NSMutableString *dsub = [NSMutableString string];
            BOOL en = sbs_itemIsDisplayed(item, dsub);
            [detail appendFormat:@"%@=%d ", ident, en ? 1 : 0];
            if (dsub.length)
                sbs_auxLogOnce([@"dl:" stringByAppendingString:ident],
                    @"displayItems 明细 %@：%@", ident, dsub);
        }
    }
    sbs_auxLogOnce([NSString stringWithFormat:@"itemstat:%lu:%@", (unsigned long)itemCount,
                    detail],
        @"【item状态】_items=%lu _displayItems=%lu data=%@ ｜ %@",
        (unsigned long)itemCount, (unsigned long)displayItemCount,
        data ? NSStringFromClass([data class]) : @"nil", detail);
}

// ⭐⭐⭐ v1.8.4 实时重算「系统正在显示哪些候选图标」——扫描 fg 视图树里**真正可见**的图标视图。
//   · 判据：图标视图已挂窗口、未隐藏、alpha>0、尺寸>0.5，且其图像标识名命中候选关键词。
//   · 巡检健康 = fg 内存在时间文字/电池视图（说明这棵 fg 是"活的、已渲染完"的），
//     不健康则只加不减（防过渡态误撤）。
static BOOL gInRescan = NO;
static void sbs_rescanFG(UIView *fg, NSString *why) {
    if (!fg || gInRescan) return;
    gInRescan = YES;
    NSMutableSet *names = [NSMutableSet set];
    BOOL healthy = NO;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:fg];
    int guard = 0;
    while (stack.count && guard++ < 600) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v == gStrip) continue;
        NSString *cn = NSStringFromClass(v.class);
        if ([cn containsString:@"Battery"] || [cn containsString:@"StringView"]) healthy = YES;
        if ([v isKindOfClass:[UIImageView class]]) {
            UIImageView *iv = (UIImageView *)v;
            // ⭐ v1.8.4 判据放宽（关键修正）：**不做 window 判定**。
            //   实测（11:05:40）：视图刚 addSubview 时 frame=0×0、window=nil，
            //   而 layout 稍后才赋 frame —— 用 window/尺寸过滤会把"刚加进来的图标"
            //   全部滤掉 → 信号集恒空（这正是本轮信号源仍不工作的原因）。
            //   改为：在 fg 树内 + 未隐藏 + alpha>0 + 有尺寸（尺寸在 0.25s 后的
            //   二次巡检时已就绪；首次巡检若尺寸为 0 也不影响，第二次能补上）。
            if (!iv.isHidden && iv.alpha > 0.01) {
                NSString *ni = nil;
                @try { ni = iv.image.accessibilityIdentifier; } @catch (__unused NSException *e) {}
                if (!ni.length)
                    @try { ni = iv.accessibilityIdentifier; } @catch (__unused NSException *e) {}
                if (ni.length) [names addObject:[ni lowercaseString]];
            }
        }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
    NSMutableSet *now = [NSMutableSet set];
    for (NSString *ident in gAuxIcons) {
        NSString *k = ident.lowercaseString;
        for (NSString *kw in sbs_auxKeyWords(k))
            for (NSString *n in names)
                if ([n containsString:kw]) {
                    [now addObject:k];
                    [sbs_sysNameHit() addObject:k];    // 命中留痕（日志追溯用，不参与判定）
                    break;
                }
    }
    {
        NSString *namesStr = [[names.allObjects sortedArrayUsingSelector:@selector(compare:)]
                              componentsJoinedByString:@","];
        NSString *hitStr = now.count ? [[now.allObjects sortedArrayUsingSelector:@selector(compare:)]
                                        componentsJoinedByString:@","] : @"(无)";
        // ⭐ v1.8.13 二审：v1.8.12 只去掉 namesStr 仍然泛洪 —— 实测 60 s 窗口
        //   `巡检tick`/`巡检tick+` 各 55 行，且**状态字段完全一致**（location/1）。
        //   真因：`stateKey` 里还带着 `why`，而一次巡检会被 `sbs_rescanSchedule`
        //   拆成「立即(tick) + 0.25s 后(tick+)」两次 ⇒ 两个 key 永远互不相等
        //   ⇒ 每次都判为"跃迁"，20s 心跳形同虚设。
        //   再加两道保险（对 healthy/hitStr 在过渡帧抖动的场景也免疫）：
        //     ① stateKey 彻底不含 `why`（只留判决量 hitStr:healthy，why 仅进正文）；
        //     ② **只记录权威那一遍**（调度器的第二遍，why 以 '+' 结尾）——
        //        第一遍是为"尽早发布抑制"服务的过渡取样，不应作为状态证据。
        if ([why hasSuffix:@"+"]) {
            sbs_auxLogState(@"scan",
                [NSString stringWithFormat:@"%@:%d", hitStr, healthy ? 1 : 0],
                @"巡检%@ 可见图标标识名=%@ 候选命中=%@ 健康=%d（名扫描仅核对，判定走 item 信号）",
                why ?: @"?", namesStr.length ? namesStr : @"(空)", hitStr, healthy ? 1 : 0);
        }
    }
    sbs_publishRescan(now, healthy, why);
    gInRescan = NO;
}

static int gRescanScheduled = 0;

// ⭐ v1.8.7 执行时从全局强引用 `gActiveFG` 现取 fg 并校验存活 —— 绝不在 block 里捕获视图。
static void sbs_rescanActive(NSString *why) {
    UIView *fg = gActiveFG;
    if (!fg || !fg.window || fg.isHidden) return;
    sbs_rescanFG(fg, why);
}

static void sbs_rescanSchedule(NSString *why) {
    if (gRescanScheduled) return;
    gRescanScheduled = 1;
    NSString *w = [why copy] ?: @"?";
    // ⭐ v1.8.4 两段式：立即一次（图已进树）+ 0.25s 后再一次（frame 已就绪）。
    //   实测依据：addSubview 时 frame=0×0/window=nil，布局完成后才有尺寸与标识名。
    //   ⚠️ block 内**只引用字符串**（w 是常量/拷贝），不引用任何 UIView → 无生命周期风险。
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { sbs_rescanActive(w); } @catch (__unused NSException *e) {}
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try { sbs_rescanActive([w stringByAppendingString:@"+"]); }
        @catch (__unused NSException *e) {}
        gRescanScheduled = 0;
    });
}

// ⭐ v1.8.1 一次性信号容器探针：把「信号源到底能不能用」的证据一次性打全。
//   （许总铁律：改逻辑前先取日志证据；这是取证步骤，不做任何显示写入）
static void sbs_probeSignal(UIView *fg) {
    static BOOL done = NO;
    if (done || !fg) return;
    done = YES;
    // 找 `_UIStatusBar`（fg 的父层里）
    id bar = nil;
    UIView *v = fg;
    for (int i = 0; i < 4 && v; i++) {
        if ([NSStringFromClass(v.class) isEqualToString:@"_UIStatusBar"]) { bar = v; break; }
        v = v.superview;
    }
    if (!bar) { sbs_auxLogOnce(@"psig:nobar", @"信号探针：未找到 _UIStatusBar"); return; }
    // ① 信号源容器的真实内容（遍历前 14 个 item 的完整字段）
    id items = nil;
    @try { items = [bar valueForKey:@"_items"]; } @catch (__unused NSException *e) {}
    sbs_auxLogOnce(@"psig:items",
        @"信号探针 _items 类型=%@ count=%lu",
        items ? NSStringFromClass([items class]) : @"nil",
        (unsigned long)([items respondsToSelector:@selector(count)] ? [items count] : 0));
    if ([items isKindOfClass:[NSDictionary class]]) {
        NSUInteger i = 0;
        for (id key in (NSDictionary *)items) {
            id item = [(NSDictionary *)items objectForKey:key];
            UIView *iv = nil;
            @try { id vv = [item valueForKey:@"view"];
                   if ([vv isKindOfClass:[UIView class]]) iv = vv; } @catch (__unused NSException *e) {}
            sbs_auxLogOnce([NSString stringWithFormat:@"psig:i%lu", (unsigned long)i],
                @"信号探针 item[%lu] key=<%@> keyCls=%@ ident=%@ itemCls=%@ viewCls=%@ "
                @"win=%@ hid=%d a=%.2f f=%@ sup=%@",
                (unsigned long)i, [key description], NSStringFromClass([key class]),
                sbs_identString(key) ?: @"(nil)",
                item ? NSStringFromClass([item class]) : @"nil",
                iv ? NSStringFromClass([iv class]) : @"nil",
                iv.window ? NSStringFromClass([iv.window class]) : @"nil",
                iv ? iv.isHidden : -1, iv ? iv.alpha : -1.0,
                iv ? NSStringFromCGRect(iv.frame) : @"-",
                iv ? NSStringFromClass([iv.superview class]) : @"-");
            if (++i >= 14) { sbs_auxLogOnce(@"psig:more", @"信号探针 item 列表截断于 14"); break; }
        }
    }
    // ② `_UIStatusBarItem` 的字段面（判断有没有更直接的"是否显示"标志）
    Class IC = objc_getClass("_UIStatusBarItem");
    if (IC) {
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList(IC, &n);
        NSMutableString *o = [NSMutableString string];
        for (unsigned int j = 0; j < n; j++)
            [o appendFormat:@"%s(%s) ", ivar_getName(ivs[j]), ivar_getTypeEncoding(ivs[j])];
        free(ivs);
        sbs_auxLogOnce(@"psig:itemivars", @"_UIStatusBarItem ivars(%u): %@", n, o);
    }
    // ③ `_UIStatusBarData` 的属性面（确认 Entry 命名，供 §状态源 对齐）
    Class DC = objc_getClass("_UIStatusBarData");
    if (DC) {
        unsigned int pn = 0;
        objc_property_t *ps = class_copyPropertyList(DC, &pn);
        NSMutableString *o = [NSMutableString string];
        for (unsigned int j = 0; j < pn && j < 120; j++) {
            const char *nm = property_getName(ps[j]);
            NSString *ns = nm ? @(nm) : @"?";
            if ([ns rangeOfString:@"Entry"].location != NSNotFound)
                [o appendFormat:@"%s ", nm];
        }
        free(ps);
        sbs_auxLogOnce(@"psig:dataProps", @"_UIStatusBarData 属性(%u) 含 Entry 者: %@", pn, o);
    }
    // ④ `_updateDisplayedItemsWithData:...` 是否真的会被调用（本探针只报"签名+存在性"，
    //    是否触发由信号日志的 #计数 证明）
    Method mud = class_getInstanceMethod([bar class],
        @selector(_updateDisplayedItemsWithData:styleAttributes:extraAnimations:));
    sbs_auxLogOnce(@"psig:udenc", @"显示决策方法签名=%s（类=%@）",
        mud ? method_getTypeEncoding(mud) : "(无)", NSStringFromClass([bar class]));
    // ⑤ 真·显示状态容器（v1.8.1 第二轮取证）：
    //    `_UIStatusBarItem` 只有 4 个 ivar，**没有 view** —— item 的显示态在
    //    `_displayItems`（display-identifier → `_UIStatusBarDisplayItem`）；
    //    条上还有 `_displayItemStates`（display-identifier → 状态对象）。
    //    本段把这两处的字段面 + 真实值打全，用于确定"系统正在显示"的判据。
    for (NSString *cn in (@[@"_UIStatusBarDisplayItem", @"_UIStatusBarDisplayItemState"])) {
        Class C = objc_getClass(cn.UTF8String);
        if (!C) { sbs_auxLogOnce([@"psig:no" stringByAppendingString:cn],
                                 @"探针：类 %@ 不存在", cn); continue; }
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList(C, &n);
        NSMutableString *o = [NSMutableString string];
        for (unsigned int j = 0; j < n; j++)
            [o appendFormat:@"%s(%s) ", ivar_getName(ivs[j]), ivar_getTypeEncoding(ivs[j])];
        free(ivs);
        sbs_auxLogOnce([@"psig:iv" stringByAppendingString:cn], @"%@ ivars(%u): %@", cn, n, o);
    }
    // ⑤b 逐 item 报告 `_displayItems` 数量 + 每个 display item 的关键标志
    //    ⚠️⚠️ 绝不能对非对象 ivar 调 object_getIvar（10:58 SpringBoard SIGSEGV 实锤：
    //       `_alpha(d)` 被当指针 `objc_retain` → EXC_BAD_ACCESS@0x3000000000000000）。
    //       只用 KVC 读已知字段，全程 @try。
    if ([items isKindOfClass:[NSDictionary class]]) {
        NSArray *watch = @[@"Alarm", @"Location", @"QuietMode", @"RotationLock",
                           @"VPN", @"Bluetooth", @"AirplaneMode"];
        for (id key in (NSDictionary *)items) {
            id item = [(NSDictionary *)items objectForKey:key];
            NSString *icls = item ? NSStringFromClass([item class]) : @"nil";
            BOOL hit = NO;
            for (NSString *w in watch) if ([icls containsString:w]) { hit = YES; break; }
            if (!hit) continue;
            id dis = nil;
            @try { dis = [item valueForKey:@"_displayItems"]; } @catch (__unused NSException *e) {}
            NSUInteger dc = [dis respondsToSelector:@selector(count)] ? [dis count] : 0;
            NSMutableString *o = [NSMutableString stringWithFormat:@"count=%lu ", (unsigned long)dc];
            if ([dis isKindOfClass:[NSDictionary class]]) {
                NSUInteger j = 0;
                for (id dk in (NSDictionary *)dis) {
                    id di = [(NSDictionary *)dis objectForKey:dk];
                    BOOL en = NO, dyn = NO;
                    @try { en  = [[di valueForKey:@"_enabled"] boolValue]; } @catch (__unused NSException *e) {}
                    @try { dyn = [[di valueForKey:@"_dynamicallyHidden"] boolValue]; } @catch (__unused NSException *e) {}
                    UIView *v = sbs_displayItemView(di);
                    [o appendFormat:@"|%@ en=%d dyn=%d v=%@ hid=%d win=%@ a=%.2f f=%@",
                        sbs_identString(dk) ?: @"?", en, dyn,
                        v ? NSStringFromClass([v class]) : @"nil",
                        v ? v.isHidden : -1,
                        v && v.window ? NSStringFromClass([v.window class]) : @"nil",
                        v ? v.alpha : -1.0,
                        v ? NSStringFromCGRect(v.frame) : @"-"];
                    if (++j >= 6) { [o appendString:@"|…"]; break; }
                }
            }
            sbs_auxLogOnce([@"psig:dis" stringByAppendingString:icls],
                           @"item %@ 的 _displayItems %@", icls, o);
        }
    }
    // ⑤c 条上 `_displayItemStates` 的前 6 个样本（键 = display-identifier）
    id states = nil;
    @try { states = [bar valueForKey:@"_displayItemStates"]; } @catch (__unused NSException *e) {}
    if ([states isKindOfClass:[NSDictionary class]]) {
        NSUInteger i = 0;
        for (id k in (NSDictionary *)states) {
            id v = [(NSDictionary *)states objectForKey:k];
            BOOL de = NO, wv = NO;
            NSString *itemCls = @"?";
            @try { de = [[v valueForKey:@"_dataEnabled"] boolValue]; } @catch (__unused NSException *e) {}
            @try { wv = [[v valueForKey:@"_wasVisible"] boolValue]; } @catch (__unused NSException *e) {}
            @try {
                id it = [v valueForKey:@"_item"];
                if (it) itemCls = NSStringFromClass([it class]);
            } @catch (__unused NSException *e) {}
            sbs_auxLogOnce([NSString stringWithFormat:@"psig:st%lu", (unsigned long)i],
                @"displayItemState[%lu] key=<%@> cls=%@ item=%@ dataEnabled=%d wasVisible=%d",
                (unsigned long)i, [k description],
                v ? NSStringFromClass([v class]) : @"nil", itemCls, de, wv);
            if (++i >= 6) { sbs_auxLogOnce(@"psig:stmore", @"displayItemState 截断于 6"); break; }
        }
    }
}

// ⭐ v1.8.0 一次性深度取证：直写 fg 的 ivar 清单与直接子视图清单。
//   用途：当前"系统显示了哪个 ident"的身份反查三条路全部失败（identifier/item/
//   可访问性），需要从 fg 自身的内部结构里找 ident↔view 的映射线索。
static void sbs_auxDeepProbe(UIView *fg) {
    static BOOL done = NO;
    if (done || !fg) return;
    done = YES;
    @try {
        unsigned int n = 0;
        Ivar *ivs = class_copyIvarList([fg class], &n);
        NSMutableString *o = [NSMutableString stringWithFormat:@"fg=%@ ivars=%u: ",
                              NSStringFromClass([fg class]), n];
        for (unsigned int i = 0; i < n; i++) {
            const char *nm = ivar_getName(ivs[i]);
            const char *tp = ivar_getTypeEncoding(ivs[i]);
            id val = nil;
            // ⚠️ 只对**对象类型** ivar 调 object_getIvar；对 d/B/q 等标量调用会
            //    把数值当指针 retain → EXC_BAD_ACCESS（10:58 SB 崩溃同一根因）
            if (tp && tp[0] == '@')
                @try { val = object_getIvar(fg, ivs[i]); } @catch (__unused NSException *e) {}
            [o appendFormat:@"%s(%s)=%@ ", nm ?: "?", tp ?: "?",
                val ? NSStringFromClass([val class]) : @"nil"];
        }
        free(ivs);
        sbs_auxLogOnce(@"deep:fgivars", @"%@",
                       o.length > 1600 ? [o substringToIndex:1600] : (NSString *)o);
    } @catch (__unused NSException *e) {}
    NSMutableString *s = [NSMutableString string];
    for (UIView *v in fg.subviews)
        [s appendFormat:@"%@%@; ", NSStringFromClass(v.class), NSStringFromCGRect(v.frame)];
    sbs_auxLogOnce(@"deep:fgsubs", @"fg 直接子视图 %lu 个: %@",
                   (unsigned long)fg.subviews.count,
                   s.length > 1600 ? [s substringToIndex:1600] : (NSString *)s);
}

// ⭐⭐ v1.8.0「系统是否已在状态栏显示该图标」的运行时判定（行为证据，非配置证据）。
//   背景（2026-10-05 日志实证）：
//     ① canEnableDisplayItem 的 orig 判据不可用 —— sbs_installAux 装好 hook 时 SB 的
//        状态栏 item 早已创建完毕，canEnable 一次都没被调用（日志零条）；
//     ② CGImage 指针比对也不可用 —— 09:30 实测系统侧明明有 1 个 _UIStatusBarImageView，
//        但指针比对命中 0（同一张 Assets.car 位图会被包成不同 CGImage 实例）。
//   ∴ 改用【像素指纹】比对：取 CGImage 的像素数据前缀 + 宽高做指纹，同一张位图必然相同。
static NSData *sbs_cgFingerprint(CGImageRef cg) {
    if (!cg) return nil;
    CGDataProviderRef dp = CGImageGetDataProvider(cg);
    if (!dp) return nil;
    CFDataRef d = CGDataProviderCopyData(dp);
    if (!d) return nil;
    NSData *all = (__bridge_transfer NSData *)d;
    NSData *px = (all.length > 8192) ? [all subdataWithRange:NSMakeRange(0, 8192)] : all;
    // 宽高编进指纹，避免不同尺寸图像前缀巧合相同造成误判
    uint32_t wh[2] = { (uint32_t)CGImageGetWidth(cg), (uint32_t)CGImageGetHeight(cg) };
    NSMutableData *m = [NSMutableData dataWithCapacity:px.length + 16];
    [m appendBytes:wh length:sizeof(wh)];
    [m appendData:px];
    return m;
}

// 收集 fg 子树内所有图标视图的「标识名」与像素指纹（排除辅助条自身）
static void sbs_collectIconRefs(UIView *v, int depth, NSMutableSet *sysNames,
                                NSMutableArray<NSData *> *fps, NSMutableSet *classes) {
    if (!v || depth < 0) return;
    if (v == gStrip) return;                       // 排除辅助条自身
    if ([v isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)v;
        NSData *fp = sbs_cgFingerprint(iv.image.CGImage);
        if (fp) [fps addObject:fp];
        NSString *cn = NSStringFromClass(v.class);
        if (cn) [classes addObject:cn];
        // ⭐⭐⭐ v1.8.0 身份判定的决定性证据（2026-10-05 09:39 日志实证）：
        //   系统图标的 UIImage 带 accessibilityIdentifier，其值就是图标标识名 ——
        //   实测系统显示的定位图标 = imageIdent「location.fill」（label「定位服务」）。
        //   该命名与 sbs_auxSpec 表里的 SF Symbol 名同源 → 可直接比对判定。
        NSString *ni = nil;
        @try { ni = iv.image.accessibilityIdentifier; } @catch (__unused NSException *e) {}
        if (!ni.length)
            @try { ni = iv.accessibilityIdentifier; } @catch (__unused NSException *e) {}
        if (ni.length) [sysNames addObject:ni];
        sbs_auxLogOnce([NSString stringWithFormat:@"idv:%@:%@:%.0f", cn, ni ?: @"(无)",
                        round(iv.frame.origin.x / 4.0) * 4.0],
            @"系统图标视图 %@ frame=%@ img=%.0fx%.0f@%.0fx 标识名=%@ 指纹=%lu B",
            cn, NSStringFromCGRect(iv.frame), iv.image.size.width, iv.image.size.height,
            iv.image.scale, ni ?: @"(无)", (unsigned long)(fp ? fp.length : 0));
    }
    for (UIView *s in v.subviews) sbs_collectIconRefs(s, depth - 1, sysNames, fps, classes);
}

// 该 ident 是否正被系统显示：按「图标标识名」比对（候选的 car 字形名 + SF Symbol 名都试）
// ⭐⭐ v1.8.0 修正（许总反馈定位图标重复）：系统图标的 accessibilityIdentifier
//   **不是固定值** —— 实测定位图标在 `location.fill` ↔ `location.circle.fill` 之间变化
//   （2026-10-05 10:37 日志：`标识名=location.circle.fill 指纹=5210 B`，
//    而 sbs_auxSpec 只列了 `location.fill` → 精确匹配落空 → 重复显示）。
//   ∴ 增加【关键词包含】匹配（覆盖同族所有变体），精确名比对保留为快速路径。
static NSArray<NSString *> *sbs_auxKeyWords(NSString *ident) {
    NSDictionary *m = @{
        @"alarm":        @[@"alarm"],
        @"location":     @[@"location"],
        @"quietmode":    @[@"quiet", @"moon", @"sleep"],
        @"rotationlock": @[@"rotation"],
        @"vpn":          @[@"vpn"],
        @"bluetooth":    @[@"bluetooth"],
        @"airplane":     @[@"airplane"],
    };
    return m[ident.lowercaseString] ?: @[ident.lowercaseString];
}

// ⭐⭐⭐ v1.8.8 状态栏 **item 级**变化信号（许总要求：不看图标名，看状态栏自己的显示决策）
//   数据源 = `_UIStatusBar._items`（NSArray<_UIStatusBarItem>），每项：
//     · 类名 = 结构身份（与图标字形名无关）：日志已逐一证实 7 个候选的类名 ——
//         _UIStatusBarIndicatorAlarmItem / _UIStatusBarIndicatorRotationLockItem /
//         _UIStatusBarIndicatorLocationItem / _UIStatusBarIndicatorQuietModeItem /
//         _UIStatusBarIndicatorVPNItem / _UIStatusBarIndicatorAirplaneModeItem /
//         _UIStatusBarBluetoothItem
//     · `_displayItems`（dict）→ value = `_UIStatusBarDisplayItem`，其 `_view` 即该 item 的图标视图
//   「系统正在显示该 item」判据 = 存在 displayItem 的视图满足：
//     已挂载（superview 或 window 非空）且未隐藏 且 宽>0.5 且 alpha>0.01。
//   日志对照依据（2026-10-05 11:14）：
//     · 未显示：`…LocationItem en=0 dyn=0 v=_UIStatusBarImageView hid=0 win=nil f={{0,0},{0,0}}`
//     · 显示中：同一 `_UIStatusBarImageView` 出现在 fg 树内且 frame 非零
//   ⇒ 与 `location.fill` / `location.circle.fill` 这类**会变的字形名彻底解耦**。
static NSString *sbs_itemClassToKey(NSString *cls) {
    if (!cls.length) return nil;
    static NSDictionary *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{
            @"_UIStatusBarIndicatorAlarmItem":        @"alarm",
            @"_UIStatusBarIndicatorRotationLockItem": @"rotationlock",
            @"_UIStatusBarIndicatorLocationItem":     @"location",
            @"_UIStatusBarIndicatorQuietModeItem":    @"quietmode",
            @"_UIStatusBarIndicatorVPNItem":          @"vpn",
            @"_UIStatusBarIndicatorAirplaneModeItem": @"airplane",
            @"_UIStatusBarBluetoothItem":             @"bluetooth",
        };
    });
    for (NSString *k in m) if ([cls hasPrefix:k]) return m[k];
    return nil;
}

// ⭐ v1.8.10 宽限表：item 被判定"系统正在显示"的时刻（key→时间戳）。
//   过渡帧会出现 `location=0{v=1(sup)但hidden/alpha}` 的**假阴性**（视图已挂载但被
//   临时置 hidden，随后才移除）→ 若即时采信，辅助条会在这一瞬补出重复图标（闪一下）。
//   ⇒ 判定侧对"刚被判为显示"的 item 保留 1.2s 宽限，只增不减，杜绝闪烁式重复。
static NSMutableDictionary<NSString *, NSNumber *> *gItemShownAt = nil;

// 返回「系统此刻正在显示」的候选键集合；detail 输出逐项证据（供日志）。
static NSSet<NSString *> *sbs_itemShownSet(NSMutableString *detail) {
    NSMutableSet *out = [NSMutableSet set];
    UIView *fg = gActiveFG;
    if (!fg) return out;
    id bar = nil;
    UIView *v = fg;
    for (int i = 0; i < 4 && v; i++) {
        if ([NSStringFromClass(v.class) isEqualToString:@"_UIStatusBar"]) { bar = v; break; }
        v = v.superview;
    }
    if (!bar) { if (detail) [detail appendString:@"(noBar) "]; return out; }
    id raw = nil;
    @try { raw = [bar valueForKey:@"_items"]; } @catch (__unused NSException *e) {}
    // ⚠️ 实测 `_UIStatusBar._items` 的类型**不稳定**：早期启动瞬间是 __NSArrayI，
    //    运行期变成 __NSMutableDictionary（key=_UIStatusBarIdentifier，value=_UIStatusBarItem）。
    //    v1.8.8 首版只判 NSArray → 全部落空成 (noItems)，item 信号一次都没生效。
    //    ⇒ 两种形态都接。
    NSArray *items = nil;
    if ([raw isKindOfClass:[NSArray class]]) items = raw;
    else if ([raw isKindOfClass:[NSDictionary class]]) items = [(NSDictionary *)raw allValues];
    if (!items.count) {
        if (detail) [detail appendFormat:@"(noItems:%@)", raw ? NSStringFromClass([raw class]) : @"nil"];
        return out;
    }
    NSMutableString *dbg = [NSMutableString string];
    for (id item in items) {
        NSString *cls = NSStringFromClass([item class]);
        NSString *key = sbs_itemClassToKey(cls);
        if (!key) continue;
        NSDictionary *dis = nil;
        @try { dis = [item valueForKey:@"_displayItems"]; } @catch (__unused NSException *e) {}
        BOOL shown = NO;
        NSString *ev = @"-";
        if ([dis isKindOfClass:[NSDictionary class]]) {
            for (id dk in dis) {
                id di = dis[dk];
                UIView *dv = sbs_displayItemView(di);
                if (!dv) continue;
                if (dv.superview || dv.window) {
                    // ⭐ v1.8.9 判据修正（实测 11:24:09.808 `location=0{v=1(sup)未可见}`）：
                    //   过渡帧里视图**已挂载但 frame 仍为 0** —— 若把"宽>0.5"写进判据，
                    //   该瞬间会判成"系统没显示" → 辅助条补一个 location → **闪一下的重复**。
                    //   实测未显示的 item 其 displayItem._view 直接为 nil（`alarm=0{-}`），
                    //   ∴ **"已挂载"本身就是充分判据**；尺寸只写进证据串。
                    if (!dv.isHidden && dv.alpha > 0.01) {
                        shown = YES;
                        ev = [NSString stringWithFormat:@"sup=%@ win=%@ f=%@",
                              dv.superview ? NSStringFromClass(dv.superview.class) : @"nil",
                              dv.window ? NSStringFromClass(dv.window.class) : @"nil",
                              NSStringFromCGRect(dv.frame)];
                        break;
                    }
                    if ([ev isEqualToString:@"-"]) ev = @"v=1(sup)但hidden/alpha";
                }
            }
        }
        [dbg appendFormat:@"%@=%d{%@} ", key, shown ? 1 : 0, ev];
        if (shown) {
            [out addObject:key];
            if (!gItemShownAt) gItemShownAt = [NSMutableDictionary dictionary];
            gItemShownAt[key] = @([NSDate date].timeIntervalSince1970);   // ⭐ 宽限打点
        }
    }
    if (detail) [detail appendString:dbg.length ? dbg : @"(none)"];
    return out;
}

// ⛔ v1.8.4 删除 `sbs_identShownBySystem`：许总明确指出「不应该根据图标名称来判断」。
//    它的角色已由 `sbs_rescanFG`（视图树变化信号）完全取代 —— 后者虽然也要读
//    图像标识名来做**身份映射**（这是无法回避的：得知道屏幕上那个图标是哪一个候选），
//    但判定依据是"该视图此刻真的挂在状态栏视图树上"，而不是"名字对得上就永久抑制"。
//    旧函数的问题是把"名字命中"记忆化 → 与实时状态脱钩（定位图标重复的元凶之一）。

// 读 _UIStatusBarData 各 Entry → 驱动图标显隐
// ⭐ 被动式：只在 hidden 值真正变化时才写 iv.hidden（防止写操作触发重布局 → 循环）
static void sbs_auxRefresh(void) {
    if (!gAuxEnabled || !gAuxViews.count) return;
    id data = sbs_gData();
    if (!data) {
        // ⭐ v1.8.0 直写：data 为空 = "条不显示"的头号原因（状态源根本没捕获到）
        sbs_auxLogOnce(@"noData", @"刷新跳过：_UIStatusBarData 尚未捕获（data=nil）");
        return;
    }
    sbs_auxLogOnce(@"dataOK", @"状态源已捕获 data=%@", NSStringFromClass([data class]));
    for (NSString *ident in gAuxViews) {
        UIImageView *iv = gAuxViews[ident];
        id entry = nil;
        @try { entry = [data valueForKey:gAuxKeys[ident]]; } @catch (__unused NSException *e) {}
        BOOL active = sbs_entryActive(entry, ident);
        // ⭐ v1.8.0 直写：每个 ident 的「Entry 是否存在 / 是否激活」= 条不显示的定位证据
        sbs_auxLogOnce([NSString stringWithFormat:@"ent:%@:%d:%d", ident,
                        entry ? 1 : 0, active ? 1 : 0],
            @"Entry %@ key=%@ 存在=%d active=%d", ident, gAuxKeys[ident],
            entry ? 1 : 0, active ? 1 : 0);
        // ⭐⭐ v1.8.0 修复：显隐 = Entry 激活 **且** 未被"系统已显示"抑制。
        //   旧实现只写 `iv.hidden = !active` —— 定位开着时 locationEntry 是 active，
        //   于是即使去重判定为"系统已显示"，这里也会把图标重新显示出来
        //   （许总实测：日志说去重了、真机仍有定位图标）。
        //   同时把信号源（gSysRendered）也纳入：系统正在显示 → 隐藏本家副本。
        BOOL sig = [sbs_sysRendered() containsObject:ident];
        BOOL suppressed = sig || [sbs_sysShown() containsObject:ident];
        BOOL hide = (!active) || suppressed;
        if (iv.hidden == hide) continue;         // 无变化不写
        iv.hidden = hide;
        // ⭐⭐ v1.8.0 **效果级日志**（许总指正：决策日志 ≠ 实际显示）：
        //   记录真正写进视图的 hidden 值 —— 这才是"真机上到底显不显示"的证据。
        sbs_auxLogOnce([NSString stringWithFormat:@"hide:%@:%d", ident, hide ? 1 : 0],
            @"图标显隐 %@ hidden=%d（entry激活=%d 被系统显示抑制=%d）",
            ident, hide, active, suppressed);
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

// ⭐ v1.8.0 颜色紧凑打印（诊断：App 内图标"看不见"= 着色与背景同色？）
static NSString *sbs_cdesc(UIColor *c) {
    if (!c) return @"nil";
    CGFloat r = 0, g = 0, b = 0, a = 0;
    BOOL ok = NO;
    @try { ok = [c getRed:&r green:&g blue:&b alpha:&a]; } @catch (__unused NSException *e) {}
    if (!ok) return [c description];
    return [NSString stringWithFormat:@"%.2f/%.2f/%.2f/%.2f", r, g, b, a];
}

// ⭐ v1.8.0 配色巡检（许总实机测试用）：自愈定时器每 1s 采一次当前 fg 的
//   配色来源（窗口 / _UIStatusBar.style / foregroundColor / 时间文字色），
//   值变化才写一行 —— 保证手动切屏（无布局事件）时也能留下颜色证据。
static void sbs_colorTick(void) {
    if (!sbs_isSpringBoard()) return;
    UIView *fg = gActiveFG;
    if (!fg || !fg.window || fg.isHidden) {
        sbs_auxLogOnce(@"ctick-nofg", @"配色巡检：gActiveFG 不可用（fg=%p）", fg);
        return;
    }
    UIColor *fgColor = nil;
    NSNumber *barStyle = nil;
    UIColor *tint = nil;
    UIView *v = fg;
    for (int i = 0; i < 4 && v; i++) {
        NSString *cn = NSStringFromClass(v.class);
        @try {
            id fc = [v valueForKey:@"foregroundColor"];
            if (!fgColor && [fc isKindOfClass:[UIColor class]]) fgColor = (UIColor *)fc;
        } @catch (__unused NSException *e) {}
        if ([cn isEqualToString:@"_UIStatusBar"]) {
            @try {
                id st = [v valueForKey:@"style"];
                if (!barStyle && [st isKindOfClass:[NSNumber class]]) barStyle = (NSNumber *)st;
            } @catch (__unused NSException *e) {}
        }
        v = v.superview;
    }
    for (UIView *s in fg.subviews) {
        if (!tint && [NSStringFromClass(s.class) containsString:@"StringView"] &&
            [s respondsToSelector:@selector(textColor)])
            tint = [(UILabel *)s textColor];
    }
    NSString *winCls = NSStringFromClass(fg.window.class);
    // ⭐ v1.8.12 同修泛洪：旧版把「5s 时间桶」编进去重键 ⇒ 每 5s 必写一条
    //   （≈1.7 万行/天，且与状态无关）。改为：**去重键 = 配色元组本身**
    //   （窗 / barStyle / fgColor / 时间色），跃迁即记 + 同状态心跳；
    //   时间桶只留在正文里，供许总把日志与手动操作时间线对齐。
    int bucket = (int)([NSDate date].timeIntervalSince1970 / 5.0);
    NSString *key = [NSString stringWithFormat:@"%@:%@:%@:%@", winCls,
                     barStyle ?: @"-", sbs_cdesc(fgColor), sbs_cdesc(tint)];
    sbs_auxLogState(@"ctick", key, @"配色巡检 窗=%@ barStyle=%@ fgColor=%@ 时间色=%@ 桶=%ds",
                    winCls, barStyle ?: @"-", sbs_cdesc(fgColor), sbs_cdesc(tint), bucket * 5);
}

// ⭐ v1.8.10 主宿主（UIStatusBarWindow 的 fg）缓存：用于 MainSwitcher 让位仲裁
static UIView *gUIFG = nil;
static void sbs_auxLayoutInFG(UIView *fg) {
    if (!gAuxEnabled || !gAuxStrip) {
        if (gStrip && !gStrip.hidden) gStrip.hidden = YES;
        sbs_auxLogOnce([NSString stringWithFormat:@"off:%d:%d", gAuxEnabled, gAuxStrip],
                       @"辅助条关闭（auxEnabled=%d auxStrip=%d）", gAuxEnabled, gAuxStrip);
        return;
    }
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
        // ⭐ v1.8.0 直写（去重）：证明"条不显示"是门禁拒绝造成的，并给出窗口类名
        sbs_auxLogOnce([@"deny:" stringByAppendingString:winCls.length ? winCls : @"nil"],
            @"布局拒绝 win=%@ winHidden=%d fgHidden=%d fgW=%.0f（SB 只放行 UIStatusBarWindow/MainSwitcher）",
            winCls.length ? winCls : @"nil", sbWin ? sbWin.isHidden : -1,
            fg.isHidden, fg.bounds.size.width);
        return;
    }
    // ⭐⭐ v1.8.10 主/次宿主仲裁（治「条每秒闪一次 / 半时间不在屏上」）
    //   日志根因（11:25:20~23）：主屏上**同时存在两个活 fg** —— UIStatusBarWindow 与
    //   SBMainSwitcherWindow，二者各以 ~1s 节奏各自走布局；单例 `gStrip` 被来回搬家
    //   → 宿主窗在两条日志之间 ping-pong（`条显示 宿主窗=` 交替）。
    //   规则：UIStatusBarWindow 的 fg 只要存活，就让 MainSwitcher 的 fg 让位。
    //   （App 前台时主屏 fg 会被摘窗 → `!live` → 自然放行，App 内仍由 MainSwitcher 承载。）
    if (sbs_isSpringBoard()) {
        if ([winCls containsString:@"UIStatusBarWindow"]) {
            gUIFG = fg;
        } else {
            UIView *ui = gUIFG;
            if (ui && ui != fg && ui.window && !ui.window.isHidden && !ui.isHidden &&
                sbs_fgIsLive(ui)) {
                sbs_auxLogState(@"arb", @"cede-mainswitch",
                    @"宿主仲裁：MainSwitcher fg(%p) 让位于存活的 UIStatusBarWindow fg(%p)", fg, ui);
                return;
            }
        }
    }
    // ⭐ v1.4.6 锁屏不显示（许总要求）：SB 进程内读系统锁屏状态，锁屏时条隐藏。
    //    解锁后主屏布局触发 → locked=NO → 条恢复。
    if (sbs_sbLocked()) {
        if (gStrip && !gStrip.hidden) gStrip.hidden = YES;
        sbs_auxLogOnce(@"locked", @"锁屏 → 条隐藏（许总要求锁屏不显示）");
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
    sbs_probeAPIs(fg);          // ⭐ v1.8.0 一次性 API 探针（找可靠前景色来源）
    sbs_auxRefresh();
    // ⭐⭐ v1.8.0 颜色来源修正（App 内图标"消失"根因）：
    //   探针实证（2026-10-05）：`_UIStatusBar.foregroundColor` / `UIStatusBar_Modern
    //   .foregroundColor` = 状态栏**真实前景色**；而 `_UIStatusBarStringView.textColor`
    //   在 App 内会失真（Calculator 渲染白字却报黑 → 条图标被着成黑 → 黑底不可见）。
    //   ∴ 优先取链上 foregroundColor，textColor 仅作兜底。
    UIColor *fgColor = nil;
    NSNumber *barStyle = nil;              // `_UIStatusBar.style`：实测与真实前景一致（Home=1→白）
    NSMutableString *chainLog = [NSMutableString string];
    {
        UIView *v = fg;
        for (int i = 0; i < 4 && v; i++) {
            NSString *cn = NSStringFromClass(v.class);
            id fc = nil, st = nil, lg = nil, cu = nil;
            @try { fc = [v valueForKey:@"foregroundColor"]; } @catch (__unused NSException *e) {}
            @try { st = [v valueForKey:@"style"]; }           @catch (__unused NSException *e) {}
            @try { lg = [v valueForKey:@"legibilityStyle"]; } @catch (__unused NSException *e) {}
            @try { cu = [v valueForKey:@"currentStyle"]; }    @catch (__unused NSException *e) {}
            [chainLog appendFormat:@"%@(st=%@,lg=%@,cur=%@,fg=%@) ", cn, st, lg, cu,
                [fc isKindOfClass:[UIColor class]] ? sbs_cdesc((UIColor *)fc) : @"-"];
            // ⭐ 只认 `_UIStatusBar`：实测其 style 与真实前景一致
            //   （Home style=1 → 前景白）。`UIStatusBar_Modern.style` 实测为 0 但前景是白
            //   → 不可用，故按类名精确匹配，避免误取 ForegroundView/Modern 的 style。
            if ([cn isEqualToString:@"_UIStatusBar"]) {
                if (!fgColor && [fc isKindOfClass:[UIColor class]]) fgColor = (UIColor *)fc;
                if (!barStyle && [st isKindOfClass:[NSNumber class]]) barStyle = (NSNumber *)st;
            }
            v = v.superview;
        }
    }
    // 颜色来源②（兜底）：时间文字色（优先可见的那份）
    UIColor *tint = nil, *tintFb = nil;
    UIColor *imgTint = nil;     // 任一 UIImageView 的 tint（系统图标视图）
    UIColor *batTint = nil;     // 电池视图 tint
    UIColor *fgTint = fg.tintColor;
    NSMutableString *svLog = [NSMutableString string];
    for (UIView *v in fg.subviews) {
        NSString *cn = NSStringFromClass(v.class);
        if ([cn containsString:@"StringView"] && [v respondsToSelector:@selector(textColor)]) {
            UIColor *tc = [(UILabel *)v textColor];
            [svLog appendFormat:@"%@(hid=%d,a=%.2f,col=%@) ", cn, v.hidden, v.alpha, sbs_cdesc(tc)];
            if (!tintFb) tintFb = tc;
            if (!tint && !v.hidden && v.alpha > 0.01) tint = tc;
        }
        if (!imgTint && [v isKindOfClass:[UIImageView class]] && ((UIImageView *)v).tintColor)
            imgTint = ((UIImageView *)v).tintColor;
        if (!batTint && [cn containsString:@"Battery"])
            batTint = v.tintColor;
    }
    if (!tint) tint = tintFb;
    // ⭐⭐ 最终选择：① `_UIStatusBar.foregroundColor`（最准）
    //   ② `_UIStatusBar.style`（1=lightContent→白 / 0=default→黑）
    //   ③ 时间文字色   ④ 白
    UIColor *chosen;
    if (fgColor)       chosen = fgColor;
    else if (barStyle) chosen = (barStyle.integerValue == 1) ? UIColor.whiteColor
                                                            : UIColor.blackColor;
    else if (tint)     chosen = tint;
    else               chosen = UIColor.whiteColor;
    // ⭐ v1.8.0 颜色取证（键含 style+选用色 → 值变化时重打，可观察 App 内 style 是否变化）
    sbs_auxLogOnce([NSString stringWithFormat:@"tint:%@:%@:%@",
                    fg.window ? NSStringFromClass(fg.window.class) : @"nil",
                    barStyle ?: @"-", sbs_cdesc(chosen)],
        @"颜色取证 选用=%@ barStyle=%@ 链=[%@] 时间色=%@ 候选=[%@] 图tint=%@ 电池tint=%@ fg.tint=%@",
        sbs_cdesc(chosen), barStyle ?: @"nil",
        chainLog.length ? (NSString *)chainLog : @"(无)",
        sbs_cdesc(tint), svLog.length ? (NSString *)svLog : @"(无)",
        sbs_cdesc(imgTint), sbs_cdesc(batTint), sbs_cdesc(fgTint));
    static UIColor *lastTint = nil;
    if (chosen != lastTint) {
        for (UIImageView *iv in gAuxViews.allValues) iv.tintColor = chosen;
        lastTint = chosen;
    }
    // 可见图标列表（保持 gAuxIcons 声明顺序）
    // ⭐⭐ v1.8.0 只放「系统不显示的」：先收集 fg 内所有图标视图的 CGImage，再逐候选
    //    比对 —— 命中即系统已在状态栏显示 → 辅助条剔除（许总需求：不重复显示）。
    NSMutableArray<NSString *> *vis = [NSMutableArray array];
    NSMutableArray<NSString *> *skipped = [NSMutableArray array];
    NSMutableSet *sysNames = [NSMutableSet set];
    NSMutableArray<NSData *> *sysFps = [NSMutableArray array];
    NSMutableSet *sysClasses = [NSMutableSet set];
    if (!gSysShownNow) gSysShownNow = [NSMutableSet set];
    [gSysShownNow removeAllObjects];              // 当次快照：每次布局重新扫描
    sbs_auxDeepProbe(fg);                         // ⭐ v1.8.0 一次性深度取证
    sbs_probeSignal(fg);                          // ⭐ v1.8.1 信号容器一次性取证
    // ⭐ v1.8.6 布局完成时 fg 内图标视图的 frame 已就绪 —— 这是巡检「系统正在显示谁」
    //   最可靠的时刻（事件触发的那一瞬间 frame 还是 0×0）。同步执行以免再等 1s。
    //   ⚠️ 只在此处用同步调用（fg 是本函数参数、调用期间必存活）；
    //      异步路径一律走 `sbs_rescanSchedule`（block 不捕获视图）。
    if (fg.window && !fg.isHidden) sbs_rescanFG(fg, @"layout");
    sbs_collectIconRefs(fg, 6, sysNames, sysFps, sysClasses);   // ⭐ 深度 3→6（定位箭头可能更深）
    if (sysClasses.count) {
        NSArray *cl = [sysClasses.allObjects sortedArrayUsingSelector:@selector(compare:)];
        sbs_auxLogOnce([@"syscls:" stringByAppendingString:[cl componentsJoinedByString:@","]],
            @"fg 内图标视图 %lu 个（类名：%@）",
            (unsigned long)sysFps.count, [cl componentsJoinedByString:@","]);
    }
    // ⭐⭐ v1.8.0 去重判定修正（许总：状态栏图标不能重复）：
    //   扫描时机不可靠 —— 有的布局轮次系统图标视图尚未建立（sysNames 为空），
    //   若据空快照判"系统没显示"就会把重复图标补回来（实测 10:14:48 location 复现）。
    //   ∴ 采用【持久抑制表】gSysShown：
    //     · 本轮命中 → 记入（此后一直抑制，跨场景/跨窗口保持）
    //     · 不再撤销 —— 因为"功能是否开启"已由 Entry 的 active 判定（见 sbs_auxRefresh，
    //       功能关闭时 Entry 失活 → iv.hidden → 本来就不会显示），
    //       所以抑制只需单向累积即可；宁可少显示，也绝不在状态栏重复同一图标。
    // ⭐⭐⭐ v1.8.4 去重判定（许总指正后的最终形态）
    //   判据①（唯一主判据）= **状态栏变化信号集** `sbs_sysRendered()`：
    //     由 fg 视图树增删事件 + 数据更新事件 + 周期巡检实时重算
    //     （`sbs_rescanFG` → `sbs_publishRescan`，加立即 / 减需 2 次一致）。
    //   判据②（纯加性兜底）= 像素指纹：本轮快照里出现同一张位图 → 判定系统在画。
    //     ⚠️ 只在本轮生效，不记忆 —— 记忆化正是旧版"误撤抑制→重复显示"的根源。
    //   ⛔ 已彻底移除：按图标名的关键词兜底记忆（gSysNameHit 不再参与判定）、
    //      以及"缺席计数连续 3 次撤销抑制"那套快照逻辑。
    // ⭐⭐⭐ v1.8.8 主判据 = **item 级状态信号**（`_UIStatusBar._items[]._displayItems[]._view`
    //   的实时挂载状态）—— 与图标字形名彻底解耦（许总：不应按图标名判断）。
    //   旧 `sbs_sysRendered()`（视图树扫描 + 名字关键词）**降级为纯日志交叉核对**，不再参与判定；
    //   像素指纹比对保留为纯加性兜底（同一张位图本轮出现在系统树 → 判定系统在画）。
    NSMutableString *itemDbg = [NSMutableString string];
    NSSet *itemShown = sbs_itemShownSet(itemDbg);
    for (NSString *ident in gAuxIcons) {
        NSString *k = ident.lowercaseString;
        UIImageView *iv = gAuxViews[k];
        if (!iv) continue;
        BOOL byItemNow = [itemShown containsObject:k];
        BOOL byItemGrace = NO;
        if (!byItemNow) {
            NSNumber *ts = gItemShownAt[k];
            byItemGrace = ts && ([NSDate date].timeIntervalSince1970 - ts.doubleValue < 1.2);
        }
        BOOL byItem = byItemNow || byItemGrace;
        BOOL byName = [sbs_sysRendered() containsObject:k];   // ⚠️ 仅核对用，不参与判定
        BOOL byFp = NO;
        if (!byItem) {
            NSData *myFp = sbs_cgFingerprint(iv.image.CGImage);
            if (myFp.length) for (NSData *fp in sysFps)
                if ([fp isEqualToData:myFp]) { byFp = YES; break; }
        }
        BOOL shownBySystem = byItem || byFp;
        sbs_auxLogState([@"dedup:" stringByAppendingString:k],
            [NSString stringWithFormat:@"%@:%d:%d:%d:%d", k, shownBySystem ? 1 : 0,
             byItemNow ? 1 : 0, byItemGrace ? 1 : 0, byName ? 1 : 0],
            @"系统侧比对 %@：item信号=%d(即时%d/宽限%d) 指纹=%d ｜ 名扫描=%d（仅核对，不判定）｜ item集=[%@] 名集=%@ ⇒ 系统已显示:%d",
            ident, byItem, byItemNow, byItemGrace, byFp, byName,
            [itemDbg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]],
            [[sbs_sysRendered().allObjects sortedArrayUsingSelector:@selector(compare:)]
              componentsJoinedByString:@","],
            shownBySystem);
        if (shownBySystem) {
            // ⭐ v1.8.0 关键修复保留：必须**真正隐藏**（只从 vis 排除不影响绘制）
            if (!iv.hidden) iv.hidden = YES;
            [skipped addObject:k]; continue;
        }
        if (iv.hidden) continue;      // Entry 未激活 → 本就不显示
        [vis addObject:k];
    }
    if (skipped.count)
        sbs_auxLogState(@"skip", [skipped componentsJoinedByString:@","],
            @"跳过（系统已显示，不重复）：%@", [skipped componentsJoinedByString:@","]);
    CGFloat fgW = fg.bounds.size.width;
    if (!vis.count || fgW <= 0) {
        if (gStrip.superview && !gStrip.hidden) gStrip.hidden = YES;
        sbs_auxLogState(@"bar", @"HIDDEN",
            @"条隐藏：无可见图标（候选 %lu 个，其中系统已显示 %lu 个）",
            (unsigned long)gAuxIcons.count, (unsigned long)itemShown.count);
        return;
    }
    // —— 单条水平居中：总宽 = n*isz + (n-1)*gap，x = (fgW-w)/2 ——
    NSInteger n = vis.count;
    CGRect island = sbs_islandFrameInFG(fg);
    CGFloat gap = gAuxGap, isz = sbs_auxIconSize();
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
    // ⭐⭐ v1.8.0 修正：种子必须用 CGRectNull（空集）。
    //   用 CGRectZero 时 CGRectUnion((0,0,0,0), target) 会把包围盒左上角强行
    //   拉到原点 → 条 frame 退化成 (0,0, x+w, y+h)（起点丢失、尺寸虚大）。
    //   条原本无背景色（透明）故肉眼不可见，仅 red 调试底/命中测试才会暴露。
    //   图标本地坐标 = t - unionR.origin，absolute 位置两种种子下一致（视觉中性），
    //   但 frame 精确化后红底框才能真实反映条的占位。
    CGRect unionR = CGRectNull;
    for (NSValue *v in targets.objectEnumerator) unionR = CGRectUnion(unionR, v.CGRectValue);
    if (CGRectIsNull(unionR)) unionR = CGRectZero;
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
    // ⭐ v1.8.0 直写：条真的显示了 → 可见清单 / 尺寸 / 位置 / 宿主（许总可核对）
    //    ⭐ 去重键含【宿主窗口类名】：主屏(UIStatusBarWindow)↔App(SBMainSwitcherWindow)
    //    切换时可见集可能相同，若只按可见集去重会吞掉 App 内"确实显示了"的证据。
    NSString *hostWinCls = host.window ? NSStringFromClass(host.window.class) : @"nil";
    NSString *chosenDesc = sbs_cdesc(chosen);
    sbs_auxLogState(@"bar",
        [NSString stringWithFormat:@"vis:%@:%@:%@:%.2f", hostWinCls,
         [vis componentsJoinedByString:@","], chosenDesc, isz],
        @"条显示 可见=%@ 边长=%.2fpt 起点=(%.1f,%.1f) 总宽=%.1f fgW=%.0f 宿主窗=%@ 颜色=%@ 岛=%@",
        [vis componentsJoinedByString:@","], isz, x, y, w, fgW,
        hostWinCls, chosenDesc,
        NSStringFromCGRect(island));
    // ⭐ v1.8.0 几何取证：宿主/条的真实 frame、hidden、clipsToBounds、所在窗口
    sbs_auxLogOnce([@"geo:" stringByAppendingString:hostWinCls],
        @"几何取证 宿主=%@ f=%@ clip=%d hid=%d | 条 f=%@ hid=%d a=%.2f win=%@ sup=%@ | fg f=%@ b=%@ | fg.sup=%@",
        NSStringFromClass(host.class), NSStringFromCGRect(host.frame),
        host.clipsToBounds, host.isHidden,
        NSStringFromCGRect(gStrip.frame), gStrip.isHidden, gStrip.alpha,
        gStrip.window ? NSStringFromClass(gStrip.window.class) : @"nil",
        gStrip.superview ? NSStringFromClass(gStrip.superview.class) : @"nil",
        NSStringFromCGRect(fg.frame), NSStringFromCGRect(fg.bounds),
        fg.superview ? NSStringFromClass(fg.superview.class) : @"nil");
    // ⭐⭐ v1.8.0 **效果核对日志**（许总指正：日志必须反映真机实际显示）：
    //   逐图标打印【最终 hidden 值】+ 条本体 hidden/frame —— 这才是"屏幕上到底有什么"。
    NSMutableString *hideLog = [NSMutableString string];
    for (NSString *ident in gAuxIcons) {
        UIImageView *iv2 = gAuxViews[ident.lowercaseString];
        [hideLog appendFormat:@"%@=%d ", ident, iv2.isHidden ? 1 : 0];
    }
    sbs_auxLogState(@"eff", [NSString stringWithFormat:@"%@:%@", hostWinCls,
                    [vis componentsJoinedByString:@","]],
        @"效果核对 条hidden=%d 条frame=%@ 图标hidden[%@]", gStrip.isHidden,
        NSStringFromCGRect(gStrip.frame), hideLog);
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

    // ⭐⭐⭐ v1.8.4 状态栏变化信号：fg 视图树增删子视图 = 系统显示/隐藏某图标的**事件**
    //   （许总要求"监听状态栏的变化信号"，而不是事后按图标名嗅探）
    BOOL addOK = SBSHook(FG, @selector(addSubview:),
                         SBSHelper.class, @selector(sbs_fgAddSubview:));
    BOOL insOK = SBSHook(FG, @selector(insertSubview:atIndex:),
                         SBSHelper.class, @selector(sbs_fgInsertSubview:atIndex:));
    BOOL remOK = SBSHook(FG, @selector(willRemoveSubview:),
                         SBSHelper.class, @selector(sbs_fgWillRemoveSubview:));
    sbs_logNow(@"[hook] 信号源 fg addSubview/insertSubview/willRemoveSubview → %d/%d/%d",
               addOK, insOK, remOK);
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
    // ⭐⭐ v1.8.0 尽早挂辅助 hook（ctor 阶段，赶在状态栏 item 创建之前 —— 见函数注释）
    if (gAuxEnabled) sbs_installAuxHooksEarly();
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
        // ⭐⭐ v1.8.0：canEnable / item / data 三类 hook 已在 sbs_install（ctor 阶段）
        //    提前安装（见 sbs_installAuxHooksEarly 注释）—— 那时装才能赶在状态栏 item
        //    创建之前，拿到 canEnable 的 orig 证据。这里只做幂等兜底。
        sbs_installAuxHooksEarly();

        // （状态源 hook 已由 sbs_installAuxHooksEarly 在 ctor 阶段提前安装，此处不重复）
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

// ═══════════════ v1.9.0 配置热重载（设置面板改参数后无需 respring）═══════════════
// 面板保存时 post Darwin 通知 `com.xu.statusbarscale/prefsChanged`；
// 这里重读配置，把新参数就地应用到当前活动 fg（右侧缩放 / leading 缩放 / 辅助条）。
// ⚠️ 通知回调可能来自任意线程 → 一律 dispatch 到主队列；
//     block 内**只引用全局量**，执行时才取 gActiveFG 并校验存活
//     （绝不捕获任何 UIView —— 见技能 §8「异步 block 捕获视图」崩溃指纹）。
static void sbs_prefsChanged(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object,
                             CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    sbs_logNow(@"[prefs] 收到设置面板变更通知");
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            sbs_loadConfig();
            gAuxForceRelayout = YES;            // 跳过节流，强制按新尺寸重排
            sbs_rescanActive(@"prefs");         // 重算「系统此刻在显示谁」
            sbs_auxRelayoutFromData();          // 按新尺寸/间距重排辅助条
            UIView *fg = gActiveFG;             // 执行时现取 + 存活校验
            if (fg && fg.window && !fg.isHidden) sbs_apply(fg);
            gAuxForceRelayout = NO;
            sbs_logNow(@"[prefs] 热重载完成 enabled=%d scale=%.3f dy=%.2f thr=%.0f "
                       @"lead=%d/%.2f/%.1f aux=%d scale=%.2f base=%.1f gap=%.1f icons=%lu",
                       gEnabled, gScale, gDy, gThr,
                       gLeadEnabled, gLeadScale, gLeadDy,
                       gAuxEnabled, gAuxScale, gAuxBaseSize, gAuxGap,
                       (unsigned long)gAuxIcons.count);
        } @catch (NSException *e) {
            gAuxForceRelayout = NO;
            sbs_logNow(@"[prefs] 热重载异常: %@", e);
        }
    });
}

static void sbs_registerPrefsObserver(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    // 纯 CoreFoundation，不碰 UIKit ⇒ 可在构造函数里安全调用（技能 §2.2）
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    sbs_prefsChanged,
                                    CFSTR("com.xu.statusbarscale/prefsChanged"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

__attribute__((constructor))
static void sbs_ctor(void) {
    // v1.5.0 防御性白名单：即使用户残留了旧版 Classes=UIApplication 过滤文件，
    // 也绝不在 Aweme/WebKit/PosterBoard/普通 App 中安装任何全局 swizzle。
    if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"])
        return;
    sbs_loadConfig();
    sbs_registerPrefsObserver();   // ⭐ v1.9.0 监听设置面板的配置变更（热重载）
    NSLog(@"[StatusBarScale] v%@ loaded in SpringBoard; aux=%d verbose=%d",
          SBS_VERSION, gAuxEnabled, gVerbose);
    sbs_log(@"[载入] v%@ proc=%@ pid=%d enabled=%d scale=%.3f dy=%.2f thr=%.0f lead=%d/%.2f",
            SBS_VERSION, [[NSProcessInfo processInfo] processName], getpid(),
            gEnabled, gScale, gDy, gThr, gLeadEnabled, gLeadScale);
    sbs_install();
}
