// ShotSuitePrefs.m —— 「截图套件」设置面板
//
// 1.0.2：不做二级跳转 —— 把 Snapper 3 / Hammer It 两个原面板的**一级设置项**
// 直接平铺到本页；分组标题由 Root.plist 提供，代码只在对应分组后插入子项。
//
// ⚠️ iOS16 + RootHide 的硬性写法（删了必坏）：
//   · PSListController 不会自动加载 bundle 内 Root.plist → 显式 loadSpecifiersFromPlistName；
//   · 它渲染私有 ivar _specifiers → 必须 KVC 写回，只重写 -specifiers 会白屏；
//   · 子面板 bundle 实体在 jbroot 内，本进程按真系统视图看不到 → glob .jbroot-* 定位；
//   · 子面板的 specifier.target 指向子控制器实例 → 必须强引用，否则 target 释放崩溃。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <glob.h>

@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)insertContiguousSpecifiers:(NSArray *)specifiers
                    afterSpecifier:(PSSpecifier *)specifier
                          animated:(BOOL)animated;
@end

#define SSS_VERSION @"1.0.3"
static NSString *const kLog = @"/var/mobile/Documents/ShotSuitePrefs.log";

static void SSLog(NSString *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], m];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    @try {
        if (![fm fileExistsAtPath:kLog]) [d writeToFile:kLog atomically:YES];
        else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLog];
            [fh seekToEndOfFile]; [fh writeData:d]; [fh closeFile];
        }
    } @catch (NSException *e) {
        NSLog(@"[ShotSuite] log fail: %@", e);
    }
}

// 取子面板的一级 specifier 列表
// 只保留必要项：白名单按 label 精确匹配，其余（推广、关于、工具、外观、兼容性开关）全部丢弃
static NSArray *SSKeepList(NSString *name)
{
    if ([name isEqualToString:@"Snapper3Preferences"]) {
        return @[@"Activation methods",   // 截图触发方式
                 @"OCR settings",         // OCR 精度/算法/语言
                 @"Plugins",              // 与 HammerIt / Imgur 的联动
                 @"Snap history"];        // 历史入口与保存上限
    }
    if ([name isEqualToString:@"HammerItPrefs"]) {
        return @[@"主要功能设置",           // 取词模式 / 复制 / 搜索引擎
                 @"翻译服务设置",           // 翻译源与 API Key
                 @"编辑菜单设置"];          // 长按菜单按钮
    }
    return @[];
}


@interface ShotSuiteRootController : PSListController
@end

@implementation ShotSuiteRootController {
    NSMutableArray *_kids;   // 强引用子面板控制器（specifier 的 target 是它们）
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"截图套件";
    SSLog(@"面板加载 v%@", SSS_VERSION);
}

// RootHide 下 /Library 有两套视图：本插件自己的 bundle 由 PreferenceLoader
// （注入的 dylib，走 jbroot 路径）加载，本进程直接 open 只能看到真系统的
// /Library —— 那里没有第三方 bundle。必须自己定位 jbroot 实体路径。
static NSString *SSResolveBundle(NSString *rel)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:rel]) return rel;

    void *h = dlopen("/usr/lib/libroot.dylib", RTLD_LAZY);
    if (!h) h = dlopen("/var/jb/usr/lib/libroot.dylib", RTLD_LAZY);
    char *(*jbr)(const char *) = h ? (char *(*)(const char *))dlsym(h, "jbroot") : NULL;
    if (jbr) {
        char *p = jbr(rel.UTF8String);
        if (p && [fm fileExistsAtPath:@(p)]) return @(p);
    }

    glob_t g;
    NSString *pat = [NSString stringWithFormat:@"/var/containers/Bundle/Application/.jbroot-*%@", rel];
    NSString *hit = nil;
    if (glob(pat.UTF8String, 0, NULL, &g) == 0) {
        for (size_t i = 0; i < g.gl_pathc; i++) {
            NSString *p = @(g.gl_pathv[i]);
            if ([fm fileExistsAtPath:p]) { hit = p; break; }
        }
        globfree(&g);
    }
    SSLog(@"resolve %@ -> %@", rel, hit ?: @"未找到");
    return hit;
}

