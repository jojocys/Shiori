import XCTest
@testable import Shiori

final class WineDockIconsTests: XCTestCase {
    func testAliasesHandleWindowsDrivePathsAndSpaces() {
        let aliases = WineDockIcons.executableAliases(URL(fileURLWithPath: "/prefix/drive_c/Games/My Game/Game.EXE"),
            prefix: URL(fileURLWithPath: "/prefix"))
        XCTAssertTrue(aliases.contains("c:/games/my game/game.exe"))
        XCTAssertTrue(aliases.contains("z:/prefix/drive_c/games/my game/game.exe"))
    }

    func testSiblingPrefixDoesNotGetCDriveAlias() {
        let aliases = WineDockIcons.executableAliases(URL(fileURLWithPath: "/prefix-other/drive_c/Game.exe"),
            prefix: URL(fileURLWithPath: "/prefix"))
        XCTAssertFalse(aliases.contains { $0.hasPrefix("c:/") })
    }

    func testEnvironmentPreservesOtherLibrariesAndDoesNotDuplicateAdapter() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = dir.appendingPathComponent("adapter.dylib")
        let manifest = dir.appendingPathComponent("icons.json")
        try Data().write(to: library); try Data().write(to: manifest)
        let original = ["DYLD_INSERT_LIBRARIES": "/other.dylib", "WINEPREFIX": "/prefix"]
        let once = WineDockIcons.environment(original, library: library, manifest: manifest)
        XCTAssertEqual(once["WINEPREFIX"], "/prefix")
        XCTAssertEqual(once["DYLD_INSERT_LIBRARIES"], "/other.dylib:" + library.path)
        XCTAssertEqual(WineDockIcons.environment(once, library: library, manifest: manifest), once)
    }

    func testMissingAdapterLeavesLaunchEnvironmentUnchanged() {
        let original = ["WINEPREFIX": "/prefix"]
        XCTAssertEqual(WineDockIcons.environment(original, library: nil, manifest: nil), original)
    }

    func testEnumerationIgnoresSymlinksOutsideGame() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let game = dir.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let exe = game.appendingPathComponent("Game.EXE")
        let other = dir.appendingPathComponent("outside.exe")
        try Data().write(to: exe); try Data().write(to: other)
        try FileManager.default.createSymbolicLink(at: game.appendingPathComponent("linked.exe"), withDestinationURL: other)
        XCTAssertEqual(WineDockIcons.executables(in: [game]).map { $0.resolvingSymlinksInPath() },
            [exe.resolvingSymlinksInPath()])
    }

    func testManifestScopesSteamToChosenDirectoryAndPrefix() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefix = dir.appendingPathComponent("prefix")
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let manifest = try WineDockIcons.prepare(prefix: prefix, gameExecutables: [], cache: dir, steamDirectory: steam)
        let data = try JSONDecoder().decode(WineDockIcons.Manifest.self, from: Data(contentsOf: manifest))
        XCTAssertTrue(data.steamRoots.contains("c:/program files (x86)/steam/"))
        XCTAssertTrue(data.icons.isEmpty)
        XCTAssertTrue(data.steamLockPath.hasPrefix(dir.path + "/"))
        _ = try WineDockIcons.prepare(prefix: prefix, gameExecutables: [], cache: dir)
        let afterGameLaunch = try JSONDecoder().decode(WineDockIcons.Manifest.self, from: Data(contentsOf: manifest))
        XCTAssertEqual(afterGameLaunch.steamRoots, data.steamRoots)
        let other = try WineDockIcons.prepare(prefix: dir.appendingPathComponent("other"), gameExecutables: [], cache: dir)
        XCTAssertNotEqual(manifest, other)
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
