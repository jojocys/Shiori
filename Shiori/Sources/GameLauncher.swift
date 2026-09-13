import Foundation

enum GameLauncherError: LocalizedError {
    case gameNotConfigured
    case gameFolderMissing
    case exeMissing
    case prefixCreateFailed
    case wineNotFound
    case logCreateFailed
    case romMissing
    case emulatorMissing
    case switchLaunchFailed

    var errorDescription: String? {
        switch self {
        case .gameNotConfigured: return "请先在 P1 选择游戏文件夹并确认主程序。"
        case .gameFolderMissing: return "游戏目录不存在。"
        case .exeMissing: return "主程序 EXE 不存在。"
        case .prefixCreateFailed: return "无法创建 Wine Prefix 文件夹。"
        case .wineNotFound: return "未找到 Wine。请使用内置 Wine 版本的 App，或手动指定 Wine。"
        case .logCreateFailed: return "无法创建日志文件。"
        case .romMissing: return "Switch ROM 不存在，请在配置中重新选择 ROM。"
        case .emulatorMissing: return "未找到 Switch 模拟器，请在配置中指定模拟器 App。"
        case .switchLaunchFailed: return "启动 Switch 模拟器失败。"
        }
    }
}

enum GameLauncher {
    /// 统一入口：按平台路由。Windows 走 Wine（默认核心，体验不变）；Switch 才跳出 Wine 走原生模拟器。
    static func launch(game: GameEntry, logsDir: URL, preferredWineBinaryPath: String,
                       switchKeysPath: String = "", switchFirmwarePath: String = "", switchDataDir: URL? = nil) throws -> URL {
        switch game.platform {
        case .windows:
            return try launchWindows(game: game, logsDir: logsDir, preferredWineBinaryPath: preferredWineBinaryPath)
        case .switchEmu:
            return try launchSwitch(game: game, logsDir: logsDir, keysPath: switchKeysPath, firmwarePath: switchFirmwarePath, dataDir: switchDataDir)
        }
    }

    private static func launchWindows(game: GameEntry, logsDir: URL, preferredWineBinaryPath: String) throws -> URL {
        guard let exeURL = game.exeURL else { throw GameLauncherError.gameNotConfigured }
        guard let folderURL = game.folderURL else { throw GameLauncherError.gameFolderMissing }
        let fm = FileManager.default
        guard fm.fileExists(atPath: folderURL.path) else { throw GameLauncherError.gameFolderMissing }
        guard fm.fileExists(atPath: exeURL.path) else { throw GameLauncherError.exeMissing }

        let prefixURL: URL
        if let existingPrefix = game.prefixURL {
            prefixURL = existingPrefix
        } else {
            throw GameLauncherError.gameNotConfigured
        }

        do {
            try fm.createDirectory(at: prefixURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            throw GameLauncherError.prefixCreateFailed
        }

        guard let wineBinary = RuntimeManager.resolveWineBinary(preferred: preferredWineBinaryPath) else {
            throw GameLauncherError.wineNotFound
        }
        let locale = resolvedLocale(for: game)

        let logURL = logsDir.appendingPathComponent(logFileName(for: game))
        guard fm.createFile(atPath: logURL.path, contents: nil) || fm.fileExists(atPath: logURL.path) else {
            throw GameLauncherError.logCreateFailed
        }
        let executableArgument = windowsDriveCPath(for: exeURL, prefixURL: prefixURL) ?? exeURL.path

        let prelude = [
            "[\(Date())] Launch request",
            "GAME=\(game.name)",
            "FOLDER=\(folderURL.path)",
            "EXE=\(exeURL.path)",
            "EXE_ARG=\(executableArgument)",
            "PREFIX=\(prefixURL.path)",
            "WINE=\(wineBinary)",
            "LANG_MODE=\(game.launchLanguageMode.rawValue)",
            "LANG=\(locale)",
            ""
        ].joined(separator: "\n")
        if let data = prelude.data(using: .utf8) {
            try? data.append(to: logURL)
        }

        let fileHandle = try FileHandle(forWritingTo: logURL)
        try fileHandle.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wineBinary)
        process.arguments = [executableArgument]
        process.currentDirectoryURL = folderURL
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefixURL.path
        env["WINEDEBUG"] = "-all"
        env["LANG"] = locale
        env["LC_ALL"] = locale
        process.environment = env
        process.standardOutput = fileHandle
        process.standardError = fileHandle
        process.terminationHandler = { _ in try? fileHandle.close() }

        try process.run()
        return logURL
    }

