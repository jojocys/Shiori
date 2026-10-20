import XCTest
@testable import Shiori

@MainActor
final class IndependentGameLaunchTests: XCTestCase {
    private final class Probe {
        var calls = 0
        var running = false
        var fails = false
        var pause = false
        var continuation: CheckedContinuation<Bool, Error>?
        func check() async throws -> Bool {
            calls += 1
            if pause { return try await withCheckedThrowingContinuation { continuation = $0 } }
            if fails { throw IndependentGameProbeError.unavailable }
            return running
        }
    }

    private func fixture() throws -> (URL, AppStore, GameEntry, Probe) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shiori-Launch-\(UUID())")
        let store = AppStore(appDataDirectory: root, initializeRuntime: false,
                             homeDirectory: root.appendingPathComponent("home"), updateInstallationGate: UpdateInstallationGate())
        let game = GameEntry(name: "Game", gameFolderPath: root.appendingPathComponent("game").path,
                             exePath: root.appendingPathComponent("game/main.exe").path,
                             prefixDir: root.appendingPathComponent("prefix").path)
        store.games = [game]; store.selectedGameID = game.id
        let probe = Probe()
        store.independentGameProbe = { _ in try await probe.check() }
        return (root, store, game, probe)
    }

    private func finish(_ store: AppStore) async {
        for _ in 0..<200 {
            if store.startingIndependentGames.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Launch request did not finish")
    }

    func testRapidRequestsAcrossEntriesReserveOneLaunchBeforeProbeCompletes() async throws {
        let (root, store, game, probe) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        probe.pause = true
        var launches = 0
        store.independentGameLauncher = { _ in
            launches += 1
            return GameLaunchResult(logURL: root.appendingPathComponent("test.log"), process: Process())
        }
        store.startGame()
        store.startGame(game)
        var duplicate = game; duplicate.id = UUID(); duplicate.name = "Alias"
        store.games.append(duplicate)
        store.startGame(duplicate)
        for _ in 0..<100 where probe.continuation == nil { await Task.yield() }
        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(launches, 0)
        XCTAssertTrue(store.isStartingGame(duplicate))
        probe.continuation?.resume(returning: false)
        await finish(store)
        XCTAssertEqual(launches, 1)
    }

    func testExistingChildBlocksAfterLoaderExitsAndExitAllowsRelaunch() async throws {
        let (root, store, game, probe) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var launches = 0
        store.independentGameLauncher = { _ in
            launches += 1
            return GameLaunchResult(logURL: root.appendingPathComponent("test.log"), process: Process())
        }
        store.startGame(game); await finish(store)
        XCTAssertEqual(launches, 1)
        probe.running = true // retained Process has exited; descendant still owns the token
        store.startGame(game); await finish(store)
        XCTAssertEqual(launches, 1)
        XCTAssertTrue(store.statusMessage.contains("已在运行"))
        probe.running = false
        store.startGame(game); await finish(store)
        XCTAssertEqual(launches, 2)
    }

    func testRetainedLiveProcessBlocksWithoutRelyingOnProbe() async throws {
        let (root, store, game, probe) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["0.5"]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        store.independentGameLauncher = { _ in
            try child.run()
            return GameLaunchResult(logURL: root.appendingPathComponent("test.log"), process: child)
        }
        store.startGame(game); await finish(store)
        store.startGame(game)
        XCTAssertEqual(probe.calls, 1)
        XCTAssertTrue(store.statusMessage.contains("已在运行"))
        child.waitUntilExit()
    }

    func testProbeOrLaunchFailureCanRetryAndNeverCreatesAnExtraProcess() async throws {
        let (root, store, game, probe) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var launches = 0
        var failLaunch = true
        store.independentGameLauncher = { _ in
            launches += 1
            if failLaunch { throw GameLauncherError.wineNotFound }
            return GameLaunchResult(logURL: root.appendingPathComponent("test.log"), process: Process())
        }
        probe.fails = true
        store.startGame(game); await finish(store)
        XCTAssertEqual(launches, 0)
        probe.fails = false
        store.startGame(game); await finish(store)
        XCTAssertEqual(launches, 1)
        failLaunch = false
        store.startGame(game); await finish(store)
        XCTAssertEqual(launches, 2)
    }

    func testConfigChangedDuringProbeCannotLaunchStaleExecutable() async throws {
        let (root, store, game, probe) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        probe.pause = true
        var launched = false
        store.independentGameLauncher = { _ in
            launched = true
            return GameLaunchResult(logURL: root.appendingPathComponent("test.log"), process: Process())
        }
        store.startGame(game)
        for _ in 0..<100 where probe.continuation == nil { await Task.yield() }
        store.games[0].exePath += ".changed"
        probe.continuation?.resume(returning: false)
        await finish(store)
        XCTAssertFalse(launched)
    }

    func testIdentityScopesExecutablesPrefixesAndFilesystemAliases() throws {
        let (root, _, game, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        var same = game
        same.exePath = alias.appendingPathComponent("game/main.exe").path
        same.prefixDir = alias.appendingPathComponent("prefix").path
        XCTAssertEqual(IndependentGameIdentity(game), IndependentGameIdentity(same))
        same = game; same.name = "Renamed"; same.id = UUID()
        XCTAssertEqual(IndependentGameIdentity(game), IndependentGameIdentity(same))
        same.exePath += ".other"
        XCTAssertNotEqual(IndependentGameIdentity(game), IndependentGameIdentity(same))
        same = game; same.prefixDir += "-other"
        XCTAssertNotEqual(IndependentGameIdentity(game), IndependentGameIdentity(same))
    }

    func testDifferentExecutablesAndPrefixesDoNotShareTheLaunchReservation() async throws {
        let (root, store, game, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var otherEXE = game; otherEXE.id = UUID(); otherEXE.exePath += ".other"
        var otherPrefix = game; otherPrefix.id = UUID(); otherPrefix.prefixDir += "-other"
        store.games += [otherEXE, otherPrefix]
        var launches = 0
        store.independentGameLauncher = { _ in
            launches += 1
            return GameLaunchResult(logURL: root.appendingPathComponent("test.log"), process: Process())
        }
        for entry in store.games { store.startGame(entry) }
        XCTAssertEqual(store.startingIndependentGames.count, 3)
        await finish(store)
        XCTAssertEqual(launches, 3)
    }

    func testUpdateArmedDuringProbePreventsRuntimeLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shiori-Launch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = UpdateInstallationGate()
        let store = AppStore(appDataDirectory: root, initializeRuntime: false, updateInstallationGate: gate)
        let game = GameEntry(name: "Game", exePath: "/test/game.exe", prefixDir: "/test/prefix")
        store.games = [game]
        let probe = Probe(); probe.pause = true
        store.independentGameProbe = { _ in try await probe.check() }
        var launched = false
        store.independentGameLauncher = { _ in
            launched = true
            return GameLaunchResult(logURL: root.appendingPathComponent("test.log"), process: Process())
        }
        store.startGame(game)
        for _ in 0..<100 where probe.continuation == nil { await Task.yield() }
        gate.arm()
        probe.continuation?.resume(returning: false)
        await finish(store)
        XCTAssertFalse(launched)
        XCTAssertTrue(store.statusMessage.contains("更新已准备安装"))
    }
}

final class IndependentGameProcessProbeTests: XCTestCase {
    private func procargs(_ args: [String], environment: [String]) -> Data {
        var result = Data([UInt8(args.count), 0, 0, 0])
        result.append(Data("/wine64\0\0".utf8))
        for field in args + environment { result.append(Data((field + "\0").utf8)) }
        result.append(0)
        return result
    }

    func testEnvironmentParsingDoesNotMatchArgumentsPrefixesOrTruncatedBuffers() {
        let key = IndependentGameIdentity.environmentKey
        let data = procargs(["wine64", "game.exe", key + "=wrong"],
                            environment: [key + "_OTHER=wrong", "PATH=/bin", key + "=correct"])
        XCTAssertEqual(IndependentGameProcessProbe.environmentValue(in: data, key: key), "correct")
        XCTAssertNil(IndependentGameProcessProbe.environmentValue(in: Data(data.prefix(7)), key: key))
        XCTAssertNil(IndependentGameProcessProbe.environmentValue(in: procargs([key + "=wrong"], environment: []), key: key))
    }

    func testWineInfrastructureCannotKeepAClosedGameMarkedRunning() {
        for service in ["services.exe", "winedevice.exe", "explorer.exe", "wineboot.exe"] {
            XCTAssertTrue(IndependentGameProcessProbe.isRuntimeService(in: procargs(["wine64", "C:\\windows\\system32\\" + service], environment: [])))
        }
        XCTAssertTrue(IndependentGameProcessProbe.isRuntimeService(in: procargs(["/wine/bin/wineserver", "-p"], environment: [])))
        XCTAssertFalse(IndependentGameProcessProbe.isRuntimeService(in: procargs(["wine64", "C:\\games\\javaw.exe"], environment: ["PATH=explorer.exe"])))
    }
}
