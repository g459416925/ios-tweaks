// SnapProbe.m —— 探针：dump Snapper3 的 automation_* 控制接口
//
// 目的：路线 A 要驱动 Snapper3 完成长截图。必须先拿到：
//   1. automation_* 定义在哪个类上
//   2. 每个方法的 type encoding（参数/返回类型）
//   3. 该类的完整方法列表（还有哪些可用的钩子）
//   4. Snapper3 里跟 scroll / crop / save 相关的类和方法
//
// 注入 com.apple.springboard，日志 /var/mobile/Documents/SnapProbe.log

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define SP_VERSION @"1.0.0"
static NSString *const kLog = @"/var/mobile/Documents/SnapProbe.log";

static void splog(NSString *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], m];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    @try {
        if (![fm fileExistsAtPath:kLog]) [d writeToFile:kLog atomically:YES];
        else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLog];
            [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile];
        }
    } @catch (__unused NSException *e) {}
}

// 关心的方法名（automation 控制面 + 直接相关的截图/滚动/裁剪/保存）
static const char *kInteresting[] = {
    "automation_start", "automation_scrollToBottom", "automation_setCropRect:",
    "automation_takeCrop", "automation_moveToSaveAndRelease",
    "automation_moveToCloseAndRelease",
    "save", "saveImage", "scroll", "crop", "snapshot", "screenshot", "capture"
};

static BOOL SPNameMatches(const char *nm)
{
    for (int i = 0; i < (int)(sizeof(kInteresting)/sizeof(kInteresting[0])); i++) {
        if (strcasestr(nm, kInteresting[i])) return YES;
    }
    return NO;
}

// 精确判定：是否真的实现了 automation_ 系列
static BOOL SPClassHasAutomation(Class c)
{
    static const char *autoSels[] = {
        "automation_start", "automation_scrollToBottom", "automation_setCropRect:",
        "automation_takeCrop", "automation_moveToSaveAndRelease",
        "automation_moveToCloseAndRelease"
    };
    for (int i = 0; i < 6; i++) {
        if (class_getInstanceMethod(c, sel_registerName(autoSels[i]))) return YES;
    }
    return NO;
}

static void SPDumpClassMethods(Class c)
{
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    splog(@"  ---- %@ 共 %u 个方法（仅显示相关）----", NSStringFromClass(c), n);
    for (unsigned int i = 0; i < n; i++) {
        const char *nm = sel_getName(method_getName(ms[i]));
        if (SPNameMatches(nm)) {
            splog(@"    -%s   encoding=%s", nm, method_getTypeEncoding(ms[i]));
        }
    }
    free(ms);
}

__attribute__((constructor)) static void SPInit(void)
{
    splog(@"SnapProbe %@ 注入 %@", SP_VERSION,
          [[NSProcessInfo processInfo] processName]);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        int count = objc_getClassList(NULL, 0);
        if (count <= 0) { splog(@"没有类"); return; }
        Class *classes = (Class *)malloc(sizeof(Class) * count);
        objc_getClassList(classes, count);

        int found = 0;
        for (int i = 0; i < count; i++) {
            Class c = classes[i];
            const char *cn = class_getName(c);
            if (!strstr(cn, "Snapper") && !strstr(cn, "SBPH") && !strstr(cn, "BigShot")) continue;

            if (SPClassHasAutomation(c)) {
                found++;
                splog(@"");
                splog(@"=== automation 宿主: %@ (super=%s) ===",
                      NSStringFromClass(c), class_getName(class_getSuperclass(c)));
                // 把 automation 六个方法的编码完整打出来
                static const char *autoSels[] = {
                    "automation_start", "automation_scrollToBottom", "automation_setCropRect:",
                    "automation_takeCrop", "automation_moveToSaveAndRelease",
                    "automation_moveToCloseAndRelease"
                };
                for (int j = 0; j < 6; j++) {
                    SEL s = sel_registerName(autoSels[j]);
                    Method m = class_getInstanceMethod(c, s);
                    if (m) splog(@"    ★ -%s  %s", autoSels[j], method_getTypeEncoding(m));
                    else   splog(@"      -%s  未实现", autoSels[j]);
                }
                // 全量 dump 这个类的方法（不再过滤），长截图/滚动的实现可能叫别的名字
                {
                    unsigned int n2 = 0;
                    Method *ms2 = class_copyMethodList(c, &n2);
                    splog(@"  ---- %@ 全部 %u 个方法 ----", NSStringFromClass(c), n2);
                    for (unsigned int k = 0; k < n2; k++) {
                        splog(@"    -%s   %s",
                              sel_getName(method_getName(ms2[k])),
                              method_getTypeEncoding(ms2[k]));
                    }
                    free(ms2);
                }
            }
        }
        splog(@"");
        splog(@"=== 找到 %d 个 automation 宿主 ===", found);

        // 顺带：所有含 Snapper 的类，列出名字，方便后续定位
        splog(@"");
        splog(@"=== 所有 Snapper 相关类 ===");
        for (int i = 0; i < count; i++) {
            const char *cn = class_getName(classes[i]);
            if (strstr(cn, "Snapper")) splog(@"  %s", cn);
        }

        free(classes);
        // 关键类全量方法（找滚动/拼接/长图实现）
        const char *keyClasses[] = {
            "Snapper3PluginManager", "SnapperCropOverlayViewController",
            "SnapperSnapsOverlayViewController", "SnapperFileManager",
            "SnapperOverlayCropControlsLayer"
        };
        for (int i = 0; i < 5; i++) {
            Class kc = objc_getClass(keyClasses[i]);
            if (!kc) continue;
            unsigned int n3 = 0;
            Method *ms3 = class_copyMethodList(kc, &n3);
            splog(@"");
            splog(@"=== %s 全部 %u 个方法 ===", keyClasses[i], n3);
            for (unsigned int k = 0; k < n3; k++) {
                splog(@"    -%s   %s",
                      sel_getName(method_getName(ms3[k])),
                      method_getTypeEncoding(ms3[k]));
            }
            free(ms3);
        }

        splog(@"=== dump 结束 ===");
    });
}
