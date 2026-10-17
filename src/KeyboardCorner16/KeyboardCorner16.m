#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#define KBC_VERSION "1.0.88"
#define TARGET_RADIUS 10.0

extern void MSHookMessageEx(Class cls, SEL sel, IMP newImp, IMP *oldImp);

static void kbc_log(NSString *line) {
    NSString *full = [NSString stringWithFormat:@"[kbc:%s:%d] %@", KBC_VERSION, getpid(), line];
    NSLog(@"%@", full);
    os_log_error(OS_LOG_DEFAULT, "%{public}s", full.UTF8String);
    FILE *fp = fopen("/var/mobile/Documents/kbc_round.log", "a");
    if (!fp) fp = fopen("/var/tmp/kbc_round.log", "a");
    if (!fp) {
        // App 进程两个绝对路径都会被沙箱拒绝，回落到自己的 tmp 才能取证
        // （抖音等 App 内的问题只能靠这条路径拿到日志）。
        NSString *sandboxPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"kbc_round.log"];
        if (sandboxPath.length) fp = fopen(sandboxPath.fileSystemRepresentation, "a");
    }
    if (fp) { fprintf(fp, "%s\n", full.UTF8String); fclose(fp); }
}

static IMP sOrigDisplayLayer = NULL;
static IMP sOrigKeyDisplayLayer = NULL;
static IMP sOrigLayerForFlags = NULL;
static IMP sOrigPopulateLayer = NULL;
static unsigned int sDisplayCount = 0;
static unsigned int sTransformLogCount = 0;
static char sRoundedImageKey;
static char sRoundedShadowImageKey;
static char sSingleImageStatsKey;
static char sRenderFlagsKey;
static char sKeyComponentRectKey;
static NSMutableSet<NSString *> *sLoggedDirectKeys;
static unsigned int sBackdropLogCount = 0;
static unsigned int sOLEDLogCount = 0;
static unsigned int sUnderDockLogCount = 0;
static unsigned int sKayokoProbeLogCount = 0;
static unsigned int sKayokoListProbeLogCount = 0;
static unsigned int sKayokoBarLogCount = 0;
static unsigned int sKayokoMigrateLogCount = 0;
static unsigned int sKayokoHitLogCount = 0;

// 自绘栏的按钮文案。系统预测栏的 TUIPredictionViewCell 会通过 accessibility
// 把覆盖其上的按钮标签"借"成自己的 label，导致候选检测把我们自己的按钮
// 当成系统候选（真机实测：数字页 cell 的 text 就是 历史/拷贝/粘贴），
// 进而把 bar 隐藏/重新挂载来回抖。检测时必须排除这三个词。
static NSArray<NSString *> *kbc_kayokoBarTitles(void) {
    return @[@"历史", @"拷贝", @"粘贴"];
}

static BOOL kbc_textIsKayokoBarTitle(NSString *text) {
    if (!text.length) return NO;
    return [kbc_kayokoBarTitles() containsObject:text];
}
static unsigned int sKayokoCandidateTreeLogCount = 0;
static unsigned int sKayokoTextChangeLogCount = 0;

// OledKeyboard 0.0.3 arm64e was recovered from its five MSHookMessageEx
// registrations and method bodies. Keep separate originals because several
// classes share layoutSubviews but have different behavior.
static IMP sOrigOLEDKeyboardDisplayLayer = NULL;
static IMP sOrigOLEDPredictionSuggestions = NULL;
static IMP sOrigOLEDDockLayout = NULL;
static IMP sOrigOLEDInputLayout = NULL;
static IMP sOrigOLEDEffectLayout = NULL;

// UnderDock 1.0 arm64e hook originals.
static IMP sOrigDockInitWithFrame = NULL;
static IMP sOrigDockLayoutSubviews = NULL;
static IMP sOrigDockSetLeftItem = NULL;
static IMP sOrigDockSetRightItem = NULL;
static IMP sOrigDockVisibility = NULL;
static IMP sOrigSelectionGestureShouldBegin = NULL;
static IMP sOrigKayokoProbeSetKeyplaneName = NULL;
static IMP sOrigKayokoProbeSetAutocorrectionList = NULL;
static IMP sOrigKayokoPageLayout = NULL;
static IMP sOrigKayokoPageHitTest = NULL;
static IMP sOrigKayokoCandidateCollectionLayout = NULL;
static IMP sOrigKayokoPredictionContentLayout = NULL;
static IMP sOrigKayokoCoreViewLayout = NULL;
static IMP sOrigKayokoCoreViewShow = NULL;
static IMP sOrigKayokoCoreViewHide = NULL;
static NSString *sKayokoProbeKeyplane = nil;
static __weak UIView *sKayokoHostView = nil;
static BOOL sKayokoHasSystemCandidates = NO;
static BOOL sKayokoPageHookInstalled = NO;
static BOOL sKayokoCandidateCollectionHookInstalled = NO;
static BOOL sKayokoPredictionContentHookInstalled = NO;
static BOOL sKayokoCoreViewHooksInstalled = NO;
static char sUnderDockViewKey;
@class KBCKayokoPredictionBar;
static char sKayokoPredictionBarKey;
static KBCKayokoPredictionBar *sSharedKayokoBar = nil;
static char sKayokoPredictionTapKey;
static char sKayokoUpdateScheduledKey;
static char sKayokoOriginalBoundsKey;
static char sKayokoOriginalSuperviewKey;
static char sKayokoLandscapeHostKey;
static char sKayokoLandscapeAnimatingKey;
static unsigned int sKayokoCoreOrientationLogCount = 0;

static NSString *kbc_kayokoListSummary(id list);
static BOOL kbc_activateKayoko(id sender);
static BOOL kbc_sendAction(id target, const char *name);
static void kbc_kayokoPageLayout(id self, SEL command);
static id kbc_kayokoPageHitTest(id self, SEL command, CGPoint point, UIEvent *event);
static void kbc_installKayokoTextDiagnostics(void);
static void kbc_updateKayokoPage(UIView *page, NSString *reason);
static void kbc_installKayokoCoreOrientationDiagnostics(void);
static void kbc_installKayokoCoreViewHooks(NSString *source);

typedef struct {
    size_t minX, minY, maxX, maxY, area;
} KBCComponent;

typedef struct {
    size_t imageWidth, imageHeight;
    size_t componentMinX, componentMinY;
    size_t componentWidth, componentHeight, componentArea;
    double widthRatio, heightRatio, fillRatio;
    BOOL eligible;
    BOOL shadowEligible;
} KBCSingleImageStats;

static BOOL kbc_outsideRoundedRect(size_t x, size_t y, KBCComponent box, double radius) {
    double px = (double)x + 0.5;
    double py = (double)y + 0.5;
    double left = (double)box.minX;
    double right = (double)box.maxX + 1.0;
    double top = (double)box.minY;
    double bottom = (double)box.maxY + 1.0;
    double cx = px < left + radius ? left + radius : (px > right - radius ? right - radius : px);
    double cy = py < top + radius ? top + radius : (py > bottom - radius ? bottom - radius : py);
    double dx = px - cx;
    double dy = py - cy;
    return dx * dx + dy * dy > radius * radius;
}

