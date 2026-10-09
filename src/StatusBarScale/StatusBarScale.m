// StatusBarScale.m —— 状态栏图标缩放 + 资源库背景透明 + 小组件背景移除（v2.2.0）
//
// 【功能范围】
//   ① 主缩放：灵动岛【右侧】（frame.minX >= 阈值）的状态栏图标，整体绕中心缩放 + 垂直微调，
//      与左侧时间的高度/重心对齐。
//   ② leading 缩放：时间右侧、灵动岛左侧的图标（闹钟/定位/录屏/麦克风等，无法按标识枚举），
//      按 fg 坐标系 frame 区间运行时发现，单独缩放。
//   ③ 资源库背景透明：App 资源库分类卡片的背景板 + 顶部搜索框背景 清成透明，只留图标与文字。
//   ④ 小组件背景移除（v2.2.0 新增）：主屏小组件（Widget）的半透明毛玻璃背景板移除，
//      只留内容。见文件末尾「小组件背景移除」模块 —— 实现手法移植自
//      RemoveWidgetBackground（MIT，OwnGoal Studio / Lessica）的"限制绘制命令尺寸"思路。
//   （辅助图标条 / 设置面板 / 热重载 / plist 配置读取已于 v2.0.0 全部移除）
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
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define SBS_VERSION @"2.2.0"

// ⭐⭐ 日志路径（2026-10-09 血泪根因）：RootHide 下不同进程的路径解析不一致 ——
//   SpringBoard 里 `/var/mobile/Documents` 可写；但 chronod（system daemon）里
//   `/var/mobile/...` 与 `/var/tmp/...` **都写不进去**（日志与落痕全部静默丢失，
//   曾据此误判"插件没注入 chronod"，浪费两轮排查）⇒ 统一改用**真实路径**。
static NSString *sbs_logPath(void);
#define SBS_LOG_PATH (sbs_logPath())

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
// 正式版关闭布局期取证。保留低频安装/异常日志，但不在每次状态栏布局时
// 递归遍历、拼接视图签名或构造候选诊断字符串。
static BOOL    gRuntimeDiagnostics = NO;
// 实时活动树/CA 绘制探针只用于一次性逆向定位。已由日志锁定 key-line ivar，
// 正式版本关闭，避免全局 CALayer display/draw hook 与每 2 秒视图树日志。
static BOOL    gApertureProbeEnabled = NO;

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
// 日志文件路径解析：真实路径优先（chronod 只认它），失败退回兼容路径。
static NSString *sbs_logPath(void) {
    static NSString *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *real   = @"/private/var/mobile/Documents/sbs_log.txt";
        NSString *legacy = @"/var/mobile/Documents/sbs_log.txt";
        if ([fm fileExistsAtPath:real]) {
            p = real;
        } else if ([fm createFileAtPath:real contents:[NSData data] attributes:nil]) {
            p = real;
        } else {
            p = legacy;
        }
    });
    return p;
}

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
static void sbs_clearLibFolderBg(UIView *bgv);
static void sbs_clearSearchFieldBg(UIView *tf);
static void sbs_probeApertureTree(UIView *fg);
static void sbs_probeApertureLayers(CALayer *x, int depth, int *count);
static void sbs_probeApertureContentViews(UIView *v, int depth, int *count);
static BOOL sbs_isApertureLayer(CALayer *layer);
static BOOL gApertureExpandedLayerCaptured = NO;

// System Aperture 的实时活动外框不是普通 CALayer.border：
// SBSystemApertureContainerView 内部通过 _darkBkgKeyLineView /
// _lightBkgKeyLineView 两个私有 UIView 绘制 key-line。它们通常是匿名
// UIView，所以不能按类名匹配；保存弱引用后，在 UIView/CALayer 写入口持续压制。
static NSHashTable *gApertureKeylineViews = nil;
static NSHashTable *gApertureKeylineLayers = nil;

static NSHashTable *sbs_apertureKeylineViews(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gApertureKeylineViews = [NSHashTable weakObjectsHashTable];
    });
    return gApertureKeylineViews;
}

static NSHashTable *sbs_apertureKeylineLayers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gApertureKeylineLayers = [NSHashTable weakObjectsHashTable];
    });
    return gApertureKeylineLayers;
}

// 只对明确的对象 ivar 调 object_getIvar。历史上对非对象 ivar 误用
// object_getIvar 会破坏 SpringBoard 堆，故这里先检查 type encoding。
static id sbs_objectIvar(id obj, const char *name) {
    if (!obj || !name) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    const char *enc = ivar_getTypeEncoding(iv);
    if (!enc || enc[0] != '@') return nil;
    @try { return object_getIvar(obj, iv); }
    @catch (__unused NSException *e) { return nil; }
}

static BOOL sbs_isManagedApertureKeyline(UIView *v) {
    return v && gApertureKeylineViews && [gApertureKeylineViews containsObject:v];
}

static BOOL sbs_isManagedApertureKeylineLayer(CALayer *layer) {
    return layer && gApertureKeylineLayers && [gApertureKeylineLayers containsObject:layer];
}

static void sbs_logApertureKeyline(UIView *v, const char *role, BOOL changed) {
    if (!v) return;
    static NSMutableSet *seen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSString *key = [NSString stringWithFormat:@"%s/%p/%d", role ?: "keyLine", v, changed ? 1 : 0];
    if ([seen containsObject:key] || seen.count >= 160) return;
    [seen addObject:key];
    CGRect f = [v convertRect:v.bounds toView:nil];
    CALayer *l = v.layer;
    sbs_logNow(@"[apertureKeyline] role=%s view=%p class=%@ frame=%@ hidden=%d alpha=%.2f "
               @"layerHidden=%d opacity=%.2f bgA=%.2f changed=%d",
               role ?: "keyLine", v, NSStringFromClass(v.class), NSStringFromCGRect(f),
               v.hidden, v.alpha, l.hidden, l.opacity,
               l.backgroundColor ? CGColorGetAlpha(l.backgroundColor) : -1.0, changed);
}

// 精确隐藏 System Aperture 容器的两条 key-line。不要隐藏 content/gainMap/
// black-fill 视图，否则会连实时活动内容或灵动岛黑底一起抹掉。
static void sbs_suppressApertureKeylines(UIView *owner) {
    if (!owner) return;
    NSString *cn = NSStringFromClass(owner.class);
    if (![cn containsString:@"SystemApertureContainerView"]) return;

    static const struct { const char *ivar; const char *role; } targets[] = {
        {"_darkBkgKeyLineView",  "dark"},
        {"_lightBkgKeyLineView", "light"},
    };
    for (NSUInteger i = 0; i < sizeof(targets) / sizeof(targets[0]); i++) {
        id obj = sbs_objectIvar(owner, targets[i].ivar);
        if (![obj isKindOfClass:[UIView class]] || obj == owner) continue;
        UIView *v = (UIView *)obj;
        CALayer *layer = v.layer;
        NSHashTable *managed = sbs_apertureKeylineViews();
        BOOL wasSuppressed = v.hidden && layer.hidden && v.alpha < 0.01 && layer.opacity < 0.01;
        [managed addObject:v];
        [sbs_apertureKeylineLayers() addObject:layer];
        // 先登记再写属性，避免全局 setter hook 把系统恢复动作漏过去。
        if (!v.hidden) v.hidden = YES;
        if (!layer.hidden) layer.hidden = YES;
        if (v.alpha >= 0.01) v.alpha = 0.0;
        if (layer.opacity >= 0.01f) layer.opacity = 0.0f;
        if (layer.borderWidth != 0.0) layer.borderWidth = 0.0;
        if (layer.borderColor && CGColorGetAlpha(layer.borderColor) > 0.0)
            layer.borderColor = [UIColor clearColor].CGColor;
        sbs_logApertureKeyline(v, targets[i].role, !wasSuppressed);
    }

    // shadowView 不是 key-line 本体；仅移除其阴影参数，保留容器的黑底和内容。
    id shadowObj = sbs_objectIvar(owner, "_shadowView");
    if ([shadowObj isKindOfClass:[UIView class]]) {
        UIView *shadow = (UIView *)shadowObj;
        CALayer *layer = shadow.layer;
        if (layer.shadowOpacity != 0.0f) layer.shadowOpacity = 0.0f;
        if (layer.shadowColor && CGColorGetAlpha(layer.shadowColor) > 0.0)
            layer.shadowColor = [UIColor clearColor].CGColor;
        if (layer.shadowRadius != 0.0) layer.shadowRadius = 0.0;
        if (layer.shadowPath) layer.shadowPath = nil;
        sbs_logApertureKeyline(shadow, "shadow", NO);
    }
}

static void sbs_logApertureClassMetadata(Class cls) {
    if (!cls) return;
    NSMutableArray *methodNames = [NSMutableArray array];
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if ([name containsString:@"border"] || [name containsString:@"Border"] ||
            [name containsString:@"background"] || [name containsString:@"Background"] ||
            [name containsString:@"effect"] || [name containsString:@"Effect"] ||
            [name containsString:@"corner"] || [name containsString:@"Corner"] ||
            [name containsString:@"portal"] || [name containsString:@"Portal"] ||
            [name containsString:@"display"] || [name containsString:@"Display"] ||
            [name containsString:@"layout"] || [name containsString:@"Layout"])
            [methodNames addObject:name];
    }
    free(methods);
    NSMutableArray *ivarNames = [NSMutableArray array];
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *name = ivar_getName(ivars[i]);
        if (name) [ivarNames addObject:[NSString stringWithUTF8String:name]];
    }
    free(ivars);
    sbs_logNow(@"[apertureClass] %@ methods=%@ ivars=%@", NSStringFromClass(cls), methodNames, ivarNames);
}

static void sbs_logApertureRenderLayer(CALayer *layer, NSString *kind, CGContextRef ctx) {
    if (!layer || !sbs_isApertureLayer(layer)) return;
    static NSMutableSet *seen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSString *key = [NSString stringWithFormat:@"%@/%p", kind, layer];
    if ([seen containsObject:key] || seen.count >= 160) return;
    [seen addObject:key];
    id delegate = layer.delegate;
    sbs_logNow(@"[apertureCA] kind=%@ layer=%p class=%@ delegate=%@ frame=%@ sub=%lu ctx=%d contents=%d",
               kind, layer, NSStringFromClass(layer.class), delegate ? NSStringFromClass([delegate class]) : @"nil",
               NSStringFromCGRect(layer.frame), (unsigned long)layer.sublayers.count, ctx ? 1 : 0,
               layer.contents ? 1 : 0);
}

