import XCTest
@testable import Shiori

@MainActor
final class AppStoreSteamCoordinationTests: XCTestCase {
    func testSteamOperationsBlockMenuGameLaunchAndFontChangesBeforeRuntimeEffects() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(appDataDirectory: root.appendingPathComponent("data"), initializeRuntime: false,
                             homeDirectory: root.appendingPathComponent("home"))
        let game = GameEntry(name: "Protected", prefixDir: root.appendingPathComponent("prefix").path)
        store.games = [game]
        store.selectedGameID = game.id
        for kind in [SteamOperationCoordinator.Kind.importing, .deleting, .launching, .stopping] {
            let lease = try XCTUnwrap(store.beginSteamOperation(kind))
            store.startGame()
            XCTAssertTrue(store.statusMessage.contains("当前 Steam 操作"))
            store.repairSelectedGameFonts()
            XCTAssertTrue(store.statusMessage.contains("当前 Steam 操作"))
            store.restoreSelectedGameFonts()
            XCTAssertTrue(store.statusMessage.contains("当前 Steam 操作"))
            XCTAssertFalse(store.isManagingFontCompatibility)
            XCTAssertTrue(store.lastLogPath.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: game.prefixDir))
            store.finishSteamOperation(lease)
        }
    }

    func testStagedUpdateAllowsStopButRejectsNewLaunchAndMutation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = UpdateInstallationGate()
        gate.arm()
        let store = AppStore(appDataDirectory: root, initializeRuntime: false,
                             homeDirectory: root.appendingPathComponent("home"), updateInstallationGate: gate)
        XCTAssertNil(store.beginSteamOperation(.launching))
        XCTAssertNil(store.beginSteamOperation(.deleting))
        XCTAssertNotNil(store.beginSteamOperation(.stopping))
        XCTAssertTrue(store.isSteamLibraryBusy)
    }

    func testDeleteDuringImportIsRejectedBeforeAnyFilesystemOrStopTask() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(appDataDirectory: root.appendingPathComponent("data"), initializeRuntime: false,
                             homeDirectory: root.appendingPathComponent("home"))
        let library = root.appendingPathComponent("wine/steamapps", isDirectory: true)
        let game = try installedGame(in: library)
        let sentinel = URL(fileURLWithPath: game.installPath).appendingPathComponent("payload.dat")
        _ = try XCTUnwrap(store.beginSteamOperation(.importing))
        store.deleteWineSteamGame(game)
        XCTAssertTrue(store.isSteamLibraryBusy)
        XCTAssertTrue(store.isSteamFileMutationInProgress)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("payload".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.manifestPath))
        XCTAssertTrue(store.statusMessage.contains("已有 Steam 操作"))
    }

    func testStatusAndRoutingRemainDistinctForSameAppIDInTwoPrefixes() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a/steamapps", isDirectory: true)
        let b = root.appendingPathComponent("b/steamapps", isDirectory: true)
        let ready = try installedGame(in: a)
        let pending = try installedGame(in: b, state: "2")
        let first = WineSteamEntryContext(steamExePath: root.appendingPathComponent("prefix-a/Steam.exe").path,
                                          prefixPath: root.appendingPathComponent("prefix-a").path, sourceLabel: "a")
        let second = WineSteamEntryContext(steamExePath: root.appendingPathComponent("prefix-b/Steam.exe").path,
                                           prefixPath: root.appendingPathComponent("prefix-b").path, sourceLabel: "b")
        let bindings = [SteamLibraryBinding(libraryURL: a, context: first), SteamLibraryBinding(libraryURL: b, context: second)]
        let statuses = SteamLibraryManager.scanInstallStatuses(steamappsURLs: [a, b])
        let store = AppStore(appDataDirectory: root.appendingPathComponent("data"), initializeRuntime: false,
                             homeDirectory: root.appendingPathComponent("home"))
        store.applySteamSnapshot(SteamLibrarySnapshot(macGames: [], wineGames: [ready, pending], installStatuses: statuses,
                                                      isRunning: false, libraries: [a, b], bindings: bindings))
        XCTAssertTrue(store.isWineSteamGameReadyToLaunch(ready))
        XCTAssertFalse(store.isWineSteamGameReadyToLaunch(pending))
        var mac = ready
        mac.source = .mac
        mac.steamappsPath = root.appendingPathComponent("mac/steamapps").path
        XCTAssertEqual(store.wineSteamInstallStatus(for: mac)?.installationIdentity, ready.installationIdentity)
        var manifestless = pending
        manifestless.manifestPath = ""
        manifestless.hasManifest = false
        store.applySteamSnapshot(SteamLibrarySnapshot(macGames: [], wineGames: [manifestless, ready, pending], installStatuses: statuses,
                                                      isRunning: false, libraries: [a, b], bindings: bindings))
        XCTAssertEqual(store.matchingWineSteamGame(forMacSteamGame: mac)?.installationIdentity, ready.installationIdentity)
        XCTAssertEqual(store.wineSteamInstallStatus(for: mac)?.installationIdentity, ready.installationIdentity)
        XCTAssertEqual(SteamLibraryRouting.installURL(for: mac, matchingWineGame: nil, status: nil), "steam://install/100")
        XCTAssertEqual(SteamLibraryRouting.installURL(for: mac, matchingWineGame: manifestless, status: nil), "steam://install/100")
        XCTAssertEqual(SteamLibraryRouting.installURL(for: mac, matchingWineGame: ready, status: statuses[ready.installationIdentity]), "steam://validate/100")
        XCTAssertEqual(SteamLibraryRouting.context(for: ready, bindings: bindings), first)
        XCTAssertEqual(SteamLibraryRouting.context(for: pending, bindings: bindings), second)
        var unknown = ready
        unknown.steamappsPath = root.appendingPathComponent("unknown/steamapps").path
        XCTAssertNil(SteamLibraryRouting.context(for: unknown, bindings: bindings))
    }

    func testIntermediateSnapshotCannotPublishDuringFileMutation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(appDataDirectory: root.appendingPathComponent("data"), initializeRuntime: false,
                             homeDirectory: root.appendingPathComponent("home"))
        let game = try installedGame(in: root.appendingPathComponent("wine/steamapps"))
        let lease = try XCTUnwrap(store.beginSteamOperation(.importing))
        store.refreshSteamLibraries(userInitiated: true)
        store.applySteamSnapshot(SteamLibrarySnapshot(macGames: [], wineGames: [game], installStatuses: [:],
                                                      isRunning: false, libraries: [], bindings: []))
        XCTAssertTrue(store.wineSteamGames.isEmpty)
        store.finishSteamOperation(lease)
    }

    private func installedGame(in library: URL, state: String = "4") throws -> SteamLibraryGame {
        let fm = FileManager.default
        try fm.createDirectory(at: library.appendingPathComponent("common/Sample"), withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: library.appendingPathComponent("common/Sample/payload.dat"))
        let manifest = """
        "AppState"
        {
            "appid" "100"
            "name" "Sample"
            "installdir" "Sample"
            "StateFlags" "\(state)"
            "SizeOnDisk" "7"
        }
        """
        try Data(manifest.utf8).write(to: library.appendingPathComponent("appmanifest_100.acf"))
        return try XCTUnwrap(SteamLibraryManager.scanWineGames(steamappsURLs: [library]).first)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shiori-Coordination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }
}
