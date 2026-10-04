// ScreenTimeLocker16.m  ——  v5
// ---------------------------------------------------------------------------
// ScreenTimeLocker 的 iOS 16.x / RootHide(arm64e) 重写版
//
// ★ v5.0.0（2026-10-04）：**按原版 DisableOneMoreMinute.dylib 反汇编结果完整还原**
//   许总原则：「不改它的功能，原生的功能就是最优的」。因此本版**不再自作聪明只在
//   UI 层藏按钮**，而是照原版的四层实现逐条复原：
//
//   ┌ 层 ────────────────────────────┬ 目标类/方法 ─────────────────────────────┬ 原版行为 ┐
//   │ ① 数据层（正统做法）            │ STManagementState                        │ 返回 @(NO) │
//   │                                 │  - shouldAllowOneMoreMinuteForBundleIdentifier:error:  │
//   │                                 │  - shouldAllowOneMoreMinuteForCategoryIdentifier:error:│
//   │                                 │  - shouldAllowOneMoreMinuteForWebDomain:error:         │
//   ├─────────────────────────────────┼──────────────────────────────────────────┼───────────┤
//   │ ② 限额设置页（**0 小时 0 分钟**）│ STAllowanceDetailListController           │ return YES│
//   │                                 │  - hasSetBudgetTime                       │          │
//   ├─────────────────────────────────┼──────────────────────────────────────────┼───────────┤
//   │ ③ 拦截页-密码入口               │ STBlockingViewController                  │ 先设备认证│
//   │                                 │  - _enterScreenTimePasscode:              │          │
//   ├─────────────────────────────────┼──────────────────────────────────────────┼───────────┤
//   │ ④ 拦截页-菜单弹窗               │ STBlockingViewController                  │ 见下方开关│
//   │                                 │  - presentViewController:animated:completion:        │
//   └─────────────────────────────────┴──────────────────────────────────────────┴───────────┘
//
//   ① 的证据（原版反汇编 0x33FC / 0x3414 / 0x342C 三处）：
//        ldr x0, <NSNumber class>
//        ldr x1, #sel(numberWithInt:)
//        mov w2, #0x0                 ← 参数 0
//        b   _objc_msgSend            ⇒ [NSNumber numberWithInt:0]
//   ② 的证据（原版 0x3A20）： mov w0,#0x1 ; ret   ⇒ 恒 YES
//        ⇒ 于是设置页认为「时长已设定」，**0 小时 0 分钟时右上角「添加」不再置灰**
//   ③ 的证据（原版 0x372C 区块）： LAContext canEvaluatePolicy:1(LAPolicyDeviceOwnerAuthentication)
//        → evaluatePolicy:1 localizedReason:<askForMoreTimeButton.currentTitle> reply:
//            success → _showPasscodeApprovedOptions ; error.code == -2(用户取消) → 直接返回
//        不能评估（未设设备密码）→ 直接走原实现
//   ④ 原版 0x3444 区块的意图是「**插入**一个『再使用一分钟』action」（insertObject:atIndex:0）。
//       结合 ①「数据层禁掉免费的一分钟」看，③④ 是**配套**的：把「免费的再使用一分钟」
//       改成「**必须先通过一次身份认证**」——这正是 DisableOneMoreMinute 的设计。
//       v5 默认开启（STL_ENABLE_PRESENT_HOOK=1），日志会把弹窗原始内容全打出来以便核对。
//
//   ★ v5 开关一览：STL_ENABLE_DEVICE_AUTH=1（③） / STL_ENABLE_PRESENT_HOOK=1（④）
//     ① ② 无开关，恒开。
//
// 注入目标：com.apple.springboard（拦截页宿主）/ com.apple.Preferences（设置页）
//           / com.apple.ScreenTimeCore
//           / com.apple.ScreenTimeUI / com.apple.ScreenTimeSettingsUI
//
// ★ 血泪修正史 ---------------------------------------------------------------
//  v1  ✗ Category 直接挂私有类 → 链接期硬符号 → ellekit 静默跳过（无日志无崩溃）。
//  v2  ✗ clang 产物未签名 → dyld CODESIGNING / Invalid Page → 打挂 SpringBoard 黑屏。
//  v3  ✗ 纯运行时 hook + 严格签名校验，但自我加了「绝不进 SpringBoard」守卫，
//         而真宿主就是 SpringBoard → **真机 0 命中且不留痕迹**。
//  v4  ✓ 解除守卫 + filter 补 springboard + dyld 回调 + 轮询 → 真机验证通过。
//  v5  ✓ 按原版反汇编**完整还原四层功能**（数据层禁用 / 0-0 可保存 / 密码前设备认证 /
//         菜单观测），并按许总要求**保留「请求更多使用时间」按钮**。
//  v5.1 ✓ 拆掉 v3/v4 遗留的**UI 层 action 过滤**（它会 disable 掉 ③④「认证后批准」
//         的选项与 ④ 刚插入的「再使用一分钟」，与原版设计直接打架）。
//         至此四层完全按原版运行，UI 层不再做任何「修改」。
// ---------------------------------------------------------------------------

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <LocalAuthentication/LocalAuthentication.h>   // ③ 设备认证
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>
#import <string.h>
#import <mach-o/dyld.h>      // _dyld_register_func_for_add_image

#define STL_VERSION @"5.2.0"

// ---- 原版四层功能开关（默认全开 = 完整还原原版 DisableOneMoreMinute 行为）----
//   ① 数据层 STManagementState → @(NO)          ← 永远开（本插件核心）
//   ② 设置页 hasSetBudgetTime → YES             ← 永远开（许总要的「0 小时 0 分钟」）
//   ③ 「请求更多使用时间」入口：设备密码/Face ID 替代屏幕使用时间密码
//   ④ 「批准使用N分钟」弹窗里插入「再使用一分钟」项
#define STL_ENABLE_DEVICE_AUTH   1
#define STL_ENABLE_PRESENT_HOOK  0   // ★ v5.2 许总要求：**不再插入「再使用一分钟」**（1 分钟没意义），
                                     //   原生弹窗的 15 分钟 / 1 小时 / 全天 选项原样保留。仅保留观测日志。