static BOOL sbs_isApertureLayer(CALayer *layer) {
    if (!layer) return NO;
    for (CALayer *p = layer; p; p = p.superlayer) {
        NSString *ln = NSStringFromClass(p.class);
        if ([ln containsString:@"Shape"] || [ln containsString:@"Border"] ||
            [ln containsString:@"Outline"] || [ln containsString:@"Ring"])
            ; // 继续检查其宿主视图/祖先层
        id delegate = p.delegate;
        if ([delegate isKindOfClass:[UIView class]]) {
            for (UIView *v = (UIView *)delegate; v; v = v.superview) {
                NSString *cn = NSStringFromClass(v.class);
                if ([cn containsString:@"Aperture"] || [cn containsString:@"Island"] ||
                    [cn containsString:@"Pill"] || [cn containsString:@"LiveActivity"] ||
                    [cn containsString:@"GainMap"] || [cn containsString:@"Border"] ||
                    [cn containsString:@"Outline"] || [cn containsString:@"Ring"])
                    return YES;
            }
        }
    }
    return NO;
}

static void sbs_probeApertureLayers(CALayer *x, int depth, int *count) {
    if (!x || !count || depth > 8 || *count >= 120) return;
    @try {
        NSArray *children = x.sublayers ?: @[];
        BOOL shape = [x isKindOfClass:[CAShapeLayer class]];
        CAShapeLayer *sl = shape ? (CAShapeLayer *)x : nil;
        CGFloat strokeA = (shape && sl.strokeColor) ? CGColorGetAlpha(sl.strokeColor) : -1.0;
        CALayer *presentation = x.presentationLayer;
        id delegate = x.delegate;
        sbs_logNow(@"[apertureLayer] d=%d idx=? class=%@ delegate=%@ frame=%@ "
                   @"sub=%lu mask=%d pres=%d contents=%d border=%.2f/%.2f "
                   @"bg=%.2f shadow=%.2f/%.2f shape=%d path=%d strokeA=%.2f line=%.2f",
                   depth, NSStringFromClass(x.class), delegate ? NSStringFromClass([delegate class]) : @"nil",
                   NSStringFromCGRect(x.frame), (unsigned long)children.count, x.mask ? 1 : 0,
                   presentation ? 1 : 0, x.contents ? 1 : 0, x.borderWidth,
                   x.borderColor ? CGColorGetAlpha(x.borderColor) : -1.0,
                   x.backgroundColor ? CGColorGetAlpha(x.backgroundColor) : -1.0,
                   x.shadowOpacity, x.shadowRadius, shape, (shape && sl.path) ? 1 : 0,
                   strokeA, shape ? sl.lineWidth : 0.0);
        (*count)++;
        if (x.mask && *count < 120) {
            sbs_logNow(@"[apertureLayerChild] d=%d kind=mask class=%@ frame=%@", depth + 1,
                       NSStringFromClass(x.mask.class), NSStringFromCGRect(x.mask.frame));
            sbs_probeApertureLayers(x.mask, depth + 1, count);
        }
        NSUInteger i = 0;
        for (CALayer *sub in children) {
            if (*count >= 120) break;
            sbs_logNow(@"[apertureLayerChild] d=%d idx=%lu class=%@ frame=%@ delegate=%@",
                       depth + 1, (unsigned long)i, NSStringFromClass(sub.class),
                       NSStringFromCGRect(sub.frame), sub.delegate ? NSStringFromClass([sub.delegate class]) : @"nil");
            sbs_probeApertureLayers(sub, depth + 1, count);
            i++;
        }
    } @catch (NSException *e) {
        sbs_logNow(@"[apertureLayerError] d=%d class=%@ reason=%@", depth,
                   NSStringFromClass(x.class), e.reason ?: @"unknown");
        (*count)++;
    }
}

// 搜索框可能挂在 SpringBoard 的特殊窗口中，UIApplication.windows 不一定能枚举到。
// 只接受 App Library 的 SBH 搜索类，避免全局 UIView setter 误伤 Spotlight、
// 控制中心或其他系统搜索界面的材质层。
static UIView *sbs_librarySearchOwner(UIView *v) {
    for (UIView *p = v; p; p = p.superview) {
        NSString *cn = NSStringFromClass(p.class);
        BOOL isHomeScreenSearch = [cn hasPrefix:@"SBH"] && [cn containsString:@"Search"];
        if (isHomeScreenSearch) return p;
    }
    return nil;
}

static BOOL sbs_isSearchBackgroundView(UIView *v) {
    if (!v) return NO;
    if ([v isKindOfClass:[UIImageView class]] || [v isKindOfClass:[UILabel class]]) return NO;
    NSString *cn = NSStringFromClass(v.class);
    // 这是 UIView 全局 setter 的热路径。先用当前类做廉价过滤，仅对真正可能是
    // 搜索框材质的少数视图遍历祖先链；否则控制中心出现时会对数百个视图反复爬树。
    BOOL candidate = [cn containsString:@"Material"] ||
                     [v isKindOfClass:[UIVisualEffectView class]];
    return candidate && sbs_librarySearchOwner(v) != nil;
}

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
    if (gRuntimeDiagnostics)
        sbs_dumpScaled(fg, @"apply"); // 诊断模式：递归记录当前带缩放的视图
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
    // v2.1.23：不再从状态栏 layoutSubviews 遍历所有窗口/图层。边框已确认是
    // SBSystemApertureContainerView 的两个 key-line ivar，由该容器的精确 hook 处理。
    if (gApertureProbeEnabled) sbs_probeApertureTree(fg);
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
        if (gRuntimeDiagnostics)
            sbs_leadNote(@"skipFg", [NSString stringWithFormat:
                @"跳过：非全屏 fg（宽 %.0f ≠ 屏宽 %.0f）—— CC/Spotlight 迷你状态栏",
                fg.bounds.size.width, scrW]);
        return;
    }
    UIView *timeV = nil; CGRect timeR = CGRectZero;
    CGFloat timeMaxX = sbs_timeMaxXDbg(fg, &timeV, &timeR);
    // ⭐ 基准取证：把"谁是时间基准"直写出来（可核对）
    if (gRuntimeDiagnostics)
        sbs_leadNote([NSString stringWithFormat:@"base:%p:%.0f", (void *)timeV, timeMaxX],
            [NSString stringWithFormat:@"时间基准 %p %s f=%@ maxX=%.1f win=%@",
             (void *)timeV, timeV ? class_getName(timeV.class) : "nil",
             NSStringFromCGRect(timeR), timeMaxX,
             fg.window ? NSStringFromClass(fg.window.class) : @"nil"]);
    if (timeMaxX <= 0.5) {
        if (gRuntimeDiagnostics)
            sbs_leadNote(@"skipTime", @"跳过：无可视时间视图（timeMaxX=0），无判定基准");
        return;
    }
    CGRect island = sbs_islandFrameInFG(fg);
    CGFloat leadLimit = CGRectIsEmpty(island) ? 152.0 : island.origin.x;
    if (leadLimit < 60.0 || leadLimit > 200.0) {
        if (gRuntimeDiagnostics)
            sbs_leadNote(@"skipIsland", [NSString stringWithFormat:
                @"跳过：灵动岛左缘异常（%.1f 不在 60~200）", leadLimit]);
        return;
    }

    NSMutableArray<UIView *> *cands = [NSMutableArray array];
    for (UIView *s in fg.subviews)
        sbs_collectLead(s, fg, 0, timeMaxX, leadLimit, cands);

    if (gRuntimeDiagnostics)
        sbs_leadReport(fg, cands, timeMaxX, leadLimit);

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

// 一次性探针：实时活动外框可能不是 CALayer.border，而是独立的私有子视图/内容层。
// 记录灵动岛附近视图的真实类名与 layer 属性，供下一轮按证据锁定目标。
static void sbs_probeApertureTreeRecursive(UIView *v, int depth, int *count) {
    if (!v || depth > 5 || !count || *count >= 160) return;
    CGRect f = [v convertRect:v.bounds toView:nil];
    BOOL region = f.origin.y < 90.0 && f.size.width >= 50.0 && f.size.width <= 450.0 &&
                  f.size.height >= 15.0 && f.size.height <= 180.0 &&
                  fabs(CGRectGetMidX(f) - 215.0) < 150.0;
    NSString *cn = NSStringFromClass(v.class);
    BOOL named = [cn containsString:@"Aperture"] || [cn containsString:@"Island"] ||
                 [cn containsString:@"Pill"] || [cn containsString:@"Activity"] ||
                 [cn containsString:@"Border"] || [cn containsString:@"Outline"] ||
                 [cn containsString:@"Ring"];
    if (region && (named || depth <= 2)) {
        CALayer *l = v.layer;
        CGFloat ba = l.backgroundColor ? CGColorGetAlpha(l.backgroundColor) : -1.0;
        CGFloat bra = l.borderColor ? CGColorGetAlpha(l.borderColor) : -1.0;
        sbs_logNow(@"[apertureProbe] d=%d %@ f=%@ hidden=%d alpha=%.2f sub=%lu "
                   @"layerBorder=%.2f/%.2f layerBg=%.2f contents=%d",
                   depth, cn, NSStringFromCGRect(f), v.hidden, v.alpha,
                   (unsigned long)v.subviews.count, l.borderWidth, bra, ba,
                   l.contents ? 1 : 0);
        (*count)++;
        if ([cn containsString:@"ApertureContainerView"] && !v.hidden && v.bounds.size.width > 200.0) {
            int contentCount = 0;
            sbs_probeApertureContentViews(v, 0, &contentCount);
            sbs_logNow(@"[apertureView] 完成宿主 %@，记录 %d 个 UIView", cn, contentCount);
            if (!gApertureExpandedLayerCaptured) {
                gApertureExpandedLayerCaptured = YES;
                sbs_logApertureClassMetadata(v.class);
                sbs_logApertureClassMetadata(object_getClass(v));
                for (UIView *p = v; p; p = p.superview) {
                    NSString *pn = NSStringFromClass(p.class);
                    if ([pn containsString:@"Aperture"] || [pn containsString:@"Portal"] ||
                        [pn containsString:@"SAUIElement"])
                        sbs_logApertureClassMetadata(p.class);
                }
                int expandedLayerCount = 0;
                sbs_logNow(@"[apertureLayerTree] captured expanded host class=%@ frame=%@",
                           cn, NSStringFromCGRect(f));
                sbs_probeApertureLayers(v.layer, 0, &expandedLayerCount);
                sbs_logNow(@"[apertureLayerTree] complete layers=%d", expandedLayerCount);
            }
        }
    }
    for (UIView *s in v.subviews)
        sbs_probeApertureTreeRecursive(s, depth + 1, count);
}

