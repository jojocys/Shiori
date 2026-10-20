import Darwin
import Foundation

/// Blocking OS probes and planned termination. Call from a detached task;
/// nothing here reads the selected game or discovers additional prefixes.
enum WineSteamProcessService {
    struct CommandResult: Sendable {
        var output: String
        var exitCode: Int32
        var timedOut: Bool
        var outputTruncated: Bool
    }

    struct StopResult: Sendable {
        var commandHits: Int
        var signaledPIDs: Set<Int32>
        var remainingPIDs: Set<Int32>
        var probeFailed: Bool
        var totalHits: Int { commandHits + signaledPIDs.count }
        var didStop: Bool { !probeFailed && remainingPIDs.isEmpty }
    }

    /// Injectable effects let tests prove that a stop plan cannot expand its
    /// prefix/PID scope without ever sending a signal to a real Wine process.
    struct StopOperations: Sendable {
        var winePIDs: @Sendable (String) -> Set<Int32>?
        var wineserver: @Sendable (String) -> String?
        var command: @Sendable (String, [String], [String: String]?) -> Int32
        var signal: @Sendable (Set<Int32>, Int32) -> Int
        var pause: @Sendable (TimeInterval) -> Void

        static let live = StopOperations(
            winePIDs: { WineSteamProcessService.processIDsResult(matching: "wine|\\.exe", openingFilesUnder: $0) },
            wineserver: { binary in
                guard !binary.isEmpty else { return nil }
                let candidate = URL(fileURLWithPath: binary).deletingLastPathComponent().appendingPathComponent("wineserver")
                return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate.path : nil
            },
            command: { WineSteamProcessService.runCommand(executable: $0, args: $1, env: $2) },
            signal: { pids, signal in
                pids.filter { $0 > 0 && $0 != ProcessInfo.processInfo.processIdentifier && Darwin.kill($0, signal) == 0 }.count
            },
            pause: { Thread.sleep(forTimeInterval: $0) })
    }