// The 1.0.38 evidence dump proved that the second UIKBSplitImageView image is
// the final grayscale+alpha key-background atlas. Normalize to RGBA, identify
// only key-sized connected alpha components, and remove pixels outside a 10pt
// rounded rectangle. Labels and the shadow atlas are separate images.
static UIImage *kbc_roundedCompositeImage(UIImage *image, NSUInteger *roundedKeys) {
    if (roundedKeys) *roundedKeys = 0;
    if (!image.CGImage) return image;

    UIImage *cached = objc_getAssociatedObject(image, &sRoundedImageKey);
    if (cached) return cached;

    CGImageRef source = image.CGImage;
    size_t width = CGImageGetWidth(source);
    size_t height = CGImageGetHeight(source);
    if (width == 0 || height == 0 || width > 4096 || height > 4096) return image;

    size_t pixelCount = width * height;
    uint8_t *pixels = calloc(pixelCount, 4);
    uint8_t *visited = calloc(pixelCount, 1);
    size_t *queue = malloc(pixelCount * sizeof(size_t));
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = pixels && colorSpace
        ? CGBitmapContextCreate(pixels, width, height, 8, width * 4, colorSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
    if (!pixels || !visited || !queue || !context) {
        if (context) CGContextRelease(context);
        if (colorSpace) CGColorSpaceRelease(colorSpace);
        free(queue); free(visited); free(pixels);
        return image;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), source);

    double scale = image.scale > 0.0 ? image.scale : 1.0;
    size_t minWidth = (size_t)(25.0 * scale);
    size_t minHeight = (size_t)(30.0 * scale);
    double radius = TARGET_RADIUS * scale;
    NSUInteger componentCount = 0;

    for (size_t start = 0; start < pixelCount; start++) {
        if (visited[start] || pixels[start * 4 + 3] <= 8) continue;
        size_t head = 0, tail = 0;
        queue[tail++] = start;
        visited[start] = 1;
        KBCComponent box = {start % width, start / width, start % width, start / width, 0};
        while (head < tail) {
            size_t index = queue[head++];
            size_t x = index % width, y = index / width;
            box.area++;
            if (x < box.minX) box.minX = x;
            if (x > box.maxX) box.maxX = x;
            if (y < box.minY) box.minY = y;
            if (y > box.maxY) box.maxY = y;
            size_t neighbors[4] = {
                x ? index - 1 : index,
                x + 1 < width ? index + 1 : index,
                y ? index - width : index,
                y + 1 < height ? index + width : index
            };
            for (NSUInteger n = 0; n < 4; n++) {
                size_t next = neighbors[n];
                if (next == index || visited[next] || pixels[next * 4 + 3] <= 8) continue;
                visited[next] = 1;
                queue[tail++] = next;
            }
        }

        size_t boxWidth = box.maxX - box.minX + 1;
        size_t boxHeight = box.maxY - box.minY + 1;
        if (boxWidth < minWidth || boxHeight < minHeight) continue;
        componentCount++;
        for (size_t y = box.minY; y <= box.maxY; y++) {
            for (size_t x = box.minX; x <= box.maxX; x++) {
                size_t offset = (y * width + x) * 4;
                if (pixels[offset + 3] && kbc_outsideRoundedRect(x, y, box, radius)) {
                    pixels[offset] = pixels[offset + 1] = pixels[offset + 2] = pixels[offset + 3] = 0;
                }
            }
        }
    }

    UIImage *result = image;
    // The label/shadow atlas has no key-sized filled components. Rebuild only
    // an atlas that contains at least ten actual key backgrounds.
    if (componentCount >= 10) {
        CGImageRef output = CGBitmapContextCreateImage(context);
        if (output) {
            UIImage *rebuilt = [UIImage imageWithCGImage:output scale:scale orientation:image.imageOrientation];
            result = [rebuilt imageWithRenderingMode:image.renderingMode];
            CGImageRelease(output);
            if (roundedKeys) *roundedKeys = componentCount;
            unsigned int logIndex = __sync_fetch_and_add(&sTransformLogCount, 1);
            if (logIndex < 8) {
                kbc_log([NSString stringWithFormat:
                    @"transform idx=%u size=%zux%zu scale=%.1f components=%lu inputMode=%ld outputMode=%ld",
                    logIndex, width, height, scale, (unsigned long)componentCount,
                    (long)image.renderingMode, (long)result.renderingMode]);
            }
        }
    }

    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    free(queue); free(visited); free(pixels);
    if (result == image) {
        objc_setAssociatedObject(image, &sRoundedImageKey, image, OBJC_ASSOCIATION_ASSIGN);
    } else {
        objc_setAssociatedObject(image, &sRoundedImageKey, result, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(result, &sRoundedImageKey, result, OBJC_ASSOCIATION_ASSIGN);
    }
    return result;
}

// The label atlas also contains one separate U-shaped bottom-shadow component
// per composite key. Evidence dumps show those components are 19 px high at
// 3x, at least one key wide, and sparse (~0.17 fill); labels do not match that
// geometry. The 1.0.50 screen measurement then proved that rounding these
// components leaves a dark center run at y+h-3 on all 32 keys. Remove only
// pixels belonging to each classified shadow component; glyph components are
// separate connected components and remain untouched.
static UIImage *kbc_removedCompositeShadowImage(UIImage *image, NSUInteger *removedShadows) {
    if (removedShadows) *removedShadows = 0;
    if (!image.CGImage) return image;

    UIImage *cached = objc_getAssociatedObject(image, &sRoundedShadowImageKey);
    if (cached) return cached;

    CGImageRef source = image.CGImage;
    size_t width = CGImageGetWidth(source), height = CGImageGetHeight(source);
    if (width == 0 || height == 0 || width > 4096 || height > 4096) return image;

    size_t pixelCount = width * height;
    uint8_t *pixels = calloc(pixelCount, 4);
    uint8_t *visited = calloc(pixelCount, 1);
    size_t *queue = malloc(pixelCount * sizeof(size_t));
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = pixels && colorSpace
        ? CGBitmapContextCreate(pixels, width, height, 8, width * 4, colorSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
    if (!pixels || !visited || !queue || !context) {
        if (context) CGContextRelease(context);
        if (colorSpace) CGColorSpaceRelease(colorSpace);
        free(queue); free(visited); free(pixels);
        return image;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), source);

    double scale = image.scale > 0.0 ? image.scale : 1.0;
    size_t minWidth = (size_t)(25.0 * scale);
    size_t minHeight = (size_t)(4.0 * scale);
    size_t maxHeight = (size_t)(8.0 * scale);
    NSUInteger componentCount = 0;

    for (size_t start = 0; start < pixelCount; start++) {
        if (visited[start] || pixels[start * 4 + 3] <= 8) continue;
        size_t head = 0, tail = 0;
        queue[tail++] = start;
        visited[start] = 1;
        KBCComponent component = {start % width, start / width, start % width, start / width, 0};
        while (head < tail) {
            size_t index = queue[head++];
            size_t x = index % width, y = index / width;
            component.area++;
            if (x < component.minX) component.minX = x;
            if (x > component.maxX) component.maxX = x;
            if (y < component.minY) component.minY = y;
            if (y > component.maxY) component.maxY = y;
            size_t neighbors[4] = {
                x ? index - 1 : index,
                x + 1 < width ? index + 1 : index,
                y ? index - width : index,
                y + 1 < height ? index + width : index
            };
            for (NSUInteger n = 0; n < 4; n++) {
                size_t next = neighbors[n];
                if (next == index || visited[next] || pixels[next * 4 + 3] <= 8) continue;
                visited[next] = 1;
                queue[tail++] = next;
            }
        }

        size_t boxWidth = component.maxX - component.minX + 1;
        size_t boxHeight = component.maxY - component.minY + 1;
        double fill = (double)component.area / (double)(boxWidth * boxHeight);
        if (boxWidth < minWidth || boxHeight < minHeight || boxHeight > maxHeight || fill > 0.35)
            continue;

        componentCount++;
        for (size_t i = 0; i < tail; i++) {
            size_t offset = queue[i] * 4;
            pixels[offset] = pixels[offset + 1] = pixels[offset + 2] = pixels[offset + 3] = 0;
        }
    }

    UIImage *result = image;
    if (componentCount >= 10) {
        CGImageRef output = CGBitmapContextCreateImage(context);
        if (output) {
            UIImage *rebuilt = [UIImage imageWithCGImage:output scale:scale orientation:image.imageOrientation];
            result = [rebuilt imageWithRenderingMode:image.renderingMode];
            CGImageRelease(output);
            if (removedShadows) *removedShadows = componentCount;
        }
    }

    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    free(queue); free(visited); free(pixels);
    if (result == image) {
        objc_setAssociatedObject(image, &sRoundedShadowImageKey, image, OBJC_ASSOCIATION_ASSIGN);
    } else {
        objc_setAssociatedObject(image, &sRoundedShadowImageKey, result, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(result, &sRoundedShadowImageKey, result, OBJC_ASSOCIATION_ASSIGN);
    }
    return result;
}

// A direct UIKBKeyView is populated from several separate images. Runtime
// dumps prove that one image is a nearly full-size, solid alpha keycap, while
// the other images contain only the bottom shadow or the label. Classify every
// image from its own pixels instead of relying on a fixed render flag or key
// name, then round the full-size background or remove the sparse bottom-shadow
// component whose retained center produced the measured black line.
static void kbc_analyzeSingleKeyImage(UIImage *image, KBCSingleImageStats *outStats) {
    KBCSingleImageStats empty = {0};
    if (outStats) *outStats = empty;
    if (!image.CGImage) return;

    NSValue *cachedStats = objc_getAssociatedObject(image, &sSingleImageStatsKey);
    if (cachedStats) {
        if (outStats) [cachedStats getValue:outStats];
        return;
    }

    CGImageRef source = image.CGImage;
    size_t width = CGImageGetWidth(source);
    size_t height = CGImageGetHeight(source);
    if (width == 0 || height == 0 || width > 2048 || height > 2048) return;

    size_t pixelCount = width * height;
    uint8_t *pixels = calloc(pixelCount, 4);
    uint8_t *visited = calloc(pixelCount, 1);
    size_t *queue = malloc(pixelCount * sizeof(size_t));
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = pixels && colorSpace
        ? CGBitmapContextCreate(pixels, width, height, 8, width * 4, colorSpace,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
    if (!pixels || !visited || !queue || !context) {
        if (context) CGContextRelease(context);
        if (colorSpace) CGColorSpaceRelease(colorSpace);
        free(queue); free(visited); free(pixels);
        return;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), source);

    KBCComponent largest = {0};
    for (size_t start = 0; start < pixelCount; start++) {
        if (visited[start] || pixels[start * 4 + 3] <= 8) continue;
        size_t head = 0, tail = 0;
        queue[tail++] = start;
        visited[start] = 1;
        KBCComponent box = {start % width, start / width, start % width, start / width, 0};
        while (head < tail) {
            size_t index = queue[head++];
            size_t x = index % width, y = index / width;
            box.area++;
            if (x < box.minX) box.minX = x;
            if (x > box.maxX) box.maxX = x;
            if (y < box.minY) box.minY = y;
            if (y > box.maxY) box.maxY = y;
            size_t neighbors[4] = {
                x ? index - 1 : index,
                x + 1 < width ? index + 1 : index,
                y ? index - width : index,
                y + 1 < height ? index + width : index
            };
            for (NSUInteger n = 0; n < 4; n++) {
                size_t next = neighbors[n];
                if (next == index || visited[next] || pixels[next * 4 + 3] <= 8) continue;
                visited[next] = 1;
                queue[tail++] = next;
            }
        }
        if (box.area > largest.area) largest = box;
    }

    KBCSingleImageStats stats = {0};
    stats.imageWidth = width;
    stats.imageHeight = height;
    if (largest.area) {
        stats.componentMinX = largest.minX;
        stats.componentMinY = largest.minY;
        stats.componentWidth = largest.maxX - largest.minX + 1;
        stats.componentHeight = largest.maxY - largest.minY + 1;
        stats.componentArea = largest.area;
        stats.widthRatio = (double)stats.componentWidth / (double)width;
        stats.heightRatio = (double)stats.componentHeight / (double)height;
        stats.fillRatio = (double)stats.componentArea /
            (double)(stats.componentWidth * stats.componentHeight);
        stats.eligible = stats.widthRatio >= 0.60 && stats.heightRatio >= 0.60 &&
            stats.fillRatio >= 0.55;
        stats.shadowEligible = stats.widthRatio >= 0.60 &&
            stats.heightRatio >= 0.05 && stats.heightRatio <= 0.30 &&
            stats.fillRatio <= 0.35;
    }

    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    free(queue); free(visited); free(pixels);

    NSValue *statsValue = [NSValue valueWithBytes:&stats objCType:@encode(KBCSingleImageStats)];
    objc_setAssociatedObject(image, &sSingleImageStatsKey, statsValue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (outStats) *outStats = stats;
}

// Run after UIKit has consumed the original UIKBCachedImage. This preserves
// the private image class path and all tint/compositing properties configured
// by _populateLayer:, changing only the alpha corners of the final backing.
static CGImageRef kbc_createRoundedBacking(CGImageRef source, CGFloat scale,
                                            KBCSingleImageStats stats) {
    if (!source || (!stats.eligible && !stats.shadowEligible)) return NULL;
    size_t width = CGImageGetWidth(source), height = CGImageGetHeight(source);
    if (width != stats.imageWidth || height != stats.imageHeight) return NULL;
    size_t bitsPerComponent = CGImageGetBitsPerComponent(source);
    size_t bitsPerPixel = CGImageGetBitsPerPixel(source);
    CGColorSpaceRef sourceColorSpace = CGImageGetColorSpace(source);
    CGImageAlphaInfo alphaInfo = CGImageGetAlphaInfo(source);
    BOOL mask8 = bitsPerComponent == 8 && bitsPerPixel == 8 && sourceColorSpace == NULL;
    BOOL grayAlpha16 = bitsPerComponent == 8 && bitsPerPixel == 16 && sourceColorSpace &&
        CGColorSpaceGetModel(sourceColorSpace) == kCGColorSpaceModelMonochrome &&
        alphaInfo == kCGImageAlphaPremultipliedLast;
    if (!mask8 && !grayAlpha16) return NULL;

    size_t rowBytes = CGImageGetBytesPerRow(source);
    CGDataProviderRef sourceProvider = CGImageGetDataProvider(source);
    CFDataRef sourceData = sourceProvider ? CGDataProviderCopyData(sourceProvider) : NULL;
    CFMutableDataRef mutableData = sourceData
        ? CFDataCreateMutableCopy(kCFAllocatorDefault, 0, sourceData) : NULL;
    if (sourceData) CFRelease(sourceData);
    if (!mutableData || (size_t)CFDataGetLength(mutableData) < rowBytes * height) {
        if (mutableData) CFRelease(mutableData);
        return NULL;
    }
    UInt8 *pixels = CFDataGetMutableBytePtr(mutableData);

    KBCComponent box = {stats.componentMinX, stats.componentMinY,
        stats.componentMinX + stats.componentWidth - 1,
        stats.componentMinY + stats.componentHeight - 1, stats.componentArea};
    double radius = TARGET_RADIUS * (scale > 0.0 ? scale : 1.0);
    for (size_t y = box.minY; y <= box.maxY; y++) {
        for (size_t x = box.minX; x <= box.maxX; x++) {
            size_t offset = y * rowBytes + x * (grayAlpha16 ? 2 : 1);
            if (stats.shadowEligible) {
                // Runtime evidence identifies this backing as the dedicated
                // flag=2 shadow mask; its glyph/background use other images.
                pixels[offset] = 0;
                if (grayAlpha16) pixels[offset + 1] = 0;
            } else if ((grayAlpha16 ? pixels[offset + 1] : pixels[offset]) &&
                       kbc_outsideRoundedRect(x, y, box, radius)) {
                pixels[offset] = 0;
                if (grayAlpha16) pixels[offset + 1] = 0;
            }
        }
    }

    CGDataProviderRef outputProvider = CGDataProviderCreateWithCFData(mutableData);
    CGImageRef output = NULL;
    if (outputProvider && mask8) {
        output = CGImageMaskCreate(width, height, 8, 8, rowBytes, outputProvider,
            CGImageGetDecode(source), CGImageGetShouldInterpolate(source));
    } else if (outputProvider && grayAlpha16) {
        output = CGImageCreate(width, height, 8, 16, rowBytes, sourceColorSpace,
            CGImageGetBitmapInfo(source), outputProvider, CGImageGetDecode(source),
            CGImageGetShouldInterpolate(source), CGImageGetRenderingIntent(source));
    }
    if (outputProvider) CGDataProviderRelease(outputProvider);
    CFRelease(mutableData);
    return output;
}

static id kbc_objectGetter(id object, const char *name) {
    SEL selector = sel_registerName(name);
    return object && [object respondsToSelector:selector]
        ? ((id(*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static NSString *kbc_layerContentsSummary(CALayer *layer) {
    if (!layer.contents) return @"nil";
    CFTypeRef object = (__bridge CFTypeRef)layer.contents;
    if (CFGetTypeID(object) != CGImageGetTypeID())
        return NSStringFromClass([layer.contents class]) ?: @"non-image";
    CGImageRef image = (CGImageRef)object;
    CGColorSpaceRef colorSpace = CGImageGetColorSpace(image);
    CGColorSpaceModel model = colorSpace ? CGColorSpaceGetModel(colorSpace) : kCGColorSpaceModelUnknown;
    return [NSString stringWithFormat:
        @"cg:%zux%zu bpc=%zu bpp=%zu row=%zu alpha=%u bitmap=0x%lx cs=%@/%ld",
        CGImageGetWidth(image), CGImageGetHeight(image), CGImageGetBitsPerComponent(image),
        CGImageGetBitsPerPixel(image), CGImageGetBytesPerRow(image),
        (unsigned int)CGImageGetAlphaInfo(image), (unsigned long)CGImageGetBitmapInfo(image),
        colorSpace ? @"yes" : @"mask", (long)model];
}

static void kbc_maskBackdropChildren(CALayer *container, CGRect componentRect) {
    if (!container || CGRectIsEmpty(componentRect)) return;
    for (CALayer *child in container.sublayers) {
        if (![child.delegate isKindOfClass:objc_getClass("UIKBBackdropView")]) continue;
        double widthRatio = container.bounds.size.width > 0.0
            ? child.bounds.size.width / container.bounds.size.width : 0.0;
        double heightRatio = container.bounds.size.height > 0.0
            ? child.bounds.size.height / container.bounds.size.height : 0.0;
        if (widthRatio < 0.90 || heightRatio < 0.90) continue;

        CGRect maskRect = CGRectIntersection(child.bounds, componentRect);
        if (CGRectIsEmpty(maskRect)) continue;
        CAShapeLayer *shapeMask = [CAShapeLayer layer];
        shapeMask.frame = child.bounds;
        shapeMask.contentsScale = UIScreen.mainScreen.scale;
        CGPathRef maskPath = CGPathCreateWithRoundedRect(maskRect, TARGET_RADIUS,
            TARGET_RADIUS, NULL);
        shapeMask.path = maskPath;
        CGPathRelease(maskPath);
        shapeMask.fillColor = UIColor.blackColor.CGColor;
        child.cornerRadius = 0.0;
        child.masksToBounds = NO;
        child.mask = shapeMask;
        unsigned int sequence = __sync_fetch_and_add(&sBackdropLogCount, 1);
        if (sequence < 8) {
            id keyView = [container.delegate isKindOfClass:objc_getClass("UIKBKeyView")]
                ? container.delegate : nil;
            id key = kbc_objectGetter(keyView, "key");
            NSString *name = kbc_objectGetter(key, "name") ?: @"unknown";
            kbc_log([NSString stringWithFormat:
                @"transition-backdrop seq=%u key=%@ delegate=%@ bounds=(%.3f,%.3f) ratios=%.3f/%.3f componentRect=(%.3f,%.3f,%.3f,%.3f) insetsTRBL=(%.3f,%.3f,%.3f,%.3f) action=component-mask radius=%.1f",
                sequence, name, NSStringFromClass([child.delegate class]),
                child.bounds.size.width, child.bounds.size.height, widthRatio, heightRatio,
                maskRect.origin.x, maskRect.origin.y, maskRect.size.width,
                maskRect.size.height, CGRectGetMinY(maskRect),
                child.bounds.size.width - CGRectGetMaxX(maskRect),
                child.bounds.size.height - CGRectGetMaxY(maskRect),
                CGRectGetMinX(maskRect), TARGET_RADIUS]);
        }
    }
}

static void kbc_keyDisplayLayer(id self, SEL command, CALayer *layer) {
    if (sOrigKeyDisplayLayer)
        ((void(*)(id, SEL, id))sOrigKeyDisplayLayer)(self, command, layer);
    if (!layer) return;

    NSValue *componentValue = objc_getAssociatedObject(self, &sKeyComponentRectKey);
    if (!componentValue) return;
    CGRect componentRect = componentValue.CGRectValue;
    kbc_maskBackdropChildren(layer, componentRect);
    CALayer *ancestor = layer.superlayer;
    for (NSUInteger depth = 0; depth < 3 && ancestor; depth++) {
        if (![ancestor.delegate isKindOfClass:objc_getClass("UIKBKeyView")]) break;
        kbc_maskBackdropChildren(ancestor, componentRect);
        ancestor = ancestor.superlayer;
    }
}

static id kbc_layerForRenderFlags(id self, SEL command, NSInteger flags) {
    id layer = sOrigLayerForFlags
        ? ((id(*)(id, SEL, NSInteger))sOrigLayerForFlags)(self, command, flags) : nil;
    if (layer)
        objc_setAssociatedObject(layer, &sRenderFlagsKey, @(flags), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return layer;
}

static void kbc_populateLayer(id self, SEL command, CALayer *layer, id contents) {
    NSNumber *flags = objc_getAssociatedObject(layer, &sRenderFlagsKey);
    id key = kbc_objectGetter(self, "key");
    NSString *name = kbc_objectGetter(key, "name") ?: @"unknown";
    UIImage *image = [contents isKindOfClass:[UIImage class]] ? (UIImage *)contents : nil;
    KBCSingleImageStats stats = {0};
    if (image) kbc_analyzeSingleKeyImage(image, &stats);

    if (sOrigPopulateLayer)
        ((void(*)(id, SEL, id, id))sOrigPopulateLayer)(self, command, layer, contents);

    if (stats.eligible && image.scale > 0.0 && (!flags || flags.integerValue == 1)) {
        CGRect componentRect = CGRectMake(
            (CGFloat)stats.componentMinX / image.scale,
            (CGFloat)stats.componentMinY / image.scale,
            (CGFloat)stats.componentWidth / image.scale,
            (CGFloat)stats.componentHeight / image.scale);
        objc_setAssociatedObject(self, &sKeyComponentRectKey,
            [NSValue valueWithCGRect:componentRect], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    BOOL transformed = NO;
    if (layer.contents) {
        CFTypeRef backingObject = (__bridge CFTypeRef)layer.contents;
        if (CFGetTypeID(backingObject) == CGImageGetTypeID()) {
            CGImageRef backing = (CGImageRef)backingObject;
            if (stats.eligible || stats.shadowEligible) {
                CGImageRef roundedBacking = kbc_createRoundedBacking(backing, image.scale, stats);
                if (roundedBacking) {
                    layer.contents = (__bridge id)roundedBacking;
                    CGImageRelease(roundedBacking);
                    transformed = YES;
                }
            }
        }
    }

    if (transformed && flags) {
        @synchronized ([NSObject class]) {
            if (!sLoggedDirectKeys) sLoggedDirectKeys = [NSMutableSet set];
            NSString *kind = stats.shadowEligible ? @"shadow" : @"background";
            NSString *identity = [NSString stringWithFormat:@"%@/%@", name, kind];
            if (![sLoggedDirectKeys containsObject:identity] && sLoggedDirectKeys.count < 64) {
                [sLoggedDirectKeys addObject:identity];
                kbc_log([NSString stringWithFormat:
                    @"direct-backing key=%@ flags=%@ kind=%@ action=%@ pixels=%zux%zu component=%zux%zu ratios=%.3f/%.3f/%.3f radius=%.1f format=%@",
                    name, flags, kind, stats.shadowEligible ? @"removed" : @"rounded",
                    stats.imageWidth, stats.imageHeight,
                    stats.componentWidth, stats.componentHeight, stats.widthRatio,
                    stats.heightRatio, stats.fillRatio, TARGET_RADIUS,
                    kbc_layerContentsSummary(layer)]);
            }
        }
    }

}

static void kbc_displayLayer(id self, SEL command, CALayer *layer) {
    if (sOrigDisplayLayer)
        ((void(*)(id, SEL, id))sOrigDisplayLayer)(self, command, layer);
    if (!layer) return;

    NSArray<CALayer *> *sublayers = layer.sublayers;
    NSUInteger compositeKeys = 0;
    NSUInteger compositeShadows = 0;
    NSUInteger changedAtlases = 0;
    NSUInteger directKeys = 0;

    for (NSUInteger index = 0; index < sublayers.count; index++) {
        CALayer *direct = sublayers[index];
        id delegate = direct.delegate;
        if ([delegate isKindOfClass:objc_getClass("UIKBSplitImageView")]) {
            // 1.0.38 dumps proved index 1 is the filled key-background atlas;
            // index 0 is empty/backdrop and index 2 contains labels/shadows.
            if (index != 1 && index != 2) continue;
            CALayer *imageLayer = direct.sublayers.firstObject;
            UIImageView *imageView = [imageLayer.delegate isKindOfClass:[UIImageView class]]
                ? (UIImageView *)imageLayer.delegate : nil;
            UIImage *original = imageView.image;
            NSUInteger keys = 0, shadows = 0;
            UIImage *rounded = index == 1
                ? kbc_roundedCompositeImage(original, &keys)
                : kbc_removedCompositeShadowImage(original, &shadows);
            if (rounded != original) {
                imageView.image = rounded;
                compositeKeys += keys;
                compositeShadows += shadows;
                changedAtlases++;
            }
            continue;
        }

        if ([delegate isKindOfClass:objc_getClass("UIKBKeyView")]) {
            CGSize size = direct.bounds.size;
            if (size.width >= 25.0 && size.height >= 30.0) {
                directKeys++;
            }
        }
    }

    unsigned int sequence = __sync_fetch_and_add(&sDisplayCount, 1);
    if (sequence < 12) {
        id keyplane = [self respondsToSelector:sel_registerName("keyplane")]
            ? ((id(*)(id, SEL))objc_msgSend)(self, sel_registerName("keyplane")) : nil;
        NSString *name = [keyplane respondsToSelector:sel_registerName("name")]
            ? ((id(*)(id, SEL))objc_msgSend)(keyplane, sel_registerName("name")) : @"unknown";
        kbc_log([NSString stringWithFormat:
            @"apply seq=%u plane=%@ sublayers=%lu changedAtlases=%lu compositeKeys=%lu compositeShadowsRemoved=%lu directKeys=%lu radius=%.1f",
            sequence, name ?: @"unknown", (unsigned long)sublayers.count,
            (unsigned long)changedAtlases, (unsigned long)compositeKeys,
            (unsigned long)compositeShadows, (unsigned long)directKeys, TARGET_RADIUS]);
    }
}

#pragma mark - OledKeyboard integration (binary-verified behavior)

static BOOL kbc_isDarkKeyboardObject(id object) {
    if (!object) return NO;
    SEL mapKitDark = sel_registerName("_mapkit_isDarkModeEnabled");
    if ([object respondsToSelector:mapKitDark])
        return ((BOOL(*)(id, SEL))objc_msgSend)(object, mapKitDark);

    SEL ancestorSelector = sel_registerName("_viewControllerForAncestor");
    id controller = [object respondsToSelector:ancestorSelector]
        ? ((id(*)(id, SEL))objc_msgSend)(object, ancestorSelector) : nil;
    UITraitCollection *traits = [controller respondsToSelector:@selector(traitCollection)]
        ? ((id(*)(id, SEL))objc_msgSend)(controller, @selector(traitCollection)) : nil;
    return traits.userInterfaceStyle == UIUserInterfaceStyleDark;
}

static void kbc_setBackgroundColorIfPossible(id object, UIColor *color) {
    if ([object respondsToSelector:@selector(setBackgroundColor:)])
        ((void(*)(id, SEL, id))objc_msgSend)(object, @selector(setBackgroundColor:), color);
}

static void kbc_logOLED(id object, NSString *site, BOOL dark) {
    unsigned int sequence = __sync_fetch_and_add(&sOLEDLogCount, 1);
    if (sequence < 16) {
        kbc_log([NSString stringWithFormat:@"oled seq=%u site=%@ class=%@ dark=%d color=%@",
            sequence, site, NSStringFromClass([object class]), dark,
            dark ? @"black" : @"clear"]);
    }
}

static void kbc_oledKeyboardDisplayLayer(id self, SEL command, CALayer *layer) {
    if (sOrigOLEDKeyboardDisplayLayer)
        ((void(*)(id, SEL, id))sOrigOLEDKeyboardDisplayLayer)(self, command, layer);
    BOOL dark = kbc_isDarkKeyboardObject(self);
    kbc_setBackgroundColorIfPossible(self, dark ? UIColor.blackColor : UIColor.clearColor);
    kbc_logOLED(self, @"UIKeyboard.displayLayer", dark);
}

static id kbc_oledPredictionSuggestions(id self, SEL command) {
    Class keyboardClass = objc_getClass("UIKeyboard");
    SEL activeSelector = sel_registerName("activeKeyboard");
    id activeKeyboard = keyboardClass && [keyboardClass respondsToSelector:activeSelector]
        ? ((id(*)(id, SEL))objc_msgSend)(keyboardClass, activeSelector) : nil;
    BOOL dark = kbc_isDarkKeyboardObject(self);
    UIColor *color = dark ? UIColor.blackColor : UIColor.clearColor;
    id view = [self respondsToSelector:@selector(view)]
        ? ((id(*)(id, SEL))objc_msgSend)(self, @selector(view)) : nil;
    kbc_setBackgroundColorIfPossible(view, color);
    kbc_setBackgroundColorIfPossible(activeKeyboard, color);
    kbc_logOLED(self, @"UIPredictionViewController._currentTextSuggestions", dark);
    return sOrigOLEDPredictionSuggestions
        ? ((id(*)(id, SEL))sOrigOLEDPredictionSuggestions)(self, command) : nil;
}

static void kbc_oledDockLayout(id self, SEL command) {
    if (sOrigOLEDDockLayout)
        ((void(*)(id, SEL))sOrigOLEDDockLayout)(self, command);
    BOOL dark = kbc_isDarkKeyboardObject(self);
    kbc_setBackgroundColorIfPossible(self, dark ? UIColor.blackColor : UIColor.clearColor);
    kbc_logOLED(self, @"UIKeyboardDockView.layoutSubviews", dark);
}

static void kbc_oledInputLayout(id self, SEL command) {
    if (sOrigOLEDInputLayout)
        ((void(*)(id, SEL))sOrigOLEDInputLayout)(self, command);
    Class emojiSearch = NSClassFromString(@"TUIEmojiSearchInputView");
    Class autoFill = NSClassFromString(@"_SFAutoFillInputView");
    if ((emojiSearch && [self isKindOfClass:emojiSearch]) ||
        (autoFill && [self isKindOfClass:autoFill])) {
        BOOL dark = kbc_isDarkKeyboardObject(self);
        kbc_setBackgroundColorIfPossible(self, dark ? UIColor.blackColor : UIColor.clearColor);
        kbc_logOLED(self, @"UIInputView.layoutSubviews", dark);
    }
}

static void kbc_oledEffectLayout(id self, SEL command) {
    if (sOrigOLEDEffectLayout)
        ((void(*)(id, SEL))sOrigOLEDEffectLayout)(self, command);
    if (!kbc_isDarkKeyboardObject(self)) return;
    SEL effectsSelector = sel_registerName("setBackgroundEffects:");
    if ([self respondsToSelector:effectsSelector])
        ((void(*)(id, SEL, id))objc_msgSend)(self, effectsSelector, nil);
    kbc_setBackgroundColorIfPossible(self, UIColor.blackColor);
    kbc_logOLED(self, @"UIKBVisualEffectView.layoutSubviews", YES);
}

#pragma mark - UnderDock integration (binary-verified behavior)

@interface KBCUnderDockStackView : UIStackView
@end

static NSArray<NSString *> *kbc_defaultShortcuts(void) {
    return @[
        @"0|selection.pin.in.out", @"1|doc.text", @"2|doc.on.doc",
        @"3|arrow.left.to.line", @"4|arrow.right.to.line", @"5|text.bubble"
    ];
}

static NSSet<NSString *> *kbc_supportedShortcuts(void) {
    static NSSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSSet setWithArray:@[
            @"0|selection.pin.in.out", @"1|doc.text", @"2|doc.on.doc",
            @"3|arrow.left.to.line", @"4|arrow.right.to.line", @"5|text.bubble",
            @"6|keyboard.chevron.compact.down", @"7|arrow.uturn.backward.circle",
            @"8|arrow.uturn.forward.circle"
        ]];
    });
    return set;
}

static id kbc_keyboardImpl(void) {
    Class cls = objc_getClass("UIKeyboardImpl");
    SEL selector = sel_registerName("activeInstance");
    return cls && [cls respondsToSelector:selector]
        ? ((id(*)(id, SEL))objc_msgSend)(cls, selector) : nil;
}

static id kbc_underDockForDock(id dock) {
    return dock ? objc_getAssociatedObject(dock, &sUnderDockViewKey) : nil;
}

static void kbc_underDockHaptic(BOOL longPress, BOOL selection) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (longPress) {
            UINotificationFeedbackGenerator *generator = [UINotificationFeedbackGenerator new];
            [generator prepare];
            [generator notificationOccurred:UINotificationFeedbackTypeSuccess];
        } else if (selection) {
            UISelectionFeedbackGenerator *generator = [UISelectionFeedbackGenerator new];
            [generator prepare];
            [generator selectionChanged];
        } else {
            UIImpactFeedbackGenerator *generator =
                [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [generator prepare];
            [generator impactOccurred];
        }
    });
}

static BOOL kbc_sendAction(id target, const char *name) {
    SEL selector = sel_registerName(name);
    if (target && [target respondsToSelector:selector]) {
        ((void(*)(id, SEL, id))objc_msgSend)(target, selector, nil);
        return YES;
    }
    return NO;
}

static BOOL kbc_activateKayoko(id sender) {
    // Kayoko 3.6.1 adds this exact action to UIResponder and uses it for both
    // its edit-menu UICommand and prediction-bar activation path. Routing the
    // action through UIApplication preserves Kayoko's own responder handling.
    SEL action = NSSelectorFromString(@"_Kayoko_OpenTools_ab2e39c7");
    BOOL routed = [UIApplication.sharedApplication sendAction:action
                                                            to:nil
                                                          from:sender
                                                      forEvent:nil];
    if (!routed) {
        // Keep the documented Core notification as a diagnostic fallback if
        // KayokoHelper was not injected into this particular UIKit process.
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("codes.aurora.kayoko.core.show"), NULL, NULL, true);
    }
    kbc_log([NSString stringWithFormat:@"kayoko activate selector=%@ routed=%d fallback=%d",
        NSStringFromSelector(action), routed, !routed]);
    return YES;
}

@interface KBCKayokoPredictionBar : UIStackView
@end

@implementation KBCKayokoPredictionBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.axis = UILayoutConstraintAxisHorizontal;
    self.distribution = UIStackViewDistributionFillEqually;
    self.alignment = UIStackViewAlignmentFill;
    self.spacing = 0.0;
    // Do not synthesize a separate fill. Kayoko lives inside the system
    // candidate page, whose existing material/background must remain the
    // single visual source in both portrait and landscape.
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    // 统一字体：UIButtonTypeSystem 在 iOS 15+ 会被 UIButtonConfiguration
    // 接管标题样式，切换 keyplane 时字体会在 13pt/15pt 之间漂移（真机
    // 截图实测数字页 15.3pt、字母页 13.3pt）。这里改用 Custom 按钮，
    // 显式锁定字号与基线，保证任意键盘布局下视觉一致。
    NSArray<NSString *> *titles = kbc_kayokoBarTitles();
    for (NSUInteger index = 0; index < titles.count; index++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = index;
        button.titleLabel.font = [UIFont systemFontOfSize:17.0
                                                 weight:UIFontWeightRegular];
        button.titleLabel.adjustsFontSizeToFitWidth = NO;
        button.titleLabel.textAlignment = NSTextAlignmentCenter;
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
        button.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
        [button setTitle:titles[index] forState:UIControlStateNormal];
        [button setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
        [button addTarget:self action:@selector(kbc_action:) forControlEvents:UIControlEventTouchUpInside];
        [self addArrangedSubview:button];
        if (index < 2) {
            UIView *separator = [[UIView alloc] initWithFrame:CGRectZero];
            separator.translatesAutoresizingMaskIntoConstraints = NO;
            separator.backgroundColor = [UIColor.separatorColor colorWithAlphaComponent:0.45];
            [button addSubview:separator];
            [NSLayoutConstraint activateConstraints:@[
                [separator.trailingAnchor constraintEqualToAnchor:button.trailingAnchor],
                [separator.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
                [separator.widthAnchor constraintEqualToConstant:0.5],
                [separator.heightAnchor constraintEqualToAnchor:button.heightAnchor multiplier:0.62]
            ]];
        }
    }
    UIButton *firstButton = self.arrangedSubviews.firstObject;
    kbc_log([NSString stringWithFormat:
        @"kayoko bar create background=inherit(clear) opaque=%d buttons=%lu type=custom font=%.1f",
        self.opaque, (unsigned long)titles.count,
        firstButton.titleLabel.font.pointSize]);
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 兜底：无论系统在哪个 keyplane 回写按钮配置，布局结束后都把字号
    // 拉回统一值，保证三个按钮在任何键盘布局下视觉完全一致。
    for (UIView *view in self.arrangedSubviews) {
        if (![view isKindOfClass:[UIButton class]]) continue;
        UIButton *button = (UIButton *)view;
        UIFont *unified = [UIFont systemFontOfSize:17.0
                                           weight:UIFontWeightRegular];
        if (fabs(button.titleLabel.font.pointSize - unified.pointSize) > 0.01 ||
            button.titleLabel.adjustsFontSizeToFitWidth ||
            button.contentVerticalAlignment != UIControlContentVerticalAlignmentCenter) {
            button.titleLabel.font = unified;
            button.titleLabel.adjustsFontSizeToFitWidth = NO;
            button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
            button.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
        }
    }
}

- (void)kbc_action:(UIButton *)sender {
    BOOL executed = NO;
    id keyboard = kbc_keyboardImpl();
    SEL inputDelegateSelector = sel_registerName("inputDelegate");
    id delegate = keyboard && [keyboard respondsToSelector:inputDelegateSelector]
        ? ((id(*)(id, SEL))objc_msgSend)(keyboard, inputDelegateSelector) : nil;
    if (sender.tag == 0) executed = kbc_activateKayoko(sender);
    else if (sender.tag == 1) executed = kbc_sendAction(delegate, "copy:");
    else if (sender.tag == 2) executed = kbc_sendAction(delegate, "paste:");
    kbc_log([NSString stringWithFormat:@"kayoko bar action tag=%ld executed=%d delegate=%@",
        (long)sender.tag, executed, NSStringFromClass([delegate class])]);
}

- (void)kbc_pageTap:(UITapGestureRecognizer *)recognizer {
    if (self.hidden || recognizer.state != UIGestureRecognizerStateEnded) return;
    CGPoint point = [recognizer locationInView:self];
    if (!CGRectContainsPoint(self.bounds, point) || self.bounds.size.width <= 0.0) return;
    UIButton *sender = [UIButton buttonWithType:UIButtonTypeCustom];
    sender.tag = MIN(2, (NSInteger)floor(point.x / (self.bounds.size.width / 3.0)));
    [self kbc_action:sender];
}

@end

static id kbc_inputDelegate(void) {
    id keyboard = kbc_keyboardImpl();
    SEL inputDelegateSelector = sel_registerName("inputDelegate");
    return keyboard && [keyboard respondsToSelector:inputDelegateSelector]
        ? ((id(*)(id, SEL))objc_msgSend)(keyboard, inputDelegateSelector) : nil;
}

static id kbc_objectForSelector(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id(*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSInteger kbc_integerForSelector(id object, NSString *name,
                                        NSInteger missing) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return missing;
    @try {
        return ((NSInteger(*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return missing;
    }
}

static void kbc_collectKayokoViews(UIView *view, NSMutableArray<NSString *> *parts,
                                   NSUInteger depth) {
    if (!view || depth > 18) return;
    NSString *name = NSStringFromClass([view class]);
    if ([name containsString:@"Kayoko"]) {
        CGAffineTransform transform = view.transform;
        [parts addObject:[NSString stringWithFormat:
            @"%@<%p> frame=(%.0f,%.0f,%.0f,%.0f) bounds=(%.0f,%.0f,%.0f,%.0f) transform=(%.2f,%.2f,%.2f,%.2f,%.0f,%.0f) hidden=%d alpha=%.2f",
            name, view, view.frame.origin.x, view.frame.origin.y,
            view.frame.size.width, view.frame.size.height,
            view.bounds.origin.x, view.bounds.origin.y,
            view.bounds.size.width, view.bounds.size.height,
            transform.a, transform.b, transform.c, transform.d,
            transform.tx, transform.ty, view.hidden, view.alpha]];
    }
    for (UIView *subview in view.subviews)
        kbc_collectKayokoViews(subview, parts, depth + 1);
}

static void kbc_logKayokoCoreOrientation(NSString *phase) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"])
        return;
    unsigned int sequence = __sync_fetch_and_add(&sKayokoCoreOrientationLogCount, 1);
    if (sequence >= 24) return;
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        [parts addObject:[NSString stringWithFormat:
            @"scene=%@<%p> state=%ld orientation=%ld bounds=(%.0f,%.0f)",
            NSStringFromClass([scene class]), scene, (long)scene.activationState,
            (long)windowScene.interfaceOrientation,
            windowScene.coordinateSpace.bounds.size.width,
            windowScene.coordinateSpace.bounds.size.height]];
        for (UIWindow *window in windowScene.windows) {
            NSMutableArray<NSString *> *views = [NSMutableArray array];
            kbc_collectKayokoViews(window, views, 0);
            UIViewController *root = window.rootViewController;
            [parts addObject:[NSString stringWithFormat:
                @"window=%@<%p> key=%d hidden=%d level=%.0f frame=(%.0f,%.0f,%.0f,%.0f) root=%@<%p> rootOrientation=%ld kayoko=[%@]",
                NSStringFromClass([window class]), window, window.isKeyWindow,
                window.hidden, window.windowLevel, window.frame.origin.x,
                window.frame.origin.y, window.frame.size.width, window.frame.size.height,
                NSStringFromClass([root class]), root,
                (long)root.interfaceOrientation,
                views.count ? [views componentsJoinedByString:@" | "] : @"none"]];
        }
    }
    kbc_log([NSString stringWithFormat:@"kayoko-core-orientation seq=%u phase=%@ %@",
        sequence, phase, [parts componentsJoinedByString:@" || "]]);
}

static NSString *kbc_viewGeometrySummary(UIView *view) {
    if (!view) return @"nil";
    CGAffineTransform transform = view.transform;
    return [NSString stringWithFormat:
        @"%@<%p> frame=(%.0f,%.0f,%.0f,%.0f) bounds=(%.0f,%.0f,%.0f,%.0f) center=(%.0f,%.0f) transform=(%.2f,%.2f,%.2f,%.2f,%.0f,%.0f) safe=(%.0f,%.0f,%.0f,%.0f)",
        NSStringFromClass([view class]), view,
        view.frame.origin.x, view.frame.origin.y, view.frame.size.width, view.frame.size.height,
        view.bounds.origin.x, view.bounds.origin.y, view.bounds.size.width, view.bounds.size.height,
        view.center.x, view.center.y, transform.a, transform.b, transform.c, transform.d,
        transform.tx, transform.ty, view.safeAreaInsets.top, view.safeAreaInsets.left,
        view.safeAreaInsets.bottom, view.safeAreaInsets.right];
}

static NSString *kbc_layerGeometrySummary(CALayer *layer) {
    if (!layer) return @"nil";
    CATransform3D transform = layer.transform;
    return [NSString stringWithFormat:
        @"%@<%p> frame=(%.1f,%.1f,%.1f,%.1f) bounds=(%.1f,%.1f,%.1f,%.1f) position=(%.1f,%.1f) opacity=%.2f transform=[%.2f %.2f %.2f %.2f]",
        NSStringFromClass([layer class]), layer,
        layer.frame.origin.x, layer.frame.origin.y, layer.frame.size.width, layer.frame.size.height,
        layer.bounds.origin.x, layer.bounds.origin.y, layer.bounds.size.width, layer.bounds.size.height,
        layer.position.x, layer.position.y, layer.opacity,
        transform.m11, transform.m12, transform.m21, transform.m22];
}

static void kbc_sampleKayokoAnimation(UIView *view, NSString *event) {
    static const int delays[] = {0, 40, 80, 140, 220, 350, 500};
    for (NSUInteger index = 0; index < sizeof(delays) / sizeof(delays[0]); index++) {
        int delay = delays[index];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            CALayer *presentation = view.layer.presentationLayer;
            kbc_log([NSString stringWithFormat:
                @"kayoko-core-animation event=%@ t=%d model={%@} presentation={%@} super={%@}",
                event, delay, kbc_layerGeometrySummary(view.layer),
                kbc_layerGeometrySummary(presentation),
                kbc_viewGeometrySummary(view.superview)]);
        });
    }
}

static void kbc_logKayokoCoreView(id self, NSString *phase) {
    if (![self isKindOfClass:[UIView class]]) return;
    UIView *view = self;
    UIWindow *window = view.window;
    UIWindowScene *scene = window.windowScene;
    kbc_log([NSString stringWithFormat:
        @"kayoko-core-view phase=%@ self={%@} super={%@} window={%@} scene=%@<%p> orientation=%ld sceneBounds=(%.0f,%.0f) screenBounds=(%.0f,%.0f)",
        phase, kbc_viewGeometrySummary(view), kbc_viewGeometrySummary(view.superview),
        kbc_viewGeometrySummary(window), NSStringFromClass([scene class]), scene,
        (long)scene.interfaceOrientation, scene.coordinateSpace.bounds.size.width,
        scene.coordinateSpace.bounds.size.height, UIScreen.mainScreen.bounds.size.width,
        UIScreen.mainScreen.bounds.size.height]);
}

static UIWindow *kbc_visibleLandscapeKeyboardWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSString *name = NSStringFromClass([window class]);
            UIInterfaceOrientation orientation = window.rootViewController.interfaceOrientation;
            if ([name isEqualToString:@"UITextEffectsWindow"] && !window.hidden &&
                window.bounds.size.width > window.bounds.size.height &&
                UIInterfaceOrientationIsLandscape(orientation)) {
                return window;
            }
        }
    }
    return nil;
}

static CGRect kbc_kayokoOriginalBounds(UIView *view) {
    NSValue *stored = objc_getAssociatedObject(view, &sKayokoOriginalBoundsKey);
    CGRect bounds = stored ? stored.CGRectValue : view.bounds;
    if (bounds.size.width <= 0.0 || bounds.size.height <= 0.0)
        bounds = CGRectMake(0.0, 0.0, 430.0, 400.0);
    return bounds;
}

static CGPoint kbc_kayokoLandscapeFinalCenter(UIView *host, CGRect bounds) {
    return CGPointMake(CGRectGetMidX(host.bounds),
                       CGRectGetMaxY(host.bounds) - bounds.size.height * 0.5);
}

static BOOL kbc_prepareKayokoLandscapeHost(UIView *view, NSString *phase) {
    UIWindow *keyboardWindow = kbc_visibleLandscapeKeyboardWindow();
    UIView *host = keyboardWindow.rootViewController.view;
    if (!host || host.bounds.size.width <= host.bounds.size.height) return NO;

    CGRect originalBounds = kbc_kayokoOriginalBounds(view);
    [view.layer removeAllAnimations];
    if (view.superview != host) {
        objc_setAssociatedObject(view, &sKayokoOriginalSuperviewKey,
            view.superview, OBJC_ASSOCIATION_ASSIGN);
        [host addSubview:view];
    }
    objc_setAssociatedObject(view, &sKayokoLandscapeHostKey, host,
        OBJC_ASSOCIATION_ASSIGN);
    view.autoresizingMask = UIViewAutoresizingNone;
    view.transform = CGAffineTransformIdentity;
    view.bounds = originalBounds;
    view.center = kbc_kayokoLandscapeFinalCenter(host, originalBounds);
    [host bringSubviewToFront:view];
    [view setNeedsLayout];
    [view layoutIfNeeded];

    UIInterfaceOrientation orientation = keyboardWindow.rootViewController.interfaceOrientation;
    kbc_log([NSString stringWithFormat:
        @"kayoko-core-landscape-host phase=%@ orientation=%ld originalBounds=(%.0f,%.0f) host={%@} result={%@}",
        phase, (long)orientation, originalBounds.size.width, originalBounds.size.height,
        kbc_viewGeometrySummary(host), kbc_viewGeometrySummary(view)]);
    return YES;
}

static void kbc_kayokoCoreViewLayout(id self, SEL command) {
    if (sOrigKayokoCoreViewLayout)
        ((void(*)(id, SEL))sOrigKayokoCoreViewLayout)(self, command);
    if ([self isKindOfClass:[UIView class]]) {
        UIView *view = self;
        UIView *host = objc_getAssociatedObject(view, &sKayokoLandscapeHostKey);
        BOOL animating = [objc_getAssociatedObject(view,
            &sKayokoLandscapeAnimatingKey) boolValue];
        if (host && view.superview == host && !animating) {
            CGRect bounds = kbc_kayokoOriginalBounds(view);
            view.transform = CGAffineTransformIdentity;
            view.bounds = bounds;
            view.center = kbc_kayokoLandscapeFinalCenter(host, bounds);
        }
    }
    kbc_logKayokoCoreView(self, @"layout-after-original");
}

static void kbc_kayokoCoreViewShow(id self, SEL command) {
    kbc_logKayokoCoreView(self, @"show-before");
    if ([self isKindOfClass:[UIView class]]) {
        UIView *view = self;
        CGRect bounds = view.bounds;
        if (bounds.size.width > 0.0 && bounds.size.height > 0.0)
            objc_setAssociatedObject(view, &sKayokoOriginalBoundsKey,
                [NSValue valueWithCGRect:bounds], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL animationsWereEnabled = UIView.areAnimationsEnabled;
    [UIView setAnimationsEnabled:NO];
    if (sOrigKayokoCoreViewShow)
        ((void(*)(id, SEL))sOrigKayokoCoreViewShow)(self, command);
    [UIView setAnimationsEnabled:animationsWereEnabled];
    if ([self isKindOfClass:[UIView class]]) {
        UIView *view = self;
        if (kbc_prepareKayokoLandscapeHost(view, @"show-after-original")) {
            UIView *host = view.superview;
            CGRect bounds = kbc_kayokoOriginalBounds(view);
            CGPoint finalCenter = kbc_kayokoLandscapeFinalCenter(host, bounds);
            view.center = CGPointMake(finalCenter.x,
                CGRectGetMaxY(host.bounds) + bounds.size.height * 0.5);
            view.alpha = 0.0;
            objc_setAssociatedObject(view, &sKayokoLandscapeAnimatingKey, @YES,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [UIView animateWithDuration:0.25 delay:0.0
                options:UIViewAnimationOptionCurveEaseOut |
                        UIViewAnimationOptionBeginFromCurrentState
                animations:^{
                    view.center = finalCenter;
                    view.alpha = 1.0;
                } completion:^(__unused BOOL finished) {
                    objc_setAssociatedObject(view, &sKayokoLandscapeAnimatingKey,
                        @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    kbc_logKayokoCoreView(view, @"show-landscape-complete");
                }];
        }
    }
    kbc_logKayokoCoreView(self, @"show-after");
    if ([self isKindOfClass:[UIView class]])
        kbc_sampleKayokoAnimation(self, @"show");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        kbc_logKayokoCoreView(self, @"show-500ms");
    });
}

static void kbc_kayokoCoreViewHide(id self, SEL command) {
    kbc_logKayokoCoreView(self, @"hide-before");
    UIView *view = [self isKindOfClass:[UIView class]] ? self : nil;
    UIView *host = view ? objc_getAssociatedObject(view,
        &sKayokoLandscapeHostKey) : nil;
    if (view && host && view.superview == host) {
        CGRect bounds = kbc_kayokoOriginalBounds(view);
        objc_setAssociatedObject(view, &sKayokoLandscapeAnimatingKey, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [UIView animateWithDuration:0.25 delay:0.0
            options:UIViewAnimationOptionCurveEaseIn |
                    UIViewAnimationOptionBeginFromCurrentState
            animations:^{
                view.center = CGPointMake(CGRectGetMidX(host.bounds),
                    CGRectGetMaxY(host.bounds) + bounds.size.height * 0.5);
                view.alpha = 0.0;
            } completion:^(__unused BOOL finished) {
                UIView *originalSuperview = objc_getAssociatedObject(view,
                    &sKayokoOriginalSuperviewKey);
                if (originalSuperview) {
                    [originalSuperview addSubview:view];
                    view.transform = CGAffineTransformIdentity;
                    view.bounds = bounds;
                    view.center = CGPointMake(CGRectGetMidX(originalSuperview.bounds),
                        CGRectGetMaxY(originalSuperview.bounds) - bounds.size.height * 0.5);
                    view.alpha = 1.0;
                }
                BOOL enabled = UIView.areAnimationsEnabled;
                [UIView setAnimationsEnabled:NO];
                if (sOrigKayokoCoreViewHide)
                    ((void(*)(id, SEL))sOrigKayokoCoreViewHide)(self, command);
                [UIView setAnimationsEnabled:enabled];
                objc_setAssociatedObject(view, &sKayokoLandscapeAnimatingKey,
                    @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(view, &sKayokoLandscapeHostKey, nil,
                    OBJC_ASSOCIATION_ASSIGN);
                objc_setAssociatedObject(view, &sKayokoOriginalSuperviewKey, nil,
                    OBJC_ASSOCIATION_ASSIGN);
                kbc_logKayokoCoreView(view, @"hide-landscape-complete");
            }];
        kbc_sampleKayokoAnimation(view, @"hide-landscape");
        return;
    }
    if (sOrigKayokoCoreViewHide)
        ((void(*)(id, SEL))sOrigKayokoCoreViewHide)(self, command);
    kbc_logKayokoCoreView(self, @"hide-after-original");
}

static void kbc_installKayokoCoreViewHooks(NSString *source) {
    if (sKayokoCoreViewHooksInstalled) return;
    Class cls = objc_getClass("KayokoView");
    Method layout = cls ? class_getInstanceMethod(cls, @selector(layoutSubviews)) : NULL;
    Method show = cls ? class_getInstanceMethod(cls, NSSelectorFromString(@"show")) : NULL;
    Method hide = cls ? class_getInstanceMethod(cls, NSSelectorFromString(@"hide")) : NULL;
    if (!layout || !show || !hide) {
        kbc_log([NSString stringWithFormat:
            @"hook feature=kayoko-core-view source=%@ class=%@ layout=%s show=%s hide=%s",
            source, NSStringFromClass(cls), layout ? method_getTypeEncoding(layout) : "missing",
            show ? method_getTypeEncoding(show) : "missing",
            hide ? method_getTypeEncoding(hide) : "missing"]);
        return;
    }
    MSHookMessageEx(cls, @selector(layoutSubviews), (IMP)kbc_kayokoCoreViewLayout,
        &sOrigKayokoCoreViewLayout);
    MSHookMessageEx(cls, NSSelectorFromString(@"show"), (IMP)kbc_kayokoCoreViewShow,
        &sOrigKayokoCoreViewShow);
    MSHookMessageEx(cls, NSSelectorFromString(@"hide"), (IMP)kbc_kayokoCoreViewHide,
        &sOrigKayokoCoreViewHide);
    sKayokoCoreViewHooksInstalled = YES;
    kbc_log([NSString stringWithFormat:
        @"hook feature=kayoko-core-view source=%@ class=%@ layout=%s show=%s hide=%s",
        source, NSStringFromClass(cls), method_getTypeEncoding(layout),
        method_getTypeEncoding(show), method_getTypeEncoding(hide)]);
}

static void kbc_kayokoCoreShowNotification(CFNotificationCenterRef center,
                                            void *observer,
                                            CFStringRef name,
                                            const void *object,
                                            CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        kbc_logKayokoCoreOrientation(@"show-now");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            kbc_logKayokoCoreOrientation(@"show-150ms");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            kbc_logKayokoCoreOrientation(@"show-600ms");
        });
    });
}

static void kbc_installKayokoCoreOrientationDiagnostics(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"])
        return;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, kbc_kayokoCoreShowNotification, CFSTR("codes.aurora.kayoko.core.show"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    kbc_installKayokoCoreViewHooks(@"constructor");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        kbc_installKayokoCoreViewHooks(@"delayed-1s");
    });
    kbc_log(@"hook feature=kayoko-core-orientation notification=core.show delays=0/150/600ms");
}

static NSString *kbc_boundedDescription(id value) {
    if (!value) return @"nil";
    NSString *description = nil;
    @try { description = [value description]; }
    @catch (__unused NSException *exception) { description = @"<exception>"; }
    description = [description stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (description.length > 180) description = [description substringToIndex:180];
    NSUInteger count = [value respondsToSelector:@selector(count)] ? [value count] : NSNotFound;
    return count == NSNotFound
        ? [NSString stringWithFormat:@"%@<%p> %@", NSStringFromClass([value class]), value, description]
        : [NSString stringWithFormat:@"%@<%p> count=%lu %@", NSStringFromClass([value class]),
            value, (unsigned long)count, description];
}

static NSString *kbc_textInputTraitsSummary(id input) {
    if (!input) return @"nil";
    NSString *text = kbc_objectForSelector(input, @"text");
    if (![text isKindOfClass:[NSString class]]) text = @"<unavailable>";
    if (text.length > 80) text = [text substringToIndex:80];
    return [NSString stringWithFormat:
        @"%@<%p> first=%d text='%@' autocorrection=%ld spell=%ld smartQuotes=%ld smartDashes=%ld keyboard=%ld return=%ld autoReturn=%ld secure=%ld contentType=%@",
        NSStringFromClass([input class]), input,
        [input respondsToSelector:@selector(isFirstResponder)] ? [input isFirstResponder] : 0,
        text,
        (long)kbc_integerForSelector(input, @"autocorrectionType", -99),
        (long)kbc_integerForSelector(input, @"spellCheckingType", -99),
        (long)kbc_integerForSelector(input, @"smartQuotesType", -99),
        (long)kbc_integerForSelector(input, @"smartDashesType", -99),
        (long)kbc_integerForSelector(input, @"keyboardType", -99),
        (long)kbc_integerForSelector(input, @"returnKeyType", -99),
        (long)kbc_integerForSelector(input, @"enablesReturnKeyAutomatically", -99),
        (long)kbc_integerForSelector(input, @"isSecureTextEntry", -99),
        kbc_objectForSelector(input, @"textContentType") ?: @"nil"];
}

static NSString *kbc_predictionControllerSummary(void) {
    id keyboard = kbc_keyboardImpl();
    id autocorrection = kbc_objectForSelector(keyboard, @"autocorrectionController");
    id prediction = kbc_objectForSelector(keyboard, @"predictionViewController");
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithArray:@[
        [NSString stringWithFormat:@"keyboard=%@<%p>", NSStringFromClass([keyboard class]), keyboard],
        [NSString stringWithFormat:@"autocorrection=%@<%p>", NSStringFromClass([autocorrection class]), autocorrection],
        [NSString stringWithFormat:@"prediction=%@<%p>", NSStringFromClass([prediction class]), prediction]
    ]];
    for (NSString *name in @[@"autocorrectionList", @"_autocorrectionList",
                              @"textSuggestionList", @"_currentTextSuggestions"]) {
        id value = kbc_objectForSelector(autocorrection, name);
        if (!value) value = kbc_objectForSelector(prediction, name);
        if (!value) value = kbc_objectForSelector(keyboard, name);
        [parts addObject:[NSString stringWithFormat:@"%@={%@}", name,
            kbc_boundedDescription(value)]];
    }
    return [parts componentsJoinedByString:@" "];
}

static void kbc_logTextInputState(id input, NSString *phase,
                                  unsigned int sequence) {
    id delegate = kbc_inputDelegate();
    kbc_log([NSString stringWithFormat:
        @"kayoko-text seq=%u phase=%@ input={%@} delegate={%@} controller={%@}",
        sequence, phase, kbc_textInputTraitsSummary(input),
        kbc_textInputTraitsSummary(delegate), kbc_predictionControllerSummary()]);
    if (sKayokoHostView) kbc_updateKayokoPage(sKayokoHostView,
        [NSString stringWithFormat:@"text-change-%@", phase]);
}

static void kbc_installKayokoTextDiagnostics(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UITextFieldTextDidBeginEditingNotification
                       object:nil queue:NSOperationQueue.mainQueue
                   usingBlock:^(NSNotification *notification) {
        id input = notification.object;
        NSString *className = NSStringFromClass([input class]);
        if (![className containsString:@"SPUITextField"]) return;
        NSInteger before = kbc_integerForSelector(input, @"autocorrectionType", -99);
        BOOL setter = [input respondsToSelector:@selector(setAutocorrectionType:)];
        @try {
            if (setter) ((void(*)(id, SEL, NSInteger))objc_msgSend)(input,
                @selector(setAutocorrectionType:), UITextAutocorrectionTypeYes);
        } @catch (__unused NSException *exception) {}
        NSInteger after = kbc_integerForSelector(input, @"autocorrectionType", -99);
        kbc_log([NSString stringWithFormat:
            @"spotlight-prediction-enable input=%@<%p> setter=%d before=%ld after=%ld first=%d",
            className, input, setter, (long)before, (long)after,
            [input respondsToSelector:@selector(isFirstResponder)] ? [input isFirstResponder] : 0]);
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([input respondsToSelector:@selector(reloadInputViews)] &&
                [input isFirstResponder]) {
                [input reloadInputViews];
                kbc_log([NSString stringWithFormat:
                    @"spotlight-prediction-reload input=%@<%p> autocorrection=%ld",
                    NSStringFromClass([input class]), input,
                    (long)kbc_integerForSelector(input, @"autocorrectionType", -99)]);
            }
        });
    }];
    NSArray<NSNotificationName> *names = @[
        UITextFieldTextDidChangeNotification, UITextViewTextDidChangeNotification
    ];
    for (NSNotificationName name in names) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                       usingBlock:^(NSNotification *notification) {
            id input = notification.object;
            BOOL active = [input respondsToSelector:@selector(isFirstResponder)] &&
                          [input isFirstResponder];
            NSString *className = NSStringFromClass([input class]);
            if (!active && ![className containsString:@"SPUITextField"]) return;
            unsigned int sequence = __sync_fetch_and_add(&sKayokoTextChangeLogCount, 1);
            // 日志配额只限制诊断输出，不能吞掉 Kayoko 状态刷新：
            // 旧写法 `if (sequence >= 80) return;` 会让第 80 次输入之后
            // 这条刷新路径彻底失效，只剩余 layout 兜底。
            BOOL detailedLog = sequence < 80;
            if (detailedLog) {
                kbc_logTextInputState(input, @"now", sequence);
            } else if (sKayokoHostView) {
                kbc_updateKayokoPage(sKayokoHostView, @"text-change-now");
            }
            for (NSNumber *delay in @[@0.12, @0.35]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                    NSString *phase = [NSString stringWithFormat:@"+%.0fms",
                        delay.doubleValue * 1000.0];
                    if (detailedLog) {
                        kbc_logTextInputState(input, phase, sequence);
                    } else if (sKayokoHostView) {
                        kbc_updateKayokoPage(sKayokoHostView,
                            [NSString stringWithFormat:@"text-change-%@", phase]);
                    }
                });
            }
        }];
    }
    kbc_log(@"hook feature=kayoko-text-diagnostics notifications=begin+change delays=0/120/350ms");
}

