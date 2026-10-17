// KBKeyProbe3 — 键盘键视图 CALayer 圆角专项实验（方案 A）
// 设计原则（吸取 KBKeyProbe2 崩溃教训）：
//   - 只 hook 1 个点：UIKBRenderFactory traitsForKey:onKeyplane:（已验证可靠触发）
//   - 不使用 __builtin_return_address（>0）、不 hook +alloc、不 hook 高频渲染方法
//   - 触发后延迟 0.5s 扫描 UIApplication 全部 window 树，找 UIKBKeyView 族实例 → 设 CALayer 圆角
//   - 扫描带重试（最多 5 次），日志低频（每扫描 1 条）
// 日志：/var/mobile/Documents/kbc_layer.log
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdio.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

extern void MSHookMessageEx(Class cls, SEL sel, IMP newImp, IMP *oldImp);

static void p3_log(NSString *line) {
    NSString *full = [NSString stringWithFormat:@"[kbp3:%d] %@", getpid(), line];
    FILE *fp = fopen("/var/mobile/Documents/kbc_layer.log", "a");
    if (!fp) fp = fopen("/var/tmp/kbc_layer.log", "a");
    if (fp) { fprintf(fp, "%s\n", full.UTF8String); fclose(fp); }
}

static BOOL p3_isKeyViewClass(Class c) {
    if (!c) return NO;
    Class cur = c;
    int guard = 0;
    while (cur && guard++ < 100) {
        if (strcmp(class_getName(cur), "UIKBKeyView") == 0) return YES;
        cur = class_getSuperclass(cur);
    }
    return NO;
}

// 返回扫到的 keyview 数量；attachCorner=YES 时执行修改
static NSInteger g_lastVisited = -1;
static NSInteger p3_scan(BOOL attachCorner) {
    NSInteger kvTotal = 0;
    @try {
        NSArray *wins = [UIApplication sharedApplication].windows;
        NSMutableDictionary *clsCount = [NSMutableDictionary dictionary];
        NSMutableString *winInfo = [NSMutableString string];
        NSMutableString *treeInfo = [NSMutableString string];
        NSInteger visited = 0, changed = 0;
        for (UIWindow *w in wins) {
            NSInteger windowKV = 0;
            NSMutableArray *layerKV = [NSMutableArray array];
            [winInfo appendFormat:@"%@(lvl=%.0f,subs=%lu) ", NSStringFromClass([w class]), w.windowLevel, (unsigned long)w.subviews.count];
            NSMutableArray *stack = [NSMutableArray arrayWithArray:w.subviews];
            while (stack.count > 0 && visited < 8000) {
                UIView *v = [stack lastObject];
                [stack removeLastObject];
                visited++;
                Class vc = object_getClass(v);
                if (p3_isKeyViewClass(vc)) {
                    kvTotal++; windowKV++;
                    NSString *cn = NSStringFromClass(vc);
                    clsCount[cn] = @([clsCount[cn] integerValue] + 1);
                    if ([cn isEqualToString:@"UIKBKeyView"]) {
                        p3_log([NSString stringWithFormat:@"kvhit frame=%@ super=%@ sublayers=%lu",
                                NSStringFromCGRect(v.frame),
                                NSStringFromClass(object_getClass(v.superview)),
                                (unsigned long)v.layer.sublayers.count]);
                    }
                    if (attachCorner) {
                        v.layer.cornerRadius = 17.0;
                        v.layer.masksToBounds = YES;
                        SEL mcs = NSSelectorFromString(@"setMaskedCorners:");
                        if ([v.layer respondsToSelector:mcs]) {
                            ((void(*)(id, SEL, unsigned long long))objc_msgSend)(v.layer, mcs, 0xFull);
                        }
                        changed++;
                    }
                }
                // 前两层打印视图类名（找键盘窗口结构）
                if (visited < 260 && [treeInfo length] < 2000) {
                    [treeInfo appendFormat:@"%@|", NSStringFromClass(vc)];
                }
                // 扫描 layer 子树找 UIKB* / Key* 相关系目
                CALayer *lay = v.layer;
                if (lay) {
                    NSMutableArray *lstack = [NSMutableArray arrayWithArray:lay.sublayers ?: @[]];
                    NSInteger lvisited = 0;
                    while (lstack.count > 0 && lvisited < 400) {
                        CALayer *l = [lstack lastObject];
                        [lstack removeLastObject];
                        lvisited++;
                        NSString *lcn = NSStringFromClass(object_getClass(l));
                        if ([lcn rangeOfString:@"UIKB"].location != NSNotFound ||
                            [lcn rangeOfString:@"Key"].location != NSNotFound) {
                            if (![layerKV containsObject:lcn]) [layerKV addObject:lcn];
                        }
                        if (l.sublayers.count && lvisited < 300) {
                            [lstack addObjectsFromArray:l.sublayers];
                        }
                    }
                }
                if (v.subviews.count && stack.count < 7000) {
                    [stack addObjectsFromArray:v.subviews];
                }
            }
            if (windowKV > 0) {
                [treeInfo appendFormat:@" <KV:%ld>", (long)windowKV];
            }
            if (layerKV.count) {
                [treeInfo appendFormat:@" LAYERS[%@]", [layerKV componentsJoinedByString:@","]];
            }
        }
        p3_log([NSString stringWithFormat:@"scan2 attach=%d visited=%ld kv=%ld changed=%ld classes=%@",
                attachCorner ? 1 : 0, (long)visited, (long)kvTotal, (long)changed, clsCount]);
        if (visited != g_lastVisited) {
            g_lastVisited = visited;
            p3_log([NSString stringWithFormat:@"windows: %@", winInfo]);
            p3_log([NSString stringWithFormat:@"tree2: %@", treeInfo]);
        }
    } @catch (NSException *e) {
        p3_log([NSString stringWithFormat:@"scan exception: %@", e]);
    }
    return kvTotal;
}

static void p3_scan_with_retry(NSInteger attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSInteger n = p3_scan(YES);
        if (n == 0 && attempt < 3) {
            p3_scan_with_retry(attempt + 1);
        }
    });
}

// 持续扫描：触发后每 0.5s 一次 × 40 次（覆盖键盘 attach 的任意时机）
static void p3_scan_tick(NSInteger tick) {
    if (tick >= 40) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        p3_scan(YES);
        p3_scan_tick(tick + 1);
    });
}

static NSTimeInterval g_lastTrigger = 0;
static void p3_maybe_trigger(void) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - g_lastTrigger < 1.5) return;
    g_lastTrigger = now;
    p3_scan_tick(0);
}

// ---- 唯一 hook：traitsForKey:onKeyplane:（触发信号）----
static IMP sO_traits = NULL;
static id p3_traits(id self, SEL _cmd, id key, id keyplane) {
    id r = sO_traits ? ((id(*)(id, SEL, id, id))sO_traits)(self, _cmd, key, keyplane) : nil;
    @try { p3_maybe_trigger(); } @catch (NSException *e) {}
    return r;
}

static void p3_install(void) {
    Class f = objc_getClass("UIKBRenderFactory");
    if (f && !sO_traits) {
        MSHookMessageEx(f, sel_registerName("traitsForKey:onKeyplane:"), (IMP)p3_traits, &sO_traits);
        p3_log(@"hook installed");
    }
}

__attribute__((constructor)) static void p3_ctor(void) {
    p3_log(@"ctor");
    @try { p3_install(); } @catch (NSException *e) {}
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { p3_install(); } @catch (NSException *e) {}
    });
}