    private static func windowsDriveCPath(for url: URL, prefixURL: URL) -> String? {
        let driveCURL = prefixURL
            .appendingPathComponent("drive_c", isDirectory: true)
            .standardizedFileURL
        let targetURL = url.standardizedFileURL
        let driveCPath = driveCURL.path
        let driveCPrefix = driveCPath.hasSuffix("/") ? driveCPath : driveCPath + "/"
        let targetPath = targetURL.path

        if targetPath == driveCPath { return "C:\\" }
        guard targetPath.hasPrefix(driveCPrefix) else {
            return nil
        }

        let relative = String(targetPath.dropFirst(driveCPrefix.count))
        let components = relative.split(separator: "/").map(String.init)
        return "C:\\" + components.joined(separator: "\\")
    }

    /// Switch：优先复刻游戏夹里的现成一键脚本（兼容任意模拟器/参数/汉化设置）；否则通用 open -n。
    private static func launchSwitch(game: GameEntry, logsDir: URL, keysPath: String, firmwarePath: String, dataDir: URL?) throws -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logURL = logsDir.appendingPathComponent(logFileName(for: game))
        _ = fm.createFile(atPath: logURL.path, contents: nil)

        let process = Process()
        var note = ""

        if !game.launchScriptPath.isEmpty, fm.fileExists(atPath: game.launchScriptPath) {
            // 1) 用户现成脚本：完整设置（含 mod / 汉化），最忠实
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [game.launchScriptPath]
            note = "SCRIPT=\(game.launchScriptPath)"
        } else if let bundled = SwitchRuntime.resolveBundledEmulator(),
                  let exec = SwitchRuntime.executable(in: bundled),
                  let dataDir {
            // 2) 内置模拟器 + 受管数据目录（铺入用户自备 keys/固件）→ 真正的"一键"
            guard !game.romPath.isEmpty, fm.fileExists(atPath: game.romPath) else {
                throw GameLauncherError.romMissing
            }
            SwitchRuntime.prepareDataDir(dataDir, keysPath: keysPath, firmwarePath: firmwarePath)
            process.executableURL = exec
            process.arguments = ["--root-data-dir", dataDir.path, game.romPath]
            note = "EMULATOR(bundled)=\(bundled.path)\nDATA=\(dataDir.path)\nROM=\(game.romPath)"
        } else if !game.emulatorAppPath.isEmpty, fm.fileExists(atPath: game.emulatorAppPath) {
            // 3) 用户已装的模拟器：open -n <模拟器.app> --args <rom>，适配 Ryujinx / yuzu 系等
            guard !game.romPath.isEmpty, fm.fileExists(atPath: game.romPath) else {
                throw GameLauncherError.romMissing
            }
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", game.emulatorAppPath, "--args", game.romPath]
            note = "EMULATOR(user)=\(game.emulatorAppPath)\nROM=\(game.romPath)"
        } else {
            throw GameLauncherError.emulatorMissing
        }

        let prelude = [
            "[\(Date())] Switch launch",
            "GAME=\(game.name)",
            note,
            ""
        ].joined(separator: "\n")
        if let data = prelude.data(using: .utf8) { try? data.append(to: logURL) }

        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { _ in try? handle.close() }
        }

        do {
            try process.run()
        } catch {
            throw GameLauncherError.switchLaunchFailed
        }
        return logURL
    }

    private static func logFileName(for game: GameEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safe = game.name.replacingOccurrences(of: "/", with: "_")
        return "\(safe)-\(formatter.string(from: Date())).log"
    }

    static func resolvedLocale(for game: GameEntry) -> String {
        switch game.launchLanguageMode {
        case .japanese:
            return "ja_JP.UTF-8"
        case .chineseSimplified:
            return "zh_CN.UTF-8"
        case .auto:
            let samples = [
                game.name.lowercased(),
                game.exePath.lowercased(),
                game.gameFolderPath.lowercased()
            ].joined(separator: " ")
            let chineseHints = ["汉化", "簡中", "简中", "zh_cn", "chs", "gbk", "中文", "cn_patch", "chinese"]
            if chineseHints.contains(where: { samples.contains($0.lowercased()) }) {
                return "zh_CN.UTF-8"
            }
            return "ja_JP.UTF-8"
        }
    }
}

private extension Data {
    func append(to url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: self)
            try handle.close()
        } else {
            try write(to: url, options: .atomic)
        }
    }
}
