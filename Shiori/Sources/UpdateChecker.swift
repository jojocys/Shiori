import Foundation

/// 应用品牌与版本信息（单一真相源）。
enum AppInfo {
    static let name = "栞 Shiori"
    static let subtitle = "exe · galgame · switch · lightweight games for macOS"

    /// 运行版本：优先取打包后 Info.plist 的 CFBundleShortVersionString，开发期回退常量。
    static var version: String {
        if let bundledVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !bundledVersion.isEmpty {
            return bundledVersion
        }

        // SwiftPM executables can occasionally be launched with a main bundle that does not
        // expose the surrounding app's Info.plist. Resolve it from the executable as a fallback
        // so the UI always reports the same version Sparkle sees in the installed app bundle.
        if let executableURL = Bundle.main.executableURL ?? CommandLine.arguments.first.map({ URL(fileURLWithPath: $0) }) {
            let infoPlistURL = executableURL
                .deletingLastPathComponent() // MacOS
                .deletingLastPathComponent() // Contents
                .appendingPathComponent("Info.plist")
            if let info = NSDictionary(contentsOf: infoPlistURL),
               let installedVersion = info["CFBundleShortVersionString"] as? String,
               !installedVersion.isEmpty {
                return installedVersion
            }
        }

        return "开发版"
    }

}
