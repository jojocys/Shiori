import Foundation
import XCTest
@testable import Shiori

final class SteamLibrarySnapshotTests: XCTestCase {
    func testUninstalledDefaultLibraryIsScannedWithoutBindingToOtherPrefix() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("ShioriSnapshotTests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let appData = home.appendingPathComponent(".shiori")
        let defaultLibrary = SteamLibraryManager.defaultWineSteamappsURL(appDataDir: appData)
        try manifest(in: defaultLibrary)
        let snapshot = SteamLibrarySnapshot.load(SteamLibraryScanInput(home: home, appDataDirectory: appData, contexts: []))
        XCTAssertEqual(snapshot.wineGames.count, 1)
        XCTAssertEqual(snapshot.installStatuses.count, 1)
        XCTAssertFalse(snapshot.isRunning)
        XCTAssertTrue(snapshot.bindings.isEmpty)
        XCTAssertEqual(snapshot.libraries.map(\.path), [SteamLibraryPathSafety.canonical(defaultLibrary).path])
    }

    func testSnapshotExcludesNativeAliasBeforeScanningWineGames() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("ShioriSnapshotTests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let nativeLibrary = home.appendingPathComponent("Library/Application Support/Steam/steamapps")
        try manifest(in: nativeLibrary)
        let appData = home.appendingPathComponent(".shiori")
        let defaultLibrary = SteamLibraryManager.defaultWineSteamappsURL(appDataDir: appData)
        try fm.createDirectory(at: defaultLibrary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: defaultLibrary, withDestinationURL: nativeLibrary)
        let snapshot = SteamLibrarySnapshot.load(SteamLibraryScanInput(home: home, appDataDirectory: appData, contexts: []))
        XCTAssertEqual(snapshot.macGames.count, 1)
        XCTAssertTrue(snapshot.wineGames.isEmpty)
        XCTAssertTrue(snapshot.installStatuses.isEmpty)
        XCTAssertTrue(snapshot.libraries.isEmpty)
        XCTAssertTrue(snapshot.bindings.isEmpty)
    }

    func testBindingsRouteExternalLibraryToItsOwnContextWithoutDefaultFallback() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("ShioriSnapshotTests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let appData = home.appendingPathComponent(".shiori")
        let defaultLibrary = SteamLibraryManager.defaultWineSteamappsURL(appDataDir: appData)
        try manifest(in: defaultLibrary)
        let prefix = home.appendingPathComponent("legacy-prefix")
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let ownLibrary = steam.appendingPathComponent("steamapps")
        let external = home.appendingPathComponent("external-library")
        try manifest(in: external.appendingPathComponent("steamapps"))
        try fm.createDirectory(at: ownLibrary, withIntermediateDirectories: true)
        try Data("\"path\" \"\(external.path)\"".utf8).write(to: ownLibrary.appendingPathComponent("libraryfolders.vdf"))
        let context = WineSteamEntryContext(steamExePath: steam.appendingPathComponent("Steam.exe").path,
                                           prefixPath: prefix.path, sourceLabel: "fixture")
        let snapshot = SteamLibrarySnapshot.load(
            SteamLibraryScanInput(home: home, appDataDirectory: appData, contexts: [context]),
            mainClientProbe: { _ in [111] })
        XCTAssertEqual(snapshot.wineGames.count, 2)
        XCTAssertEqual(snapshot.installStatuses.count, 2)
        XCTAssertTrue(snapshot.isRunning)
        XCTAssertFalse(snapshot.bindings.contains { $0.libraryURL.path == SteamLibraryPathSafety.canonical(defaultLibrary).path })
        let externalBinding = try XCTUnwrap(snapshot.bindings.first {
            $0.libraryURL.path == SteamLibraryPathSafety.canonical(external.appendingPathComponent("steamapps")).path
        })
        XCTAssertEqual(externalBinding.context, context)
    }

    private func manifest(in library: URL) throws {
        try FileManager.default.createDirectory(at: library.appendingPathComponent("common/Sample"), withIntermediateDirectories: true)
        let text = "\"appid\" \"100\"\n\"name\" \"Sample\"\n\"installdir\" \"Sample\"\n\"StateFlags\" \"4\""
        try Data(text.utf8).write(to: library.appendingPathComponent("appmanifest_100.acf"))
    }
}
