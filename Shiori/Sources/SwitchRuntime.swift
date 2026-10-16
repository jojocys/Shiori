import Foundation
import Darwin

enum SwitchRuntimeImportError: LocalizedError {
    case invalidKeys
    case keysCopyMismatch
    case invalidFirmware
    case firmwareCopyMismatch
    case firmwareScanLimit

    var errorDescription: String? {
        switch self {
        case .invalidKeys: return "prod.keys 必须是可读取的非空文件。"
        case .keysCopyMismatch: return "prod.keys 复制校验失败，原有文件已保留。"
        case .invalidFirmware: return "固件目录中没有可导入的非空 .nca 文件或目录。"
        case .firmwareCopyMismatch: return "固件复制校验失败，原有固件已保留。"
        case .firmwareScanLimit: return "固件目录包含过多条目，请选择仅包含固件的文件夹。"
        }
    }
}

/// Switch 运行支撑：解析内置模拟器、把用户自备的 keys/固件铺进受管数据目录。
/// 注意：Shiori 只编排"用户自己合法获取的 keys/固件"，绝不打包/分发版权文件。
enum SwitchRuntime {
    /// 保留现成脚本的自定义参数；只有明确引用已丢失的静态模拟器路径时才回退。
    static func launchScriptHasMissingEmulator(_ script: URL) -> Bool {
        guard let text = try? String(contentsOf: script, encoding: .utf8),
              isSimpleLaunchScript(text) else { return false }
        var assignments: [String] = []
        for line in text.split(separator: "\n") {
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("EMULATOR=") {
                assignments.append(String(line.dropFirst("EMULATOR=".count)))
            } else if line.range(of: "\\bEMULATOR(?:\\+|\\[[^]]*\\])?=", options: .regularExpression) != nil {
                return false
            }
        }
        // Multiple assignments and shell expressions need the original shell.
        guard assignments.count == 1, let path = staticShellPath(assignments[0]) else { return false }
        // EMULATOR can name an App or an executable. Existing paths retain all
        // script-defined flags and setup, even when Shiori cannot inspect them.
        return !FileManager.default.fileExists(atPath: path)
    }