static BOOL kbc_inputHasMarkedText(void) {
    id delegate = kbc_inputDelegate();
    if (![delegate conformsToProtocol:@protocol(UITextInput)]) return NO;
    @try {
        return [(id<UITextInput>)delegate markedTextRange] != nil;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL kbc_viewIsVisibleInPage(UIView *view, UIView *page, CGRect frame) {
    if (CGRectIsEmpty(frame) || !CGRectIntersectsRect(page.bounds, frame)) return NO;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha <= 0.01) return NO;
        if (ancestor == page) return YES;
    }
    return NO;
}

static BOOL kbc_viewShowsImage(UIView *view, NSUInteger depth) {
    if (!view || depth > 4) return NO;
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)view;
        if (!imageView.hidden && imageView.alpha > 0.01 && imageView.image) return YES;
    }
    for (UIView *subview in view.subviews)
        if (kbc_viewShowsImage(subview, depth + 1)) return YES;
    return NO;
}

static void kbc_collectCandidateNodes(UIView *view, UIView *page,
                                      NSMutableArray<NSString *> *parts,
                                      BOOL *hasVisibleCandidateText,
                                      NSUInteger depth) {
    if (!view || depth > 12) return;
    NSString *className = NSStringFromClass([view class]);
    // emoji 候选整行只有图标、没有文本，且所在容器类名不一定含
    // Candidate/Prediction。page 子树里除系统内容就只有自绘栏（无图标），
    // 因此这里对任何可见的 emoji 缩略图直接判为"系统内容"。
    if ([view isKindOfClass:[UIImageView class]]) {
        CGRect imageFrame = [view convertRect:view.bounds toView:page];
        if (imageFrame.size.height > 18.0 && imageFrame.size.width > 10.0 &&
            kbc_viewIsVisibleInPage(view, page, imageFrame))
            *hasVisibleCandidateText = YES;
    }
    BOOL candidateNode = [className containsString:@"Candidate"] ||
                         [className containsString:@"Prediction"];
    if (candidateNode && ![view isKindOfClass:[KBCKayokoPredictionBar class]]) {
        CGRect frame = [view convertRect:view.bounds toView:page];
        NSString *label = nil;
        NSString *value = nil;
        @try {
            label = view.accessibilityLabel;
            value = [view.accessibilityValue isKindOfClass:[NSString class]]
                ? view.accessibilityValue : nil;
        }
        @catch (__unused NSException *exception) {}
        NSString *text = label.length ? label : value;
        BOOL visible = kbc_viewIsVisibleInPage(view, page, frame);
        // 判据覆盖三类系统内容：
        // 1) 文字候选（TUICandidateLabel / PredictionViewCell 的 label）
        // 2) 任意 Cell 类节点自带的文本（排除自绘按钮文案）
        // 3) emoji 候选 —— 没有文本，只有 UIImageView，必须按图标判定，
        //    否则整行表情建议会被当成"无候选"，Kayoko 栏压上去导致重叠。
        BOOL cellNode = candidateNode && [className containsString:@"Cell"];
        BOOL labelNode = [className containsString:@"CandidateLabel"] ||
                         ([view isKindOfClass:[UILabel class]] && candidateNode);
        BOOL ownText = text.length && !kbc_textIsKayokoBarTitle(text);
        if (visible && ownText && (cellNode || labelNode))
            *hasVisibleCandidateText = YES;
        if (visible && cellNode && kbc_viewShowsImage(view, 0))
            *hasVisibleCandidateText = YES;
        [parts addObject:[NSString stringWithFormat:
            @"%@<%p> visible=%d hidden=%d alpha=%.2f frame=(%.0f,%.0f,%.0f,%.0f) text=%@",
            className, view, visible, view.hidden, view.alpha,
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            text.length ? text : @"-"]];
    }
    for (UIView *subview in view.subviews)
        kbc_collectCandidateNodes(subview, page, parts,
                                  hasVisibleCandidateText, depth + 1);
}

