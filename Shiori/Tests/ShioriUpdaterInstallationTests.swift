import XCTest
@testable import Shiori

@MainActor
final class ShioriUpdaterInstallationTests: XCTestCase {
    func testStandardInstallClickAutomaticallyChecksSavesAndResumesOnce() async {
        let gate = UpdateInstallationGate()
        gate.roots = { ["/tmp/isolated-update-test"] }
        gate.probe = { _ in [] }
        var events: [String] = []
        gate.saveBeforeExit = { events.append("save") }
        gate.reportProblem = { _, _ in XCTFail("No problem is expected") }
        let updater = makeUpdater(gate: gate)
        var returnedFromDelegate = false
        XCTAssertTrue(updater.postponeInstallation {
            XCTAssertTrue(returnedFromDelegate, "Resume only after Sparkle accepts postponement")
            events.append("resume")
        })
        returnedFromDelegate = true
        let completed = await eventually { events == ["save", "resume"] }
        XCTAssertTrue(completed, "One standard Install click must resume without a second menu or toolbar action")
        updater.checkForUpdates()
        updater.checkForUpdatesFromToolbar()
        await Task.yield()
        XCTAssertEqual(events, ["save", "resume"])
    }

    func testRunningGameBlocksInstallAndMenuRetryUsesTheSameHandler() async {
        let fixture = fixture()
        fixture.gate.probe = { _ in [UpdateActivity(pid: 7, name: "fake-game")] }
        let updater = makeUpdater(gate: fixture.gate)
        _ = updater.postponeInstallation { fixture.events.append("resume") }
        let blocked = await eventually { fixture.problems.count == 1 && updater.canCheckForUpdates }
        XCTAssertTrue(blocked)
        XCTAssertTrue(fixture.events.isEmpty)
        XCTAssertTrue(fixture.gate.blocksLaunch)
        XCTAssertEqual(updater.toolbarState, .downloaded)
        XCTAssertTrue(fixture.problems[0].contains("重启以更新"))
        fixture.gate.probe = { _ in [] }
        updater.checkForUpdates()
        let resumed = await eventually { fixture.events == ["save", "resume"] }
        XCTAssertTrue(resumed)
    }

    func testProbeFailureCanRetryFromToolbarWithoutSavingOrResumingEarly() async {
        let fixture = fixture()
        fixture.gate.probe = { _ in throw UpdateSafetyError.probeFailed("controlled failure") }
        let updater = makeUpdater(gate: fixture.gate)
        _ = updater.postponeInstallation { fixture.events.append("resume") }
        let blocked = await eventually { fixture.problems.count == 1 && updater.canCheckForUpdates }
        XCTAssertTrue(blocked)
        XCTAssertTrue(fixture.events.isEmpty)
        XCTAssertEqual(updater.toolbarState, .downloaded)
        fixture.gate.probe = { _ in [] }
        updater.checkForUpdatesFromToolbar()
        let resumed = await eventually { fixture.events == ["save", "resume"] }
        XCTAssertTrue(resumed)
    }

    func testFailedSaveKeepsContinuationForSuccessfulRetry() async {
        let fixture = fixture()
        fixture.gate.saveBeforeExit = { throw UpdateSafetyError.probeFailed("controlled disk failure") }
        let updater = makeUpdater(gate: fixture.gate)
        _ = updater.postponeInstallation { fixture.events.append("resume") }
        let blocked = await eventually { fixture.problems.count == 1 && updater.canCheckForUpdates }
        XCTAssertTrue(blocked)
        XCTAssertTrue(fixture.events.isEmpty)
        fixture.gate.saveBeforeExit = { fixture.events.append("save") }
        updater.checkForUpdatesFromToolbar()
        let resumed = await eventually { fixture.events == ["save", "resume"] }
        XCTAssertTrue(resumed)
    }

    func testRepeatedActionsShareOneProbeAndResumeExactlyOnce() async {
        let fixture = fixture()
        let probe = SuspendedInstallationProbe()
        fixture.gate.probe = { _ in try await probe.inspect() }
        let updater = makeUpdater(gate: fixture.gate)
        _ = updater.postponeInstallation { fixture.events.append("resume") }
        updater.checkForUpdates()
        updater.checkForUpdatesFromToolbar()
        let started = await probe.waitForCalls(1)
        XCTAssertTrue(started)
        updater.checkForUpdates()
        updater.checkForUpdatesFromToolbar()
        await probe.release([])
        let resumed = await eventually { fixture.events == ["save", "resume"] }
        XCTAssertTrue(resumed)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }

    func testInstallRequestWaitsForAnExistingSafetyCheck() async {
        let fixture = fixture()
        let probe = SuspendedInstallationProbe()
        fixture.gate.probe = { _ in try await probe.inspect() }
        let existing = Task { await fixture.gate.allowInstallation() }
        let checking = await probe.waitForCalls(1)
        XCTAssertTrue(checking)
        let updater = makeUpdater(gate: fixture.gate)
        _ = updater.postponeInstallation { fixture.events.append("resume") }
        XCTAssertTrue(fixture.events.isEmpty)
        await probe.release([])
        _ = await existing.value
        let started = await probe.waitForCalls(2)
        XCTAssertTrue(started)
        XCTAssertFalse(fixture.events.contains("resume"))
        await probe.release([])
        let resumed = await eventually { fixture.events.last == "resume" }
        XCTAssertTrue(resumed)
        XCTAssertEqual(fixture.events.filter { $0 == "resume" }.count, 1)
    }

    func testAbortedSessionCannotSaveOrResumeAfterProbeCompletes() async {
        let fixture = fixture()
        let probe = SuspendedInstallationProbe()
        fixture.gate.probe = { _ in try await probe.inspect() }
        let updater = makeUpdater(gate: fixture.gate)
        _ = updater.postponeInstallation { fixture.events.append("stale-resume") }
        let started = await probe.waitForCalls(1)
        XCTAssertTrue(started)
        updater.handleUpdateAbort(NSError(domain: "ControlledAbort", code: 1))
        await probe.release([])
        let finished = await eventually { !fixture.gate.isChecking }
        XCTAssertTrue(finished)
        XCTAssertTrue(fixture.events.isEmpty)
        XCTAssertTrue(fixture.problems.isEmpty)
        XCTAssertEqual(updater.toolbarState, .failed)
        XCTAssertFalse(fixture.gate.blocksLaunch)
    }

    func testInformationFailurePreservesAStagedInstallation() async {
        let fixture = fixture()
        let probe = SuspendedInstallationProbe()
        fixture.gate.probe = { _ in try await probe.inspect() }
        let updater = makeUpdater(gate: fixture.gate)
        _ = updater.postponeInstallation { fixture.events.append("resume") }
        let started = await probe.waitForCalls(1)
        XCTAssertTrue(started)
        updater.finishUpdateCycle(error: NSError(domain: "ControlledInformationFailure", code: 1))
        XCTAssertEqual(updater.toolbarState, .downloaded)
        XCTAssertTrue(fixture.gate.blocksLaunch)
        await probe.release([])
        let resumed = await eventually { fixture.events == ["save", "resume"] }
        XCTAssertTrue(resumed)
    }

    func testReplacingSessionDiscardsOldContinuationAndRechecksBeforeResumingNewOne() async {
        let fixture = fixture()
        let probe = SuspendedInstallationProbe()
        fixture.gate.probe = { _ in try await probe.inspect() }
        let updater = makeUpdater(gate: fixture.gate)
        _ = updater.postponeInstallation { fixture.events.append("stale-resume") }
        let first = await probe.waitForCalls(1)
        XCTAssertTrue(first)
        _ = updater.postponeInstallation { fixture.events.append("new-resume") }
        await probe.release([])
        let second = await probe.waitForCalls(2)
        XCTAssertTrue(second)
        XCTAssertTrue(fixture.events.isEmpty)
        await probe.release([])
        let resumed = await eventually { fixture.events == ["save", "new-resume"] }
        XCTAssertTrue(resumed)
    }

    private func fixture() -> InstallationFixture {
        let fixture = InstallationFixture()
        fixture.gate.roots = { ["/tmp/isolated-update-test"] }
        fixture.gate.probe = { _ in [] }
        fixture.gate.saveBeforeExit = { [weak fixture] in fixture?.events.append("save") }
        fixture.gate.reportProblem = { [weak fixture] title, message in fixture?.problems.append(title + message) }
        return fixture
    }

    private func makeUpdater(gate: UpdateInstallationGate) -> ShioriUpdater {
        ShioriUpdater(informationClient: InstallationInformationClient(),
                      defaults: InstallationDefaults(), now: Date.init,
                      scheduleSilentCheck: { _ in }, installationGate: gate)
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        return predicate()
    }
}

@MainActor
private final class InstallationFixture {
    let gate = UpdateInstallationGate()
    var events: [String] = []
    var problems: [String] = []
}

private actor SuspendedInstallationProbe {
    private(set) var calls = 0
    private var pending: [CheckedContinuation<[UpdateActivity], Error>] = []
    func inspect() async throws -> [UpdateActivity] {
        calls += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func release(_ activities: [UpdateActivity]) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: activities)
    }
    func waitForCalls(_ count: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while calls < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        return calls >= count
    }
}

@MainActor
private final class InstallationInformationClient: UpdateInformationClient {
    var canCheckForUpdates = false
    var sessionInProgress = true
    func startInformationCheck() -> Bool { XCTFail("Installation must not start another check"); return false }
}

private final class InstallationDefaults: UserDefaults, @unchecked Sendable {
    override func object(forKey defaultName: String) -> Any? { nil }
    override func set(_ value: Any?, forKey defaultName: String) { XCTFail("No preferences should be written") }
}
