// StatusBarScale.m —— 状态栏图标缩放（精简版 v2.0.0）
//
// 【功能范围】仅此两项，辅助图标条 / 设置面板 / 热重载 / plist 配置读取已全部移除：
//   ① 主缩放：灵动岛【右侧】（frame.minX >= 阈值）的状态栏图标，整体绕中心缩放 + 垂直微调，
//      与左侧时间的高度/重心对齐。
//   ② leading 缩放：时间右侧、灵动岛左侧的图标（闹钟/定位/录屏/麦克风等，无法按标识枚举），
//      按 fg 坐标系 frame 区间运行时发现，单独缩放。
//
// 问题背景：iPhone 14 Pro Max (iOS 16.5.1) 灵动岛右侧图标与时间不对齐
//   实测基线（1x points）：时间 高12 上沿24 下沿35 重心29.38
//   图标 高13(均值) 上沿22-23 下沿34-35 重心27.71 → 图标偏高 1.66px、偏高 1px
//
// 手法：hook _UIStatusBarForegroundView -layoutSubviews（布局终点，每帧可重入），
//   对命中视图施加 transform = 绕中心缩放(scale) + 下移(dy)。transform 不影响 frame 布局，
//   每次布局后重设，幂等。
//   ⚠️ UIView.transform 是绕 anchorPoint(0.5,0.5)=中心 变换；
//      CGAffineTransformTranslate(Scale(s,s),0,dys) 的屏幕位移 = s*dys → dys = dy/s。
//
// 【参数全部硬编码】原 com.xu.statusbarscale.plist 配置项已废弃（不再读取任何配置文件）。
//   当前值取自设备实测调定：scale=0.9025 / dy(锚点)=0.6687 / threshold=280 / leadScale=0.5038
//
// 【日志】/var/mobile/Documents/sbs_log.txt
//   diag=YES（默认）：关键事件直写（[hook]/[lead]/[leadApply]/[scaled]/[undo]/[leadUndo]）
//   verbose=YES：额外高频诊断（[apply]/dump 层）
//
// ⭐⭐ 历史事故防护（必须保留，勿删）：
//   · v1.9.2 撤销/复核：状态栏 item 视图会被 SBStatusBarReusePoolWindow 复用池回收后
//     换身份（同一个 _UIStatusBarStringView 既当【时间】又当【电池百分比/运营商名】）
//     ⇒ 只"登记 + 粘滞"必出错（症状＝主屏正常、进 App/锁屏「时间被缩放」）。
//     故主缩放 / leading 都必须带撤销表（sbs_revalidateManaged / sbs_leadRevalidate）。
//   · 文字视图(_UIStatusBarStringView) 永不参与主缩放。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define SBS_VERSION @"2.0.0"
#define SBS_LOG_PATH @"/var/mobile/Documents/sbs_log.txt"

// ─────────────── 硬编码参数（原 plist 配置 / 设置面板已移除）───────────────
static BOOL    gEnabled     = YES;
// 右侧图标缩放（实机调定值）
static CGFloat gScale       = 0.9025f;
// 垂直微调「锚点强度」：scale=0.84847 时的下移量；实际 dy 由 sbs_dyForScale(gScale) 实时推算
static CGFloat gDy          = 0.6687f;
// 右侧判定阈值：frame.minX >= 该值（灵动岛右缘，实机调定 280）
static CGFloat gThr         = 280.0f;
// leading 区（时间右侧、灵动岛左侧）图标缩放
static BOOL    gLeadEnabled = YES;
static CGFloat gLeadScale   = 0.5038f;
static CGFloat gLeadDy      = 0.0f;
// 日志门控：diag=关键事件直写（默认开）；verbose=高频/批量诊断（默认关）
static BOOL    gDiag        = YES;
static BOOL    gVerbose     = NO;

// 受管图标视图的弱引用集合（setTransform: hook 据此拦截系统改动）
static NSHashTable *gManaged     = nil;   // 主缩放
static NSHashTable *gManagedLead = nil;   // leading 缩放（变换值不同，分开管理）

// ─────────────── 变换 ───────────────
// ⭐ 垂直微调与缩放**绑定**：dy(s) = K · (1 − s)
//   · s → 1（不缩）时 dy → 0 —— 符合"不缩就不必下移"的直觉；
//   · K 由实机调定的工作点标定：锚点强度 = gDy，配锚点缩放 0.84847
//     （实测 dy=0.6687、scale=0.84847 ⇒ K ≈ 4.41）。
#define SBS_DY_ANCHOR_SCALE      0.84847f
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