static NSString *kbc_candidateTreeSummary(UIView *page,
                                          BOOL *hasVisibleCandidateText) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    *hasVisibleCandidateText = NO;
    for (UIView *subview in page.subviews)
        kbc_collectCandidateNodes(subview, page, parts,
                                  hasVisibleCandidateText, 0);
    return parts.count ? [parts componentsJoinedByString:@" | "] : @"none";
}

static void kbc_updateKayokoPage(UIView *page, NSString *reason) {
    if (!page) return;
    KBCKayokoPredictionBar *bar = objc_getAssociatedObject(page, &sKayokoPredictionBarKey);
    if (!bar) return;
    // 系统在切换 keyplane 时会把 page 的非系统子视图搬进预测栏内容区
    // （TUIPredictionViewStackContentView）。一旦被搬走，bar 就会被预测栏
    // 的排版规则接管：字号、内边距、基线都随之变化，表现为数字页/字母页
    // 字体和位置不一致。这里检测到父视图漂移就立即搬回 page 顶层。
    if (bar.superview != page) {
        UIView *oldParent = bar.superview;
        unsigned int migrateSeq = __sync_fetch_and_add(&sKayokoMigrateLogCount, 1);
        if (migrateSeq < 40) {
            kbc_log([NSString stringWithFormat:
                @"kayoko bar migrate seq=%u reason=%@ from=%@ to=%@ size=(%.0f,%.0f)",
                migrateSeq, reason, NSStringFromClass([oldParent class]),
                NSStringFromClass([page class]),
                bar.bounds.size.width, bar.bounds.size.height]);
        }
        [page addSubview:bar];
        bar.frame = page.bounds;
    }
    BOOL visibleCandidateText = NO;
    NSString *tree = kbc_candidateTreeSummary(page, &visibleCandidateText);
    BOOL composing = kbc_inputHasMarkedText();
    BOOL listCandidates = sKayokoHasSystemCandidates;
    BOOL hasCandidates = visibleCandidateText || listCandidates;
    // 英文键盘在部分界面（如 App 资源库搜索）没有预测栏，page 会被系统移到
    // 屏幕外（高度 0 或 y 在屏幕下方），此时 bar 即使 hidden=NO 也不该存在，
    // 否则会以错误坐标留在键盘按键行上。这里按 page 的实际可见性裁决。
    CGRect pageInWindow = page.window
        ? [page convertRect:page.bounds toView:page.window] : CGRectZero;
    BOOL pageVisible = page.window &&
        pageInWindow.size.height >= 20.0 && pageInWindow.size.width >= 20.0 &&
        CGRectIntersectsRect(page.window.bounds, pageInWindow);
    BOOL shouldHide = composing || hasCandidates || !pageVisible;
    // 挂回 page：bar.frame 恒等于 page.bounds，键盘移动/高度动画都由
    // page 的布局带动，不会再出现"栏留在键盘按键行"的错位。
    if (shouldHide) {
        if (bar.superview) [bar removeFromSuperview];
        bar.hidden = YES;
    } else {
        bar.hidden = NO;
        if (bar.superview != page) [page addSubview:bar];
        bar.frame = page.bounds;
        [page bringSubviewToFront:bar];
    }
    UIGestureRecognizer *tap = objc_getAssociatedObject(page, &sKayokoPredictionTapKey);
    tap.enabled = !shouldHide;
    unsigned int sequence = __sync_fetch_and_add(&sKayokoBarLogCount, 1);
    if (sequence < 240) {
        UIView *firstButton = bar.arrangedSubviews.firstObject;
        kbc_log([NSString stringWithFormat:
            @"kayoko pagebar seq=%u reason=%@ page=%p bar=%p super=%@ keyplane=%@ delegate=%@ composing=%d list=%d visibleText=%d hidden=%d gesture=%d frame=(%.0f,%.0f) pageBounds=(%.0f,%.0f) barOrigin=(%.1f,%.1f) btnH=%.1f",
            sequence, reason, page, bar, NSStringFromClass([bar.superview class]),
            sKayokoProbeKeyplane ?: @"unknown",
            NSStringFromClass([kbc_inputDelegate() class]), composing,
            listCandidates, visibleCandidateText, bar.hidden, tap.enabled,
            bar.bounds.size.width, bar.bounds.size.height,
            page.bounds.size.width, page.bounds.size.height,
            bar.frame.origin.x, bar.frame.origin.y,
            firstButton.bounds.size.height]);
    }
    unsigned int treeSequence = __sync_fetch_and_add(&sKayokoCandidateTreeLogCount, 1);
    if (treeSequence < 160) {
        kbc_log([NSString stringWithFormat:@"kayoko-tree seq=%u reason=%@ page=%p %@",
            treeSequence, reason, page, tree]);
    }
}

