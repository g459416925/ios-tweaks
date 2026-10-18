// DLISafeKVC.m
#import "DLISafeKVC.h"

id DLISafeValue(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(object), key.UTF8String);
    if (iv) {
        const char *enc = ivar_getTypeEncoding(iv);
        if (enc && enc[0] == '@') return object_getIvar(object, iv);
        return nil;
    }
    SEL selector = NSSelectorFromString(key);
    if ([object respondsToSelector:selector]) {
        @try {
            return [object valueForKey:key];
        } @catch (__unused NSException *e) {
            return nil;
        }
    }
    return nil;
}
