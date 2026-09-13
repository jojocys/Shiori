import XCTest
@testable import Shiori

@MainActor
final class AppStorePersistenceTests: XCTestCase {
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