#define STL_TEST_FORCE_FALLBACK  0   // 仅测试用：置 1 强制走「Face ID 失败 → 回落密码」分支；发布版=0
#define STL_LOG     @"/var/mobile/Documents/stl_log.txt"

// ===========================================================================
#pragma mark - 日志（写盘只在「真宿主」里做；其余进程仅 NSLog）
// ===========================================================================

static BOOL gActive = NO;          // 本进程是否真的是拦截页宿主
static BOOL gForceLog = NO;        // 「载入即落盘」：构造期强制写盘（此时 gActive 还是 NO）
static NSString *gLogPath = nil;   // 实际可写的日志路径

static NSLock *gLogLock = nil;

// 沙箱进程写不了 /var/mobile/Documents，逐级回退到可写目录
static NSString *STLResolveLogPath(void) {
    if (gLogPath) return gLogPath;
    NSArray *cands = @[ STL_LOG,
                        [NSTemporaryDirectory() stringByAppendingPathComponent:@"stl_log.txt"],
                        @"/tmp/stl_log.txt" ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in cands) {
        if (!p.length) continue;
        if (![fm fileExistsAtPath:p]) [fm createFileAtPath:p contents:nil attributes:nil];
        if ([fm isWritableFileAtPath:p]) {
            gLogPath = [p copy];
            NSLog(@"[STL] log path -> %@", gLogPath);
            return gLogPath;
        }
    }
    return nil;
}

static void STLWrite(NSString *msg) {
    @autoreleasepool {
        static NSDateFormatter *df = nil;
        if (!df) { df = [[NSDateFormatter alloc] init]; df.dateFormat = @"HH:mm:ss.SSS"; }
        NSString *line = [NSString stringWithFormat:@"%@ [%@/%d] %@\n",
                          [df stringFromDate:[NSDate date]],
                          [[NSProcessInfo processInfo] processName],
                          getpid(), msg];

        NSLog(@"[STL] %@", msg);          // 永远安全的通道

        if (!gActive && !gForceLog) return;   // 非宿主：默认不写盘，避免沙箱违规

        NSString *path = STLResolveLogPath();
        if (!path) return;

        if (!gLogLock) gLogLock = [[NSLock alloc] init];
        [gLogLock lock];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            @try { [fh seekToEndOfFile];
                    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
            @catch (__unused NSException *e) {}
            [fh closeFile];
        }
        [gLogLock unlock];
    }
}

