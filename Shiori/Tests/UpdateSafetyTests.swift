import XCTest
@testable import Shiori

final class UpdateSafetyTests: XCTestCase {
    func testOnlyProcessesUsingManagedRootsAreBlocked() {
        let output = """
        p10
        cShiori
        n/用户/游戏 Prefix/system.reg
        p11
        cwine64
        n/用户/游戏 Prefix/drive_c/game.exe
        p12
        cwine64
        n/用户/游戏 Prefix-other/system.reg
        p13
        cUpdater
        n/Applications/Shiori.app/Contents/Frameworks/Sparkle.framework/Updater
        p14
        cEmulator
        n/Applications/Shiori.app/Contents/Resources/EmbeddedEmulator/emu
        p15
        cwineserver
        n/外部/游戏/drive_c/save.dat
        """
        let found = UpdateActivityProbe.parse(output, roots: ["/用户/游戏 Prefix", "/Applications/Shiori.app/Contents/Resources/EmbeddedEmulator"], excluding: 10)
        XCTAssertEqual(found.map(\.pid), [11, 14])
    }

    func testDetachedChildAndInheritedLogAreDetectedOnce() {
        let found = UpdateActivityProbe.parse("p123\ncgame.exe\nn/tmp/shiori/logs/game.log\nn/tmp/prefix/system.reg\n", roots: ["/tmp/shiori/logs", "/tmp/prefix"], excluding: 99)
        XCTAssertEqual(found, [UpdateActivity(pid: 123, name: "game.exe")])
    }

    func testPathBoundary() {
        XCTAssertTrue(UpdateActivityProbe.isInside("/a/b", root: "/a"))
        XCTAssertFalse(UpdateActivityProbe.isInside("/ab", root: "/a"))
        XCTAssertTrue(UpdateActivityProbe.isInside("/a/中文 文件", root: "/a/"))
        XCTAssertTrue(UpdateActivityProbe.isInside("/private/var/folders/游戏/save", root: "/var/folders/游戏"))
        XCTAssertFalse(UpdateActivityProbe.isInside("/private/var/folders/游戏-other/save", root: "/var/folders/游戏"))
    }

    func testPendingInstallationBlocksNewLaunchesUntilAborted() async {
        await MainActor.run {
            let gate = UpdateInstallationGate()
            XCTAssertFalse(gate.blocksLaunch)
            gate.arm()
            XCTAssertTrue(gate.blocksLaunch)
            gate.disarm()
            XCTAssertFalse(gate.blocksLaunch)
        }
    }

    @MainActor
    func testRunningGameBlocksInstallAndRetrySavesBeforeExit() async {
        let gate = UpdateInstallationGate()
        gate.roots = { ["/tmp/test-prefix"] }
        var saved = false
        var messages: [String] = []
        gate.saveBeforeExit = { saved = true }
        gate.reportProblem = { title, _ in messages.append(title) }
        gate.probe = { _ in [UpdateActivity(pid: 1, name: "game")] }
        gate.arm()
        let blocked = await gate.allowInstallation()
        XCTAssertFalse(blocked)
        XCTAssertFalse(saved)
        XCTAssertTrue(gate.blocksLaunch)
        XCTAssertEqual(messages, ["更新已暂缓"])
        gate.probe = { _ in [] }
        let allowed = await gate.allowInstallation()
        XCTAssertTrue(allowed)
        XCTAssertTrue(saved)
    }

    @MainActor
    func testProbeAndSaveFailuresCannotPermitExit() async {
        let gate = UpdateInstallationGate()
        gate.roots = { ["/tmp/test-prefix"] }
        gate.reportProblem = { _, _ in }
        gate.probe = { _ in throw UpdateSafetyError.probeFailed("timeout") }
        let probeFailure = await gate.allowInstallation()
        XCTAssertFalse(probeFailure)
        gate.probe = { _ in [] }
        gate.saveBeforeExit = { throw UpdateSafetyError.probeFailed("disk full") }
        let saveFailure = await gate.allowInstallation()
        XCTAssertFalse(saveFailure)
    }

    func testRealProcessHoldingGameLogIsDetected() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("游戏 日志")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["20"]
        child.standardOutput = handle
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let matches = try UpdateActivityProbe.scan(roots: [folder.resolvingSymlinksInPath().path])
        XCTAssertTrue(matches.contains { $0.pid == child.processIdentifier }, "Expected PID \(child.processIdentifier) under \(folder.resolvingSymlinksInPath().path), got \(matches)")
    }
}
