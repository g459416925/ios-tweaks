// KBKeyProbe4 0.1.7 — bounded, read-only keyplane snapshot.
// Evidence from 0.1.6 proved that keysOrderedByPosition and
// geometriesOrderedByPosition are aligned arrays on keyplanes 429/430.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <string.h>

extern void MSHookMessageEx(Class cls, SEL sel, IMP newImp, IMP *oldImp);

static void p4_log(NSString *line) {
    NSString *full = [NSString stringWithFormat:@"[kbp4:%d] %@", getpid(), line];
    FILE *fp = fopen("/var/mobile/Documents/kbc_kp.log", "a");
    if (!fp) fp = fopen("/var/tmp/kbc_kp.log", "a");
    if (fp) { fprintf(fp, "%s\n", full.UTF8String); fclose(fp); }
}

static const char *p4_type(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static Method p4_getter(id obj, const char *name) {
    if (!obj || !name) return NULL;
    Method method = class_getInstanceMethod(object_getClass(obj), sel_registerName(name));
    return method && method_getNumberOfArguments(method) == 2 ? method : NULL;
}

static id p4_object(id obj, const char *name) {
    Method method = p4_getter(obj, name);
    if (!method) return nil;
    char type[128] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (p4_type(type)[0] != '@') return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName(name)); }
    @catch (NSException *exception) { return nil; }
}

static NSString *p4_string(id obj, const char *name) {
    id value = p4_object(obj, name);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *p4_scalar(id obj, const char *name) {
    Method method = p4_getter(obj, name);
    if (!method) return @"NA";
    char typeBuffer[256] = {0};
    method_getReturnType(method, typeBuffer, sizeof(typeBuffer));
    const char *type = p4_type(typeBuffer);
    SEL selector = sel_registerName(name);
    @try {
        if (!strcmp(type, @encode(BOOL)) || type[0] == 'B' || type[0] == 'c')
            return [NSString stringWithFormat:@"%d", ((BOOL (*)(id, SEL))objc_msgSend)(obj, selector) ? 1 : 0];
        if (strchr("CsSiIlLqQ", type[0]))
            return [NSString stringWithFormat:@"%lld", ((long long (*)(id, SEL))objc_msgSend)(obj, selector)];
        if (type[0] == 'f')
            return [NSString stringWithFormat:@"%.4f", (double)((float (*)(id, SEL))objc_msgSend)(obj, selector)];
        if (type[0] == 'd')
            return [NSString stringWithFormat:@"%.4f", ((double (*)(id, SEL))objc_msgSend)(obj, selector)];

        NSMethodSignature *signature = [obj methodSignatureForSelector:selector];
        if (!signature) return [NSString stringWithFormat:@"type=%s", type];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = obj;
        invocation.selector = selector;
        [invocation invoke];
        if (!strcmp(type, @encode(CGRect))) {
            CGRect value = CGRectZero; [invocation getReturnValue:&value];
            return NSStringFromCGRect(value);
        }
        if (!strcmp(type, @encode(CGSize))) {
            CGSize value = CGSizeZero; [invocation getReturnValue:&value];
            return NSStringFromCGSize(value);
        }
        if (!strcmp(type, @encode(CGPoint))) {
            CGPoint value = CGPointZero; [invocation getReturnValue:&value];
            return NSStringFromCGPoint(value);
        }
        return [NSString stringWithFormat:@"type=%s", type];
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"EX:%@", exception.name];
    }
}

static void p4_append_fields(id obj, NSMutableString *line, const char **fields, NSUInteger count) {
    for (NSUInteger index = 0; index < count; index++) {
        if (p4_getter(obj, fields[index]))
            [line appendFormat:@" %s=%@", fields[index], p4_scalar(obj, fields[index])];
    }
}

static void p4_append_geometry(id geometryNode, NSMutableString *line) {
    if (!geometryNode) { [line appendString:@" geomNode=nil"]; return; }
    [line appendFormat:@" geomNode=%p/%@ geomNodeName=%@", geometryNode,
        NSStringFromClass([geometryNode class]), p4_string(geometryNode, "name") ?: @"(null)"];
    const char *nodeFields[] = {"visible", "disabled", "state", "clipCorners"};
    p4_append_fields(geometryNode, line, nodeFields, sizeof(nodeFields) / sizeof(nodeFields[0]));

    id renderGeometry = p4_object(geometryNode, "geometry");
    if (!renderGeometry && [NSStringFromClass([geometryNode class]) rangeOfString:@"Geometry"].location != NSNotFound)
        renderGeometry = geometryNode;
    if (!renderGeometry) { [line appendString:@" renderGeometry=nil"]; return; }
    [line appendFormat:@" renderGeometry=%p/%@", renderGeometry, NSStringFromClass([renderGeometry class])];
    const char *geometryFields[] = {"frame", "paddedFrame", "bounds", "origin", "size",
        "roundRectRadius", "roundRectCorners", "layeredBackgroundRoundRectRadius",
        "layeredForegroundRoundRectRadius", "cornerRadius"};
    p4_append_fields(renderGeometry, line, geometryFields,
                     sizeof(geometryFields) / sizeof(geometryFields[0]));
}