#define STLLog(fmt, ...) do { \
    @autoreleasepool { STLWrite([NSString stringWithFormat:(fmt), ##__VA_ARGS__]); } \
} while (0)

// ===========================================================================
#pragma mark - 「免费绕过」按钮标题
// ===========================================================================

static NSArray<NSString *> *STLForbiddenTitles(void) {
    static NSArray *cache = nil;
    if (cache) return cache;

    NSMutableArray *a = [NSMutableArray array];
    Class cls = objc_getClass("STBlockingViewController");
    NSBundle *b = cls ? [NSBundle bundleForClass:cls]
                      : [NSBundle bundleWithPath:
                            @"/System/Library/PrivateFrameworks/ScreenTimeUI.framework"];
    // 注意：这些 key 必须来自 ScreenTimeUI.framework/Localizable.loctable，
    //       用 localizedStringForKey: 取当前语言下的真实标题。
    // ★ v5.1：**只保留真正的「免费绕过」**。
    //   原版 DisableOneMoreMinute 从不在 UI 层禁用任何东西 —— 免费绕过交给
    //   ①数据层（shouldAllowOneMoreMinuteFor* → @NO）解决。
    //   把「批准使用15分钟 / 批准使用一小时」留在名单里是 v3/v4 的遗留，
    //   它会把 ③「认证后」弹出的选项一并 disable，与 ④ 插入的「再使用一分钟」打架
    //   （2026-10-04 12:19:18 实机日志已证）。故剔除。
    // ★ 仍**故意不包含** `AskForMoreTimeButtonTitle`（请求更多使用时间）——
    //   许总要求保留该按钮（它是通向「输入屏幕使用时间密码」的唯一入口）。
    NSArray *keys = @[ @"OneMoreMinuteButtonTitle",
                       @"IgnoreLimitButtonTitle",
                       @"IgnoreLimitForTodayButtonTitle" ];
    if (b) {
        for (NSString *k in keys) {
            @try {
                NSString *s = [b localizedStringForKey:k value:nil table:nil];
                if (s.length && ![s isEqualToString:k]) [a addObject:s];
            } @catch (__unused NSException *e) {}
        }
    }
    // 兜底硬编码（localizedStringForKey 万一取不到）
    [a addObjectsFromArray:@[ @"再使用一分钟", @"One More Minute",
                              @"忽略限额", @"Ignore Limit",
                              @"今天忽略限额", @"Ignore Limit For Today" ]];

    // ★ 实测发现：ignoreLimit 菜单里还有一项「15分钟后提醒我」，
    //   它同样会关掉拦截页（等于白送 15 分钟）→ 必须一并拉黑。
    Class alertCls = objc_getClass("STBlockingViewController");
    NSBundle *ab = alertCls ? [NSBundle bundleForClass:alertCls] : b;
    for (NSString *k in @[ @"RemindMeIn15MinutesButtonTitle" ]) {
        @try {
            NSString *s = [ab localizedStringForKey:k value:nil table:nil];
            if (s.length && ![s isEqualToString:k]) [a addObject:s];
        } @catch (__unused NSException *e) {}
    }
    [a addObjectsFromArray:@[ @"15分钟后提醒我", @"Remind Me in 15 minutes",
                              @"Remind Me in 15 Minutes" ]];

    // 去重（本地化结果与硬编码兜底会重叠）
    NSMutableArray *uniq = [NSMutableArray array];
    for (NSString *s in a) if (![uniq containsObject:s]) [uniq addObject:s];

    cache = [uniq copy];
    STLLog(@"[cfg] forbidden titles(%lu): %@", (unsigned long)cache.count,
           [cache componentsJoinedByString:@" | "]);
    return cache;
}

static BOOL STLIsForbidden(NSString *title) {
    if (!gActive) return NO;                       // 非宿主一律不干预
    if (!title.length) return NO;
    NSString *t = [title stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return NO;
    return [STLForbiddenTitles() containsObject:t];
}

// ===========================================================================
#pragma mark - 运行时 hook 工具
// ===========================================================================

static BOOL STLHook(Class target, SEL origSel, Class src, SEL implSel) {
    if (!target) return NO;
    Method mo = class_getInstanceMethod(target, origSel);
    Method mi = class_getInstanceMethod(src, implSel);
    if (!mo) { STLLog(@"[hook] SKIP  %@ (目标类无此方法)",
                      NSStringFromSelector(origSel)); return NO; }
    if (!mi) { STLLog(@"[hook] SKIP  %@ (实现缺失)",
                      NSStringFromSelector(origSel)); return NO; }

    const char *eo = method_getTypeEncoding(mo);
    const char *ei = method_getTypeEncoding(mi);
    if (!eo || !ei || strcmp(eo, ei) != 0) {
        STLLog(@"[hook] SKIP  %@ (typeEncoding %s != %s)",
               NSStringFromSelector(origSel), eo ?: "?", ei ?: "?");
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

    STLLog(@"[hook] OK    %@  %s", NSStringFromSelector(origSel), eo);
    return TRUE;
}

// ===========================================================================
#pragma mark - 视图遍历
// ===========================================================================

static NSString *STLViewTitle(UIView *v) {
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        if ([b respondsToSelector:@selector(configuration)]) {
            UIButtonConfiguration *c = b.configuration;
            if (c) {
                if (c.title.length) return c.title;
                if (c.attributedTitle.length) return c.attributedTitle.string;
            }
        }
        if (b.currentTitle.length) return b.currentTitle;
        if (b.currentAttributedTitle.length) return b.currentAttributedTitle.string;
        if (b.titleLabel.text.length) return b.titleLabel.text;
    }
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (l.text.length) return l.text;
    }
    return nil;
}

static void STLStripView(UIView *v, int depth) {
    if (!v || depth > 24) return;
    NSString *t = STLViewTitle(v);
    if (t && STLIsForbidden(t)) {
        STLLog(@"[strip] <%@> title=“%@” -> 禁用并隐藏",
               NSStringFromClass([v class]), t);
        v.hidden = YES;
        v.alpha = 0.0;
        v.userInteractionEnabled = NO;
        if ([v isKindOfClass:[UIControl class]]) ((UIControl *)v).enabled = NO;
        return;
    }
    for (UIView *s in v.subviews) STLStripView(s, depth + 1);
}

static void STLStripAlert(UIViewController *host) {
    UIViewController *p = host.presentedViewController;
    // ★ v5.1：**不再禁用 alert 里的 action**。
    //   原版从不禁用 action —— 它靠 ①数据层 + ③④「认证后批准」。
    //   v3/v4 的 action 过滤会把 ④ 刚插入的「再使用一分钟」以及「批准使用15分钟/
    //   批准使用一小时」一起 disable（实机 12:19:18 日志已证），与 ③④ 直接打架。
    if ([p isKindOfClass:[UIViewController class]]) {
        STLStripView(p.view, 0);
    }
}

// ---------------------------------------------------------------------------
// UIMenu 层面：iOS 16 的「再使用一分钟 / 忽略限额」是 UIMenu 菜单项
// ---------------------------------------------------------------------------

static NSString *STLMenuElementTitle(UIMenuElement *e) {
    if ([e respondsToSelector:@selector(title)]) return [(id)e title];
    return nil;
}

static void STLDisableAnyAction(id action, const char *where) {
    if (!gActive || !action) return;
    NSString *t = STLMenuElementTitle(action);
    STLLog(@"[%s] 见到 %@ title=“%@”", where, NSStringFromClass([action class]), t ?: @"(无)");
    if (!STLIsForbidden(t)) return;
    @try {
        if ([action respondsToSelector:@selector(setEnabled:)])
            [action setEnabled:NO];
    } @catch (__unused NSException *e) {}
}

/// 递归剔除菜单里标题命中黑名单的项
static UIMenu *STLFilterMenu(UIMenu *menu) {
    if (!gActive || ![menu isKindOfClass:[UIMenu class]]) return menu;
    NSMutableArray *keep = [NSMutableArray array];
    for (UIMenuElement *e in menu.children) {
        NSString *t = STLMenuElementTitle(e);
        if (STLIsForbidden(t)) {
            STLLog(@"[menu] 剔除菜单项 “%@” (%@)", t, NSStringFromClass([e class]));
            continue;
        }
        if ([e isKindOfClass:[UIMenu class]]) {
            UIMenu *sub = STLFilterMenu((UIMenu *)e);
            [keep addObject:sub ?: (id)e];
        } else {
            [keep addObject:e];
        }
    }
    @try { return [menu menuByReplacingChildren:keep]; }
    @catch (__unused NSException *e) { return menu; }
}

// ===========================================================================
#pragma mark - hook 实现载体（自己的类，编译期可见选择子）
// ===========================================================================

@interface STLHookImpl : NSObject
- (void)stl_viewDidLoad;
- (void)stl_viewWillAppear:(BOOL)animated;
- (void)stl_showAskForMoreTimeOptions:(id)sender;
- (void)stl_showIgnoreLimitOptions:(id)sender;
- (void)stl_ok:(id)sender;
- (void)stl_enterScreenTimePasscode:(id)sender;
// ---- iOS 16 专有 ----
- (void)stl_updateButtons;
- (id (^)(void))stl_askForMoreTimeMenuProvider;   // 真身是返回 UIMenu 的 block
- (id (^)(void))stl_ignoreLimitMenuProvider;
- (id)stl_oneMoreMinuteAction;
- (id)stl_ignoreForTodayAction;
- (id)stl_remindMeIn15MinutesAction;
- (id)stl_enterScreenTimePasscodeAction;
- (id)stl_sendRequestAction;
- (void)stl_showPasscodeApprovedOptions;
- (void)stl_oneMoreMinute:(id)sender;
- (void)stl_ignoreLimitForAdditionalTime:(double)arg;
- (void)stl_hideCustomButtons;

// ---------- v5：按原版反汇编完整还原的四层 ----------
// ① 数据层（正统做法：从系统层面判「不允许再使用一分钟」）
- (id)stl_shouldAllowOneMoreMinuteForBundleIdentifier:(id)bundleID error:(NSError **)error;
- (id)stl_shouldAllowOneMoreMinuteForCategoryIdentifier:(id)categoryID error:(NSError **)error;
- (id)stl_shouldAllowOneMoreMinuteForWebDomain:(id)domain error:(NSError **)error;
// ② 限额设置页：让「0 小时 0 分钟」也能保存
- (BOOL)stl_hasSetBudgetTime;
// ④ 拦截页要 present 的弹窗（v5.2：只观测、不插入任何 action）
- (void)stl_presentViewController:(UIViewController *)vc
                         animated:(BOOL)animated
                       completion:(void (^)(void))completion;
@end

// 只声明选择子（不声明类），不会产生链接期符号，安全。
@interface NSObject (STLPrivate)
- (id)_actions;                     // UIAlertController 私有
- (void)_oneMoreMinute:(id)sender;  // STBlockingViewController 私有
@end

@implementation STLHookImpl

- (void)stl_viewDidLoad {
    [self stl_viewDidLoad];
    STLLog(@"[hook] STBlockingViewController -viewDidLoad");
    STLStripView(((UIViewController *)self).view, 0);
}

- (void)stl_viewWillAppear:(BOOL)animated {
    [self stl_viewWillAppear:animated];
    STLLog(@"[hook] STBlockingViewController -viewWillAppear:");
    STLStripView(((UIViewController *)self).view, 0);
}

- (void)stl_showAskForMoreTimeOptions:(id)sender {
    STLLog(@"[hook] -_showAskForMoreTimeOptions: 命中");
    [self stl_showAskForMoreTimeOptions:sender];
    __weak UIViewController *host = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *h = host; if (h) STLStripAlert(h);
    });
}

