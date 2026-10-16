import Foundation

enum WineSteamDockReopenPolicy {
    static let showMainWindowURL = "steam://open/main"
    static let activationDelayNanoseconds: UInt64 = 350_000_000
    static let requestCooldown: TimeInterval = 2

    /// 顶部“启动/唤起”按钮共用这一策略：客户端已运行时必须显式发送
    /// `steam://open/main`，否则再次执行 Steam.exe 只会把请求交给后台实例，窗口仍不出现。
    static func clientEntryArguments(steamMainClientPIDs: Set<Int32>) -> [String] {
        steamMainClientPIDs.isEmpty ? [] : [showMainWindowURL]
    }

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
              !visibleWindowOwnerPIDs.contains(activatedPID) else {
            return false
        }

        // The single Dock entry may belong to Steam's backend. A visible
        // helper window can still be behind another app; ask Steam to bring
        // its frontend forward when the activated owner has no own window.

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
