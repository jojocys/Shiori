import CoreText
import Foundation

enum WineFontCompatibilityProfile: String, Codable, Sendable {
    case simplifiedChinese
    case japanese

    var title: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .japanese: return "日文"
        }
    }

    fileprivate var preferredFontFamilies: [String] {
        switch self {
        case .simplifiedChinese:
            return ["Hiragino Sans GB", "Heiti SC"]
        case .japanese:
            return ["Hiragino Sans", "Hiragino Kaku Gothic ProN"]
        }
    }
}

struct WineFontCompatibilityReport: Sendable {
    let summary: String
    let changedCount: Int
    let preservedCount: Int
}

struct WineFontRegistryChange: Codable, Hashable, Sendable {
    let key: String
    let name: String
    let previousValue: String?
    let appliedValue: String

    var identity: String { "\(key.lowercased())\u{0}\(name.lowercased())" }
}

struct WineFontRepairRecord: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let updatedAt: Date
    let profile: WineFontCompatibilityProfile
    let targetFontFamily: String
    let changes: [WineFontRegistryChange]
}

struct WineFontRepairPlan: Sendable {
    let changes: [WineFontRegistryChange]
    let preservedNames: [String]
}

enum WineFontCompatibilityError: LocalizedError {
    case prefixMissing
    case wineMissing
    case compatibleFontMissing(WineFontCompatibilityProfile)
    case commandTimedOut
    case commandFailed(String)
    case recordReadFailed(String)
    case recordWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .prefixMissing:
            return "当前游戏没有可用的 Wine Prefix。"
        case .wineMissing:
            return "未找到当前 Shiori 使用的 Wine 执行文件。"
        case .compatibleFontMissing(let profile):
            return "macOS 中未找到可用于\(profile.title)的兼容字体。"
        case .commandTimedOut:
            return "Wine 字体修复命令超时。请结束该 Prefix 中卡住的 Windows 程序后重试。"
        case .commandFailed(let detail):
            return "Wine 字体修复命令失败：\(detail)"
        case .recordReadFailed(let detail):
            return "无法读取现有字体修复记录：\(detail)。未修改 Prefix。"
        case .recordWriteFailed(let detail):
            return "字体映射已写入，但无法保存回滚记录：\(detail)"
        }
    }
}

enum WineFontCompatibility {
    static let replacementsKey = "HKCU\\Software\\Wine\\Fonts\\Replacements"
    static let fontSubstitutesKey = "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes"

    private static let repairRecordName = ".shiori-font-compatibility.json"
    private static let commandTimeout: TimeInterval = 30

    /// These aliases follow the current Winetricks fakechinese/fakejapanese verbs.
    /// Applying both groups makes a prefix resilient to translated games that retain
    /// Japanese font names while rendering Simplified Chinese text.
    static let cjkAliases = [
        "Dengxian", "FangSong", "KaiTi", "Microsoft YaHei", "Microsoft YaHei UI",
        "NSimSun", "SimHei", "SimKai", "SimSun", "SimSun-ExtB",
        "Meiryo", "Meiryo UI", "MS Gothic", "MS PGothic", "MS Mincho",
        "MS PMincho", "MS UI Gothic", "UD Digi KyoKasho N-R",
        "UD Digi KyoKasho NK-R", "UD Digi KyoKasho NP-R", "Yu Gothic",
        "Yu Gothic UI", "Yu Mincho", "メイリオ", "ＭＳ ゴシック",
        "ＭＳ Ｐゴシック", "ＭＳ 明朝", "ＭＳ Ｐ明朝"
    ]

    static func profile(for game: GameEntry) -> WineFontCompatibilityProfile {
        GameLauncher.resolvedLocale(for: game).hasPrefix("zh_") ? .simplifiedChinese : .japanese
    }