- (void)stl_showIgnoreLimitOptions:(id)sender {
    STLLog(@"[hook] -_showIgnoreLimitOptions: 命中");
    [self stl_showIgnoreLimitOptions:sender];
    __weak UIViewController *host = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *h = host; if (h) STLStripAlert(h);
    });
}

- (void)stl_ok:(id)sender {
    STLLog(@"[hook] -_ok: 命中（保留）");
    [self stl_ok:sender];
}

// ---- ③ 拦截页-密码入口（原版 0x372C 区块）----------------------------------
// 原版逻辑：把「请求更多使用时间」的密码校验，从**屏幕使用时间密码**换成
//   **Face ID**（LAContext，policy=1=DeviceOwnerAuthenticationWithBiometrics）。
//   认证通过 → 直接 `_showPasscodeApprovedOptions`（＝「批准使用15分钟 / 1小时」选项）。
//
// ★ v5.2（许总要求：「走 Face ID 和屏幕使用时间密码」→ Face ID 优先，走不通转密码）：
//   - Face ID **可用** → 弹面容：
//       · 通过      → `_showPasscodeApprovedOptions`
//       · 取消/失败 → **回落**到「输入屏幕使用时间密码」输入框（不再原地干等）
//   - Face ID **不可用**（未录面容 / 被停用）→ 同样回落屏幕使用时间密码
//   两条路都保留：能用面容就用面容，用不了就输屏幕使用时间密码。
//   ⚠️ 回落必须调 `stl_enterScreenTimePasscode:` —— swizzle 后该名字挂的才是**原实现**；
//      绝不能回头调 `_enterScreenTimePasscode:`（那已被换成我们自己的钩子 → 会无限递归弹面容）。
- (void)stl_enterScreenTimePasscode:(id)sender {
    STLLog(@"[hook] -_enterScreenTimePasscode: 命中");

#if STL_ENABLE_DEVICE_AUTH
    @try {
        id btn = nil;
        @try { btn = [self valueForKey:@"askForMoreTimeButton"]; } @catch (__unused NSException *e) {}
        NSString *reason = nil;
        if ([btn respondsToSelector:@selector(currentTitle)]) reason = [btn currentTitle];
        if (!reason.length) reason = @"请求更多使用时间";

        LAContext *ctx = [[LAContext alloc] init];
        NSError  *canErr = nil;
        // 原版反汇编里 policy 立即数是 0x1（LAPolicyDeviceOwnerAuthenticationWithBiometrics）。
        LAPolicy policy = (LAPolicy)1;
        if ([ctx canEvaluatePolicy:policy error:&canErr]) {
            STLLog(@"[③] Face ID 可用 → 开始面容认证 reason=“%@”", reason);
            __weak id wself = self;
            [ctx evaluatePolicy:policy
                localizedReason:reason
                          reply:^(__unused BOOL success, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    id s = wself;
                    if (!s) return;
                    BOOL ok = success;
#if STL_TEST_FORCE_FALLBACK
                    ok = NO;   // ⚠️ 测试：强制模拟「Face ID 失败」，验证回落分支
                    STLLog(@"[③][测试] 强制模拟 Face ID 失败 → 走回落");
#endif
                    if (ok) {
                        STLLog(@"[③] Face ID 通过 → _showPasscodeApprovedOptions");
                        SEL sel = NSSelectorFromString(@"_showPasscodeApprovedOptions");
                        if ([s respondsToSelector:sel]) {
                            IMP imp = [s methodForSelector:sel];
                            ((void (*)(id, SEL))imp)(s, sel);
                        } else {
                            STLLog(@"[③] 目标不响应 _showPasscodeApprovedOptions");
                        }
                    } else {
                        // ★ v5.2：Face ID 取消(-2) / 失败 → 回落「输入屏幕使用时间密码」
                        STLLog(@"[③] Face ID 未通过 code=%ld（-2=用户取消）→ 回落屏幕使用时间密码",
                               (long)error.code);
                        SEL sel = @selector(stl_enterScreenTimePasscode:);   // ← 此名即原实现
                        if ([s respondsToSelector:sel]) {
                            IMP imp = [s methodForSelector:sel];
                            ((void (*)(id, SEL, id))imp)(s, sel, nil);
                        } else {
                            STLLog(@"[③] 回落失败：对象不响应 stl_enterScreenTimePasscode:");
                        }
                    }
                });
            }];
            return;                       // 已接管，不再走原生
        }
        STLLog(@"[③] Face ID 不可用（code=%ld %@）→ 回落屏幕使用时间密码",
               (long)canErr.code, canErr.localizedDescription ?: @"");
    } @catch (NSException *e) {
        STLLog(@"[③] 异常 %@ → 回落屏幕使用时间密码", e);
    }
