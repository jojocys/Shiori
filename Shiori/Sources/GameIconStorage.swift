import Darwin
import Foundation

enum GameIconStorage {
    /// Preserve the old icon until a verified replacement is ready, including
    /// when the selected source is the currently stored icon itself.
    static func replace(from source: URL, gameID: UUID, in directory: URL,
                        fileManager fm: FileManager = .default) throws -> URL {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let attributes = try fm.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("\(gameID.uuidString).\(ext)")
        if source.path == destination.resolvingSymlinksInPath().standardizedFileURL.path { return destination }
        let temporary = directory.appendingPathComponent(".icon-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: source, to: temporary)
        guard fm.contentsEqual(atPath: source.path, andPath: temporary.path) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Remove old extensions only after the replacement was committed.
        for old in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where old.deletingPathExtension().lastPathComponent == gameID.uuidString
            && old.lastPathComponent != destination.lastPathComponent {
            try? fm.removeItem(at: old)
        }
        return destination
    }
}
