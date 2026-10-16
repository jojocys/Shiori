#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Keep the upstream emulator intact; the signed launcher applies Shiori's
// presentation adapter only to the sibling runtime in this bundle.
int main(int argc, char **argv) {
    char raw[PATH_MAX], path[PATH_MAX], library[PATH_MAX];
    uint32_t size = sizeof(raw);
    if (_NSGetExecutablePath(raw, &size) || !realpath(raw, path)) return 1;
    char *slash = strrchr(path, '/');
    if (!slash) return 1;
    *slash = '\0';
    if (snprintf(library, sizeof(library), "%s/libShioriSwitchDock.dylib", path) >= sizeof(library)) return 1;
    char executable[PATH_MAX];
    if (snprintf(executable, sizeof(executable), "%s/Ryujinx", path) >= sizeof(executable)) return 1;
    if (access(library, R_OK) || access(executable, X_OK)) return 1;
    if (setenv("DYLD_INSERT_LIBRARIES", library, 1)) return 1;
    argv[0] = executable;
    execv(executable, argv);
    fprintf(stderr, "Shiori Switch launch failed: %s\n", strerror(errno));
    return 1;
}