// label 可能挂在 propertyForKey:@"label" 上，也可能只能通过 -name 取到
static NSString *SSLabelOf(PSSpecifier *sp)
{
    id l = [sp propertyForKey:@"label"];
    if ([l isKindOfClass:[NSString class]] && [l length]) return l;
    SEL sel = sel_registerName("name");
    if ([sp respondsToSelector:sel]) {
        NSString *(*fn)(id, SEL) = (void *)objc_msgSend;
        id n = fn(sp, sel);
        if ([n isKindOfClass:[NSString class]] && [n length]) return n;
    }
    return nil;
}

- (NSArray *)filter:(NSArray *)specs keep:(NSArray *)keep
{
    NSMutableArray *out = [NSMutableArray array];
    for (PSSpecifier *sp in specs) {
        NSString *label = SSLabelOf(sp);
        if (label && [keep containsObject:label]) [out addObject:sp];
    }
    return out;
}

- (NSArray *)specsFromBundle:(NSString *)name
{
    NSString *rel = [NSString stringWithFormat:@"/Library/PreferenceBundles/%@.bundle", name];
    NSString *path = SSResolveBundle(rel);
    if (!path) return @[];

    NSBundle *b = [NSBundle bundleWithPath:path];
    NSError *err = nil;
    if (!b || ![b loadAndReturnError:&err]) {
        SSLog(@"%@ 加载失败: %@", name, err);
        return @[];
    }
    Class cls = [b principalClass];
    if (!cls) { SSLog(@"%@ principalClass 为空", name); return @[]; }

    id vc = [[cls alloc] init];
    if (!vc) { SSLog(@"%@ 实例化失败", name); return @[]; }
    if (!_kids) _kids = [NSMutableArray array];
    [_kids addObject:vc];

    SEL sel = sel_registerName("specifiers");
    NSArray *s = nil;
    if ([vc respondsToSelector:sel]) {
        NSArray *(*fn)(id, SEL) = (void *)objc_msgSend;
        s = fn(vc, sel);
    }
    // 有些控制器要到视图加载后才建 specifier
    if (!s.count && [vc isKindOfClass:[UIViewController class]]) {
        [(UIViewController *)vc loadViewIfNeeded];
        if ([vc respondsToSelector:sel]) {
            NSArray *(*fn)(id, SEL) = (void *)objc_msgSend;
            s = fn(vc, sel);
        }
    }
    NSArray *kept = [self filter:s ?: @[] keep:SSKeepList(name)];
    SSLog(@"%@ 原始 %lu 项 -> 保留 %lu 项", name, (unsigned long)s.count, (unsigned long)kept.count);
    return kept;
}

- (NSArray *)specifiers
{
    NSArray *cached = nil;
    @try { cached = [self valueForKey:@"_specifiers"]; } @catch (__unused NSException *e) {}
    if ([cached isKindOfClass:[NSArray class]] && cached.count) return cached;

    NSMutableArray *base = [self loadSpecifiersFromPlistName:@"Root" target:self];
    @try { [self setValue:base forKey:@"_specifiers"]; } @catch (NSException *e) {
        SSLog(@"写 _specifiers 失败: %@", e);
    }

    PSSpecifier *snapGroup = nil, *hammerGroup = nil;
    for (PSSpecifier *sp in base) {
        NSString *l = SSLabelOf(sp);
        if ([l isEqualToString:@"Snapper 3"]) snapGroup = sp;
        else if ([l isEqualToString:@"Hammer It"]) hammerGroup = sp;
    }

    // 走官方插入 API：它会做 cell 元数据/索引登记，直接改数组会导致子项不渲染
    NSArray *snapItems = [self specsFromBundle:@"Snapper3Preferences"];
    if (snapGroup && snapItems.count) {
        @try {
            [self insertContiguousSpecifiers:snapItems afterSpecifier:snapGroup animated:NO];
        } @catch (NSException *e) { SSLog(@"插入 Snapper 失败: %@", e); }
    }
    NSArray *hammerItems = [self specsFromBundle:@"HammerItPrefs"];
    if (hammerGroup && hammerItems.count) {
        @try {
            [self insertContiguousSpecifiers:hammerItems afterSpecifier:hammerGroup animated:NO];
        } @catch (NSException *e) { SSLog(@"插入 Hammer 失败: %@", e); }
    }

    NSArray *result = nil;
    @try { result = [self valueForKey:@"_specifiers"]; } @catch (__unused NSException *e) {}
    if (![result isKindOfClass:[NSArray class]]) result = base;
    SSLog(@"合并后共 %lu 项", (unsigned long)result.count);
    return result;
}

@end
