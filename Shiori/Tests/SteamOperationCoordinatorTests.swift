import XCTest
@testable import Shiori

@MainActor
final class SteamOperationCoordinatorTests: XCTestCase {
    func testImportAndDeleteAreMutuallyExclusiveAndCannotBeCancelledAsLaunch() throws {
        let coordinator = SteamOperationCoordinator()
        let lease = try XCTUnwrap(coordinator.begin(.importing))
        XCTAssertNil(coordinator.begin(.deleting))
        XCTAssertNil(coordinator.begin(.launching))
        XCTAssertFalse(coordinator.cancelLaunch())
        XCTAssertEqual(coordinator.active, lease)
        coordinator.finish(lease)
        XCTAssertNotNil(coordinator.begin(.deleting))
    }

    func testStoppingCancelsPendingLaunchAndOldCompletionCannotReleaseNewMutation() async throws {
        let coordinator = SteamOperationCoordinator()
        let launch = try XCTUnwrap(coordinator.begin(.launching))
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
        coordinator.track(task, for: launch)
        XCTAssertTrue(coordinator.cancelLaunch())
        XCTAssertTrue(task.isCancelled)
        let deletion = try XCTUnwrap(coordinator.begin(.deleting))
        coordinator.finish(launch)
        XCTAssertEqual(coordinator.active, deletion)
        coordinator.finish(deletion)
        XCTAssertNil(coordinator.active)
        await task.value
    }
}
