import XCTest
@testable import DemoLogic

final class DemoOTATests: XCTestCase {
    func testTerminalProgressStillProtectsExitUntilFinalCompletion() {
        let flow = DemoOTAFlow(); let token = flow.begin()!
        XCTAssertTrue(flow.protectsExit); XCTAssertNil(flow.begin())
        flow.update(token, stage: 4, percent: 100)
        XCTAssertTrue(flow.protectsExit); XCTAssertNil(flow.outcome)
        XCTAssertTrue(flow.finish(token, outcome: .success)); XCTAssertFalse(flow.protectsExit)
    }
    func testSelectingNewFirmwareClearsPreviousResultAndRejectsLateProgress() {
        let flow = DemoOTAFlow(); let old = flow.begin()!
        flow.finish(old, outcome: .success); flow.connectionReady(true)
        XCTAssertTrue(flow.selectFirmware())
        flow.update(old, stage: 4, percent: 100)
        XCTAssertEqual(flow.percent, 0); XCTAssertNil(flow.stage); XCTAssertNil(flow.outcome)
        XCTAssertFalse(flow.businessReady); XCTAssertEqual(flow.title, "未开始升级")
    }
    func testCancelAcknowledgementDoesNotMeanCancelledOrAllowRepeatedRequests() {
        let flow = DemoOTAFlow(); let token = flow.begin()!
        XCTAssertEqual(flow.beginCancel(), token); XCTAssertNil(flow.beginCancel())
        XCTAssertTrue(flow.cancelResult(token, accepted: true)); XCTAssertTrue(flow.cancelPending)
        XCTAssertTrue(flow.active); XCTAssertNil(flow.outcome); XCTAssertNil(flow.beginCancel())
        flow.update(token, stage: 5, percent: 42); XCTAssertTrue(flow.protectsExit)
        flow.finish(token, outcome: .cancelled)
        XCTAssertFalse(flow.cancelPending); XCTAssertEqual(flow.outcome, .cancelled)
    }
    func testRejectedCancelCanRetryButLateAcknowledgementCannotOverwriteSuccess() {
        let flow = DemoOTAFlow(); let token = flow.begin()!
        _ = flow.beginCancel(); flow.cancelResult(token, accepted: false)
        XCTAssertFalse(flow.cancelPending); XCTAssertEqual(flow.beginCancel(), token)
        flow.finish(token, outcome: .success)
        XCTAssertFalse(flow.cancelResult(token, accepted: true)); XCTAssertEqual(flow.outcome, .success)
    }
    func testBusinessConnectionIsSeparateFromUpgradeSuccess() {
        let flow = DemoOTAFlow(); let token = flow.begin()!
        flow.connectionReady(true) // Old business connection cannot count as recovery.
        XCTAssertFalse(flow.businessReady)
        flow.finish(token, outcome: .success)
        XCTAssertTrue(flow.title.contains("正在恢复"))
        flow.connectionReady(true); XCTAssertTrue(flow.title.contains("已恢复"))
        flow.connectionReady(false); XCTAssertTrue(flow.title.contains("正在恢复"))
    }
    func testLateCompletionCannotFinishANewUpgradeOrChangeItsProgress() {
        let flow = DemoOTAFlow(); let first = flow.begin()!
        flow.finish(first, outcome: .failed); let second = flow.begin()!
        XCTAssertFalse(flow.finish(first, outcome: .success))
        flow.update(first, stage: 4, percent: 100)
        XCTAssertTrue(flow.active); XCTAssertEqual(flow.percent, 0)
        flow.update(second, stage: 1, percent: 99)
        XCTAssertEqual(flow.percent, 99); XCTAssertTrue(flow.protectsExit)
    }
    func testFileSizeBoundariesAndActiveImportProtection() {
        XCTAssertFalse(DemoOTAFlow.validFileSize(0)); XCTAssertFalse(DemoOTAFlow.validFileSize(-1))
        XCTAssertTrue(DemoOTAFlow.validFileSize(1)); XCTAssertTrue(DemoOTAFlow.validFileSize(Int64(Int32.max)))
        XCTAssertFalse(DemoOTAFlow.validFileSize(Int64(Int32.max) + 1))
        let flow = DemoOTAFlow(); _ = flow.begin(); XCTAssertFalse(flow.selectFirmware())
    }
}
