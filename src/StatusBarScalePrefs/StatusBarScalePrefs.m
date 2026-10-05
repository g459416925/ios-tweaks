// StatusBarScalePrefs.m —— StatusBarScale 设置面板（PreferenceBundle）
//
// 作用：在「设置」App 里为 StatusBarScale 提供可视化配置界面。
//   ① 开关类：PSSwitchCell（原生）
//   ② 数值类：自定义 SBSSliderCell（滑块 + 实时数值，拖动即预览、松手即保存）
//   ③ 操作类：PSButtonCell（恢复默认 / 重启桌面）
//
// 关键设计（RootHide / arm64e 约束）：
//   -- 不链接 Preferences.framework：PSSpecifier / PSTableCell / PSListController
//      全部只做编译期前向声明，链接用 -undefined dynamic_lookup，
//      运行时由「设置」App 自身提供（零硬符号，与 tweak 侧 §2.4 同理）。
//   -- 配置读写走 CFPreferences（domain = com.xu.statusbarscale）。
//      「设置」App 与 SpringBoard 都是被 RootHide patch 过的进程，两边解析到
//      **同一份** /var/mobile/Library/Preferences/com.xu.statusbarscale.plist。
//   -- 保存后发 Darwin 通知 com.xu.statusbarscale/prefsChanged，
//      插件侧监听到即热重载配置并重排，无需 respring。
//
// ⚠️ 本文件禁止出现完整 /System/Library/... 路径字面量（RootHide patch 会改坏签名）。
// ⚠️ 面板里单元格类型由 Root.plist 的 cellClass 指定，故本文件不构造 specifier。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <spawn.h>

extern char **environ;

#define PREFS_DOMAIN   "com.xu.statusbarscale"
#define NOTIFY_RELOAD  "com.xu.statusbarscale/prefsChanged"

// ══════════════════════════ 私有类前向声明（零链接期符号） ══════════════════════════

@interface PSSpecifier : NSObject
- (NSString *)name;
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
@end

@interface PSTableCell : UITableViewCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier;
- (PSSpecifier *)specifier;
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier;
@end

@interface PSListController : UIViewController
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
@end

// ══════════════════════════ 配置读写 ══════════════════════════
//
// ⚠️⚠️ 不用 CFPreferences！实测（2026-10-05）：
//   RootHide 下「设置」App 进程的 CFPreferences 读写落在**影子目录**
//   `/var/mobile/Library/Preferences/`（内容停在 10-04 的旧值 dy=1.7），
//   而插件（SpringBoard）读硬编码 `/var/mobile/...` 实际解析到**真实文件**
//   `/rootfs/private/var/mobile/Library/Preferences/`（dy=1.5）——
//   两边根本不是同一份文件，改设置对插件完全无效。
//   ⇒ 面板一律**直接读写真实路径**（含 /rootfs 前缀），并在影子路径上同步一份，
//     保证无论从哪个视角看内容都一致。

static NSArray<NSString *> *SBSPrefsPaths(void) {
    // 第 0 项 = 插件真正读取的真实文件；第 1 项 = 影子副本（兼容/留证）
    return @[@"/rootfs/private/var/mobile/Library/Preferences/com.xu.statusbarscale.plist",
             @"/var/mobile/Library/Preferences/com.xu.statusbarscale.plist"];
}

static NSMutableDictionary *SBSPrefsLoad(void) {
    for (NSString *p in SBSPrefsPaths()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d.count) return [d mutableCopy];
    }
    return [NSMutableDictionary dictionary];
}

static id SBSPrefGet(NSString *key, id fallback) {
    if (!key) return fallback;
    id v = SBSPrefsLoad()[key];
    return v ?: fallback;
}

static NSString *SBSPrefsPrimaryPath(void) { return SBSPrefsPaths()[0]; }

static void SBSPrefSet(NSString *key, id value) {
    if (!key) return;
    for (NSString *p in SBSPrefsPaths()) {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:p]
                               ?: [NSMutableDictionary dictionary];
        if (value) d[key] = value; else [d removeObjectForKey:key];
        [d writeToFile:p atomically:YES];
    }
    // 通知插件热重载（Darwin 通知，插件侧已注册）
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR(NOTIFY_RELOAD), NULL, NULL, YES);
}

// ══════════════════════════ 自定义滑块单元格 ══════════════════════════

@interface SBSSliderCell : PSTableCell
@property (nonatomic, strong) UILabel  *sbsValueLabel;
@property (nonatomic, strong) UISlider *sbsSlider;
@end

@implementation SBSSliderCell

- (PSSpecifier *)sbsSpecifier {
    PSSpecifier *sp = nil;
    if ([self respondsToSelector:@selector(specifier)]) sp = [self specifier];
    if (!sp) {
        @try { sp = [self valueForKey:@"specifier"]; } @catch (__unused NSException *e) {}
    }
    return sp;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) [self sbsBuild];
    return self;
}

