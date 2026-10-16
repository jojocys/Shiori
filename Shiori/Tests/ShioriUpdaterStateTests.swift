import XCTest
@testable import Shiori

final class ShioriUpdaterStateTests: XCTestCase {
    func testOnlyInteractiveStatesAcceptClicks() {
        XCTAssertTrue(UpdateToolbarState.idle.acceptsInteraction)
        XCTAssertTrue(UpdateToolbarState.failed.acceptsInteraction)
        XCTAssertTrue(UpdateToolbarState.available(version: "1.2.0").acceptsInteraction)
        XCTAssertTrue(UpdateToolbarState.downloaded.acceptsInteraction)

        XCTAssertFalse(UpdateToolbarState.checking.acceptsInteraction)
        XCTAssertFalse(UpdateToolbarState.upToDate.acceptsInteraction)
        XCTAssertFalse(UpdateToolbarState.downloading.acceptsInteraction)
        XCTAssertFalse(UpdateToolbarState.hidden.acceptsInteraction)
    }

    func testNoUpdateCanRemoveTheToolbarItem() {
        XCTAssertFalse(UpdateToolbarState.upToDate.isHidden)
        XCTAssertTrue(UpdateToolbarState.hidden.isHidden)
    }

    func testDownloadedStateCannotBeDowngradedByLaterFailure() {
        let staged = UpdateToolbarState.downloaded
        XCTAssertEqual(staged.preservingDownloadedState(when: .failed), .downloaded)
        XCTAssertEqual(staged.preservingDownloadedState(when: .checking), .downloaded)
    }

    func testOrdinaryStatesCanTransitionNormally() {
        let checking = UpdateToolbarState.checking
        XCTAssertEqual(
            checking.preservingDownloadedState(when: .available(version: "1.2.0")),
            .available(version: "1.2.0")
        )
    }

