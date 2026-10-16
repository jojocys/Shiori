import Foundation
import CryptoKit

/// Offline icon mapping inherited by Windows children of a managed Wine launch.
/// Full executable paths avoid assigning a launcher's icon to an unrelated child.
enum WineDockIcons {
    struct Manifest: Codable {
        var icons: [String: String]
        var steamRoots: [String]
        var steamLockPath: String
        var steamIconPath: String?
    }

    static func normalized(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .precomposedStringWithCanonicalMapping.lowercased()
    }

    static func executableAliases(_ exe: URL, prefix: URL) -> [String] {
        let paths = Set([exe.standardizedFileURL.path, exe.resolvingSymlinksInPath().path])
        let driveC = prefix.appendingPathComponent("drive_c")
        let drivePaths = Set([driveC.standardizedFileURL.path + "/", driveC.resolvingSymlinksInPath().path + "/"])
        var aliases: Set<String> = []
        for path in paths {
            aliases.insert(normalized(path))
            aliases.insert(normalized("Z:" + path))
            for drivePath in drivePaths where path.hasPrefix(drivePath) {
                aliases.insert(normalized("C:/" + path.dropFirst(drivePath.count)))
            }
        }
        return aliases.sorted()
    }

    static func environment(_ original: [String: String], library: URL?, manifest: URL?) -> [String: String] {
        guard let library, let manifest,
              FileManager.default.fileExists(atPath: library.path),
              FileManager.default.fileExists(atPath: manifest.path) else { return original }
        var env = original
        var libraries = (env["DYLD_INSERT_LIBRARIES"] ?? "").split(separator: ":").map(String.init)
        if !libraries.contains(library.path) { libraries.append(library.path) }
        env["DYLD_INSERT_LIBRARIES"] = libraries.joined(separator: ":")
        env["SHIORI_WINE_DOCK_ICONS"] = manifest.path
        return env
    }

    static var adapter: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("libShioriWineDock.dylib"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func prepare(prefix: URL, gameExecutables: [URL], cache: URL, steamDirectory: URL? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let prefixKey = SHA256.hash(data: Data(prefix.resolvingSymlinksInPath().path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let manifest = cache.appendingPathComponent(prefixKey + ".json")
        let previous = (try? Data(contentsOf: manifest)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        var icons = previous?.icons ?? [:]
        for exe in Set(gameExecutables.map { $0.standardizedFileURL }) {
            // Keep Steam and its shell processes on their own icons.
            let name = exe.lastPathComponent.lowercased()
            guard !["steam.exe", "steamwebhelper.exe", "gameoverlayui.exe"].contains(name) else { continue }
            let attributes = try? fm.attributesOfItem(atPath: exe.path)
            let stamp = "\(exe.path)|\(attributes?[.size] ?? 0)|\(attributes?[.modificationDate] ?? "")"
            let key = SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined()
            let icon = cache.appendingPathComponent(key + ".ico")
            if !fm.fileExists(atPath: icon.path) {
                guard let data = PEIconExtractor.icoData(fromEXEPath: exe.path) else { continue }
                try data.write(to: icon, options: .atomic)
            }
            for alias in executableAliases(exe, prefix: prefix) { icons[alias] = icon.path }
        }
        let roots = steamDirectory.map { executableAliases($0, prefix: prefix).map { $0 + "/" } } ?? previous?.steamRoots ?? []
        var steamIcon = previous?.steamIconPath
        if let steamDirectory {
            let steamEXE = ["steam.exe", "Steam.exe"].map { steamDirectory.appendingPathComponent($0) }
                .first { fm.fileExists(atPath: $0.path) }
            if let steamEXE, let data = PEIconExtractor.icoData(fromEXEPath: steamEXE.path) {
                let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let icon = cache.appendingPathComponent("steam-" + key + ".ico")
                if !fm.fileExists(atPath: icon.path) { try data.write(to: icon, options: .atomic) }
                steamIcon = icon.path
            }
        }
        try JSONEncoder().encode(Manifest(icons: icons, steamRoots: roots,
            steamLockPath: cache.appendingPathComponent(prefixKey + ".steam.lock").path,
            steamIconPath: steamIcon))
            .write(to: manifest, options: .atomic)
        return manifest
    }

    static func executables(in installDirectories: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for directory in installDirectories {
            guard let walker = fm.enumerator(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let file as URL in walker {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { walker.skipDescendants(); continue }
                guard file.pathExtension.lowercased() == "exe", values?.isRegularFile == true else { continue }
                result.append(file)
            }
        }
        return result
    }
}
