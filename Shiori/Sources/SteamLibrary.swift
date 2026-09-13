import Darwin
import Foundation

enum SteamLibrarySource: String, Hashable {
    case mac
    case wine

    var title: String {
        switch self {
        case .mac: return "Mac Steam"
        case .wine: return "Wine Steam"
        }
    }
}

struct SteamLibraryGame: Identifiable, Hashable {
    var id: String
    var appID: String
    var name: String
    var installDir: String
    var libraryPath: String
    var steamappsPath: String
    var installPath: String
    var manifestPath: String
    var sizeOnDisk: Int64
    var buildID: String
    var stateFlags: String
    var source: SteamLibrarySource
    var hasManifest: Bool
    var isPreloadOnly: Bool

    var sizeLabel: String {
        guard sizeOnDisk > 0 else { return "未知大小" }
        return ByteCountFormatter.string(fromByteCount: sizeOnDisk, countStyle: .file)
    }

    var sourceLabel: String {
        if isPreloadOnly { return "本地预填充" }
        return source.title
    }
}

struct SteamPrefillReport: Hashable {
    var targetPath: String
    var copiedFiles: Int
    var skippedFiles: Int
    var copiedBytes: Int64

    var copiedSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: copiedBytes, countStyle: .file)
    }
}

struct SteamPrefillMetadata: Codable, Hashable {
    var appID: String
    var name: String
    var installDir: String
    var targetPath: String
    var copiedFiles: Int
    var skippedFiles: Int
    var copiedBytes: Int64
    var sourceSizeOnDisk: Int64
    var sourceBuildID: String? = nil
    var createdAt: Date

    var copiedSizeLabel: String {
        ByteCountFormatter.string(fromByteCount: copiedBytes, countStyle: .file)
    }
}

struct SteamInstallStatus: Hashable {
    var appID: String
    var name: String
    var installDir: String
    var steamappsPath: String
    var manifestPath: String
    var stateFlags: String
    var buildID: String
    var lastUpdated: String
    var isShioriPrefillManifest: Bool
    var bytesToDownload: Int64
    var bytesDownloaded: Int64
    var bytesToStage: Int64
    var bytesStaged: Int64
    var sizeOnDisk: Int64
    var downloadingSize: Int64
    var tempSize: Int64
    var hasDownloadingDir: Bool
    var hasTempDir: Bool
    var prefillMetadata: SteamPrefillMetadata?

    /// 仅在还在下载 / 写入时返回进度；已安装或下载与写入都完成 → nil（不显示进度条）。
    var progressFraction: Double? {
        if isLaunchReady { return nil }
        if bytesToDownload > 0, bytesDownloaded < bytesToDownload {
            return min(max(Double(bytesDownloaded) / Double(bytesToDownload), 0), 1)
        }
        if bytesToStage > 0, bytesStaged < bytesToStage {
            return min(max(Double(bytesStaged) / Double(bytesToStage), 0), 1)
        }
        return nil
    }

    var isPendingPrefillValidation: Bool {
        prefillMetadata != nil
            && !manifestPath.isEmpty
            && lastUpdated == "0"
            && (isShioriPrefillManifest || buildID.isEmpty || buildID == "0")
            && bytesToDownload == 0
            && bytesToStage == 0
    }

    var isLaunchReady: Bool {
        stateFlags == "4" && !hasDownloadingDir && !hasTempDir && !isPendingPrefillValidation
    }

    var didCompleteLargeSteamDownloadAfterPrefill: Bool {
        guard let prefillMetadata,
              bytesToDownload > 0,
              bytesDownloaded >= bytesToDownload,
              !hasDownloadingDir,
              !hasTempDir,
              prefillMetadata.copiedBytes > 0 else {
            return false
        }
        let finalBytes = max(sizeOnDisk, bytesToStage, bytesToDownload)
        guard finalBytes > 0 else { return false }
        return Double(bytesDownloaded) / Double(finalBytes) >= 0.7
            && Double(bytesDownloaded) / Double(prefillMetadata.copiedBytes) >= 0.9
    }

    var prefillEvidenceNeedsAttention: Bool {
        guard let prefillMetadata else { return false }
        if didCompleteLargeSteamDownloadAfterPrefill { return true }
        if !installDir.isEmpty, installDir.caseInsensitiveCompare(prefillMetadata.installDir) != .orderedSame {
            return true
        }
        if bytesToDownload > 0, bytesDownloaded < bytesToDownload, prefillMetadata.copiedBytes > 0 {
            let ratio = Double(bytesToDownload) / Double(prefillMetadata.copiedBytes)
            if ratio >= 0.9 { return true }
        }
        if hasDownloadingDir,
           sizeOnDisk > 0,
           prefillMetadata.copiedBytes > 0,
           Double(sizeOnDisk) / Double(prefillMetadata.copiedBytes) <= 0.5 {
            return true
        }
        return false
    }

    var activityLabel: String {
        if isLaunchReady {
            return "已安装"
        }
        if isPendingPrefillValidation {
            return "等待 Steam 校验"
        }
        if bytesToDownload > 0, bytesDownloaded < bytesToDownload {
            return "下载/发现文件"
        }
        if bytesToStage > 0, bytesStaged < bytesToStage {
            return "校验/写入"
        }
        if hasDownloadingDir || hasTempDir {
            return "下载/校验中"
        }
        if manifestPath.isEmpty {
            return "等待安装/验证"
        }
        return stateFlags.isEmpty ? "未知状态" : "Steam 状态 \(stateFlags)"
    }

