import XCTest
#if canImport(DemoLogic)
@testable import DemoLogic
#else
@testable import WaveNoteDemo
#endif

final class DemoFlowTests: XCTestCase {
    func testUnboundSelectionBindsThenConnectsOnlyOnce() {
        let flow = DemoFlow(); let selection = flow.select(bound: false, fresh: true)!
        XCTAssertEqual(selection.1, .bind); XCTAssertTrue(flow.busy)
        XCTAssertNil(flow.select(bound: false, fresh: true))
        XCTAssertTrue(flow.bound(selection.0, success: true))
        XCTAssertFalse(flow.bound(selection.0, success: true))
        XCTAssertFalse(flow.ready); flow.connected(); XCTAssertTrue(flow.ready)
    }
    func testBoundSelectionSkipsBindAndStillWaitsForReady() {
        let flow = DemoFlow(); let selection = flow.select(bound: true, fresh: true)!
        XCTAssertEqual(selection.1, .connect); XCTAssertFalse(flow.bound(selection.0, success: true))
        XCTAssertNil(flow.beginSetting()); flow.connected(); XCTAssertNotNil(flow.beginSetting())
    }
    func testBindingFailureDoesNotConnectAndAllowsRetry() {
        let flow = DemoFlow(); let token = flow.select(bound: false, fresh: true)!.0
        XCTAssertFalse(flow.bound(token, success: false)); XCTAssertFalse(flow.ready)
        XCTAssertNotNil(flow.select(bound: false, fresh: true))
    }
    func testExpiredDiscoveryDoesNotStartOperation() {
        let flow = DemoFlow(); XCTAssertNil(flow.select(bound: false, fresh: false)); XCTAssertFalse(flow.busy)
    }
    func testDisconnectInvalidatesBindingAndReadyPage() {
        let flow = DemoFlow(); let token = flow.select(bound: false, fresh: true)!.0
        flow.invalidate(); XCTAssertFalse(flow.bound(token, success: true))
        flow.connected(); let query = flow.beginSetting()!
        flow.invalidate(); XCTAssertFalse(flow.ready); XCTAssertFalse(flow.finish(query)); XCTAssertNil(flow.beginSetting())
    }
    func testLateSettingCannotFinishNewOperation() {
        let flow = DemoFlow(); flow.connected(); let first = flow.beginSetting()!
        XCTAssertNil(flow.beginSetting()); XCTAssertTrue(flow.finish(first))
        let second = flow.beginSetting()!
        XCTAssertFalse(flow.finish(first)); XCTAssertTrue(flow.busy); XCTAssertTrue(flow.finish(second))
    }
    func testOwnershipPersistsBetweenStoreInstancesAndDisconnectDoesNotUnbind() {
        var disk: [String: String] = [:]
        func store() -> DemoOwnershipStore { DemoOwnershipStore(read: { disk }, write: { disk = $0 }) }
        XCTAssertTrue(store().bind("device-hash", user: "user-hash"))
        let flow = DemoFlow(); flow.connected(); flow.invalidate()
        XCTAssertEqual(store().owner("device-hash"), "user-hash")
        XCTAssertTrue(store().bind("device-hash", user: "user-hash"))
        XCTAssertTrue(store().unbind("device-hash", user: "user-hash")); XCTAssertNil(store().owner("device-hash"))
    }
    func testOwnershipRejectsOtherUserWithoutChangingRecord() {
        var disk = ["device-hash": "owner-hash"]
        let store = DemoOwnershipStore(read: { disk }, write: { disk = $0 })
        XCTAssertFalse(store.bind("device-hash", user: "other-hash"))
        XCTAssertFalse(store.unbind("device-hash", user: "other-hash"))
        XCTAssertEqual(store.owner("device-hash"), "owner-hash")
    }
    func testGainRawBoundariesAndMalformedInput() {
        XCTAssertEqual(DemoFlow.gain("0"), 0); XCTAssertEqual(DemoFlow.gain("255"), 255)
        for text in ["", "-1", "256", "1.5", " ", "１２", "9999999999999999999999999"] { XCTAssertNil(DemoFlow.gain(text)) }
    }
    func testScanStopDuringBindingDoesNotCancelSelection() {
        let flow = DemoFlow(); let token = flow.select(bound: false, fresh: true)!.0
        flow.disconnected(); XCTAssertTrue(flow.busy); XCTAssertTrue(flow.bound(token, success: true))
        flow.disconnected(); XCTAssertTrue(flow.selecting); flow.connected(); XCTAssertTrue(flow.ready)
    }
    func testRepeatedDisconnectKeepsSingleGenerationForShutdownResult() {
        let flow = DemoFlow(); flow.connected(); let token = flow.beginSetting()!
        flow.disconnected(); flow.disconnected()
        XCTAssertEqual(flow.generation, token + 1); XCTAssertFalse(flow.ready)
        XCTAssertFalse(flow.finish(token))
    }
    func testUnknownAndCustomAutoPowerOffAreNotDefaulted() {
        XCTAssertEqual(DemoFlow.minutes(nil), "未知"); XCTAssertEqual(DemoFlow.minutes(0), "永不")
        XCTAssertEqual(DemoFlow.minutes(17), "17 分钟")
    }
}

final class DemoSettingsTests: XCTestCase {
    func testQueriesAreSequentialAndDuplicateCallbacksDoNotAdvance() {
        var requested: [Int] = []; var callbacks: [(Int?) -> Void] = []; var completions = 0
        DemoReadSequence.run([102, 105, 106], active: { true }, query: { item, done in requested.append(item); callbacks.append(done) }, finished: { (_: Int?) in completions += 1 })
        XCTAssertEqual(requested, [102]); callbacks[0](nil); callbacks[0](nil)
        XCTAssertEqual(requested, [102, 105]); callbacks[1](nil); callbacks[2](nil); callbacks[2](nil)
        XCTAssertEqual(requested, [102, 105, 106]); XCTAssertEqual(completions, 1)
    }
    func testQueryFailureStopsSequenceWithoutSuccess() {
        var requested: [Int] = []; var result: Int?
        DemoReadSequence.run([102, 105], active: { true }, query: { item, done in requested.append(item); done(1103) }, finished: { result = $0 })
        XCTAssertEqual(requested, [102]); XCTAssertEqual(result, 1103)
    }
    func testOldSessionQueryCannotUpdateNewSession() {
        let flow = DemoFlow(); flow.connected(); let token = flow.beginSetting()!
        var callback: ((Int?) -> Void)?; var finished = false
        DemoReadSequence.run([102, 105], active: { flow.accepts(token) }, query: { _, done in callback = done }, finished: { (_: Int?) in finished = true })
        flow.disconnected(); flow.connected(); callback?(nil); XCTAssertFalse(finished)
    }
    func testUnknownUSBIsNotOffAndCannotBeEdited() {
        XCTAssertEqual(DemoValues.usb(nil), "未知"); XCTAssertFalse(DemoValues.canSetUSB(nil))
        XCTAssertEqual(DemoValues.usb(0), "已关闭"); XCTAssertTrue(DemoValues.canSetUSB(0))
        XCTAssertEqual(DemoValues.usb(1), "已开启"); XCTAssertTrue(DemoValues.canSetUSB(1))
    }
    func testReadbackFailureAndShutdownUnknownRemainExplicit() {
        XCTAssertTrue(DemoValues.error(1202).contains("未确认"))
        XCTAssertTrue(DemoValues.error(1203).contains("结果未确认"))
        XCTAssertFalse(DemoValues.error(1203).contains("已确认关机"))
    }
}
