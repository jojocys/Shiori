import XCTest
@testable import Shiori

final class SwitchRuntimeTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMissingStaticEmulatorTriggersFallback() throws {
        let root = try temporaryDirectory()
        let script = root.appendingPathComponent("launch.command")
        try "EMULATOR=\"\(root.path)/missing.app\"\nopen -n \"$EMULATOR\"".write(to: script, atomically: true, encoding: .utf8)
        XCTAssertTrue(SwitchRuntime.launchScriptHasMissingEmulator(script))
    }

    func testValidEmulatorAndDynamicScriptsStayWithUserScript() throws {
        let root = try temporaryDirectory()
        let emulator = root.appendingPathComponent("Custom.app/Contents/MacOS/Custom")
        try FileManager.default.createDirectory(at: emulator.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: emulator, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: emulator.path)
        let script = root.appendingPathComponent("launch.command")
        for content in ["EMULATOR=\"\(root.path)/Custom.app\"", "EMULATOR=\"$HOME/Custom.app\"", "open -n Custom.app"] {
            try content.write(to: script, atomically: true, encoding: .utf8)
            XCTAssertFalse(SwitchRuntime.launchScriptHasMissingEmulator(script))
        }
    }

    func testReuseExistingDataOnlyWithoutExplicitImportsAndWithRequiredFiles() throws {
        let home = try temporaryDirectory()
        let managed = home.appendingPathComponent("managed")
        let existing = home.appendingPathComponent("Library/Application Support/Ryujinx", isDirectory: true)
        let firmware = existing.appendingPathComponent("bis/system/Contents/registered")
        try FileManager.default.createDirectory(at: firmware, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: existing.appendingPathComponent("system"), withIntermediateDirectories: true)
        XCTAssertEqual(SwitchRuntime.dataDirectory(managed: managed, keysPath: "", firmwarePath: "", home: home), managed)
        try Data("test fixture".utf8).write(to: existing.appendingPathComponent("system/prod.keys"))
        XCTAssertNil(SwitchRuntime.existingUserDataDirectory(home: home))
        try Data("test fixture".utf8).write(to: firmware.appendingPathComponent("test.nca"))
        XCTAssertEqual(SwitchRuntime.dataDirectory(managed: managed, keysPath: "", firmwarePath: "", home: home), existing)
        XCTAssertEqual(SwitchRuntime.dataDirectory(managed: managed, keysPath: "/custom/prod.keys", firmwarePath: "", home: home), managed)
        XCTAssertEqual(SwitchRuntime.dataDirectory(managed: managed, keysPath: "", firmwarePath: "/custom/firmware", home: home), managed)
    }

    func testKeysImportKeepsSameFileAndItsAliases() throws {
        let root = try temporaryDirectory()
        let system = root.appendingPathComponent("system", isDirectory: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        let key = system.appendingPathComponent("prod.keys")
        let bytes = Data("original keys fixture".utf8)
        try bytes.write(to: key)
        let symbolic = root.appendingPathComponent("symbolic.keys")
        let hard = root.appendingPathComponent("hard.keys")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: key)
        try FileManager.default.linkItem(at: key, to: hard)
        for source in [key, symbolic, hard, system.appendingPathComponent("../system/prod.keys")] {
            try SwitchRuntime.prepareDataDir(root, keysPath: source.path, firmwarePath: "")
            XCTAssertEqual(try Data(contentsOf: key), bytes)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    func testKeysImportReplacesOnlyAfterCopyAndPreservesOriginalOnFailure() throws {
        let root = try temporaryDirectory()
        let data = root.appendingPathComponent("managed", isDirectory: true)
        let key = data.appendingPathComponent("system/prod.keys")
        try FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old keys".utf8).write(to: key)
        let source = root.appendingPathComponent("new.keys")
        let updated = Data("new keys".utf8)
        try updated.write(to: source)
        try SwitchRuntime.prepareDataDir(data, keysPath: source.path, firmwarePath: "")
        XCTAssertEqual(try Data(contentsOf: key), updated)
        XCTAssertEqual(try Data(contentsOf: source), updated)
        for invalid in [root.appendingPathComponent("missing.keys"), root] {
            XCTAssertThrowsError(try SwitchRuntime.prepareDataDir(data, keysPath: invalid.path, firmwarePath: ""))
            XCTAssertEqual(try Data(contentsOf: key), updated)
        }
        try Data().write(to: source)
        XCTAssertThrowsError(try SwitchRuntime.prepareDataDir(data, keysPath: source.path, firmwarePath: ""))
        XCTAssertEqual(try Data(contentsOf: key), updated)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: key.deletingLastPathComponent().path), ["prod.keys"])
    }

    func testKeysReplacementDoesNotOverwriteExternalSymbolicLinkTarget() throws {
        let root = try temporaryDirectory()
        let data = root.appendingPathComponent("managed", isDirectory: true)
        let key = data.appendingPathComponent("system/prod.keys")
        try FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true)
        let external = root.appendingPathComponent("external.keys")
        let original = Data("protected external keys".utf8)
        try original.write(to: external)
        try FileManager.default.createSymbolicLink(at: key, withDestinationURL: external)
        let source = root.appendingPathComponent("replacement.keys")
        let replacement = Data("replacement keys".utf8)
        try replacement.write(to: source)
        try SwitchRuntime.prepareDataDir(data, keysPath: source.path, firmwarePath: "")
        XCTAssertEqual(try Data(contentsOf: key), replacement)
        XCTAssertEqual(try Data(contentsOf: external), original)
        XCTAssertEqual(try key.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, false)
    }

    func testFirmwareImportRepairsEmptyAndPartialBisAndPreservesUserData() throws {
        let root = try temporaryDirectory()
        let data = root.appendingPathComponent("managed", isDirectory: true)
        let protectedPaths = ["bis/user/save/slot.dat", "mods/custom.ini", "Config.json"]
        let protectedBytes = Data("protected user fixture".utf8)
        for path in protectedPaths {
            try write(protectedBytes, to: data.appendingPathComponent(path))
        }
        let source = root.appendingPathComponent("firmware", isDirectory: true)
        let bytes = Data("complete firmware fixture".utf8)
        try write(bytes, to: source.appendingPathComponent("new.nca"))
        let registered = data.appendingPathComponent("bis/system/Contents/registered", isDirectory: true)
        try SwitchRuntime.prepareDataDir(data, keysPath: "", firmwarePath: source.path)
        XCTAssertEqual(try Data(contentsOf: registered.appendingPathComponent("new.nca")), bytes)
        // Simulate a prior interrupted/partial copy. Repeating the import repairs it.
        try write(Data("partial".utf8), to: registered.appendingPathComponent("new.nca"))
        try write(Data("stale".utf8), to: registered.appendingPathComponent("stale.nca"))
        try SwitchRuntime.prepareDataDir(data, keysPath: "", firmwarePath: source.path)
        XCTAssertEqual(try Data(contentsOf: registered.appendingPathComponent("new.nca")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: registered.appendingPathComponent("stale.nca").path))
        for path in protectedPaths {
            XCTAssertEqual(try Data(contentsOf: data.appendingPathComponent(path)), protectedBytes)
        }
        let before = try registered.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try SwitchRuntime.prepareDataDir(data, keysPath: "", firmwarePath: source.path)
        XCTAssertEqual(try registered.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: registered.deletingLastPathComponent().path), ["registered"])
    }

    func testStandardBisFirmwareSourceDoesNotImportItsSavesOrMods() throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        let data = root.appendingPathComponent("managed", isDirectory: true)
        let bytes = Data("nca directory content".utf8)
        try write(bytes, to: source.appendingPathComponent("bis/system/Contents/registered/firmware.nca/00"))
        try write(Data("source user save".utf8), to: source.appendingPathComponent("bis/user/save/imported.dat"))
        try write(Data("source mod".utf8), to: source.appendingPathComponent("mods/source.ini"))
        let retained = data.appendingPathComponent("bis/user/save/original.dat")
        let original = Data("original user save".utf8)
        try write(original, to: retained)
        try SwitchRuntime.prepareDataDir(data, keysPath: "", firmwarePath: source.path)
        XCTAssertEqual(try Data(contentsOf: data.appendingPathComponent("bis/system/Contents/registered/firmware.nca/00")), bytes)
        XCTAssertEqual(try Data(contentsOf: retained), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("bis/user/save/imported.dat").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("mods/source.ini").path))
    }

    func testInvalidFirmwareLeavesExistingTreeAndRetryWorks() throws {
        let root = try temporaryDirectory()
        let data = root.appendingPathComponent("managed", isDirectory: true)
        let registered = data.appendingPathComponent("bis/system/Contents/registered", isDirectory: true)
        let previous = registered.appendingPathComponent("previous.nca")
        let bytes = Data("previous working firmware".utf8)
        try write(bytes, to: previous)
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let zero = root.appendingPathComponent("zero", isDirectory: true)
        try write(Data(), to: zero.appendingPathComponent("invalid.nca"))
        let collision = root.appendingPathComponent("collision", isDirectory: true)
        try write(Data("one".utf8), to: collision.appendingPathComponent("a/duplicate.nca"))
        try write(Data("two".utf8), to: collision.appendingPathComponent("b/duplicate.nca"))
        for invalid in [root.appendingPathComponent("missing"), empty, zero, collision] {
            XCTAssertThrowsError(try SwitchRuntime.prepareDataDir(data, keysPath: "", firmwarePath: invalid.path))
            XCTAssertEqual(try Data(contentsOf: previous), bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: registered.deletingLastPathComponent().path), ["registered"])
        }
        let valid = root.appendingPathComponent("valid", isDirectory: true)
        try write(Data("new firmware".utf8), to: valid.appendingPathComponent("new.nca"))
        try SwitchRuntime.prepareDataDir(data, keysPath: "", firmwarePath: valid.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: registered.appendingPathComponent("new.nca").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
    }

    func testExecutableAndCommentedAppAssignmentsPreserveScript() throws {
        let root = try temporaryDirectory()
        let binary = root.appendingPathComponent("Ryujinx")
        try write(Data("#!/bin/sh\nexit 0\n".utf8), to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let app = root.appendingPathComponent("Custom App.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("launch.command")
        for assignment in ["EMULATOR=\"\(binary.path)\"", "EMULATOR='\(app.path)' # custom flags below", "export EMULATOR=\"\(app.path)\" # comment", "EMULATOR=\(binary.path) # comment"] {
            try assignment.write(to: script, atomically: true, encoding: .utf8)
            XCTAssertFalse(SwitchRuntime.launchScriptHasMissingEmulator(script), assignment)
        }
        try "EMULATOR='\(root.path)/missing.app' # unavailable".write(to: script, atomically: true, encoding: .utf8)
        XCTAssertTrue(SwitchRuntime.launchScriptHasMissingEmulator(script))
    }

    func testUncertainShellAssignmentsNeverBypassScript() throws {
        let root = try temporaryDirectory()
        let missing = root.appendingPathComponent("missing.app").path
        let script = root.appendingPathComponent("launch.command")
        let contents = [
            "EMULATOR=\"\(missing)\"#literal-suffix",
            "EMULATOR= \"\(missing)\"",
            "EMULATOR=\"\(missing)\"; prepare_runtime",
            "EMULATOR=\"\(missing)\"'suffix'",
            "EMULATOR=\(missing)\\ with\\ spaces",
            "EMULATOR=\(missing)*",
            "EMULATOR=\"$HOME/missing.app\"",
            "EMULATOR=\"$(find_emulator)\"",
            "EMULATOR=\"`find_emulator`\"",
            "EMULATOR=\"\(missing)\"\nEMULATOR=\"$HOME/Custom.app\"",
            "EMULATOR=\"\(missing)\"\nEMULATOR+=suffix",
            "EMULATOR=\"\(missing)\"\nEMULATOR[0]=\"$HOME/Custom.app\""
        ]
        for content in contents {
            try content.write(to: script, atomically: true, encoding: .utf8)
            XCTAssertFalse(SwitchRuntime.launchScriptHasMissingEmulator(script), content)
        }
    }

    func testControlFlowHereDocsAndContinuationsPreserveScript() throws {
        let root = try temporaryDirectory()
        let assignment = "EMULATOR=\"\(root.path)/missing.app\""
        let script = root.appendingPathComponent("launch.command")
        let contents = [
            "cat <<'HELP' >/dev/null\n\(assignment)\nHELP\necho custom-launch",
            "if false; then\n\(assignment)\nfi\necho custom-launch",
            "unused() {\n\(assignment)\n}\necho custom-launch",
            "for name in first second; do\n\(assignment)\ndone",
            "\(assignment)\\\n'suffix'\nopen -n \"$EMULATOR\"",
            "echo continuation \\\n\(assignment)\nopen -n Custom.app",
            "MESSAGE=\"documentation\n\(assignment)\n\"\necho custom-launch",
            "\(assignment)\nsource ./custom-runtime.conf\nopen -n \"$EMULATOR\"",
            "\(assignment)\n.\t./custom-runtime.conf\nopen -n \"$EMULATOR\"",
            "\(assignment)\nreadonly EMULATOR=\"$HOME/Custom.app\"",
            "\(assignment)\neval \"custom-runtime-setup\""
        ]
        for content in contents {
            try content.write(to: script, atomically: true, encoding: .utf8)
            XCTAssertFalse(SwitchRuntime.launchScriptHasMissingEmulator(script), content)
        }
    }

    func testSimpleTopLevelMissingAssignmentStillFallsBackAfterSetup() throws {
        let root = try temporaryDirectory()
        let script = root.appendingPathComponent("launch.command")
        let content = """
        #!/bin/zsh
        # Documentation can mention if, for, << and a trailing backslash \\
        set -e
        cd -- "\(root.path)"
        EMULATOR='\(root.path)/missing.app' # missing static app
        open -n "$EMULATOR" --args "$GAME"
        """
        try content.write(to: script, atomically: true, encoding: .utf8)
        XCTAssertTrue(SwitchRuntime.launchScriptHasMissingEmulator(script))
    }

    private func write(_ bytes: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }
}
