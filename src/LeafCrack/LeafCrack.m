// LeafCrack —— Leaf VPN 会员解锁
// 目标: com.kitslabs.production.Leaf (Leaf 1.19 build 37)
// 平台: iOS 16.5.1 / arm64e / RootHide (relaxin) + ElleKit
//
// 原理:
//   1. NSUserDefaults 写入会员标记，并 swizzle set*:forKey: 让写入值被强制覆盖
//   2. RevenueCat 权益类 isActive / active 恒返回 YES
//   3. 后台巡检，标记被改回来立刻重写
//
// 注意: 不要碰 LEAF_ENC_IS_USING_GO_PREMIUM_CONFIG。
//       会员激活后 Leaf 会用它拉云端 premium 节点配置（LEAF_ENC_UPDATED_GO_PREMIUM_CONF），
//       强行置 0 会让 App 退回本地配置，隧道能起但没有可用节点（表现为只能直连）。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define LC_VERSION   @"1.2.1"
#define GROUP_ID     @"group.com.kitslabs.production.Leaf"

static void lc_log(NSString *fmt, ...) {
    va_list a;
    va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSLog(@"[LeafCrack] %@", s);
}


// 保证 DEFAULT_CONFIG_KEY 指向一个有效文件。
// Leaf 起隧道前会读这个键；键缺失或指向不存在的文件时，点 GO 会静默失败
// （界面停在 Ready to Connect，LeafTunnel 不会启动）。
// 云端节点配置走 LEAF_ENC_UPDATED_GO_PREMIUM_CONF，与这个本地文件互不影响。
static void lc_ensure_config(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *grp = [fm containerURLForSecurityApplicationGroupIdentifier:GROUP_ID];
    if (!grp) {
        lc_log(@"拿不到 AppGroup 容器");
        return;
    }

    NSString *dir = [grp.path stringByAppendingPathComponent:@"Leaf/conf"];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *path = [dir stringByAppendingPathComponent:@"leafcrack.conf"];
    if (![fm fileExistsAtPath:path]) {
        NSString *body =
            @"[General]\n"
             "dns-server = 1.1.1.1, 223.5.5.5\n"
             "\n"
             "[Proxy]\n"
             "Direct = direct\n"
             "Reject = reject\n"
             "\n"
             "[Rule]\n"
             "FINAL, Direct\n";
        [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        lc_log(@"created %@", path);
    }

    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GROUP_ID];
    NSString *want = [@"file://" stringByAppendingString:path];
    NSString *cur = [d stringForKey:@"LEAF_ENC_DEFAULT_CONFIG_KEY"];
    if (!cur || ![cur isEqualToString:want]) {
        [d setObject:want forKey:@"LEAF_ENC_DEFAULT_CONFIG_KEY"];
        [d synchronize];
        lc_log(@"DEFAULT_CONFIG_KEY -> %@", want);
    }
}

// 写入会员标记
static void lc_force(void) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GROUP_ID];
    if (!d) {
        lc_log(@"拿不到 suite %@", GROUP_ID);
        return;
    }

    [d setBool:YES forKey:@"LEAF_ENC_IS_PREMIUM_ACTIVATED"];
    [d setInteger:2147483647 forKey:@"TOTAL_POINTS"];
    [d setDouble:4102444800.0 forKey:@"LAST_DEDUCT_TIME"];   // 2100-01-01
    [d setBool:NO forKey:@"IS_VPN_SHARE_ENABLED"];
    [d synchronize];

    lc_log(@"forced premium=1 points=%ld",
           (long)[d integerForKey:@"TOTAL_POINTS"]);
}

// 运行时守卫: 谁想把这几个键改回去，都按我们的值写
static void lc_guard(void) {
    Class UD = objc_getClass("NSUserDefaults");
    if (!UD) return;

    SEL selB = @selector(setBool:forKey:);
    Method mB = class_getInstanceMethod(UD, selB);
    if (mB) {
        IMP o = method_getImplementation(mB);
        method_setImplementation(mB, imp_implementationWithBlock(^(id self, BOOL v, NSString *key) {
            if ([key isEqualToString:@"LEAF_ENC_IS_PREMIUM_ACTIVATED"]) v = YES;
            else if ([key isEqualToString:@"IS_VPN_SHARE_ENABLED"])    v = NO;
            ((void (*)(id, SEL, BOOL, id))o)(self, selB, v, key);
        }));
    }

    SEL selI = @selector(setInteger:forKey:);
    Method mI = class_getInstanceMethod(UD, selI);
    if (mI) {
        IMP o = method_getImplementation(mI);
        method_setImplementation(mI, imp_implementationWithBlock(^(id self, NSInteger v, NSString *key) {
            if ([key isEqualToString:@"TOTAL_POINTS"]) v = 2147483647;
            ((void (*)(id, SEL, NSInteger, id))o)(self, selI, v, key);
        }));
    }

    SEL selD = @selector(setDouble:forKey:);
    Method mD = class_getInstanceMethod(UD, selD);
    if (mD) {
        IMP o = method_getImplementation(mD);
        method_setImplementation(mD, imp_implementationWithBlock(^(id self, double v, NSString *key) {
            if ([key isEqualToString:@"LAST_DEDUCT_TIME"] && v < 4102444800.0)
                v = 4102444800.0;
            ((void (*)(id, SEL, double, id))o)(self, selD, v, key);
        }));
    }

    lc_log(@"guard installed");
}

// RevenueCat 权益兜底，让 UI 层直接显示会员
static void lc_rc_hooks(void) {
    Class EI = objc_getClass("RCEntitlementInfo");
    if (EI) {
        SEL sels[] = { @selector(isActive),
                       @selector(isActiveInCurrentEnvironment),
                       @selector(isActiveInAnyEnvironment) };
        for (int i = 0; i < 3; i++) {
            SEL cur = sels[i];
            Method m = class_getInstanceMethod(EI, cur);
            if (!m) continue;
            method_setImplementation(m, imp_implementationWithBlock(^BOOL(id self) {
                return YES;
            }));
        }
        lc_log(@"RCEntitlementInfo hooked");
    }

    Class EIs = objc_getClass("RCEntitlementInfos");
    if (EIs) {
        SEL sels[] = { @selector(active),
                       @selector(activeInCurrentEnvironment),
                       @selector(activeInAnyEnvironment) };
        for (int i = 0; i < 3; i++) {
            SEL cur = sels[i];
            Method m = class_getInstanceMethod(EIs, cur);
            if (!m) continue;
            method_setImplementation(m, imp_implementationWithBlock(^BOOL(id self) {
                return YES;
            }));
        }
        lc_log(@"RCEntitlementInfos hooked");
    }
}

__attribute__((constructor)) static void lc_init(void) {
    @autoreleasepool {
        lc_log(@"v%@ loaded in %@ pid=%d", LC_VERSION,
               [[NSBundle mainBundle] bundleIdentifier], getpid());

        lc_ensure_config();
        lc_guard();
        lc_force();
        lc_rc_hooks();

        // 主线程启动完成后再写一遍，覆盖 App 自己的初始化
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            lc_ensure_config();
            lc_force();
            lc_log(@"post-launch force done");
        });

        // 巡检 10 分钟
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            for (int i = 0; i < 600; i++) {
                [NSThread sleepForTimeInterval:1.0];
                NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:GROUP_ID];
                if (![d boolForKey:@"LEAF_ENC_IS_PREMIUM_ACTIVATED"]) {
                    lc_force();
                }
            }
        });
    }
}