    static func hasRepairRecord(prefixPath: String) -> Bool {
        guard !prefixPath.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: recordURL(prefixPath: prefixPath).path)
    }

    static func repair(
        prefixPath: String,
        wineBinary: String,
        profile: WineFontCompatibilityProfile
    ) throws -> WineFontCompatibilityReport {
        guard !prefixPath.isEmpty else { throw WineFontCompatibilityError.prefixMissing }
        guard !wineBinary.isEmpty, FileManager.default.isExecutableFile(atPath: wineBinary) else {
            throw WineFontCompatibilityError.wineMissing
        }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: prefixPath, isDirectory: true),
            withIntermediateDirectories: true
        )

        let availableFamilies = Set(
            (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
                .map { $0.lowercased() }
        )
        guard let targetFamily = profile.preferredFontFamilies.first(where: {
            availableFamilies.contains($0.lowercased())
        }) else {
            throw WineFontCompatibilityError.compatibleFontMissing(profile)
        }

        let replacements = try queryRegistryKey(replacementsKey, wineBinary: wineBinary, prefixPath: prefixPath)
        let substitutes = try queryRegistryKey(fontSubstitutesKey, wineBinary: wineBinary, prefixPath: prefixPath)
        let existingRecord: WineFontRepairRecord?
        if hasRepairRecord(prefixPath: prefixPath) {
            do {
                existingRecord = try loadRecord(prefixPath: prefixPath)
            } catch {
                throw WineFontCompatibilityError.recordReadFailed(error.localizedDescription)
            }
        } else {
            existingRecord = nil
        }
        let plan = makePlan(
            targetFamily: targetFamily,
            replacements: replacements,
            fontSubstitutes: substitutes,
            ownedChanges: existingRecord?.changes ?? []
        )

        if plan.changes.isEmpty {
            let preserved = plan.preservedNames.count
            let suffix = preserved == 0 ? "" : "；保留了 \(preserved) 项已有自定义映射"
            return WineFontCompatibilityReport(
                summary: "中日文字体兼容已经就绪（\(targetFamily)）\(suffix)。",
                changedCount: 0,
                preservedCount: preserved
            )
        }

        do {
            try importRegistryValues(
                plan.changes.map { ($0.key, $0.name, Optional($0.appliedValue)) },
                wineBinary: wineBinary,
                prefixPath: prefixPath
            )
        } catch {
            // A .reg import can theoretically stop after a partial write.
            try? importRegistryValues(
                plan.changes.map { ($0.key, $0.name, $0.previousValue) },
                wineBinary: wineBinary,
                prefixPath: prefixPath
            )
            throw error
        }

        let mergedChanges = merge(existing: existingRecord?.changes ?? [], applied: plan.changes)
        let record = WineFontRepairRecord(
            version: WineFontRepairRecord.currentVersion,
            updatedAt: Date(),
            profile: profile,
            targetFontFamily: targetFamily,
            changes: mergedChanges
        )
        do {
            try saveRecord(record, prefixPath: prefixPath)
        } catch {
            // Keep the prefix reversible even when persistence fails.
            try? importRegistryValues(
                plan.changes.map { ($0.key, $0.name, $0.previousValue) },
                wineBinary: wineBinary,
                prefixPath: prefixPath
            )
            throw WineFontCompatibilityError.recordWriteFailed(error.localizedDescription)
        }

        let preserved = plan.preservedNames.count
        let suffix = preserved == 0 ? "" : "；保留了 \(preserved) 项已有自定义映射"
        return WineFontCompatibilityReport(
            summary: "已写入 \(plan.changes.count) 项中日文字体映射（\(targetFamily)）\(suffix)。请重启游戏验证。",
            changedCount: plan.changes.count,
            preservedCount: preserved
        )
    }

    static func restore(prefixPath: String, wineBinary: String) throws -> WineFontCompatibilityReport {
        guard !prefixPath.isEmpty else { throw WineFontCompatibilityError.prefixMissing }
        guard !wineBinary.isEmpty, FileManager.default.isExecutableFile(atPath: wineBinary) else {
            throw WineFontCompatibilityError.wineMissing
        }
        let record = try loadRecord(prefixPath: prefixPath)
        let replacements = try queryRegistryKey(replacementsKey, wineBinary: wineBinary, prefixPath: prefixPath)
        let substitutes = try queryRegistryKey(fontSubstitutesKey, wineBinary: wineBinary, prefixPath: prefixPath)
        let snapshots = [replacementsKey: replacements, fontSubstitutesKey: substitutes]

        var restoreValues: [(String, String, String?)] = []
        var preservedCount = 0
        for change in record.changes.reversed() {
            let current = snapshots[change.key].flatMap { registryValue(named: change.name, in: $0) }
            guard current == change.appliedValue else {
                preservedCount += 1
                continue
            }
            restoreValues.append((change.key, change.name, change.previousValue))
        }
        try importRegistryValues(restoreValues, wineBinary: wineBinary, prefixPath: prefixPath)

        try? FileManager.default.removeItem(at: recordURL(prefixPath: prefixPath))
        let suffix = preservedCount == 0 ? "" : "；保留了 \(preservedCount) 项后来被修改的设置"
        return WineFontCompatibilityReport(
            summary: "已撤销 \(restoreValues.count) 项 Shiori 字体映射\(suffix)。请重启游戏验证。",
            changedCount: restoreValues.count,
            preservedCount: preservedCount
        )
    }

    static func makePlan(
        targetFamily: String,
        replacements: [String: String],
        fontSubstitutes: [String: String],
        ownedChanges: [WineFontRegistryChange]
    ) -> WineFontRepairPlan {
        let owned = Dictionary(uniqueKeysWithValues: ownedChanges.map { ($0.identity, $0) })
        var changes: [WineFontRegistryChange] = []
        var preserved: [String] = []

        for alias in cjkAliases {
            appendPlannedChange(
                key: replacementsKey,
                name: alias,
                target: targetFamily,
                current: registryValue(named: alias, in: replacements),
                allowedDefaults: [],
                owned: owned,
                changes: &changes,
                preserved: &preserved
            )
        }

        appendPlannedChange(
            key: fontSubstitutesKey,
            name: "MS Shell Dlg",
            target: targetFamily,
            current: registryValue(named: "MS Shell Dlg", in: fontSubstitutes),
            allowedDefaults: ["SimSun", "Tahoma"],
            owned: owned,
            changes: &changes,
            preserved: &preserved
        )
        appendPlannedChange(
            key: fontSubstitutesKey,
            name: "MS Shell Dlg 2",
            target: targetFamily,
            current: registryValue(named: "MS Shell Dlg 2", in: fontSubstitutes),
            allowedDefaults: ["Tahoma", "SimSun"],
            owned: owned,
            changes: &changes,
            preserved: &preserved
        )

        return WineFontRepairPlan(changes: changes, preservedNames: preserved)
    }

    static func parseRegistryQuery(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \Character.isNewline) {
            let parts = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard let typeIndex = parts.firstIndex(where: { $0.hasPrefix("REG_") }), typeIndex > 0,
                  typeIndex + 1 < parts.count else { continue }
            let name = parts[..<typeIndex].joined(separator: " ")
            let value = parts[(typeIndex + 1)...].joined(separator: " ")
            values[name] = value
        }
        return values
    }

    private static func appendPlannedChange(
        key: String,
        name: String,
        target: String,
        current: String?,
        allowedDefaults: Set<String>,
        owned: [String: WineFontRegistryChange],
        changes: inout [WineFontRegistryChange],
        preserved: inout [String]
    ) {
        if let current, current.caseInsensitiveCompare(target) == .orderedSame { return }

        let identity = "\(key.lowercased())\u{0}\(name.lowercased())"
        let previousOwned = owned[identity]
        let isOwnedCurrentValue = previousOwned?.appliedValue.caseInsensitiveCompare(current ?? "") == .orderedSame
        let isAllowedDefault = current.map { currentValue in
            allowedDefaults.contains { $0.caseInsensitiveCompare(currentValue) == .orderedSame }
        } ?? false
        let mayReplace = current == nil || isAllowedDefault || isOwnedCurrentValue
        guard mayReplace else {
            preserved.append(name)
            return
        }

        changes.append(WineFontRegistryChange(
            key: key,
            name: name,
            previousValue: previousOwned == nil ? current : previousOwned?.previousValue,
            appliedValue: target
        ))
    }

    private static func merge(
        existing: [WineFontRegistryChange],
        applied: [WineFontRegistryChange]
    ) -> [WineFontRegistryChange] {
        var values = Dictionary(uniqueKeysWithValues: existing.map { ($0.identity, $0) })
        for change in applied { values[change.identity] = change }
        return values.values.sorted {
            "\($0.key)\u{0}\($0.name)".localizedStandardCompare("\($1.key)\u{0}\($1.name)") == .orderedAscending
        }
    }

    private static func registryValue(named name: String, in values: [String: String]) -> String? {
        if let exact = values[name] { return exact }
        return values.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    private static func queryRegistryKey(
        _ key: String,
        wineBinary: String,
        prefixPath: String
    ) throws -> [String: String] {
        let result = try runWine(
            wineBinary: wineBinary,
            arguments: ["reg", "query", key],
            prefixPath: prefixPath
        )
        if result.status == 0 { return parseRegistryQuery(result.output) }

        let lower = result.output.lowercased()
        if lower.contains("unable to find") || lower.contains("not found") || lower.contains("找不到") {
            return [:]
        }
        throw WineFontCompatibilityError.commandFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func importRegistryValues(
        _ values: [(key: String, name: String, value: String?)],
        wineBinary: String,
        prefixPath: String
    ) throws {
        guard !values.isEmpty else { return }
        let registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shiori-font-\(UUID().uuidString).reg")
        defer { try? FileManager.default.removeItem(at: registryURL) }
        try makeRegistryData(values).write(to: registryURL, options: .atomic)

        let result = try runWine(
            wineBinary: wineBinary,
            arguments: ["reg", "import", registryURL.path],
            prefixPath: prefixPath
        )
        guard result.status == 0 else {
            throw WineFontCompatibilityError.commandFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func makeRegistryData(
        _ values: [(key: String, name: String, value: String?)]
    ) throws -> Data {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        let grouped = Dictionary(grouping: values) { $0.key }
        for key in grouped.keys.sorted() {
            lines.append("[\(expandedRegistryKey(key))]")
            for entry in (grouped[key] ?? []).sorted(by: { $0.name < $1.name }) {
                let name = escapedRegistryString(entry.name)
                if let value = entry.value {
                    lines.append("\"\(name)\"=\"\(escapedRegistryString(value))\"")
                } else {
                    lines.append("\"\(name)\"=-")
                }
            }
            lines.append("")
        }

        guard var data = lines.joined(separator: "\r\n").data(using: .utf16LittleEndian) else {
            throw WineFontCompatibilityError.commandFailed("无法生成 Unicode 注册表文件")
        }
        data.insert(contentsOf: [0xff, 0xfe], at: 0)
        return data
    }

    private static func expandedRegistryKey(_ key: String) -> String {
        if key.hasPrefix("HKCU\\") { return key.replacingOccurrences(of: "HKCU\\", with: "HKEY_CURRENT_USER\\") }
        if key.hasPrefix("HKLM\\") { return key.replacingOccurrences(of: "HKLM\\", with: "HKEY_LOCAL_MACHINE\\") }
        return key
    }

    private static func escapedRegistryString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runWine(
        wineBinary: String,
        arguments: [String],
        prefixPath: String
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shiori-wine-command-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
            throw WineFontCompatibilityError.commandFailed("无法创建临时命令日志")
        }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.executableURL = URL(fileURLWithPath: wineBinary)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["WINEPREFIX"] = prefixPath
        environment["WINEDEBUG"] = "-all"
        environment["LANG"] = "C"
        environment["LC_ALL"] = "C"
        environment["MVK_CONFIG_LOG_LEVEL"] = "0"
        process.environment = environment
        process.standardOutput = outputHandle
        process.standardError = outputHandle

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw WineFontCompatibilityError.commandFailed(error.localizedDescription)
        }
        guard finished.wait(timeout: .now() + commandTimeout) == .success else {
            process.terminate()
            throw WineFontCompatibilityError.commandTimedOut
        }
        try? outputHandle.synchronize()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func recordURL(prefixPath: String) -> URL {
        URL(fileURLWithPath: prefixPath, isDirectory: true).appendingPathComponent(repairRecordName)
    }

    private static func loadRecord(prefixPath: String) throws -> WineFontRepairRecord {
        let data = try Data(contentsOf: recordURL(prefixPath: prefixPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(WineFontRepairRecord.self, from: data)
        guard record.version == WineFontRepairRecord.currentVersion else {
            throw WineFontCompatibilityError.recordReadFailed("不支持的记录版本 \(record.version)")
        }
        return record
    }

    private static func saveRecord(_ record: WineFontRepairRecord, prefixPath: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: recordURL(prefixPath: prefixPath), options: .atomic)
    }
}
