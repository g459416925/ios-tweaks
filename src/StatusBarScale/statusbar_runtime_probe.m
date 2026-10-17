#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <unistd.h>

static void SBSProbeTree(UIView *view, UIView *root, int depth, int *hits) {
    if (!view || !root || depth > 30) return;
    NSString *name = NSStringFromClass(view.class);
    BOOL interesting = [name containsString:@"StatusBar"] ||
                       [name containsString:@"Battery"] ||
                       [name containsString:@"Foreground"];
    if (interesting) {
        CGRect rect = [view convertRect:view.bounds toView:root];
        NSLog(@"[SBSRuntimeProbe] tree depth=%d class=%@ super=%@ rootRect=%@ bounds=%@ "
              @"transform=(%.4f,%.4f) hidden=%d alpha=%.2f subviews=%lu ptr=%p",
              depth, name, NSStringFromClass(view.superview.class),
              NSStringFromCGRect(rect), NSStringFromCGRect(view.bounds),
              view.transform.a, view.transform.d, view.hidden, view.alpha,
              (unsigned long)view.subviews.count, view);
        (*hits)++;
    }
    for (UIView *subview in view.subviews)
        SBSProbeTree(subview, root, depth + 1, hits);
}

__attribute__((constructor))
static void SBSRuntimeProbeStart(void) {
    NSLog(@"[SBSRuntimeProbe] ctor pid=%d", getpid());
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            SEL selector = NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:");
            NSArray *windows = nil;
            if ([UIWindow respondsToSelector:selector])
                windows = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(UIWindow.class,
                    selector, YES, NO);
            if (![windows isKindOfClass:NSArray.class])
                windows = UIApplication.sharedApplication.windows ?: @[];
            UIScreen *screen = UIScreen.screens.firstObject;
            NSLog(@"[SBSRuntimeProbe] begin windows=%lu internal=%d screen=%@",
                  (unsigned long)windows.count, [UIWindow respondsToSelector:selector],
                  screen ? NSStringFromCGRect(screen.bounds) : @"nil");
            int hits = 0;
            NSUInteger index = 0;
            for (UIWindow *window in windows) {
                NSLog(@"[SBSRuntimeProbe] window index=%lu class=%@ frame=%@ hidden=%d alpha=%.2f level=%.1f",
                      (unsigned long)index++, NSStringFromClass(window.class),
                      NSStringFromCGRect(window.frame), window.hidden, window.alpha,
                      window.windowLevel);
                SBSProbeTree(window, window, 0, &hits);
            }
            NSLog(@"[SBSRuntimeProbe] end hits=%d", hits);
        } @catch (NSException *exception) {
            NSLog(@"[SBSRuntimeProbe] exception=%@", exception);
        }
    });
}
