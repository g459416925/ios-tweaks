// ReScaleKB.m — Re:Scale 2 键盘适配（合并版 1.0.6）
//
// 「行为级还原 + 功能合并」的重写实现：
//   · 还原自 com.xu.rescale2plus 1.0.5-2 内 ReScaleKB.dylib 的双切片反汇编
//     （../../reverse/asm/ReScaleKB_arm64.s、ReScaleKB_arm64e.s）
//   · 并入原独立插件 com.xu.rescalekb440fix（ZZReScaleKB440Fix.dylib）的 440×956 修正
// 合并后只需一个 dylib + 一个注入 plist，不再依赖 ellekit 按文件名排序。
//
// ── 原始 ReScaleKB 结构（逐条指令核对）──────────────────────────────
// ctor（arm64 0x72ac / arm64e 0x72c8）：
//   1. s = jbroot("/Library/dpkg/info/tf.festival.rescale2.list"); access(s, F_OK)
//   2. adds w8, w0, #1 ; b.ne install
//      access 返回 0（存在）时 w8=1 → Z=0 → 跳去安装；返回 -1（缺失）时 w8=0 → 不跳。
//      即 **标记文件存在才装 hook**。方向极易看反，此处以指令与实机行为为准。
//   3. UIApplication.sharedApplication 为 nil 时整体跳过（纯命令行进程不 hook）
//   4. UIKeyboardImpl 元类上 MSHookMessageEx 三个类方法；UIKeyboardLayoutStar 上 hook -setFrame:
//
// 三个类方法体（0x73d0 / 0x75bc / 0x77a8）逐条等价：
//   orig   = 调原实现
//   idiom  = UIDevice.currentDevice.userInterfaceIdiom，非 0 直接返回 orig
//   bounds = UIScreen.mainScreen.bounds
//   pad    = [cls deviceSpecificPaddingForInterfaceOrientation:o inputMode:nil]
//   rect   = CGRectInset(bounds, pad.left, 0)        // dx 取 left，dy 恒 0
//   return CGSize{ rect.size.width, orig.height }    // 宽跟屏幕，高保留原值
//
// -setFrame:（0x7994）：
//   landscape = UIInterfaceOrientationIsLandscape(UIApplication.statusBarOrientation)
//   landscape ? orig(self, setFrame, CGRect{CGPointZero,
//               [UIKeyboardImpl keyboardSizeForInterfaceOrientation:o]})
//             : orig(self, cmd, frame)
//
// ── 本合并版的改动 ────────────────────────────────────────────────
// A. guard 宽容化：原版只认 tf.festival.rescale2.list，而本机装的是重打包的
//    com.xu.rescale2plus，标记文件不在 → 四个原版 dylib 全部静默失效
//    （canvas 与键盘适配一起不生效）。这里任一清单存在即视为已安装，另支持
//    RESCALEKB_FORCE 覆盖。deb 侧由 postinst 补一份标记文件，兼容其余三个原版 dylib。
// B. 440 钳制：竖屏、屏幕 440×956、上游宽度 414 时把宽度钉到 440。
//    原 ZZ 插件靠「后加载再包一层」；现在写在同一层里，结果一致但无顺序依赖。
//    该钳制独立于 A 的 guard 判定，任何情况下都生效。
// C. ⭐ 2026-10-24 修：ctor 里绝不触碰 UIKit。
//    1.0.5-3 之前的试验版在 dyld initializer 阶段调 screenSize() → +[UIScreen mainScreen]
//    → NSAssertion → SIGABRT → 安全模式（2026-10-20 12:25 事故）。现在：
//      · ctor 只做「文件判定 + 日志」，纯 POSIX，不碰任何 UIKit 类；
//      · hook 安装与屏幕查询全部 dispatch_async 到主队列，等 run loop 起来后执行；
//      · 装 hook 前仍按原版语义检查 UIApplication.sharedApplication（主队列上取，安全）。
// D. 单一版本来源：版本号由构建脚本 -DKBM_VERSION_CSTR 注入，源码默认值仅作兜底。
// E. 紧急开关：存在 /var/mobile/Library/com.xu.rescale2plus/kb_disabled 时整体不 hook，
//    免重装即可在设备上关掉（配合 respring）。
//
// 纯函数在 kb440_math.h，主机单测见 ../tools/test_kb440.c。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <math.h>
#import <unistd.h>
#import <stdlib.h>
#import <stdio.h>
#import <glob.h>