    func testSilentAutomaticChecksUseA24HourSchedule() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(SilentUpdateSchedule.interval, 86_400)
        XCTAssertEqual(SilentUpdateSchedule.delaySinceLastCheck(nil, now: now), 0)
        XCTAssertEqual(
            SilentUpdateSchedule.delaySinceLastCheck(now.addingTimeInterval(-100), now: now),
            86_300
        )
        XCTAssertEqual(
            SilentUpdateSchedule.delaySinceLastCheck(now.addingTimeInterval(-90_000), now: now),
            0
        )
    }

    @MainActor
    func testBusySessionDoesNotStartSilentProbeOrChangeStateAndRetriesSoon() async throws {
        let priorCheck = Date(timeIntervalSince1970: 100_000)
        let now = priorCheck.addingTimeInterval(90_000)
        let states: [UpdateToolbarState] = [.idle, .failed, .available(version: "1.2.0"), .downloading, .downloaded]
        for state in states {
            let client = FakeUpdateInformationClient()
            client.canCheckForUpdates = true
            client.sessionInProgress = true
            let fixture = try updaterFixture(client: client, state: state, now: now)
            fixture.defaults.set(priorCheck, forKey: "ShioriUpdater.lastSilentCheckDate")
            fixture.updater.performSilentAutomaticCheck()
            XCTAssertEqual(client.startRequests, 0)
            XCTAssertEqual(fixture.updater.toolbarState, state)
            XCTAssertEqual(fixture.schedule.delays, [60])
            XCTAssertEqual(fixture.defaults.object(forKey: "ShioriUpdater.lastSilentCheckDate") as? Date, priorCheck)
        }
    }

    @MainActor
    func testBusyToolbarProbeKeepsInteractiveStateWithoutRequest() async throws {
        for state in [UpdateToolbarState.idle, .failed] {
            let client = FakeUpdateInformationClient()
            client.sessionInProgress = true
            let fixture = try updaterFixture(client: client, state: state)
            fixture.updater.checkForUpdatesFromToolbar()
            XCTAssertEqual(client.startRequests, 0)
            XCTAssertEqual(fixture.updater.toolbarState, state)
            XCTAssertTrue(fixture.updater.toolbarState.acceptsInteraction)
            XCTAssertTrue(fixture.schedule.delays.isEmpty)
        }
    }

    @MainActor
    func testAcceptedSilentProbeRecordsStartAndNilCompletionRestoresInteraction() async throws {
        let now = Date(timeIntervalSince1970: 200_000)
        for state in [UpdateToolbarState.idle, .failed, .available(version: "1.2.0")] {
            let client = FakeUpdateInformationClient()
            let fixture = try updaterFixture(client: client, state: state, now: now)
            fixture.updater.performSilentAutomaticCheck()
            XCTAssertEqual(client.startRequests, 1)
            XCTAssertEqual(fixture.updater.toolbarState, .checking)
            XCTAssertFalse(fixture.updater.toolbarState.acceptsInteraction)
            XCTAssertFalse(fixture.updater.canCheckForUpdates)
            XCTAssertEqual(fixture.schedule.delays, [SilentUpdateSchedule.interval])
            XCTAssertEqual(fixture.defaults.object(forKey: "ShioriUpdater.lastSilentCheckDate") as? Date, now)
            client.completeSession()
            fixture.updater.finishUpdateCycle(error: nil)
            XCTAssertEqual(fixture.updater.toolbarState, state)
            XCTAssertTrue(fixture.updater.toolbarState.acceptsInteraction)
            XCTAssertTrue(fixture.updater.canCheckForUpdates)
        }
    }

    @MainActor
    func testRejectedStartDoesNotPublishCheckingOrRecordSuccessfulSchedule() async throws {
        let client = FakeUpdateInformationClient()
        client.acceptsStart = false
        let fixture = try updaterFixture(client: client, state: .failed)
        fixture.updater.performSilentAutomaticCheck()
        XCTAssertEqual(client.startRequests, 1)
        XCTAssertEqual(fixture.updater.toolbarState, .failed)
        XCTAssertNil(fixture.defaults.object(forKey: "ShioriUpdater.lastSilentCheckDate"))
        XCTAssertEqual(fixture.schedule.delays, [60])
    }

    @MainActor
    func testUnavailableCanCheckAlsoRetriesWithoutAttempt() async throws {
        let client = FakeUpdateInformationClient()
        client.canCheckForUpdates = false
        let fixture = try updaterFixture(client: client)
        fixture.updater.performSilentAutomaticCheck()
        XCTAssertEqual(client.startRequests, 0)
        XCTAssertEqual(fixture.updater.toolbarState, .idle)
        XCTAssertEqual(fixture.schedule.delays, [60])
        XCTAssertNil(fixture.defaults.object(forKey: "ShioriUpdater.lastSilentCheckDate"))
    }

    @MainActor
    func testToolbarProbeNilCompletionResetsCheckingWithoutAutomaticTimestamp() async throws {
        let client = FakeUpdateInformationClient()
        let fixture = try updaterFixture(client: client)
        fixture.updater.checkForUpdatesFromToolbar()
        XCTAssertEqual(fixture.updater.toolbarState, .checking)
        client.completeSession()
        fixture.updater.finishUpdateCycle(error: nil)
        XCTAssertEqual(fixture.updater.toolbarState, .idle)
        XCTAssertTrue(fixture.updater.canCheckForUpdates)
        XCTAssertTrue(fixture.updater.toolbarState.acceptsInteraction)
        XCTAssertTrue(fixture.schedule.delays.isEmpty)
        XCTAssertNil(fixture.defaults.object(forKey: "ShioriUpdater.lastSilentCheckDate"))
    }

    @MainActor
    func testNilCycleCompletionKeepsMeaningfulExistingResults() async throws {
        for state in [UpdateToolbarState.available(version: "1.2.0"), .downloading, .downloaded, .hidden, .upToDate] {
            let fixture = try updaterFixture(client: FakeUpdateInformationClient(), state: state)
            fixture.updater.finishUpdateCycle(error: nil)
            XCTAssertEqual(fixture.updater.toolbarState, state)
        }
        let fixture = try updaterFixture(client: FakeUpdateInformationClient(), state: .checking)
        fixture.updater.finishUpdateCycle(error: nil)
        XCTAssertEqual(fixture.updater.toolbarState, .idle)
        XCTAssertTrue(fixture.updater.toolbarState.acceptsInteraction)
    }

    @MainActor
    private func updaterFixture(client: FakeUpdateInformationClient,
                                state: UpdateToolbarState = .idle,
                                now: Date = Date(timeIntervalSince1970: 200_000)) throws -> UpdaterFixture {
        let defaults = InMemoryUpdateDefaults()
        let schedule = SilentCheckScheduleRecorder()
        let updater = ShioriUpdater(informationClient: client, initialState: state,
                                    defaults: defaults, now: { now },
                                    scheduleSilentCheck: { schedule.delays.append($0) })
        return UpdaterFixture(updater: updater, defaults: defaults, schedule: schedule)
    }
}

@MainActor
private final class FakeUpdateInformationClient: UpdateInformationClient {
    var canCheckForUpdates = true
    var sessionInProgress = false
    var acceptsStart = true
    private(set) var startRequests = 0

    func startInformationCheck() -> Bool {
        startRequests += 1
        guard acceptsStart else { return false }
        canCheckForUpdates = false
        sessionInProgress = true
        return true
    }

    func completeSession() {
        canCheckForUpdates = true
        sessionInProgress = false
    }
}

@MainActor
private final class SilentCheckScheduleRecorder {
    var delays: [TimeInterval] = []
}

@MainActor
private struct UpdaterFixture {
    let updater: ShioriUpdater
    let defaults: UserDefaults
    let schedule: SilentCheckScheduleRecorder
}

/// No preference-domain writes: all scheduling timestamps stay inside the test.
private final class InMemoryUpdateDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }

    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}
