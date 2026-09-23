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
}