#import "kb440_math.h"

extern void MSHookMessageEx(Class, SEL, IMP, IMP *);

// 版本号单一来源：构建脚本通过 -DKBM_VERSION_CSTR="\"x.y.z\"" 注入，
// 保持 C 字符串形态（宏无法生成 @"..." 字面量），需要 NSString 时走 kbmVersion()。
#ifndef KBM_VERSION_CSTR
#define KBM_VERSION_CSTR "1.0.6"
#endif

static inline NSString *kbmVersion(void) {
    return [NSString stringWithUTF8String:KBM_VERSION_CSTR];
}

static NSString *const kGuardListA  = @"/Library/dpkg/info/tf.festival.rescale2.list";
static NSString *const kGuardListB  = @"/Library/dpkg/info/com.xu.rescale2plus.list";
static NSString *const kDisableFlag = @"/var/mobile/Library/com.xu.rescale2plus/kb_disabled";
static NSString *const kLogPath     = @"/var/mobile/Documents/rescale_kb_merge.log";

static BOOL gEnabled = NO;          // 与原版同义：guard 命中才 hook
static int  gLogBudget[3] = {0, 0, 0};

#pragma mark - jbroot 感知的文件判定

// ⭐⭐ 2026-10-24 修复（严重回归）：RootHide 下的 jbroot 前缀**必须**用 RootHide 自己的
// _jbroot() 算，不能用 glob() 枚举 /var/containers/Bundle/Application/.jbroot-*。
//
// 原因：guest 进程（尤其是沙盒 App）没有列目录权限，glob() 直接失败并返回空串，
// 于是 kb_file_exists() 只能试裸路径 /Library/dpkg/info/...（沙盒里同样不可见）→
// 判定全部为 NO → gEnabled=NO → **整个 App 里键盘修正静默失效**。
// 实测：Safari 侥幸命中（jbroot 可枚举），而「电话 / 短信 / 备忘录 / 微信 / 日历」
// 全部 enabled=NO，也就是说真正打字时用的键盘根本没被修正。
//
// 原版 ReScaleKB 的做法就是 ctor 里 `bl _jbroot` 再 `access`，这里恢复同一机制：
//   · 首选运行期 dlsym("jbroot")（libroothide 通过 RTLD_GLOBAL 提供，签名 char*(const char*)）
//   · 退回 JBROOT 环境变量
//   · 最后才用 glob() 枚举（仅作兜底，仅对非沙盒进程有效）
// 注意 _jbroot 返回的是 malloc 缓冲，必须 free。
typedef char *(*kb_jbroot_fn)(const char *);
static void kb_jbroot_free(void *p) { if (p) free(p); }