#endif

    [self stl_enterScreenTimePasscode:sender];
}

// ==================== iOS 16 专有实现 ====================

- (void)stl_updateButtons {
    [self stl_updateButtons];
    STLLog(@"[hook] -_updateButtons 命中");

    // ★ v5（许总要求）：**不再隐藏任何按钮**，保留「请求更多使用时间」。
    //   原版 DisableOneMoreMinute 也从不碰这两个按钮 —— 它走的是**数据层**
    //   `STManagementState -shouldAllowOneMoreMinuteFor*:error:` 一律返回 @(NO)，
    //   让 iOS 自己把免费的「再使用一分钟」从菜单里去掉。在 UI 层硬藏按钮
    //   是我 v3/v4 自作聪明的做法，已废弃。
    //   这里只做**状态观测**，方便日志核对按钮到底在不在、标题是什么。
    for (NSString *key in @[ @"okButton", @"askForMoreTimeButton",
                             @"ignoreLimitButton", @"enterScreenTimePasscodeButton" ]) {
        @try {
            id btn = [self valueForKey:key];
            NSString *title = nil;
            if ([btn respondsToSelector:@selector(currentTitle)])
                title = [btn currentTitle];
            else if ([btn respondsToSelector:@selector(titleForState:)])
                title = [btn titleForState:UIControlStateNormal];
            STLLog(@"[btn] %-30s = %@ 标题=“%@” hidden=%@",
                   [key UTF8String],
                   btn ? NSStringFromClass([btn class]) : @"nil",
                   title ?: @"-",
                   btn ? ([(UIView *)btn isHidden] ? @"是" : @"否") : @"-");
        } @catch (NSException *e) {
            STLLog(@"[btn] 读取 %@ 异常: %@", key, e);
        }
    }

    // 视图树兜底：只对**标题命中黑名单的其他控件**生效。
    //（「请求更多使用时间」已从黑名单里移除，不会被误藏）
    STLStripView(((UIViewController *)self).view, 0);
}

- (id (^)(void))stl_askForMoreTimeMenuProvider {
    id (^orig)(void) = [self stl_askForMoreTimeMenuProvider];
    if (!orig) { STLLog(@"[hook] -_askForMoreTimeMenuProvider 为 nil"); return nil; }
    id (^wrapped)(void) = ^{
        id menu = orig();
        STLLog(@"[hook] askForMoreTime 菜单 -> %@", NSStringFromClass([menu class]));
        if ([menu isKindOfClass:[UIMenu class]]) {
            for (UIMenuElement *e in [(UIMenu *)menu children])
                STLDisableAnyAction((id)e, "menu");
            return (id)STLFilterMenu((UIMenu *)menu);
        }
        return menu;
    };
    return [wrapped copy];
}

- (id (^)(void))stl_ignoreLimitMenuProvider {
    id (^orig)(void) = [self stl_ignoreLimitMenuProvider];
    if (!orig) { STLLog(@"[hook] -_ignoreLimitMenuProvider 为 nil"); return nil; }
    id (^wrapped)(void) = ^{
        id menu = orig();
        STLLog(@"[hook] ignoreLimit 菜单 -> %@", NSStringFromClass([menu class]));
        if ([menu isKindOfClass:[UIMenu class]]) {
            for (UIMenuElement *e in [(UIMenu *)menu children])
                STLDisableAnyAction((id)e, "menu");
            return (id)STLFilterMenu((UIMenu *)menu);
        }
        return menu;
    };
    return [wrapped copy];
}

- (id)stl_oneMoreMinuteAction {
    id a = [self stl_oneMoreMinuteAction];
    STLDisableAnyAction(a, "action"); return a;
}
- (id)stl_ignoreForTodayAction {
    id a = [self stl_ignoreForTodayAction];
    STLDisableAnyAction(a, "action"); return a;
}
- (id)stl_remindMeIn15MinutesAction {
    id a = [self stl_remindMeIn15MinutesAction];
    STLDisableAnyAction(a, "action"); return a;
}
- (id)stl_enterScreenTimePasscodeAction {
    id a = [self stl_enterScreenTimePasscodeAction];
    STLDisableAnyAction(a, "action"); return a;      // 「输入密码」必须保留
}
- (id)stl_sendRequestAction {
    id a = [self stl_sendRequestAction];
    STLDisableAnyAction(a, "action"); return a;
}

- (void)stl_showPasscodeApprovedOptions {
    STLLog(@"[hook] -_showPasscodeApprovedOptions 命中（密码已通过后的选项）");
    [self stl_showPasscodeApprovedOptions];
    __weak UIViewController *host = (UIViewController *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *h = host; if (h) STLStripAlert(h);
    });
}

