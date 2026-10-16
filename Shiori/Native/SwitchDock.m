#import <AppKit/AppKit.h>
#import <objc/runtime.h>

// Avalonia requests Regular even for an LSUIElement bundle. Enforce the
// accessory policy only in a helper explicitly marked by Shiori's packager.
static BOOL (*originalSetActivationPolicy)(id, SEL, NSApplicationActivationPolicy);
static BOOL managedSetActivationPolicy(id app, SEL selector, NSApplicationActivationPolicy policy) {
    if (policy == NSApplicationActivationPolicyRegular) {
        policy = NSApplicationActivationPolicyAccessory;
    }
    return originalSetActivationPolicy(app, selector, policy);
}

__attribute__((constructor)) static void configureShioriSwitchDock(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] objectForInfoDictionaryKey:@"ShioriManagedSwitchRuntime"] boolValue]) {
            return;
        }
        Method method = class_getInstanceMethod([NSApplication class], @selector(setActivationPolicy:));
        if (!method) return;
        originalSetActivationPolicy = (void *)method_getImplementation(method);
        method_setImplementation(method, (IMP)managedSetActivationPolicy);
        fprintf(stderr, "[Shiori] Switch runtime uses accessory Dock policy\n");
    }
}