    var detailLabel: String {
        var parts = [activityLabel]
        if bytesToDownload > 0 {
            parts.append("下载 \(byteLabel(bytesDownloaded))/\(byteLabel(bytesToDownload))")
        }
        if bytesToStage > 0 {
            parts.append("写入 \(byteLabel(bytesStaged))/\(byteLabel(bytesToStage))")
        }
        if hasDownloadingDir {
            parts.append("downloading \(byteLabel(downloadingSize))")
        }
        if hasTempDir, tempSize > 0 {
            parts.append("temp \(byteLabel(tempSize))")
        }
        return parts.joined(separator: " · ")
    }

    var prefillEvidenceLabel: String? {
        guard let prefillMetadata else { return nil }
        var parts = ["Shiori 已预填充 \(prefillMetadata.copiedSizeLabel)"]
        if manifestPath.isEmpty {
            parts.append("等待在 Wine Steam 安装窗口确认")
        } else if isPendingPrefillValidation {
            parts.append("已写入 Wine manifest，等待 Steam 验证")
        }
        if !installDir.isEmpty, installDir.caseInsensitiveCompare(prefillMetadata.installDir) != .orderedSame {
            parts.append("目录不一致：预填充在 \(prefillMetadata.installDir)，Steam 使用 \(installDir)")
        }
        if bytesToDownload > 0 {
            let remaining = max(bytesToDownload - bytesDownloaded, 0)
            parts.append("Steam 仍需下载 \(byteLabel(remaining))/\(byteLabel(bytesToDownload))")
        }
        if didCompleteLargeSteamDownloadAfterPrefill {
            parts.append("Steam 已完成大额下载，这次不能视为预填充复用成功")
        }
        if bytesToDownload > 0, prefillMetadata.copiedBytes > 0 {
            let ratio = Double(bytesToDownload) / Double(prefillMetadata.copiedBytes)
            if ratio >= 0.9, bytesDownloaded < bytesToDownload {
                parts.append("复用率可能偏低，建议暂停并用 Shiori 删除后重新预填充")
            } else if ratio <= 0.35 {
                parts.append("预填充可能有效")
            }
        }
        if hasDownloadingDir,
           sizeOnDisk > 0,
           prefillMetadata.copiedBytes > 0,
           Double(sizeOnDisk) / Double(prefillMetadata.copiedBytes) <= 0.5 {
            parts.append("安装目录小于预填充，可能被 Steam 重新 staging")
        }
        parts.append("以 Windows manifest 校验为准")
        return parts.joined(separator: " · ")
    }