static void sbs_probeApertureContentViews(UIView *v, int depth, int *count) {
    if (!v || !count || depth > 12 || *count >= 240) return;
    CALayer *l = v.layer;
    CGRect f = [v convertRect:v.bounds toView:nil];
    // 聚焦展开态容器及其直接渲染节点，避免重复输出整棵静态子树。
    if (depth <= 1) {
        NSString *curve = @"unavailable";
        SEL curveSel = NSSelectorFromString(@"cornerCurve");
        if ([l respondsToSelector:curveSel]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(l, curveSel);
            curve = [value respondsToSelector:@selector(description)] ? [value description] : @"nil";
        }
        NSString *signature = [NSString stringWithFormat:@"%@|%d|%.1f|%.1f|%d|%.2f|%.2f|%@|%d|%.2f|%@|%@|%@",
            NSStringFromClass(v.class), depth, f.size.width, f.size.height, v.hidden, v.alpha,
            l.cornerRadius, curve, l.masksToBounds, l.borderWidth,
            l.filters ?: @[], l.backgroundFilters ?: @[], l.compositingFilter ?: @"nil"];
        static NSMutableDictionary *lastSignatures = nil;
        static dispatch_once_t signatureOnce;
        dispatch_once(&signatureOnce, ^{ lastSignatures = [NSMutableDictionary dictionary]; });
        NSString *key = [NSString stringWithFormat:@"%@/%d", NSStringFromClass(v.class), depth];
        if (![lastSignatures[key] isEqualToString:signature]) {
            lastSignatures[key] = signature;
            sbs_logNow(@"[apertureView] d=%d class=%@ frame=%@ hidden=%d alpha=%.2f opaque=%d sub=%lu corner=%.2f curve=%@ masks=%d border=%.2f/%.2f filters=%@ bgFilters=%@ compFilter=%@ edgeAA=%d raster=%d",
                       depth, NSStringFromClass(v.class), NSStringFromCGRect(f), v.hidden, v.alpha, v.opaque,
                       (unsigned long)v.subviews.count, l.cornerRadius, curve, l.masksToBounds,
                       l.borderWidth, l.borderColor ? CGColorGetAlpha(l.borderColor) : -1.0,
                       l.filters ?: @[], l.backgroundFilters ?: @[], l.compositingFilter ?: @"nil",
                       l.allowsEdgeAntialiasing, l.shouldRasterize);
        }
    }
    (*count)++;
    for (UIView *sub in [v.subviews copy]) sbs_probeApertureContentViews(sub, depth + 1, count);
}

static void sbs_probeApertureTree(UIView *fg) {
    if (!fg) return;
    static NSTimeInterval lastProbe = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - lastProbe < 2.0) return;
    lastProbe = now;
    UIView *node = fg;
    int count = 0;
    for (int up = 0; up < 4 && node.superview; up++) {
        UIView *parent = node.superview;
        for (UIView *sib in parent.subviews) {
            if (sib == node) continue;
            sbs_probeApertureTreeRecursive(sib, 0, &count);
        }
        node = parent;
    }
    // System Aperture/实时活动可能位于独立窗口，不在 fg 的祖先兄弟树中。
    // 补扫 UIApplication 当前可见窗口，按屏幕坐标记录顶部灵动岛区域。
    for (UIWindow *w in [UIApplication sharedApplication].windows)
        sbs_probeApertureTreeRecursive(w, 0, &count);
    sbs_logNow(@"[apertureProbe] 完成，记录 %d 个视图 fgWin=%@", count,
               fg.window ? NSStringFromClass(fg.window.class) : @"nil");
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

// ===========================================================================
// 模块：主屏小组件（Widget）背景移除 —— 全局量 / 辅助（v2.2.0 新增）
//
// 【为什么不能"找背景视图"】小组件由 SwiftUI 渲染，背景板是渲染后端（RenderBox）
//   用绘制命令画出来的 —— 视图树里往往找不到一个可辨识的"背景视图"类。
// 【正解】在渲染后端拦截【尺寸超过阈值的绘制矩形】：超过阈值即视为背景板，
//   把它归零（不画），而文字/图标等小元素照常绘制。
//   手法来源：RemoveWidgetBackground（MIT License，OwnGoal Studio / Lessica）
//   的 "restricting the size of drawing commands" 思路，本项目按需重写。
//
// 【生效范围】只对 widget 宿主窗口的绘制生效：
//   窗口打标（UIWindow -initWithWindowScene:）→ 渲染期置线程标记
//   （RBLayer -display）→ RBShape -setRect: 命中阈值才抹。绝不做全局绘制改写。
//
// 【日志】[wbg-*] 前缀，关键事件直写 /var/mobile/Documents/sbs_log.txt
// ===========================================================================
// ⭐⭐ chronod（system daemon）里 `/var/mobile/...`、`/var/tmp/...`、`/private/var/...`
//   写入**全部失败**（沙箱）⇒ 诊断只能走两条路：os_log（NSLog）+ 进程自己的临时目录。
//   NSTemporaryDirectory() 是 chronod 唯一保证可写的路径。
static void sbs_wlogFile(NSString *line) {
    static NSString *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"sbs_wbg.txt"];
        if (!p.length) p = @"/private/var/tmp/sbs_wbg.txt";
    });
    NSString *s = [NSString stringWithFormat:@"[%lu] %@\n",
                   (unsigned long)getpid(), line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!fh) {
        [s writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[s dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

#define SBS_WLOG(fmt, ...) do { \
    NSLog(@"[SBSW] " fmt, ##__VA_ARGS__); \
    sbs_wlogFile([NSString stringWithFormat:fmt, ##__VA_ARGS__]); \
} while (0)

// 总开关。⭐⭐ 2026-10-09 对齐全量官方 RWB 源码后重开：
//   此前"抹第 2+ 背景板仍在 / 抹第 1 变黑"的实测结论，根因是**强制暗色未配套**——
//   官方 RWB 的 RBShape 抹除必须配合「UIWindow + CHUISWidgetScene + CHS*PresentationAttributes
//   强制 dark colorScheme」：暗色下背景板才以【独立超阈值矩形】呈现，可被尺寸分离。
//   浅色下背景与内容同尺寸，无论跳/抹都会误伤 → 变黑或无效。
//   ⇒ 恢复渲染侧抹除（官方 RWB 的主力手段），并与强制暗色配套使用。
static BOOL    gWidgetBgClear = YES;
// 阈值（RBShape 绘制坐标系 = 屏幕点）。⭐⭐ 2026-10-09 实机实测绘制矩形分布：
//     364x170  ×7   ← 整块 widget 尺寸（背景板与根层都在这个尺寸上）
//     165x146  ×1   ← 内容卡
//     161x28   ×4   ← 文字行
//     20x20    ×20  ← 图标
//   ⇒ 150 阈值恰好【只命中整块 widget 尺寸】的绘制，不误伤内容元素。
static CGFloat gWidgetMaxW    = 150.0f;
static CGFloat gWidgetMaxH    = 150.0f;
// 跳过【前 N 个】"整块尺寸"绘制，第 N+1 个起抹除（对齐官方 RWB iOS16 策略）。
// ⚠️ 必须与「强制暗色」配套：暗色下第 1 个大矩形是内容根层（跳过），第 2+ 个才是背景板（抹除）。
static int     gWidgetSkipN   = 1;

static NSString *const kSBSWbgThreadFlag = @"sbs_wbg_hide";        // 线程标记：本次渲染在 widget 窗口内
static NSString *const kSBSWbgSkipN  = @"sbs_wbg_skip_n";   // 本次渲染已跳过的大矩形个数
static const void   *kSBSWbgWindowMark   = &kSBSWbgWindowMark;     // 关联对象 key：窗口已打标

// 本进程是否为"小组件渲染进程"（chronod 或 WidgetRenderer-XXXX）
static BOOL sbs_isWidgetRenderProcess(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if ([bid hasPrefix:@"com.apple.chrono.WidgetRenderer-"]) return YES;
    if ([bid isEqualToString:@"com.apple.chronod"]) return YES;
    NSString *p = [[NSProcessInfo processInfo] processName] ?: @"";
    if ([p isEqualToString:@"WidgetRenderer"] || [p isEqualToString:@"chronod"]) return YES;
    return NO;
}

// 该 UIWindowScene 是否为小组件宿主场景（不写死单一类名，宽容匹配；首见即打印）
static BOOL sbs_isWidgetScene(id scene) {
    if (!scene) return NO;
    static Class cWidget = Nil, cAvocado = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cWidget  = objc_getClass("CHUISWidgetScene");
        cAvocado = objc_getClass("CHUISAvocadoWindowScene");
    });
    if (cWidget  && [scene isKindOfClass:cWidget])  return YES;
    if (cAvocado && [scene isKindOfClass:cAvocado]) return YES;
    NSString *cn = NSStringFromClass([scene class]);
    if ([cn containsString:@"CHUIS"] &&
        ([cn containsString:@"Widget"] || [cn containsString:@"Avocado"])) return YES;
    return NO;
}

// ⭐ 白名单：只处理 Remove Widget Background 已验证支持的 widget（照其默认名单）。
//   非白名单 widget 一律不碰 —— 实测对它们抹除会让 widget 变纯黑块。
static NSSet *sbs_widgetWhitelist(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            // ── 系统 widget ──
            @"com.apple.mobiletimer.WorldClockWidget",                          // 时钟
            @"com.apple.mobilecal.CalendarWidgetExtension",                     // 日历
            @"com.apple.mobilemail.MailWidgetExtension",                        // 邮件
            @"com.apple.ScreenTimeWidgetApplication.ScreenTimeWidgetExtension", // 使用时间
            @"com.apple.reminders.WidgetExtension",                             // 提醒事项
            @"com.apple.weather.widget",                                        // 天气
            @"com.apple.Fitness.FitnessWidget",                                 // 健身
            @"com.apple.Passbook.PassbookWidgets",                              // 钱包
            @"com.apple.Health.Sleep.SleepWidgetExtension",                     // 睡眠
            @"com.apple.tips.TipsSwift",                                        // 提示
            @"com.apple.Music.MusicWidgets",                                    // 音乐
            @"com.apple.gamecenter.widgets.extension",                          // Game Center
            @"com.apple.tv.TVWidgetExtension",                                  // TV
            @"com.apple.news.widget",                                           // Apple News
            // ── 第三方 widget ──
            @"com.growing.topwidgetsplus.Widget",           // Top Widgets
            @"dk.simonbs.Scriptable.ScriptableWidget",      // Scriptable
            @"wiki.qaq.trapp.LaunchPad",                    // 巨魔录音机
        ]];
    });
    return s;
}

// 取 widget 宿主场景的 extensionBundleIdentifier（KVC，零链接期私有符号；取不到返回 nil）
static NSString *sbs_widgetBundleIDOfScene(id scene) {
    if (!scene) return nil;
    @try {
        id widget = [scene valueForKey:@"widget"];
        if (!widget) return nil;
        id bid = [widget valueForKey:@"extensionBundleIdentifier"];
        if ([bid isKindOfClass:[NSString class]] && [bid length]) return bid;
    } @catch (NSException *e) { }
    return nil;
}

