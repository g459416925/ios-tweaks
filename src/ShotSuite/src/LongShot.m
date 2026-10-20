// LongShot.m —— 长截图实现（路线 A：在 App 进程内用 renderInContext 一次性渲染）
//
// 原理（从 BigShotSnapper3Plugin 反汇编实证）：
//   BigShot 并不逐屏截图，它用 CALayer 的 renderInContext: 把整个
//   scrollView 的 layer 树一次性画进 contentSize 大小的离屏画布。
//   证据：导入 UIGraphicsBeginImageContextWithOptions / GetCurrentContext /
//   GetImageFromCurrentImageContext + UIScrollView + UIWebView，选择器含
//   renderInContext: / setBounds: / setContentOffset:，日志含 calculatedHeight。
//
// 流程：
//   1. BFS 找 contentSize 最大且可滚动的主 scrollView
//   2. 滚到底再回顶，触发懒加载内容（不做这步长图会有空白段）
//   3. 临时把 layer.bounds 放大到 contentSize，renderInContext 整层渲染
//   4. 恢复 bounds / contentOffset，PNG 存相册
//
// 触发：Darwin 通知 com.xu.longshot（配合 xnotify 工具自测）
// 日志：/var/mobile/Documents/LongShot.log

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <notify.h>

#define LS_VERSION @"1.0.0"
static NSString *const kLog = @"/var/mobile/Documents/LongShot.log";
static NSString *const kTrigger = @"com.xu.longshot";

static void lslog(NSString *fmt, ...)
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

#pragma mark - 找主 scrollView

static UIScrollView *LSFindMainScrollView(void)
{
    UIWindow *win = nil;
    if ([UIApplication sharedApplication].keyWindow) win = [UIApplication sharedApplication].keyWindow;
    if (!win) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
    }
    if (!win) return nil;

    UIScrollView *best = nil;
    CGFloat bestScore = 0;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:win];
    int guard = 0;

    while (queue.count && guard++ < 20000) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];

        if ([v isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sv = (UIScrollView *)v;
            CGFloat ch = sv.contentSize.height;
            CGFloat bh = sv.bounds.size.height;
            BOOL scrollable = (ch > bh + 1) && sv.bounds.size.width > 100;
            // 排除横向翻页（如轮播、PageViewController）
            BOOL horizontal = (sv.contentSize.width > sv.bounds.size.width * 1.5);
            if (scrollable && !horizontal) {
                CGFloat score = ch * sv.bounds.size.width;
                if (score > bestScore) { bestScore = score; best = sv; }
            }
        }
        if (v.subviews.count) [queue addObjectsFromArray:v.subviews];
    }
    return best;
}

#pragma mark - 长截图

static void LSTakeLongShot(void)
{
    UIScrollView *sv = LSFindMainScrollView();
    if (!sv) { lslog(@"没找到可滚动的主 scrollView"); return; }

    CGFloat W = sv.bounds.size.width;
    CGFloat H = sv.contentSize.height;
    CGFloat screenH = sv.bounds.size.height;
    CGPoint origOffset = sv.contentOffset;
    UIEdgeInsets origInset = sv.contentInset;

    lslog(@"[%@] scrollView=%@  W=%.1f H=%.1f screenH=%.1f offset=%@",
          [[NSProcessInfo processInfo] processName],
          NSStringFromClass([sv class]), W, H, screenH, NSStringFromCGPoint(origOffset));

    // 内存保护：超大页面拒绝（1 张 1000x30000 的图约 120MB）
    const CGFloat kMaxH = 30000;
    if (H > kMaxH) { lslog(@"页面过高 %.0f > %.0f，放弃", H, kMaxH); return; }

    // 1) 滚到底再回顶，触发懒加载（否则长图中间会有空白）
    [sv setContentOffset:CGPointMake(0, MAX(0, H - screenH)) animated:NO];
    [CATransaction flush];
    [NSThread sleepForTimeInterval:0.25];
    [sv setContentOffset:origOffset animated:NO];
    [CATransaction flush];
    [NSThread sleepForTimeInterval:0.25];

    // 2) 临时放大 layer.bounds 到完整内容，整层渲染
    CALayer *layer = sv.layer;
    CGRect oldBounds = layer.bounds;
    CGPoint oldPos = layer.position;

    layer.bounds = CGRectMake(0, 0, W, H);
    layer.position = CGPointMake(W / 2.0, H / 2.0);

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(W, H), NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    BOOL ok = NO;
    @try {
        [layer renderInContext:ctx];
        ok = YES;
    } @catch (NSException *e) {
        lslog(@"renderInContext 异常: %@", e);
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    // 3) 恢复
    layer.bounds = oldBounds;
    layer.position = oldPos;
    sv.contentInset = origInset;
    [sv setContentOffset:origOffset animated:NO];
    [CATransaction flush];

    if (!ok || !img) { lslog(@"渲染失败"); return; }
    lslog(@"[%@] 渲染完成 图片尺寸=%@", [[NSProcessInfo processInfo] processName], NSStringFromCGSize(img.size));

    // 4) 存相册
    UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil);
    lslog(@"已提交保存到相册");
}

#pragma mark - 触发

static void LSNotifyCallback(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *object,
                             CFDictionaryRef userInfo)
{
    // Darwin 通知是广播的，所有注入进程都会收到。
    // 只让"前台 App"响应：排除 SpringBoard（它只有资源库/桌面，没有目标内容），
    // 再要求 applicationState == Active。
    NSString *pname = [[NSProcessInfo processInfo] processName];
    if ([pname isEqualToString:@"SpringBoard"]) return;
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        lslog(@"[%@] 收到触发但非前台，忽略", pname);
        return;
    }
    lslog(@"[%@] 收到触发", pname);
    dispatch_async(dispatch_get_main_queue(), ^{
        LSTakeLongShot();
    });
}

static void LSInit(void);

// ⚠️ 不要用 __attribute__((constructor)) + static：universal 编译下这个构造函数
// 会被链接器丢弃（实测 mod_init_func 段直接消失，dylib 注入了也一行代码不跑）。
// ObjC 的 +load 由运行时保证调用，最可靠。
@interface LSLoader : NSObject @end

@implementation LSLoader
+ (void)load { LSInit(); }
@end

static void LSInit(void)
{
    lslog(@"LongShot %@ 注入 %@", LS_VERSION,
          [[NSProcessInfo processInfo] processName]);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, LSNotifyCallback,
                                    (__bridge CFStringRef)kTrigger,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    lslog(@"已监听 %@", kTrigger);
}