    /// Drain stdout using a nonblocking descriptor, checking a monotonic
    /// deadline even while output is continuous. Neither a full pipe nor a
    /// descendant retaining stdout can prevent return.
    static func execute(executable: String, args: [String] = [], env: [String: String]? = nil,
                        timeout: TimeInterval = 3, maxOutputBytes: Int = 1_048_576) -> CommandResult {
        let process = Process()
        let output = Pipe()
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return CommandResult(output: "", exitCode: -1, timedOut: false, outputTruncated: false)
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        if let env {
            process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        }
        do { try process.run() } catch {
            return CommandResult(output: "", exitCode: -1, timedOut: false, outputTruncated: false)
        }
        try? output.fileHandleForWriting.close()
        defer { try? output.fileHandleForReading.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + min(max(timeout, 0.01), 60)
        let limit = min(max(maxOutputBytes, 0), 8_388_608)
        var captured = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var truncated = false
        var timedOut = false
        var terminatedAt: TimeInterval?
        var killed = false
        while true {
            // Limit each draining pass so a flood of output cannot postpone
            // checking the timeout indefinitely.
            var drained = 0
            while drained < 262_144 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    drained += count
                    let kept = min(count, limit - captured.count)
                    if kept > 0 { captured.append(contentsOf: buffer.prefix(kept)) }
                    if kept < count { truncated = true }
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            if !process.isRunning { break }
            let now = ProcessInfo.processInfo.systemUptime
            if let terminatedAt {
                if now - terminatedAt >= 0.1, !killed {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    killed = true
                }
                if now - terminatedAt >= 0.5 { break }
            } else if now >= deadline {
                timedOut = true
                terminatedAt = now
                process.terminate()
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return CommandResult(output: String(decoding: captured, as: UTF8.self),
                             exitCode: timedOut ? -2 : (process.isRunning ? -1 : process.terminationStatus),
                             timedOut: timedOut, outputTruncated: truncated)
    }

    static func commandOutput(executable: String, args: [String] = [], env: [String: String]? = nil,
                              timeout: TimeInterval = 3, maxOutputBytes: Int = 1_048_576) -> String {
        let result = execute(executable: executable, args: args, env: env, timeout: timeout, maxOutputBytes: maxOutputBytes)
        return result.timedOut || result.outputTruncated || result.exitCode != 0 ? "" : result.output
    }

    static func runCommand(executable: String, args: [String] = [], env: [String: String]? = nil,
                           timeout: TimeInterval = 3) -> Int32 {
        execute(executable: executable, args: args, env: env, timeout: timeout, maxOutputBytes: 0).exitCode
    }

    static func mainClientPIDs(in prefix: String) -> Set<Int32> {
        mainClientPIDsResult(in: prefix) ?? []
    }

    private static func mainClientPIDsResult(in prefix: String) -> Set<Int32>? {
        guard let candidates = processIDsResult(matching: "steam\\.exe", openingFilesUnder: prefix),
              let commands = commandLinesResult(for: candidates) else { return nil }
        return Set(candidates.filter { WineSteamDockReopenPolicy.isSteamMainClientCommandLine(commands[$0] ?? "") })
    }

    static func clientPIDs(in prefix: String) -> Set<Int32> {
        let candidates = processIDs(matching: "steam\\.exe|steamwebhelper\\.exe|steamservice\\.exe|gameoverlayui\\.exe",
                                    openingFilesUnder: prefix)
        let names: Set<String> = ["steam.exe", "steamwebhelper.exe", "steamservice.exe", "gameoverlayui.exe"]
        let commands = commandLines(for: candidates)
        return Set(candidates.filter { names.contains(executableName(commands[$0] ?? "")) })
    }

    static func winePIDs(in prefix: String) -> Set<Int32> {
        processIDs(matching: "wine|\\.exe", openingFilesUnder: prefix)
    }

    static func shellPIDs(in prefix: String) -> Set<Int32> {
        processIDs(matching: "wineserver|winedevice|wineboot\\.exe|services\\.exe|plugplay\\.exe|svchost\\.exe|explorer\\.exe|rpcss\\.exe",
                   openingFilesUnder: prefix)
    }

    static func gamePIDs(_ game: SteamLibraryGame, in context: WineSteamEntryContext) -> Set<Int32> {
        guard !game.installPath.isEmpty, FileManager.default.fileExists(atPath: game.installPath) else { return [] }
        return processIDs(matching: "wine|\\.exe", openingFilesUnder: game.installPath)
            .subtracting(clientPIDs(in: context.prefixPath))
    }

    static func independentGamePIDsResult(executable: String, prefix: String) -> Set<Int32>? {
        guard FileManager.default.fileExists(atPath: prefix),
              FileManager.default.fileExists(atPath: executable) else { return [] }
        guard let candidates = processIDsResult(matching: "wine|\\.exe", openingFilesUnder: prefix) else { return nil }
        guard !candidates.isEmpty else { return [] }
        let result = execute(executable: "/usr/sbin/lsof",
            args: ["-nP", "-Fpn", "-p", candidates.sorted().map(String.init).joined(separator: ",")])
        guard result.exitCode == 0, !result.timedOut, !result.outputTruncated else { return nil }
        return processIDs(openFilesOutput: result.output, candidates: candidates, prefix: executable)
    }

    static func clearStaleShell(in prefix: String) -> Int {
        guard let clients = mainClientPIDsResult(in: prefix), clients.isEmpty,
              let planned = processIDsResult(matching: "wineserver|winedevice|wineboot\\.exe|services\\.exe|plugplay\\.exe|svchost\\.exe|explorer\\.exe|rpcss\\.exe", openingFilesUnder: prefix),
              !planned.isEmpty else { return 0 }
        let termHits = StopOperations.live.signal(planned, SIGTERM)
        Thread.sleep(forTimeInterval: 0.2)
        guard let current = processIDsResult(matching: "wineserver|winedevice|wineboot\\.exe|services\\.exe|plugplay\\.exe|svchost\\.exe|explorer\\.exe|rpcss\\.exe", openingFilesUnder: prefix) else { return termHits }
        let remaining = current.intersection(planned)
        return termHits + StopOperations.live.signal(remaining, SIGKILL)
    }

    static func stop(contexts: [WineSteamEntryContext], wineBinary: String,
                     operations: StopOperations = .live) -> StopResult {
        var seen = Set<String>()
        var invalidContext = false
        let prefixes = contexts.compactMap { context -> String? in
            guard !context.prefixPath.isEmpty else { invalidContext = true; return nil }
            let prefix = SteamLibraryPathSafety.canonical(URL(fileURLWithPath: context.prefixPath)).path
            guard prefix != "/" else { invalidContext = true; return nil }
            guard seen.insert(prefix).inserted else { return nil }
            return prefix
        }
        guard !invalidContext else {
            return StopResult(commandHits: 0, signaledPIDs: [], remainingPIDs: [], probeFailed: true)
        }
        func probe() -> Set<Int32>? {
            var pids = Set<Int32>()
            for prefix in prefixes {
                guard let found = operations.winePIDs(prefix) else { return nil }
                pids.formUnion(found)
            }
            return pids.filter { $0 > 0 && $0 != ProcessInfo.processInfo.processIdentifier }
        }
        guard let planned = probe() else {
            return StopResult(commandHits: 0, signaledPIDs: [], remainingPIDs: [], probeFailed: true)
        }
        var probeFailed = false
        var commandHits = 0
        if !prefixes.isEmpty, let wineserver = operations.wineserver(wineBinary) {
            for prefix in prefixes where operations.command(wineserver, ["-k"], ["WINEPREFIX": prefix]) == 0 {
                commandHits += 1
            }
        }
        var signaled = Set<Int32>()
        if !planned.isEmpty {
            _ = operations.signal(planned, SIGTERM)
            signaled.formUnion(planned)
            operations.pause(0.5)
            if let remaining = probe()?.intersection(planned) {
                _ = operations.signal(remaining, SIGKILL)
                signaled.formUnion(remaining)
            } else { probeFailed = true }
            operations.pause(0.2)
        }
        let finalRemaining = probe()
        return StopResult(commandHits: commandHits, signaledPIDs: signaled,
                          remainingPIDs: finalRemaining ?? planned, probeFailed: probeFailed || finalRemaining == nil)
    }

    private static func processIDs(matching pattern: String, openingFilesUnder rawPrefix: String) -> Set<Int32> {
        processIDsResult(matching: pattern, openingFilesUnder: rawPrefix) ?? []
    }

    private static func processIDsResult(matching pattern: String, openingFilesUnder rawPrefix: String) -> Set<Int32>? {
        guard !rawPrefix.isEmpty else { return nil }
        let prefix = SteamLibraryPathSafety.canonical(URL(fileURLWithPath: rawPrefix)).path
        guard prefix != "/" else { return nil }
        let matches = execute(executable: "/usr/bin/pgrep", args: ["-if", pattern])
        guard !matches.timedOut, !matches.outputTruncated else { return nil }
        if matches.exitCode == 1, matches.output.isEmpty { return [] }
        guard matches.exitCode == 0, let parsed = parsedPIDList(matches.output) else { return nil }
        let candidates = parsed.filter { $0 > 0 && $0 != ProcessInfo.processInfo.processIdentifier }
        guard !candidates.isEmpty else { return [] }
        let output = execute(executable: "/usr/sbin/lsof", args: ["-nP", "-Fpn", "-p", candidates.sorted().map(String.init).joined(separator: ",")])
        guard !output.timedOut, !output.outputTruncated else { return nil }
        if output.exitCode != 0 {
            guard output.exitCode == 1 else { return nil }
            // An empty/partial lsof failure does not prove that no Wine process
            // opens this Prefix. Accept it only if ps confirms all candidates
            // disappeared; a surviving unreadable process blocks deletion.
            let alive = execute(executable: "/bin/ps", args: ["-p", candidates.sorted().map(String.init).joined(separator: ","), "-o", "pid="])
            guard !alive.timedOut, !alive.outputTruncated,
                  alive.exitCode == 0 || (alive.exitCode == 1 && alive.output.isEmpty),
                  let existing = parsedPIDList(alive.output), existing.isEmpty else { return nil }
            return []
        }
        return processIDs(openFilesOutput: output.output, candidates: candidates, prefix: prefix)
    }

    static func processIDs(openFilesOutput: String, candidates: Set<Int32>, prefix: String) -> Set<Int32> {
        let root = SteamLibraryPathSafety.canonical(URL(fileURLWithPath: prefix))
        var owner: Int32?
        var found = Set<Int32>()
        for line in openFilesOutput.split(whereSeparator: \.isNewline) {
            if line.first == "p" {
                owner = Int32(line.dropFirst())
            } else if line.first == "n", let owner, candidates.contains(owner),
                      line.dropFirst().hasPrefix("/") {
                let file = SteamLibraryPathSafety.canonical(URL(fileURLWithPath: String(line.dropFirst())))
                if SteamLibraryPathSafety.contains(file, in: root) { found.insert(owner) }
            }
        }
        return found
    }

    private static func commandLines(for pids: Set<Int32>) -> [Int32: String] {
        commandLinesResult(for: pids) ?? [:]
    }

    private static func commandLinesResult(for pids: Set<Int32>) -> [Int32: String]? {
        guard !pids.isEmpty else { return [:] }
        let result = execute(executable: "/bin/ps", args: ["-p", pids.sorted().map(String.init).joined(separator: ","), "-o", "pid=", "-o", "args="])
        guard !result.timedOut, !result.outputTruncated else { return nil }
        if result.exitCode == 1, result.output.isEmpty { return [:] }
        guard result.exitCode == 0 else { return nil }
        var commands: [Int32: String] = [:]
        for line in result.output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let pid = Int32(fields[0]), pids.contains(pid) else { return nil }
            commands[pid] = String(fields[1]).trimmingCharacters(in: .whitespaces)
        }
        return commands
    }

    private static func parsedPIDList(_ output: String) -> Set<Int32>? {
        var pids = Set<Int32>()
        for line in output.split(whereSeparator: \.isNewline) {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid > 0 else { return nil }
            pids.insert(pid)
        }
        return pids
    }

    private static func executableName(_ command: String) -> String {
        let path = command.lowercased().replacingOccurrences(of: "\\", with: "/")
        guard let end = path.range(of: ".exe")?.upperBound else { return "" }
        return String(path[..<end]).split(separator: "/").last.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) ?? ""
    }
}