// 取 widget 宿主 ViewController 的 extensionBundleIdentifier（SB 侧）
static NSString *sbs_widgetBundleIDOfHost(id vc) {
    if (!vc) return nil;
    @try {
        id widget = [vc valueForKey:@"widget"];
        if (!widget) return nil;
        id bid = [widget valueForKey:@"extensionBundleIdentifier"];
        if ([bid isKindOfClass:[NSString class]] && [bid length]) return bid;
    } @catch (NSException *e) { }
    return nil;
}

// 该宿主是否命中白名单（未命中 ⇒ 一律走原实现，绝不干预）
static BOOL sbs_hostIsWhitelisted(id vc) {
    NSString *bid = sbs_widgetBundleIDOfHost(vc);
    return bid && [sbs_widgetWhitelist() containsObject:bid];
}

// 窗口是否为我们【已打标且在白名单内】的小组件宿主窗口。
// ⚠️ 实测 rootViewController 恒为 nil（类名兜底判据不可用）⇒ 只认窗口标记，避免误伤非白名单 widget。
static BOOL sbs_windowLooksLikeWidgetHost(UIWindow *w) {
    if (!w) return NO;
    return [objc_getAssociatedObject(w, kSBSWbgWindowMark) boolValue];
}

// ── 小组件宿主视图树 dump（诊断用，gWbgDump 关掉即静默）──
static BOOL gWbgDump = YES;
static int  gWbgDumpBudget = 0;

static void sbs_dumpSubtree(UIView *v, int depth, int maxDepth) {
    if (!v || depth > maxDepth || gWbgDumpBudget <= 0) return;
    gWbgDumpBudget--;
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"··"];
    sbs_logNow(@"[wbg-tree]%@%@ f=%@ a=%.2f hid=%d layer=%@",
               pad, NSStringFromClass(v.class), NSStringFromCGRect(v.frame),
               v.alpha, v.hidden, NSStringFromClass(v.layer.class));
    for (UIView *s in v.subviews) sbs_dumpSubtree(s, depth + 1, maxDepth);
}

static void sbs_dumpLayers(CALayer *l, int depth, int maxDepth) {
    if (!l || depth > maxDepth || gWbgDumpBudget <= 0) return;
    gWbgDumpBudget--;
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"··"];
    sbs_logNow(@"[wbg-layer]%@%@ f=%@ bg=%@ op=%.2f",
               pad, NSStringFromClass(l.class), NSStringFromCGRect(l.frame),
               l.backgroundColor ? @"有" : @"nil", l.opacity);
    for (CALayer *s in l.sublayers) sbs_dumpLayers(s, depth + 1, maxDepth);
}

@interface SBSHelper : NSObject
@end

@implementation SBSHelper
// Core Animation 可能直接生成实时活动外框纹理；记录 display/drawInContext 入口。
- (void)sbs_layerDisplay {
    CALayer *layer = (CALayer *)self;
    sbs_logApertureRenderLayer(layer, @"display", NULL);
    [self sbs_layerDisplay];
}

- (void)sbs_layerDrawInContext:(CGContextRef)ctx {
    CALayer *layer = (CALayer *)self;
    sbs_logApertureRenderLayer(layer, @"drawInContext", ctx);
    [self sbs_layerDrawInContext:ctx];
}

- (void)sbs_viewDrawLayer:(CALayer *)layer inContext:(CGContextRef)ctx {
    if (layer && sbs_isApertureLayer(layer))
        sbs_logApertureRenderLayer(layer, @"delegateDrawLayer", ctx);
    [self sbs_viewDrawLayer:layer inContext:ctx];
}

// System Aperture 的外框可能来自私有 UIView 的自定义 drawRect，而非 layer 属性。
// 先记录真实绘制入口与实例，再决定是否仅跳过外壳绘制，避免误删倒计时/圆环内容。
- (void)sbs_apertureDrawRect:(CGRect)rect {
    UIView *v = (UIView *)self;
    static NSMutableSet *seen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSString *key = [NSString stringWithFormat:@"%@/%p", NSStringFromClass(v.class), v];
    if (![seen containsObject:key] && seen.count < 80) {
        [seen addObject:key];
        sbs_logNow(@"[apertureDraw] class=%@ self=%p rect=%@ frame=%@ sub=%lu hidden=%d alpha=%.2f",
                   NSStringFromClass(v.class), v, NSStringFromCGRect(rect), NSStringFromCGRect(v.frame),
                   (unsigned long)v.subviews.count, v.hidden, v.alpha);
    }
    [self sbs_apertureDrawRect:rect];
}

- (void)sbs_apertureLayoutSubviews {
    UIView *v = (UIView *)self;
    static NSMutableSet *seen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSString *key = [NSString stringWithFormat:@"%@/%p", NSStringFromClass(v.class), v];
    if (![seen containsObject:key] && seen.count < 80) {
        [seen addObject:key];
        sbs_logNow(@"[apertureLayout] class=%@ self=%p frame=%@ sub=%lu hidden=%d alpha=%.2f",
                   NSStringFromClass(v.class), v, NSStringFromCGRect(v.frame),
                   (unsigned long)v.subviews.count, v.hidden, v.alpha);
    }
    [self sbs_apertureLayoutSubviews];
    @try { sbs_suppressApertureKeylines(v); }
    @catch (NSException *e) { sbs_logNow(@"[exc-apertureKeyline] %@", e); }
}

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

// 搜索框及其材质子视图在资源库滑动转场中会动态挂窗；即时清理，不依赖 windows 扫描。
- (void)sbs_viewDidMoveToWindow {
    [self sbs_viewDidMoveToWindow];
    UIView *v = (UIView *)self;
    NSString *cn = NSStringFromClass(v.class);
    // 全局 didMoveToWindow 也属于控制中心转场热路径：只检查搜索类本身或材质候选，
    // 避免每个新挂窗视图都遍历祖先链。
    if ([cn containsString:@"Search"])
        sbs_clearSearchFieldBg(v);
    else if (sbs_isSearchBackgroundView(v)) {
        v.hidden = YES;
        v.backgroundColor = [UIColor clearColor];
    }
}

// 系统切换资源库可见性时可能把材质背景重新设为可见，立即压回隐藏状态。
- (void)sbs_viewSetHidden:(BOOL)h {
    UIView *v = (UIView *)self;
    BOOL keyline = sbs_isManagedApertureKeyline(v);
    if (!h && sbs_isSearchBackgroundView(v)) h = YES;
    if (keyline && !h) h = YES;
    [self sbs_viewSetHidden:h];
    if (keyline && !v.layer.hidden) v.layer.hidden = YES;
}

// 系统重设材质背景色时立即清透明；不影响搜索框内的图标和文字。
- (void)sbs_viewSetBackgroundColor:(UIColor *)c {
    UIView *v = (UIView *)self;
    if (sbs_isSearchBackgroundView(v)) c = [UIColor clearColor];
    [self sbs_viewSetBackgroundColor:c];
}

// 系统可能用 alpha 而不是 hidden 切换 key-line，两个入口都要拦截。
- (void)sbs_viewSetAlpha:(CGFloat)a {
    UIView *v = (UIView *)self;
    BOOL keyline = sbs_isManagedApertureKeyline(v);
    if (keyline && a > 0.0) a = 0.0;
    [self sbs_viewSetAlpha:a];
    if (keyline && v.layer.opacity > 0.0f) v.layer.opacity = 0.0f;
}

// 实时活动外框实际会在 CALayer 写入口被系统恢复；拦截写入而不是只做一次清理。
- (void)sbs_layerSetBorderColor:(CGColorRef)c {
    if (sbs_isApertureLayer((CALayer *)self)) c = [UIColor clearColor].CGColor;
    [self sbs_layerSetBorderColor:c];
}

- (void)sbs_layerSetBorderWidth:(CGFloat)w {
    if (sbs_isApertureLayer((CALayer *)self)) w = 0.0;
    [self sbs_layerSetBorderWidth:w];
}

- (void)sbs_shapeSetStrokeColor:(CGColorRef)c {
    if (sbs_isApertureLayer((CALayer *)self)) c = [UIColor clearColor].CGColor;
    [self sbs_shapeSetStrokeColor:c];
}

- (void)sbs_shapeSetLineWidth:(CGFloat)w {
    if (sbs_isApertureLayer((CALayer *)self)) w = 0.0;
    [self sbs_shapeSetLineWidth:w];
}

- (void)sbs_layerSetShadowColor:(CGColorRef)c {
    if (sbs_isApertureLayer((CALayer *)self)) c = [UIColor clearColor].CGColor;
    [self sbs_layerSetShadowColor:c];
}

- (void)sbs_layerSetShadowOpacity:(float)o {
    if (sbs_isApertureLayer((CALayer *)self)) o = 0.0f;
    [self sbs_layerSetShadowOpacity:o];
}

- (void)sbs_layerSetShadowRadius:(CGFloat)r {
    if (sbs_isApertureLayer((CALayer *)self)) r = 0.0;
    [self sbs_layerSetShadowRadius:r];
}

- (void)sbs_layerSetShadowPath:(CGPathRef)p {
    if (sbs_isApertureLayer((CALayer *)self)) p = nil;
    [self sbs_layerSetShadowPath:p];
}

- (void)sbs_layerSetHidden:(BOOL)h {
    CALayer *layer = (CALayer *)self;
    if (sbs_isManagedApertureKeylineLayer(layer) && !h) h = YES;
    [self sbs_layerSetHidden:h];
}

- (void)sbs_layerSetOpacity:(float)o {
    CALayer *layer = (CALayer *)self;
    if (sbs_isManagedApertureKeylineLayer(layer) && o > 0.0f) o = 0.0f;
    [self sbs_layerSetOpacity:o];
}

// ⭐⭐ v2.1.2：系统会【反复重设】该背景视图的 backgroundColor / hidden
//   （实测每轮扫描都能撞见 hidden=0 bgA=1.00 的"新"实例）⇒ 单纯定时清会被系统盖回去。
//   必须在【设置入口】拦截：无论系统设什么，统一改成透明/隐藏。
- (void)sbs_podBgSetBackgroundColor:(UIColor *)c {
    if ([NSStringFromClass(((UIView *)self).class) containsString:@"Library"])
        c = [UIColor clearColor];
    [self sbs_podBgSetBackgroundColor:c];
}

- (void)sbs_podBgSetHidden:(BOOL)h {
    if ([NSStringFromClass(((UIView *)self).class) containsString:@"Library"])
        h = YES;
    [self sbs_podBgSetHidden:h];
}

// 资源库搜索框背景透明：hook SBHSearchTextField -layoutSubviews
- (void)sbs_searchFieldLayout {
    [self sbs_searchFieldLayout];   // 原实现
    @try { sbs_clearSearchFieldBg((UIView *)self); }
    @catch (NSException *e) { sbs_log(@"[exc-searchbg] %@", e); }
}

// 资源库文件夹背景透明：hook _SBHLibraryCategoryStackViewBackgroundView -layoutSubviews
- (void)sbs_libBgLayout {
    [self sbs_libBgLayout];      // 原实现
    @try { sbs_clearLibFolderBg((UIView *)self); }
    @catch (NSException *e) { sbs_log(@"[exc-libbg] %@", e); }
}