// ─────────────── 日志 ───────────────
static void sbs_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void sbs_logNow(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

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
    //    SpringBoard 内存 5.5GB → Jetsam 循环杀进程 = "下拉就 respring"）
    static NSTimeInterval windowStart = 0, lastWrite = 0;
    static int dropped = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (windowStart == 0) windowStart = now;
    if (now - windowStart >= 5.0) {
        if (dropped > 0) {
            // ⭐ v1.4.6 改 append 写：atomically=YES 是整文件覆盖 —— 多进程
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

// ⭐ v1.4.6 关键事件直写（不限流）：[move]/[lead]/[undo] 是定位"缩放异常"的决定性证据。
//   这类事件本身低频，直写安全。
static void sbs_logNow(NSString *fmt, ...) {
    if (!gDiag) return;
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

// ─────────────── 身份去重（探针日志用）───────────────
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

// ─────────────── 主缩放撤销/复核 ───────────────
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

// ─────────────── 前向声明 ───────────────
static void sbs_applyLead(UIView *fg);
static CGRect sbs_islandFrameInFG(UIView *fg);
static void sbs_dumpScaled(UIView *fg, NSString *by);

// ─────────────── 主流程：右侧缩放 + leading 缩放 ───────────────
static void sbs_apply(UIView *fg) {
    // ⭐ 上游探针：确认 fg layoutSubviews hook 真的触发（App 内诊断）
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
    sbs_dumpScaled(fg, @"apply");     // ⭐ 探针：此刻 fg 内谁带着缩放过（变更即记 + 60s 心跳）
    // ⭐ 绑定取证：缩放一变就打印实时推算的垂直微调（变更即记，可核对联动）
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
        // 按类名过滤：只缩放状态栏 item 视图，
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
    // ⭐ v1.7.0 leading 区（时间右侧、灵动岛左侧）图标独立缩放 —— 与右侧互斥
    @try { sbs_applyLead(fg); } @catch (NSException *e) { sbs_logNow(@"[exc-lead] %@", e); }
}

// ===========================================================================
// leading 区（时间右侧、灵动岛左侧）图标缩放 + 运行时发现探针
//
// 许总反馈：原实现只缩放 minX >= threshold(280，灵动岛右侧) 的图标，
// 【时间右侧、灵动岛左侧】的那批图标被整体漏掉，且它们无法按标识枚举。
// 本模块改为按【fg 坐标系下的 frame 区间】发现它们，并把每次命中直写日志，
// 使"命中清单"可被实机核对（不允许凭猜测定类名）。
//
// 区间定义（统一换算到 fg 坐标系，points）：
//   timeMaxX  = 时间视图右缘（所有可见 StringView 的最大 maxX；无时间则 0）
//   leadLimit = 灵动岛左缘（sbs_islandFrameInFG().origin.x，兜底 152）
//   候选 = 非 StringView + 非 Background + class 含 StatusBar/Battery
//          + 宽高 >= 3pt 且宽 < 200pt（排除全宽容器/legibility 背景）
//          + maxX 落在 (timeMaxX, leadLimit)
// ===========================================================================

static NSMutableSet *sbs_leadSeen(void) {
    static NSMutableSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}

// 去重直写一条提示（同 key 只写一次）—— 用于记录"为何跳过"，使判定可核对。
static void sbs_leadNote(NSString *key, NSString *msg) {
    NSMutableSet *seen = sbs_leadSeen();
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    sbs_logNow(@"[lead] %@", msg);
}

// 时间视图右缘（leading 参照起点）；取所有可见 StringView 的最大右缘
// ⭐ 探针：把「贡献 timeMaxX 的那个 StringView」带出来。
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

// ⭐ 探针：列出 fg 子树内**所有当前带非单位变换**的视图 —— 即"此刻屏幕上到底有什么
//   被缩过"。带实例地址，用于识别状态栏 item 视图是否被系统复用池回收后拿去渲染了别的 item
//   （ReusePool 真实存在：SBStatusBarReusePoolWindow）。
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
//   不该缩的一直缩」；同时防「视图被复用池拿去渲染别的 item 后仍带着缩放值」。
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

// leading 区主流程：发现 → 上报 → 施加变换
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
    // ⭐ 基准取证：把"谁是时间基准"直写出来（可核对）
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

// ⭐ 灵动岛检测。灵动岛不是 _UIStatusBarForegroundView 的子视图（dump 证实），
//   是 SystemAperture 家族的独立视图。从 fg 向上爬 ≤4 层，在每层兄弟子树里按类名找
//   （深度 ≤2）。
// ⭐⭐ v1.4.2 加水平居中硬校验：实测锁屏/解锁后扫到假岛（宽126高37 恰好匹配但
//   x=117.5 中心 180.5 ≠ 屏幕中心 215）→ 条整体偏左 35pt。真岛永远水平居中于状态栏，
//   宽度校验 + 居中校验双条件。
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
    // 缓存 2s（每帧递归扫视图树太贵）；⭐ 缓存绑定 fg 实例（不同 fg 坐标系不同）
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
            if (sib == node) continue;
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

// ===========================================================================
// hook 基建
// ===========================================================================

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
    @try { sbs_apply((UIView *)self); }
    @catch (NSException *e) { sbs_log(@"[exc] %@", e); }
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
        // ⭐ v1.7.0 leading 图标与右侧图标分属不同受管表
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
        if (gVerbose) sbs_log(@"[didMove] self=%@ win=%@",
            NSStringFromClass(((UIView *)self).class),
            ((UIView *)self).window ? @"有" : @"nil");
        // 挂载后的布局尚未发生时，子视图可能还没建好 → 下一 runloop 补施
        dispatch_async(dispatch_get_main_queue(), ^{
            sbs_apply((UIView *)self);
        });
        // ⭐ v1.4.5 多档补触发：退出 App 回主屏时主屏 fg 可能不触发 layoutSubviews
        //    （实测 home 后零布局），0.3s 单次触发不够 —— 多档重试覆盖切换动画全周期。
        for (int i = 0; i < 4; i++) {
            NSTimeInterval delay = (i == 0 ? 0.0 : (i == 1 ? 0.3 : (i == 2 ? 0.8 : 1.5)));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try { sbs_apply((UIView *)self); }
                @catch (NSException *e) { sbs_log(@"[exc-dm] %@", e); }
            });
        }
    } @catch (NSException *e) {
        sbs_log(@"[exc] %@", e);
    }
}
@end

