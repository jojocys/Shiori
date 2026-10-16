#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <crt_externs.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <limits.h>

static NSDictionary *iconPaths;
static NSImage *selectedIcon;
static NSArray *steamRoots;
static NSString *steamLockPath;
static NSString *steamIconPath;
static int steamLock = -1;
static BOOL wantsSteamDock;
static dispatch_source_t promotionTimer;
static void (*originalSetIcon)(id, SEL, NSImage *);
static BOOL (*originalSetPolicy)(id, SEL, NSApplicationActivationPolicy);

static NSString *executableArgument(void) {
    char **argv = *_NSGetArgv();
    for (int i = 0; i < *_NSGetArgc(); i++) {
        // Wine can shorten argv without updating the host runtime's argc.
        if (!argv[i]) break;
        NSString *argument = [[NSString stringWithUTF8String:argv[i]]
            stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if (!argument) continue;
        NSRange suffix = [argument rangeOfString:@".exe" options:NSCaseInsensitiveSearch];
        if (suffix.location == NSNotFound) continue;
        // Wine rewrites argv[0] to its Windows command line. Stop at the
        // first executable; never match --launcher or -steampath arguments.
        NSString *path = [argument substringToIndex:NSMaxRange(suffix)];
        path = [path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
        if (![path hasPrefix:@"/"] && !(path.length >= 2 && [path characterAtIndex:1] == ':')) {
            path = [[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:path] stringByStandardizingPath];
        }
        return path.precomposedStringWithCanonicalMapping.lowercaseString;
    }
    return nil;
}

static int steamRole(void);
static NSImage *gameIcon(void) {
    if (selectedIcon) return selectedIcon;
    NSString *path = iconPaths[executableArgument() ?: @""];
    if (!path && steamRole() == 1) path = steamIconPath;
    if ([path isKindOfClass:[NSString class]]) {
        selectedIcon = [[NSImage alloc] initWithContentsOfFile:path];
    }
    return selectedIcon;
}

// Only the client and helper executables under the configured Steam directory
// participate. Games, other prefixes and unrelated Wine launches are excluded.
static int steamRole(void) {
    NSString *path = executableArgument();
    if (!path) return 0;
    BOOL inSteam = NO;
    for (id root in steamRoots) {
        if ([root isKindOfClass:[NSString class]] && [path hasPrefix:root]) { inSteam = YES; break; }
    }
    if (!inSteam) return 0;
    NSString *name = path.lastPathComponent;
    if ([name isEqualToString:@"steam.exe"] || [name isEqualToString:@"steamwebhelper.exe"]) return 1;
    if ([name isEqualToString:@"gameoverlayui.exe"] || [name isEqualToString:@"steamerrorreporter.exe"] ||
        [name isEqualToString:@"steamerrorreporter64.exe"]) return 2;
    return 0;
}

static void releaseSteamDock(void) {
    if (steamLock >= 0) { close(steamLock); steamLock = -1; }
}

static BOOL claimSteamDock(void) {
    if (steamLock >= 0) return YES;
    if (!steamLockPath.length) return NO;
    int fd = open(steamLockPath.fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return YES; // Keep the original visible entry if the cache is unavailable.
    if (flock(fd, LOCK_EX | LOCK_NB)) {
        int error = errno;
        close(fd);
        return error != EWOULDBLOCK && error != EAGAIN;
    }
    steamLock = fd;
    return YES;
}

static void managedSetIcon(id app, SEL selector, NSImage *image) {
    originalSetIcon(app, selector, gameIcon() ?: image);
}

static BOOL managedSetPolicy(id app, SEL selector, NSApplicationActivationPolicy policy) {
    int role = steamRole();
    if (role) {
        wantsSteamDock = role == 1 && policy == NSApplicationActivationPolicyRegular;
        if (!wantsSteamDock) releaseSteamDock();
        if (policy == NSApplicationActivationPolicyRegular && (role == 2 || !claimSteamDock())) {
            policy = NSApplicationActivationPolicyAccessory;
        }
    }
    BOOL result = originalSetPolicy(app, selector, policy);
    if (!result && role) releaseSteamDock();
    if (result && policy == NSApplicationActivationPolicyRegular) {
        // Reapply after Wine's foreground conversion. Games retain their own
        // Dock/keyboard/exit policy; no window activation is performed here.
        dispatch_async(dispatch_get_main_queue(), ^{
            NSImage *image = gameIcon();
            if (image) originalSetIcon(app, @selector(setApplicationIconImage:), image);
        });
    }
    return result;
}

__attribute__((constructor)) static void configureWineDockIcons(void) {
    @autoreleasepool {
        const char *config = getenv("SHIORI_WINE_DOCK_ICONS");
        if (!config) return;
#ifndef SHIORI_WINE_DOCK_TESTING
        // A Windows program may spawn a native helper inheriting its env.
        // Never alter that helper's AppKit presentation.
        char executable[PATH_MAX];
        uint32_t length = sizeof(executable);
        if (_NSGetExecutablePath(executable, &length)) return;
        NSString *name = [NSString stringWithUTF8String:executable].lastPathComponent;
        if (![@[@"wine", @"wine64", @"wine-preloader", @"wine64-preloader"] containsObject:name]) return;
#endif
        NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:config]];
        if (!data) return;
        id document = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![document isKindOfClass:[NSDictionary class]] || ![document[@"icons"] isKindOfClass:[NSDictionary class]]) return;
        iconPaths = document[@"icons"];
        if ([document[@"steamRoots"] isKindOfClass:[NSArray class]]) steamRoots = document[@"steamRoots"];
        if ([document[@"steamLockPath"] isKindOfClass:[NSString class]]) steamLockPath = document[@"steamLockPath"];
        if ([document[@"steamIconPath"] isKindOfClass:[NSString class]]) steamIconPath = document[@"steamIconPath"];
        Method icon = class_getInstanceMethod([NSApplication class], @selector(setApplicationIconImage:));
        Method policy = class_getInstanceMethod([NSApplication class], @selector(setActivationPolicy:));
        if (!icon || !policy) return;
        originalSetIcon = (void *)method_getImplementation(icon);
        originalSetPolicy = (void *)method_getImplementation(policy);
        method_setImplementation(icon, (IMP)managedSetIcon);
        method_setImplementation(policy, (IMP)managedSetPolicy);
        // If the owner exits, promote another visible Steam window without
        // activating it. The OS releases flock even after an abnormal exit.
        promotionTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(promotionTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
        dispatch_source_set_event_handler(promotionTimer, ^{
            if (!wantsSteamDock || steamLock >= 0 || !NSApp) return;
            BOOL visible = NO;
            for (NSWindow *window in NSApp.windows) {
                if (window.isVisible && (window.canBecomeKeyWindow || window.canBecomeMainWindow)) { visible = YES; break; }
            }
            if (visible && claimSteamDock()) {
                if (!originalSetPolicy(NSApp, @selector(setActivationPolicy:), NSApplicationActivationPolicyRegular)) releaseSteamDock();
            }
        });
        dispatch_resume(promotionTimer);
    }
}
