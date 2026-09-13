import Foundation
@testable import Shiori
import XCTest

final class SteamLibraryTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShioriSteamLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testPrefillSkipsManifestAndMacOnlyBundleFiles() throws {
        let fm = FileManager.default
        let macSteamapps = tempRoot.appendingPathComponent("MacSteam/steamapps", isDirectory: true)
        let macCommon = macSteamapps.appendingPathComponent("common", isDirectory: true)
        let gameRoot = macCommon.appendingPathComponent("Sample VN", isDirectory: true)
        let appResources = gameRoot
            .appendingPathComponent("Sample VN.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let appData = appResources.appendingPathComponent("Data", isDirectory: true)
        let infoURL = appResources.deletingLastPathComponent().appendingPathComponent("Info.plist")
        try fm.createDirectory(at: appData, withIntermediateDirectories: true)
        try write("asset", to: appData.appendingPathComponent("sharedassets0.assets"))
        try write("wrapper data", to: appResources.appendingPathComponent("mac-wrapper.dat"))
        try write("pak", to: appResources.appendingPathComponent("shared.pak"))
        try write("mac dylib", to: appResources.appendingPathComponent("libmac.dylib"))
        try write("music", to: appResources.appendingPathComponent("resources/packed/music.a"))
        try write("localized", to: appResources.appendingPathComponent("resources.kr/gfx/icon.png"))
        try write("linux so", to: appResources.appendingPathComponent("resources/libsteam_api.so"))
        try write("localized plist", to: appResources.appendingPathComponent("en.lproj/InfoPlist.strings"))
        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>SampleWin</string>
        </dict>
        </plist>
        """, to: infoURL)
        try fm.createDirectory(at: macSteamapps, withIntermediateDirectories: true)
        try write("""
        "AppState"
        {
            "appid" "100"
            "name" "Sample VN"
            "StateFlags" "4"
            "installdir" "Sample VN"
            "SizeOnDisk" "1024"
            "buildid" "1"
        }
        """, to: macSteamapps.appendingPathComponent("appmanifest_100.acf"))

        let games = SteamLibraryManager.scanGames(steamappsURLs: [macSteamapps], source: .mac, includePreloadOnly: false)
        XCTAssertEqual(games.count, 1)

        let wineSteamapps = tempRoot.appendingPathComponent("WineSteam/steamapps", isDirectory: true)
        let report = try SteamLibraryManager.prefillWineSteam(from: games[0], to: wineSteamapps)
        let target = wineSteamapps.appendingPathComponent("common/Sample VN", isDirectory: true)

        XCTAssertGreaterThan(report.copiedFiles, 0)
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("SampleWin_Data/sharedassets0.assets").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("Sample VN_Data/sharedassets0.assets").path))
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("shared.pak").path))
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("resources/packed/music.a").path))
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("resources.kr/gfx/icon.png").path))
        let staging = wineSteamapps.appendingPathComponent("downloading/100", isDirectory: true)
        XCTAssertFalse(fm.fileExists(atPath: staging.path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("Sample VN.app").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("libmac.dylib").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("mac-wrapper.dat").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("resources/libsteam_api.so").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("en.lproj/InfoPlist.strings").path))
        let generatedManifest = wineSteamapps.appendingPathComponent("appmanifest_100.acf")
        XCTAssertTrue(fm.fileExists(atPath: generatedManifest.path))
        let generatedManifestText = try String(contentsOf: generatedManifest, encoding: .utf8)
        XCTAssertTrue(generatedManifestText.contains("\"appid\"        \"100\""))
        XCTAssertTrue(generatedManifestText.contains("\"ShioriPrefill\"        \"1\""))
        XCTAssertTrue(generatedManifestText.contains("\"StateFlags\"        \"4\""))
        XCTAssertTrue(generatedManifestText.contains("\"installdir\"        \"Sample VN\""))
        XCTAssertTrue(generatedManifestText.contains("\"buildid\"        \"1\""))
        XCTAssertTrue(generatedManifestText.contains("\"TargetBuildID\"        \"1\""))
        XCTAssertTrue(generatedManifestText.contains("\"FullValidateAfterNextUpdate\"        \"1\""))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent(".shiori-prefill").path))

        let preloadedGames = SteamLibraryManager.scanGames(steamappsURLs: [wineSteamapps], source: .wine, includePreloadOnly: true)
        XCTAssertEqual(preloadedGames.first?.appID, "100")
        XCTAssertEqual(preloadedGames.first?.name, "Sample VN")
        XCTAssertEqual(preloadedGames.first?.hasManifest, true)

        let statuses = SteamLibraryManager.scanInstallStatuses(steamappsURLs: [wineSteamapps])
        XCTAssertEqual(statuses["100"]?.prefillMetadata?.copiedBytes, report.copiedBytes)
        XCTAssertEqual(statuses["100"]?.buildID, "1")
        XCTAssertEqual(statuses["100"]?.activityLabel, "等待 Steam 校验")
        XCTAssertEqual(statuses["100"]?.hasDownloadingDir, false)
        XCTAssertEqual(statuses["100"]?.isLaunchReady, false)
        XCTAssertTrue(try XCTUnwrap(statuses["100"]?.prefillEvidenceLabel).contains("已写入 Wine manifest"))
    }

    func testPrefillCleansStaleDownloadStateAndStatusReadsSteamProgress() throws {
        let fm = FileManager.default
        let sourceRoot = tempRoot.appendingPathComponent("MacSteam/steamapps/common/Progress Game", isDirectory: true)
        try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try write("asset", to: sourceRoot.appendingPathComponent("shared.assets"))

        let wineSteamapps = tempRoot.appendingPathComponent("WineSteam/steamapps", isDirectory: true)
        let staleDownloading = wineSteamapps.appendingPathComponent("downloading/300", isDirectory: true)
        let staleTemp = wineSteamapps.appendingPathComponent("temp/300", isDirectory: true)
        let stalePatch = wineSteamapps.appendingPathComponent("downloading/state_300_301.patch")
        try fm.createDirectory(at: staleDownloading, withIntermediateDirectories: true)
        try fm.createDirectory(at: staleTemp, withIntermediateDirectories: true)
        try write("old", to: staleDownloading.appendingPathComponent("old.bin"))
        try write("old", to: staleTemp.appendingPathComponent("old.bin"))
        try write("old patch", to: stalePatch)

        let sourceGame = SteamLibraryGame(
            id: "mac:300:\(sourceRoot.path)",
            appID: "300",
            name: "Progress Game",
            installDir: "Progress Game",
            libraryPath: sourceRoot.deletingLastPathComponent().deletingLastPathComponent().path,
            steamappsPath: sourceRoot.deletingLastPathComponent().deletingLastPathComponent().path,
            installPath: sourceRoot.path,
            manifestPath: "",
            sizeOnDisk: 5,
            buildID: "",
            stateFlags: "4",
            source: .mac,
            hasManifest: true,
            isPreloadOnly: false
        )

        _ = try SteamLibraryManager.prefillWineSteam(from: sourceGame, to: wineSteamapps)

        XCTAssertFalse(fm.fileExists(atPath: staleDownloading.path))
        XCTAssertFalse(fm.fileExists(atPath: staleTemp.path))
        XCTAssertFalse(fm.fileExists(atPath: stalePatch.path))

        try write("""
        "AppState"
        {
            "appid" "300"
            "name" "Progress Game"
            "StateFlags" "1042"
            "installdir" "Progress Game"
            "SizeOnDisk" "0"
            "BytesToDownload" "1000"
            "BytesDownloaded" "250"
            "BytesToStage" "2000"
            "BytesStaged" "500"
        }
        """, to: wineSteamapps.appendingPathComponent("appmanifest_300.acf"))
        let activeDownloading = wineSteamapps.appendingPathComponent("downloading/300", isDirectory: true)
        try fm.createDirectory(at: activeDownloading, withIntermediateDirectories: true)
        try write("chunk", to: activeDownloading.appendingPathComponent("chunk.bin"))

        let status = try XCTUnwrap(SteamLibraryManager.scanInstallStatuses(steamappsURLs: [wineSteamapps])["300"])
        XCTAssertEqual(status.bytesToDownload, 1000)
        XCTAssertEqual(status.bytesDownloaded, 250)
        XCTAssertEqual(status.bytesToStage, 2000)
        XCTAssertEqual(status.bytesStaged, 500)
        XCTAssertEqual(try XCTUnwrap(status.progressFraction), 0.25, accuracy: 0.001)
        XCTAssertTrue(status.hasDownloadingDir)
        XCTAssertNotNil(status.prefillMetadata)
        XCTAssertEqual(status.activityLabel, "下载/发现文件")
        XCTAssertFalse(status.isLaunchReady)
        let evidence = try XCTUnwrap(status.prefillEvidenceLabel)
        XCTAssertTrue(evidence.contains("Shiori 已预填充"))
        XCTAssertTrue(evidence.contains("Steam 仍需下载"))
        XCTAssertTrue(evidence.contains("以 Windows manifest 校验为准"))
    }

    func testInstallStatusWarnsWhenWindowsManifestUsesDifferentInstallDir() throws {
        let fm = FileManager.default
        let sourceRoot = tempRoot.appendingPathComponent("MacSteam/steamapps/common/Mac Dir", isDirectory: true)
        try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try write("shared data", to: sourceRoot.appendingPathComponent("shared.assets"))

        let wineSteamapps = tempRoot.appendingPathComponent("WineSteam/steamapps", isDirectory: true)
        let sourceGame = SteamLibraryGame(
            id: "mac:350:\(sourceRoot.path)",
            appID: "350",
            name: "Directory Mismatch",
            installDir: "Mac Dir",
            libraryPath: "",
            steamappsPath: "",
            installPath: sourceRoot.path,
            manifestPath: "",
            sizeOnDisk: 11,
            buildID: "",
            stateFlags: "4",
            source: .mac,
            hasManifest: true,
            isPreloadOnly: false
        )
        _ = try SteamLibraryManager.prefillWineSteam(from: sourceGame, to: wineSteamapps)

        try write("""
        "AppState"
        {
            "appid" "350"
            "name" "Directory Mismatch"
            "StateFlags" "1026"
            "installdir" "Windows Dir"
            "SizeOnDisk" "0"
            "BytesToDownload" "1000"
            "BytesDownloaded" "0"
        }
        """, to: wineSteamapps.appendingPathComponent("appmanifest_350.acf"))

        let status = try XCTUnwrap(SteamLibraryManager.scanInstallStatuses(steamappsURLs: [wineSteamapps])["350"])
        let evidence = try XCTUnwrap(status.prefillEvidenceLabel)
        XCTAssertTrue(evidence.contains("目录不一致"))
        XCTAssertTrue(evidence.contains("预填充在 Mac Dir"))
        XCTAssertTrue(evidence.contains("Steam 使用 Windows Dir"))
    }

    func testInstallStatusWarnsWhenSteamDoesNotReusePrefill() throws {
        let fm = FileManager.default
        let sourceRoot = tempRoot.appendingPathComponent("MacSteam/steamapps/common/Risk Game", isDirectory: true)
        try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try write(String(repeating: "x", count: 2048), to: sourceRoot.appendingPathComponent("shared.assets"))

        let wineSteamapps = tempRoot.appendingPathComponent("WineSteam/steamapps", isDirectory: true)
        let sourceGame = SteamLibraryGame(
            id: "mac:360:\(sourceRoot.path)",
            appID: "360",
            name: "Risk Game",
            installDir: "Risk Game",
            libraryPath: "",
            steamappsPath: "",
            installPath: sourceRoot.path,
            manifestPath: "",
            sizeOnDisk: 2048,
            buildID: "",
            stateFlags: "4",
            source: .mac,
            hasManifest: true,
            isPreloadOnly: false
        )
        _ = try SteamLibraryManager.prefillWineSteam(from: sourceGame, to: wineSteamapps)

        let target = wineSteamapps.appendingPathComponent("common/Risk Game", isDirectory: true)
        try fm.removeItem(at: target)
        try write("tiny", to: target.appendingPathComponent("tiny.dat"))
        let activeDownloading = wineSteamapps.appendingPathComponent("downloading/360", isDirectory: true)
        try write("chunk", to: activeDownloading.appendingPathComponent("chunk.dat"))
        try write("""
        "AppState"
        {
            "appid" "360"
            "name" "Risk Game"
            "StateFlags" "1042"
            "installdir" "Risk Game"
            "SizeOnDisk" "4"
            "BytesToDownload" "4096"
            "BytesDownloaded" "128"
            "BytesToStage" "4096"
            "BytesStaged" "128"
        }
        """, to: wineSteamapps.appendingPathComponent("appmanifest_360.acf"))

        let status = try XCTUnwrap(SteamLibraryManager.scanInstallStatuses(steamappsURLs: [wineSteamapps])["360"])
        let evidence = try XCTUnwrap(status.prefillEvidenceLabel)
        XCTAssertTrue(evidence.contains("复用率可能偏低"))
        XCTAssertTrue(evidence.contains("建议暂停"))
        XCTAssertTrue(evidence.contains("安装目录小于预填充"))
    }

    func testInstallStatusWarnsWhenLargeSteamDownloadAlreadyCompletedAfterPrefill() throws {
        let fm = FileManager.default
        let sourceRoot = tempRoot.appendingPathComponent("MacSteam/steamapps/common/Completed Download Game", isDirectory: true)
        try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try write(String(repeating: "x", count: 2048), to: sourceRoot.appendingPathComponent("shared.assets"))

        let wineSteamapps = tempRoot.appendingPathComponent("WineSteam/steamapps", isDirectory: true)
        let sourceGame = SteamLibraryGame(
            id: "mac:365:\(sourceRoot.path)",
            appID: "365",
            name: "Completed Download Game",
            installDir: "Completed Download Game",
            libraryPath: "",
            steamappsPath: "",
            installPath: sourceRoot.path,
            manifestPath: "",
            sizeOnDisk: 2048,
            buildID: "",
            stateFlags: "4",
            source: .mac,
            hasManifest: true,
            isPreloadOnly: false
        )
        _ = try SteamLibraryManager.prefillWineSteam(from: sourceGame, to: wineSteamapps)

        try write("""
        "AppState"
        {
            "appid" "365"
            "name" "Completed Download Game"
            "StateFlags" "4"
            "installdir" "Completed Download Game"
            "SizeOnDisk" "4096"
            "BytesToDownload" "3900"
            "BytesDownloaded" "3900"
            "BytesToStage" "4096"
            "BytesStaged" "4096"
        }
        """, to: wineSteamapps.appendingPathComponent("appmanifest_365.acf"))

        let status = try XCTUnwrap(SteamLibraryManager.scanInstallStatuses(steamappsURLs: [wineSteamapps])["365"])
        XCTAssertTrue(status.isLaunchReady)
        XCTAssertTrue(status.didCompleteLargeSteamDownloadAfterPrefill)
        XCTAssertTrue(status.prefillEvidenceNeedsAttention)
        let evidence = try XCTUnwrap(status.prefillEvidenceLabel)
        XCTAssertTrue(evidence.contains("Steam 已完成大额下载"))
        XCTAssertTrue(evidence.contains("不能视为预填充复用成功"))
        XCTAssertFalse(evidence.contains("建议暂停"))
    }

    func testPrefillRefusesExistingWineManifestForSameAppID() throws {
        let fm = FileManager.default
        let sourceRoot = tempRoot.appendingPathComponent("MacSteam/steamapps/common/Existing Game", isDirectory: true)
        try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try write("asset", to: sourceRoot.appendingPathComponent("shared.assets"))
        let wineSteamapps = tempRoot.appendingPathComponent("WineSteam/steamapps", isDirectory: true)
        try write("manifest", to: wineSteamapps.appendingPathComponent("appmanifest_400.acf"))

        let sourceGame = SteamLibraryGame(
            id: "mac:400:\(sourceRoot.path)",
            appID: "400",
            name: "Existing Game",
            installDir: "Existing Game",
            libraryPath: "",
            steamappsPath: "",
            installPath: sourceRoot.path,
            manifestPath: "",
            sizeOnDisk: 5,
            buildID: "",
            stateFlags: "4",
            source: .mac,
            hasManifest: true,
            isPreloadOnly: false
        )

        XCTAssertThrowsError(try SteamLibraryManager.prefillWineSteam(from: sourceGame, to: wineSteamapps))
    }

    func testPrefillRefusesUnknownNonEmptyTargetDirectory() throws {
        let fm = FileManager.default
        let sourceRoot = tempRoot.appendingPathComponent("MacSteam/steamapps/common/Dirty Game", isDirectory: true)
        let wineSteamapps = tempRoot.appendingPathComponent("WineSteam/steamapps", isDirectory: true)
        let dirtyTarget = wineSteamapps.appendingPathComponent("common/Dirty Game", isDirectory: true)
        try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: dirtyTarget, withIntermediateDirectories: true)
        try write("asset", to: sourceRoot.appendingPathComponent("shared.assets"))
        try write("unknown", to: dirtyTarget.appendingPathComponent("old.bin"))

        let sourceGame = SteamLibraryGame(
            id: "mac:500:\(sourceRoot.path)",
            appID: "500",
            name: "Dirty Game",
            installDir: "Dirty Game",
            libraryPath: "",
            steamappsPath: "",
            installPath: sourceRoot.path,
            manifestPath: "",
            sizeOnDisk: 5,
            buildID: "",
            stateFlags: "4",
            source: .mac,
            hasManifest: true,
            isPreloadOnly: false
        )

        XCTAssertThrowsError(try SteamLibraryManager.prefillWineSteam(from: sourceGame, to: wineSteamapps))
        XCTAssertTrue(fm.fileExists(atPath: dirtyTarget.appendingPathComponent("old.bin").path))
    }

    func testDeleteWineGameRemovesManifestInstallDirAndSteamCachesOnlyInWineLibrary() throws {
        let fm = FileManager.default
        let wineSteamapps = tempRoot.appendingPathComponent("WineSteam/steamapps", isDirectory: true)
        let install = wineSteamapps.appendingPathComponent("common/Sample", isDirectory: true)
        let manifest = wineSteamapps.appendingPathComponent("appmanifest_200.acf")
        let downloading = wineSteamapps.appendingPathComponent("downloading/200", isDirectory: true)
        let statePatch = wineSteamapps.appendingPathComponent("downloading/state_200_201.patch")
        let temp = wineSteamapps.appendingPathComponent("temp/200", isDirectory: true)
        let shadercache = wineSteamapps.appendingPathComponent("shadercache/200", isDirectory: true)
        let compatdata = wineSteamapps.appendingPathComponent("compatdata/200", isDirectory: true)
        let workshop = wineSteamapps.appendingPathComponent("workshop/content/200", isDirectory: true)
        let siblingDepotcache = wineSteamapps.deletingLastPathComponent().appendingPathComponent("depotcache", isDirectory: true)
        let nestedDepotcache = wineSteamapps.appendingPathComponent("depotcache", isDirectory: true)
        let appDepotManifest = siblingDepotcache.appendingPathComponent("200_111.manifest")
        let installedDepotManifest = siblingDepotcache.appendingPathComponent("201_222.manifest")
        let mountedDepotManifest = nestedDepotcache.appendingPathComponent("202_333.manifest")
        let otherDepotManifest = siblingDepotcache.appendingPathComponent("999_444.manifest")
        let macSteamapps = tempRoot.appendingPathComponent("MacSteam/steamapps", isDirectory: true)
        let macInstall = macSteamapps.appendingPathComponent("common/Sample", isDirectory: true)
        let metadataDirectory = wineSteamapps.appendingPathComponent(".shiori-prefill", isDirectory: true)
        let metadataURL = metadataDirectory.appendingPathComponent("200.json")

        for dir in [install, downloading, temp, shadercache, compatdata, workshop, macInstall, siblingDepotcache, nestedDepotcache] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try write("file", to: dir.appendingPathComponent("payload.dat"))
        }
        try write("""
        "AppState"
        {
            "appid" "200"
            "InstalledDepots"
            {
                "201"
                {
                    "manifest" "222"
                }
            }
            "MountedDepots"
            {
                "202" "333"
            }
        }
        """, to: manifest)
        try write("patch", to: statePatch)
        try write("manifest", to: appDepotManifest)
        try write("manifest", to: installedDepotManifest)
        try write("manifest", to: mountedDepotManifest)
        try write("manifest", to: otherDepotManifest)
        try fm.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        let metadata = SteamPrefillMetadata(
            appID: "200",
            name: "Sample",
            installDir: "Sample",
            targetPath: install.path,
            copiedFiles: 1,
            skippedFiles: 0,
            copiedBytes: 4,
            sourceSizeOnDisk: 4,
            createdAt: Date()
        )
        try JSONEncoder().encode(metadata).write(to: metadataURL)

        let game = SteamLibraryGame(
            id: "wine:200:\(wineSteamapps.path)",
            appID: "200",
            name: "Sample",
            installDir: "Sample",
            libraryPath: wineSteamapps.deletingLastPathComponent().path,
            steamappsPath: wineSteamapps.path,
            installPath: install.path,
            manifestPath: manifest.path,
            sizeOnDisk: 4,
            buildID: "1",
            stateFlags: "4",
            source: .wine,
            hasManifest: true,
            isPreloadOnly: false
        )

        try SteamLibraryManager.deleteWineGame(game)

        XCTAssertFalse(fm.fileExists(atPath: manifest.path))
        XCTAssertFalse(fm.fileExists(atPath: install.path))
        XCTAssertFalse(fm.fileExists(atPath: downloading.path))
        XCTAssertFalse(fm.fileExists(atPath: statePatch.path))
        XCTAssertFalse(fm.fileExists(atPath: temp.path))
        XCTAssertFalse(fm.fileExists(atPath: shadercache.path))
        XCTAssertFalse(fm.fileExists(atPath: compatdata.path))
        XCTAssertFalse(fm.fileExists(atPath: workshop.path))
        XCTAssertFalse(fm.fileExists(atPath: appDepotManifest.path))
        XCTAssertFalse(fm.fileExists(atPath: installedDepotManifest.path))
        XCTAssertFalse(fm.fileExists(atPath: mountedDepotManifest.path))
        XCTAssertTrue(fm.fileExists(atPath: otherDepotManifest.path))
        XCTAssertFalse(fm.fileExists(atPath: metadataURL.path))
        XCTAssertTrue(fm.fileExists(atPath: macInstall.path))
    }

    func testExcludingSteamappsURLsRemovesMacSteamRootsAndChildren() throws {
        let macSteamapps = tempRoot.appendingPathComponent("MacSteam/steamapps", isDirectory: true)
        let macChild = macSteamapps.appendingPathComponent("nested", isDirectory: true)
        let wineSteamapps = tempRoot.appendingPathComponent("WineSteam/steamapps", isDirectory: true)

        let filtered = SteamLibraryManager.excludingSteamappsURLs(
            [macSteamapps, macChild, wineSteamapps, wineSteamapps],
            under: [macSteamapps]
        )

        XCTAssertEqual(filtered, [wineSteamapps.standardizedFileURL])
    }

    func testSteamworksCommonRedistributablesIsNotShownAsAGame() throws {
        let steamapps = tempRoot.appendingPathComponent("Steam/steamapps", isDirectory: true)
        let installDir = "Steamworks Shared"
        try FileManager.default.createDirectory(
            at: steamapps.appendingPathComponent("common/\(installDir)", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write("""
        "AppState"
        {
            "appid" "228980"
            "name" "Steamworks Common Redistributables"
            "StateFlags" "4"
            "installdir" "Steamworks Shared"
            "SizeOnDisk" "1024"
        }
        """, to: steamapps.appendingPathComponent("appmanifest_228980.acf"))

        let games = SteamLibraryManager.scanGames(
            steamappsURLs: [steamapps],
            source: .wine,
            includePreloadOnly: true
        )
        let statuses = SteamLibraryManager.scanInstallStatuses(steamappsURLs: [steamapps])

        XCTAssertTrue(games.isEmpty)
        XCTAssertNil(statuses["228980"])
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)?.write(to: url)
    }
}
