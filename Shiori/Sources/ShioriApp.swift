import AppKit
import SwiftUI

@main
struct ShioriApp: App {
    @NSApplicationDelegateAdaptor(ShioriApplicationDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @StateObject private var updater = ShioriUpdater()

    var body: some Scene {
        WindowGroup(AppInfo.name) {
            RootView(store: store, checkForUpdates: updater.checkForUpdates, canCheckForUpdates: updater.canCheckForUpdates)
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
                .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}
