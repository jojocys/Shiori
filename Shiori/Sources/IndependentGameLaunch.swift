import CryptoKit
import Darwin
import Foundation

/// Display names and configuration IDs may change or duplicate. Runtime identity
/// is the actual executable in its Wine Prefix, including filesystem aliases.
struct IndependentGameIdentity: Hashable, Sendable {
    let executable: String
    let prefix: String

    init?(_ game: GameEntry) {
        guard game.platform == .windows, !game.exePath.isEmpty, !game.prefixDir.isEmpty else { return nil }
        executable = SteamLibraryPathSafety.canonical(URL(fileURLWithPath: game.exePath)).path
        prefix = SteamLibraryPathSafety.canonical(URL(fileURLWithPath: game.prefixDir)).path
    }

    static let environmentKey = "SHIORI_GAME_INSTANCE"
    var token: String {
        let value = "\(prefix.utf8.count):\(prefix)\(executable.utf8.count):\(executable)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct GameLaunchResult {
    let logURL: URL
    let process: Process
}

enum IndependentGameProbeError: LocalizedError {
    case unavailable
    var errorDescription: String? { "暂时无法确认应用是否已在运行，请稍后重试。" }
}

enum IndependentGameProcessProbe {
    /// The launch token is inherited by children, so a short-lived Wine loader
    /// exiting does not release the game. It also survives a Shiori restart.
    /// Read only the required environment value; never log process environments.
    static func isRunning(_ identity: IndependentGameIdentity) throws -> Bool {
        let snapshot = WineSteamProcessService.execute(executable: "/bin/ps",
            args: ["-U", String(getuid()), "-o", "pid="])
        guard snapshot.exitCode == 0, !snapshot.timedOut, !snapshot.outputTruncated else {
            throw IndependentGameProbeError.unavailable
        }
        let token = identity.token
        for line in snapshot.output.split(whereSeparator: \.isNewline) {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid > 0 else {
                throw IndependentGameProbeError.unavailable
            }
            if pid != getpid(), let data = arguments(of: pid),
               environmentValue(in: data, key: IndependentGameIdentity.environmentKey) == token,
               !isRuntimeService(in: data) {
                return true
            }
        }
        // Older launches have no token. Inspect their executable and Prefix
        // together; another game merely sharing the Prefix must not block this one.
        guard let existing = WineSteamProcessService.independentGamePIDsResult(
            executable: identity.executable, prefix: identity.prefix) else {
            throw IndependentGameProbeError.unavailable
        }
        return !existing.isEmpty
    }

    private static func arguments(of pid: Int32) -> Data? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size >= 4, size <= 2_097_152 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        return Data(bytes.prefix(size))
    }

    static func environmentValue(in data: Data, key: String) -> String? {
        decodedArguments(data)?.environment.first(where: { $0.hasPrefix(key + "=") })
            .map { String($0.dropFirst(key.utf8.count + 1)) }
    }

    static func isRuntimeService(in data: Data) -> Bool {
        guard let arguments = decodedArguments(data)?.arguments else { return false }
        let services: Set<String> = ["wineserver", "services.exe", "winedevice.exe", "wineboot.exe",
                                     "explorer.exe", "plugplay.exe", "svchost.exe", "rpcss.exe", "conhost.exe"]
        for argument in arguments {
            let path = argument.replacingOccurrences(of: "\\", with: "/").lowercased()
            if let end = path.range(of: ".exe")?.upperBound {
                let name = String(path[..<end]).split(separator: "/").last.map(String.init) ?? ""
                return services.contains(name.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            }
        }
        return arguments.first.map { services.contains(URL(fileURLWithPath: $0).lastPathComponent) } ?? false
    }

    private static func decodedArguments(_ data: Data) -> (arguments: [String], environment: [String])? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let argc = bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard argc > 0, argc <= 65_536 else { return nil }
        var offset = 4
        func skipString() -> Bool {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return false }
            offset = end + 1
            return true
        }
        guard skipString() else { return nil } // executable path
        while offset < bytes.count, bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            let start = offset
            guard skipString() else { return nil }
            arguments.append(String(decoding: bytes[start..<(offset - 1)], as: UTF8.self))
        }
        var environment: [String] = []
        while offset < bytes.count, bytes[offset] != 0 {
            let start = offset
            guard skipString() else { return nil }
            environment.append(String(decoding: bytes[start..<(offset - 1)], as: UTF8.self))
        }
        return (arguments, environment)
    }
}
