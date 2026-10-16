import Foundation

/// Canonical library authorization and a complete preflight before mutation.
/// Roots are approved separately from untrusted manifest/game path fields.
struct SteamLibraryPathSafety: Sendable {
    let steamappsURL: URL
    private let protectedRoots: [URL]

    static func canonical(_ url: URL) -> URL {
        // Foundation can leave intermediate links unresolved when the leaf does
        // not exist yet. Walk components so prospective write targets get the
        // same canonical parent as existing files.
        var pending = url.path.split(separator: "/").map(String.init)
        var resolved: [String] = []
        var followedLinks = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." { continue }
            if component == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
            let candidate = "/" + (resolved + [component]).joined(separator: "/")
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                followedLinks += 1
                guard followedLinks <= 40 else {
                    return URL(fileURLWithPath: candidate + "/.__shiori_unresolvable_link__")
                }
                if destination.hasPrefix("/") { resolved.removeAll() }
                pending = destination.split(separator: "/").map(String.init) + pending
            } else {
                resolved.append(component)
            }
        }
        return URL(fileURLWithPath: "/" + resolved.joined(separator: "/"), isDirectory: url.hasDirectoryPath)
    }

    private static func lexical(_ url: URL) -> URL {
        var components: [String] = []
        for component in url.path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(String(component))
        }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: url.hasDirectoryPath)
    }

    static func contains(_ child: URL, in parent: URL) -> Bool {
        let path = lexical(child).path
        let root = lexical(parent).path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    init(steamappsURL: URL, protectedRoots: [URL], allowedRoots: [URL]) throws {
        self.steamappsURL = Self.canonical(steamappsURL)
        self.protectedRoots = protectedRoots.map(Self.canonical)
        guard allowedRoots.contains(where: { Self.canonical($0).path == self.steamappsURL.path }) else {
            throw Self.error("该路径不是获准管理的 Wine Steam 库：\(steamappsURL.path)")
        }
        try rejectProtected(self.steamappsURL)
    }

    func validateComponent(_ value: String, label: String, allowEmpty: Bool = false, numeric: Bool = false) throws {
        guard (allowEmpty && value.isEmpty) || (!value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
            && (!numeric || value.allSatisfy({ $0.isASCII && $0.isNumber }))) else {
            throw Self.error("无效的 \(label)，已拒绝文件操作。")
        }
    }

    func validate(_ target: URL, siblingDepotCache: Bool = false) throws {
        let normalized = Self.lexical(target)
        let resolved = Self.canonical(target)
        let boundary = siblingDepotCache
            ? steamappsURL.deletingLastPathComponent().appendingPathComponent("depotcache")
            : steamappsURL
        guard Self.contains(normalized, in: boundary), Self.contains(resolved, in: boundary),
              normalized.path == resolved.path else {
            throw Self.error("路径或符号链接越出获准目标，已拒绝文件操作：\(target.path)")
        }
        try rejectProtected(resolved)
    }

    func validateRecordedPath(_ path: String, expected: URL) throws {
        guard Self.canonical(URL(fileURLWithPath: path)).path == Self.canonical(expected).path else {
            throw Self.error("游戏记录中的路径与库内目标不一致，已拒绝文件操作：\(path)")
        }
        // Validate the recorded spelling as well, so a link alias cannot hide an
        // unexpected intermediate directory even when the destination agrees.
        try validate(expected)
    }

    private func rejectProtected(_ target: URL) throws {
        guard !protectedRoots.contains(where: {
            Self.contains(target, in: $0) || Self.contains($0, in: target)
        }) else {
            throw Self.error("该路径涉及 Mac Steam 原生库，已拒绝文件操作：\(target.path)")
        }
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "ShioriSteamPathSafety", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
