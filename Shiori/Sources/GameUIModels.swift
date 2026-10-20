import Foundation

struct GameNameChange: Equatable {
    let gameID: UUID
    let name: String
}

/// Keep spaces and temporarily empty input until the user commits the edit.
/// The ID binds the draft to its game even if the selection later changes.
struct GameNameDraft {
    private(set) var gameID: UUID?
    private var savedName = ""
    var text = ""

    init(game: GameEntry? = nil) { synchronize(with: game) }

    var pendingChange: GameNameChange? {
        guard let gameID, text != savedName else { return nil }
        return GameNameChange(gameID: gameID, name: text)
    }

    mutating func synchronize(with game: GameEntry?) {
        gameID = game?.id
        text = game?.name ?? ""
        savedName = text
    }
}

/// Cards and previews share one revision for the same artwork.
enum GameArtworkIdentity {
    /// Stable across display-name edits; a different file or manual icon must
    /// not inherit the previous configuration's image while loading.
    static func source(for game: GameEntry) -> String {
        let fields = [game.id.uuidString, game.iconPath, game.exePath, game.romPath,
                      game.launchScriptPath, game.gameFolderPath, game.platform.rawValue]
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }

    static func revision(for game: GameEntry) -> String {
        let fields = ["game", game.id.uuidString, game.iconPath, game.exePath,
                      game.romPath, game.launchScriptPath, game.gameFolderPath,
                      game.name, game.platform.rawValue,
                      String(game.updatedAt.timeIntervalSince1970)]
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }
}