static NSString *kb_jbroot(void) {
    static NSString *cached = nil;
    if (cached) return cached;

    // 1) 运行期符号（与原版二进制一致）
    kb_jbroot_fn fn = (kb_jbroot_fn)dlsym(RTLD_DEFAULT, "jbroot");
    if (fn) {
        char *r = fn("/");
        if (r && r[0]) {
            // _jbroot("/") 返回形如 /var/containers/Bundle/Application/.jbroot-XXXX/
            // 去掉尾部 '/'，便于直接 stringByAppendingString:
            NSString *s = [NSString stringWithUTF8String:r];
            kb_jbroot_free(r);
            while (s.length > 1 && [s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
            if (s.length > 1) { cached = s; return cached; }
        } else if (r) {
            kb_jbroot_free(r);
        }
    }

    // 2) 环境变量
    const char *env = getenv("JBROOT");
    if (env && env[0]) { cached = [NSString stringWithUTF8String:env]; return cached; }

    // 3) glob 兜底（沙盒进程下通常不可用）
    glob_t g;
    if (glob("/var/containers/Bundle/Application/.jbroot-*", 0, NULL, &g) == 0 && g.gl_pathc) {
        cached = [NSString stringWithUTF8String:g.gl_pathv[0]];
        globfree(&g);
    } else {
        cached = @"";
    }
    return cached;
}

// 标记文件判定：裸路径 + jbroot 前缀路径都试。
// ⭐ RootHide 上即使裸路径也不可读时，用 _jbroot() 算出来的前缀就能读到了。
static BOOL kb_file_exists(NSString *path) {
    if (access(path.fileSystemRepresentation, F_OK) == 0) return YES;
    NSString *jb = kb_jbroot();
    if (jb.length && access([jb stringByAppendingString:path].fileSystemRepresentation, F_OK) == 0) return YES;
    return NO;
}

#pragma mark - 日志

static void kblog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[ReScaleKB %@] pid=%d %@", kbmVersion(), getpid(), body];
    NSLog(@"%@", line);

    // 落盘策略（2026-10-24 修）：沙盒 App 进程（Safari/微信…）没有 /var/mobile/Documents
    // 写权限，fopen 失败会伪装成「插件没注入」。按顺序试两个可写点，都失败只丢日志。
    //   1) /var/mobile/Documents/…       —— SpringBoard 与守护进程可写
    //   2) 本进程 tmp/rescale_kb_merge.log —— 沙盒 App 唯一稳的可写点
    NSString *tmpCopy = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rescale_kb_merge.log"];
    for (NSString *path in @[kLogPath, tmpCopy ?: @""]) {
        if (path.length == 0) continue;
        FILE *f = fopen(path.fileSystemRepresentation, "a");
        if (f) { fprintf(f, "%s\n", line.UTF8String); fclose(f); return; }
    }
}

#pragma mark - 原始实现指针

typedef CGSize (*KBSizeIMP)(id, SEL, UIInterfaceOrientation);
typedef void   (*KBSetFrameIMP)(id, SEL, CGRect);
typedef struct { double top, left, bottom, right; } KBEdgeInsets;   // 与 UIEdgeInsets 同布局

static KBSizeIMP gOrigDefault, gOrigKeyboard, gOrigSize;
static KBSetFrameIMP gOrigSetFrame;

static BOOL isIPhone(void) {
    Class dev = objc_getClass("UIDevice");
    if (!dev) return NO;
    id d = ((id(*)(id, SEL))objc_msgSend)((id)dev, NSSelectorFromString(@"currentDevice"));
    if (!d) return NO;
    return ((long(*)(id, SEL))objc_msgSend)(d, NSSelectorFromString(@"userInterfaceIdiom")) == 0;
}

static KBEdgeInsets paddingFor(Class keyboardClass, UIInterfaceOrientation o) {
    SEL sel = NSSelectorFromString(@"deviceSpecificPaddingForInterfaceOrientation:inputMode:");
    if (!keyboardClass || ![keyboardClass respondsToSelector:sel]) return (KBEdgeInsets){0, 0, 0, 0};
    return ((KBEdgeInsets(*)(id, SEL, UIInterfaceOrientation, id))objc_msgSend)((id)keyboardClass, sel, o, nil);
}

// ⚠️ 只能在主队列（run loop 已启动、UIKit 已就绪）之后调用。
//    dyld initializer 阶段调用会 NSAssertion → SIGABRT（见文首 C 项）。
static CGSize screenSize(void) {
    static CGSize fake = {0, 0};
    static BOOL probed = NO;
    if (!probed) {   // 仅调试：RESCALEKB_FAKE_SCREEN=440x956 用假屏幕驱动分支
        probed = YES;
        const char *e = getenv("RESCALEKB_FAKE_SCREEN");
        if (e) { double w = 0, h = 0; if (sscanf(e, "%lfx%lf", &w, &h) == 2 && w > 0 && h > 0) fake = CGSizeMake(w, h); }
    }
    if (fake.width > 0) return fake;

    Class scr = objc_getClass("UIScreen");
    if (!scr) return CGSizeZero;
    id s = ((id(*)(id, SEL))objc_msgSend)((id)scr, NSSelectorFromString(@"mainScreen"));
    if (!s) return CGSizeZero;
    CGRect b = ((CGRect(*)(id, SEL))objc_msgSend)(s, NSSelectorFromString(@"bounds"));
    return b.size;
}

#pragma mark - 三个类方法 hook

static CGSize handleSize(KBSizeIMP orig, const char *name, int slot,
                         id self, SEL cmd, UIInterfaceOrientation o) {
    CGSize original = orig ? orig(self, cmd, o) : CGSizeZero;

    CGSize screen = screenSize();
    CGSize out = original;

    if (gEnabled && orig && isIPhone()) {
        KBEdgeInsets pad = paddingFor(object_getClass(self), o);
        out = kb_corrected_size(screen, pad.left, original, (long)o);   // 宽跟屏幕，高保留
    }
    // 440 钳制独立于 guard：重写后宽度已是屏幕宽，这一句是 414 的兜底
    BOOL clamp440 = kb_should_apply_440(screen, (long)o, original);
    if (clamp440) out.width = screen.width;

    BOOL changed = fabs(out.width - original.width) > KB_EPS || fabs(out.height - original.height) > KB_EPS;
    if ((changed || slot == 0) && gLogBudget[slot] < 40) {
        gLogBudget[slot]++;
        kblog(@"%s o=%ld before={%.2f,%.2f} after={%.2f,%.2f} screen={%.2f,%.2f} action=%@",
              name, (long)o, original.width, original.height, out.width, out.height,
              screen.width, screen.height,
              clamp440 ? @"440-fix" : (changed ? @"screen-width" : @"pass"));
    }
    return out;
}

static CGSize fixedDefault(id self, SEL cmd, UIInterfaceOrientation o) {
    return handleSize(gOrigDefault, "defaultSizeForInterfaceOrientation:", 0, self, cmd, o);
}
static CGSize fixedKeyboard(id self, SEL cmd, UIInterfaceOrientation o) {
    return handleSize(gOrigKeyboard, "keyboardSizeForInterfaceOrientation:", 1, self, cmd, o);
}
static CGSize fixedSize(id self, SEL cmd, UIInterfaceOrientation o) {
    return handleSize(gOrigSize, "sizeForInterfaceOrientation:", 2, self, cmd, o);
}

#pragma mark - UIKeyboardLayoutStar setFrame:

static long statusBarOrientation(void) {
    Class app = objc_getClass("UIApplication");
    if (!app) return 0;
    id a = ((id(*)(id, SEL))objc_msgSend)((id)app, NSSelectorFromString(@"sharedApplication"));
    if (!a) return 0;
    return ((long(*)(id, SEL))objc_msgSend)(a, NSSelectorFromString(@"statusBarOrientation"));
}

static void fixedSetFrame(id self, SEL cmd, CGRect frame) {
    if (!gOrigSetFrame) return;
    if (!gEnabled) { gOrigSetFrame(self, cmd, frame); return; }

    long o = statusBarOrientation();
    if (!kb_is_landscape(o)) { gOrigSetFrame(self, cmd, frame); return; }

    Class kb = objc_getClass("UIKeyboardImpl");
    SEL sel = NSSelectorFromString(@"keyboardSizeForInterfaceOrientation:");
    CGSize size = CGSizeZero;
    if (kb && [(id)kb respondsToSelector:sel])
        size = ((CGSize(*)(id, SEL, long))objc_msgSend)((id)kb, sel, o);

    gOrigSetFrame(self, cmd, CGRectMake(0, 0, size.width, size.height));
}

#pragma mark - 自检导出（设备侧 harness dlopen 后验证 440 分支）

__attribute__((visibility("default")))
CGSize kb_selftest_probe_screen(CGSize screen, CGSize synthetic, long orientation) {
    KBEdgeInsets pad = paddingFor(objc_getClass("UIKeyboardImpl"), (UIInterfaceOrientation)orientation);
    CGSize out = kb_corrected_size(screen, pad.left, synthetic, orientation);
    if (kb_should_apply_440(screen, orientation, synthetic)) out.width = screen.width;
    kblog(@"selftest screen={%.2f,%.2f} synthetic={%.2f,%.2f} o=%ld -> {%.2f,%.2f} action=%@",
          screen.width, screen.height, synthetic.width, synthetic.height, orientation,
          out.width, out.height,
          kb_should_apply_440(screen, orientation, synthetic) ? @"440-fix" : @"pass");
    return out;
}

#pragma mark - 安装

static void installMeta(Class cls, const char *selName, IMP rep, IMP *orig) {
    SEL sel = NSSelectorFromString([NSString stringWithUTF8String:selName]);
    Method m = class_getClassMethod(cls, sel);
    if (!m) { kblog(@"missing +%s", selName); return; }
    Dl_info info = {0};
    const char *owner = "-";
    if (dladdr((const void *)method_getImplementation(m), &info) && info.dli_fname) owner = info.dli_fname;
    kblog(@"hook +%s enc=%s owner=%s", selName, method_getTypeEncoding(m), owner);
    MSHookMessageEx(object_getClass(cls), sel, rep, orig);
}

static void installInstance(Class cls, const char *selName, IMP rep, IMP *orig) {
    SEL sel = NSSelectorFromString([NSString stringWithUTF8String:selName]);
    if (!class_getInstanceMethod(cls, sel)) { kblog(@"missing -%s", selName); return; }
    kblog(@"hook -%s on %s", selName, class_getName(cls));
    MSHookMessageEx(cls, sel, rep, orig);
}

// ⚠️ 这段体内不得出现任何 UIKit 类方法调用（见文首 C 项）。
__attribute__((constructor)) static void ReScaleKBInit(void) {
    BOOL markA = kb_file_exists(kGuardListA);
    BOOL markB = kb_file_exists(kGuardListB);
    BOOL flag  = kb_file_exists(kDisableFlag);
    gEnabled = (markA || markB || getenv("RESCALEKB_FORCE") != NULL) && !flag;

    kblog(@"ctor version=%@ bundle=%@ guard{A=%@ B=%@} disabled-flag=%@ enabled=%@ jbroot=%@",
          kbmVersion(), NSBundle.mainBundle.bundleIdentifier ?: @"(null)",
          markA ? @"yes" : @"no", markB ? @"yes" : @"no", flag ? @"yes" : @"no",
          gEnabled ? @"YES" : @"NO", kb_jbroot());

    if (!gEnabled) return;   // 与原版一致：包标记不存在则不 hook

    // 延迟到主队列：此时 run loop 已启动、UIKit 已就绪，取 sharedApplication / UIScreen 均安全。
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            Class app = objc_getClass("UIApplication");
            if (!app) { kblog(@"UIApplication unavailable, skip"); return; }
            id shared = ((id(*)(id, SEL))objc_msgSend)((id)app, NSSelectorFromString(@"sharedApplication"));
            if (!shared) { kblog(@"sharedApplication nil, skip (命令行进程)"); return; }

            Class kb = objc_getClass("UIKeyboardImpl");
            if (!kb) { kblog(@"UIKeyboardImpl unavailable"); return; }
            installMeta(kb, "defaultSizeForInterfaceOrientation:", (IMP)fixedDefault, (IMP *)&gOrigDefault);
            installMeta(kb, "keyboardSizeForInterfaceOrientation:", (IMP)fixedKeyboard, (IMP *)&gOrigKeyboard);
            installMeta(kb, "sizeForInterfaceOrientation:", (IMP)fixedSize, (IMP *)&gOrigSize);

            Class star = objc_getClass("UIKeyboardLayoutStar");
            if (star) installInstance(star, "setFrame:", (IMP)fixedSetFrame, (IMP *)&gOrigSetFrame);
            else kblog(@"UIKeyboardLayoutStar unavailable");

            CGSize s = screenSize();
            kblog(@"ready screen={%.1f,%.1f} 440-eligible=%@", s.width, s.height,
                  kb_should_apply_440(s, 1, CGSizeMake(KB_STALE_W, 0)) ? @"YES" : @"NO");
        }
    });
}
