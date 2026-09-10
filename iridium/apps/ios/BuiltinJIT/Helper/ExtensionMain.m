#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// NSExtension's input decoder omits the XPC endpoint class. Extend that one
// allow-list entry; unlike the reference proposal, never disable class validation.
static void (*originalValidation)(id, SEL, Class, id, BOOL);
static void validateEndpoint(id decoder, SEL selector, Class cls, id key, BOOL invocations) {
    if (cls == NSXPCListenerEndpoint.class && !invocations) return;
    originalValidation(decoder, selector, cls, key, invocations);
}
__attribute__((used, visibility("default")))
int NSExtensionMain(int argc, char **argv) {
    Class decoder = NSClassFromString(@"NSXPCDecoder");
    SEL selector = NSSelectorFromString(@"_validateAllowedClass:forKey:allowingInvocations:");
    Method method = class_getInstanceMethod(decoder, selector);
    int (*entry)(int, char **) = dlsym(RTLD_NEXT, "NSExtensionMain");
    if (!method || !entry) return 70; // Fail closed if Apple's private interface changes.
    originalValidation = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)validateEndpoint);
    return entry(argc, argv);
}
