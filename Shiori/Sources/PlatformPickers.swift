import AppKit
import Foundation
import UniformTypeIdentifiers

enum PlatformPickers {
    static func chooseGameFolder(startingAt path: String?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择游戏文件夹"
        panel.message = "请选择整个游戏目录（启动器会自动扫描并推荐主程序）"
        if let path, !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseExecutable(startingAt path: String?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.prompt = "选择 EXE"
        panel.message = "请选择 Windows 游戏主程序（.exe）"
        if let path, !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFolder(startingAt path: String?, prompt: String = "选择文件夹", message: String = "请选择文件夹") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        if let path, !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseWineBinary(startingAt path: String?) -> URL? {
        chooseFile(
            startingAt: path,
            prompt: "选择 Wine 可执行文件",
            message: "请选择 wine 或 wine64 可执行文件"
        )
    }

    static func chooseApp(startingAt path: String?, prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        if let appType = UTType(filenameExtension: "app") {
            panel.allowedContentTypes = [appType]
        }
        panel.canChooseDirectories = true
        if let path, !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFile(startingAt path: String?, prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        if let path, !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseImage(startingAt path: String?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "选择图标"
        panel.message = "请选择一张图片作为游戏图标（PNG / JPG / ICNS 等）"
        if let path, !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
