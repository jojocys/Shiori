import Foundation
@testable import Shiori
import XCTest

final class WineFontCompatibilityTests: XCTestCase {
    func testPlanAddsCJKAliasesAndShellFontsWithoutOverwritingAnything() {
        let plan = WineFontCompatibility.makePlan(
            targetFamily: "Hiragino Sans GB",
            replacements: [:],
            fontSubstitutes: [:],
            ownedChanges: []
        )

        XCTAssertEqual(plan.changes.count, WineFontCompatibility.cjkAliases.count + 2)
        XCTAssertTrue(plan.preservedNames.isEmpty)
        XCTAssertEqual(change(named: "SimSun", in: plan)?.appliedValue, "Hiragino Sans GB")
        XCTAssertEqual(change(named: "MS Gothic", in: plan)?.appliedValue, "Hiragino Sans GB")
        XCTAssertEqual(change(named: "MS Shell Dlg 2", in: plan)?.previousValue, nil)
    }

    func testPlanPreservesUserFontMappingsButReplacesWineShellDefaults() {
        let plan = WineFontCompatibility.makePlan(
            targetFamily: "Hiragino Sans GB",
            replacements: ["SimSun": "My Chinese Font"],
            fontSubstitutes: [
                "MS Shell Dlg": "SimSun",
                "MS Shell Dlg 2": "My UI Font"
            ],
            ownedChanges: []
        )

        XCTAssertNil(change(named: "SimSun", in: plan))
        XCTAssertNil(change(named: "MS Shell Dlg 2", in: plan))
        XCTAssertEqual(change(named: "MS Shell Dlg", in: plan)?.previousValue, "SimSun")
        XCTAssertTrue(plan.preservedNames.contains("SimSun"))
        XCTAssertTrue(plan.preservedNames.contains("MS Shell Dlg 2"))
    }

    func testPlanCanUpdateShioriOwnedMappingWhileKeepingOriginalRollbackValue() {
        let owned = WineFontRegistryChange(
            key: WineFontCompatibility.replacementsKey,
            name: "MS Gothic",
            previousValue: nil,
            appliedValue: "Hiragino Sans GB"
        )
        let plan = WineFontCompatibility.makePlan(
            targetFamily: "Hiragino Sans",
            replacements: ["MS Gothic": "Hiragino Sans GB"],
            fontSubstitutes: [:],
            ownedChanges: [owned]
        )

        let updated = change(named: "MS Gothic", in: plan)
        XCTAssertEqual(updated?.appliedValue, "Hiragino Sans")
        XCTAssertNil(updated?.previousValue)
    }

    func testRegistryQueryParserSupportsNamesAndValuesContainingSpaces() {
        let output = """
        HKEY_CURRENT_USER\\Software\\Wine\\Fonts\\Replacements
            MS UI Gothic    REG_SZ    Hiragino Sans GB
            SimSun    REG_SZ    Hiragino Sans GB
        """

        let values = WineFontCompatibility.parseRegistryQuery(output)
        XCTAssertEqual(values["MS UI Gothic"], "Hiragino Sans GB")
        XCTAssertEqual(values["SimSun"], "Hiragino Sans GB")
    }

    func testRegistryImportDataIsUTF16AndSupportsLocalizedNamesAndDeletion() throws {
        let data = try WineFontCompatibility.makeRegistryData([
            (WineFontCompatibility.replacementsKey, "ＭＳ ゴシック", "Hiragino Sans"),
            (WineFontCompatibility.replacementsKey, "Old Font", nil)
        ])

        XCTAssertEqual(Array(data.prefix(2)), [0xff, 0xfe])
        let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        XCTAssertTrue(try XCTUnwrap(text).contains("[HKEY_CURRENT_USER\\Software\\Wine\\Fonts\\Replacements]"))
        XCTAssertTrue(try XCTUnwrap(text).contains("\"ＭＳ ゴシック\"=\"Hiragino Sans\""))
        XCTAssertTrue(try XCTUnwrap(text).contains("\"Old Font\"=-"))
    }

    func testAutoLanguageUsesChineseProfileForCHSExecutable() {
        let game = GameEntry(
            name: "WHITE ALBUM2",
            gameFolderPath: "/Games/WHITE ALBUM2",
            exePath: "/Games/WHITE ALBUM2/WA2_chs.exe",
            prefixDir: "/Prefixes/WA2"
        )

        XCTAssertEqual(WineFontCompatibility.profile(for: game), .simplifiedChinese)
    }

    private func change(named name: String, in plan: WineFontRepairPlan) -> WineFontRegistryChange? {
        plan.changes.first { $0.name == name }
    }
}
