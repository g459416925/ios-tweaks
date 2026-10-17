#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <ptrauth.h>
#import <stdio.h>

int main(void) {
    @autoreleasepool {
        void *handle = dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", RTLD_NOW);
        if (!handle) {
            fprintf(stderr, "dlopen failed: %s\n", dlerror());
            return 1;
        }

        Class tree = objc_getClass("UIKBTree");
        Method method = class_getInstanceMethod(tree, sel_registerName("setClipCorners:"));
        if (!method) {
            fprintf(stderr, "UIKBTree/setClipCorners missing\n");
            return 2;
        }

        void *implementation = (void *)method_getImplementation(method);
#if __has_feature(ptrauth_calls)
        implementation = ptrauth_strip(implementation, ptrauth_key_function_pointer);
#endif
        Dl_info info = {0};
        if (!dladdr(implementation, &info) || !info.dli_fbase) {
            fprintf(stderr, "dladdr failed\n");
            return 3;
        }

        uintptr_t base = (uintptr_t)info.dli_fbase;
        uintptr_t start = base + 0xaa3800;
        size_t length = 0x1000;
        FILE *output = fopen("/var/tmp/UIKitCore-aa3800-aa4800.bin", "wb");
        if (!output) {
            perror("fopen");
            return 4;
        }
        size_t written = fwrite((const void *)start, 1, length, output);
        fclose(output);
        printf("base=%p imp=%p impOffset=0x%lx start=%p written=%zu\n",
               info.dli_fbase, implementation,
               (unsigned long)((uintptr_t)implementation - base),
               (void *)start, written);
        return written == length ? 0 : 5;
    }
}