// 状态栏 foreground view 被重新挂到 window（App↔主屏切换/锁屏解锁）时补多次。
- (void)sbs_fgDidMoveToWindow {
    [self sbs_fgDidMoveToWindow];         // 原实现
    @try {
        if (gVerbose) sbs_log(@"[didMove] self=%@ win=%@",
            NSStringFromClass(((UIView *)self).class),
            ((UIView *)self).window ? @"有" : @"nil");
        // 挂载后的布局尚未发生时，子视图可能还没建好 → 下一 runloop 补施
        // ⭐ v1.4.5 多档补触发：退出 App 回主屏时主屏 fg 可能不触发 layoutSubviews
        //    （实测 home 后零布局），0.3s 单次触发不够 —— 多档重试覆盖切换动画全周期。
        for (int i = 0; i < 3; i++) {
            NSTimeInterval delay = (i == 0 ? 0.0 : (i == 1 ? 0.3 : 0.8));
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

#pragma mark - 小组件（Widget）背景移除 · 渲染进程侧（v2.2.0）
// 手法来源：RemoveWidgetBackground（MIT，OwnGoal Studio / Lessica）。
// 只对"已打标的 widget 宿主窗口"的绘制生效，绝不做全局改写。

// UIWindow -initWithWindowScene: —— widget 宿主窗口一创建就打标
- (id)sbs_wbgWindowInitWithWindowScene:(UIWindowScene *)scene {
    BOOL isWidgetScene = sbs_isWidgetScene(scene);
    NSString *wid = isWidgetScene ? sbs_widgetBundleIDOfScene(scene) : nil;
    BOOL mark = isWidgetScene && wid && [sbs_widgetWhitelist() containsObject:wid];
    if (isWidgetScene) {
        static int loggedScene = 0;
        if (loggedScene < 24) {
            loggedScene++;
            SBS_WLOG(@"widget scene id=%@ 白名单=%d", wid ?: @"(nil)", mark);
        }
    } else if (scene) {
        static int loggedNon = 0;
        if (loggedNon < 8) {
            loggedNon++;
            SBS_WLOG(@"scene 非 widget: %@", NSStringFromClass([scene class]));
        }
    }
    id w = [self sbs_wbgWindowInitWithWindowScene:scene];
    // ⭐⭐ 强制暗色（对齐官方 RWB：对所有 widget 窗口无条件强制 dark，不只白名单）。
    //    这是 RBShape 抹除生效的前提 —— 暗色下背景板才以独立超阈值矩形呈现，可被尺寸分离。
    if (w && isWidgetScene) {
        [(UIWindow *)w setOverrideUserInterfaceStyle:UIUserInterfaceStyleDark];
    }
    if (mark && w) {
        objc_setAssociatedObject(w, kSBSWbgWindowMark, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIWindow *win = (UIWindow *)w;
        sbs_logNow(@"[wbg] widget 窗口打标 %.0fx%.0f id=%@（已强制暗色）",
                   win.bounds.size.width, win.bounds.size.height, wid);
        SBS_WLOG(@"打标 %.0fx%.0f id=%@（已强制暗色）", win.bounds.size.width, win.bounds.size.height, wid);
    }
    return w;
}

// RBLayer -display —— 渲染期置/清线程标记（SwiftUI 绘制命令在同一线程下发）
- (void)sbs_wbgRBLayerDisplay {
    UIView *view = (UIView *)((CALayer *)self).delegate;
    BOOL hide = NO;
    BOOL isView = [view isKindOfClass:[UIView class]];
    if (isView) hide = sbs_windowLooksLikeWidgetHost(view.window);
    static int loggedHit = 0, loggedMiss = 0;
    if (hide) {
        if (loggedHit++ < 4) SBS_WLOG(@"RBLayer 命中 widget 窗口 → 进入涂抹模式");
    } else if (isView && loggedMiss++ < 5) {
        SBS_WLOG(@"RBLayer 非 widget 窗口 win=%@ rvc=%@",
                 NSStringFromClass([view.window class]),
                 NSStringFromClass([[view.window rootViewController] class]));
    }
    if (hide) {
        NSMutableDictionary *td = [NSThread currentThread].threadDictionary;
        td[kSBSWbgThreadFlag] = @YES;
        [td removeObjectForKey:kSBSWbgSkipN];
        [self sbs_wbgRBLayerDisplay];
        [td removeObjectForKey:kSBSWbgThreadFlag];
        [td removeObjectForKey:kSBSWbgSkipN];
        return;
    }
    [self sbs_wbgRBLayerDisplay];
}

// RBShape -setRect: —— 「限制绘制命令尺寸」：超过阈值的绘制矩形归零 ⇒ 背景板不画
- (void)sbs_wbgRBShapeSetRect:(CGRect)rect {
    NSMutableDictionary *td = [NSThread currentThread].threadDictionary;
    // 诊断：把标记生效期内见到的绘制矩形全量记前 30 条（用于标定阈值与坐标系）
    if (td[kSBSWbgThreadFlag]) {
        static int seen = 0;
        if (seen < 30) {
            seen++;
            SBS_WLOG(@"rect %.0fx%.0f (阈值 %.0fx%.0f)",
                     rect.size.width, rect.size.height, gWidgetMaxW, gWidgetMaxH);
        }
    }
    if (td[kSBSWbgThreadFlag] && gWidgetBgClear &&
        rect.size.width > gWidgetMaxW && rect.size.height > gWidgetMaxH) {
        int passed = [td[kSBSWbgSkipN] intValue];
        td[kSBSWbgSkipN] = @(passed + 1);
        if (passed >= gWidgetSkipN) {      // 跳过前 gWidgetSkipN 个（第 1 个=内容根层），第 2+ 个=背景板 → 抹除
            SBS_WLOG(@"抹除 %.0fx%.0f (第%d个)", rect.size.width, rect.size.height, passed + 1);
            [self sbs_wbgRBShapeSetRect:CGRectZero];
            return;
        }
        SBS_WLOG(@"跳过 %.0fx%.0f (第%d个)", rect.size.width, rect.size.height, passed + 1);
    }
    [self sbs_wbgRBShapeSetRect:rect];
}

#pragma mark - 小组件（Widget）背景移除 · SpringBoard 侧（v2.2.0）
// SB 里的 widget 宿主视图控制器会主动给 widget 加背景材质 / 快照。
// 在"设置入口"拦掉 ⇒ 背景板不会出现（不需要注入渲染进程）。

// ⭐⭐ SB 侧核心招式（对齐上游 RWB）：**白名单命中才**阻止系统给 widget 铺背景材质 / 生成快照。
//   ⚠️ 必须带白名单条件 —— 实测无条件 return 会把非白名单 widget（支付宝）打成纯黑圆角块。
- (void)sbs_wbgHostUpdateBgMaterial {
    if (sbs_hostIsWhitelisted(self)) {
        static int n = 0;
        if (n < 8) { n++; SBS_WLOG(@"[材质] 拦下背景材质更新 id=%@", sbs_widgetBundleIDOfHost(self)); }
        return;      // 不调 orig：系统这次不会给 widget 铺背景材质
    }
    [self sbs_wbgHostUpdateBgMaterial];
}

- (void)sbs_wbgHostUpdateSnapshot {
    if (sbs_hostIsWhitelisted(self)) {
        static int n = 0;
        if (n < 8) { n++; SBS_WLOG(@"[快照] 拦下 %@", NSStringFromSelector(_cmd)); }
        return;
    }
    [self sbs_wbgHostUpdateSnapshot];
}

// ⚠️ 必须用【独立方法】挂第二个 selector：同一实现挂两个 selector 时，
//    swizzle 交换会互相覆盖，导致 orig 回调指错（递归/失效）。
- (void)sbs_wbgHostUpdateSnapshot2 {
    if (sbs_hostIsWhitelisted(self)) {
        static int n = 0;
        if (n < 8) { n++; SBS_WLOG(@"[快照2] 拦下 %@", NSStringFromSelector(_cmd)); }
        return;
    }
    [self sbs_wbgHostUpdateSnapshot2];
}

- (id)sbs_wbgHostScreenshotManager {
    if (sbs_hostIsWhitelisted(self)) return nil;   // 快照通常带背景板 ⇒ 不生成
    return [self sbs_wbgHostScreenshotManager];
}

// iOS 16.0-16.2：从 URL 加载持久化快照 —— 白名单命中返回 nil（阻止加载带背景的快照）
- (id)sbs_wbgHostSnapshotImageFromURL:(id)arg1 {
    if (sbs_hostIsWhitelisted(self)) return nil;
    return [self sbs_wbgHostSnapshotImageFromURL:arg1];
}

- (unsigned long long)sbs_wbgHostColorScheme {
    if (sbs_hostIsWhitelisted(self)) return 2;     // 强制暗色（对齐上游，需与材质拦截配套）
    return [self sbs_wbgHostColorScheme];
}

- (void)sbs_wbgHostViewWillAppear:(BOOL)animated {
    [self sbs_wbgHostViewWillAppear:animated];   // 原实现
    @try {
        UIViewController *vc = (UIViewController *)self;
        UIView *root = vc.view;
        // 诊断：dump 宿主视图/图层真实结构（前 3 次，预算限条数，避免刷屏）
        if (gWbgDump && root) {
            static int dumped = 0;
            if (dumped < 3) {
                dumped++;
                gWbgDumpBudget = 240;
                sbs_logNow(@"[wbg-dump] 宿主 %@ view=%@ frame=%@ sub=%lu",
                           NSStringFromClass([vc class]), NSStringFromClass([root class]),
                           NSStringFromCGRect(root.frame), (unsigned long)root.subviews.count);
                sbs_dumpSubtree(root, 0, 5);
                gWbgDumpBudget = 180;
                sbs_dumpLayers(root.layer, 0, 4);
            }
        }
        // 温和处理：材质类视图 alpha 归零（绝不拦截系统设置入口 —— 实测会把 widget 打成黑块）
        UIView *v = root;
        for (int depth = 0; depth < 4 && v; depth++) {
            for (UIView *sub in v.subviews) {
                BOOL isMat = [sub isKindOfClass:[UIVisualEffectView class]] ||
                             [NSStringFromClass(sub.class) containsString:@"Material"];
                if (isMat && sub.alpha > 0.01) {
                    sub.alpha = 0.0;
                    sbs_logNow(@"[wbg-sb] 材质 alpha=0 %@ depth=%d",
                               NSStringFromClass(sub.class), depth);
                }
            }
            v = v.subviews.firstObject;
        }
    } @catch (NSException *e) { sbs_log(@"[exc-wbg] %@", e); }
}

#pragma mark - 小组件背景移除 · 对照 Remove Widget Background 补齐（2026-10-09）
// ⭐⭐ 实测结论：官方 RWB v2.1.1 在本机【有效】（时钟 widget 背景板消失、内容完整）。
//   对比其源码，我此前漏掉的关键招式是下面几条 —— 都只动"视图背景色 / 材质 alpha"，
//   绝不碰绘制命令，所以不会把 widget 打成黑块。

// ① chronod 侧：UIView -layoutSubviews —— 非 SwiftUI 宿主视图一律清背景色。
//    （上游 RWB 的原话注释：这是把 widget 宿主视图的底色清掉，最温和也最有效的一招）
- (void)sbs_wbgViewLayoutSubviews {
    [self sbs_wbgViewLayoutSubviews];      // 原实现
    // ⚠️ 这是全局高频 hook（每次布局都来）⇒ 先做最便宜的判断：无背景色直接返回。
    UIView *v = (UIView *)self;
    UIColor *bg = v.backgroundColor;
    if (!bg || CGColorGetAlpha(bg.CGColor) <= 0.01) return;
    NSString *cn = NSStringFromClass([self class]);
    if ([cn containsString:@"UIHostingView"]) return;   // SwiftUI 宿主视图不动
    v.backgroundColor = [UIColor clearColor];           // 幂等：有颜色才写
    static int n = 0;
    if (n < 10) { n++; SBS_WLOG(@"清底 %@", cn); }
}

// ② SB 侧：SBHWidgetStackViewController / WGWidgetListItemViewController
//    viewWillAppear: → 【两层】firstObject 若是材质视图 ⇒ alpha = 0
//    ⚠️ 此前我只扫了一层 subviews ⇒ 没命中（上游是 firstChild.subviews.firstObject）
- (void)sbs_wbgStackViewWillAppear:(BOOL)animated {
    [self sbs_wbgStackViewWillAppear:animated];
    @try {
        UIView *first = ((UIViewController *)self).view.subviews.firstObject;
        UIView *target = first.subviews.firstObject;
        NSString *cn = NSStringFromClass([target class]);
        if ([target isKindOfClass:[UIVisualEffectView class]] || [cn containsString:@"Material"]) {
            target.alpha = 0.0;
            SBS_WLOG(@"[栈] 材质 alpha=0 %@", cn);
        }
    } @catch (NSException *e) { sbs_log(@"[exc-wbg2] %@", e); }
}

// ③ SB 侧：SBHWidgetViewController（iOS 15 风格单 widget 宿主）
//    viewWillAppear: → firstObject 若是 UIVisualEffectView ⇒ alpha = 0
- (void)sbs_wbgSingleViewWillAppear:(BOOL)animated {
    [self sbs_wbgSingleViewWillAppear:animated];
    @try {
        UIView *first = ((UIViewController *)self).view.subviews.firstObject;
        if ([first isKindOfClass:[UIVisualEffectView class]]) {
            first.alpha = 0.0;
            SBS_WLOG(@"[单] 材质 alpha=0 %@", NSStringFromClass([first class]));
        }
    } @catch (NSException *e) { sbs_log(@"[exc-wbg3] %@", e); }
}

// ── chronod 侧强制暗色（对齐官方 RWB，无条件 return 2，与 RBShape 抹除配套）──
//   ⚠️ 缺这些 hook 时，widget 在浅色下渲染 → 背景板与内容同尺寸 → RBShape 抹除误伤/无效。
// CHUISWidgetScene.colorScheme（返回 unsigned long long，与 SB 侧 host 一致）
- (unsigned long long)sbs_wbgSceneColorScheme {
    return 2;
}
// CHSMutableScreenshotPresentationAttributes / CHSScreenshotPresentationAttributes.colorScheme（返回 long long）
- (long long)sbs_wbgAttrColorScheme {
    return 2;
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

// 枚举当前 ObjC runtime 中带 SystemAperture/LiveActivity 语义的 UIView 类，
// 只 hook 由该类自身定义的 drawRect:/layoutSubviews，避免重复交换继承方法。
static void sbs_installApertureRenderProbes(void) {
    int num = objc_getClassList(NULL, 0);
    if (num <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * num);
    num = objc_getClassList(classes, num);
    NSUInteger draws = 0, layouts = 0, matched = 0;
    Class viewClass = [UIView class];
    for (int i = 0; i < num; i++) {
        Class c = classes[i];
        if (!c || c == viewClass) continue;
        BOOL isView = NO;
        for (Class p = c; p; p = class_getSuperclass(p)) {
            if (p == viewClass) { isView = YES; break; }
        }
        if (!isView) continue;
        NSString *name = NSStringFromClass(c);
        if (![name containsString:@"Aperture"] && ![name containsString:@"LiveActivity"] &&
            ![name containsString:@"DynamicIsland"]) continue;
        matched++;
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        BOOL hasDraw = NO, hasLayout = NO;
        for (unsigned int j = 0; j < count; j++) {
            SEL sel = method_getName(methods[j]);
            if (sel == @selector(drawRect:)) hasDraw = YES;
            if (sel == @selector(layoutSubviews)) hasLayout = YES;
        }
        free(methods);
        if (hasDraw && SBSHook(c, @selector(drawRect:), SBSHelper.class, @selector(sbs_apertureDrawRect:))) draws++;
        // Container 的 layoutSubviews 由正式 key-line hook 独占，避免诊断模式重复交换。
        if (hasLayout && ![name containsString:@"SystemApertureContainerView"] &&
            SBSHook(c, @selector(layoutSubviews), SBSHelper.class, @selector(sbs_apertureLayoutSubviews))) layouts++;
    }
    free(classes);
    sbs_logNow(@"[apertureRenderHook] matched=%lu draw=%lu layout=%lu",
               (unsigned long)matched, (unsigned long)draws, (unsigned long)layouts);
}

// ===========================================================================
// 功能：资源库（App Library）文件夹背景透明
//
// 实机 dump（2026-10-07，SpringBoard，iOS 16.5.1）确认的视图结构：
//   _SBHLibraryPodIconListView            (资源库滚动列表)
//     _SBHLibraryPodIconView  {170×184}   (每个分类卡片)
//       SBHLibraryCategoryPodBackgroundView {170×170}  ← ★ 本 hook 的 self（背景板）
//       SBHLibraryCategoryPodIconListView  {170×170}   (图标层，兄弟节点，不动)
//         SBHLibraryCategoryPodIconView ×4
//   ⚠️ 勿hook _SBHLibraryCategoryStackViewBackgroundView —— 那是【Dock 上"App 资源库"
//      按钮的图标】(挂在 SBFloatingDockWindow)，不是页面里的卡片。
//
// 策略：把 backgroundView 自身及其子树的实色背景清成透明、材质(毛玻璃)视图隐藏；
//       应用图标(UIImageView)与文字(UILabel)一律保留。
// 安全门禁：类名必须含 "Library" ⇒ 绝不误伤主屏 App 文件夹或系统其它 MTMaterialView。
// ===========================================================================
static BOOL gLibBgClear = YES;   // 资源库文件夹背景透明 总开关

// 递归清背景（深度 4）
static void sbs_clearBgRecursive(UIView *v, int depth) {
    if (!v || depth > 4) return;
    NSString *cn = NSStringFromClass(v.class);
    if ([cn containsString:@"Material"] || [v isKindOfClass:[UIVisualEffectView class]]) {
        v.hidden = YES;                                      // 毛玻璃/材质 → 隐藏
        return;
    }
    if (![v isKindOfClass:[UIImageView class]] && ![v isKindOfClass:[UILabel class]]) {
        UIColor *c = v.backgroundColor;
        if (c && CGColorGetAlpha(c.CGColor) > 0.01)
            v.backgroundColor = [UIColor clearColor];        // 实色背景 → 透明
    }
    for (UIView *s in v.subviews) sbs_clearBgRecursive(s, depth + 1);
}

static void sbs_clearLibFolderBg(UIView *bgv) {
    if (!gLibBgClear || !bgv) return;
    if (![NSStringFromClass(bgv.class) containsString:@"Library"]) return;   // 门禁
    // ⭐ v2.1.2：实测该视图【无任何子视图 ⇒ 纯背景】⇒ 整块隐藏最彻底。
    //    只清 backgroundColor 对"自绘背景"无效 —— "建议/最近添加"就是这么漏掉的。
    static int n = 0;
    BOOL was = bgv.hidden;
    bgv.hidden = YES;
    bgv.layer.hidden = YES;   // ⭐ v2.1.2：layer 级隐藏 —— 绕开 view.hidden 被系统复位的路径
    if (n < 5) {
        n++;
        sbs_logNow(@"[libBg] 命中 %@ frame=%@ 原hidden=%d bgA=%.2f",
                   NSStringFromClass(bgv.class), NSStringFromCGRect(bgv.frame), was,
                   bgv.backgroundColor ? CGColorGetAlpha(bgv.backgroundColor.CGColor) : -1.0);
    }
    UIColor *c = bgv.backgroundColor;
    if (c && CGColorGetAlpha(c.CGColor) > 0.01) bgv.backgroundColor = [UIColor clearColor];
    for (UIView *s in bgv.subviews) sbs_clearBgRecursive(s, 0);
}

// ===========================================================================
// 功能：资源库顶部搜索框背景透明（v2.1.1）
//
// 实机 dump（hitTest(215,99)，SpringBoard，iOS 16.5.1）：
//   SBHSearchBar {430×147}
//     SBHSearchTextField {33,75,364,48}            ← 本 hook 的 self
//       MTMaterialView {0,0,364,48}                ← ★ 背景材质（毛玻璃）→ 隐藏
//       UIImageView（放大镜）/ UISearchBarTextFieldLabel（"App 资源库"）→ 保留
// ===========================================================================
static void sbs_clearSearchFieldBg(UIView *tf) {
    if (!gLibBgClear || !tf) return;
    if (![NSStringFromClass(tf.class) containsString:@"Search"]) return;   // 仅处理搜索框类
    static BOOL logged = NO;
    int hid = 0, clr = 0;
    for (UIView *s in tf.subviews) {
        NSString *cn = NSStringFromClass(s.class);
        if ([cn containsString:@"Material"] || [s isKindOfClass:[UIVisualEffectView class]]) {
            s.hidden = YES; hid++;                                         // 材质背景 → 隐藏
            continue;
        }
        if ([s isKindOfClass:[UIImageView class]] || [s isKindOfClass:[UILabel class]]) continue;
        UIColor *c = s.backgroundColor;
        if (c && CGColorGetAlpha(c.CGColor) > 0.01) { s.backgroundColor = [UIColor clearColor]; clr++; }
    }
    if (!logged) {          // 首次调用取证：门禁是否通过 + 实际动了几个视图
        logged = YES;
        sbs_logNow(@"[searchBg] cls=%@ 直接子视图=%lu → 隐藏材质%d 清背景%d",
                   NSStringFromClass(tf.class), (unsigned long)tf.subviews.count, hid, clr);
    }
}

// ⚠️ 实测（11:41）：单独 hook SBHSearchTextField -layoutSubviews【不触发】——
//   搜索框是常驻视图（随 SpringBoard 启动就在树里），进入资源库时只改可见性、
//   不重新布局 ⇒ layoutSubviews 不再调用。故必须【主动扫描】兜底。
// ⚠️⚠️ 关键：资源库页面所在的窗口**不在** [UIApplication sharedApplication].windows 里
//   （实测打点 (38,250) 处只有窗口层、扫到的 8 个 backgroundView 全是离屏副本）
//   ⇒ 统一用 connectedScenes 收集【所有场景】的窗口。
static NSArray<UIWindow *> *sbs_allWindows(void) {
    // ⚠️ 实测：connectedScenes 收不到资源库所在的 SBHomeScreenWindow（返回 0 个 Pod），
    //    却会混入控制中心等后台场景 ⇒ 以 [UIApplication windows] 为准。
    return [UIApplication sharedApplication].windows;
}

// ⚠️ 实测（11:52）：hook `SBHLibraryCategoryPodBackgroundView -layoutSubviews` **不可靠** ——
//   普通分类卡片透明了，但"建议/最近添加"两行没变（探针实测其 bgA 仍 = 1.00、hid = 0，
//   说明清理根本没执行到）⇒ 部分实例创建后不再重布局，hook 不触发。
//   ⇒ 统一改为【主动扫描】兜底（与搜索框同一套机制，0.5s 一轮）。
static void sbs_sweepAll(void) {
    Class PODBG = objc_getClass("SBHLibraryCategoryPodBackgroundView");
    NSMutableArray *stack = [NSMutableArray array];
    for (UIWindow *w in sbs_allWindows()) [stack addObject:w];
    int guard = 0;
    int podHit = 0, podDirty = 0;
    // ⚠️ 上限 20000 → 200000：资源库页面 + SpringBoard 整个视图树节点数远超 2 万，
    //    旧上限会让遍历提前中断、后段的 backgroundView 根本没被扫到（"建议/最近添加"漏掉的原因）
    while (stack.count && guard++ < 200000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (PODBG && [v isKindOfClass:PODBG]) {
            podHit++;
            if (v.backgroundColor && CGColorGetAlpha(v.backgroundColor.CGColor) > 0.01) podDirty++;
            sbs_clearLibFolderBg(v);
        }
        else if ([NSStringFromClass(v.class) containsString:@"Search"])
            sbs_clearSearchFieldBg(v);
        for (UIView *c in v.subviews) [stack addObject:c];
    }
    {   // 每 2s 记一次统计：若 podDirty 持续 > 0 ⇒ 系统在改回；若恒为 0 ⇒ 处理已生效
        static NSTimeInterval last = 0;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (now - last > 2.0) {
            last = now;
            sbs_logNow(@"[sweep] 节点=%d bg视图=%d 其中带色=%d", guard, podHit, podDirty);
        }
    }
}

// 延迟安装资源库相关 hook（类可能晚于 ctor 加载；避开 ctor 阶段触发 +initialize 的风险）
static void sbs_installLibBgHook(void) {
    static int tries = 0;
    static BOOL bgDone = NO;
    static BOOL sfDone = NO;
    if (bgDone && sfDone) return;
    Class BG = objc_getClass("SBHLibraryCategoryPodBackgroundView");
    Class SF = objc_getClass("SBHSearchTextField");
    if (!BG && !SF) {
        if (tries++ < 40)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ sbs_installLibBgHook(); });
        else
            sbs_logNow(@"[hook] 资源库相关类等待超时（%d 次）", tries);
        return;
    }
    if (BG && !bgDone) {
        BOOL ok  = SBSHook(BG, @selector(layoutSubviews), SBSHelper.class,
                           @selector(sbs_libBgLayout));
        BOOL ok2 = SBSHook(BG, @selector(setBackgroundColor:), SBSHelper.class,
                           @selector(sbs_podBgSetBackgroundColor:));
        BOOL ok3 = SBSHook(BG, @selector(setHidden:), SBSHelper.class,
                           @selector(sbs_podBgSetHidden:));
        sbs_logNow(@"[hook] 资源库背景 SBHLibraryCategoryPodBackgroundView → layout=%@ setBg=%@ setHidden=%@",
                   ok ? @"OK" : @"失败", ok2 ? @"OK" : @"失败", ok3 ? @"OK" : @"失败");
        bgDone = ok && ok2 && ok3;
    }
    if (SF && !sfDone) {
        BOOL ok = SBSHook(SF, @selector(layoutSubviews), SBSHelper.class,
                          @selector(sbs_searchFieldLayout));
        sbs_logNow(@"[hook] 资源库搜索框背景 SBHSearchTextField → %@",
                   ok ? @"已安装" : @"失败");
        sfDone = ok;
    }
    if (!(bgDone && sfDone) && tries++ < 40)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ sbs_installLibBgHook(); });
}

// 只扫描 UIView 树并精确命中 System Aperture 容器；不访问 CALayer 子树。
// 仅在 hook 安装成功后执行一次，用于处理安装前已经存在且暂未重新布局的实时活动。
static void sbs_suppressExistingApertureKeylines(UIView *v, int depth, int *hits) {
    if (!v || depth > 20) return;
    if ([NSStringFromClass(v.class) containsString:@"SystemApertureContainerView"]) {
        sbs_suppressApertureKeylines(v);
        if (hits) (*hits)++;
    }
    for (UIView *sub in v.subviews)
        sbs_suppressExistingApertureKeylines(sub, depth + 1, hits);
}

static void sbs_installApertureKeylineHook(void) {
    static BOOL done = NO;
    static int tries = 0;
    if (done) return;
    Class container = objc_getClass("SBSystemApertureContainerView");
    if (!container) {
        if (tries++ < 40)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ sbs_installApertureKeylineHook(); });
        return;
    }
    done = SBSHook(container, @selector(layoutSubviews), SBSHelper.class,
                   @selector(sbs_apertureLayoutSubviews));
    sbs_logNow(@"[hook] SystemAperture key-line 精确布局保护=%@",
               done ? @"OK" : @"失败");
    if (!done) return;

    int hits = 0;
    for (UIWindow *w in [UIApplication sharedApplication].windows)
        sbs_suppressExistingApertureKeylines(w, 0, &hits);
    sbs_logNow(@"[apertureKeyline] 启动定向扫描命中=%d", hits);
}

