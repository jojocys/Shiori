import XCTest
@testable import Shiori

final class WineSteamCleanupPolicyTests: XCTestCase {
    @MainActor
    func testSelectedStandaloneGameDoesNotAuthorizeAppStoreCleanup() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(appDataDirectory: root.appendingPathComponent("data"),
                             initializeRuntime: false, homeDirectory: root.appendingPathComponent("home"))
        let standalone = root.appendingPathComponent("standalone", isDirectory: true)
        try FileManager.default.createDirectory(at: standalone, withIntermediateDirectories: true)
        let game = GameEntry(name: "Protected standalone game", prefixDir: standalone.path)
        store.games = [game]
        store.selectedGameID = game.id
        XCTAssertTrue(store.resolveWineSteamCleanupContexts().isEmpty)
        XCTAssertNil(store.wineSteamEntryContext)
    }

    func testStandalonePrefixWithoutSteamNeverEntersCleanupPlan() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("standalone", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let save = game.appendingPathComponent("save.dat")
        try Data("protected progress".utf8).write(to: save)
        let candidate = context(game)
        XCTAssertTrue(WineSteamCleanupPolicy.contexts([candidate]).isEmpty)
        XCTAssertEqual(try Data(contentsOf: save), Data("protected progress".utf8))
    }

    func testOnlySteamPrefixIsSelectedAlongsideStandaloneGame() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let steam = root.appendingPathComponent("steam", isDirectory: true)
        let standalone = root.appendingPathComponent("standalone", isDirectory: true)
        try FileManager.default.createDirectory(at: standalone, withIntermediateDirectories: true)
        let valid = context(steam)
        let exe = URL(fileURLWithPath: valid.steamExePath)
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fake Steam".utf8).write(to: exe)
        XCTAssertEqual(WineSteamCleanupPolicy.contexts([context(standalone), valid]), [valid])
    }

    func testAliasesDeduplicateAndExecutableEscapingPrefixIsRejected() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let steam = root.appendingPathComponent("steam", isDirectory: true)
        let valid = context(steam)
        let exe = URL(fileURLWithPath: valid.steamExePath)
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fake Steam".utf8).write(to: exe)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: steam)
        XCTAssertEqual(WineSteamCleanupPolicy.contexts([valid, context(alias)]).count, 1)
        let standalone = root.appendingPathComponent("standalone", isDirectory: true)
        let escaped = context(standalone)
        let link = URL(fileURLWithPath: escaped.steamExePath)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: exe)
        XCTAssertTrue(WineSteamCleanupPolicy.contexts([escaped]).isEmpty)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shiori-Cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func context(_ prefix: URL) -> WineSteamEntryContext {
        WineSteamEntryContext(steamExePath: prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/Steam.exe").path,
                              prefixPath: prefix.path, sourceLabel: "fixture")
    }
}
