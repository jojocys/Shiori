import XCTest
@testable import Shiori

final class WineSteamDockReopenPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let mainPID: Int32 = 100
    private let helperPID: Int32 = 101

    func testRequestsReopenForActivatedSteamProcessWhenNoWindowIsVisible() {
        XCTAssertTrue(shouldRequestReopen(activatedPID: mainPID))
    }

    func testRequestsReopenForActivatedSteamWebHelperWhenNoWindowIsVisible() {
        XCTAssertTrue(shouldRequestReopen(activatedPID: helperPID))
    }

    func testDoesNotRequestReopenForUnrelatedWineProcess() {
        XCTAssertFalse(shouldRequestReopen(activatedPID: 999))
    }

    func testDoesNotRequestReopenWithoutRunningMainClient() {
        XCTAssertFalse(shouldRequestReopen(
            activatedPID: mainPID,
            steamMainClientPIDs: []
        ))
    }

    func testDoesNotRequestReopenWhenAnySteamClientWindowIsVisible() {
        XCTAssertFalse(shouldRequestReopen(
            activatedPID: mainPID,
            visibleWindowOwnerPIDs: [helperPID]
        ))
    }

    func testCooldownPreventsActivationLoop() {
        XCTAssertFalse(shouldRequestReopen(
            activatedPID: mainPID,
            lastRequestAt: now.addingTimeInterval(-1)
        ))
    }

    func testRequestIsAllowedAfterCooldown() {
        XCTAssertTrue(shouldRequestReopen(
            activatedPID: mainPID,
            lastRequestAt: now.addingTimeInterval(-WineSteamDockReopenPolicy.requestCooldown)
        ))
    }

    func testClientEntryStartsNormallyWhenSteamIsNotRunning() {
        XCTAssertEqual(
            WineSteamDockReopenPolicy.clientEntryArguments(steamMainClientPIDs: []),
            []
        )
    }

    func testClientEntryRequestsMainWindowWhenSteamIsAlreadyRunning() {
        XCTAssertEqual(
            WineSteamDockReopenPolicy.clientEntryArguments(steamMainClientPIDs: [mainPID]),
            ["steam://open/main"]
        )
    }

    func testRecognizesSteamMainClientFromWineCommandLineWithSpaces() {
        XCTAssertTrue(WineSteamDockReopenPolicy.isSteamMainClientCommandLine(
            #"C:\Program Files (x86)\Steam\Steam.exe -no-cef-sandbox -foreground"#
        ))
    }

    func testDoesNotMistakeSteamWebHelperSteamPathArgumentForMainClient() {
        XCTAssertFalse(WineSteamDockReopenPolicy.isSteamMainClientCommandLine(
            #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe -steampath=C:\Program Files (x86)\Steam\steam.exe"#
        ))
    }

    func testDoesNotMistakeGameProcessSteamArgumentForMainClient() {
        XCTAssertFalse(WineSteamDockReopenPolicy.isSteamMainClientCommandLine(
            #"C:\Games\Example\game.exe --launcher C:\Program Files (x86)\Steam\Steam.exe"#
        ))
    }

    private func shouldRequestReopen(
        activatedPID: Int32,
        steamMainClientPIDs: Set<Int32>? = nil,
        visibleWindowOwnerPIDs: Set<Int32> = [],
        lastRequestAt: Date? = nil
    ) -> Bool {
        WineSteamDockReopenPolicy.shouldRequestReopen(
            activatedPID: activatedPID,
            steamClientPIDs: [mainPID, helperPID],
            steamMainClientPIDs: steamMainClientPIDs ?? [mainPID],
            visibleWindowOwnerPIDs: visibleWindowOwnerPIDs,
            now: now,
            lastRequestAt: lastRequestAt
        )
    }
}
