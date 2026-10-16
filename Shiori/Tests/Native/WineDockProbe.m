// Headless integration harness: records the adapter's AppKit calls using
// fake callbacks, without creating NSApplication or displaying a Dock entry.
#define SHIORI_WINE_DOCK_TESTING 1
#import "../../Native/WineDock.m"
#include <stdio.h>

static NSApplicationActivationPolicy observedPolicy;
static NSImage *observedIcon;
static BOOL recordPolicy(id app, SEL selector, NSApplicationActivationPolicy policy) {
    observedPolicy = policy;
    return YES;
}
static void recordIcon(id app, SEL selector, NSImage *image) { observedIcon = image; }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && !strcmp(argv[1], "--truncated")) argv[1] = NULL;
        originalSetPolicy = recordPolicy;
        originalSetIcon = recordIcon;
        NSObject *app = [NSObject new];
        NSImage *fallback = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
        managedSetPolicy(app, @selector(setActivationPolicy:), NSApplicationActivationPolicyRegular);
        managedSetIcon(app, @selector(setApplicationIconImage:), fallback);
        printf("{\"role\":%d,\"policy\":%ld,\"gameIcon\":%s}\n", steamRole(),
            (long)observedPolicy, observedIcon != fallback ? "true" : "false");
        fflush(stdout);
        if (argc > 2) usleep((unsigned int)(atof(argv[2]) * 1000000));
        return 0;
    }
}