static void p4_snapshot(id keyplane) {
    NSString *plane = p4_string(keyplane, "name") ?: @"(null)";
    Method keysMethod = p4_getter(keyplane, "keysOrderedByPosition");
    Method geometriesMethod = p4_getter(keyplane, "geometriesOrderedByPosition");
    p4_log([NSString stringWithFormat:@"SNAPSHOT017-BEGIN plane=%@ keyplane=%p keysEnc=%s geometriesEnc=%s",
        plane, keyplane, keysMethod ? method_getTypeEncoding(keysMethod) : "missing",
        geometriesMethod ? method_getTypeEncoding(geometriesMethod) : "missing"]);

    id keysValue = p4_object(keyplane, "keysOrderedByPosition");
    id geometriesValue = p4_object(keyplane, "geometriesOrderedByPosition");
    NSArray *keys = [keysValue isKindOfClass:[NSArray class]] ? keysValue : nil;
    NSArray *geometries = [geometriesValue isKindOfClass:[NSArray class]] ? geometriesValue : nil;
    p4_log([NSString stringWithFormat:@"SNAPSHOT017-COUNTS plane=%@ keysClass=%@ keys=%lu geometriesClass=%@ geometries=%lu",
        plane, NSStringFromClass([keysValue class]), (unsigned long)keys.count,
        NSStringFromClass([geometriesValue class]), (unsigned long)geometries.count]);

    NSUInteger count = MIN(keys.count, (NSUInteger)80);
    for (NSUInteger index = 0; index < count; index++) {
        id key = keys[index];
        id geometry = index < geometries.count ? geometries[index] : nil;
        NSMutableString *line = [NSMutableString stringWithFormat:
            @"SNAPSHOT017-KEY plane=%@ idx=%lu key=%p/%@ name=%@",
            plane, (unsigned long)index, key, NSStringFromClass([key class]),
            p4_string(key, "name") ?: @"(null)"];
        const char *keyFields[] = {"visible", "disabled", "ghost", "displayType", "displayRowHint",
            "_renderAsStringKey", "shouldCacheKey", "state", "clipCorners", "isLeafType"};
        p4_append_fields(key, line, keyFields, sizeof(keyFields) / sizeof(keyFields[0]));
        p4_append_geometry(geometry, line);
        p4_log(line);
    }
    p4_log([NSString stringWithFormat:@"SNAPSHOT017-END plane=%@ dumped=%lu geometryDelta=%ld",
        plane, (unsigned long)count, (long)geometries.count - (long)keys.count]);
}

static IMP p4_original_traits;
static NSMutableSet<NSString *> *p4_seen;

static id p4_traits(id self, SEL command, id key, id keyplane) {
    id result = p4_original_traits
        ? ((id (*)(id, SEL, id, id))p4_original_traits)(self, command, key, keyplane)
        : nil;
    @try {
        NSString *plane = p4_string(keyplane, "name");
        if (plane && [plane rangeOfString:@"Numbers-And-Punctuation"].location != NSNotFound) {
            if (!p4_seen) p4_seen = [NSMutableSet set];
            NSString *identity = [NSString stringWithFormat:@"%d|%@", getpid(), plane];
            BOOL first = NO;
            @synchronized (p4_seen) {
                if (![p4_seen containsObject:identity]) { [p4_seen addObject:identity]; first = YES; }
            }
            if (first) {
                p4_log([NSString stringWithFormat:@"SNAPSHOT017-SCHEDULE plane=%@ triggerKey=%@",
                    plane, p4_string(key, "name")]);
                dispatch_async(dispatch_get_main_queue(), ^{ p4_snapshot(keyplane); });
            }
        }
    } @catch (NSException *exception) {
        p4_log([NSString stringWithFormat:@"SNAPSHOT017-EX exception=%@", exception]);
    }
    return result;
}

static void p4_install(void) {
    Class factory = objc_getClass("UIKBRenderFactory");
    SEL selector = sel_registerName("traitsForKey:onKeyplane:");
    Method method = factory ? class_getInstanceMethod(factory, selector) : NULL;
    if (method && !p4_original_traits) {
        p4_log([NSString stringWithFormat:@"traits method enc=%s", method_getTypeEncoding(method)]);
        MSHookMessageEx(factory, selector, (IMP)p4_traits, &p4_original_traits);
        p4_log(@"traitsForKey hook installed (bounded read-only mode 0.1.7)");
    } else if (!method) p4_log(@"traitsForKey hook unavailable");
}

__attribute__((constructor)) static void p4_ctor(void) {
    p4_log(@"ctor version=0.1.7");
    @try { p4_install(); } @catch (NSException *exception) {}
    dispatch_async(dispatch_get_main_queue(), ^{ @try { p4_install(); } @catch (NSException *exception) {} });
}
