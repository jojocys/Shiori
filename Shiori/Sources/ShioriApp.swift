import AppKit
import SwiftUI

@main
struct ShioriApp: App {
    /// The unified toolbar starts at the detail column edge while the home
    /// content is inset by 24 pt. The Unicode spacing below gives the native
    /// title the same visual inset as the home section header.
    private static let alignedWindowTitle = "\u{2003}\u{2002}\u{2004}\(AppInfo.name)"

    @NSApplicationDelegateAdaptor(ShioriApplicationDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @StateObject private var updater = ShioriUpdater()

    var body: some Scene {
        WindowGroup(Self.alignedWindowTitle) {
            RootView(store: store, updater: updater)
                .onAppear { store.configureUpdateSafety() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(
                    for: NSWorkspace.didActivateApplicationNotification
                )) { notification in
                    guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                    store.handleWorkspaceApplicationActivation(application)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加游戏文件夹") {
                    store.chooseAndScanGameFolder()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("开始游戏") {
                    store.startGame()
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }

            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    updater.checkForUpdates()
                }
                .disabled(!(updater.canCheckForUpdates || updater.toolbarState.isDownloaded))
            }
        }
    }
}
