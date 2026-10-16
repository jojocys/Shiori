import AppKit

/// Routes Shiori's Dock entry to the bundled game's accessory window.
/// Matching the exact bundle path excludes separately installed emulators.
@MainActor
enum SwitchDockIntegration {
    static var runningApplication: NSRunningApplication? {
        guard let bundle = SwitchRuntime.resolveBundledEmulator(),
              let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              info["ShioriManagedSwitchRuntime"] as? Bool == true else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.bundleURL?.standardizedFileURL == bundle.standardizedFileURL
        }
    }

    @discardableResult
    static func showGameWindow() -> Bool {
        guard let app = runningApplication else { return false }
        return app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
}