// 安装「小组件背景移除」hook —— 只在 widget 渲染进程（chronod / WidgetRenderer）调用。
// RBShape / RBLayer 是 SwiftUI 私有类，类可能晚于 ctor 加载 ⇒ 0.5s 间隔重试。
static void sbs_installWidgetBgHooks(void) {
    static BOOL shapeDone = NO, layerDone = NO, winTried = NO, csTried = NO;
    static int tries = 0;
    // ⚠️ 即使 gWidgetBgClear=NO（纯观测）也要装 hook —— 抹除与否在 setRect 内判定。
    if (!shapeDone || !layerDone) {
        Class clShape = objc_getClass("RBShape");
        Class clLayer = objc_getClass("RBLayer");
        if (!clShape || !clLayer) {
            if (tries++ < 60)
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                               ^{ sbs_installWidgetBgHooks(); });
            else
                sbs_logNow(@"[hook] 小组件渲染类等待超时 (RBShape=%d RBLayer=%d)",
                           clShape != Nil, clLayer != Nil);
            if (!clShape || !clLayer)
                SBS_WLOG(@"渲染类缺失 RBShape=%d RBLayer=%d", clShape != Nil, clLayer != Nil);
            return;
        }
        if (!shapeDone)
            shapeDone = SBSHook(clShape, @selector(setRect:), SBSHelper.class,
                                @selector(sbs_wbgRBShapeSetRect:));
        if (!layerDone)
            layerDone = SBSHook(clLayer, @selector(display), SBSHelper.class,
                                @selector(sbs_wbgRBLayerDisplay));
        sbs_logNow(@"[hook] 小组件渲染层 RBShape.setRect=%d RBLayer.display=%d",
                   shapeDone, layerDone);
        SBS_WLOG(@"hook 渲染层 RBShape=%d RBLayer=%d proc=%@",
                 shapeDone, layerDone, [[NSProcessInfo processInfo] processName]);
    }
    if (!winTried) {
        winTried = YES;
        BOOL ok = SBSHook([UIWindow class], @selector(initWithWindowScene:), SBSHelper.class,
                          @selector(sbs_wbgWindowInitWithWindowScene:));
        // ⭐⭐ 关键招式（此前遗漏）：清 widget 宿主视图的底色 —— 上游 RWB 的核心手段，
        //    只动 backgroundColor，不碰绘制命令，因此不会把 widget 打成黑块。
        BOOL clr = SBSHook([UIView class], @selector(layoutSubviews), SBSHelper.class,
                           @selector(sbs_wbgViewLayoutSubviews));
        sbs_logNow(@"[hook] 小组件渲染侧 窗口打标=%@ 清底色=%@",
                   ok ? @"OK" : @"SKIP", clr ? @"OK" : @"SKIP");
        SBS_WLOG(@"渲染侧 hook 窗口打标=%@ 清底色=%@",
                 ok ? @"OK" : @"SKIP", clr ? @"OK" : @"SKIP");
    }
    // ⭐⭐ chronod 侧强制暗色 hook（CHUISWidgetScene / CHS*PresentationAttributes.colorScheme → 2）。
    //   这是 RBShape 抹除生效的前提：暗色下背景板才以独立超阈值矩形呈现，可被尺寸分离。
    if (!csTried) {
        Class csScene = objc_getClass("CHUISWidgetScene");
        Class csMut   = objc_getClass("CHSMutableScreenshotPresentationAttributes");
        Class csAttr  = objc_getClass("CHSScreenshotPresentationAttributes");
        if (!csScene && !csMut && !csAttr) {
            if (tries < 60)
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                               ^{ sbs_installWidgetBgHooks(); });
            return;
        }
        csTried = YES;
        int cn = 0;
        if (csScene) cn += SBSHook(csScene, @selector(colorScheme), SBSHelper.class, @selector(sbs_wbgSceneColorScheme)) ? 1 : 0;
        if (csMut)   cn += SBSHook(csMut,   @selector(colorScheme), SBSHelper.class, @selector(sbs_wbgAttrColorScheme)) ? 1 : 0;
        if (csAttr)  cn += SBSHook(csAttr,  @selector(colorScheme), SBSHelper.class, @selector(sbs_wbgAttrColorScheme)) ? 1 : 0;
        sbs_logNow(@"[hook] 小组件强制暗色 scene=%d mut=%d attr=%d 装=%d",
                   csScene != Nil, csMut != Nil, csAttr != Nil, cn);
    }
}

