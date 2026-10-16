import XCTest
@testable import Shiori

final class GameIconStorageTests: XCTestCase {
    func testChoosingCurrentIconRetainsItsBytes() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let icon = root.appendingPathComponent("\(id.uuidString).png")
        try Data("current icon".utf8).write(to: icon)
        let result = try GameIconStorage.replace(from: icon, gameID: id, in: root)
        XCTAssertEqual(result.path, icon.path)
        XCTAssertEqual(try Data(contentsOf: icon), Data("current icon".utf8))
    }

    func testCopyFailurePreservesOldIconAndSuccessfulReplacementRetiresOldExtension() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let old = root.appendingPathComponent("\(id.uuidString).png")
        try Data("old".utf8).write(to: old)
        let source = root.appendingPathComponent("new.jpg")
        try Data("replacement".utf8).write(to: source)
        XCTAssertThrowsError(try GameIconStorage.replace(from: source, gameID: id, in: root,
                                                         fileManager: FailingCopyFileManager()))
        XCTAssertEqual(try Data(contentsOf: old), Data("old".utf8))
        let replacement = try GameIconStorage.replace(from: source, gameID: id, in: root)
        XCTAssertEqual(try Data(contentsOf: replacement), Data("replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("replacement".utf8))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Shiori-Icon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }
}

private final class FailingCopyFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws { throw CocoaError(.fileWriteOutOfSpace) }
}