static UIView *kbc_candidatePageForView(UIView *view) {
    Class pageClass = objc_getClass("TUISystemInputAssistantPageView");
    for (UIView *ancestor = view.superview; ancestor; ancestor = ancestor.superview) {
        if (pageClass && [ancestor isKindOfClass:pageClass]) return ancestor;
    }
    return nil;
}

static void kbc_scheduleKayokoPageUpdateFromCandidateView(UIView *view,
                                                           NSString *reason) {
    UIView *page = kbc_candidatePageForView(view);
    if (!page || [objc_getAssociatedObject(page, &sKayokoUpdateScheduledKey) boolValue]) return;
    objc_setAssociatedObject(page, &sKayokoUpdateScheduledKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakPage = page;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongPage = weakPage;
        if (!strongPage) return;
        objc_setAssociatedObject(strongPage, &sKayokoUpdateScheduledKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        kbc_updateKayokoPage(strongPage, reason);
    });
}

static void kbc_kayokoCandidateCollectionLayout(id self, SEL command) {
    if (sOrigKayokoCandidateCollectionLayout)
        ((void(*)(id, SEL))sOrigKayokoCandidateCollectionLayout)(self, command);
    if ([self isKindOfClass:[UIView class]])
        kbc_scheduleKayokoPageUpdateFromCandidateView(self, @"candidate-collection-layout");
}

