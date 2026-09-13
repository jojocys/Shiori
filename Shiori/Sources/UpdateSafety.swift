import AppKit
import Foundation

struct UpdateActivity: Equatable, Sendable {
    let pid: Int32
    let name: String
}

enum UpdateSafetyError: LocalizedError {
    case probeFailed(String)
    var errorDescription: String? {
        switch self {
        case .probeFailed(let reason): return "暂时无法确认游戏是否已退出，请稍后重试。\(reason)"
        }
    }
}

/// Only inspects this user's processes. No game process is signalled or terminated.
enum UpdateActivityProbe {
    private static func comparablePath(_ path: String) -> String {
        // Foundation may present /var while lsof reports the same vnode as /private/var.
        // These are macOS system aliases, not a general substring replacement.
        for alias in ["/var", "/tmp", "/etc"] {
            if path == "/private" + alias || path.hasPrefix("/private" + alias + "/") {
                return String(path.dropFirst("/private".count)).precomposedStringWithCanonicalMapping
            }
        }
        return path.precomposedStringWithCanonicalMapping
    }

    static func isInside(_ path: String, root: String) -> Bool {
        let path = comparablePath(path)
        let root = comparablePath(root)
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func parse(_ output: String, roots: [String], excluding ownPID: Int32) -> [UpdateActivity] {
        var pid: Int32?
        var name = "运行中的游戏"
        var matches: [Int32: UpdateActivity] = [:]
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p": pid = Int32(value); name = "运行中的游戏"
            case "c": name = value
            case "n":
                guard let pid, pid != ownPID else { continue }
                if roots.contains(where: { isInside(value, root: $0) }) {
                    matches[pid] = UpdateActivity(pid: pid, name: name)
                }
            default: break
            }
        }
        return matches.values.sorted { $0.pid < $1.pid }
    }

    static func scan(roots: [String], timeout: TimeInterval = 8) throws -> [UpdateActivity] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("processes")
        let errorURL = directory.appendingPathComponent("errors")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let scanner = Process()
        scanner.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        scanner.arguments = ["-nP", "-a", "-u", String(getuid()), "-Fpcn"]
        scanner.standardOutput = output
        scanner.standardError = errors
        try scanner.run()
        let deadline = Date().addingTimeInterval(timeout)
        while scanner.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if scanner.isRunning {
            // Only our bounded, read-only scanner is stopped on timeout.
            kill(scanner.processIdentifier, SIGKILL)
            scanner.waitUntilExit()
            throw UpdateSafetyError.probeFailed("进程检测超时。")
        }
        let diagnostics = try String(contentsOf: errorURL, encoding: .utf8)
        guard scanner.terminationStatus == 0, diagnostics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UpdateSafetyError.probeFailed("进程检测未完整完成。")
        }
        return parse(try String(contentsOf: outputURL, encoding: .utf8), roots: roots, excluding: getpid())
    }
}

/// Shared by updater and every launch entry. A pending installation also guards ordinary Quit.
@MainActor
final class UpdateInstallationGate: ObservableObject {
    static let shared = UpdateInstallationGate()
    @Published private(set) var installationPending = false
    @Published private(set) var isChecking = false
    var roots: () -> [String] = { [] }
    var saveBeforeExit: () throws -> Void = {}
    var probe: @Sendable ([String]) async throws -> [UpdateActivity] = { paths in
        try await Task.detached(priority: .userInitiated) { try UpdateActivityProbe.scan(roots: paths) }.value
    }
    var reportProblem: (String, String) -> Void = { title, message in UpdateInstallationGate.show(title, message) }

    var blocksLaunch: Bool { installationPending || isChecking }
    func arm() { installationPending = true }
    func disarm() { installationPending = false }

    func allowInstallation() async -> Bool {
        guard !isChecking else { return false }
        isChecking = true
        defer { isChecking = false }
        let paths = roots().filter { !$0.isEmpty }.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        }
        do {
            guard !paths.isEmpty else { throw UpdateSafetyError.probeFailed("更新配置尚未就绪。") }
            let activities = try await probe(paths)
            if !activities.isEmpty {
                reportProblem("更新已暂缓", "请先保存并退出相关游戏或 Wine Steam，再继续更新。\n" +
                    activities.map { "\($0.name)（PID \($0.pid)）" }.joined(separator: "\n"))
                return false
            }
            try saveBeforeExit()
            return true
        } catch {
            reportProblem("暂时无法安装更新", error.localizedDescription)
            return false
        }
    }

    static func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

@MainActor
final class ShioriApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let gate = UpdateInstallationGate.shared
        guard gate.installationPending else { return .terminateNow }
        Task {
            let permitted = await gate.allowInstallation()
            sender.reply(toApplicationShouldTerminate: permitted)
        }
        return .terminateLater
    }
}
