#import <UIKit/UIKit.h>

// Reads the System Aperture's own layout report (posted whenever its elements or
// frames change) and reduces it to what the status bar needs.
//
// iOS 版本差异（2026-10-18 真机取证结论）：
//   iOS 17+ : SBSystemApertureViewController -_postLayoutDidChangeNotificationIfNecessary
//             之后可读 ivar `_cachedLayoutDidChangeUserInfo`（键 SBSystemApertureFrames 等）。
//   iOS 16.x: 上述方法与 ivar 均不存在；系统改为发 NSNotification
//             `SBSystemApertureLayoutDidChangeNotification`，userInfo 键为
//             `SBSystemApertureFramesKey` / `SBSystemApertureVisibleElementIdentifiersKey`。
//   本类两条路径都支持，调用方按可用性选择。

typedef NS_ENUM(NSInteger, DLIAperturePhase) {
    DLIAperturePhaseUnknown = 0,
    DLIAperturePhaseSingle,   // idle, one compact element, or suppressed
    DLIAperturePhaseSplit,    // mitosis: two elements, the second as a minimal bubble
    DLIAperturePhaseExpanded, // an element is expanded (alert, long press, custom layout)
    DLIAperturePhaseLandscape,
};

@interface DLIApertureObserver : NSObject
@property (nonatomic, readonly) DLIAperturePhase phase;
@property (nonatomic, readonly) CGRect islandFrame;  // hardware island, screen coordinates
@property (nonatomic, readonly) CGRect primaryFrame; // first element, screen coordinates
@property (nonatomic, readonly) NSUInteger visibleElementCount; // 系统报告的可见元素数
// Returns YES when the phase changed.
- (BOOL)updateFromApertureViewController:(UIViewController *)viewController;
// iOS 16 path: the System Aperture's layout notification.
- (BOOL)updateFromNotification:(NSNotification *)notification;
@end