static void kbc_kayokoPredictionContentLayout(id self, SEL command) {
    if (sOrigKayokoPredictionContentLayout)
        ((void(*)(id, SEL))sOrigKayokoPredictionContentLayout)(self, command);
    if ([self isKindOfClass:[UIView class]])
        kbc_scheduleKayokoPageUpdateFromCandidateView(self, @"prediction-content-layout");
}

static void kbc_kayokoPageLayout(id self, SEL command) {
    if (sOrigKayokoPageLayout)
        ((void(*)(id, SEL))sOrigKayokoPageLayout)(self, command);
    if (![self isKindOfClass:[UIView class]]) return;
    UIView *page = self;
    // 隐藏/离屏的 page 不做处理，避免旧页面抢走共享 bar 的位置。
    if (page.hidden || page.alpha < 0.01 || page.bounds.size.height < 1.0) return;
    sKayokoHostView = page;
    KBCKayokoPredictionBar *bar = objc_getAssociatedObject(page, &sKayokoPredictionBarKey);
    if (!bar) {
        // 全进程只允许存在一个 bar：切换中英文/字母数字时系统会重建
        // TUISystemInputAssistantPageView，旧实现每个新 page 都 new 一个
        // 并挂到键盘窗口，窗口上就留下多个叠在一起的 bar（资源库搜索框
        // 下切输入法即可复现"两个 bar"）。
        if (!sSharedKayokoBar) {
            sSharedKayokoBar = [[KBCKayokoPredictionBar alloc] initWithFrame:page.bounds];
            sSharedKayokoBar.autoresizingMask =
                UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            kbc_log(@"kayoko bar alloc singleton");
        }
        bar = sSharedKayokoBar;
        objc_setAssociatedObject(page, &sKayokoPredictionBarKey, bar,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // 直接挂在 page 上：bar.frame 恒等于 page.bounds，键盘移动/高度变化
        // 时天然跟随，不需要手动 convertRect（挂键盘窗口时靠 convertRect
        // 定位，窗口位移而 page 未 layout 就会把栏留在键盘按键行上）。
        // KayokoHelper 的预测栏注入已在 ctor 关闭，page 上不会再有第二份文案。
        NSUInteger purged = 0;
        for (UIView *subview in [page.window.subviews copy]) {
            if ([subview isKindOfClass:[KBCKayokoPredictionBar class]] && subview != bar) {
                [subview removeFromSuperview];
                purged++;
            }
        }
        for (UIView *subview in [page.subviews copy]) {
            if ([subview isKindOfClass:[KBCKayokoPredictionBar class]] && subview != bar) {
                [subview removeFromSuperview];
                purged++;
            }
        }
        [page addSubview:bar];
        bar.frame = page.bounds;
        kbc_log([NSString stringWithFormat:
            @"kayoko bar attach page=%p bar=%p host=%@ purged=%lu",
            page, bar, NSStringFromClass([page class]), (unsigned long)purged]);
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:bar action:@selector(kbc_pageTap:)];
        tap.cancelsTouchesInView = YES;
        tap.delaysTouchesEnded = YES;
        [page addGestureRecognizer:tap];
        objc_setAssociatedObject(page, &sKayokoPredictionTapKey, tap,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    kbc_updateKayokoPage(page, @"page-layout");
    // 统计 page 内与键盘窗口上的 bar 实例数（窗口层才是权威口径）。
    NSUInteger pageBars = 0, windowBars = 0;
    for (UIView *subview in page.subviews)
        if ([subview isKindOfClass:[KBCKayokoPredictionBar class]]) pageBars++;
    for (UIView *subview in page.window.subviews)
        if ([subview isKindOfClass:[KBCKayokoPredictionBar class]]) windowBars++;
    unsigned int countSeq = __sync_fetch_and_add(&sKayokoMigrateLogCount, 1);
    if (countSeq < 80) {
        kbc_log([NSString stringWithFormat:
            @"kayoko pagebars page=%p pageBars=%lu windowBars=%lu subviews=%lu window=%@",
            page, (unsigned long)pageBars, (unsigned long)windowBars,
            (unsigned long)page.subviews.count,
            NSStringFromClass([page.window class])]);
    }
}

static id kbc_kayokoPageHitTest(id self, SEL command, CGPoint point, UIEvent *event) {
    KBCKayokoPredictionBar *bar = objc_getAssociatedObject(self, &sKayokoPredictionBarKey);
    if (bar) {
        unsigned int hitSeq = __sync_fetch_and_add(&sKayokoHitLogCount, 1);
        if (hitSeq < 40) {
            kbc_log([NSString stringWithFormat:
                @"kayoko hit seq=%u page=%p bar=%p hidden=%d alpha=%.2f super=%@ frame=(%.1f,%.1f,%.1f,%.1f) window=%@ point=(%.1f,%.1f)",
                hitSeq, self, bar, bar.hidden, bar.alpha,
                NSStringFromClass([bar.superview class]),
                bar.frame.origin.x, bar.frame.origin.y,
                bar.frame.size.width, bar.frame.size.height,
                NSStringFromClass([bar.window class]), point.x, point.y]);
        }
    }
    if (bar && !bar.hidden && bar.userInteractionEnabled) {
        CGPoint barPoint = [bar convertPoint:point fromView:self];
        UIView *hit = [bar hitTest:barPoint withEvent:event];
        if (hit) return hit;
    }
    return sOrigKayokoPageHitTest
        ? ((id(*)(id, SEL, CGPoint, id))sOrigKayokoPageHitTest)(self, command, point, event) : nil;
}

@implementation KBCUnderDockStackView

- (instancetype)initWithShortcuts:(NSArray<NSString *> *)shortcuts
              enabledDockGestures:(BOOL)enabledDockGestures {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    self.tintColor = UIColor.systemBlueColor;
    self.userInteractionEnabled = YES;
    self.axis = UILayoutConstraintAxisHorizontal;
    self.distribution = UIStackViewDistributionFillEqually;
    self.alignment = UIStackViewAlignmentFill;
    self.spacing = 10.0;

    NSUInteger count = 0;
    for (NSString *shortcut in shortcuts) {
        if (count >= 6 || ![kbc_supportedShortcuts() containsObject:shortcut]) continue;
        NSArray<NSString *> *parts = [shortcut componentsSeparatedByString:@"|"];
        if (parts.count != 2) continue;
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        UIImage *image = [UIImage systemImageNamed:parts.lastObject];
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:16.0
                                                            weight:UIImageSymbolWeightHeavy
                                                             scale:UIImageSymbolScaleLarge];
        [button setImage:[image imageByApplyingSymbolConfiguration:configuration]
                forState:UIControlStateNormal];
        button.tag = parts.firstObject.integerValue;
        [button addTarget:self action:@selector(kbc_buttonPress:)
         forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(kbc_buttonLongPress:)];
        [button addGestureRecognizer:longPress];
        [self addArrangedSubview:button];
        count++;
    }
    if (enabledDockGestures) {
        for (NSNumber *direction in @[@(UISwipeGestureRecognizerDirectionLeft),
                                       @(UISwipeGestureRecognizerDirectionRight)]) {
            UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc]
                initWithTarget:self action:@selector(kbc_underDockSwipe:)];
            swipe.direction = direction.unsignedIntegerValue;
            [self addGestureRecognizer:swipe];
        }
    }
    kbc_log([NSString stringWithFormat:@"underdock create buttons=%lu gestures=%d framePolicy=leading72,trailing-72,bottom-20,height42",
        (unsigned long)count, enabledDockGestures]);
    return self;
}