- (void)stl_oneMoreMinute:(id)sender {
    STLLog(@"[hook] -_oneMoreMinute: 命中 —— 将要「再使用一分钟」");
    [self stl_oneMoreMinute:sender];
}

- (void)stl_ignoreLimitForAdditionalTime:(double)arg {
    STLLog(@"[hook] -_ignoreLimitForAdditionalTime:%.1f 命中", arg);
    [self stl_ignoreLimitForAdditionalTime:arg];
}

- (void)stl_hideCustomButtons {
    STLLog(@"[hook] -_hideCustomButtons 命中");
    [self stl_hideCustomButtons];
}

// ===========================================================================
#pragma mark - v5：按原版反汇编还原的四层
// ===========================================================================

// ---- ① 数据层 STManagementState -------------------------------------------
// 原版证据（0x33FC / 0x3414 / 0x342C 三处，结构一模一样）：
//     ldr x0, <NSNumber classref>
//     ldr x1, #sel(numberWithInt:)
//     mov w2, #0x0                  ← 参数 0
//     b   _objc_msgSend             ⇒ [NSNumber numberWithInt:0]
// 即三个方法**一律返回 @(0)**：从系统管理层面就判定「不允许再使用一分钟」。
// 这是「直接调用 iOS 原生实现」的正统做法，比在 UI 层藏按钮干净得多。

- (id)stl_shouldAllowOneMoreMinuteForBundleIdentifier:(id)bundleID error:(NSError **)error {
    id orig = nil;
    @try { orig = [self stl_shouldAllowOneMoreMinuteForBundleIdentifier:bundleID error:error]; }
    @catch (__unused NSException *e) {}
    STLLog(@"[SMS] bundle=“%@” 原返回值=%@ → 强制 @NO", bundleID ?: @"(nil)", orig ?: @"(nil)");
    return @(NO);
}

- (id)stl_shouldAllowOneMoreMinuteForCategoryIdentifier:(id)categoryID error:(NSError **)error {
    id orig = nil;
    @try { orig = [self stl_shouldAllowOneMoreMinuteForCategoryIdentifier:categoryID error:error]; }
    @catch (__unused NSException *e) {}
    STLLog(@"[SMS] category=“%@” 原返回值=%@ → 强制 @NO", categoryID ?: @"(nil)", orig ?: @"(nil)");
    return @(NO);
}

- (id)stl_shouldAllowOneMoreMinuteForWebDomain:(id)domain error:(NSError **)error {
    id orig = nil;
    @try { orig = [self stl_shouldAllowOneMoreMinuteForWebDomain:domain error:error]; }
    @catch (__unused NSException *e) {}
    STLLog(@"[SMS] webDomain=“%@” 原返回值=%@ → 强制 @NO", domain ?: @"(nil)", orig ?: @"(nil)");
    return @(NO);
}

// ---- ② 设置页 STAllowanceDetailListController.hasSetBudgetTime --------------
// 原版证据（0x3A20）： mov w0, #0x1 ; ret   ⇒ 恒返回 YES
// 效果：设置页据此认为「时长已设定」→
//   **右上角「添加」在 0 小时 0 分钟时不再置灰，可直接保存 0/0 限额**。
// （许总指出 ScreenTimeLocker 原生支持 0/0 —— 反汇编确认就是这个 hook。）

- (BOOL)stl_hasSetBudgetTime {
    BOOL orig = NO;
    @try { orig = [self stl_hasSetBudgetTime]; } @catch (__unused NSException *e) {}
    STLLog(@"[Budget] hasSetBudgetTime 原值=%@ → 强制 YES（解锁 0 小时 0 分钟）",
           orig ? @"YES" : @"NO");
    return YES;
}

// ---- ④ 拦截页弹窗 presentViewController:animated:completion: ----------------
// 原版证据（0x3444 区块）：
//     if ([vc isKindOfClass:UIAlertController]) {
//       NSArray *acts = [vc _actions];
//       if (acts.count) {
//         NSString *t0  = acts[0].title;
//         NSString *t15 = [STScreenTimeUIBundle localizedStringForKey:@"ApproveFor15MinutesButtonTitle"]; // 批准使用15分钟
//         if ([t0 isEqualToString:t15]) {
//           NSString *t1m = [bundle localizedStringForKey:@"OneMoreMinuteButtonTitle"];                    // 再使用一分钟
//           UIAlertAction *a = [UIAlertAction actionWithTitle:t1m style:0
//                               handler:^(UIAlertAction *x){ [self _oneMoreMinute:x]; }];
//           [acts insertObject:a atIndex:0];            // ← 注意是「插入」
//         }
//       }
//     }
// ⚠️ 这一段方向存疑（看起来是**放开**一个免费 1 分钟入口，而非收紧），
//    因此默认 **只观测、不篡改**；日志会把 alert 的全部 action 标题打出来，
//    这样一次就能看清 iOS 16.5.1 菜单的真实构成。
//    是否照抄原版由 STL_ENABLE_PRESENT_HOOK 开关控制。
// ★ v5.2（许总要求）：开关已置 **0** —— **不再插入「再使用一分钟」**（1 分钟没意义），
//    原生的「15 分钟 / 1 小时 / 全天」选项**原样保留**。本钩子现在只出观测日志
//    （打印 alert 的全部 action 标题），对 UI 零改动。

