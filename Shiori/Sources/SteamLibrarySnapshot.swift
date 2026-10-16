import Foundation

struct SteamLibraryScanInput: Hashable, Sendable {
    var home: URL
    var appDataDirectory: URL
    /// Already validated Steam installations; this scan never discovers extra
    /// prefixes from process state or from another selected game.
    var contexts: [WineSteamEntryContext]
}

struct SteamLibraryBinding: Hashable, Sendable {
    var libraryURL: URL
    var context: WineSteamEntryContext
}

struct SteamLibrarySnapshot: Sendable {
    var macGames: [SteamLibraryGame]
    var wineGames: [SteamLibraryGame]
    var installStatuses: [String: SteamInstallStatus]
    var isRunning: Bool
    var libraries: [URL]
    var bindings: [SteamLibraryBinding]

    /// Invoke through BackgroundSnapshotLoader or Task.detached.
    static func load(_ input: SteamLibraryScanInput,
                     mainClientProbe: @Sendable (String) -> Set<Int32> = { WineSteamProcessService.mainClientPIDs(in: $0) }) -> SteamLibrarySnapshot {
        let nativeLibraries = SteamLibraryManager.macSteamappsURLs(home: input.home)
        let defaultLibrary = SteamLibraryManager.defaultWineSteamappsURL(appDataDir: input.appDataDirectory)
        var candidates = [defaultLibrary]
        var candidateBindings: [SteamLibraryBinding] = []
        for context in input.contexts {
            let root = SteamLibraryManager.wineSteamappsURL(for: context)
            let libraries = [root] + SteamLibraryManager.steamappsURLsFromLibraryFolders(
                steamappsURL: root, winePrefixURL: URL(fileURLWithPath: context.prefixPath))
            candidates.append(contentsOf: libraries)
            candidateBindings.append(contentsOf: libraries.map { SteamLibraryBinding(libraryURL: $0, context: context) })
        }
        // The uninstalled default Prefix can still contain a prefill and its
        // external-library configuration, but has no launch binding.
        candidates.append(contentsOf: SteamLibraryManager.steamappsURLsFromLibraryFolders(
            steamappsURL: defaultLibrary,
            winePrefixURL: input.appDataDirectory.appendingPathComponent("steam-prefix")))
        let libraries = SteamLibraryManager.excludingSteamappsURLs(candidates, under: nativeLibraries)
        let libraryPaths = Set(libraries.map(\.path))
        var seen = Set<String>()
        let bindings = candidateBindings.compactMap { binding -> SteamLibraryBinding? in
            let canonical = SteamLibraryPathSafety.canonical(binding.libraryURL)
            guard libraryPaths.contains(canonical.path), seen.insert(canonical.path).inserted else { return nil }
            return SteamLibraryBinding(libraryURL: canonical, context: binding.context)
        }
        return SteamLibrarySnapshot(
            macGames: SteamLibraryManager.scanMacGames(home: input.home),
            wineGames: SteamLibraryManager.scanWineGames(steamappsURLs: libraries),
            installStatuses: SteamLibraryManager.scanInstallStatuses(steamappsURLs: libraries),
            isRunning: input.contexts.contains { !mainClientProbe($0.prefixPath).isEmpty },
            libraries: libraries,
            bindings: bindings)
    }
}