// 只基于 class_copyMethodList 的元数据找出真正覆写 selector 的类。
// base!=Nil 时仅限 base 子类。用于 hook 状态栏的实际实例类（子类覆写布局方法）。
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
            continue;
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
// 安装
// ===========================================================================
static void sbs_install(void) {
    static BOOL installed = NO;
    static int classWaitAttempt = 0;
    if (installed) return;
    Class FG = objc_getClass("_UIStatusBarForegroundView");
    if (!FG) {
        // SpringBoard 冷启动时 ctor 可能早于 UIKit 私有状态栏类注册。
        // 有限重试等待类出现（旧代码在此永久返回 → 整次启动都不生效）。
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

    // ① 布局终点 hook：每帧可重入 → 承载主缩放 + leading 缩放
    BOOL layoutOK = SBSHook(FG, @selector(layoutSubviews),
                            SBSHelper.class, @selector(sbs_fgLayoutSubviews));
    sbs_logNow(@"[hook] layoutSubviews → %@", layoutOK ? @"已安装" : @"失败");

    // ② 全局 hook UIView.setTransform: 拦截受管图标被系统重置（关键修复）
    BOOL transformOK = SBSHook([UIView class], @selector(setTransform:),
                               SBSHelper.class, @selector(sbs_viewSetTransform:));
    sbs_logNow(@"[hook] UIView.setTransform: → %@", transformOK ? @"已安装" : @"失败");

    // ③ fg 重新挂窗（App↔主屏切换/解锁）时补施
    BOOL windowOK = SBSHook(FG, @selector(didMoveToWindow),
                            SBSHelper.class, @selector(sbs_fgDidMoveToWindow));
    sbs_logNow(@"[hook] didMoveToWindow → %@", windowOK ? @"已安装" : @"失败");

    // ④ 状态栏的实际实例类可能是 FG 的子类（覆写布局方法）→ 逐个定义类补 hook
    NSUInteger layoutSubs = sbs_hookDefiningClasses(FG, @selector(layoutSubviews),
        @selector(sbs_fgLayoutSubviews),
        method_getTypeEncoding(class_getInstanceMethod(FG, @selector(layoutSubviews))),
        @"layout subclass");
    NSUInteger windowSubs = sbs_hookDefiningClasses(FG, @selector(didMoveToWindow),
        @selector(sbs_fgDidMoveToWindow),
        method_getTypeEncoding(class_getInstanceMethod(FG, @selector(didMoveToWindow))),
        @"window subclass");
    NSLog(@"[StatusBarScale] subclass hooks layout=%lu window=%lu",
          (unsigned long)layoutSubs, (unsigned long)windowSubs);
    sbs_logNow(@"[hook] 子类补 hook layout=%lu window=%lu",
               (unsigned long)layoutSubs, (unsigned long)windowSubs);
}

__attribute__((constructor))
static void sbs_ctor(void) {
    // 防御性白名单：绝不在非 SpringBoard 进程安装任何全局 swizzle。
    if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"])
        return;
    NSLog(@"[StatusBarScale] v%@ loaded in SpringBoard (scale=%.4f thr=%.0f lead=%.4f)",
          SBS_VERSION, gScale, gThr, gLeadScale);
    sbs_log(@"[载入] v%@ proc=%@ pid=%d enabled=%d scale=%.4f dy=%.4f thr=%.0f lead=%d/%.4f",
            SBS_VERSION, [[NSProcessInfo processInfo] processName], getpid(),
            gEnabled, gScale, gDy, gThr, gLeadEnabled, gLeadScale);
    sbs_install();
}
