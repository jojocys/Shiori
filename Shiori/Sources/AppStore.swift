import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    private static func storageHome() -> URL {
        if Bundle.main.bundleIdentifier == "com.jojocys.shiori.update-test",
           let path = Bundle.main.object(forInfoDictionaryKey: "ShioriTestingDataDirectory") as? String {
            return URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("isolated-home")
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    private static let steamInstallerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
    /// Steam 关窗后会保持后台运行，Wine 的 Dock reopen 只能恢复已有的最小化窗口。
    /// 将这个 URL 转交给现有 Steam 实例，才能让 Steam 自己重建已关闭/隐藏的主窗口。

    @Published var games: [GameEntry] = []
    @Published var selectedGameID: UUID?
    @Published var statusMessage: String = "欢迎使用：先在 P1 选择游戏文件夹。"
    @Published var lastLogPath: String = ""

    @Published var scanResult: ScanResult?
    @Published var runtimeReport = RuntimeCheckReport(items: [], resolvedWineBinaryPath: "", detectedWineAppPath: "", rosettaInstalled: false, xquartzInstalled: false, gatekeeperBlocked: false)
    @Published var isDownloadingInstaller = false
    @Published var downloadStatusText: String = ""
    @Published var isManagingFontCompatibility = false
    @Published var fontCompatibilityStatusText = "尚未检测当前 Prefix 的中日文字体兼容状态。"
    @Published var macSteamGames: [SteamLibraryGame] = []
    @Published var wineSteamGames: [SteamLibraryGame] = []
    @Published var wineSteamInstallStatuses: [String: SteamInstallStatus] = [:]
    // 已确认检测到游戏进程的 Wine Steam AppID，保留为本地启动历史。
    @Published var launchedWineSteamAppIDs: Set<String> = []
    @Published var launchingWineSteamAppIDs: Set<String> = []
    @Published var isWineSteamRunning = false
    @Published var isSteamPrefillImporting = false
    @Published private(set) var isSteamLibraryBusy = false
    @Published var steamLibraryStatusText: String = ""
    // Switch：用户自备的 prod.keys 与固件目录（绝不随 App 分发）。
    @Published var preferredKeysPath: String = ""
    @Published var preferredFirmwarePath: String = ""

    private let fm = FileManager.default
    private let homeDirectory: URL
    private let updateGate: UpdateInstallationGate
    private let steamOperations = SteamOperationCoordinator()
    private var steamLibraryBindings: [SteamLibraryBinding] = []
    private var wantsSteamRefreshConfirmation = false
    private lazy var steamSnapshotLoader = BackgroundSnapshotLoader<SteamLibraryScanInput, SteamLibrarySnapshot>(
        operation: { SteamLibrarySnapshot.load($0) },
        publish: { [weak self] in self?.applySteamSnapshot($0) }
    )
    var isSteamFileMutationInProgress: Bool {
        steamOperations.active?.kind == .importing || steamOperations.active?.kind == .deleting
    }
    private var wineSteamDockActivationTask: Task<Void, Never>?
    private var lastWineSteamWindowReopenRequestAt: Date?
    @Published private(set) var startingIndependentGames: Set<IndependentGameIdentity> = []
    private var independentGameProcesses: [IndependentGameIdentity: Process] = [:]
    var independentGameProbe: @Sendable (IndependentGameIdentity) async throws -> Bool = { identity in
        try await Task.detached(priority: .utility) { try IndependentGameProcessProbe.isRunning(identity) }.value
    }
    /// Injected only by headless tests; normal launches always use GameLauncher.
    var independentGameLauncher: ((GameEntry) throws -> GameLaunchResult)?

    let appDataDir: URL
    let logsDir: URL
    let prefixesDir: URL
    let iconsDir: URL
    let storeURL: URL
    let storeBackupURL: URL

    private var isLoadingConfiguration = false
    var preferredWineBinaryPath: String = "" { didSet { if !isLoadingConfiguration { save() } } }
    var preferredWineAppPath: String = "" { didSet { if !isLoadingConfiguration { save() } } }

    init(appDataDirectory: URL? = nil, initializeRuntime: Bool = true, homeDirectory: URL? = nil,
         updateInstallationGate: UpdateInstallationGate? = nil) {
        let home = homeDirectory ?? Self.storageHome()
        self.homeDirectory = home
        self.updateGate = updateInstallationGate ?? .shared
        let legacyAppDataDir = home.appendingPathComponent(".vnlauncher", isDirectory: true)
        let testDataPath = Bundle.main.bundleIdentifier == "com.jojocys.shiori.update-test"
            ? Bundle.main.object(forInfoDictionaryKey: "ShioriTestingDataDirectory") as? String : nil
        appDataDir = appDataDirectory
            ?? testDataPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".shiori", isDirectory: true)
        logsDir = appDataDir.appendingPathComponent("logs", isDirectory: true)
        prefixesDir = appDataDir.appendingPathComponent("prefixes", isDirectory: true)
        iconsDir = appDataDir.appendingPathComponent("icons", isDirectory: true)
        storeURL = appDataDir.appendingPathComponent("games.json")
        storeBackupURL = appDataDir.appendingPathComponent("games.backup.json")
        if appDataDirectory == nil, testDataPath == nil { migrateLegacyDataIfNeeded(from: legacyAppDataDir) }
        ensureDirs()
        load()
        if initializeRuntime {
            refreshRuntimeStatus()
            refreshSteamLibraries()
            configureUpdateSafety()
        }
    }

    var selectedIndex: Int? {
        guard let id = selectedGameID else { return nil }
        return games.firstIndex(where: { $0.id == id })
    }

    var selectedGame: GameEntry? {
        guard let idx = selectedIndex else { return nil }
        return games[idx]
    }

    var selectedGameWineDriveStatus: String {
        guard let game = selectedGame, game.platform == .windows else { return "" }
        guard !game.gameFolderPath.isEmpty, !game.prefixDir.isEmpty else { return "尚未配置 Wine C 盘路径" }

        let folderURL = URL(fileURLWithPath: game.gameFolderPath, isDirectory: true)
        let driveCURL = URL(fileURLWithPath: game.prefixDir, isDirectory: true)
            .appendingPathComponent("drive_c", isDirectory: true)
        guard isURL(folderURL, inside: driveCURL) else {
            return "当前从 macOS 路径运行"
        }
        if pathHasSymbolicLinkComponent(folderURL, stoppingAt: driveCURL) {
            return "位于 Wine C 盘路径，但包含符号链接"
        }
        return "已在 Wine C 盘真实目录"
    }

    var canCopySelectedGameToWineDrive: Bool {
        guard let game = selectedGame, game.platform == .windows else { return false }
        return !game.gameFolderPath.isEmpty && !game.exePath.isEmpty
    }

    var wineSteamTips: [String] {
        [
            "“结束进程”会终止 Wine Steam 与其子进程，正在运行的 Steam 游戏会被强制退出。",
            "入口优先使用专用 Prefix：~/.shiori/steam-prefix（首次启动会兼容迁移旧 ~/.vnlauncher 数据）。",
            "如果提示未找到 Windows Steam，请先在该 Prefix 中完成一次安装。",
            "从 Mac Steam 导入只做本地预填充：复制可能复用的资源/数据文件，并写入 Wine 侧待验证 manifest；不复制 Mac 的 appmanifest、.app、.dylib、.framework、Info.plist 等 Mac 专用内容。",
            "预填充不等于已安装。Wine Steam 仍会下载 Windows EXE/DLL、运行库、平台专属 depot，以及路径或校验不匹配的文件。",
            "预填充后请点“安装/验证”；Shiori 会优先打开 Steam 校验入口，让 Steam 校验现有 staging 目录并补缺。",
            "如果 Mac 版和 Windows 版目录结构差异很大，Steam 可能只能复用少量文件，下载量会接近重新下载。",
            "Windows manifest 出现后，Shiori 会比对 Steam 实际安装目录；若提示目录不一致，Steam 可能没有使用预填充目录。",
            "从 Shiori 启动后，同一个 Prefix 中的 Steam 客户端与界面辅助进程共用一个程序坞入口；游戏进程使用对应 EXE 的图标。已在后台运行的旧进程需退出后重新启动，才会应用此规则。"
        ]
    }

    var wineSteamEntryContext: WineSteamEntryContext? {
        resolveWineSteamEntryContext()
    }

    var wineSteamLibraryPath: String {
        primaryWineSteamappsURL()
            .appendingPathComponent("common", isDirectory: true)
            .path
    }

    func load() {
        let primaryExists = fm.fileExists(atPath: storeURL.path)
        let backupExists = fm.fileExists(atPath: storeBackupURL.path)
        guard primaryExists || backupExists else { return }

        do {
            let file: GameStoreFile
            let recoveredFromBackup: Bool
            do {
                guard primaryExists else { throw CocoaError(.fileNoSuchFile) }
                file = try decodeStoreFile(at: storeURL)
                recoveredFromBackup = false
            } catch {
                guard backupExists else { throw error }
                file = try decodeStoreFile(at: storeBackupURL)
                recoveredFromBackup = true
            }

            isLoadingConfiguration = true
            defer { isLoadingConfiguration = false }
            games = file.games.sorted(by: { $0.updatedAt > $1.updatedAt })
            selectedGameID = file.selectedGameID.flatMap { savedID in
                games.contains(where: { $0.id == savedID }) ? savedID : nil
            } ?? games.first?.id
            preferredWineBinaryPath = file.preferredWineBinaryPath
            preferredWineAppPath = file.preferredWineAppPath
            preferredKeysPath = file.preferredKeysPath ?? ""
            preferredFirmwarePath = file.preferredFirmwarePath ?? ""
            launchedWineSteamAppIDs = Set(file.launchedWineSteamAppIDs ?? [])
            repairLegacyPlatformMetadata()
            refreshSelectedScanResult(repairLegacyPlatform: true)
            refreshSelectedFontCompatibilityStatus()
            if recoveredFromBackup {
                statusMessage = "主配置文件不可用，已从本地备份恢复。"
                try saveForUpdate()
            } else if !fm.fileExists(atPath: storeBackupURL.path)
                        || (try? decodeStoreFile(at: storeBackupURL)) == nil {
                // Older versions only had games.json. Seed a verified backup on the first
                // successful load, and repair an unusable backup from the verified primary.
                try Data(contentsOf: storeURL).write(to: storeBackupURL, options: .atomic)
            }
        } catch {
            statusMessage = "读取配置失败：\(error.localizedDescription)"
        }
    }

    func save() {
        do { try saveForUpdate() }
        catch { statusMessage = "保存配置失败：\(error.localizedDescription)" }
    }

    private func saveForUpdate() throws {
        ensureDirs()
        let file = GameStoreFile(
            selectedGameID: selectedGameID,
            games: games,
            preferredWineBinaryPath: preferredWineBinaryPath,
            preferredWineAppPath: preferredWineAppPath,
            preferredKeysPath: preferredKeysPath,
            preferredFirmwarePath: preferredFirmwarePath,
            launchedWineSteamAppIDs: Array(launchedWineSteamAppIDs)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(to: storeURL, options: .atomic)
        try data.write(to: storeBackupURL, options: .atomic)
    }

    private func decodeStoreFile(at url: URL) throws -> GameStoreFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GameStoreFile.self, from: Data(contentsOf: url))
    }

    func configureUpdateSafety() {
        updateGate.roots = { [weak self] in
            guard let self else { return [] }
            let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
            return [resources.appendingPathComponent("EmbeddedWine").path,
                    resources.appendingPathComponent("EmbeddedEmulator").path,
                    self.prefixesDir.path, self.logsDir.path,
                    self.appDataDir.appendingPathComponent("steam-prefix").path,
                    self.appDataDir.appendingPathComponent("switch-data").path] +
                self.games.map(\.prefixDir).filter { !$0.isEmpty } +
                self.games.map(\.emulatorAppPath).filter { !$0.isEmpty } +
                self.resolveWineSteamCleanupContexts().map(\.prefixPath)
        }
        updateGate.saveBeforeExit = { [weak self] in
            guard let self else { throw UpdateSafetyError.probeFailed("配置尚未就绪。") }
            guard !self.isManagingFontCompatibility, !self.isSteamLibraryBusy else {
                throw UpdateSafetyError.probeFailed("请等待运行环境配置或游戏导入完成。")
            }
            try self.saveForUpdate()
        }
    }

    private func permitRuntimeLaunch() -> Bool {
        guard !updateGate.blocksLaunch else {
            statusMessage = "更新已准备安装，请先完成更新并重启 Shiori，再启动游戏或运行环境。"
            return false
        }
        guard !isManagingFontCompatibility else {
            statusMessage = "请等待当前字体配置完成，再启动或更改运行环境。"
            return false
        }
        return true
    }

    private func permitIndependentRuntimeLaunch() -> Bool {
        guard !isSteamLibraryBusy else {
            statusMessage = "请等待当前 Steam 操作完成，再启动游戏或更改运行环境。"
            return false
        }
        return permitRuntimeLaunch()
    }

    func refreshRuntimeStatus(userInitiated: Bool = false) {
        let report = RuntimeManager.detect(
            preferredWineBinaryPath: preferredWineBinaryPath,
            preferredWineAppPath: preferredWineAppPath
        )
        runtimeReport = report
        if userInitiated {
            let summary: String
            if report.resolvedWineBinaryPath.isEmpty {
                summary = "未检测到 Wine"
            } else {
                summary = "已重新检测运行环境"
            }
            statusMessage = summary
            if !downloadStatusText.isEmpty {
                downloadStatusText = ""
            }
        }
    }

    func selectGame(_ id: UUID?) {
        selectedGameID = id
        refreshSelectedScanResult(repairLegacyPlatform: true)
        refreshSelectedFontCompatibilityStatus()
        save()
    }

    func addEmptyGame() {
        let name = nextUntitledName()
        let entry = GameEntry(name: name, prefixDir: defaultPrefixDir(for: name))
        games.insert(entry, at: 0)
        selectedGameID = entry.id
        scanResult = nil
        statusMessage = "已创建空白配置"
        save()
    }

    func removeSelectedGame() {
        guard let idx = selectedIndex else { return }
        let removed = games.remove(at: idx)
        removeStoredIconFiles(for: removed.id)
        selectedGameID = games.first?.id
        statusMessage = "已删除配置：\(removed.name)"
        refreshSelectedScanResult(repairLegacyPlatform: true)
        save()
    }

    func chooseAndScanGameFolder() {
        let start = selectedGame?.gameFolderPath
        guard let folder = PlatformPickers.chooseGameFolder(startingAt: start) else { return }
        applyScanResult(GameScanner.scanGameFolder(folder), persistAsCurrent: true)
    }

    func rescanCurrentFolder() {
        guard let path = selectedGame?.gameFolderPath, !path.isEmpty else {
            statusMessage = "请先选择游戏文件夹"
            return
        }
        applyScanResult(GameScanner.scanGameFolder(URL(fileURLWithPath: path)), persistAsCurrent: true)
    }

    func chooseEXEManually() {
        let start = selectedGame?.exePath
        guard let exe = PlatformPickers.chooseExecutable(startingAt: start) else { return }
        updateSelected { game in
            game.platform = .windows
            game.exePath = exe.path
            if game.gameFolderPath.isEmpty { game.gameFolderPath = exe.deletingLastPathComponent().path }
            if game.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || game.name == "新游戏" {
                game.name = exe.deletingPathExtension().lastPathComponent
            }
            if game.prefixDir.isEmpty { game.prefixDir = defaultPrefixDir(for: game.name) }
        }
        statusMessage = "已手动选择 EXE：\(exe.lastPathComponent)"
        if let folder = selectedGame?.gameFolderPath, !folder.isEmpty {
            scanResult = GameScanner.scanGameFolder(URL(fileURLWithPath: folder))
        }
    }

    func choosePrefixFolder() {
        let start = selectedGame?.prefixDir
        guard let folder = PlatformPickers.chooseFolder(startingAt: start, prompt: "选择 Prefix", message: "建议为每个游戏使用独立 Prefix 文件夹") else { return }
        updateSelected { $0.prefixDir = folder.path }
        statusMessage = "已设置 Prefix：\(folder.lastPathComponent)"
        refreshSelectedFontCompatibilityStatus()
    }

    func copySelectedGameToWineDrive() {
        guard let idx = selectedIndex else {
            statusMessage = "请先选择一个游戏配置"
            return
        }
        guard games[idx].platform == .windows else {
            statusMessage = "Switch 游戏不需要复制到 Wine C 盘"
            return
        }
        guard !games[idx].gameFolderPath.isEmpty, !games[idx].exePath.isEmpty else {
            statusMessage = "请先选择游戏文件夹和 EXE"
            return
        }

        let sourceFolderURL = URL(fileURLWithPath: games[idx].gameFolderPath, isDirectory: true)
        let sourceExeURL = URL(fileURLWithPath: games[idx].exePath)
        guard fm.fileExists(atPath: sourceFolderURL.path) else {
            statusMessage = "游戏目录不存在，无法复制到 Wine C 盘"
            return
        }
        guard fm.fileExists(atPath: sourceExeURL.path) else {
            statusMessage = "主程序 EXE 不存在，无法复制到 Wine C 盘"
            return
        }

        if games[idx].prefixDir.isEmpty {
            games[idx].prefixDir = defaultPrefixDir(for: games[idx].name)
        }

        let prefixURL = URL(fileURLWithPath: games[idx].prefixDir, isDirectory: true)
        let driveCURL = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        if isURL(sourceFolderURL, inside: driveCURL),
           !pathHasSymbolicLinkComponent(sourceFolderURL, stoppingAt: driveCURL) {
            statusMessage = "当前游戏目录已经在 Wine C 盘真实目录内"
            return
        }

        let resolvedSourceFolderURL = sourceFolderURL.resolvingSymlinksInPath()
        let exeRelativePath = relativePath(of: sourceExeURL, under: sourceFolderURL)
            ?? relativePath(of: sourceExeURL.resolvingSymlinksInPath(), under: resolvedSourceFolderURL)
        guard let exeRelativePath else {
            statusMessage = "主程序不在游戏目录内，无法安全复制"
            return
        }

        let gamesDir = driveCURL.appendingPathComponent("Games", isDirectory: true)
        let displayName = games[idx].name.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBaseName = displayName.isEmpty || displayName == "新游戏"
            ? sourceFolderURL.lastPathComponent
            : displayName
        let destinationURL = uniqueDirectory(in: gamesDir, baseName: slug(rawBaseName))
        let temporaryURL = gamesDir.appendingPathComponent(
            ".\(destinationURL.lastPathComponent)-copy-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            try fm.createDirectory(at: gamesDir, withIntermediateDirectories: true)
            try copyDirectoryPreferClone(from: resolvedSourceFolderURL, to: temporaryURL)
            try fm.moveItem(at: temporaryURL, to: destinationURL)

            let destinationExeURL = appendingRelativePath(exeRelativePath, to: destinationURL)
            guard fm.fileExists(atPath: destinationExeURL.path) else {
                throw NSError(
                    domain: "ShioriCopyToWineDrive",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "复制完成，但未能在目标目录找到原 EXE。"]
                )
            }

            games[idx].gameFolderPath = destinationURL.path
            games[idx].exePath = destinationExeURL.path
            games[idx].prefixDir = prefixURL.path
            games[idx].updatedAt = Date()
            save()
            scanResult = GameScanner.scanGameFolder(destinationURL)
            statusMessage = "已复制到 Wine C 盘：C:\\Games\\\(destinationURL.lastPathComponent)"
        } catch {
            try? fm.removeItem(at: temporaryURL)
            statusMessage = "复制到 Wine C 盘失败：\(error.localizedDescription)"
        }
    }

    // Switch：与 chooseEXEManually / choosePrefixFolder 同构的手动选择（ROM 之于 EXE，模拟器之于 Wine）。
    func chooseSwitchROM() {
        let start = selectedGame?.romPath
        guard let rom = PlatformPickers.chooseFile(startingAt: start, prompt: "选择 ROM", message: "请选择 Switch 游戏 ROM（.nsp / .xci）") else { return }
        updateSelected { game in
            game.platform = .switchEmu
            game.romPath = rom.path
            if game.gameFolderPath.isEmpty { game.gameFolderPath = rom.deletingLastPathComponent().path }
            if game.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || game.name == "新游戏" {
                game.name = rom.deletingPathExtension().lastPathComponent
            }
            if game.engineHint == "未识别" { game.engineHint = "Nintendo Switch" }
        }
        statusMessage = "已选择 ROM：\(rom.lastPathComponent)"
    }

    func chooseEmulatorApp() {
        let start = selectedGame?.emulatorAppPath
        guard let app = PlatformPickers.chooseApp(startingAt: start, prompt: "选择模拟器", message: "请选择 Switch 模拟器 App（Ryujinx / yuzu 系等均可）") else { return }
        updateSelected { game in
            game.emulatorAppPath = app.path
            game.platform = .switchEmu
        }
        statusMessage = "已设置模拟器：\(app.lastPathComponent)"
    }

    // —— 游戏图标：自定义覆盖；留空则由 GameIconResolver 自动提取（Windows EXE 内嵌图标 / 目录图片）——
    func chooseCustomIconForSelectedGame() {
        guard let idx = selectedIndex else {
            statusMessage = "请先选择一个游戏配置"
            return
        }
        let start = games[idx].iconPath.isEmpty ? games[idx].gameFolderPath : games[idx].iconPath
        guard let picked = PlatformPickers.chooseImage(startingAt: start.isEmpty ? nil : start) else { return }

        ensureDirs()
        do {
            let dest = try GameIconStorage.replace(from: picked, gameID: games[idx].id, in: iconsDir)
            updateSelected { $0.iconPath = dest.path }
            statusMessage = "已设置自定义图标：\(picked.lastPathComponent)"
        } catch {
            statusMessage = "设置图标失败：\(error.localizedDescription)"
        }
    }

    func clearCustomIconForSelectedGame() {
        guard let idx = selectedIndex else { return }
        removeStoredIconFiles(for: games[idx].id)
        updateSelected { $0.iconPath = "" }
        statusMessage = "已恢复默认图标"
    }

    var selectedGameHasCustomIcon: Bool {
        !(selectedGame?.iconPath.isEmpty ?? true)
    }

    /// 重新获取在线封面：清掉该游戏的在线缓存，抬高 updatedAt 触发 GameIconView 重新解析。
    func refetchIconForSelectedGame() {
        guard let game = selectedGame else { return }
        GameIconResolver.clearRemoteCache(for: game, cacheDirectory: iconsDir.appendingPathComponent("cache"))
        touchSelected()
        statusMessage = "正在重新获取封面…"
    }

    private func removeStoredIconFiles(for id: UUID) {
        guard let items = try? fm.contentsOfDirectory(at: iconsDir, includingPropertiesForKeys: nil) else { return }
        for url in items where url.deletingPathExtension().lastPathComponent == id.uuidString {
            try? fm.removeItem(at: url)
        }
    }

    // —— Switch keys / firmware：仅"导入用户自备文件"，绝不分发版权文件 ——
    func chooseSwitchKeys() {
        guard let f = PlatformPickers.chooseFile(startingAt: preferredKeysPath, prompt: "选择 prod.keys", message: "请选择你从自己持有的 Switch 主机导出的 prod.keys") else { return }
        preferredKeysPath = f.path
        save()
        statusMessage = "已导入 prod.keys（你自备）"
    }

    func chooseSwitchFirmware() {
        guard let f = PlatformPickers.chooseFolder(startingAt: preferredFirmwarePath, prompt: "选择固件文件夹", message: "请选择包含 Switch 固件（一组 .nca）的文件夹") else { return }
        preferredFirmwarePath = f.path
        save()
        statusMessage = "已设置固件目录（你自备）"
    }

    var switchKeysReady: Bool {
        (!preferredKeysPath.isEmpty && fm.fileExists(atPath: preferredKeysPath)) || existingSwitchDataDirectory != nil
    }

    var switchFirmwareReady: Bool {
        (!preferredFirmwarePath.isEmpty && fm.fileExists(atPath: preferredFirmwarePath)) || existingSwitchDataDirectory != nil
    }

    var existingSwitchDataDirectory: URL? {
        guard preferredKeysPath.isEmpty, preferredFirmwarePath.isEmpty,
              let bundled = SwitchRuntime.resolveBundledEmulator(),
              SwitchRuntime.executable(in: bundled) != nil else { return nil }
        return SwitchRuntime.existingUserDataDirectory()
    }

    func renameSelectedGame(_ name: String) {
        guard let id = selectedGameID else { return }
        renameGame(id, to: name)
    }

    func renameGame(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let committed = trimmed.isEmpty ? "未命名游戏" : trimmed
        guard let index = games.firstIndex(where: { $0.id == id }), games[index].name != committed else { return }
        GameIconResolver.preserveCachedCover(for: games[index], cacheDirectory: iconsDir.appendingPathComponent("cache"))
        games[index].name = committed
        games[index].updatedAt = Date()
        save()
    }

    func setSelectedLaunchLanguage(_ mode: LaunchLanguageMode) {
        updateSelected { game in
            game.launchLanguageMode = mode
        }
        refreshSelectedFontCompatibilityStatus()
    }

    var selectedGameHasFontCompatibilityRepair: Bool {
        guard let prefix = selectedGame?.prefixDir else { return false }
        return WineFontCompatibility.hasRepairRecord(prefixPath: prefix)
    }

    func repairSelectedGameFonts() {
        guard permitIndependentRuntimeLaunch() else { return }
        guard let game = selectedGame, game.platform == .windows else {
            statusMessage = "请先选择一个 Windows 游戏配置"
            return
        }
        guard !game.prefixDir.isEmpty else {
            statusMessage = "请先设置 Wine Prefix"
            return
        }
        guard let wineBinary = RuntimeManager.resolveWineBinary(preferred: preferredWineBinaryPath) else {
            statusMessage = "未找到 Wine。请先在运行环境中选择或安装 Wine。"
            return
        }

        let gameID = game.id
        let prefixPath = game.prefixDir
        let profile = WineFontCompatibility.profile(for: game)
        isManagingFontCompatibility = true
        fontCompatibilityStatusText = "正在使用当前 Wine 检测并修复 \(profile.title)字体映射…"
        statusMessage = "正在修复中日文字体兼容…"

        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try WineFontCompatibility.repair(
                        prefixPath: prefixPath,
                        wineBinary: wineBinary,
                        profile: profile
                    )
                }.value
                if selectedGameID == gameID {
                    fontCompatibilityStatusText = report.summary
                }
                statusMessage = report.summary
            } catch {
                let detail = error.localizedDescription
                if selectedGameID == gameID {
                    fontCompatibilityStatusText = "修复失败：\(detail)"
                }
                statusMessage = "字体修复失败：\(detail)"
            }
            isManagingFontCompatibility = false
        }
    }

    func restoreSelectedGameFonts() {
        guard permitIndependentRuntimeLaunch() else { return }
        guard let game = selectedGame, game.platform == .windows else {
            statusMessage = "请先选择一个 Windows 游戏配置"
            return
        }
        guard WineFontCompatibility.hasRepairRecord(prefixPath: game.prefixDir) else {
            statusMessage = "当前 Prefix 没有 Shiori 字体修复记录"
            return
        }
        guard let wineBinary = RuntimeManager.resolveWineBinary(preferred: preferredWineBinaryPath) else {
            statusMessage = "未找到 Wine。无法安全撤销字体修复。"
            return
        }

        let gameID = game.id
        let prefixPath = game.prefixDir
        isManagingFontCompatibility = true
        fontCompatibilityStatusText = "正在撤销 Shiori 写入的字体映射…"
        statusMessage = "正在撤销字体修复…"

        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try WineFontCompatibility.restore(prefixPath: prefixPath, wineBinary: wineBinary)
                }.value
                if selectedGameID == gameID {
                    fontCompatibilityStatusText = report.summary
                }
                statusMessage = report.summary
            } catch {
                let detail = error.localizedDescription
                if selectedGameID == gameID {
                    fontCompatibilityStatusText = "撤销失败：\(detail)"
                }
                statusMessage = "撤销字体修复失败：\(detail)"
            }
            isManagingFontCompatibility = false
        }
    }

    private func refreshSelectedFontCompatibilityStatus() {
        guard let game = selectedGame, game.platform == .windows else {
            fontCompatibilityStatusText = "Switch 游戏不使用 Wine 字体兼容层。"
            return
        }
        guard !game.prefixDir.isEmpty else {
            fontCompatibilityStatusText = "请先设置 Wine Prefix。"
            return
        }
        let profile = WineFontCompatibility.profile(for: game)
        fontCompatibilityStatusText = WineFontCompatibility.hasRepairRecord(prefixPath: game.prefixDir)
            ? "当前 Prefix 已有 Shiori 字体修复记录；可再次检测以补齐或切换到\(profile.title)字形。"
            : "尚未修复。将按\(profile.title)模式映射缺失的 Windows 中日文字体。"
    }

    func chooseWineBinary() {
        let start = preferredWineBinaryPath
        guard let file = PlatformPickers.chooseWineBinary(startingAt: start) else { return }
        preferredWineBinaryPath = file.path
        statusMessage = "已设置 Wine 路径（优先使用）"
        refreshRuntimeStatus()
    }

    func chooseWineApp() {
        let start = preferredWineAppPath
        guard let app = PlatformPickers.chooseApp(startingAt: start, prompt: "选择 Wine.app", message: "请选择 Wine Stable.app 或 Wine.app") else { return }
        preferredWineAppPath = app.path
        statusMessage = "已记录 Wine.app 路径"
        refreshRuntimeStatus()
    }

    func openSelectedGameFolder() {
        guard let path = selectedGame?.gameFolderPath, !path.isEmpty else {
            statusMessage = "当前配置还没有游戏文件夹"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func refreshSteamLibraries(userInitiated: Bool = false) {
        wantsSteamRefreshConfirmation = wantsSteamRefreshConfirmation || userInitiated
        guard !isSteamLibraryBusy else { return }
        steamSnapshotLoader.request(SteamLibraryScanInput(home: homeDirectory, appDataDirectory: appDataDir,
            contexts: resolveWineSteamCleanupContexts()), force: userInitiated)
    }

    func applySteamSnapshot(_ snapshot: SteamLibrarySnapshot) {
        guard !isSteamLibraryBusy else { return }
        macSteamGames = snapshot.macGames
        wineSteamGames = snapshot.wineGames
        wineSteamInstallStatuses = snapshot.installStatuses
        steamLibraryBindings = snapshot.bindings
        isWineSteamRunning = snapshot.isRunning
        let summary = "Mac Steam \(macSteamGames.count) 个 · Wine Steam \(wineSteamGames.count) 个"
        steamLibraryStatusText = summary
        if wantsSteamRefreshConfirmation {
            statusMessage = "已刷新 Steam 库：\(summary)"
            wantsSteamRefreshConfirmation = false
        }
    }

    func beginSteamOperation(_ kind: SteamOperationCoordinator.Kind) -> SteamOperationCoordinator.Lease? {
        if kind == .stopping {
            // A staged update blocks new launches, but the user must still be
            // able to close Steam before the update can be installed.
            guard !isManagingFontCompatibility else {
                statusMessage = "请等待字体配置完成，再关闭 Wine Steam。"
                return nil
            }
        } else {
            guard permitRuntimeLaunch() else { return nil }
        }
        guard let lease = steamOperations.begin(kind) else {
            statusMessage = "已有 Steam 操作正在进行，请等待完成。"
            return nil
        }
        isSteamLibraryBusy = true
        isSteamPrefillImporting = kind == .importing
        steamSnapshotLoader.cancel()
        return lease
    }

    func finishSteamOperation(_ lease: SteamOperationCoordinator.Lease) {
        guard steamOperations.active == lease else { return }
        steamOperations.finish(lease)
        isSteamLibraryBusy = false
        isSteamPrefillImporting = false
        refreshSteamLibraries(userInitiated: false)
    }

    private func contextForSteamGame(_ game: SteamLibraryGame) -> WineSteamEntryContext? {
        let wineGame = game.source == .mac ? matchingWineSteamGame(forMacSteamGame: game) : game
        if let wineGame {
            guard let context = SteamLibraryRouting.context(for: wineGame, bindings: steamLibraryBindings),
                  resolveWineSteamCleanupContexts().contains(context) else { return nil }
            return context
        }
        return game.source == .mac ? resolveWineSteamEntryContext() : nil
    }

    private func contextsManagingLibrary(_ library: URL) -> [WineSteamEntryContext] {
        let path = SteamLibraryPathSafety.canonical(library).path
        return resolveWineSteamCleanupContexts().filter { context in
            let primary = SteamLibraryManager.wineSteamappsURL(for: context)
            let libraries = [primary] + SteamLibraryManager.steamappsURLsFromLibraryFolders(
                steamappsURL: primary, winePrefixURL: URL(fileURLWithPath: context.prefixPath))
            return libraries.contains { SteamLibraryPathSafety.canonical($0).path == path }
        }
    }

    private func stopSteamContexts(_ contexts: [WineSteamEntryContext]) async -> WineSteamProcessService.StopResult {
        let preferred = preferredWineBinaryPath
        return await Task.detached(priority: .userInitiated) {
            let wine = RuntimeManager.resolveWineBinary(preferred: preferred) ?? ""
            return WineSteamProcessService.stop(contexts: contexts, wineBinary: wine)
        }.value
    }

    func wineSteamInstallStatus(for game: SteamLibraryGame) -> SteamInstallStatus? {
        let wineGame = game.source == .mac ? matchingWineSteamGame(forMacSteamGame: game) : game
        guard let wineGame, !wineGame.appID.isEmpty else { return nil }
        return wineSteamInstallStatuses[wineGame.installationIdentity]
    }

    func isWineSteamGameReadyToLaunch(_ game: SteamLibraryGame) -> Bool {
        guard game.hasManifest, !game.appID.isEmpty else { return false }
        guard let status = wineSteamInstallStatus(for: game) else { return true }
        return status.isLaunchReady
    }

    func canPrefillMacSteamGame(_ game: SteamLibraryGame) -> Bool {
        guard !isSteamLibraryBusy else { return false }
        guard !game.installPath.isEmpty, fm.fileExists(atPath: game.installPath) else { return false }
        return !wineSteamGames.contains { $0.appID == game.appID && $0.hasManifest }
    }

    func canResetWineSteamGameAndPrefill(_ game: SteamLibraryGame) -> Bool {
        guard !isSteamLibraryBusy else { return false }
        guard !game.installPath.isEmpty, fm.fileExists(atPath: game.installPath) else { return false }
        return matchingWineSteamGame(forMacSteamGame: game) != nil
    }

    func isMacSteamGamePrefilledInWine(_ game: SteamLibraryGame) -> Bool {
        wineSteamGames.contains { !$0.hasManifest && $0.installDir == game.installDir }
    }

    func matchingWineSteamGame(forMacSteamGame game: SteamLibraryGame) -> SteamLibraryGame? {
        let appMatches = game.appID.isEmpty ? [] : wineSteamGames.filter { $0.appID == game.appID }
        let matches = appMatches.isEmpty
            ? wineSteamGames.filter { $0.installDir.caseInsensitiveCompare(game.installDir) == .orderedSame }
            : appMatches
        return matches.first(where: { $0.hasManifest }) ?? matches.first
    }

    func prefillMacSteamGameToWine(_ game: SteamLibraryGame) {
        guard canPrefillMacSteamGame(game), let lease = beginSteamOperation(.importing) else { return }
        let target = primaryWineSteamappsURL()
        let allowedRoots = wineSteamappsURLsForManagement()
        let protectedRoots = SteamLibraryManager.macSteamappsURLs(home: homeDirectory)
        let contexts = contextsManagingLibrary(target)
        statusMessage = "正在从 Mac Steam 本地预填充：\(game.name)"
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishSteamOperation(lease) }
            let stopped = await self.stopSteamContexts(contexts)
            guard stopped.didStop else {
                self.statusMessage = "无法确认 Wine Steam 已完全退出，已取消导入。"
                return
            }
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try SteamLibraryManager.prefillWineSteam(from: game, to: target,
                        protectedRoots: protectedRoots, allowedRoots: allowedRoots)
                }.value
                self.steamLibraryStatusText = "已预填充 \(report.copiedFiles) 个文件，跳过 \(report.skippedFiles) 项"
                self.statusMessage = "已本地预填充 \(game.name)：\(report.copiedSizeLabel)。这不是完整安装；Wine Steam 仍会下载 Windows 文件和校验不匹配的内容。"
            } catch { self.statusMessage = "导入失败：\(error.localizedDescription)" }
        }
        steamOperations.track(task, for: lease)
    }

    func resetWineSteamGameAndPrefill(_ game: SteamLibraryGame) {
        guard let existing = matchingWineSteamGame(forMacSteamGame: game) else {
            prefillMacSteamGameToWine(game)
            return
        }
        guard !isInsideMacSteamLibrary(existing),
              !game.installPath.isEmpty, fm.fileExists(atPath: game.installPath) else {
            statusMessage = "源目录不可用，或目标涉及 Mac Steam 原生库，已拒绝重置。"
            return
        }
        guard let lease = beginSteamOperation(.importing) else { return }
        let target = URL(fileURLWithPath: existing.steamappsPath, isDirectory: true)
        let allowedRoots = wineSteamappsURLsForManagement()
        let protectedRoots = SteamLibraryManager.macSteamappsURLs(home: homeDirectory)
        let contexts = contextsManagingLibrary(target)
        statusMessage = "正在重置 Wine 侧文件并重新预填充：\(game.name)"
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishSteamOperation(lease) }
            let stopped = await self.stopSteamContexts(contexts)
            guard stopped.didStop else {
                self.statusMessage = "无法确认 Wine Steam 已完全退出，已取消重置。"
                return
            }
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try SteamLibraryManager.deleteWineGame(existing, protectedRoots: protectedRoots, allowedRoots: allowedRoots)
                    return try SteamLibraryManager.prefillWineSteam(from: game, to: target,
                        protectedRoots: protectedRoots, allowedRoots: allowedRoots)
                }.value
                self.statusMessage = "已重新预填充 \(game.name)：\(report.copiedSizeLabel)。下一步请点“安装/验证”。"
            } catch { self.statusMessage = "重置预填充失败：\(error.localizedDescription)" }
        }
        steamOperations.track(task, for: lease)
    }

    func deleteWineSteamGame(_ game: SteamLibraryGame) {
        guard !isInsideMacSteamLibrary(game) else {
            statusMessage = "拒绝删除：该路径位于 Mac Steam 原生库内。请在 Mac Steam 中管理它。"
            return
        }
        guard let lease = beginSteamOperation(.deleting) else { return }
        let allowedRoots = wineSteamappsURLsForManagement()
        let protectedRoots = SteamLibraryManager.macSteamappsURLs(home: homeDirectory)
        let contexts = contextsManagingLibrary(URL(fileURLWithPath: game.steamappsPath))
        statusMessage = "正在删除 Wine Steam 文件：\(game.name)"
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishSteamOperation(lease) }
            let stopped = await self.stopSteamContexts(contexts)
            guard stopped.didStop else {
                self.statusMessage = "无法确认 Wine Steam 已完全退出，已取消删除。"
                return
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SteamLibraryManager.deleteWineGame(game, protectedRoots: protectedRoots, allowedRoots: allowedRoots)
                }.value
                self.statusMessage = "已删除 Wine Steam 文件：\(game.name)"
            } catch { self.statusMessage = "删除失败：\(error.localizedDescription)" }
        }
        steamOperations.track(task, for: lease)
    }

    func openWineSteamGameFolder(_ game: SteamLibraryGame) {
        guard !game.installPath.isEmpty, fm.fileExists(atPath: game.installPath) else {
            statusMessage = "Wine Steam 游戏目录不存在"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: game.installPath, isDirectory: true))
    }

    @discardableResult
    func launchWineSteamInstall(for game: SteamLibraryGame, afterPrefillReport: SteamPrefillReport? = nil) -> Bool {
        guard !game.appID.isEmpty, let context = contextForSteamGame(game) else {
            statusMessage = "未找到该游戏所属库的 Wine Steam，请安装客户端或刷新游戏库后重试。"
            return false
        }
        guard let lease = beginSteamOperation(.launching) else { return false }
        let url = SteamLibraryRouting.installURL(for: game,
            matchingWineGame: game.source == .mac ? matchingWineSteamGame(forMacSteamGame: game) : game,
            status: wineSteamInstallStatus(for: game))
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishSteamOperation(lease) }
            _ = await self.launchWineSteam(extraArguments: [url],
                successMessage: "已向该库所属 Wine Steam 发送安装/验证请求：\(game.name)",
                missingSteamMessage: "未找到该游戏所属的 Wine Steam。",
                allowInstallerFallback: false, contextOverride: context)
            if !Task.isCancelled, let report = afterPrefillReport {
                self.steamLibraryStatusText = "已预填充 \(report.copiedFiles) 个文件，等待 Steam 验证"
            }
        }
        steamOperations.track(task, for: lease)
        return true
    }

    func launchWineSteamEntry() {
        guard let lease = beginSteamOperation(.launching) else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishSteamOperation(lease) }
            _ = await self.launchWineSteam(extraArguments: [], successMessage: nil,
                missingSteamMessage: "未找到 Windows Steam（Steam.exe）。请先安装 Wine 版 Steam。",
                allowInstallerFallback: true)
        }
        steamOperations.track(task, for: lease)
    }

    /// 将 macOS 程序坞对 Wine 前台进程的激活，转成 Steam 自身的主窗口重开请求。
    /// 先给 Wine 自带的 reopen 逻辑一点时间；它若已恢复最小化窗口，这里不再重复处理。
    func handleWorkspaceApplicationActivation(_ application: NSRunningApplication) {
        wineSteamDockActivationTask?.cancel()
        wineSteamDockActivationTask = nil

        let looksLikeWine = application.localizedName?.caseInsensitiveCompare("wine") == .orderedSame
            || application.executableURL?.lastPathComponent.caseInsensitiveCompare("wine") == .orderedSame
        guard looksLikeWine else { return }

        let activatedPID = Int32(application.processIdentifier)
        guard activatedPID > 0 else { return }

        wineSteamDockActivationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: WineSteamDockReopenPolicy.activationDelayNanoseconds)
            } catch {
                return
            }
            await self?.requestWineSteamWindowFromDockIfNeeded(activatedPID: activatedPID)
        }
    }

    /// 先启动并确认 Wine Steam 客户端，再发送 rungameid，最后确认游戏进程是否出现。
    /// 预填充（无清单/AppID）仍转到安装/验证入口。
    func launchWineSteamGame(_ game: SteamLibraryGame) {
        guard isWineSteamGameReadyToLaunch(game) else {
            _ = launchWineSteamInstall(for: game)
            return
        }
        guard let context = contextForSteamGame(game) else {
            statusMessage = "未找到该游戏所属库的 Wine Steam，请刷新游戏库后重试。"
            return
        }
        guard let lease = beginSteamOperation(.launching) else { return }
        let identity = game.installationIdentity
        launchingWineSteamAppIDs.insert(identity)
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.launchingWineSteamAppIDs.remove(identity)
                self.finishSteamOperation(lease)
            }
            await self.launchWineSteamGameAfterClientReady(game, in: context)
        }
        steamOperations.track(task, for: lease)
    }

    func isLaunchingWineSteamGame(_ game: SteamLibraryGame) -> Bool {
        launchingWineSteamAppIDs.contains(game.installationIdentity)
    }

    /// 该 Wine Steam 游戏是否曾由 Shiori 确认成功启动。
    func wineSteamGameHasRun(_ appID: String) -> Bool {
        !appID.isEmpty && launchedWineSteamAppIDs.contains(appID)
    }

    private func launchWineSteamGameAfterClientReady(_ game: SteamLibraryGame, in context: WineSteamEntryContext) async {
        guard !Task.isCancelled else { return }
        statusMessage = "正在启动游戏所属的 Wine Steam：\(game.name)"
        guard await launchWineSteam(extraArguments: [], successMessage: "正在等待 Wine Steam 客户端就绪…",
            missingSteamMessage: "未找到该游戏所属的 Wine Steam。", allowInstallerFallback: false,
            contextOverride: context), !Task.isCancelled else { return }
        let ready = await waitForWineSteamClient(in: context, timeout: 20)
        guard !Task.isCancelled else { return }
        guard ready else {
            isWineSteamRunning = false
            statusMessage = "未能确认 Wine Steam 客户端已启动，已取消启动 \(game.name)。"
            return
        }
        isWineSteamRunning = true
        let existing = await Task.detached(priority: .utility) {
            WineSteamProcessService.gamePIDs(game, in: context)
        }.value
        guard !Task.isCancelled else { return }
        if !existing.isEmpty {
            confirmWineSteamGameLaunch(game, message: "\(game.name) 已在运行。")
            return
        }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard await launchWineSteam(extraArguments: ["steam://rungameid/\(game.appID)"],
            successMessage: "已发送启动请求，正在确认游戏进程…", missingSteamMessage: "未找到游戏所属的 Wine Steam。",
            allowInstallerFallback: false, contextOverride: context), !Task.isCancelled else { return }
        let launched = await waitForWineSteamGame(game, in: context, excluding: existing, timeout: 30)
        guard !Task.isCancelled else { return }
        if launched {
            confirmWineSteamGameLaunch(game, message: "已确认启动：\(game.name)")
        } else {
            statusMessage = "已发送启动请求，但 30 秒内未检测到 \(game.name) 的进程；请在 Steam 客户端中查看提示。"
        }
    }

    private func waitForWineSteamClient(in context: WineSteamEntryContext, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled, Date() < deadline {
            let pids = await Task.detached(priority: .utility) {
                WineSteamProcessService.mainClientPIDs(in: context.prefixPath)
            }.value
            guard !Task.isCancelled else { return false }
            if !pids.isEmpty { return true }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return false }
        }
        return false
    }

    private func waitForWineSteamGame(_ game: SteamLibraryGame, in context: WineSteamEntryContext,
                                    excluding existingPIDs: Set<Int32>, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled, Date() < deadline {
            let pids = await Task.detached(priority: .utility) {
                WineSteamProcessService.gamePIDs(game, in: context)
            }.value
            guard !Task.isCancelled else { return false }
            if !pids.subtracting(existingPIDs).isEmpty { return true }
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return false }
        }
        return false
    }

    private func confirmWineSteamGameLaunch(_ game: SteamLibraryGame, message: String) {
        statusMessage = message
        guard launchedWineSteamAppIDs.insert(game.appID).inserted else { return }
        save()
    }

    @discardableResult
    private func launchWineSteam(
        extraArguments: [String],
        successMessage: String?,
        missingSteamMessage: String,
        allowInstallerFallback: Bool,
        contextOverride: WineSteamEntryContext? = nil
    ) async -> Bool {
        guard !Task.isCancelled, permitRuntimeLaunch() else { return false }
        let preferred = preferredWineBinaryPath
        let wineBinary = await Task.detached(priority: .userInitiated) {
            RuntimeManager.resolveWineBinary(preferred: preferred) ?? ""
        }.value
        guard !Task.isCancelled, permitRuntimeLaunch() else { return false }

        guard !wineBinary.isEmpty else {
            statusMessage = "未检测到 Wine。请先在 P2 选择/安装 Wine。"
            return false
        }

        guard let context = contextOverride ?? resolveWineSteamEntryContext() else {
            if allowInstallerFallback, launchSteamInstallerIfAvailable(wineBinary: wineBinary) {
                return true
            }
            statusMessage = missingSteamMessage
            return false
        }

        do {
            try fm.createDirectory(atPath: context.prefixPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            statusMessage = "无法创建/访问 Steam Prefix：\(error.localizedDescription)"
            return false
        }

        var cleanupCount = 0
        var arguments = extraArguments
        var reopenedExistingClient = false
        if extraArguments.isEmpty {
            let existingSteamPIDs = await Task.detached(priority: .utility) {
                WineSteamProcessService.mainClientPIDs(in: context.prefixPath)
            }.value
            guard !Task.isCancelled else { return false }
            if existingSteamPIDs.isEmpty {
                cleanupCount = await Task.detached(priority: .userInitiated) {
                    WineSteamProcessService.clearStaleShell(in: context.prefixPath)
                }.value
                guard !Task.isCancelled else { return false }
            } else {
                // 客户端还活着，多半只是主窗口被关掉了（Steam 关窗＝隐藏到托盘）。
                // 这时再起一个客户端没有意义，而什么都不做又会让用户只能杀进程重开，
                // 所以把 steam://open/main 转交给现有实例，由它重新显示主窗口。
                arguments = WineSteamDockReopenPolicy.clientEntryArguments(
                    steamMainClientPIDs: existingSteamPIDs
                )
                reopenedExistingClient = true
                lastWineSteamWindowReopenRequestAt = Date()
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wineBinary)
        process.arguments = [context.steamExePath, "-no-cef-sandbox", "-foreground"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: context.steamExePath).deletingLastPathComponent()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = context.prefixPath
        env["WINEDEBUG"] = "-all"
        if let adapter = WineDockIcons.adapter {
            let games = wineSteamGames.filter {
                SteamLibraryRouting.context(for: $0, bindings: steamLibraryBindings)?.prefixPath == context.prefixPath
            }
            let original = env
            let cache = iconsDir.appendingPathComponent("wine-dock", isDirectory: true)
            env = await Task.detached(priority: .utility) {
                let executables = WineDockIcons.executables(in: games.map { URL(fileURLWithPath: $0.installPath) })
                let manifest = try? WineDockIcons.prepare(prefix: URL(fileURLWithPath: context.prefixPath),
                    gameExecutables: executables, cache: cache,
                    steamDirectory: URL(fileURLWithPath: context.steamExePath).deletingLastPathComponent())
                return WineDockIcons.environment(original, library: adapter, manifest: manifest)
            }.value
        }
        guard !Task.isCancelled, permitRuntimeLaunch() else { return false }
        process.environment = env

        do {
            try process.run()
            if let successMessage {
                statusMessage = successMessage
            } else if reopenedExistingClient {
                statusMessage = "Wine Steam 已在运行，已请求重新显示主窗口。"
            } else if cleanupCount > 0 {
                statusMessage = "已清理 \(cleanupCount) 个 Wine Steam 残留进程并启动客户端（\(context.sourceLabel)）。"
            } else {
                statusMessage = "已启动 Wine Steam（\(context.sourceLabel)）。"
            }
            isWineSteamRunning = true
            return true
        } catch {
            statusMessage = "启动 Wine Steam 失败：\(error.localizedDescription)"
            return false
        }
    }

    func stopWineSteamProcesses() {
        if steamOperations.cancelLaunch() {
            launchingWineSteamAppIDs.removeAll()
            isSteamLibraryBusy = false
        }
        wineSteamDockActivationTask?.cancel()
        guard let lease = beginSteamOperation(.stopping) else { return }
        let contexts = resolveWineSteamCleanupContexts()
        statusMessage = "正在关闭 Wine Steam…"
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishSteamOperation(lease) }
            let result = await self.stopSteamContexts(contexts)
            if result.didStop {
                self.isWineSteamRunning = false
                self.statusMessage = result.totalHits == 0 ? "未发现正在运行的 Wine Steam 进程。" : "已关闭 Wine Steam 相关进程（命中 \(result.totalHits) 项）。"
            } else {
                self.statusMessage = "无法确认 Wine Steam 已完全退出；尚未对游戏文件执行其他操作。"
            }
        }
        steamOperations.track(task, for: lease)
    }

    func refreshWineSteamRunningState() {
        refreshSteamLibraries()
    }

    func applyRecommendedCandidate(_ candidate: ScanCandidate) {
        updateSelected { game in
            let platform = scanResult?.platform ?? game.platform
            game.platform = platform
            if let currentScan = scanResult {
                game.engineHint = currentScan.engineHint
            }

            switch platform {
            case .windows:
                game.exePath = candidate.exeURL.path
                game.gameFolderPath = candidate.exeURL.deletingLastPathComponent().path
                if game.name == "新游戏" || game.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    game.name = candidate.exeURL.deletingPathExtension().lastPathComponent
                }
                if game.prefixDir.isEmpty {
                    game.prefixDir = defaultPrefixDir(for: game.name)
                }
            case .switchEmu:
                game.romPath = candidate.exeURL.path
                if game.gameFolderPath.isEmpty {
                    game.gameFolderPath = candidate.exeURL.deletingLastPathComponent().path
                }
            }
        }
        let label = selectedGame?.platform == .switchEmu ? "ROM" : "主程序"
        statusMessage = "已选择\(label)：\(candidate.exeURL.lastPathComponent)"
    }

    func saveCurrentFromP1() {
        guard selectedGame != nil else { return }
        updateSelected { game in
            if let scanResult {
                game.platform = scanResult.platform
                game.engineHint = scanResult.engineHint
                switch scanResult.platform {
                case .windows:
                    if game.prefixDir.isEmpty { game.prefixDir = defaultPrefixDir(for: game.name) }
                    if let recommended = scanResult.recommendedEXE, game.exePath.isEmpty {
                        game.exePath = recommended.path
                    }
                case .switchEmu:
                    if let rom = scanResult.romURL, game.romPath.isEmpty { game.romPath = rom.path }
                    if let emu = scanResult.emulatorAppURL, game.emulatorAppPath.isEmpty { game.emulatorAppPath = emu.path }
                    if let script = scanResult.launchScriptURL, game.launchScriptPath.isEmpty { game.launchScriptPath = script.path }
                }
            } else if game.prefixDir.isEmpty {
                game.prefixDir = defaultPrefixDir(for: game.name)
            }
        }
        statusMessage = "已保存到游戏列表（进入 P2）"
    }

    func startGame() {
        guard let game = selectedGame else {
            statusMessage = "请先选择一个游戏配置"
            return
        }
        startGame(game)
    }

    /// 从主页卡片直接启动指定配置，不依赖当前详情页选择。
    func startGame(_ game: GameEntry) {
        guard permitIndependentRuntimeLaunch() else { return }
        guard game.platform == .windows else {
            performGameLaunch(game)
            return
        }
        guard let identity = IndependentGameIdentity(game) else {
            statusMessage = "启动失败：请先配置主程序和 Wine Prefix。"
            return
        }
        guard !startingIndependentGames.contains(identity) else {
            statusMessage = "正在启动：\(game.name)，请稍候。"
            return
        }
        guard independentGameProcesses[identity]?.isRunning != true else {
            statusMessage = "\(game.name) 已在运行。"
            return
        }
        // Reserve before the first await, across detail, menu and home actions.
        startingIndependentGames.insert(identity)
        let probe = independentGameProbe
        Task { [weak self] in
            do {
                let running = try await probe(identity)
                guard let self else { return }
                defer { self.startingIndependentGames.remove(identity) }
                guard !Task.isCancelled else { return }
                if running {
                    self.statusMessage = "\(game.name) 已在运行。"
                    return
                }
                guard self.permitIndependentRuntimeLaunch() else { return }
                guard let current = self.games.first(where: { $0.id == game.id }),
                      IndependentGameIdentity(current) == identity else {
                    self.statusMessage = "配置已更改，已取消旧的启动请求。"
                    return
                }
                self.independentGameProcesses.removeValue(forKey: identity)
                self.performGameLaunch(current, identity: identity)
            } catch {
                guard let self else { return }
                self.startingIndependentGames.remove(identity)
                self.statusMessage = "启动已暂缓：\(error.localizedDescription)"
            }
        }
    }

    func isStartingGame(_ game: GameEntry) -> Bool {
        IndependentGameIdentity(game).map { startingIndependentGames.contains($0) } ?? false
    }

    private func performGameLaunch(_ game: GameEntry, identity: IndependentGameIdentity? = nil) {
        do {
            let result: GameLaunchResult
            if let identity, let independentGameLauncher {
                result = try independentGameLauncher(game)
                independentGameProcesses[identity] = result.process
            } else {
                result = try GameLauncher.launch(
                    game: game,
                    logsDir: logsDir,
                    preferredWineBinaryPath: preferredWineBinaryPath,
                    switchKeysPath: preferredKeysPath,
                    switchFirmwarePath: preferredFirmwarePath,
                    switchDataDir: appDataDir.appendingPathComponent("switch-data", isDirectory: true)
                )
                if let identity { independentGameProcesses[identity] = result.process }
            }
            lastLogPath = result.logURL.path
            statusMessage = "已尝试启动：\(game.name)"
            if let index = games.firstIndex(where: { $0.id == game.id }) {
                games[index].updatedAt = Date()
                save()
            }
        } catch {
            statusMessage = "启动失败：\(error.localizedDescription)"
        }
    }

    func openLastLog() {
        guard !lastLogPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: lastLogPath))
    }

    func openRepairGuide() {
        RuntimeManager.openPrivacySecuritySettings()
    }

    func installEmbeddedXQuartz() {
        guard let path = RuntimeManager.resolveEmbeddedXQuartzInstaller() else {
            statusMessage = "未找到内置 XQuartz 安装包。请重新打包，或确认桌面存在 XQuartz.pkg。"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        statusMessage = "已打开 XQuartz 安装包"
    }

    func openRosettaGuide() { RuntimeManager.openRosettaGuide() }
    func openPrivacySettings() { RuntimeManager.openPrivacySecuritySettings() }
    func openWineDownloadPage() { RuntimeManager.openWineDownloadPage() }
    func openXQuartzDownloadPage() { RuntimeManager.openXQuartzDownloadPage() }

    func copyTerminalInstallCommands() {
        let commands = [
            "# Shiori：Wine 已内置，无需单独安装 Wine",
            "",
            "# 1) Rosetta 2（Apple Silicon 必需/建议）",
            "/usr/sbin/softwareupdate --install-rosetta --agree-to-license",
            "",
            "# 2) XQuartz（部分 Wine 场景需要，二选一）",
            "# 方式 A：使用 App 内置的一键安装按钮（推荐）",
            "# 方式 B：终端安装",
            "brew install --cask xquartz",
            "",
            "# 如未安装 Homebrew，先执行：",
            "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        ].joined(separator: "\n")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(commands, forType: .string)
        statusMessage = "已复制终端安装命令（Rosetta / XQuartz；Wine 已内置）"
    }

    func downloadAndOpenWineInstaller() {
        downloadAndOpenInstaller(.wine)
    }

    func downloadAndOpenXQuartzInstaller() {
        downloadAndOpenInstaller(.xquartz)
    }

    func downloadAndOpenWineSteamInstaller() {
        guard !isDownloadingInstaller else { return }
        isDownloadingInstaller = true
        downloadStatusText = "正在下载 Wine Steam 安装器..."

        Task {
            defer {
                Task { @MainActor in self.isDownloadingInstaller = false }
            }

            do {
                let installerURL = try await downloadWineSteamInstaller()
                await MainActor.run {
                    NSWorkspace.shared.open(installerURL)
                    self.downloadStatusText = "Wine Steam 安装器已下载并打开：\(installerURL.lastPathComponent)"
                    self.statusMessage = "已打开 Wine Steam 安装器"
                }
            } catch {
                await MainActor.run {
                    self.downloadStatusText = "Wine Steam 下载失败：\(error.localizedDescription)"
                    self.statusMessage = self.downloadStatusText
                }
            }
        }
    }

    func downloadAndOpenInstaller(_ kind: RuntimeInstaller.InstallerKind) {
        guard !isDownloadingInstaller else { return }
        isDownloadingInstaller = true
        downloadStatusText = "正在准备下载 \(kind.displayName) 安装包..."
        Task {
            defer {
                Task { @MainActor in self.isDownloadingInstaller = false }
            }
            do {
                let result = try await RuntimeInstaller.downloadLatestInstaller(kind: kind)
                await MainActor.run {
                    self.downloadStatusText = "下载完成并已打开安装包：\(result.downloadedFileURL.lastPathComponent)"
                    self.statusMessage = "已打开 \(kind.displayName) 安装包"
                }
            } catch {
                await MainActor.run {
                    self.downloadStatusText = "\(kind.displayName) 下载失败：\(error.localizedDescription)"
                    self.statusMessage = self.downloadStatusText
                }
            }
        }
    }

    private func applyScanResult(_ result: ScanResult, persistAsCurrent: Bool) {
        scanResult = result
        updateSelected { game in
            game.gameFolderPath = result.folderURL.path
            game.platform = result.platform
            game.engineHint = result.engineHint
            if game.name == "新游戏" || game.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                game.name = result.folderURL.lastPathComponent
            }
            switch result.platform {
            case .windows:
                if let recommended = result.recommendedEXE {
                    game.exePath = recommended.path
                }
                if game.prefixDir.isEmpty {
                    game.prefixDir = defaultPrefixDir(for: game.name)
                }
            case .switchEmu:
                if game.romPath.isEmpty, let rom = result.romURL { game.romPath = rom.path }
                if game.emulatorAppPath.isEmpty, let emu = result.emulatorAppURL { game.emulatorAppPath = emu.path }
                if game.launchScriptPath.isEmpty, let script = result.launchScriptURL { game.launchScriptPath = script.path }
            }
        }

        if result.platform == .switchEmu {
            let emu = result.emulatorName ?? "模拟器"
            if result.launchScriptURL != nil {
                statusMessage = "已识别为 Switch 游戏（将用现成一键脚本启动 · \(emu)）"
            } else if result.romURL != nil {
                statusMessage = "已识别为 Switch 游戏（ROM 就绪 · 模拟器：\(emu)）"
            } else {
                statusMessage = "已识别为 Switch 游戏，但未找到 ROM/模拟器（可手动选择）"
            }
        } else if let blocker = result.antiCheats.first(where: { $0.severity == .blocking }) {
            statusMessage = "⚠️ 检测到 \(blocker.name)：内核级反作弊，macOS 无法运行此游戏。"
        } else if let limited = result.antiCheats.first {
            statusMessage = "⚠️ 检测到 \(limited.name)：macOS 上几乎无法运行。"
        } else if let recommended = result.recommendedEXE {
            statusMessage = "已扫描：推荐主程序 \(recommended.lastPathComponent)"
        } else {
            statusMessage = "已扫描文件夹，但未找到可用 EXE（可手动选择）"
        }

        if !persistAsCurrent { return }
    }

    private func refreshSelectedScanResult(repairLegacyPlatform: Bool) {
        guard let game = selectedGame, !game.gameFolderPath.isEmpty else {
            scanResult = nil
            return
        }

        let result = GameScanner.scanGameFolder(URL(fileURLWithPath: game.gameFolderPath))
        scanResult = result

        if repairLegacyPlatform {
            repairSelectedGamePlatformIfNeeded(using: result)
        }
    }

    private func repairSelectedGamePlatformIfNeeded(using result: ScanResult) {
        guard let idx = selectedIndex else { return }
        let game = games[idx]
        let shouldRepairAsSwitch = result.platform == .switchEmu
            || game.engineHint == "Nintendo Switch"
            || !game.romPath.isEmpty
        guard shouldRepairAsSwitch else { return }

        let targetEngineHint = result.platform == .switchEmu ? result.engineHint : "Nintendo Switch"
        let needsRepair = game.platform != .switchEmu
            || game.engineHint != targetEngineHint
            || (game.romPath.isEmpty && result.romURL != nil)
            || (game.emulatorAppPath.isEmpty && result.emulatorAppURL != nil)
            || (game.launchScriptPath.isEmpty && result.launchScriptURL != nil)
        guard needsRepair else { return }

        updateSelected { game in
            game.platform = .switchEmu
            game.engineHint = targetEngineHint
            if result.platform == .switchEmu {
                if let rom = result.romURL { game.romPath = rom.path }
                if let emu = result.emulatorAppURL { game.emulatorAppPath = emu.path }
                if let script = result.launchScriptURL { game.launchScriptPath = script.path }
            }
        }
    }

    private func repairLegacyPlatformMetadata() {
        var changed = false

        for idx in games.indices {
            let game = games[idx]
            let hasSwitchMetadata = game.platform == .switchEmu
                || game.engineHint == "Nintendo Switch"
                || !game.romPath.isEmpty
            guard hasSwitchMetadata else { continue }
            var repairedEntry = false

            var scan: ScanResult?
            if !game.gameFolderPath.isEmpty {
                let result = GameScanner.scanGameFolder(URL(fileURLWithPath: game.gameFolderPath))
                if result.platform == .switchEmu {
                    scan = result
                }
            }

            if games[idx].platform != .switchEmu {
                games[idx].platform = .switchEmu
                repairedEntry = true
            }
            if games[idx].engineHint != "Nintendo Switch" {
                games[idx].engineHint = "Nintendo Switch"
                repairedEntry = true
            }
            if games[idx].romPath.isEmpty, let rom = scan?.romURL {
                games[idx].romPath = rom.path
                repairedEntry = true
            }
            if let emu = scan?.emulatorAppURL, games[idx].emulatorAppPath.isEmpty {
                games[idx].emulatorAppPath = emu.path
                repairedEntry = true
            }
            if let script = scan?.launchScriptURL, games[idx].launchScriptPath.isEmpty {
                games[idx].launchScriptPath = script.path
                repairedEntry = true
            }
            if repairedEntry {
                games[idx].updatedAt = Date()
                changed = true
            }
        }

        if changed {
            save()
        }
    }

    private func updateSelected(_ mutate: (inout GameEntry) -> Void) {
        guard let idx = selectedIndex else { return }
        mutate(&games[idx])
        games[idx].updatedAt = Date()
        save()
    }

    private func touchSelected() {
        updateSelected { _ in }
    }

    private func ensureDirs() {
        try? fm.createDirectory(at: appDataDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: prefixesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: iconsDir, withIntermediateDirectories: true)
    }

    private func migrateLegacyDataIfNeeded(from legacyDir: URL) {
        let hasCurrentRoot = fm.fileExists(atPath: appDataDir.path)
        if !hasCurrentRoot, fm.fileExists(atPath: legacyDir.path) {
            try? fm.copyItem(at: legacyDir, to: appDataDir)
        }

        try? fm.createDirectory(at: appDataDir, withIntermediateDirectories: true)

        copyLegacyFile(named: "gal-for-macos-games.json", to: storeURL, legacyDir: legacyDir)
        copyLegacyDirectory(named: "zero-prefixes", to: prefixesDir, legacyDir: legacyDir)
        copyLegacyDirectory(
            named: "steam-prefix",
            to: appDataDir.appendingPathComponent("steam-prefix", isDirectory: true),
            legacyDir: legacyDir
        )
        copyLegacyDirectory(
            named: "downloads",
            to: appDataDir.appendingPathComponent("downloads", isDirectory: true),
            legacyDir: legacyDir
        )
    }

    private func copyLegacyFile(named legacyName: String, to destination: URL, legacyDir: URL) {
        guard !fm.fileExists(atPath: destination.path) else { return }
        let candidates = [
            appDataDir.appendingPathComponent(legacyName),
            legacyDir.appendingPathComponent(legacyName)
        ]
        guard let source = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { return }
        try? fm.copyItem(at: source, to: destination)
    }

    private func copyLegacyDirectory(named legacyName: String, to destination: URL, legacyDir: URL) {
        guard !fm.fileExists(atPath: destination.path) else { return }
        let candidates = [
            appDataDir.appendingPathComponent(legacyName, isDirectory: true),
            legacyDir.appendingPathComponent(legacyName, isDirectory: true)
        ]
        guard let source = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { return }
        if source.path.hasPrefix(appDataDir.path + "/") {
            try? fm.moveItem(at: source, to: destination)
        } else {
            try? fm.copyItem(at: source, to: destination)
        }
    }

    private func resolveWineSteamEntryContext() -> WineSteamEntryContext? {
        resolveWineSteamCleanupContexts().first(where: { fm.fileExists(atPath: $0.steamExePath) })
    }

    private func primaryWineSteamappsURL() -> URL {
        if let context = resolveWineSteamEntryContext() {
            return SteamLibraryManager.wineSteamappsURL(for: context)
        }
        return SteamLibraryManager.defaultWineSteamappsURL(appDataDir: appDataDir)
    }

    private func wineSteamappsURLsForManagement() -> [URL] {
        var urls = [primaryWineSteamappsURL(), SteamLibraryManager.defaultWineSteamappsURL(appDataDir: appDataDir)]
        let contexts = resolveWineSteamCleanupContexts()
        for context in contexts {
            let steamappsURL = SteamLibraryManager.wineSteamappsURL(for: context)
            urls.append(steamappsURL)
            urls.append(contentsOf: SteamLibraryManager.steamappsURLsFromLibraryFolders(
                steamappsURL: steamappsURL,
                winePrefixURL: URL(fileURLWithPath: context.prefixPath, isDirectory: true)
            ))
        }

        let defaultSteamapps = SteamLibraryManager.defaultWineSteamappsURL(appDataDir: appDataDir)
        urls.append(contentsOf: SteamLibraryManager.steamappsURLsFromLibraryFolders(
            steamappsURL: defaultSteamapps,
            winePrefixURL: appDataDir.appendingPathComponent("steam-prefix", isDirectory: true)
        ))

        return SteamLibraryManager.excludingSteamappsURLs(
            urls,
            under: SteamLibraryManager.macSteamappsURLs(home: homeDirectory)
        )
    }

    private func isInsideMacSteamLibrary(_ game: SteamLibraryGame) -> Bool {
        let macSteamappsURLs = SteamLibraryManager.macSteamappsURLs(home: homeDirectory)
        let pathsToCheck = [game.steamappsPath, game.installPath, game.manifestPath]
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }

        return macSteamappsURLs.contains { steamappsURL in
            let root = steamappsURL.resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            return pathsToCheck.contains { path in
                path == root || path.hasPrefix(prefix)
            }
        }
    }

    func resolveWineSteamCleanupContexts() -> [WineSteamEntryContext] {
        let home = homeDirectory
        var candidates: [(steamExe: URL, prefix: URL, source: String)] = [
            (
                steamExecutableURL(in: steamInstallDir(in: appDataDir.appendingPathComponent("steam-prefix", isDirectory: true))),
                appDataDir.appendingPathComponent("steam-prefix", isDirectory: true),
                "专用 Steam Prefix（.shiori）"
            ),
            (
                steamExecutableURL(in: steamInstallDir(in: home
                    .appendingPathComponent(".vnlauncher", isDirectory: true)
                    .appendingPathComponent("steam-prefix", isDirectory: true))),
                home
                    .appendingPathComponent(".vnlauncher", isDirectory: true)
                    .appendingPathComponent("steam-prefix", isDirectory: true),
                "兼容 Steam Prefix（.vnlauncher）"
            ),
            (
                steamExecutableURL(in: steamInstallDir(in: home
                    .appendingPathComponent(".vnlauncher-zero", isDirectory: true)
                    .appendingPathComponent("steam-prefix", isDirectory: true))),
                home
                    .appendingPathComponent(".vnlauncher-zero", isDirectory: true)
                    .appendingPathComponent("steam-prefix", isDirectory: true),
                "兼容 Steam Prefix（.vnlauncher-zero）"
            )
        ]

        if
            let selected = selectedGame,
            !selected.prefixDir.isEmpty
        {
            let prefix = URL(fileURLWithPath: selected.prefixDir, isDirectory: true)
            candidates.append((
                steamExecutableURL(in: steamInstallDir(in: prefix)),
                prefix,
                "当前游戏 Prefix"
            ))
        }

        return WineSteamCleanupPolicy.contexts(candidates.map {
            WineSteamEntryContext(steamExePath: $0.steamExe.path,
                                 prefixPath: $0.prefix.path,
                                 sourceLabel: $0.source)
        }, fileManager: fm)
    }

    private func steamInstallDir(in prefix: URL) -> URL {
        prefix
            .appendingPathComponent("drive_c", isDirectory: true)
            .appendingPathComponent("Program Files (x86)", isDirectory: true)
            .appendingPathComponent("Steam", isDirectory: true)
    }

    private func steamExecutableURL(in steamDir: URL) -> URL {
        let candidates = ["Steam.exe", "steam.exe"].map { steamDir.appendingPathComponent($0) }
        return candidates.first(where: { fm.fileExists(atPath: $0.path) }) ?? candidates[0]
    }

    private func launchSteamInstallerIfAvailable(wineBinary: String) -> Bool {
        guard permitRuntimeLaunch() else { return false }
        guard let installer = existingSteamInstallerURL() else {
            return false
        }

        let defaultPrefix = appDataDir.appendingPathComponent("steam-prefix", isDirectory: true)
        try? fm.createDirectory(at: defaultPrefix, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wineBinary)
        process.arguments = [installer.path]
        process.currentDirectoryURL = installer.deletingLastPathComponent()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = defaultPrefix.path
        env["WINEDEBUG"] = "-all"
        process.environment = env

        do {
            try process.run()
            statusMessage = "未检测到 Steam 客户端，已自动启动 Steam 安装器。安装完成后再点一次即可。"
            return true
        } catch {
            statusMessage = "启动 Steam 安装器失败：\(error.localizedDescription)"
            return true
        }
    }

    private func existingSteamInstallerURL() -> URL? {
        let home = homeDirectory
        let installerCandidates: [URL] = [
            appDataDir
                .appendingPathComponent("downloads", isDirectory: true)
                .appendingPathComponent("SteamSetup.exe"),
            home
                .appendingPathComponent(".vnlauncher", isDirectory: true)
                .appendingPathComponent("downloads", isDirectory: true)
                .appendingPathComponent("SteamSetup.exe"),
            home
                .appendingPathComponent(".vnlauncher-zero", isDirectory: true)
                .appendingPathComponent("downloads", isDirectory: true)
                .appendingPathComponent("SteamSetup.exe")
        ]

        return installerCandidates.first(where: { fm.fileExists(atPath: $0.path) })
    }

    private func downloadWineSteamInstaller() async throws -> URL {
        let downloadsDir = appDataDir.appendingPathComponent("downloads", isDirectory: true)
        try fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let targetURL = downloadsDir.appendingPathComponent("SteamSetup.exe")
        let session = URLSession(configuration: .default)
        var request = URLRequest(url: Self.steamInstallerURL)
        request.setValue("Shiori/1.0", forHTTPHeaderField: "User-Agent")

        let (tmpURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "WineSteamInstaller",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Steam 安装器下载失败（服务器返回异常）。"]
            )
        }

        try? fm.removeItem(at: targetURL)
        try fm.moveItem(at: tmpURL, to: targetURL)
        return targetURL
    }

    private func inferFromRunningPrefixes() -> WineSteamEntryContext? {
        guard let selected = selectedGame else { return nil }
        let possibleSteamExe = steamExecutableURL(in: steamInstallDir(in: URL(fileURLWithPath: selected.prefixDir, isDirectory: true)))

        guard fm.fileExists(atPath: possibleSteamExe.path), !selected.prefixDir.isEmpty else { return nil }
        return WineSteamEntryContext(
            steamExePath: possibleSteamExe.path,
            prefixPath: selected.prefixDir,
            sourceLabel: "当前游戏 Prefix"
        )
    }

    private func requestWineSteamWindowFromDockIfNeeded(activatedPID: Int32) async {
        guard !Task.isCancelled, !isSteamLibraryBusy else { return }
        let now = Date()
        let visiblePIDs = visibleUserFacingWindowOwnerProcessIDs()
        for context in resolveWineSteamCleanupContexts() {
            let pids = await Task.detached(priority: .utility) {
                (WineSteamProcessService.mainClientPIDs(in: context.prefixPath),
                 WineSteamProcessService.clientPIDs(in: context.prefixPath))
            }.value
            guard !Task.isCancelled, !isSteamLibraryBusy else { return }
            guard WineSteamDockReopenPolicy.shouldRequestReopen(activatedPID: activatedPID,
                steamClientPIDs: pids.1, steamMainClientPIDs: pids.0,
                visibleWindowOwnerPIDs: visiblePIDs, now: now,
                lastRequestAt: lastWineSteamWindowReopenRequestAt) else { continue }
            guard let lease = beginSteamOperation(.launching) else { return }
            if let task = wineSteamDockActivationTask { steamOperations.track(task, for: lease) }
            defer { finishSteamOperation(lease) }
            lastWineSteamWindowReopenRequestAt = now
            _ = await launchWineSteam(extraArguments: [WineSteamDockReopenPolicy.showMainWindowURL],
                successMessage: "已通过程序坞请求重新显示 Wine Steam 主窗口。",
                missingSteamMessage: "未找到当前程序坞图标所属的 Wine Steam。",
                allowInstallerFallback: false, contextOverride: context)
            return
        }
    }

    /// 只使用 CGWindowList 可公开读取的窗口属主、层级和尺寸，不需要读取窗口标题。
    /// 过滤掉 CEF/Wine 的透明或极小辅助窗口，防止它们被误当成可交互的 Steam 主窗口。
    private func visibleUserFacingWindowOwnerProcessIDs() -> Set<Int32> {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var result = Set<Int32>()
        for window in windowInfo {
            guard let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0 else {
                continue
            }

            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.01,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width >= 160,
                  height >= 100 else {
                continue
            }

            result.insert(ownerPID)
        }
        return result
    }

    private func isURL(_ child: URL, inside parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        let parentPrefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        return childPath == parentPath || childPath.hasPrefix(parentPrefix)
    }

    private func relativePath(of child: URL, under parent: URL) -> String? {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        let parentPrefix = parentPath.hasSuffix("/") ? parentPath : parentPath + "/"
        guard childPath.hasPrefix(parentPrefix) else { return nil }
        let relative = String(childPath.dropFirst(parentPrefix.count))
        return relative.isEmpty ? nil : relative
    }

    private func appendingRelativePath(_ relativePath: String, to baseURL: URL) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(baseURL) { partial, component in
                partial.appendingPathComponent(String(component))
            }
    }

    private func pathHasSymbolicLinkComponent(_ url: URL, stoppingAt root: URL) -> Bool {
        let targetPath = url.standardizedFileURL.path
        let rootURL = root.standardizedFileURL
        let rootPath = rootURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath == rootPath || targetPath.hasPrefix(rootPrefix) else { return false }
        if isSymbolicLink(at: rootURL) { return true }
        if targetPath == rootPath { return false }

        let relative = String(targetPath.dropFirst(rootPrefix.count))
        var current = rootURL
        for component in relative.split(separator: "/") {
            current = current.appendingPathComponent(String(component))
            if isSymbolicLink(at: current) { return true }
        }
        return false
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    private func uniqueDirectory(in parent: URL, baseName: String) -> URL {
        var candidate = parent.appendingPathComponent(baseName, isDirectory: true)
        if !fm.fileExists(atPath: candidate.path) { return candidate }

        var index = 2
        while true {
            candidate = parent.appendingPathComponent("\(baseName)-\(index)", isDirectory: true)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func copyDirectoryPreferClone(from source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-cRp", source.path, destination.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return
            }
        } catch {
            // Fall back to Foundation copy below.
        }

        try? fm.removeItem(at: destination)
        try fm.copyItem(at: source, to: destination)
    }

    private func defaultPrefixDir(for name: String) -> String {
        let safe = slug(name)
        let path = prefixesDir.appendingPathComponent(safe, isDirectory: true)
        try? fm.createDirectory(at: path, withIntermediateDirectories: true)
        return path.path
    }

    private func slug(_ raw: String) -> String {
        let lower = raw.lowercased()
        let mapped = lower.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "." { return ch }
            return "_"
        }
        let joined = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_-."))
        return joined.isEmpty ? UUID().uuidString.lowercased() : joined
    }

    private func nextUntitledName() -> String {
        let existing = Set(games.map(\.name))
        if !existing.contains("新游戏") { return "新游戏" }
        var i = 2
        while existing.contains("新游戏 \(i)") { i += 1 }
        return "新游戏 \(i)"
    }
}
