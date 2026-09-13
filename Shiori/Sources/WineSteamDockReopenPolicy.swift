import Foundation

enum WineSteamDockReopenPolicy {
    static let activationDelayNanoseconds: UInt64 = 350_000_000
    static let requestCooldown: TimeInterval = 2

    static func shouldRequestReopen(
        activatedPID: Int32,
        steamClientPIDs: Set<Int32>,
        steamMainClientPIDs: Set<Int32>,
        visibleWindowOwnerPIDs: Set<Int32>,
        now: Date,
        lastRequestAt: Date?
    ) -> Bool {
        guard steamMainClientPIDs.isEmpty == false,
              steamClientPIDs.contains(activatedPID),
              steamClientPIDs.isDisjoint(with: visibleWindowOwnerPIDs) else {
            return false
        }

        if let lastRequestAt,
           now.timeIntervalSince(lastRequestAt) < requestCooldown {
            return false
        }

        return true
    }

    /// Wine 进程在 macOS `ps` 中以 Windows 命令行显示，路径含空格且通常没有引号。
    /// 取命令行中第一个 `.exe` 作为实际可执行文件，避免把 steamwebhelper
    /// 参数里的 `-steampath=...\\steam.exe` 误判成 Steam 主进程。
    static func isSteamMainClientCommandLine(_ commandLine: String) -> Bool {
        let lowercased = commandLine.lowercased()
        guard let executableEnd = lowercased.range(of: ".exe")?.upperBound else {
            return false
        }

        let executablePath = lowercased[..<executableEnd]
            .replacingOccurrences(of: "\\", with: "/")
        return executablePath.split(separator: "/").last == "steam.exe"
    }
}
