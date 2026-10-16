import Foundation

enum SteamLibraryRouting {
    static func installURL(for game: SteamLibraryGame, matchingWineGame: SteamLibraryGame?,
                           status: SteamInstallStatus?) -> String {
        let hasManifest = matchingWineGame?.hasManifest == true || !(status?.manifestPath.isEmpty ?? true)
        return hasManifest ? "steam://validate/\(game.appID)" : "steam://install/\(game.appID)"
    }

    static func context(for game: SteamLibraryGame, bindings: [SteamLibraryBinding]) -> WineSteamEntryContext? {
        guard game.source == .wine, !game.steamappsPath.isEmpty else { return nil }
        let path = SteamLibraryPathSafety.canonical(URL(fileURLWithPath: game.steamappsPath)).path
        return bindings.first { SteamLibraryPathSafety.canonical($0.libraryURL).path == path }?.context
    }
}
