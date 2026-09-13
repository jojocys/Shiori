import AppKit
import Combine
import Sparkle

/// Sparkle 控制器必须与 App 同生命周期，才能负责后台检查、下载安装、替换和重启。
@MainActor
final class ShioriUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    private var resumeInstallation: (() -> Void)?
    @Published private(set) var canCheckForUpdates = true

    init(startingUpdater: Bool = true) {
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        observation = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            Task { @MainActor in self?.canCheckForUpdates = change.newValue ?? false }
        }
        if startingUpdater { controller?.startUpdater() }
    }

    func checkForUpdates() {
        if resumeInstallation != nil {
            continueInstallation()
            return
        }
        guard let controller else {
            UpdateInstallationGate.show("检查更新不可用", "请使用安装到应用程序目录的 Shiori 正式 App。源码运行不支持应用内更新。")
            return
        }
        guard controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        // The installer can subsequently install on ordinary quit, even after a dismissed alert.
        UpdateInstallationGate.shared.arm()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        UpdateInstallationGate.shared.arm()
        resumeInstallation = installHandler
        continueInstallation()
        return true
    }

    private func continueInstallation() {
        guard resumeInstallation != nil, !UpdateInstallationGate.shared.isChecking else { return }
        Task {
            if await UpdateInstallationGate.shared.allowInstallation(), let resume = resumeInstallation {
                resumeInstallation = nil
                resume()
            } else {
                // Reuse the visible Check Updates entries as an explicit retry action.
                canCheckForUpdates = true
            }
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        resumeInstallation = nil
        UpdateInstallationGate.shared.disarm()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // A successful cycle may have staged an install-on-quit. Keep its termination guard armed.
        if error != nil { UpdateInstallationGate.shared.disarm(); resumeInstallation = nil }
    }
}
