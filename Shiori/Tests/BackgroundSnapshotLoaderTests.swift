import Foundation
import XCTest
@testable import Shiori

private func snapshotTestIsMainThread() -> Bool { Thread.isMainThread }

private actor SnapshotOperationGate {
    private(set) var inputs: [Int] = []
    private var continuations: [CheckedContinuation<String, Never>] = []

    func load(_ input: Int) async -> String {
        inputs.append(input)
        return await withCheckedContinuation { continuations.append($0) }
    }

    func release(_ value: String) { continuations.removeFirst().resume(returning: value) }

    func waitForRuns(_ count: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while inputs.count < count, Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        return inputs.count >= count
    }
}

@MainActor
final class BackgroundSnapshotLoaderTests: XCTestCase {
    func testRepeatedSameInputCoalescesIntoOneBackgroundOperation() async {
        let gate = SnapshotOperationGate()
        var published: [String] = []
        let loader = BackgroundSnapshotLoader<Int, String>(operation: { await gate.load($0) }, publish: { published.append($0) })
        loader.request(1)
        loader.request(1)
        loader.request(1)
        let started = await gate.waitForRuns(1)
        XCTAssertTrue(started)
        let inputs = await gate.inputs
        XCTAssertEqual(inputs, [1])
        await gate.release("one")
        let completed = await eventually { published == ["one"] && !loader.isLoading }
        XCTAssertTrue(completed)
    }

    func testOnlyLatestChangedInputRunsAndOutdatedResultCannotPublish() async {
        let gate = SnapshotOperationGate()
        var published: [String] = []
        let loader = BackgroundSnapshotLoader<Int, String>(operation: { await gate.load($0) }, publish: { published.append($0) })
        loader.request(1)
        let started = await gate.waitForRuns(1)
        XCTAssertTrue(started)
        loader.request(2)
        loader.request(3)
        loader.request(3)
        await gate.release("outdated")
        let latestStarted = await gate.waitForRuns(2)
        XCTAssertTrue(latestStarted)
        let inputs = await gate.inputs
        XCTAssertEqual(inputs, [1, 3])
        XCTAssertTrue(published.isEmpty)
        await gate.release("latest")
        let completed = await eventually { published == ["latest"] && !loader.isLoading }
        XCTAssertTrue(completed)
    }

    func testForcedSameInputInvalidatesActiveResultAndQueuesOneFreshRun() async {
        let gate = SnapshotOperationGate()
        var published: [String] = []
        let loader = BackgroundSnapshotLoader<Int, String>(operation: { await gate.load($0) }, publish: { published.append($0) })
        loader.request(1)
        let started = await gate.waitForRuns(1)
        XCTAssertTrue(started)
        loader.request(1, force: true)
        loader.request(1, force: true)
        await gate.release("old")
        let freshStarted = await gate.waitForRuns(2)
        XCTAssertTrue(freshStarted)
        let inputs = await gate.inputs
        XCTAssertEqual(inputs, [1, 1])
        XCTAssertTrue(published.isEmpty)
        await gate.release("fresh")
        let completed = await eventually { published == ["fresh"] }
        XCTAssertTrue(completed)
    }

    func testCancelInvalidatesResultAndNewRequestWaitsForOccupiedSlot() async {
        let gate = SnapshotOperationGate()
        var published: [String] = []
        let loader = BackgroundSnapshotLoader<Int, String>(operation: { await gate.load($0) }, publish: { published.append($0) })
        loader.request(1)
        let started = await gate.waitForRuns(1)
        XCTAssertTrue(started)
        loader.request(2)
        loader.cancel()
        XCTAssertFalse(loader.isLoading)
        loader.request(3)
        let beforeRelease = await gate.inputs
        XCTAssertEqual(beforeRelease, [1])
        await gate.release("cancelled")
        let newStarted = await gate.waitForRuns(2)
        XCTAssertTrue(newStarted)
        let afterRelease = await gate.inputs
        XCTAssertEqual(afterRelease, [1, 3])
        XCTAssertTrue(published.isEmpty)
        await gate.release("new")
        let completed = await eventually { published == ["new"] && !loader.isLoading }
        XCTAssertTrue(completed)
    }

    func testWorkRunsOffMainThreadAndPublicationRunsOnMainThread() async {
        var workerWasMain: Bool?
        var publisherWasMain = false
        let loader = BackgroundSnapshotLoader<Int, Bool>(operation: { _ in snapshotTestIsMainThread() }, publish: {
            workerWasMain = $0
            publisherWasMain = Thread.isMainThread
        })
        loader.request(1)
        let completed = await eventually { workerWasMain != nil }
        XCTAssertTrue(completed)
        XCTAssertEqual(workerWasMain, false)
        XCTAssertTrue(publisherWasMain)
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000) }
        return predicate()
    }
}
