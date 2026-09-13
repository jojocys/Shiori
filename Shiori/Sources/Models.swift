import Foundation

enum LaunchLanguageMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case japanese
    case chineseSimplified

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .japanese: return "日文"
        case .chineseSimplified: return "简中"
        }
    }
}

/// 游戏平台：Windows（Wine，默认核心）/ Nintendo Switch（原生模拟器）。
enum GamePlatform: String, Codable {
    case windows
    case switchEmu = "switch"

    var badge: String {
        switch self {
        case .windows: return "WIN"
        case .switchEmu: return "SWITCH"
        }
    }

    var title: String {
        switch self {
        case .windows: return "Windows"
        case .switchEmu: return "Nintendo Switch"
        }
    }
}

struct GameEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var gameFolderPath: String
    var exePath: String
    var prefixDir: String
    var engineHint: String
    var platform: GamePlatform
    var romPath: String          // Switch: 游戏 ROM（.nsp/.xci）
    var emulatorAppPath: String  // Switch: 模拟器 .app（任意，不限 Ryujinx）
    var launchScriptPath: String // Switch: 现成启动脚本（优先复刻）
    var launchLanguageMode: LaunchLanguageMode
    var iconPath: String         // 自定义图标：用户手动指定的图片文件（留空则自动提取/回退）
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        gameFolderPath: String = "",
        exePath: String = "",
        prefixDir: String = "",
        engineHint: String = "未识别",
        platform: GamePlatform = .windows,
        romPath: String = "",
        emulatorAppPath: String = "",
        launchScriptPath: String = "",
        launchLanguageMode: LaunchLanguageMode = .auto,
        iconPath: String = "",
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.gameFolderPath = gameFolderPath
        self.exePath = exePath
        self.prefixDir = prefixDir
        self.engineHint = engineHint
        self.platform = platform
        self.romPath = romPath
        self.emulatorAppPath = emulatorAppPath
        self.launchScriptPath = launchScriptPath
        self.launchLanguageMode = launchLanguageMode
        self.iconPath = iconPath
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case gameFolderPath
        case exePath
        case prefixDir
        case engineHint
        case platform
        case romPath
        case emulatorAppPath
        case launchScriptPath
        case launchLanguageMode
        case iconPath
        case notes
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名游戏"
        gameFolderPath = try container.decodeIfPresent(String.self, forKey: .gameFolderPath) ?? ""
        exePath = try container.decodeIfPresent(String.self, forKey: .exePath) ?? ""
        prefixDir = try container.decodeIfPresent(String.self, forKey: .prefixDir) ?? ""
        engineHint = try container.decodeIfPresent(String.self, forKey: .engineHint) ?? "未识别"
        platform = try container.decodeIfPresent(GamePlatform.self, forKey: .platform) ?? .windows
        romPath = try container.decodeIfPresent(String.self, forKey: .romPath) ?? ""
        emulatorAppPath = try container.decodeIfPresent(String.self, forKey: .emulatorAppPath) ?? ""
        launchScriptPath = try container.decodeIfPresent(String.self, forKey: .launchScriptPath) ?? ""
        launchLanguageMode = try container.decodeIfPresent(LaunchLanguageMode.self, forKey: .launchLanguageMode) ?? .auto
        iconPath = try container.decodeIfPresent(String.self, forKey: .iconPath) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    var folderURL: URL? {
        guard !gameFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: gameFolderPath)
    }

    var exeURL: URL? {
        guard !exePath.isEmpty else { return nil }
        return URL(fileURLWithPath: exePath)
    }

    var prefixURL: URL? {
        guard !prefixDir.isEmpty else { return nil }
        return URL(fileURLWithPath: prefixDir)
    }

    var displaySubtitle: String {
        switch platform {
        case .windows:
            if let exeURL { return exeURL.lastPathComponent }
            if let folderURL { return folderURL.lastPathComponent }
            return "未配置"
        case .switchEmu:
            if !romPath.isEmpty { return URL(fileURLWithPath: romPath).lastPathComponent }
            if !launchScriptPath.isEmpty { return URL(fileURLWithPath: launchScriptPath).lastPathComponent }
            if let folderURL { return folderURL.lastPathComponent }
            return "未配置"
        }
    }
}

struct GameStoreFile: Codable {
    var selectedGameID: UUID?
    var games: [GameEntry]
    var preferredWineBinaryPath: String
    var preferredWineAppPath: String
    // Switch 运行所需，由用户自备（不随 App 分发）。可选以兼容旧库。
    var preferredKeysPath: String?
    var preferredFirmwarePath: String?
    // 已成功启动过的 Wine Steam 游戏 AppID（安装完成 + 运行过 → 不再显示预填充黄字提示）。
    var launchedWineSteamAppIDs: [String]?
}

struct ScanCandidate: Identifiable, Hashable {
    let id = UUID()
    let exeURL: URL
    let score: Int
    let reason: String
}

enum AntiCheatSeverity: Hashable {
    /// 内核级反作弊，macOS / Wine 上无任何可行路径。
    case blocking
    /// 内核级但存在 Linux/Proton 适配开关，macOS 上仍极难成功。
    case unlikely

    var headline: String {
        switch self {
        case .blocking: return "macOS 无法运行"
        case .unlikely: return "macOS 上几乎无法运行"
        }
    }
}

struct AntiCheatHit: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let severity: AntiCheatSeverity
    let evidence: [String]
    let advice: String
}

struct ScanResult {
    let folderURL: URL
    let engineHint: String
    let xp3Count: Int
    let exeCandidates: [ScanCandidate]
    let antiCheats: [AntiCheatHit]
    var platform: GamePlatform = .windows
    var romURL: URL? = nil            // Switch ROM（.nsp/.xci）
    var emulatorAppURL: URL? = nil    // 检测到的任意 Switch 模拟器 .app
    var emulatorName: String? = nil   // 模拟器显示名（如 Ryujinx / yuzu …）
    var launchScriptURL: URL? = nil   // 现成启动脚本（.command/.sh）

    var recommendedEXE: URL? { exeCandidates.first?.exeURL }
    var hasBlockingAntiCheat: Bool { antiCheats.contains { $0.severity == .blocking } }
    var isSwitch: Bool { platform == .switchEmu }
}

struct RuntimeCheckItem: Identifiable {
    enum State {
        case ok
        case bundled
        case warning
        case missing
        case blocked

        var label: String {
            switch self {
            case .ok: return "就绪"
            case .bundled: return "已内置"
            case .warning: return "需注意"
            case .missing: return "未安装"
            case .blocked: return "被拦截"
            }
        }
    }

    let id = UUID()
    let title: String
    let detail: String
    let state: State
}

struct RuntimeCheckReport {
    var items: [RuntimeCheckItem]
    var resolvedWineBinaryPath: String
    var detectedWineAppPath: String
    var rosettaInstalled: Bool
    var xquartzInstalled: Bool
    var gatekeeperBlocked: Bool
}

struct WineSteamEntryContext: Hashable {
    var steamExePath: String
    var prefixPath: String
    var sourceLabel: String
}

struct InstallerDownloadResult {
    let downloadedFileURL: URL
    let sourceURL: URL
}