// 安装「小组件背景移除」SpringBoard 侧 hook —— 在 SpringBoard 进程内调用。
// 相关私有类可能晚于 ctor 加载 ⇒ 0.5s 间隔重试（最多 40 次）。
static void sbs_installWidgetSbHooks(void) {
    static BOOL done = NO;
    static int tries = 0;
    if (done) return;   // ⚠️ 观测期也要装（用于 dump widget 宿主视图树）
    Class host  = objc_getClass("CHUISWidgetHostViewController");
    Class avoc  = objc_getClass("CHUISAvocadoHostViewController");
    Class stack = objc_getClass("SBHWidgetStackViewController");
    Class list  = objc_getClass("WGWidgetListItemViewController");
    Class single= objc_getClass("SBHWidgetViewController");
    if (!host && !avoc && !stack && !list && !single) {
        if (tries++ < 40)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ sbs_installWidgetSbHooks(); });
        else
            sbs_logNow(@"[hook] 小组件 SB 侧：候选类全部不存在（等待超时）");
        return;
    }
    NSMutableArray *classes = [NSMutableArray array];
    if (host) [classes addObject:host];
    if (avoc) [classes addObject:avoc];
    int n = 0, tot = 0;
    // ⭐⭐ 白名单条件下的入口拦截（对齐上游 RWB 的 SpringBoard 组）：
    //   ⚠️ 19:14 实测"拦截后 widget 变纯黑块"是**无条件拦截**（连非白名单 widget 一起挡）造成的；
    //      加上白名单条件后只影响白名单 widget —— 这正是上游 RWB 的做法，其 v2.1.1 实机有效。
    for (Class c in classes) {
        if (SBSHook(c, @selector(_updateBackgroundMaterialAndColor), SBSHelper.class,
                    @selector(sbs_wbgHostUpdateBgMaterial))) n++;
        if (SBSHook(c, @selector(_updatePersistedSnapshotContent), SBSHelper.class,
                    @selector(sbs_wbgHostUpdateSnapshot))) n++;
        if (SBSHook(c, @selector(_updatePersistedSnapshotContentIfNecessary), SBSHelper.class,
                    @selector(sbs_wbgHostUpdateSnapshot2))) n++;
        if (SBSHook(c, @selector(colorScheme), SBSHelper.class,
                    @selector(sbs_wbgHostColorScheme))) n++;
        tot += 4;
    }
    // avoc 专属（iOS 15）：screenshotManager → nil；host 专属（iOS 16.0-16.2）：_snapshotImageFromURL: → nil
    if (avoc) { if (SBSHook(avoc, @selector(screenshotManager), SBSHelper.class,
                            @selector(sbs_wbgHostScreenshotManager))) n++; tot++; }
    if (host)  { if (SBSHook(host, @selector(_snapshotImageFromURL:), SBSHelper.class,
                            @selector(sbs_wbgHostSnapshotImageFromURL:))) n++; tot++; }
    // 栈类用【两层 firstObject】取材质；单 widget 宿主用【一层】取 UIVisualEffectView
    if (stack)  { if (SBSHook(stack, @selector(viewWillAppear:), SBSHelper.class,
                              @selector(sbs_wbgStackViewWillAppear:))) n++; tot++; }
    if (list)   { if (SBSHook(list, @selector(viewWillAppear:), SBSHelper.class,
                              @selector(sbs_wbgStackViewWillAppear:))) n++; tot++; }
    if (single) { if (SBSHook(single, @selector(viewWillAppear:), SBSHelper.class,
                              @selector(sbs_wbgSingleViewWillAppear:))) n++; tot++; }
    sbs_logNow(@"[hook] 小组件 SB 侧 类存在性 host=%d avoc=%d stack=%d list=%d single=%d ⇒ 已装 %d/%d",
               host != Nil, avoc != Nil, stack != Nil, list != Nil, single != Nil, n, tot);
    done = (n > 0);
    if (!done && tries++ < 40)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ sbs_installWidgetSbHooks(); });
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
        if (classWaitAttempt++ < 40) {
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
    if (gApertureProbeEnabled) {
        sbs_installApertureRenderProbes();
        BOOL caDisplayOK = SBSHook([CALayer class], @selector(display),
                                   SBSHelper.class, @selector(sbs_layerDisplay));
        BOOL caDrawOK = SBSHook([CALayer class], @selector(drawInContext:),
                                SBSHelper.class, @selector(sbs_layerDrawInContext:));
        BOOL delegateDrawOK = SBSHook([UIView class], @selector(drawLayer:inContext:),
                                      SBSHelper.class, @selector(sbs_viewDrawLayer:inContext:));
        sbs_logNow(@"[hook] CoreAnimation 实时活动渲染 display=%@ draw=%@ delegate=%@",
                   caDisplayOK ? @"OK" : @"失败", caDrawOK ? @"OK" : @"失败",
                   delegateDrawOK ? @"OK" : @"失败");
    }

    // ① 布局终点 hook：每帧可重入 → 承载主缩放 + leading 缩放
    BOOL layoutOK = SBSHook(FG, @selector(layoutSubviews),
                            SBSHelper.class, @selector(sbs_fgLayoutSubviews));
    sbs_logNow(@"[hook] layoutSubviews → %@", layoutOK ? @"已安装" : @"失败");

    // ② 全局 hook UIView.setTransform: 拦截受管图标被系统重置（关键修复）
    BOOL transformOK = SBSHook([UIView class], @selector(setTransform:),
                               SBSHelper.class, @selector(sbs_viewSetTransform:));
    sbs_logNow(@"[hook] UIView.setTransform: → %@", transformOK ? @"已安装" : @"失败");

    BOOL moveOK = SBSHook([UIView class], @selector(didMoveToWindow),
                          SBSHelper.class, @selector(sbs_viewDidMoveToWindow));
    BOOL hiddenOK = SBSHook([UIView class], @selector(setHidden:),
                            SBSHelper.class, @selector(sbs_viewSetHidden:));
    BOOL bgOK = SBSHook([UIView class], @selector(setBackgroundColor:),
                        SBSHelper.class, @selector(sbs_viewSetBackgroundColor:));
    BOOL alphaOK = SBSHook([UIView class], @selector(setAlpha:),
                           SBSHelper.class, @selector(sbs_viewSetAlpha:));
    sbs_logNow(@"[hook] UIView 搜索框/实时活动保护 didMove=%@ hidden=%@ bg=%@ alpha=%@",
               moveOK ? @"OK" : @"失败", hiddenOK ? @"OK" : @"失败",
               bgOK ? @"OK" : @"失败", alphaOK ? @"OK" : @"失败");

    // v2.1.23：普通 border/stroke/shadow 已由日志排除，不再全局 hook 这些高频
    // Core Animation setter。控制中心转场会创建大量 layer，旧祖先链判断会阻塞主线程。
    BOOL layerHiddenOK = SBSHook([CALayer class], @selector(setHidden:),
                                 SBSHelper.class, @selector(sbs_layerSetHidden:));
    BOOL layerOpacityOK = SBSHook([CALayer class], @selector(setOpacity:),
                                  SBSHelper.class, @selector(sbs_layerSetOpacity:));
    sbs_logNow(@"[hook] CALayer key-line 持续保护 hidden=%@ opacity=%@",
               layerHiddenOK ? @"OK" : @"失败", layerOpacityOK ? @"OK" : @"失败");

    // 精确 hook 私有容器；类晚加载时有限重试。
    sbs_installApertureKeylineHook();

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

    // ⚠️ 资源库背景类可能晚于 ctor 加载。立即切到主线程尝试安装，
    //    类未就绪时由 sbs_installLibBgHook 以 0.5s 间隔重试，避免转场时出现背景闪现。
    if (gLibBgClear) {
        dispatch_async(dispatch_get_main_queue(), ^{
            sbs_installLibBgHook();
            sbs_sweepAll();
            // 部分资源库视图会在 SpringBoard 启动后稍晚创建，再补一次即可；
            // 后续由目标类 layout/setter hook 维持，不再永久全树轮询。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ sbs_sweepAll(); });
        });
    }
}

