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

enum SilentUpdateSchedule {
    static let interval: TimeInterval = 24 * 60 * 60

    static func delaySinceLastCheck(_ lastCheck: Date?, now: Date = Date()) -> TimeInterval {
        guard let lastCheck else { return 0 }
        return max(0, interval - now.timeIntervalSince(lastCheck))
    }
}

/// Information probes have a stricter busy condition than Sparkle's menu UI.
/// A displayed update window can accept menu clicks while its session is active.
@MainActor
protocol UpdateInformationClient: AnyObject {
    var canCheckForUpdates: Bool { get }
    var sessionInProgress: Bool { get }
    /// Returns whether a new probe was accepted; no state changes on a no-op.
    func startInformationCheck() -> Bool
}

@MainActor
private final class SparkleUpdateInformationClient: UpdateInformationClient {
    private let updater: SPUUpdater

    init(updater: SPUUpdater) { self.updater = updater }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
    var sessionInProgress: Bool { updater.sessionInProgress }

    func startInformationCheck() -> Bool {
        guard canCheckForUpdates, !sessionInProgress else { return false }
        updater.checkForUpdateInformation()
        return updater.sessionInProgress
    }
}

private enum UpdateInformationProbeResult {
    case started
    case busy
    case unavailable
}

/// Sparkle controller and the toolbar's update state share the app lifetime.
@MainActor
final class ShioriUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private static let lastSilentCheckKey = "ShioriUpdater.lastSilentCheckDate"
    private static let busyRetryInterval: TimeInterval = 60

    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    private var resumeInstallation: (() -> Void)?
    private var installationAttempt: UUID?
    private var installationTask: Task<Void, Never>?
    private var availableUpdateVersion: String?
    private var automaticCheckTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var informationClient: (any UpdateInformationClient)?
    private var stateBeforeInformationProbe: UpdateToolbarState?
    private let updateDefaults: UserDefaults
    private let currentDate: () -> Date
    private let silentCheckScheduler: ((TimeInterval) -> Void)?
    private let installationGate: UpdateInstallationGate

    @Published private(set) var canCheckForUpdates = true
    @Published private(set) var toolbarState: UpdateToolbarState = .idle
    @Published private(set) var toolbarToast: UpdateToolbarToast?

    init(startingUpdater: Bool = true) {
        updateDefaults = .standard
        currentDate = Date.init
        silentCheckScheduler = nil
        installationGate = .shared
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        if let updater = controller?.updater {
            informationClient = SparkleUpdateInformationClient(updater: updater)
        }
        observation = controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            Task { @MainActor in self?.canCheckForUpdates = change.newValue ?? false }
        }
        if startingUpdater {
            controller?.startUpdater()
            configureSilentAutomaticChecks()
        }
    }

    /// Headless dependency injection: does not construct or start Sparkle's UI.
    init(informationClient: any UpdateInformationClient,
         initialState: UpdateToolbarState = .idle,
         defaults: UserDefaults,
         now: @escaping () -> Date,
         scheduleSilentCheck: @escaping (TimeInterval) -> Void,
         installationGate: UpdateInstallationGate? = nil) {
        self.informationClient = informationClient
        updateDefaults = defaults
        currentDate = now
        silentCheckScheduler = scheduleSilentCheck
        self.installationGate = installationGate ?? .shared
        super.init()
        toolbarState = initialState
        canCheckForUpdates = informationClient.canCheckForUpdates
    }

    deinit {
        installationTask?.cancel()
        automaticCheckTask?.cancel()
        stateTask?.cancel()
        toastTask?.cancel()
    }

    /// Sparkle's scheduled checks use its standard alert window. Shiori owns the
    /// 24-hour schedule instead and only performs information probes, so an
    /// automatic result can update the toolbar without presenting a window.
    private func configureSilentAutomaticChecks() {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = false
        let lastCheck = updateDefaults.object(forKey: Self.lastSilentCheckKey) as? Date
        scheduleSilentAutomaticCheck(after: SilentUpdateSchedule.delaySinceLastCheck(lastCheck))
    }

    private func scheduleSilentAutomaticCheck(after delay: TimeInterval) {
        automaticCheckTask?.cancel()
        if let silentCheckScheduler {
            silentCheckScheduler(delay)
            return
        }
        automaticCheckTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            self?.performSilentAutomaticCheck()
        }
    }

    func performSilentAutomaticCheck() {
        switch probeForUpdates(showUnavailableAlert: false) {
        case .busy:
            scheduleSilentAutomaticCheck(after: Self.busyRetryInterval)
        case .started:
            updateDefaults.set(currentDate(), forKey: Self.lastSilentCheckKey)
            scheduleSilentAutomaticCheck(after: SilentUpdateSchedule.interval)
        case .unavailable:
            break
        }
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

    @discardableResult
    private func probeForUpdates(showUnavailableAlert: Bool = true) -> UpdateInformationProbeResult {
        guard let informationClient else {
            if showUnavailableAlert {
                UpdateInstallationGate.show("检查更新不可用", "请使用安装到应用程序目录的 Shiori 正式 App。源码运行不支持应用内更新。")
            }
            return .unavailable
        }
        guard informationClient.canCheckForUpdates, !informationClient.sessionInProgress else { return .busy }
        let previousState = toolbarState
        guard informationClient.startInformationCheck() else { return .busy }
        stateBeforeInformationProbe = previousState
        canCheckForUpdates = informationClient.canCheckForUpdates
        transition(to: .checking)
        return .started
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
        installationGate.arm()
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
        postponeInstallation(untilInvoking: installHandler)
    }

    /// Shared by Sparkle's one-shot Install button and headless regression tests.
    func postponeInstallation(untilInvoking installHandler: @escaping () -> Void) -> Bool {
        cancelInstallationAttempt()
        installationGate.arm()
        resumeInstallation = installHandler
        transition(to: .downloaded)
        // Sparkle's standard button consumes its callback on the first click.
        // Defer until this delegate returns, then complete our safety checks
        // and invoke the saved handler without requiring another UI action.
        continueInstallation()
        return true
    }

    private func continueInstallation() {
        guard resumeInstallation != nil, installationAttempt == nil else { return }
        let attempt = UUID()
        installationAttempt = attempt
        let gate = installationGate
        installationTask = Task { [weak self] in
            // A pending Quit may already be inspecting activity. Wait for that
            // bounded check rather than dropping the one-shot Install request.
            while gate.isChecking {
                guard !Task.isCancelled, self?.installationAttempt == attempt else { return }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
            guard !Task.isCancelled, self?.installationAttempt == attempt else { return }
            let allowed = await gate.allowInstallation()
            guard let self, !Task.isCancelled, self.installationAttempt == attempt else { return }
            self.installationAttempt = nil
            self.installationTask = nil
            if allowed, let resume = self.resumeInstallation {
                self.resumeInstallation = nil
                resume()
            } else {
                // Failed safety checks deliberately leave the restart action visible.
                self.toolbarState = .downloaded
                self.canCheckForUpdates = true
            }
        }
    }

    private func cancelInstallationAttempt() {
        installationTask?.cancel()
        installationTask = nil
        installationAttempt = nil
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        showFailureUnlessInstallationIsReady()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        handleUpdateAbort(error)
    }

    func handleUpdateAbort(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain && nsError.code == 1_001 {
            if toolbarState != .hidden && toolbarState != .upToDate { showUpToDateThenHide() }
            return
        }
        if resumeInstallation != nil || installationAttempt != nil || toolbarState.isDownloaded {
            // A genuine session abort invalidates Sparkle's continuation. An
            // unrelated informational failure still preserves a staged update.
            cancelInstallationAttempt()
            resumeInstallation = nil
            installationGate.disarm()
            stateTask?.cancel()
            toolbarState = .failed
            showToast(.failed, duration: .milliseconds(1_600))
            return
        }
        showFailureUnlessInstallationIsReady()
    }

    private func showFailureUnlessInstallationIsReady() {
        guard !toolbarState.isDownloaded else { return }
        cancelInstallationAttempt()
        resumeInstallation = nil
        installationGate.disarm()
        transition(to: .failed)
        showToast(.failed, duration: .milliseconds(1_600))
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finishUpdateCycle(error: error)
    }

    /// Both the delegate and headless clients complete through the same state path.
    func finishUpdateCycle(error: Error?) {
        let previousState = stateBeforeInformationProbe
        stateBeforeInformationProbe = nil
        if let informationClient { canCheckForUpdates = informationClient.canCheckForUpdates }
        guard let error else {
            if toolbarState == .checking { transition(to: previousState ?? .idle) }
            return
        }
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