- (void)stl_presentViewController:(UIViewController *)vc
                         animated:(BOOL)animated
                       completion:(void (^)(void))completion {
    @try {
        if ([vc isKindOfClass:[UIAlertController class]]) {
            NSArray *acts = [(UIAlertController *)vc _actions];
            NSMutableString *dump = [NSMutableString string];
            for (NSUInteger i = 0; i < acts.count; i++) {
                id a = acts[i];
                NSString *t = [a respondsToSelector:@selector(title)] ? [a title] : nil;
                [dump appendFormat:@"\n    [%lu] <%@> “%@”", (unsigned long)i,
                                   NSStringFromClass([a class]), t ?: @"(无)"];
            }
            STLLog(@"[present] UIAlertController 共 %lu 个 action:%@",
                   (unsigned long)acts.count, dump);
#if STL_ENABLE_PRESENT_HOOK
            if (acts.count) {
                NSString *t0 = [acts[0] respondsToSelector:@selector(title)] ? [acts[0] title] : nil;
                NSBundle *b = [NSBundle bundleWithPath:
                               @"/System/Library/PrivateFrameworks/ScreenTimeUI.framework"];
                NSString *t15 = [b localizedStringForKey:@"ApproveFor15MinutesButtonTitle"
                                                   value:nil table:nil];
                if (t0 && t15 && [t0 isEqualToString:t15]) {
                    NSString *t1m = [b localizedStringForKey:@"OneMoreMinuteButtonTitle"
                                                       value:nil table:nil];
                    id host = self;
                    UIAlertAction *a = [UIAlertAction actionWithTitle:t1m
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(UIAlertAction *x) {
                        if ([host respondsToSelector:@selector(_oneMoreMinute:)])
                            [host _oneMoreMinute:x];
                    }];
                    if ([acts isKindOfClass:[NSMutableArray class]])
                        [(NSMutableArray *)acts insertObject:a atIndex:0];
                    STLLog(@"[present] 已按原版插入「%@」到 index 0", t1m);
                }
            }
#endif
        }
    } @catch (NSException *e) {
        STLLog(@"[present] 异常: %@", e);
    }
    [self stl_presentViewController:vc animated:animated completion:completion];
}

@end


// ===========================================================================
#pragma mark - 安装（只有真宿主才装）
// ===========================================================================

// ★ v5：三层**各自独立安装**。原因：
//   ① 数据层 STManagementState 在「调用拦截页的进程」（iOS 16.5.1 = SpringBoard）
//   ② 设置页 STAllowanceDetailListController 在「com.apple.Preferences」
//   ③④ 拦截页 STBlockingViewController 在 SpringBoard
//   三者**不在同一个进程**，若仍旧「见到 STBlockingViewController 才装」，
//   则 Preferences / ScreenTimeCore 里的 hook 永远不会被安装 → 0 小时 0 分钟照样点不动。
static BOOL gTriedBVC  = NO;   // ③④ 拦截页（SpringBoard）
static BOOL gTriedSMS  = NO;   // ① 数据层（SpringBoard / ScreenTimeCore）
static BOOL gTriedADLC = NO;   // ② 设置页（Preferences）

static void STLTryInstall(void) {
    NSString *proc = [[NSProcessInfo processInfo] processName];

    // ================= ② 设置页：解锁「0 小时 0 分钟」=================
    // 宿主 = com.apple.Preferences。原版证据（0x3A20）： mov w0,#0x1 ; ret  ⇒ 恒 YES
    // 效果：设置页据此认为「时长已设定」→ 0 小时 0 分钟时右上角「添加」不再置灰。
    if (!gTriedADLC) {
        Class adlc = objc_getClass("STAllowanceDetailListController");
        if (adlc) {
            gTriedADLC = YES;
            gActive = YES;                 // 从这一刻起本进程才写盘/干预 UI
            STLLog(@"==============================================================");
            STLLog(@"ScreenTimeLocker16 %@ [②设置页] 真宿主 proc=%@ pid=%d",
                   STL_VERSION, proc, getpid());
            STLHook(adlc, @selector(hasSetBudgetTime),
                    [STLHookImpl class], @selector(stl_hasSetBudgetTime));
            STLLog(@"[②设置页] 安装完成（0/0 可保存）");
        }
    }

    // ================= ① 数据层：禁止「再使用一分钟」=================
    // 原版证据（0x33FC / 0x3414 / 0x342C 三处结构一致）：⇒ [NSNumber numberWithInt:0]
    // 这是「直接调用 iOS 原生实现」的正统做法：让系统自己判「不允许再使用一分钟」。
    if (!gTriedSMS) {
        Class sms = objc_getClass("STManagementState");
        if (sms) {
            gTriedSMS = YES;
            gActive = YES;
            STLLog(@"==============================================================");
            STLLog(@"ScreenTimeLocker16 %@ [①数据层] 真宿主 proc=%@ pid=%d",
                   STL_VERSION, proc, getpid());
            Class implC = [STLHookImpl class];
            STLHook(sms, @selector(shouldAllowOneMoreMinuteForBundleIdentifier:error:),
                    implC, @selector(stl_shouldAllowOneMoreMinuteForBundleIdentifier:error:));
            STLHook(sms, @selector(shouldAllowOneMoreMinuteForCategoryIdentifier:error:),
                    implC, @selector(stl_shouldAllowOneMoreMinuteForCategoryIdentifier:error:));
            STLHook(sms, @selector(shouldAllowOneMoreMinuteForWebDomain:error:),
                    implC, @selector(stl_shouldAllowOneMoreMinuteForWebDomain:error:));
            STLLog(@"[①数据层] 安装完成");
        }
    }

    // ================= ③④ 拦截页 =================
    if (gTriedBVC) return;                 // 本进程该装的都装过了
    Class bvc = objc_getClass("STBlockingViewController");
    if (!bvc) return;                      // 框架还没进来，等下次重试
    gTriedBVC = YES;
    gActive = YES;                         // 从这一刻起才是真宿主

    STLLog(@"==============================================================");
    STLLog(@"ScreenTimeLocker16 %@ [③④拦截页] 真宿主 proc=%@ pid=%d",
           STL_VERSION, proc, getpid());

    Class implC = [STLHookImpl class];
    STLHook(bvc, @selector(viewDidLoad),                 implC, @selector(stl_viewDidLoad));
    STLHook(bvc, @selector(viewWillAppear:),             implC, @selector(stl_viewWillAppear:));
    STLHook(bvc, @selector(_showAskForMoreTimeOptions:), implC, @selector(stl_showAskForMoreTimeOptions:));
    STLHook(bvc, @selector(_showIgnoreLimitOptions:),    implC, @selector(stl_showIgnoreLimitOptions:));
    STLHook(bvc, @selector(_ok:),                        implC, @selector(stl_ok:));
    STLHook(bvc, @selector(_enterScreenTimePasscode:),   implC, @selector(stl_enterScreenTimePasscode:));

    // ---- iOS 16 拦截页真正的绕过点 ----
    STLHook(bvc, @selector(_updateButtons),              implC, @selector(stl_updateButtons));
    STLHook(bvc, @selector(_askForMoreTimeMenuProvider), implC, @selector(stl_askForMoreTimeMenuProvider));
    STLHook(bvc, @selector(_ignoreLimitMenuProvider),    implC, @selector(stl_ignoreLimitMenuProvider));
    STLHook(bvc, @selector(_oneMoreMinuteAction),        implC, @selector(stl_oneMoreMinuteAction));
    STLHook(bvc, @selector(_ignoreForTodayAction),       implC, @selector(stl_ignoreForTodayAction));
    STLHook(bvc, @selector(_remindMeIn15MinutesAction),  implC, @selector(stl_remindMeIn15MinutesAction));
    STLHook(bvc, @selector(_enterScreenTimePasscodeAction), implC, @selector(stl_enterScreenTimePasscodeAction));
    STLHook(bvc, @selector(_sendRequestAction),          implC, @selector(stl_sendRequestAction));
    STLHook(bvc, @selector(_showPasscodeApprovedOptions), implC, @selector(stl_showPasscodeApprovedOptions));
    STLHook(bvc, @selector(_oneMoreMinute:),             implC, @selector(stl_oneMoreMinute:));
    STLHook(bvc, @selector(_ignoreLimitForAdditionalTime:), implC, @selector(stl_ignoreLimitForAdditionalTime:));
    STLHook(bvc, @selector(_hideCustomButtons),          implC, @selector(stl_hideCustomButtons));

    // ---- ④ 拦截页弹窗（原版 0x3444 区块）----
    //   观测 UIAlertController 的全部 action。v5.2 开关=0 → **不插入任何 action**。
    STLHook(bvc, @selector(presentViewController:animated:completion:),
            implC, @selector(stl_presentViewController:animated:completion:));

    // ★ v5.1：**移除 UIAlertController / UIAlertAction 的过滤 hook**。
    //   原版 DisableOneMoreMinute 从不在 UI 层禁用 action；保留它会把 ③④
    //   「认证后批准」的选项一起禁用（与 ④ 插入的『再使用一分钟』直接冲突）。
    //   免费绕过交给 ①数据层 + 菜单过滤（ignoreLimit / askForMoreTime）处理。

    STLForbiddenTitles();
    STLLog(@"初始化完成");
}

