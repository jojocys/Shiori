import XCTest
@testable import Shiori

@MainActor
final class AppStorePersistenceTests: XCTestCase {
    func testReloadPreservesManuallySelectedROMAndScriptWhenLegacyMetadataNeedsRepair() throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let roms = root.appendingPathComponent("roms", isDirectory: true)
        try FileManager.default.createDirectory(at: roms, withIntermediateDirectories: true)
        let a = roms.appendingPathComponent("GameA.nsp")
        let b = roms.appendingPathComponent("GameB.nsp")
        try Data().write(to: a)
        try Data().write(to: b)
        let first = try XCTUnwrap(GameScanner.scanGameFolder(roms).romURL)
        let manual = first.path == a.path ? b : a
        let store = AppStore(appDataDirectory: root.appendingPathComponent("data"), initializeRuntime: false)
        let game = GameEntry(name: "Manual choice", gameFolderPath: roms.path, engineHint: "legacy",
                             platform: .switchEmu, romPath: manual.path,
                             emulatorAppPath: "/explicit/emulator.app", launchScriptPath: "/explicit/launch.sh")
        store.games = [game]
        store.selectedGameID = game.id
        store.save()
        let reloaded = AppStore(appDataDirectory: store.appDataDir, initializeRuntime: false)
        XCTAssertEqual(reloaded.selectedGame?.romPath, manual.path)
        XCTAssertEqual(reloaded.selectedGame?.launchScriptPath, game.launchScriptPath)
        XCTAssertEqual(reloaded.selectedGame?.emulatorAppPath, game.emulatorAppPath)
        let again = AppStore(appDataDirectory: store.appDataDir, initializeRuntime: false)
        XCTAssertEqual(again.selectedGame?.romPath, manual.path)
    }

    func testNameDraftCommitsToOriginalGameAfterSelectionChanges() throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(appDataDirectory: root, initializeRuntime: false)
        let original = GameEntry(name: "Original")
        let other = GameEntry(name: "Other")
        store.games = [original, other]
        store.selectedGameID = original.id
        var draft = GameNameDraft(game: original)
        draft.text = ""
        for character in "My Game" { draft.text.append(character) }
        let change = try XCTUnwrap(draft.pendingChange)
        store.selectedGameID = other.id
        store.renameGame(change.gameID, to: change.name)
        XCTAssertEqual(store.games.first(where: { $0.id == original.id })?.name, "My Game")
        XCTAssertEqual(store.selectedGame?.name, "Other")
        let reloaded = AppStore(appDataDirectory: root, initializeRuntime: false)
        XCTAssertEqual(reloaded.games.first(where: { $0.id == original.id })?.name, "My Game")
    }

    func testUpdateGateBlocksBothFontRepairAndRestoreBeforeAnyRuntimeLaunch() throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = UpdateInstallationGate()
        gate.arm()
        let store = AppStore(appDataDirectory: root, initializeRuntime: false, updateInstallationGate: gate)
        let game = GameEntry(name: "Protected", prefixDir: root.appendingPathComponent("prefix").path)
        store.games = [game]
        store.selectedGameID = game.id
        store.repairSelectedGameFonts()
        XCTAssertTrue(store.statusMessage.contains("更新已准备安装"))
        store.restoreSelectedGameFonts()
        XCTAssertTrue(store.statusMessage.contains("更新已准备安装"))
        XCTAssertFalse(store.isManagingFontCompatibility)
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.prefixDir))
    }

    func testFreshAndExplicitlyEmptyStoresStayEmpty() throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fresh = AppStore(appDataDirectory: root, initializeRuntime: false)
        XCTAssertTrue(fresh.games.isEmpty)
        XCTAssertNil(fresh.selectedGameID)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fresh.prefixesDir.appendingPathComponent("新游戏").path
        ))

        fresh.save()
        let reloaded = AppStore(appDataDirectory: root, initializeRuntime: false)
        XCTAssertTrue(reloaded.games.isEmpty)
        XCTAssertNil(reloaded.selectedGameID)
    }

    func testManuallyAddedEmptyGamePersistsAcrossRelaunch() throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AppStore(appDataDirectory: root, initializeRuntime: false)
        store.addEmptyGame()
        let addedID = try XCTUnwrap(store.selectedGameID)

        let reloaded = AppStore(appDataDirectory: root, initializeRuntime: false)
        XCTAssertEqual(reloaded.games.count, 1)
        XCTAssertEqual(reloaded.games.first?.id, addedID)
        XCTAssertEqual(reloaded.games.first?.name, "新游戏")
        XCTAssertEqual(reloaded.selectedGameID, addedID)
    }

    func testConfiguredGameSurvivesRelaunchAndPrimaryFileRecovery() throws {
        let root = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AppStore(appDataDirectory: root, initializeRuntime: false)
        store.addEmptyGame()
        store.games[0].name = "保留的游戏"
        store.games[0].gameFolderPath = "/测试/游戏目录"
        store.games[0].exePath = "/测试/游戏目录/game.exe"
        store.games[0].notes = "升级后仍应存在"
        store.save()

        // Simulate a configuration created by an older Shiori release, before backups existed.
        try FileManager.default.removeItem(at: store.storeBackupURL)
        let reloaded = AppStore(appDataDirectory: root, initializeRuntime: false)
        XCTAssertEqual(reloaded.games.first?.name, "保留的游戏")
        XCTAssertEqual(reloaded.games.first?.exePath, "/测试/游戏目录/game.exe")
        XCTAssertEqual(reloaded.games.first?.notes, "升级后仍应存在")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded.storeBackupURL.path))

        try Data("损坏的备份配置".utf8).write(to: reloaded.storeBackupURL, options: .atomic)
        let repaired = AppStore(appDataDirectory: root, initializeRuntime: false)
        try Data("损坏的主配置".utf8).write(to: repaired.storeURL, options: .atomic)
        let recovered = AppStore(appDataDirectory: root, initializeRuntime: false)
        XCTAssertEqual(recovered.games.first?.name, "保留的游戏")
        XCTAssertEqual(recovered.games.first?.exePath, "/测试/游戏目录/game.exe")
        XCTAssertEqual(recovered.games.first?.notes, "升级后仍应存在")
        XCTAssertEqual(recovered.statusMessage, "主配置文件不可用，已从本地备份恢复。")
    }

    private func temporaryStoreDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Shiori-AppStoreTests-\(UUID().uuidString)", isDirectory: true)
    }
}
