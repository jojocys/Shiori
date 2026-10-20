import XCTest
@testable import Shiori

@MainActor
final class AutomaticArtworkPersistenceTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!

    private func legacyKey(_ name: String) -> String { "name-" + TitleMatch.stableHash(TitleMatch.normalize(name)) }

    func testRenameBeforeFirstViewLoadMigratesLegacyCoverAndSurvivesRelaunchOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shiori-Cover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(appDataDirectory: root, initializeRuntime: false)
        let cache = store.iconsDir.appendingPathComponent("cache")
        let game = GameEntry(name: "Original cover title", gameFolderPath: root.appendingPathComponent("generic").path)
        store.games = [game]; store.selectedGameID = game.id
        let oldKey = legacyKey(game.name)
        RemoteIconCache.write(png, key: oldKey, directory: cache)
        store.renameGame(game.id, to: "Unrelated renamed title")
        let renamed = try XCTUnwrap(store.selectedGame)
        let cover = await GameIconResolver.iconData(for: renamed, cacheDirectory: cache, online: false)
        XCTAssertEqual(cover, png)
        XCTAssertEqual(RemoteIconCache.read(oldKey, directory: cache), png, "Legacy icon bytes must remain intact")
        let reloaded = AppStore(appDataDirectory: root, initializeRuntime: false)
        let persisted = try XCTUnwrap(reloaded.selectedGame)
        XCTAssertEqual(persisted.id, game.id)
        XCTAssertEqual(persisted.name, renamed.name)
        let afterRelaunch = await GameIconResolver.iconData(for: persisted, cacheDirectory: cache, online: false)
        XCTAssertEqual(afterRelaunch, png)
    }

    func testNormalLoadBindsLegacyCacheBeforeSubsequentNameChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shiori-Cover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var game = GameEntry(name: "Original")
        RemoteIconCache.write(png, key: legacyKey(game.name), directory: root)
        let initial = await GameIconResolver.iconData(for: game, cacheDirectory: root, online: false)
        XCTAssertEqual(initial, png)
        game.name = "Changed"; game.updatedAt = Date()
        let renamed = await GameIconResolver.iconData(for: game, cacheDirectory: root, online: false)
        XCTAssertEqual(renamed, png)
    }

    func testSourceIdentityRetainsNameEditsButSeparatesGamesAndExecutables() {
        var game = GameEntry(name: "Original", exePath: "/a.exe", prefixDir: "/prefix")
        let source = GameArtworkIdentity.source(for: game)
        let key = GameIconResolver.persistentCoverKey(for: game)
        game.name = "Renamed"; game.updatedAt = Date()
        XCTAssertEqual(source, GameArtworkIdentity.source(for: game))
        XCTAssertEqual(key, GameIconResolver.persistentCoverKey(for: game))
        game.exePath = "/b.exe"
        XCTAssertNotEqual(key, GameIconResolver.persistentCoverKey(for: game))
        game.exePath = "/a.exe"; game.id = UUID()
        XCTAssertNotEqual(key, GameIconResolver.persistentCoverKey(for: game))
    }

    func testExplicitRefetchClearsStableBindingWithoutTouchingManualIcon() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shiori-Cover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manual = root.appendingPathComponent("manual.png")
        try png.write(to: manual)
        var game = GameEntry(name: "Cover")
        RemoteIconCache.write(png, key: GameIconResolver.persistentCoverKey(for: game), directory: root)
        GameIconResolver.clearRemoteCache(for: game, cacheDirectory: root)
        let cleared = await GameIconResolver.iconData(for: game, cacheDirectory: root, online: false)
        XCTAssertNil(cleared)
        game.iconPath = manual.path
        let custom = await GameIconResolver.iconData(for: game, cacheDirectory: root, online: false)
        XCTAssertEqual(custom, png)
        XCTAssertEqual(try Data(contentsOf: manual), png)
    }

    func testRenameRetainsManualImageAndAllExistingConfigurationFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shiori-Cover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(appDataDirectory: root, initializeRuntime: false)
        let manual = store.iconsDir.appendingPathComponent("manual.png")
        try png.write(to: manual)
        let game = GameEntry(name: "Original", gameFolderPath: "/original/game", exePath: "/original/game/main.exe",
                             prefixDir: "/original/prefix", launchLanguageMode: .chineseSimplified,
                             iconPath: manual.path, notes: "保留现有配置")
        store.games = [game]; store.selectedGameID = game.id
        store.preferredKeysPath = "/original/prod.keys"
        store.preferredFirmwarePath = "/original/firmware"
        store.renameGame(game.id, to: "Renamed")
        let reloaded = AppStore(appDataDirectory: root, initializeRuntime: false)
        let result = try XCTUnwrap(reloaded.selectedGame)
        XCTAssertEqual(result.id, game.id)
        XCTAssertEqual(result.iconPath, game.iconPath)
        XCTAssertEqual(result.exePath, game.exePath)
        XCTAssertEqual(result.prefixDir, game.prefixDir)
        XCTAssertEqual(result.gameFolderPath, game.gameFolderPath)
        XCTAssertEqual(result.launchLanguageMode, game.launchLanguageMode)
        XCTAssertEqual(result.notes, game.notes)
        XCTAssertEqual(reloaded.preferredKeysPath, store.preferredKeysPath)
        XCTAssertEqual(reloaded.preferredFirmwarePath, store.preferredFirmwarePath)
        let image = await GameIconResolver.iconData(for: result, cacheDirectory: store.iconsDir.appendingPathComponent("cache"), online: false)
        XCTAssertEqual(image, png)
        XCTAssertEqual(try Data(contentsOf: manual), png)
    }
}