- (void)setTintColor:(UIColor *)tintColor {
    [super setTintColor:tintColor];
    for (UIView *view in self.arrangedSubviews)
        if ([view isKindOfClass:[UIButton class]]) view.tintColor = tintColor;
}

- (void)kbc_buttonPress:(UIButton *)button {
    [self kbc_performAction:button.tag longPress:NO];
}

- (void)kbc_buttonLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan)
        [self kbc_performAction:recognizer.view.tag longPress:YES];
}

- (void)kbc_underDockSwipe:(UISwipeGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateEnded)
        [self kbc_performAction:6 longPress:NO];
}

- (void)kbc_performAction:(NSInteger)tag longPress:(BOOL)longPress {
    id keyboard = kbc_keyboardImpl();
    SEL inputDelegateSelector = sel_registerName("inputDelegate");
    id delegate = keyboard && [keyboard respondsToSelector:inputDelegateSelector]
        ? ((id(*)(id, SEL))objc_msgSend)(keyboard, inputDelegateSelector) : nil;
    id<UITextInput> input = [delegate conformsToProtocol:@protocol(UITextInput)] ? delegate : nil;
    BOOL executed = NO;

    switch (tag) {
        case 0:
            executed = kbc_sendAction(delegate, longPress ? "selectAll:" : "select:");
            break;
        case 1:
            executed = kbc_sendAction(delegate, longPress ? "cut:" : "copy:");
            break;
        case 2:
            @try {
                if (!longPress) {
                    executed = kbc_sendAction(delegate, "paste:");
                } else {
                    NSURL *url = [NSURL URLWithString:UIPasteboard.generalPasteboard.string ?: @""];
                    BOOL isWebURL = url.scheme.length > 0 && url.host.length > 0;
                    executed = kbc_sendAction(delegate,
                        isWebURL ? "pasteAndGo:" : "pasteAndSearch:");
                }
            } @catch (__unused NSException *exception) {
                executed = kbc_sendAction(delegate, "paste:");
            }
            break;
        case 3:
        case 4:
            if (longPress && input) {
                UITextPosition *position = tag == 3 ? input.beginningOfDocument : input.endOfDocument;
                input.selectedTextRange = [input textRangeFromPosition:position toPosition:position];
                SEL caretSelector = sel_registerName("setCaretBlinks:");
                if ([keyboard respondsToSelector:caretSelector])
                    ((void(*)(id, SEL, BOOL))objc_msgSend)(keyboard, caretSelector, YES);
                executed = YES;
            } else {
                SEL movement = sel_registerName(tag == 3
                    ? "_moveToStartOfLine:withHistory:" : "_moveToEndOfLine:withHistory:");
                if ([delegate respondsToSelector:movement]) {
                    ((void(*)(id, SEL, BOOL, id))objc_msgSend)(delegate, movement, NO, nil);
                    executed = YES;
                }
            }
            break;
        case 5: {
            executed = kbc_activateKayoko(self);
            break;
        }
        case 6: {
            SEL dismissSelector = sel_registerName("dismissKeyboard");
            if ([keyboard respondsToSelector:dismissSelector]) {
                ((void(*)(id, SEL))objc_msgSend)(keyboard, dismissSelector);
                executed = YES;
            }
            break;
        }
        case 7: {
            NSUndoManager *manager = [delegate respondsToSelector:@selector(undoManager)]
                ? ((id(*)(id, SEL))objc_msgSend)(delegate, @selector(undoManager)) : nil;
            if (manager.canUndo) { [manager undo]; executed = YES; }
            break;
        }
        case 8: {
            NSUndoManager *manager = [delegate respondsToSelector:@selector(undoManager)]
                ? ((id(*)(id, SEL))objc_msgSend)(delegate, @selector(undoManager)) : nil;
            if (manager.canRedo) { [manager redo]; executed = YES; }
            break;
        }
        default:
            break;
    }
    kbc_underDockHaptic(longPress, tag == 0 && !longPress);
    unsigned int sequence = __sync_fetch_and_add(&sUnderDockLogCount, 1);
    if (sequence < 32) {
        kbc_log([NSString stringWithFormat:@"underdock action seq=%u tag=%ld long=%d executed=%d delegate=%@",
            sequence, (long)tag, longPress, executed, NSStringFromClass([delegate class])]);
    }
}

@end

static NSDictionary *kbc_underDockPreferences(void) {
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.p2kdev.underdock.plist"];
    return [preferences isKindOfClass:[NSDictionary class]] ? preferences : @{};
}

static id kbc_dockInitWithFrame(id self, SEL command, CGRect frame) {
    id dock = sOrigDockInitWithFrame
        ? ((id(*)(id, SEL, CGRect))sOrigDockInitWithFrame)(self, command, frame) : self;
    if (!dock || kbc_underDockForDock(dock)) return dock;
    NSDictionary *preferences = kbc_underDockPreferences();
    NSArray *shortcuts = [preferences[@"shortcuts"] isKindOfClass:[NSArray class]]
        ? preferences[@"shortcuts"] : kbc_defaultShortcuts();
    BOOL gestures = preferences[@"dismissGestureEnabled"]
        ? [preferences[@"dismissGestureEnabled"] boolValue] : YES;
    KBCUnderDockStackView *underDock = [[KBCUnderDockStackView alloc]
        initWithShortcuts:shortcuts enabledDockGestures:gestures];
    objc_setAssociatedObject(dock, &sUnderDockViewKey, underDock, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    underDock.translatesAutoresizingMaskIntoConstraints = NO;
    [dock addSubview:underDock];
    [NSLayoutConstraint activateConstraints:@[
        [underDock.leadingAnchor constraintEqualToAnchor:[dock leadingAnchor] constant:72.0],
        [underDock.trailingAnchor constraintEqualToAnchor:[dock trailingAnchor] constant:-72.0],
        [underDock.heightAnchor constraintEqualToConstant:42.0],
        [underDock.bottomAnchor constraintEqualToAnchor:[dock bottomAnchor] constant:-20.0]
    ]];
    return dock;
}

static void kbc_dockLayoutSubviews(id self, SEL command) {
    if (sOrigDockLayoutSubviews)
        ((void(*)(id, SEL))sOrigDockLayoutSubviews)(self, command);
    KBCUnderDockStackView *underDock = kbc_underDockForDock(self);
    for (UIView *view in underDock.arrangedSubviews)
        if ([view isKindOfClass:[UIButton class]]) view.tintColor = underDock.tintColor;
}

static void kbc_updateUnderDockTintFromItem(id dock, id item) {
    SEL buttonSelector = sel_registerName("button");
    id button = [item respondsToSelector:buttonSelector]
        ? ((id(*)(id, SEL))objc_msgSend)(item, buttonSelector) : nil;
    UIColor *tint = [button respondsToSelector:@selector(tintColor)]
        ? ((id(*)(id, SEL))objc_msgSend)(button, @selector(tintColor)) : nil;
    if (tint) [kbc_underDockForDock(dock) setTintColor:tint];
}

static void kbc_dockSetLeftItem(id self, SEL command, id item) {
    kbc_updateUnderDockTintFromItem(self, item);
    if (sOrigDockSetLeftItem)
        ((void(*)(id, SEL, id))sOrigDockSetLeftItem)(self, command, item);
}

static void kbc_dockSetRightItem(id self, SEL command, id item) {
    kbc_updateUnderDockTintFromItem(self, item);
    if (sOrigDockSetRightItem)
        ((void(*)(id, SEL, id))sOrigDockSetRightItem)(self, command, item);
}

static void kbc_dockVisibility(id self, SEL command) {
    if (sOrigDockVisibility)
        ((void(*)(id, SEL))sOrigDockVisibility)(self, command);
    id dock = kbc_objectGetter(self, "dockView");
    id centerItem = kbc_objectGetter(dock, "centerDockItem");
    id centerView = kbc_objectGetter(centerItem, "view");
    BOOL centerVisible = centerView && ![centerView isHidden];
    BOOL landscape = UIInterfaceOrientationIsLandscape(UIApplication.sharedApplication.statusBarOrientation);
    KBCUnderDockStackView *underDock = kbc_underDockForDock(dock);
    underDock.hidden = centerVisible || landscape;
    unsigned int sequence = __sync_fetch_and_add(&sUnderDockLogCount, 1);
    if (sequence < 32) {
        kbc_log([NSString stringWithFormat:@"underdock visibility seq=%u centerVisible=%d landscape=%d hidden=%d",
            sequence, centerVisible, landscape, underDock.hidden]);
    }
}

static BOOL kbc_selectionGestureShouldBegin(id self, SEL command, UIGestureRecognizer *recognizer) {
    if ([NSStringFromClass([recognizer.view class]) isEqualToString:@"UIKeyboardDockView"])
        return NO;
    return sOrigSelectionGestureShouldBegin
        ? ((BOOL(*)(id, SEL, id))sOrigSelectionGestureShouldBegin)(self, command, recognizer) : YES;
}

static NSString *kbc_kayokoObjectValueSummary(id object) {
    if (!object) return @"nil";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *name in @[@"inputMode", @"activeInputMode", @"currentInputMode",
                              @"inputModeIdentifier", @"currentInputModeIdentifier",
                              @"keyboardInputMode", @"primaryLanguage"]) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) continue;
        @try {
            id value = ((id(*)(id, SEL))objc_msgSend)(object, selector);
            if (value) [parts addObject:[NSString stringWithFormat:@"%@=%@", name, value]];
        } @catch (__unused NSException *exception) {}
    }
    return parts.count ? [parts componentsJoinedByString:@" "] : @"unavailable";
}