- (void)sbsBuild {
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.textLabel.font = [UIFont systemFontOfSize:15.0];
    self.textLabel.textColor = [UIColor labelColor];

    _sbsValueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _sbsValueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15.0
                                                           weight:UIFontWeightSemibold];
    _sbsValueLabel.textColor = [UIColor secondaryLabelColor];
    _sbsValueLabel.textAlignment = NSTextAlignmentRight;
    _sbsValueLabel.adjustsFontSizeToFitWidth = YES;
    _sbsValueLabel.minimumScaleFactor = 0.8;
    [self.contentView addSubview:_sbsValueLabel];

    _sbsSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    _sbsSlider.continuous = YES;
    [_sbsSlider addTarget:self action:@selector(sbsSliderMoved:)
         forControlEvents:UIControlEventValueChanged];
    [_sbsSlider addTarget:self action:@selector(sbsSliderCommitted:)
         forControlEvents:(UIControlEventTouchUpInside |
                           UIControlEventTouchUpOutside |
                           UIControlEventTouchCancel)];
    [self.contentView addSubview:_sbsSlider];

    [self sbsLoadFromPrefs];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    self.textLabel.frame  = CGRectMake(16.0, 6.0, w - 118.0, 20.0);
    self.sbsValueLabel.frame = CGRectMake(w - 100.0, 6.0, 84.0, 20.0);
    self.sbsSlider.frame  = CGRectMake(16.0, h - 36.0, w - 32.0, 31.0);
}

- (NSString *)sbsFormat:(float)v specifier:(PSSpecifier *)sp {
    NSNumber *p = [sp propertyForKey:@"precision"];
    NSInteger prec = p ? p.integerValue : 2;
    NSString *unit = [sp propertyForKey:@"unit"];
    return [NSString stringWithFormat:@"%.*f%@", (int)prec, v, unit ?: @""];
}

- (void)sbsLoadFromPrefs {
    PSSpecifier *sp = [self sbsSpecifier];
    NSString *key  = [sp propertyForKey:@"key"];
    NSNumber *mn   = [sp propertyForKey:@"min"];
    NSNumber *mx   = [sp propertyForKey:@"max"];
    NSNumber *def  = [sp propertyForKey:@"default"];

    self.sbsSlider.minimumValue = mn ? mn.floatValue : 0.0f;
    self.sbsSlider.maximumValue = mx ? mx.floatValue : 1.0f;

    id cur = SBSPrefGet(key, def);
    float v = [cur respondsToSelector:@selector(floatValue)] ? [cur floatValue]
                                                             : (def ? def.floatValue : 0.0f);
    if (v < self.sbsSlider.minimumValue) v = self.sbsSlider.minimumValue;
    if (v > self.sbsSlider.maximumValue) v = self.sbsSlider.maximumValue;
    self.sbsSlider.value = v;

    NSString *label = [sp propertyForKey:@"label"] ?: [sp name];
    if (label.length) self.textLabel.text = label;
    self.sbsValueLabel.text = [self sbsFormat:v specifier:sp];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self sbsLoadFromPrefs];
}

- (void)sbsSliderMoved:(UISlider *)s {
    self.sbsValueLabel.text = [self sbsFormat:s.value specifier:[self sbsSpecifier]];
}

- (void)sbsSliderCommitted:(UISlider *)s {
    PSSpecifier *sp = [self sbsSpecifier];
    self.sbsValueLabel.text = [self sbsFormat:s.value specifier:sp];
    SBSPrefSet([sp propertyForKey:@"key"], @(s.value));
}

@end

// ══════════════════════════ 主控制器 ══════════════════════════

@interface SBSRootListController : PSListController
@end

@implementation SBSRootListController

- (NSArray *)specifiers {
    NSArray *sp = nil;
    @try { sp = [self valueForKey:@"_specifiers"]; } @catch (__unused NSException *e) {}
    if (!sp) {
        sp = [self loadSpecifiersFromPlistName:@"Root" target:self];
        if (sp) {
            @try { [self setValue:sp forKey:@"_specifiers"]; } @catch (__unused NSException *e) {}
        }
    }
    return sp;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"状态栏缩放";
}

// ── 统一读写入口：Root.plist 里每个 specifier 都指定 get/set 指向这两个方法 ──
//    （这样开关也走真实路径，而不是 Preferences 默认的 CFPreferences 影子目录）
- (id)sbsReadPref:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (key.length == 0) return nil;
    if ([key isEqualToString:@"sbsAboutVersion"]) {
        return [[NSBundle bundleForClass:[self class]]
                    objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"—";
    }
    id v = SBSPrefsLoad()[key];
    return v ?: [spec propertyForKey:@"default"];
}

- (void)sbsWritePref:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if ([key isEqualToString:@"sbsAboutVersion"]) return;   // 只读
    SBSPrefSet(key, value);
}

// ── 恢复默认值 ──
- (void)sbsResetDefaults:(PSSpecifier *)specifier {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"恢复默认值"
                         message:@"将删除当前全部配置并恢复默认，此操作不可撤销。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"恢复"
                                           style:UIAlertActionStyleDestructive
                                         handler:^(__unused UIAlertAction *a) {
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *p in SBSPrefsPaths()) [fm removeItemAtPath:p error:NULL];
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR(NOTIFY_RELOAD), NULL, NULL, YES);
        [weakSelf reloadSpecifiers];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

// ── 重启桌面（部分改动需要重建 hook 才彻底生效）──
- (void)sbsRespring:(PSSpecifier *)specifier {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"重启桌面"
                         message:@"将重启 SpringBoard（屏幕会短暂黑一下），是否继续？"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"重启"
                                           style:UIAlertActionStyleDestructive
                                         handler:^(__unused UIAlertAction *a) {
        [self sbsRunTool:@"/usr/bin/sbreload"];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)sbsRunTool:(NSString *)path {
    pid_t pid = 0;
    const char *cpath = path.UTF8String;
    char *argv[] = { (char *)cpath, NULL };
    int rc = posix_spawn(&pid, cpath, NULL, NULL, argv, environ);
    if (rc != 0) {
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"执行失败"
                             message:[NSString stringWithFormat:@"无法启动 %@（错误码 %d）", path, rc]
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
                                             handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

@end