// ===========================================================================
#pragma mark - 入口
// ===========================================================================

// dyld 镜像加载回调：ScreenTimeUI / ScreenTimeSettingsUI 被 dlopen 时**立刻**尝试安装。
// ⚠️ 本回调运行在 dyld 锁内：只允许做「判断 + 异步派发」，绝不在这里调 ObjC/UIKit，
//    也不用 dladdr/_dyld_get_image_name（会二次取 dyld 锁 → 死锁）。
//    mario 原插件就是因为直接在回调里 objc_msgSend → SIGBUS。
static void STLOnImageAdded(const struct mach_header *mh, intptr_t slide) {
    dispatch_async(dispatch_get_main_queue(), ^{ STLTryInstall(); });
}

__attribute__((constructor))
static void STLInit(void) {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName];

        // ★ 2026-10-04 重大修正：解除「绝不进 SpringBoard」的旧铁律。
        //   真机实测（AX 探针）证明：iOS 16.5.1 的「App 限额」拦截页
        //   **由 SpringBoard 以远程视图形式呈现**——
        //     元素 id = pid:6521|ctx:2012533904|...，其中 ctx 属微信场景，
        //     但解析出的 host pid = SpringBoard(5829)，且 visible_point=(-1,-1)。
        //   之前那条守卫把真正的宿主挡在门外，于是真机上 0 命中（日志全空）。
        //   现在只避开黑屏风险最高、且与拦截页无关的底层进程。
        if ([proc isEqualToString:@"backboardd"] ||
            [proc isEqualToString:@"runningboardd"]) {
            return;
        }

        NSLog(@"[STL] %@ loaded into %@ pid=%d", STL_VERSION, proc, getpid());
        // ★ 关键诊断：载入即落盘（不只走 NSLog）。
        //   这样只要某个进程被注入，日志里就有它的名字 —— 用于回答
        //   "到底哪个进程是拦截页宿主"。沙箱进程会自动回退到自己的 tmp。
        //   ⚠️ 必须临时置 gForceLog（此刻 gActive 还是 NO，否则这行会被 STLWrite 挡掉）。
        gForceLog = YES;
        STLLog(@"[载入] v%@ proc=%@ pid=%d 可写日志=%@",
               STL_VERSION, proc, getpid(), STLResolveLogPath() ?: @"(不可写)");

        // ① 本进程启动时类已在（SpringBoard 若启动即链接 ScreenTimeUI）→ 立即装
        STLTryInstall();

        // ② 框架稍后才被 dlopen → dyld 回调最快（毫秒级）
        _dyld_register_func_for_add_image(STLOnImageAdded);

        // ③ 兜底轮询：每 3 秒一次，**不设上限**（用户可能几小时后才首次触发限额）。
        //    objc_getClass 对不存在的类开销极低。装上任意一层后放慢到 15 秒。
        //    ⚠️ 不能「装完一层就停」——SpringBoard 里 ① 数据层随进程启动就有，
        //       而 ③④ 拦截页要等用户真的触发限额、ScreenTimeUI 被 dlopen 才出现。
        __block void (^tick)(void);
        tick = ^{
            if (gTriedBVC && gTriedSMS && gTriedADLC) return;
            STLTryInstall();
            NSTimeInterval iv = (gTriedBVC || gTriedSMS || gTriedADLC) ? 15.0 : 3.0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(iv * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), tick);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), tick);
    }
}