    /// This is a narrow recognizer, not a shell interpreter. In richer scripts a
    /// matching line may be here-doc text, an inactive branch, or a function body.
    private static func isSimpleLaunchScript(_ text: String) -> Bool {
        let uncertainWords = "if|then|elif|else|fi|for|select|while|until|do|done|case|esac|function|eval|source|unset|read|readonly|typeset|declare|let"
        let uncertainCommand = "(^|[\\s;|&])(?:\(uncertainWords))(?=$|[\\s;|&])"
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let shell = unquotedShellText(String(line)) else { return false }
            if shell.contains("<<") || shell.contains("&&") || shell.contains("||")
                || shell.rangeOfCharacter(from: CharacterSet(charactersIn: "(){};")) != nil
                || shell.range(of: uncertainCommand, options: .regularExpression) != nil
                || shell.trimmingCharacters(in: .whitespaces).range(of: "^\\.\\s", options: .regularExpression) != nil {
                return false
            }
        }
        return true
    }

    /// Preserve only unquoted syntax for the structural check. A quote or escape
    /// continuing onto the next line is deliberately outside the supported form.
    private static func unquotedShellText(_ line: String) -> String? {
        var result = ""
        var quote: Character?
        var escaped = false
        var previousWasWhitespace = true
        for character in line {
            if escaped {
                escaped = false
                result.append(" ")
                previousWasWhitespace = false
                continue
            }
            if character == "\\", quote != "'" {
                escaped = true
                result.append(" ")
                previousWasWhitespace = false
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                result.append(" ")
                previousWasWhitespace = false
                continue
            }
            if character == "#", previousWasWhitespace { break }
            if character == "\"" || character == "'" {
                quote = character
                result.append(" ")
            } else {
                result.append(character)
            }
            previousWasWhitespace = character.isWhitespace
        }
        guard quote == nil, !escaped else { return nil }
        return result
    }

    private static func staticShellPath(_ assignment: String) -> String? {
        guard assignment.first?.isWhitespace != true else { return nil }
        let text = assignment.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return nil }
        let path: String
        let tail: String
        if first == "\"" || first == "'" {
            let body = text.dropFirst()
            guard let closing = body.firstIndex(of: first) else { return nil }
            path = String(body[..<closing])
            tail = String(body[body.index(after: closing)...])
            // Escapes/interpolation/quoted concatenation are intentionally left
            // to the user's shell, rather than guessing and skipping its script.
            guard !path.contains("\\"), !path.contains("$"), !path.contains("`") else { return nil }
        } else {
            let token = text.prefix { !$0.isWhitespace }
            path = String(token)
            tail = String(text.dropFirst(token.count))
            let syntax = CharacterSet(charactersIn: "\\\"'$`;;&|<>(){}[]*?!#~")
            guard path.rangeOfCharacter(from: syntax) == nil else { return nil }
        }
        let remainder = tail.trimmingCharacters(in: .whitespaces)
        let comment = tail.first?.isWhitespace == true && remainder.hasPrefix("#")
        guard path.hasPrefix("/"), remainder.isEmpty || comment else { return nil }
        return path
    }

    /// 没有显式导入 keys/固件时复用既有 Ryujinx 数据，保留存档、mods 和设置。
    static func existingUserDataDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let root = home.appendingPathComponent("Library/Application Support/Ryujinx", isDirectory: true)
        let fm = FileManager.default
        let firmware = root.appendingPathComponent("bis/system/Contents/registered", isDirectory: true)
        guard fm.fileExists(atPath: root.appendingPathComponent("system/prod.keys").path),
              let contents = try? fm.contentsOfDirectory(at: firmware, includingPropertiesForKeys: nil),
              !contents.isEmpty else { return nil }
        return root
    }

    static func dataDirectory(managed: URL, keysPath: String, firmwarePath: String,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if keysPath.isEmpty, firmwarePath.isEmpty, let existing = existingUserDataDirectory(home: home) {
            return existing
        }
        return managed
    }

    /// 内置模拟器：打包进 App 的 Resources/EmbeddedEmulator/*.app（由 build 时提供，运行期只读取）。
    static func resolveBundledEmulator() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let dir = resources.appendingPathComponent("EmbeddedEmulator", isDirectory: true)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return items.first(where: { $0.pathExtension.lowercased() == "app" })
    }

    /// 取 .app 内的可执行文件（优先 Info.plist 的 CFBundleExecutable）。
    static func executable(in appURL: URL) -> URL? {
        let fm = FileManager.default
        let macos = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        if let plist = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
           let exe = plist["CFBundleExecutable"] as? String {
            let url = macos.appendingPathComponent(exe)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        if let items = try? fm.contentsOfDirectory(at: macos, includingPropertiesForKeys: nil) {
            return items.first(where: { fm.isExecutableFile(atPath: $0.path) })
        }
        return nil
    }

    /// 把用户自备的 keys/固件铺进受管数据目录（Ryujinx 系布局）。
    /// 导入失败阻止启动；不能先删除已可用的 keys。
    static func prepareDataDir(_ dataDir: URL, keysPath: String, firmwarePath: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)

        // 在目标目录暂存并校验，再通过同一文件系统的 rename 原子替换。
        if !keysPath.isEmpty {
            let systemDir = dataDir.appendingPathComponent("system", isDirectory: true)
            try fm.createDirectory(at: systemDir, withIntermediateDirectories: true)
            try importKeys(from: URL(fileURLWithPath: keysPath),
                           to: systemDir.appendingPathComponent("prod.keys"), fm: fm)
        }

        // 只替换固件 registered 子树，不复制/覆盖 bis 中的用户存档。
        // 空 bis 或此前失败的部分导入都可重试。
        if !firmwarePath.isEmpty {
            try importFirmware(from: URL(fileURLWithPath: firmwarePath),
                               to: dataDir.appendingPathComponent("bis/system/Contents/registered", isDirectory: true), fm: fm)
        }
    }

    private static func importKeys(from source: URL, to destination: URL, fm: FileManager) throws {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destination.standardizedFileURL
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw SwitchRuntimeImportError.invalidKeys
        }
        let resolvedDestination = destination.resolvingSymlinksInPath()
        if source.path == resolvedDestination.path || sameFile(source, resolvedDestination, fm: fm) { return }
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".prod.keys-import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: source, to: staged)
        guard fm.contentsEqual(atPath: source.path, andPath: staged.path) else {
            throw SwitchRuntimeImportError.keysCopyMismatch
        }
        try atomicRename(staged, to: destination)
    }

    private static func sameFile(_ first: URL, _ second: URL, fm: FileManager) -> Bool {
        guard let a = try? fm.attributesOfItem(atPath: first.path),
              let b = try? fm.attributesOfItem(atPath: second.path),
              let deviceA = a[.systemNumber] as? NSNumber, let deviceB = b[.systemNumber] as? NSNumber,
              let inodeA = a[.systemFileNumber] as? NSNumber, let inodeB = b[.systemFileNumber] as? NSNumber else { return false }
        return deviceA == deviceB && inodeA == inodeB
    }

    private static func atomicRename(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in Darwin.rename(sourcePath, destinationPath) }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private static func importFirmware(from source: URL, to destination: URL, fm: FileManager) throws {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let standard = source.appendingPathComponent("bis/system/Contents/registered", isDirectory: true)
        let input = fm.fileExists(atPath: standard.path) ? standard : source
        let ncas = try firmwareNCAs(in: input, fm: fm)
        guard !ncas.isEmpty, Set(ncas.map(\.lastPathComponent)).count == ncas.count else {
            throw SwitchRuntimeImportError.invalidFirmware
        }
        // Fully matching imported content needs no write. A partial tree does.
        if let existing = try? fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
           Set(existing.map(\.lastPathComponent)) == Set(ncas.map(\.lastPathComponent)),
           ncas.allSatisfy({ fm.contentsEqual(atPath: $0.path, andPath: destination.appendingPathComponent($0.lastPathComponent).path) }) {
            return
        }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appendingPathComponent(".shiori-firmware-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staged) }
        for nca in ncas {
            let copy = staged.appendingPathComponent(nca.lastPathComponent)
            try fm.copyItem(at: nca, to: copy)
            guard fm.contentsEqual(atPath: nca.path, andPath: copy.path) else {
                throw SwitchRuntimeImportError.firmwareCopyMismatch
            }
        }
        if fm.fileExists(atPath: destination.path) {
            // macOS exchanges nonempty directories atomically. On unsupported
            // filesystems fail safely instead of first removing the old tree.
            let result = staged.path.withCString { stagedPath in
                destination.path.withCString { destinationPath in
                    Darwin.renamex_np(stagedPath, destinationPath, UInt32(RENAME_SWAP))
                }
            }
            guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            // staged now names the old firmware, removed only after commit.
        } else {
            try atomicRename(staged, to: destination)
        }
    }

    private static func firmwareNCAs(in folder: URL, fm: FileManager) throws -> [URL] {
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw SwitchRuntimeImportError.invalidFirmware }
        var enumerationError: Error?
        guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                                     options: [.skipsHiddenFiles], errorHandler: { _, error in
                                         enumerationError = error
                                         return false
                                     }) else { throw SwitchRuntimeImportError.invalidFirmware }
        var found: [URL] = []
        var count = 0
        while let u = en.nextObject() as? URL {
            count += 1
            if count > 5000 { throw SwitchRuntimeImportError.firmwareScanLimit }
            guard u.pathExtension.lowercased() == "nca" else { continue }
            let values = try u.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw SwitchRuntimeImportError.invalidFirmware }
            if values.isDirectory == true {
                guard !(try fm.contentsOfDirectory(atPath: u.path)).isEmpty else { throw SwitchRuntimeImportError.invalidFirmware }
                en.skipDescendants()
            } else {
                guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw SwitchRuntimeImportError.invalidFirmware }
            }
            found.append(u)
        }
        if let error = enumerationError { throw error }
        return found
    }
}