    private func byteLabel(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

enum SteamLibraryManager {
    /// Steam-managed components that have app manifests but are not user-launchable games.
    private static let nonGameAppIDs: Set<String> = ["228980"]

    static func macSteamappsURLs(home: URL, fileManager fm: FileManager = .default) -> [URL] {
        let defaultRoot = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Steam", isDirectory: true)
        var urls = [defaultRoot.appendingPathComponent("steamapps", isDirectory: true)]

        let libraryFoldersURL = defaultRoot
            .appendingPathComponent("steamapps", isDirectory: true)
            .appendingPathComponent("libraryfolders.vdf")
        for rootPath in parseLibraryFolderPaths(from: libraryFoldersURL) {
            let steamappsURL = URL(fileURLWithPath: rootPath, isDirectory: true)
                .appendingPathComponent("steamapps", isDirectory: true)
            urls.append(steamappsURL)
        }

        return uniqueExistingDirectories(urls, fileManager: fm)
    }

    static func steamappsURLsFromLibraryFolders(steamappsURL: URL, winePrefixURL: URL? = nil, fileManager fm: FileManager = .default) -> [URL] {
        let libraryFoldersURL = steamappsURL.appendingPathComponent("libraryfolders.vdf")
        let libraryRoots = parseLibraryFolderPaths(from: libraryFoldersURL)
        let urls = libraryRoots.compactMap { rootPath -> URL? in
            let rootURL: URL
            if let winePrefixURL, let converted = urlForWinePath(rootPath, prefixURL: winePrefixURL, fileManager: fm) {
                rootURL = converted
            } else {
                rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            }
            return rootURL.appendingPathComponent("steamapps", isDirectory: true)
        }
        return uniqueExistingDirectories(urls, fileManager: fm)
    }

    static func scanMacGames(home: URL, fileManager fm: FileManager = .default) -> [SteamLibraryGame] {
        scanGames(steamappsURLs: macSteamappsURLs(home: home, fileManager: fm), source: .mac, includePreloadOnly: false, fileManager: fm)
    }

    static func scanWineGames(steamappsURLs: [URL], fileManager fm: FileManager = .default) -> [SteamLibraryGame] {
        scanGames(steamappsURLs: uniqueExistingDirectories(steamappsURLs, fileManager: fm), source: .wine, includePreloadOnly: true, fileManager: fm)
    }

    static func scanInstallStatuses(steamappsURLs: [URL], fileManager fm: FileManager = .default) -> [String: SteamInstallStatus] {
        var statuses: [String: SteamInstallStatus] = [:]

        for steamappsURL in uniqueExistingDirectories(steamappsURLs, fileManager: fm) {
            let prefillByAppID = prefillMetadataByAppID(in: steamappsURL, fileManager: fm)
            let manifestURLs = (try? fm.contentsOfDirectory(
                at: steamappsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?.filter {
                $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension.lowercased() == "acf"
            } ?? []

            for manifestURL in manifestURLs {
                guard let status = parseInstallStatus(
                    manifestURL,
                    steamappsURL: steamappsURL,
                    prefillMetadata: prefillByAppID,
                    fileManager: fm
                ), !nonGameAppIDs.contains(status.appID) else {
                    continue
                }
                statuses[status.appID] = status
            }

            for metadata in prefillByAppID.values
            where statuses[metadata.appID] == nil && !nonGameAppIDs.contains(metadata.appID) {
                let downloadingURL = steamappsURL
                    .appendingPathComponent("downloading", isDirectory: true)
                    .appendingPathComponent(metadata.appID, isDirectory: true)
                let tempURL = steamappsURL
                    .appendingPathComponent("temp", isDirectory: true)
                    .appendingPathComponent(metadata.appID, isDirectory: true)
                statuses[metadata.appID] = SteamInstallStatus(
                    appID: metadata.appID,
                    name: metadata.name,
                    installDir: metadata.installDir,
                    steamappsPath: steamappsURL.path,
                    manifestPath: "",
                    stateFlags: "",
                    buildID: "",
                    lastUpdated: "",
                    isShioriPrefillManifest: false,
                    bytesToDownload: 0,
                    bytesDownloaded: 0,
                    bytesToStage: 0,
                    bytesStaged: 0,
                    sizeOnDisk: directorySize(URL(fileURLWithPath: metadata.targetPath, isDirectory: true), fileManager: fm),
                    downloadingSize: directorySize(downloadingURL, fileManager: fm),
                    tempSize: directorySize(tempURL, fileManager: fm),
                    hasDownloadingDir: fm.fileExists(atPath: downloadingURL.path),
                    hasTempDir: fm.fileExists(atPath: tempURL.path),
                    prefillMetadata: metadata
                )
            }
        }

        return statuses
    }

    static func excludingSteamappsURLs(_ urls: [URL], under excludedRoots: [URL]) -> [URL] {
        let excludedPaths = excludedRoots.map { $0.standardizedFileURL.path }
        var seen = Set<String>()
        return urls.compactMap { url in
            let path = url.standardizedFileURL.path
            guard !excludedPaths.contains(where: { excluded in
                let prefix = excluded.hasSuffix("/") ? excluded : excluded + "/"
                return path == excluded || path.hasPrefix(prefix)
            }) else {
                return nil
            }
            guard seen.insert(path).inserted else { return nil }
            return url
        }
    }

    static func scanGames(steamappsURLs: [URL], source: SteamLibrarySource, includePreloadOnly: Bool, fileManager fm: FileManager = .default) -> [SteamLibraryGame] {
        var games: [SteamLibraryGame] = []
        var seenIDs = Set<String>()

        for steamappsURL in steamappsURLs {
            let prefillByInstallDir = prefillMetadataByInstallDir(in: steamappsURL, fileManager: fm)
            let manifestURLs = (try? fm.contentsOfDirectory(
                at: steamappsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?.filter {
                $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension.lowercased() == "acf"
            } ?? []

            var manifestInstallDirs = Set<String>()
            for manifestURL in manifestURLs {
                guard let game = parseAppManifest(manifestURL, steamappsURL: steamappsURL, source: source, fileManager: fm) else {
                    continue
                }
                manifestInstallDirs.insert(game.installDir)
                guard !nonGameAppIDs.contains(game.appID) else { continue }
                if seenIDs.insert(game.id).inserted {
                    games.append(game)
                }
            }

            guard includePreloadOnly else { continue }
            let commonURL = steamappsURL.appendingPathComponent("common", isDirectory: true)
            let commonDirs = (try? fm.contentsOfDirectory(
                at: commonURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for installURL in commonDirs {
                let values = try? installURL.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                let installDir = installURL.lastPathComponent
                guard !manifestInstallDirs.contains(installDir) else { continue }
                let metadata = prefillByInstallDir[installDir]
                guard !nonGameAppIDs.contains(metadata?.appID ?? "") else { continue }
                let path = installURL.standardizedFileURL.path
                let game = SteamLibraryGame(
                    id: metadata.map { "wine-preload:\($0.appID):\(steamappsURL.standardizedFileURL.path)" } ?? "wine-preload:\(path)",
                    appID: metadata?.appID ?? "",
                    name: metadata?.name ?? installDir,
                    installDir: installDir,
                    libraryPath: steamappsURL.deletingLastPathComponent().path,
                    steamappsPath: steamappsURL.path,
                    installPath: path,
                    manifestPath: "",
                    sizeOnDisk: directorySize(installURL, fileManager: fm),
                    buildID: "",
                    stateFlags: "",
                    source: source,
                    hasManifest: false,
                    isPreloadOnly: true
                )
                if seenIDs.insert(game.id).inserted {
                    games.append(game)
                }
            }
        }

        return games.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func wineSteamappsURL(for context: WineSteamEntryContext) -> URL {
        URL(fileURLWithPath: context.steamExePath)
            .deletingLastPathComponent()
            .appendingPathComponent("steamapps", isDirectory: true)
    }

    static func defaultWineSteamappsURL(appDataDir: URL) -> URL {
        appDataDir
            .appendingPathComponent("steam-prefix", isDirectory: true)
            .appendingPathComponent("drive_c", isDirectory: true)
            .appendingPathComponent("Program Files (x86)", isDirectory: true)
            .appendingPathComponent("Steam", isDirectory: true)
            .appendingPathComponent("steamapps", isDirectory: true)
    }

    static func prefillWineSteam(from sourceGame: SteamLibraryGame, to wineSteamappsURL: URL, fileManager fm: FileManager = .default) throws -> SteamPrefillReport {
        let sourceURL = URL(fileURLWithPath: sourceGame.installPath, isDirectory: true)
        if !sourceGame.appID.isEmpty {
            let manifestURL = wineSteamappsURL.appendingPathComponent("appmanifest_\(sourceGame.appID).acf")
            if fm.fileExists(atPath: manifestURL.path) {
                throw NSError(
                    domain: "ShioriSteamPrefill",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Wine Steam 已存在该 AppID 的安装清单。请先在 Shiori 的 Wine Steam 游戏列表中删除旧安装/下载任务，再重新预填充。"]
                )
            }
            try removeSteamDownloadState(appID: sourceGame.appID, steamappsURL: wineSteamappsURL, fileManager: fm)
        }

        let commonURL = wineSteamappsURL.appendingPathComponent("common", isDirectory: true)
        let targetURL = commonURL.appendingPathComponent(sourceGame.installDir, isDirectory: true)
        try preparePrefillTarget(sourceGame: sourceGame, targetURL: targetURL, steamappsURL: wineSteamappsURL, fileManager: fm)
        try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)

        var report = SteamPrefillReport(targetPath: targetURL.path, copiedFiles: 0, skippedFiles: 0, copiedBytes: 0)
        if isAppBundleLikeRoot(sourceURL, fileManager: fm) {
            try copyBundlePayload(from: sourceURL, bundleBaseName: sourceGame.installDir, to: targetURL, report: &report, fileManager: fm)
        } else {
            try copyDirectoryContents(from: sourceURL, to: targetURL, report: &report, fileManager: fm)
        }

        if !sourceGame.appID.isEmpty {
            let metadata = SteamPrefillMetadata(
                appID: sourceGame.appID,
                name: sourceGame.name,
                installDir: sourceGame.installDir,
                targetPath: targetURL.path,
                copiedFiles: report.copiedFiles,
                skippedFiles: report.skippedFiles,
                copiedBytes: report.copiedBytes,
                sourceSizeOnDisk: sourceGame.sizeOnDisk,
                sourceBuildID: sourceGame.buildID,
                createdAt: Date()
            )
            try writePrefillMetadata(metadata, in: wineSteamappsURL, fileManager: fm)
            try writePrefillAppManifest(metadata, in: wineSteamappsURL, fileManager: fm)
        }
        return report
    }

    private static func preparePrefillTarget(
        sourceGame: SteamLibraryGame,
        targetURL: URL,
        steamappsURL: URL,
        fileManager fm: FileManager
    ) throws {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue else {
            throw NSError(
                domain: "ShioriSteamPrefill",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Wine Steam 目标路径已存在且不是文件夹：\(targetURL.path)"]
            )
        }
        if directoryIsEmpty(targetURL, fileManager: fm) {
            return
        }

        let metadataByAppID = sourceGame.appID.isEmpty
            ? nil
            : prefillMetadataByAppID(in: steamappsURL, fileManager: fm)[sourceGame.appID]
        let metadata = metadataByAppID ?? prefillMetadataByInstallDir(in: steamappsURL, fileManager: fm)[sourceGame.installDir]
        guard let metadata,
              metadata.installDir == sourceGame.installDir,
              sourceGame.appID.isEmpty || metadata.appID == sourceGame.appID else {
            throw NSError(
                domain: "ShioriSteamPrefill",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Wine Steam 已存在同名目录，但不是 Shiori 可确认的同 AppID 预填充。请先在 Wine Steam 游戏列表中删除该目录，再重新预填充。"]
            )
        }

        try fm.removeItem(at: targetURL)
    }

    static func deleteWineGame(_ game: SteamLibraryGame, fileManager fm: FileManager = .default) throws {
        let manifestText = game.manifestPath.isEmpty ? nil : try? String(contentsOfFile: game.manifestPath, encoding: .utf8)
        if !game.manifestPath.isEmpty, fm.fileExists(atPath: game.manifestPath) {
            try fm.removeItem(atPath: game.manifestPath)
        }
        if !game.installPath.isEmpty, fm.fileExists(atPath: game.installPath) {
            try fm.removeItem(atPath: game.installPath)
        }
        if !game.appID.isEmpty {
            let steamappsURL = URL(fileURLWithPath: game.steamappsPath, isDirectory: true)
            let cleanupTargets = [
                steamappsURL.appendingPathComponent("downloading", isDirectory: true).appendingPathComponent(game.appID, isDirectory: true),
                steamappsURL.appendingPathComponent("temp", isDirectory: true).appendingPathComponent(game.appID, isDirectory: true),
                steamappsURL.appendingPathComponent("shadercache", isDirectory: true).appendingPathComponent(game.appID, isDirectory: true),
                steamappsURL.appendingPathComponent("compatdata", isDirectory: true).appendingPathComponent(game.appID, isDirectory: true),
                steamappsURL
                    .appendingPathComponent("workshop", isDirectory: true)
                    .appendingPathComponent("content", isDirectory: true)
                    .appendingPathComponent(game.appID, isDirectory: true)
            ]
            for target in cleanupTargets where fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try removeSteamDownloadStatePatchFiles(appID: game.appID, steamappsURL: steamappsURL, fileManager: fm)
            try removeDepotManifestFiles(appID: game.appID, manifestText: manifestText, steamappsURL: steamappsURL, fileManager: fm)
        }
        try removePrefillMetadata(for: game, fileManager: fm)
    }

    private static func parseInstallStatus(
        _ manifestURL: URL,
        steamappsURL: URL,
        prefillMetadata: [String: SteamPrefillMetadata],
        fileManager fm: FileManager
    ) -> SteamInstallStatus? {
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else { return nil }
        let values = parseVDFKeyValues(text)
        guard let appID = values["appid"] ?? appIDFromManifestFilename(manifestURL) else { return nil }
        let installDir = values["installdir"] ?? ""
        let installURL = installDir.isEmpty
            ? steamappsURL.appendingPathComponent("common", isDirectory: true)
            : steamappsURL.appendingPathComponent("common", isDirectory: true).appendingPathComponent(installDir, isDirectory: true)
        let downloadingURL = steamappsURL
            .appendingPathComponent("downloading", isDirectory: true)
            .appendingPathComponent(appID, isDirectory: true)
        let tempURL = steamappsURL
            .appendingPathComponent("temp", isDirectory: true)
            .appendingPathComponent(appID, isDirectory: true)

        return SteamInstallStatus(
            appID: appID,
            name: values["name"] ?? prefillMetadata[appID]?.name ?? installDir,
            installDir: installDir,
            steamappsPath: steamappsURL.path,
            manifestPath: manifestURL.path,
            stateFlags: values["StateFlags"] ?? "",
            buildID: values["buildid"] ?? "",
            lastUpdated: values["LastUpdated"] ?? "",
            isShioriPrefillManifest: values["ShioriPrefill"] == "1",
            bytesToDownload: int64Value(values["BytesToDownload"]),
            bytesDownloaded: int64Value(values["BytesDownloaded"]),
            bytesToStage: int64Value(values["BytesToStage"]),
            bytesStaged: int64Value(values["BytesStaged"]),
            sizeOnDisk: int64Value(values["SizeOnDisk"]) > 0 ? int64Value(values["SizeOnDisk"]) : directorySize(installURL, fileManager: fm),
            downloadingSize: directorySize(downloadingURL, fileManager: fm),
            tempSize: directorySize(tempURL, fileManager: fm),
            hasDownloadingDir: fm.fileExists(atPath: downloadingURL.path),
            hasTempDir: fm.fileExists(atPath: tempURL.path),
            prefillMetadata: prefillMetadata[appID]
        )
    }

    private static func removeSteamDownloadState(appID: String, steamappsURL: URL, fileManager fm: FileManager) throws {
        guard !appID.isEmpty else { return }
        let cleanupTargets = [
            steamappsURL.appendingPathComponent("downloading", isDirectory: true).appendingPathComponent(appID, isDirectory: true),
            steamappsURL.appendingPathComponent("temp", isDirectory: true).appendingPathComponent(appID, isDirectory: true)
        ]
        for target in cleanupTargets where fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try removeSteamDownloadStatePatchFiles(appID: appID, steamappsURL: steamappsURL, fileManager: fm)
    }

    private static func removeSteamDownloadStatePatchFiles(appID: String, steamappsURL: URL, fileManager fm: FileManager) throws {
        guard !appID.isEmpty else { return }
        let downloadingURL = steamappsURL.appendingPathComponent("downloading", isDirectory: true)
        let patchURLs = (try? fm.contentsOfDirectory(
            at: downloadingURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter {
            $0.lastPathComponent.hasPrefix("state_\(appID)_") && $0.pathExtension.lowercased() == "patch"
        } ?? []
        for url in patchURLs {
            try fm.removeItem(at: url)
        }
    }

    private static func removeDepotManifestFiles(appID: String, manifestText: String?, steamappsURL: URL, fileManager fm: FileManager) throws {
        var depotIDs = Set<String>()
        depotIDs.insert(appID)
        if let manifestText {
            depotIDs.formUnion(installedDepotIDs(in: manifestText))
        }

        let depotcacheURLs = uniqueExistingDirectories([
            steamappsURL.appendingPathComponent("depotcache", isDirectory: true),
            steamappsURL.deletingLastPathComponent().appendingPathComponent("depotcache", isDirectory: true)
        ], fileManager: fm)

        for depotcacheURL in depotcacheURLs {
            let manifestURLs = (try? fm.contentsOfDirectory(
                at: depotcacheURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?.filter { url in
                guard url.pathExtension.lowercased() == "manifest" else { return false }
                return depotIDs.contains { depotID in
                    url.lastPathComponent.hasPrefix("\(depotID)_")
                }
            } ?? []

            for url in manifestURLs {
                try fm.removeItem(at: url)
            }
        }
    }

    private static func installedDepotIDs(in manifestText: String) -> Set<String> {
        var depotIDs = Set<String>()
        var pendingKey: String?
        var section: String?
        var sectionDepth = 0

        for rawLine in manifestText.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let key = firstQuotedValue(in: line) {
                if section != nil, sectionDepth == 0, key.allSatisfy(\.isNumber) {
                    depotIDs.insert(key)
                }
                pendingKey = key
            }

            if line == "{" {
                if pendingKey == "InstalledDepots" || pendingKey == "MountedDepots" {
                    section = pendingKey
                    sectionDepth = 0
                } else if section != nil {
                    sectionDepth += 1
                }
                pendingKey = nil
            } else if line == "}" {
                if section != nil {
                    if sectionDepth == 0 {
                        section = nil
                    } else {
                        sectionDepth -= 1
                    }
                }
                pendingKey = nil
            }
        }

        return depotIDs
    }

    private static func firstQuotedValue(in line: String) -> String? {
        guard line.first == "\"" else { return nil }
        let valueStart = line.index(after: line.startIndex)
        guard let valueEnd = line[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(line[valueStart..<valueEnd])
    }

    private static func prefillMetadataDirectory(in steamappsURL: URL) -> URL {
        steamappsURL.appendingPathComponent(".shiori-prefill", isDirectory: true)
    }

    private static func prefillMetadataURL(for appID: String, in steamappsURL: URL) -> URL {
        prefillMetadataDirectory(in: steamappsURL).appendingPathComponent("\(appID).json")
    }

    private static func writePrefillMetadata(_ metadata: SteamPrefillMetadata, in steamappsURL: URL, fileManager fm: FileManager) throws {
        let directory = prefillMetadataDirectory(in: steamappsURL)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: prefillMetadataURL(for: metadata.appID, in: steamappsURL), options: [.atomic])
    }

    private static func writePrefillAppManifest(_ metadata: SteamPrefillMetadata, in steamappsURL: URL, fileManager fm: FileManager) throws {
        let manifestURL = steamappsURL.appendingPathComponent("appmanifest_\(metadata.appID).acf")
        let buildID = metadata.sourceBuildID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? metadata.sourceBuildID!
            : "0"
        let text = """
        "AppState"
        {
            "appid"        "\(vdfEscaped(metadata.appID))"
            "Universe"        "1"
            "ShioriPrefill"        "1"
            "name"        "\(vdfEscaped(metadata.name))"
            "StateFlags"        "4"
            "installdir"        "\(vdfEscaped(metadata.installDir))"
            "LastUpdated"        "0"
            "LastPlayed"        "0"
            "SizeOnDisk"        "\(metadata.copiedBytes)"
            "StagingSize"        "0"
            "buildid"        "\(vdfEscaped(buildID))"
            "DownloadType"        "1"
            "UpdateResult"        "0"
            "BytesToDownload"        "0"
            "BytesDownloaded"        "0"
            "BytesToStage"        "0"
            "BytesStaged"        "0"
            "TargetBuildID"        "\(vdfEscaped(buildID))"
            "AutoUpdateBehavior"        "0"
            "AllowOtherDownloadsWhileRunning"        "0"
            "ScheduledAutoUpdate"        "0"
            "FullValidateAfterNextUpdate"        "1"
            "InstalledDepots"
            {
            }
            "UserConfig"
            {
                "language"        "english"
            }
            "MountedConfig"
            {
            }
        }

        """
        try fm.createDirectory(at: steamappsURL, withIntermediateDirectories: true)
        try text.data(using: .utf8)?.write(to: manifestURL, options: [.atomic])
    }

    private static func vdfEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func prefillMetadata(in steamappsURL: URL, fileManager fm: FileManager) -> [SteamPrefillMetadata] {
        let directory = prefillMetadataDirectory(in: steamappsURL)
        let urls = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension.lowercased() == "json" } ?? []
        let decoder = JSONDecoder()
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(SteamPrefillMetadata.self, from: data)
        }
    }

    private static func prefillMetadataByAppID(in steamappsURL: URL, fileManager fm: FileManager) -> [String: SteamPrefillMetadata] {
        Dictionary(uniqueKeysWithValues: prefillMetadata(in: steamappsURL, fileManager: fm).map { ($0.appID, $0) })
    }

    private static func prefillMetadataByInstallDir(in steamappsURL: URL, fileManager fm: FileManager) -> [String: SteamPrefillMetadata] {
        Dictionary(uniqueKeysWithValues: prefillMetadata(in: steamappsURL, fileManager: fm).map { ($0.installDir, $0) })
    }

    private static func removePrefillMetadata(for game: SteamLibraryGame, fileManager fm: FileManager) throws {
        guard !game.steamappsPath.isEmpty else { return }
        let steamappsURL = URL(fileURLWithPath: game.steamappsPath, isDirectory: true)
        let directory = prefillMetadataDirectory(in: steamappsURL)
        let urls = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension.lowercased() == "json" } ?? []
        let decoder = JSONDecoder()
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let metadata = try? decoder.decode(SteamPrefillMetadata.self, from: data) else {
                continue
            }
            if (!game.appID.isEmpty && metadata.appID == game.appID) || metadata.installDir == game.installDir {
                try fm.removeItem(at: url)
            }
        }
    }

    private static func parseAppManifest(_ manifestURL: URL, steamappsURL: URL, source: SteamLibrarySource, fileManager fm: FileManager) -> SteamLibraryGame? {
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else { return nil }
        let values = parseVDFKeyValues(text)
        guard let appID = values["appid"], let installDir = values["installdir"] else { return nil }
        let name = values["name"] ?? installDir
        let installURL = steamappsURL
            .appendingPathComponent("common", isDirectory: true)
            .appendingPathComponent(installDir, isDirectory: true)
        let size = Int64(values["SizeOnDisk"] ?? "") ?? directorySize(installURL, fileManager: fm)

        return SteamLibraryGame(
            id: "\(source.rawValue):\(appID):\(steamappsURL.standardizedFileURL.path)",
            appID: appID,
            name: name,
            installDir: installDir,
            libraryPath: steamappsURL.deletingLastPathComponent().path,
            steamappsPath: steamappsURL.path,
            installPath: installURL.path,
            manifestPath: manifestURL.path,
            sizeOnDisk: size,
            buildID: values["buildid"] ?? "",
            stateFlags: values["StateFlags"] ?? "",
            source: source,
            hasManifest: true,
            isPreloadOnly: false
        )
    }

    private static func parseLibraryFolderPaths(from url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseVDFRepeatedValues(text, key: "path")
    }

    private static func parseVDFKeyValues(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let tokens = quotedTokens(in: String(line))
            guard tokens.count >= 2 else { continue }
            result[tokens[0]] = tokens[1]
        }
        return result
    }

    private static func parseVDFRepeatedValues(_ text: String, key: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let tokens = quotedTokens(in: String(line))
            guard tokens.count >= 2, tokens[0] == key else { return nil }
            return tokens[1]
        }
    }

    private static func int64Value(_ raw: String?) -> Int64 {
        Int64(raw ?? "") ?? 0
    }

    private static func appIDFromManifestFilename(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("appmanifest_") else { return nil }
        let appID = String(name.dropFirst("appmanifest_".count))
        return appID.isEmpty ? nil : appID
    }

    private static func directoryIsEmpty(_ url: URL, fileManager fm: FileManager) -> Bool {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return true
        }
        return enumerator.nextObject() == nil
    }

    private static func quotedTokens(in line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var escaping = false

        for ch in line {
            if escaping {
                current.append(ch)
                escaping = false
                continue
            }
            if ch == "\\" {
                escaping = true
                continue
            }
            if ch == "\"" {
                if inQuote {
                    tokens.append(current)
                    current = ""
                }
                inQuote.toggle()
            } else if inQuote {
                current.append(ch)
            }
        }

        return tokens
    }

    private static func uniqueExistingDirectories(_ urls: [URL], fileManager fm: FileManager) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let standardized = url.standardizedFileURL
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: standardized.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard seen.insert(standardized.path).inserted else { continue }
            result.append(standardized)
        }
        return result
    }

    private static func urlForWinePath(_ rawPath: String, prefixURL: URL, fileManager fm: FileManager) -> URL? {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard normalized.count >= 3,
              let drive = normalized.first?.lowercased(),
              normalized.dropFirst().first == ":",
              normalized.dropFirst(2).first == "/" else {
            if normalized.hasPrefix("/") {
                return URL(fileURLWithPath: normalized, isDirectory: true)
            }
            return nil
        }

        let rest = String(normalized.dropFirst(3))
        let driveRoot: URL
        if drive == "c" {
            driveRoot = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        } else if drive == "z" {
            driveRoot = URL(fileURLWithPath: "/", isDirectory: true)
        } else {
            let dosDevice = prefixURL
                .appendingPathComponent("dosdevices", isDirectory: true)
                .appendingPathComponent("\(drive):")
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: dosDevice.path) else {
                return nil
            }
            if destination.hasPrefix("/") {
                driveRoot = URL(fileURLWithPath: destination, isDirectory: true)
            } else {
                driveRoot = dosDevice.deletingLastPathComponent().appendingPathComponent(destination, isDirectory: true)
            }
        }

        return rest.isEmpty
            ? driveRoot
            : rest.split(separator: "/").reduce(driveRoot) { partial, component in
                partial.appendingPathComponent(String(component), isDirectory: true)
            }
    }

    private static func copyDirectoryContents(from source: URL, to destination: URL, report: inout SteamPrefillReport, fileManager fm: FileManager) throws {
        let items = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])
        for item in items {
            if item.pathExtension.lowercased() == "app" {
                try copyBundlePayload(from: item, bundleBaseName: item.deletingPathExtension().lastPathComponent, to: destination, report: &report, fileManager: fm)
                continue
            }
            let target = destination.appendingPathComponent(item.lastPathComponent, isDirectory: false)
            try copyFilteredItem(from: item, to: target, report: &report, fileManager: fm)
        }
    }

    private static func copyBundlePayload(from bundleURL: URL, bundleBaseName: String, to destination: URL, report: inout SteamPrefillReport, fileManager fm: FileManager) throws {
        let resourcesURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        guard fm.fileExists(atPath: resourcesURL.path) else {
            report.skippedFiles += 1
            return
        }

        let unityDataURL = resourcesURL.appendingPathComponent("Data", isDirectory: true)
        if fm.fileExists(atPath: unityDataURL.path) {
            let executableBaseName = bundleExecutableName(bundleURL, fileManager: fm) ?? bundleBaseName
            let dataTarget = destination.appendingPathComponent("\(executableBaseName)_Data", isDirectory: true)
            try copyFilteredItem(from: unityDataURL, to: dataTarget, report: &report, fileManager: fm)
        }

        let autorunURL = resourcesURL.appendingPathComponent("autorun", isDirectory: true)
        if fm.fileExists(atPath: autorunURL.path) {
            try copyDirectoryContents(from: autorunURL, to: destination, report: &report, fileManager: fm)
        }

        for folderName in ["game", "www"] {
            let folderURL = resourcesURL.appendingPathComponent(folderName, isDirectory: true)
            if fm.fileExists(atPath: folderURL.path) {
                try copyFilteredItem(
                    from: folderURL,
                    to: destination.appendingPathComponent(folderName, isDirectory: true),
                    report: &report,
                    fileManager: fm
                )
            }
        }

        let rootResources = try fm.contentsOfDirectory(at: resourcesURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])
        for item in rootResources {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            guard shouldCopyResourceDirectoryFromBundle(item) else { continue }
            try copyFilteredItem(
                from: item,
                to: destination.appendingPathComponent(item.lastPathComponent, isDirectory: true),
                report: &report,
                fileManager: fm
            )
        }

        for item in rootResources {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory != true else { continue }
            guard shouldCopyResourceFileFromBundle(item) else {
                report.skippedFiles += 1
                continue
            }
            try copyFilteredItem(
                from: item,
                to: destination.appendingPathComponent(item.lastPathComponent),
                report: &report,
                fileManager: fm
            )
        }
    }

    private static func copyFilteredItem(from source: URL, to destination: URL, report: inout SteamPrefillReport, fileManager fm: FileManager) throws {
        if shouldSkipForWine(source) {
            report.skippedFiles += 1
            return
        }

        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values.isDirectory == true {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let items = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])
            for item in items {
                try copyFilteredItem(from: item, to: destination.appendingPathComponent(item.lastPathComponent), report: &report, fileManager: fm)
            }
            return
        }

        if fm.fileExists(atPath: destination.path) {
            report.skippedFiles += 1
            return
        }

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cloneOrCopyFile(from: source, to: destination, fileManager: fm)
        report.copiedFiles += 1
        report.copiedBytes += Int64(values.fileSize ?? 0)
    }

    private static func shouldSkipForWine(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == ".DS_Store" || name.hasPrefix("._") || name == "__MACOSX" { return true }
        if name == "Info.plist" || name == "PkgInfo" || name == "embedded.provisionprofile" { return true }

        let ext = url.pathExtension.lowercased()
        let skippedExtensions: Set<String> = [
            "app", "dylib", "so", "bundle", "framework", "icns", "nib",
            "storyboardc", "xpc", "appex", "prefpane", "qlgenerator"
        ]
        return skippedExtensions.contains(ext)
    }

    private static func shouldCopyResourceDirectoryFromBundle(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".lproj") { return false }
        return name == "resources"
            || name.hasPrefix("resources.")
            || name == "assets"
    }

    private static func shouldCopyResourceFileFromBundle(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let resourceExtensions: Set<String> = [
            "pak", "arc", "bin", "assets", "resource", "res",
            "obb", "zip", "7z", "png", "jpg", "jpeg", "webp", "ogg",
            "wav", "mp3", "bank", "json", "csv", "txt"
        ]
        return resourceExtensions.contains(ext)
    }

    private static func bundleExecutableName(_ bundleURL: URL, fileManager fm: FileManager) -> String? {
        let infoURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let executable = dict["CFBundleExecutable"] as? String else {
            return nil
        }
        let trimmed = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isAppBundleLikeRoot(_ url: URL, fileManager fm: FileManager) -> Bool {
        fm.fileExists(atPath: url.appendingPathComponent("Contents", isDirectory: true).path)
            && fm.fileExists(atPath: url.appendingPathComponent("Contents/Resources", isDirectory: true).path)
    }

    private static func cloneOrCopyFile(from source: URL, to destination: URL, fileManager fm: FileManager) throws {
        if clonefile(source.path, destination.path, 0) == 0 {
            return
        }
        try fm.copyItem(at: source, to: destination)
    }

    private static func directorySize(_ url: URL, fileManager fm: FileManager) -> Int64 {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            size += Int64(values.fileSize ?? 0)
        }
        return size
    }
}