static NSString *kbc_kayokoInputModeSummary(void) {
    return kbc_kayokoObjectValueSummary(kbc_keyboardImpl());
}

static NSString *kbc_kayokoListSummary(id list) {
    if (!list) return @"nil";
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:NSStringFromClass([list class])];
    for (NSString *name in @[@"autocorrection", @"predictions", @"emojiList", @"candidates"]) {
        SEL selector = NSSelectorFromString(name);
        if (![list respondsToSelector:selector]) continue;
        @try {
            id value = ((id(*)(id, SEL))objc_msgSend)(list, selector);
            NSUInteger count = [value respondsToSelector:@selector(count)] ? [value count] : (value ? 1 : 0);
            NSString *sample = @"";
            if ([value isKindOfClass:[NSArray class]] && count) {
                NSArray *array = value;
                sample = [NSString stringWithFormat:@" sample=%@", array[0]];
            }
            [parts addObject:[NSString stringWithFormat:@"%@=%lu%@", name, (unsigned long)count, sample]];
        } @catch (__unused NSException *exception) {}
    }
    return [parts componentsJoinedByString:@" "];
}

static BOOL kbc_kayokoListHasCandidates(id list) {
    if (!list) return NO;
    for (NSString *name in @[@"candidates", @"predictions", @"autocorrection"]) {
        SEL selector = NSSelectorFromString(name);
        if (![list respondsToSelector:selector]) continue;
        @try {
            id value = ((id(*)(id, SEL))objc_msgSend)(list, selector);
            if ([value respondsToSelector:@selector(count)] && [value count] > 0) return YES;
            if (value && ![value respondsToSelector:@selector(count)]) return YES;
        } @catch (__unused NSException *exception) {}
    }
    return NO;
}

static void kbc_installKayokoPageHooksIfAvailable(NSString *source) {
    if (sKayokoPageHookInstalled) return;
    Class pageClass = objc_getClass("TUISystemInputAssistantPageView");
    Method layoutMethod = pageClass
        ? class_getInstanceMethod(pageClass, @selector(layoutSubviews)) : NULL;
    if (!layoutMethod) return;

    MSHookMessageEx(pageClass, @selector(layoutSubviews),
        (IMP)kbc_kayokoPageLayout, &sOrigKayokoPageLayout);
    Method hitTestMethod = class_getInstanceMethod(pageClass, @selector(hitTest:withEvent:));
    if (hitTestMethod) {
        MSHookMessageEx(pageClass, @selector(hitTest:withEvent:),
            (IMP)kbc_kayokoPageHitTest, &sOrigKayokoPageHitTest);
    }
    sKayokoPageHookInstalled = YES;
    kbc_log([NSString stringWithFormat:
        @"hook feature=kayoko-pagebar-once source=%@ layout=%s hitTest=%s",
        source, method_getTypeEncoding(layoutMethod),
        hitTestMethod ? method_getTypeEncoding(hitTestMethod) : "missing"]);
}

static void kbc_kayokoProbeSetKeyplaneName(id self, SEL command, NSString *name) {
    if (sOrigKayokoProbeSetKeyplaneName)
        ((void(*)(id, SEL, id))sOrigKayokoProbeSetKeyplaneName)(self, command, name);
    unsigned int sequence = __sync_fetch_and_add(&sKayokoProbeLogCount, 1);
    if (sequence < 64) {
        sKayokoProbeKeyplane = [name copy];
        kbc_log([NSString stringWithFormat:
            @"kayoko-probe seq=%u keyplane=%@ input=%@ layout=%@",
            sequence, name, kbc_kayokoInputModeSummary(), NSStringFromClass([self class])]);
    }
    kbc_installKayokoPageHooksIfAvailable(@"keyplane");
    if (!sKayokoCandidateCollectionHookInstalled) {
        Class candidateClass = objc_getClass("TUICandidateCollectionView");
        Method method = candidateClass
            ? class_getInstanceMethod(candidateClass, @selector(layoutSubviews)) : NULL;
        if (method) {
            MSHookMessageEx(candidateClass, @selector(layoutSubviews),
                (IMP)kbc_kayokoCandidateCollectionLayout,
                &sOrigKayokoCandidateCollectionLayout);
            sKayokoCandidateCollectionHookInstalled = YES;
            kbc_log([NSString stringWithFormat:
                @"hook feature=kayoko-candidate-content class=%@ layout=%s",
                NSStringFromClass(candidateClass), method_getTypeEncoding(method)]);
        }
    }
    if (!sKayokoPredictionContentHookInstalled) {
        Class predictionClass = objc_getClass("TUIPredictionViewStackContentView");
        Method method = predictionClass
            ? class_getInstanceMethod(predictionClass, @selector(layoutSubviews)) : NULL;
        if (method) {
            MSHookMessageEx(predictionClass, @selector(layoutSubviews),
                (IMP)kbc_kayokoPredictionContentLayout,
                &sOrigKayokoPredictionContentLayout);
            sKayokoPredictionContentHookInstalled = YES;
            kbc_log([NSString stringWithFormat:
                @"hook feature=kayoko-prediction-content class=%@ layout=%s",
                NSStringFromClass(predictionClass), method_getTypeEncoding(method)]);
        }
    }
}


static void kbc_kayokoProbeSetAutocorrectionList(id self, SEL command, id list) {
    sKayokoHasSystemCandidates = kbc_kayokoListHasCandidates(list);
    unsigned int sequence = __sync_fetch_and_add(&sKayokoListProbeLogCount, 1);
    if (sequence < 160) {
        kbc_log([NSString stringWithFormat:
            @"kayoko-list seq=%u keyplane=%@ controller=%@<%p> has=%d host=%p mode={%@} list={%@}",
            sequence, sKayokoProbeKeyplane ?: @"unknown", NSStringFromClass([self class]),
            self, sKayokoHasSystemCandidates, sKayokoHostView,
            kbc_kayokoObjectValueSummary(self), kbc_kayokoListSummary(list)]);
    }
    if (sOrigKayokoProbeSetAutocorrectionList)
        ((void(*)(id, SEL, id))sOrigKayokoProbeSetAutocorrectionList)(self, command, list);
    dispatch_async(dispatch_get_main_queue(), ^{
        [sKayokoHostView setNeedsLayout];
    });
}


static void kbc_hookAndLog(const char *className, const char *selectorName,
                           IMP replacement, IMP *original, NSString *feature) {
    Class cls = objc_getClass(className);
    SEL selector = sel_registerName(selectorName);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : "missing";
    kbc_log([NSString stringWithFormat:@"hook feature=%@ method=%s.%s encoding=%s",
        feature, className, selectorName, encoding]);
    if (method) MSHookMessageEx(cls, selector, replacement, original);
}

static void installIntegratedHooks(void) {
    kbc_hookAndLog("UIKeyboard", "displayLayer:", (IMP)kbc_oledKeyboardDisplayLayer,
        &sOrigOLEDKeyboardDisplayLayer, @"oled");
    kbc_hookAndLog("UIPredictionViewController", "_currentTextSuggestions",
        (IMP)kbc_oledPredictionSuggestions, &sOrigOLEDPredictionSuggestions, @"oled");
    kbc_hookAndLog("UIKeyboardDockView", "layoutSubviews", (IMP)kbc_oledDockLayout,
        &sOrigOLEDDockLayout, @"oled");
    kbc_hookAndLog("UIInputView", "layoutSubviews", (IMP)kbc_oledInputLayout,
        &sOrigOLEDInputLayout, @"oled");
    kbc_hookAndLog("UIKBVisualEffectView", "layoutSubviews", (IMP)kbc_oledEffectLayout,
        &sOrigOLEDEffectLayout, @"oled");

    // Chaining order is intentional: UnderDock's layout hook calls the OLED
    // replacement above as its original, preserving both integrations.
    kbc_hookAndLog("UIKeyboardDockView", "initWithFrame:", (IMP)kbc_dockInitWithFrame,
        &sOrigDockInitWithFrame, @"underdock");
    kbc_hookAndLog("UIKeyboardDockView", "layoutSubviews", (IMP)kbc_dockLayoutSubviews,
        &sOrigDockLayoutSubviews, @"underdock");
    kbc_hookAndLog("UIKeyboardDockView", "setLeftDockItem:", (IMP)kbc_dockSetLeftItem,
        &sOrigDockSetLeftItem, @"underdock");
    kbc_hookAndLog("UIKeyboardDockView", "setRightDockItem:", (IMP)kbc_dockSetRightItem,
        &sOrigDockSetRightItem, @"underdock");
    kbc_hookAndLog("UISystemKeyboardDockController", "updateDockItemsVisibility",
        (IMP)kbc_dockVisibility, &sOrigDockVisibility, @"underdock");
    kbc_hookAndLog("_UIKeyboardTextSelectionInteraction", "gestureRecognizerShouldBegin:",
        (IMP)kbc_selectionGestureShouldBegin, &sOrigSelectionGestureShouldBegin, @"underdock");
    kbc_hookAndLog("UIKeyboardLayoutStar", "setKeyplaneName:",
        (IMP)kbc_kayokoProbeSetKeyplaneName, &sOrigKayokoProbeSetKeyplaneName, @"kayoko-probe");
    kbc_hookAndLog("UIKeyboardAutocorrectionController", "setAutocorrectionList:",
        (IMP)kbc_kayokoProbeSetAutocorrectionList, &sOrigKayokoProbeSetAutocorrectionList,
        @"kayoko-list-probe");
    kbc_installKayokoPageHooksIfAvailable(@"constructor");
    kbc_installKayokoTextDiagnostics();
    kbc_log(@"install integrated=oledkeyboard+underdock+kayoko defaults=6 shortcuts");
}

static void installHooks(void) {
    Class cls = objc_getClass("UIKBKeyplaneView");
    SEL selector = sel_registerName("displayLayer:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : "missing";
    kbc_log([NSString stringWithFormat:@"hook method=UIKBKeyplaneView.displayLayer: encoding=%s", encoding]);
    if (method && strcmp(encoding, "v24@0:8@16") == 0)
        MSHookMessageEx(cls, selector, (IMP)kbc_displayLayer, &sOrigDisplayLayer);

    Class keyClass = objc_getClass("UIKBKeyView");
    SEL keyDisplaySelector = sel_registerName("displayLayer:");
    Method keyDisplayMethod = keyClass ? class_getInstanceMethod(keyClass, keyDisplaySelector) : NULL;
    const char *keyDisplayEncoding = keyDisplayMethod ? method_getTypeEncoding(keyDisplayMethod) : "missing";
    kbc_log([NSString stringWithFormat:@"hook method=UIKBKeyView.displayLayer: encoding=%s", keyDisplayEncoding]);
    if (keyDisplayMethod && strcmp(keyDisplayEncoding, "v24@0:8@16") == 0)
        MSHookMessageEx(keyClass, keyDisplaySelector, (IMP)kbc_keyDisplayLayer, &sOrigKeyDisplayLayer);

    SEL flagsSelector = sel_registerName("layerForRenderFlags:");
    Method flagsMethod = keyClass ? class_getInstanceMethod(keyClass, flagsSelector) : NULL;
    const char *flagsEncoding = flagsMethod ? method_getTypeEncoding(flagsMethod) : "missing";
    kbc_log([NSString stringWithFormat:@"hook method=layerForRenderFlags: encoding=%s", flagsEncoding]);
    if (flagsMethod && strcmp(flagsEncoding, "@24@0:8q16") == 0)
        MSHookMessageEx(keyClass, flagsSelector, (IMP)kbc_layerForRenderFlags, &sOrigLayerForFlags);

    SEL populateSelector = sel_registerName("_populateLayer:withContents:");
    Method populateMethod = keyClass ? class_getInstanceMethod(keyClass, populateSelector) : NULL;
    const char *populateEncoding = populateMethod ? method_getTypeEncoding(populateMethod) : "missing";
    kbc_log([NSString stringWithFormat:@"hook method=_populateLayer:withContents: encoding=%s", populateEncoding]);
    if (populateMethod && strcmp(populateEncoding, "v32@0:8@16@24") == 0)
        MSHookMessageEx(keyClass, populateSelector, (IMP)kbc_populateLayer, &sOrigPopulateLayer);
    kbc_log(@"install mode=background+shadow-removal-classifier");
}

// Kayoko 原版（KayokoHelper）在激活方式为「预测栏」时，会把 历史/拷贝/粘贴
// 作为候选塞进系统预测栏（其 Root.plist 原话：displays custom suggestions on
// the "More Keyboard Keyplane" (123)）。这与本插件自绘的同名三按钮落在同一
// 位置，差几像素叠成「厝臾」式重影，且只在 123 页出现。这里把 ActivationMethod
// 的预测栏位清零（9 -> 8，仅保留编辑菜单），面板入口与自动粘贴均不受影响。
static void kbc_neutralizeKayokoPredictionBar(void) {
    NSString *suite = @"/var/mobile/Library/Preferences/codes.aurora.kayoko.preferences.plist";
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    if (!defaults) return;
    NSInteger method = [defaults integerForKey:@"ActivationMethod"];
    if ((method & 1) == 0) return;
    NSInteger updated = method & ~1;
    [defaults setInteger:updated forKey:@"ActivationMethod"];
    [defaults synchronize];
    kbc_log([NSString stringWithFormat:
        @"kayoko activation-method neutralize %ld -> %ld (prediction-bar injection off)",
        (long)method, (long)updated]);
}

__attribute__((constructor)) static void kbc_ctor(void) {
    kbc_log([NSString stringWithFormat:@"ctor version=%s", KBC_VERSION]);
    kbc_neutralizeKayokoPredictionBar();
    kbc_installKayokoCoreOrientationDiagnostics();
    installHooks();
    installIntegratedHooks();
}
