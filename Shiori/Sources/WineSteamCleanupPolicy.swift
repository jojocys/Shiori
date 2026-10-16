import Foundation

/// Only an actual Steam installation grants permission to stop a whole Prefix.
/// A selected standalone game's directory is never sufficient evidence.
enum WineSteamCleanupPolicy {
    static func contexts(_ candidates: [WineSteamEntryContext],
                         fileManager: FileManager = .default) -> [WineSteamEntryContext] {
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let prefix = URL(fileURLWithPath: candidate.prefixPath, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
            let executable = URL(fileURLWithPath: candidate.steamExePath)
                .resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard executable.lastPathComponent.lowercased() == "steam.exe",
                  fileManager.fileExists(atPath: executable.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  executable.path.hasPrefix(prefix.path + "/"),
                  seen.insert(prefix.path).inserted else { return nil }
            return WineSteamEntryContext(steamExePath: executable.path,
                                         prefixPath: prefix.path,
                                         sourceLabel: candidate.sourceLabel)
        }
    }
}
