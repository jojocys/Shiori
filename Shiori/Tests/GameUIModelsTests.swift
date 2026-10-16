import XCTest
@testable import Shiori

final class GameNameDraftTests: XCTestCase {
    func testTypingKeepsSpacesUntilCommit() {
        let game = GameEntry(name: "")
        var draft = GameNameDraft(game: game)
        for character in "My Game" { draft.text.append(character) }
        XCTAssertEqual(draft.text, "My Game")
        XCTAssertEqual(draft.pendingChange, GameNameChange(gameID: game.id, name: "My Game"))
    }

    func testAnEmptyDraftDoesNotInsertAPlaceholderWhileEditing() {
        let game = GameEntry(name: "Original")
        var draft = GameNameDraft(game: game)
        draft.text = ""
        XCTAssertEqual(draft.text, "")
        XCTAssertEqual(draft.pendingChange, GameNameChange(gameID: game.id, name: ""))
    }

    func testPendingEditRetainsTheOriginalGameIdentity() {
        let first = GameEntry(name: "First")
        let second = GameEntry(name: "Second")
        var draft = GameNameDraft(game: first)
        draft.text = "Renamed First"
        let pending = draft.pendingChange
        draft.synchronize(with: second)
        XCTAssertEqual(pending?.gameID, first.id)
        XCTAssertEqual(pending?.name, "Renamed First")
        XCTAssertEqual(draft.gameID, second.id)
        XCTAssertEqual(draft.text, second.name)
        XCTAssertNil(draft.pendingChange)
    }

    func testSynchronizingTheSavedValueMakesTheDraftClean() {
        var game = GameEntry(name: "Original")
        var draft = GameNameDraft(game: game)
        draft.text = "Saved Name"
        game.name = "Saved Name"
        draft.synchronize(with: game)
        XCTAssertNil(draft.pendingChange)
    }
}

@MainActor
final class GameArtworkTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!

    func testArtworkRevisionChangesForReplacementAndRefetch() {
        var game = GameEntry(name: "Game", iconPath: "/icons/first.png")
        let original = GameArtworkIdentity.revision(for: game)
        game.iconPath = "/icons/second.png"
        let replaced = GameArtworkIdentity.revision(for: game)
        XCTAssertNotEqual(original, replaced)
        game.updatedAt = game.updatedAt.addingTimeInterval(1)
        XCTAssertNotEqual(replaced, GameArtworkIdentity.revision(for: game))
    }

    func testLaunchScriptChangesInvalidateTheArtworkIdentity() {
        var game = GameEntry(name: "Game", platform: .switchEmu, launchScriptPath: "/first.command")
        let original = GameArtworkIdentity.revision(for: game)
        game.launchScriptPath = "/second.command"
        XCTAssertNotEqual(original, GameArtworkIdentity.revision(for: game))
    }

    func testCardAndPreviewReuseTheSameDecodedRevision() async {
        let game = GameEntry(name: "Cached Cover")
        let revision = GameArtworkIdentity.revision(for: game)
        let card = await GameArtworkLoader.load(revision: revision) { self.png }
        XCTAssertNotNil(card.image)
        var requestedData = false
        let preview = await GameArtworkLoader.load(revision: revision) {
            requestedData = true
            return nil
        }
        XCTAssertFalse(requestedData)
        XCTAssertTrue(card.image === preview.image)
    }

    func testAChangedRevisionCannotReturnThePreviousPreview() async {
        var game = GameEntry(name: "Changed Cover", iconPath: "/old.png")
        let old = await GameArtworkLoader.load(revision: GameArtworkIdentity.revision(for: game)) { self.png }
        XCTAssertNotNil(old.image)
        game.iconPath = "/new.png"
        let replacement = await GameArtworkLoader.load(revision: GameArtworkIdentity.revision(for: game)) { nil }
        guard case .unavailable = replacement else {
            return XCTFail("The new revision must not reuse the old cover")
        }
    }

    func testMissingAndInvalidImageDataCompleteWithoutALoadingResult() async {
        let missing = await GameArtworkLoader.load(revision: UUID().uuidString) { nil }
        let invalid = await GameArtworkLoader.load(revision: UUID().uuidString) { Data("invalid image".utf8) }
        guard case .unavailable = missing, case .unavailable = invalid else {
            return XCTFail("Missing and invalid artwork must finish as unavailable")
        }
    }
}
