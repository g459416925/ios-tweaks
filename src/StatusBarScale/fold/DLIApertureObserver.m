#import "DLIApertureObserver.h"
#import "DLISafeKVC.h"
#import "SBDFold.h"

// iOS 16 与 iOS 17+ 的键名不同，两套都认。
static NSString *const DLIFramesKeyLegacy = @"SBSystemApertureFrames";
static NSString *const DLIFramesKey = @"SBSystemApertureFramesKey";
static NSString *const DLIIdentifiersKeyLegacy = @"SBSystemApertureVisibleElementIdentifiers";
static NSString *const DLIIdentifiersKey = @"SBSystemApertureVisibleElementIdentifiersKey";

static NSArray *DLIArrayValue(id value) {
    if ([value isKindOfClass:NSArray.class]) return value;
    if ([value isKindOfClass:NSOrderedSet.class]) return [(NSOrderedSet *)value array];
    if ([value isKindOfClass:NSSet.class]) return [(NSSet *)value allObjects];
    if ([value isKindOfClass:NSValue.class]) return @[ value ];
    return nil;
}

static CGRect DLICGRectOfValue(id value) {
    if (![value isKindOfClass:NSValue.class]) return CGRectNull;
    const char *type = [(NSValue *)value objCType];
    if (!type || strcmp(type, @encode(CGRect)) != 0) return CGRectNull;
    return [(NSValue *)value CGRectValue];
}

// 首帧可能发生在 System Aperture 的 window 尚未挂载时：convertRect:toView:nil 会返回
// 本地坐标（真机实证 island x=-62.67）。用屏幕范围做一次合法性过滤，宁可这一帧不画，
// 也不要把环画到屏幕外。
static BOOL DLIRectLooksLikeScreen(CGRect rect) {
    if (CGRectIsNull(rect) || rect.size.width < 1 || rect.size.height < 1) return NO;
    CGSize screen = UIScreen.mainScreen.bounds.size;
    if (screen.width < 1) return YES;
    return rect.origin.x >= -1 && rect.origin.y >= -1
        && CGRectGetMaxX(rect) <= screen.width + 1 && CGRectGetMaxY(rect) <= screen.height + 1;
}

@implementation DLIApertureObserver {
    NSDictionary *_lastInfo;
    __weak UIViewController *_apertureViewController;
}

- (instancetype)init {
    if ((self = [super init])) {
        _islandFrame = CGRectNull;
        _primaryFrame = CGRectNull;
    }
    return self;
}

- (BOOL)updateFromApertureViewController:(UIViewController *)viewController {
    if (viewController) _apertureViewController = viewController;
    // iOS 17+：布局 hook 之后读缓存的 userInfo。iOS 16 无此 ivar → nil，走通知路径。
    NSDictionary *info = DLISafeValue(viewController, @"_cachedLayoutDidChangeUserInfo");
    return [self updateWithInfo:([info isKindOfClass:NSDictionary.class] ? info : nil) viewController:viewController];
}

- (BOOL)updateFromNotification:(NSNotification *)notification {
    id object = notification.object;
    UIViewController *viewController = [object isKindOfClass:UIViewController.class] ? object : _apertureViewController;
    if (viewController) _apertureViewController = viewController;
    NSDictionary *info = [notification.userInfo isKindOfClass:NSDictionary.class] ? notification.userInfo : nil;
    return [self updateWithInfo:info viewController:viewController];
}

- (BOOL)updateWithInfo:(NSDictionary *)info viewController:(UIViewController *)viewController {
    if (!info && CGRectIsNull(_islandFrame)) return NO;
    // The hook runs on every layout pass; most of them report the same layout again (a
    // small dictionary, cheap to compare).
    if (info && [info isEqual:_lastInfo] && !CGRectIsNull(_islandFrame)) return NO;
    _lastInfo = [info copy];

    // The curtain view always covers the sensor housing, whatever the elements do.
    UIView *curtain = DLISafeValue(viewController, @"_magiciansCurtainView");
    if ([curtain isKindOfClass:UIView.class] && curtain.window) {
        CGRect frame = [curtain convertRect:curtain.bounds toView:nil];
        if (DLIRectLooksLikeScreen(frame)) _islandFrame = frame;
    }

    NSArray *identifiers = DLIArrayValue(info[DLIIdentifiersKey] ?: info[DLIIdentifiersKeyLegacy]);
    NSArray *frames = DLIArrayValue(info[DLIFramesKey] ?: info[DLIFramesKeyLegacy]);
    NSUInteger count = identifiers ? identifiers.count : frames.count;
    _visibleElementCount = count;

    CGRect primary = CGRectNull;
    if (frames.count > 0) primary = DLICGRectOfValue(frames[0]);
    // 同一帧既可能直接是 NSValue(CGRect)，也可能外层再包一层 NSValue。
    if (CGRectIsNull(primary) && [frames[0] isKindOfClass:NSValue.class])
        primary = DLICGRectOfValue([(NSValue *)frames[0] nonretainedObjectValue]);
    _primaryFrame = DLIRectLooksLikeScreen(primary) ? primary : CGRectNull;
    if (CGRectIsNull(_islandFrame) && !CGRectIsNull(_primaryFrame)) _islandFrame = _primaryFrame;

    DLIAperturePhase phase;
    NSInteger orientation = [DLISafeValue(viewController, @"_activeElementInterfaceOrientation") integerValue];
    if (orientation != 0 && orientation != UIInterfaceOrientationPortrait) {
        phase = DLIAperturePhaseLandscape;
    } else if (!CGRectIsNull(_primaryFrame) && !CGRectIsNull(_islandFrame)
               && _primaryFrame.size.height > _islandFrame.size.height + 4) {
        phase = DLIAperturePhaseExpanded;
    } else {
        phase = count >= 2 ? DLIAperturePhaseSplit : DLIAperturePhaseSingle;
    }
    BOOL changed = phase != _phase;
    _phase = phase;
    return changed;
}

@end
