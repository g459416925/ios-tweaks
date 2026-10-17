// KBPathProbe5 — keyboard rounded-path call-site probe
// Evidence target: identify the low-level UIKitCore caller that creates the
// visible keycap path, with its CGRect and radius. No rendering values are
// modified by this probe.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdio.h>

extern void MSHookFunction(void *symbol, void *replace, void **result);
extern void MSHookMessageEx(Class cls, SEL sel, IMP replacement, IMP *result);

static CGPathRef (*p5_orig_create)(CGRect, CGFloat, CGFloat, const CGAffineTransform *) = NULL;
static void (*p5_orig_add)(CGMutablePathRef, const CGAffineTransform *, CGRect, CGFloat, CGFloat) = NULL;
static NSMutableSet<NSString *> *p5_seen;
static IMP p5_orig_set_clip = NULL;

static void p5_log(NSString *message) {
    NSString *line = [NSString stringWithFormat:@"[kbp5:%d] %@", getpid(), message];
    FILE *fp = fopen("/var/mobile/Documents/kbc_cgpath.log", "a");
    if (!fp) fp = fopen("/var/tmp/kbc_cgpath.log", "a");
    if (fp) {
        fprintf(fp, "%s\n", line.UTF8String);
        fclose(fp);
    }
}

static BOOL p5_keyboard_sized(CGRect rect, CGFloat rx, CGFloat ry) {
    double w = fabs(rect.size.width);
    double h = fabs(rect.size.height);
    double x = fabs(rx);
    double y = fabs(ry);
    return w >= 25.0 && w <= 240.0 && h >= 25.0 && h <= 75.0 &&
           x <= 30.0 && y <= 30.0;
}

static void p5_record(const char *kind, CGRect rect, CGFloat rx, CGFloat ry, void *caller) {
    if (!p5_keyboard_sized(rect, rx, ry)) return;

    Dl_info info = {0};
    if (!dladdr(caller, &info) || !info.dli_fname || !info.dli_fbase) return;
    NSString *image = [NSString stringWithUTF8String:info.dli_fname];
    if ([image rangeOfString:@"UIKitCore"].location == NSNotFound) return;

    uintptr_t offset = (uintptr_t)caller - (uintptr_t)info.dli_fbase;
    NSString *key = [NSString stringWithFormat:@"%s|%lx|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f",
                     kind, (unsigned long)offset,
                     rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, rx, ry];
    @synchronized (p5_seen) {
        if ([p5_seen containsObject:key]) return;
        [p5_seen addObject:key];
    }

    p5_log([NSString stringWithFormat:@"path kind=%s caller=UIKitCore+0x%lx rect={%.2f,%.2f,%.2f,%.2f} radius={%.2f,%.2f}",
            kind, (unsigned long)offset,
            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height, rx, ry]);
}

static CGPathRef p5_create(CGRect rect, CGFloat rx, CGFloat ry, const CGAffineTransform *transform) {
    p5_record("create", rect, rx, ry, __builtin_return_address(0));
    return p5_orig_create(rect, rx, ry, transform);
}

static void p5_add(CGMutablePathRef path, const CGAffineTransform *transform,
                   CGRect rect, CGFloat rx, CGFloat ry) {
    p5_record("add", rect, rx, ry, __builtin_return_address(0));
    p5_orig_add(path, transform, rect, rx, ry);
}

static id p5_object(id object, const char *selector_name) {
    if (!object) return nil;
    SEL selector = sel_registerName(selector_name);
    if (![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static long long p5_integer(id object, const char *selector_name, long long fallback) {
    if (!object) return fallback;
    SEL selector = sel_registerName(selector_name);
    if (![object respondsToSelector:selector]) return fallback;
    @try {
        return ((long long (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return fallback;
    }
}

static NSString *p5_short_description(id value) {
    if (!value) return @"nil";
    NSString *description = [value description] ?: @"nil";
    if (description.length > 120) description = [description substringToIndex:120];
    return description;
}

static void p5_set_clip(id self, SEL command, unsigned long long corners) {
    @try {
        NSString *name = p5_short_description(p5_object(self, "name"));
        void *caller = __builtin_return_address(0);
        Dl_info info = {0};
        unsigned long offset = 0;
        if (dladdr(caller, &info) && info.dli_fbase) {
            offset = (unsigned long)((uintptr_t)caller - (uintptr_t)info.dli_fbase);
        }
        p5_log([NSString stringWithFormat:
                @"tree name=%@ clip=0x%llx caller=0x%lx display=%lld row=%lld visual=%lld interaction=%lld type=%lld state=%lld renderString=%lld cache=%lld adaptive=%lld charging=%lld letters=%lld shiftChooser=%lld",
                name, corners, offset,
                p5_integer(self, "displayType", -1),
                p5_integer(self, "displayRowHint", -1),
                p5_integer(self, "visualStyle", -1),
                p5_integer(self, "interactionType", -1),
                p5_integer(self, "type", -1),
                p5_integer(self, "state", -1),
                p5_integer(self, "_renderAsStringKey", -1),
                p5_integer(self, "shouldCacheKey", -1),
                p5_integer(self, "usesAdaptiveKeys", -1),
                p5_integer(self, "usesKeyCharging", -1),
                p5_integer(self, "isLetters", -1),
                p5_integer(self, "isShiftKeyPlaneChooser", -1)]);
    } @catch (__unused NSException *exception) {
    }
    if (p5_orig_set_clip) {
        ((void (*)(id, SEL, unsigned long long))p5_orig_set_clip)(self, command, corners);
    }
}

__attribute__((constructor)) static void p5_ctor(void) {
    @autoreleasepool {
        p5_seen = [NSMutableSet new];
        p5_log(@"ctor read-only probe");

        void *create = dlsym(RTLD_DEFAULT, "CGPathCreateWithRoundedRect");
        if (create) {
            MSHookFunction(create, (void *)p5_create, (void **)&p5_orig_create);
            p5_log(@"hooked CGPathCreateWithRoundedRect");
        } else {
            p5_log(@"missing CGPathCreateWithRoundedRect");
        }

        void *add = dlsym(RTLD_DEFAULT, "CGPathAddRoundedRect");
        if (add) {
            MSHookFunction(add, (void *)p5_add, (void **)&p5_orig_add);
            p5_log(@"hooked CGPathAddRoundedRect");
        } else {
            p5_log(@"missing CGPathAddRoundedRect");
        }

        Class tree = objc_getClass("UIKBTree");
        SEL set_clip = sel_registerName("setClipCorners:");
        if (tree && class_getInstanceMethod(tree, set_clip)) {
            MSHookMessageEx(tree, set_clip, (IMP)p5_set_clip, &p5_orig_set_clip);
            p5_log(@"hooked UIKBTree setClipCorners:");
        } else {
            p5_log(@"missing UIKBTree setClipCorners:");
        }
    }
}
