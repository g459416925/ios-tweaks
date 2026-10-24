// kb440_math.h — ReScaleKB 合并版的纯函数层（不含 UIKit，可在 mac 上单测）
//
// 还原自 ReScaleKB.dylib 三个类方法 hook 的公共函数体（arm64 切片 0x73d0/0x75bc/0x77a8）：
//   width = CGRectInset(screenBounds, padLeft, 0).size.width
//   height = 原实现返回的 height
//
// 合并的 440 修正：竖屏、屏幕 440×956、上游宽度 414 时，宽度钉到 440。

#ifndef KB440_MATH_H
#define KB440_MATH_H

#include <CoreGraphics/CoreGraphics.h>
#include <math.h>

// UIInterfaceOrientation：1=portrait, 2=portraitUpsideDown, 3=landscapeLeft, 4=landscapeRight, 0=unknown
static inline int kb_is_portrait(long o) { return o == 0 || o == 1 || o == 2; }
static inline int kb_is_landscape(long o) { return o == 3 || o == 4; }

#define KB_TARGET_W   440.0
#define KB_TARGET_H   956.0
#define KB_STALE_W    414.0
#define KB_EPS        0.01

static inline int kb_should_apply_440(CGSize screen, long orientation, CGSize original) {
    return kb_is_portrait(orientation)
        && fabs(screen.width  - KB_TARGET_W) < KB_EPS
        && fabs(screen.height - KB_TARGET_H) < KB_EPS
        && fabs(original.width - KB_STALE_W) < KB_EPS;
}

// padLeft 是 UIEdgeInsets 的第 2 个元素（top,left,bottom,right 中的 left）
static inline CGSize kb_corrected_size(CGSize screen, double padLeft, CGSize original,
                                       long orientation) {
    CGFloat width = CGRectInset(CGRectMake(0, 0, screen.width, screen.height), padLeft, 0).size.width;
    if (kb_should_apply_440(screen, orientation, original)) width = screen.width;
    return CGSizeMake(width, original.height);
}

#endif
