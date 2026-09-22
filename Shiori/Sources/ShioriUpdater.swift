import AppKit
import Combine
import Sparkle

enum UpdateToolbarState: Equatable {
    case idle
    case checking
    case upToDate
    case hidden
    case available(version: String)
    case downloading
    case downloaded
    case failed

    var isHidden: Bool {
        if case .hidden = self { return true }
        return false
    }

    var isDownloaded: Bool {
        if case .downloaded = self { return true }
        return false
    }

    var acceptsInteraction: Bool {
        switch self {
        case .checking, .upToDate, .hidden, .downloading: return false
        case .idle, .available, .downloaded, .failed: return true
        }
    }

    /// A staged update must remain actionable even if a later probe fails.
    func preservingDownloadedState(when proposedState: UpdateToolbarState) -> UpdateToolbarState {
        isDownloaded ? self : proposedState
    }
}

enum UpdateToolbarToastKind: Equatable {
    case upToDate
    case failed
}

struct UpdateToolbarToast: Equatable, Identifiable {
    let id = UUID()
    let kind: UpdateToolbarToastKind

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind
    }
}

/// Sparkle controller and the toolbar's update state share the app lifetime.
@MainActor
final class ShioriUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    private var resumeInstallation: (() -> Void)?
    private var availableUpdateVersion: String?
    private var stateTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    @Published private(set) var canCheckForUpdates = true
    @Published private(set) var toolbarState: UpdateToolbarState = .idle
    @Published private(set) var toolbarToast: UpdateToolbarToast?

    init(startingUpdater: Bool = true) {
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        observation = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            Task { @MainActor in self?.canCheckForUpdates = change.newValue ?? false }
        }
        if startingUpdater { controller?.startUpdater() }
    }

    deinit {
        stateTask?.cancel()
        toastTask?.cancel()
    }

    /// Toolbar checks are informational: no Sparkle window is shown merely to say
    /// that the current version is already up to date.
    func checkForUpdatesFromToolbar() {
        switch toolbarState {
        case .downloaded:
            continueInstallation()
        case .available:
            showStandardUpdateWindow()
        case .idle, .failed:
            probeForUpdates()
        case .checking, .upToDate, .hidden, .downloading:
            break
        }
    }

    /// The application-menu command always remains available as the conventional
    /// way to bring Sparkle's standard update UI into focus.
    func checkForUpdates() {
        if toolbarState.isDownloaded || resumeInstallation != nil {
            continueInstallation()
            return
        }
        guard let controller else {
            UpdateInstallationGate.show("检查更新不可用", "请使用安装到应用程序目录的 Shiori 正式 App。源码运行不支持应用内更新。")
            return
        }
        guard controller.updater.canCheckForUpdates else { return }
        // If Sparkle already owns an update/progress session, this action only
        // brings its standard window forward; no fresh delegate callback follows.
        // Keep the toolbar's meaningful state instead of stranding it at checking.
        switch toolbarState {
        case .available, .downloading:
            break
        default:
            transition(to: .checking)
        }
        controller.checkForUpdates(nil)
    }

    private func probeForUpdates() {
        guard let controller else {
            UpdateInstallationGate.show("检查更新不可用", "请使用安装到应用程序目录的 Shiori 正式 App。源码运行不支持应用内更新。")
            return
        }
        guard controller.updater.canCheckForUpdates else { return }
        transition(to: .checking)
        controller.updater.checkForUpdateInformation()
    }

    private func showStandardUpdateWindow() {
        guard let controller, controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    private func transition(to proposedState: UpdateToolbarState) {
        stateTask?.cancel()
        toolbarState = toolbarState.preservingDownloadedState(when: proposedState)
    }

    private func showToast(_ kind: UpdateToolbarToastKind, duration: Duration) {
        toastTask?.cancel()
        toolbarToast = UpdateToolbarToast(kind: kind)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.toolbarToast = nil }
        }
    }

    private func showUpToDateThenHide() {
        transition(to: .upToDate)
        showToast(.upToDate, duration: .milliseconds(1_200))
        stateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.toolbarState == .upToDate else { return }
                self?.toolbarState = .hidden
            }
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableUpdateVersion = item.displayVersionString
        transition(to: .available(version: item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        showUpToDateThenHide()
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        transition(to: .downloading)
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        UpdateInstallationGate.shared.arm()
        transition(to: .downloading)
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        guard let availableUpdateVersion else {
            transition(to: .idle)
            return
        }
        transition(to: .available(version: availableUpdateVersion))
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        UpdateInstallationGate.shared.arm()
        resumeInstallation = installHandler
        transition(to: .downloaded)
        return true
    }

    private func continueInstallation() {
        guard resumeInstallation != nil, !UpdateInstallationGate.shared.isChecking else { return }
        Task {
            if await UpdateInstallationGate.shared.allowInstallation(), let resume = resumeInstallation {
                resumeInstallation = nil
                resume()
            } else {
                // Failed safety checks deliberately leave the restart action visible.
                toolbarState = .downloaded
                canCheckForUpdates = true
            }
        }
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        showFailureUnlessInstallationIsReady()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain && nsError.code == 1_001 {
            if toolbarState != .hidden && toolbarState != .upToDate { showUpToDateThenHide() }
            return
        }
        showFailureUnlessInstallationIsReady()
    }

    private func showFailureUnlessInstallationIsReady() {
        guard !toolbarState.isDownloaded else { return }
        resumeInstallation = nil
        UpdateInstallationGate.shared.disarm()
        transition(to: .failed)
        showToast(.failed, duration: .milliseconds(1_600))
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain && nsError.code == 1_001 { return }
        showFailureUnlessInstallationIsReady()
    }

    // Every scheduled update uses the toolbar as a gentle reminder and never
    // steals focus. The user opens Sparkle's standard window explicitly.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        availableUpdateVersion = update.displayVersionString
        transition(to: .available(version: update.displayVersionString))
    }
}