__attribute__((constructor))
static void sbs_ctor(void) {
    NSString *proc = [[NSProcessInfo processInfo] processName];
    NSString *bid  = [[NSBundle mainBundle] bundleIdentifier] ?: @"-";
    // 无条件构造日志（走 os_log，供 syslog 抓取）：用于判定"插件到底有没有被注入本进程"。
    NSLog(@"[SBS] v%@ ctor proc=%@ bid=%@ pid=%d", SBS_VERSION, proc, bid, getpid());
    // ⭐ 注入面诊断（技能 §4.2「载入即落盘」）：把"本进程被注入"的事实写到 /var/tmp，
    //    respring 后 ls 一次即可看清哪些进程真的被注入（不依赖 syslog 抓取窗口）。
    // ⚠️ 仅小组件渲染进程写落痕（plist 用 Classes 过滤时会注入所有 App，避免刷出一堆文件）
    if (sbs_isWidgetRenderProcess()) {
        NSString *body = [NSString stringWithFormat:@"v%@ proc=%@ bid=%@ pid=%d mode=widget渲染\n",
                          SBS_VERSION, proc, bid, getpid()];
        [body writeToFile:[NSString stringWithFormat:@"/private/var/tmp/sbs_inject_%@_%d.txt", proc, getpid()]
                 atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    // ② 小组件渲染进程（chronod / WidgetRenderer）：只装「小组件背景移除」。
    if (sbs_isWidgetRenderProcess()) {
        SBS_WLOG(@"进入小组件背景移除模式 proc=%@ pid=%d", proc, getpid());
        sbs_logNow(@"[载入] v%@ proc=%@ pid=%d 模式=小组件背景移除",
                   SBS_VERSION, proc, getpid());
        // ⚠️⚠️ 实测（2026-10-09）：ctor 里 dispatch_async 到【主队列】的 block **不执行**
        //    （chronod 的 run loop 尚未启动）⇒ 直接同步试一次，再用【全局队列】重试兜底。
        sbs_installWidgetBgHooks();
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            sbs_installWidgetBgHooks();
        });
        return;
    }

    // ① 状态栏缩放 / 资源库背景：防御性白名单 —— 绝不在非 SpringBoard 进程安装全局 swizzle。
    if (![proc isEqualToString:@"SpringBoard"])
        return;
    NSLog(@"[StatusBarScale] v%@ loaded in SpringBoard (scale=%.4f thr=%.0f lead=%.4f)",
          SBS_VERSION, gScale, gThr, gLeadScale);
    sbs_log(@"[载入] v%@ proc=%@ pid=%d enabled=%d scale=%.4f dy=%.4f thr=%.0f lead=%d/%.4f",
            SBS_VERSION, proc, getpid(),
            gEnabled, gScale, gDy, gThr, gLeadEnabled, gLeadScale);
    sbs_install();

    // ③ 小组件背景移除 · SpringBoard 侧（观测期也装：dump widget 宿主视图/图层结构）
    dispatch_async(dispatch_get_main_queue(), ^{ sbs_installWidgetSbHooks(); });
}
