import Darwin
import Foundation
import XCTest
@testable import Shiori

private final class StopEffectRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var probes: [String: Int] = [:]
    private let failAfterInitial: Bool
    private(set) var commandPrefixes: [String] = []
    private(set) var signals: [(Set<Int32>, Int32)] = []

    init(failAfterInitial: Bool = false) { self.failAfterInitial = failAfterInitial }

    func probe(_ prefix: String) -> Set<Int32>? {
        lock.lock(); defer { lock.unlock() }
        let count = probes[prefix, default: 0]
        probes[prefix] = count + 1
        if failAfterInitial {
            return count == 0 ? [111] : (count == 1 ? nil : [])
        }
        return count == 0 ? [111] : (count == 1 ? [111, 222] : [222])
    }
    func command(_ env: [String: String]?) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        commandPrefixes.append(env?["WINEPREFIX"] ?? "")
        return 0
    }
    func signal(_ pids: Set<Int32>, _ signal: Int32) -> Int {
        lock.lock(); defer { lock.unlock() }
        signals.append((pids, signal))
        return pids.count
    }
}

final class WineSteamProcessServiceTests: XCTestCase {
    func testCommandDrainsLargeOutputAndBoundsRetainedBytes() throws {
        let script = try script("i=0\nwhile [ \"$i\" -lt 20000 ]; do\n  printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'\n  i=$((i + 1))\ndone\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let result = WineSteamProcessService.execute(executable: script.path, timeout: 5, maxOutputBytes: 4096)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.outputTruncated)
        XCTAssertEqual(result.output.utf8.count, 4096)
        XCTAssertTrue(result.output.hasPrefix("0123456789abcdef"))
    }

    func testCommandTimeoutReturnsWithoutWaitingForSleep() {
        let started = ProcessInfo.processInfo.systemUptime
        let result = WineSteamProcessService.execute(executable: "/bin/sleep", args: ["5"], timeout: 0.05)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, -2)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
    }

    func testDescendantHoldingOutputCannotKeepCaptureWaitingAfterParentExits() throws {
        // Allow for cold process startup while keeping the inherited pipe open
        // much longer than the capture deadline.
        let script = try script("/bin/sleep 5 &\nprintf 'parent-finished'\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let started = ProcessInfo.processInfo.systemUptime
        let result = WineSteamProcessService.execute(executable: script.path, timeout: 2)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, "parent-finished")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2.5)
    }

    func testCommandEnvironmentAndFailedLaunchAreExplicit() throws {
        let script = try script("printf '%s' \"$SHIORI_COMMAND_TEST\"\nexit 7\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let result = WineSteamProcessService.execute(executable: script.path, env: ["SHIORI_COMMAND_TEST": "controlled-value"])
        XCTAssertEqual(result.output, "controlled-value")
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertFalse(result.timedOut)
        let missing = WineSteamProcessService.execute(executable: script.deletingLastPathComponent().appendingPathComponent("missing").path)
        XCTAssertEqual(missing.exitCode, -1)
    }

    func testStopUsesOnlyPassedPrefixesAndSignalsOnlyInitiallyPlannedPIDs() {
        let effects = StopEffectRecorder()
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("controlled-prefix").path
        let context = WineSteamEntryContext(steamExePath: prefix + "/drive_c/Steam/Steam.exe", prefixPath: prefix, sourceLabel: "test")
        let operations = WineSteamProcessService.StopOperations(
            winePIDs: { effects.probe($0) }, wineserver: { _ in "/controlled/wineserver" },
            command: { _, _, env in effects.command(env) }, signal: { effects.signal($0, $1) }, pause: { _ in })
        let result = WineSteamProcessService.stop(contexts: [context, context], wineBinary: "/controlled/wine", operations: operations)
        XCTAssertEqual(effects.commandPrefixes, [SteamLibraryPathSafety.canonical(URL(fileURLWithPath: prefix)).path])
        XCTAssertEqual(effects.signals.map { $0.0 }, [[111], [111]])
        XCTAssertEqual(effects.signals.map { $0.1 }, [SIGTERM, SIGKILL])
        XCTAssertEqual(result.signaledPIDs, [111])
        XCTAssertEqual(result.remainingPIDs, [222])
        XCTAssertEqual(result.commandHits, 1)
        XCTAssertFalse(result.didStop)
    }

    func testEmptyStopPlanDoesNotRunCommandsOrSignalAnything() {
        let effects = StopEffectRecorder()
        let operations = WineSteamProcessService.StopOperations(
            winePIDs: { effects.probe($0) }, wineserver: { _ in "/controlled/wineserver" },
            command: { _, _, env in effects.command(env) }, signal: { effects.signal($0, $1) }, pause: { _ in })
        let result = WineSteamProcessService.stop(contexts: [], wineBinary: "/controlled/wine", operations: operations)
        XCTAssertTrue(effects.commandPrefixes.isEmpty)
        XCTAssertTrue(effects.signals.isEmpty)
        XCTAssertEqual(result.totalHits, 0)
    }

    func testFailedInitialProbeCannotSignalOrClaimProcessesHaveStopped() {
        let effects = StopEffectRecorder()
        let context = WineSteamEntryContext(steamExePath: "/controlled/prefix/Steam.exe", prefixPath: "/controlled/prefix", sourceLabel: "test")
        let operations = WineSteamProcessService.StopOperations(
            winePIDs: { _ in nil }, wineserver: { _ in "/controlled/wineserver" },
            command: { _, _, env in effects.command(env) }, signal: { effects.signal($0, $1) }, pause: { _ in })
        let result = WineSteamProcessService.stop(contexts: [context], wineBinary: "/controlled/wine", operations: operations)
        XCTAssertTrue(result.probeFailed)
        XCTAssertFalse(result.didStop)
        XCTAssertTrue(effects.commandPrefixes.isEmpty)
        XCTAssertTrue(effects.signals.isEmpty)
    }

    func testFailedFollowupProbeSkipsKillAndBlocksSuccessEvenIfFinalProbeIsEmpty() {
        let effects = StopEffectRecorder(failAfterInitial: true)
        let context = WineSteamEntryContext(steamExePath: "/controlled/prefix/Steam.exe", prefixPath: "/controlled/prefix", sourceLabel: "test")
        let operations = WineSteamProcessService.StopOperations(
            winePIDs: { effects.probe($0) }, wineserver: { _ in nil },
            command: { _, _, env in effects.command(env) }, signal: { effects.signal($0, $1) }, pause: { _ in })
        let result = WineSteamProcessService.stop(contexts: [context], wineBinary: "/controlled/wine", operations: operations)
        XCTAssertEqual(effects.signals.map { $0.1 }, [SIGTERM])
        XCTAssertTrue(result.remainingPIDs.isEmpty)
        XCTAssertTrue(result.probeFailed)
        XCTAssertFalse(result.didStop)
    }

    func testOpenFileRecordsCannotAssignSiblingPathsOrUnselectedPIDs() {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("controlled-prefix").path
        let records = "p111\nn\(prefix)/drive_c/file\np222\nn\(prefix)-other/file\np333\nn\(prefix)/drive_c/file\n"
        XCTAssertEqual(WineSteamProcessService.processIDs(openFilesOutput: records, candidates: [111, 222], prefix: prefix), [111])
    }

    private func script(_ body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShioriCommandTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("command")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}
