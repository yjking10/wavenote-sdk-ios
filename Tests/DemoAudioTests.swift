import XCTest
import AVFoundation
#if canImport(DemoLogic)
@testable import DemoLogic
#else
@testable import WaveNoteDemo
#endif

final class DemoAudioTests: XCTestCase {
    func testTransferRateExcludesResumeOffsetAndThrottlesSamples() {
        let rate = DemoTransferRate()
        XCTAssertNil(rate.sample(bytes: 100_000, now: 10))
        XCTAssertNil(rate.sample(bytes: 100_512, now: 10.25))
        XCTAssertEqual(rate.sample(bytes: 101_024, now: 10.5)!, 2, accuracy: 0.001)
        XCTAssertEqual(rate.sample(bytes: 101_024, now: 11)!, 0)
        XCTAssertNil(rate.sample(bytes: 0, now: 12))
        var row = DemoAudioRow(file: file)
        row.status = "继续下载"; row.kilobytesPerSecond = 2
        XCTAssertTrue(row.speedText.contains("KB/s"))
        row.status = "正在生成音频文件 10%"
        XCTAssertEqual(row.speedText, "")
        row.status = "同步完成"
        XCTAssertEqual(row.speedText, "")
    }
    let stopped = DemoRecordingValue(state: 1, name: nil, mode: nil)
    let active = DemoRecordingValue(state: 2, name: "1800000000.opus", mode: 1)
    let file = DemoAudioFile(name: "one.opus", size: 7, mode: 1)
    func testManagedPathRedactsUserInCompletionLog() {
        var row = DemoAudioRow(file: DemoAudioFile(name: "test.opus", size: 7, mode: 1))
        row.localPath = "/private/wavenote/sensitive-user/device/file/id.ogg"
        XCTAssertFalse(row.logJSON.contains("sensitive-user"))
        XCTAssertTrue(row.logJSON.contains("[redacted]"))
        XCTAssertTrue(row.localPath!.contains("sensitive-user"))
    }
    func configured() -> DemoAudioLibrary {
        let lib = DemoAudioLibrary()
        lib.readRecording = { $0(self.stopped, nil) }
        lib.count = { mode, done in done(mode == 1 ? 1 : 0, nil) }
        lib.page = { _, _, done in done([self.file], nil) }
        return lib
    }
    func testStoppedListsBothModesThenDownloadsWithProgressAndCompletion() {
        let lib = configured(); var calls: [String] = []; var complete: ((String?, String?) -> Void)?; var progress: ((Int64) -> Void)?
        lib.count = { mode, done in calls.append("count\(mode)"); done(1, nil) }
        lib.page = { mode, _, done in calls.append("page\(mode)"); done([DemoAudioFile(name: "one.opus", size: 7, mode: mode)], nil) }
        lib.download = { file, update, done in calls.append("download\(file.mode)"); progress = update; complete = done; return {} }
        var logs: [DemoAudioRow] = []; lib.completedRow = { logs.append($0) }
        XCTAssertTrue(lib.start()); XCTAssertFalse(lib.start())
        XCTAssertEqual(calls, ["count1", "page1", "count2", "page2", "download1"])
        XCTAssertEqual(lib.syncCountText, "已完成同步 0/2 个文件")
        progress?(3); XCTAssertEqual(lib.rows[0].received, 3); XCTAssertNil(lib.rows[0].localPath)
        lib.converting(bytes: 3, total: 7)
        XCTAssertEqual(lib.rows[0].status, "正在生成音频文件 42%")
        XCTAssertEqual(lib.completedCount, 0); XCTAssertNil(lib.rows[0].localPath)
        let first = complete; first?("/one.ogg", nil); first?("/wrong.ogg", nil)
        XCTAssertEqual(calls.last, "download2"); XCTAssertEqual(lib.rows[0].localPath, "/one.ogg"); XCTAssertEqual(lib.completedCount, 1)
        complete?("/two.ogg", nil); XCTAssertFalse(lib.busy); XCTAssertEqual(lib.rows[1].localPath, "/two.ogg")
        XCTAssertEqual(lib.syncCountText, "已完成同步 2/2 个文件")
        XCTAssertEqual(logs.count, 2)
        let json = try! JSONSerialization.jsonObject(with: Data(logs[0].logJSON.utf8)) as! [String: Any]
        XCTAssertEqual(json["received"] as? Int, 7); XCTAssertEqual(json["status"] as? String, "同步完成")
        XCTAssertEqual(json["localPath"] as? String, "/one.ogg")
        XCTAssertEqual((json["file"] as? [String: Any])?["name"] as? String, "one.opus")
    }
    func testTransportPreparationRunsAfterBothListsAndBeforeFirstDownload() {
        let lib = configured(); var calls: [String] = []; var prepared: ((String?) -> Void)?
        lib.count = { mode, done in calls.append("count\(mode)"); done(mode == 1 ? 1 : 0, nil) }
        lib.page = { _, _, done in calls.append("page"); done([self.file], nil) }
        lib.prepareDownloads = { done in calls.append("prepare"); prepared = done }
        lib.download = { _, _, _ in calls.append("download"); return {} }
        XCTAssertTrue(lib.start())
        XCTAssertEqual(calls, ["count1", "page", "count2", "prepare"])
        prepared?(nil)
        XCTAssertEqual(calls.last, "download")
    }
    func testTransportPreparationFailureEndsWithoutDownload() {
        let lib = configured(); var finished = 0
        lib.prepareDownloads = { $0("Wi-Fi 未就绪") }
        lib.download = { _, _, _ in XCTFail("must not download"); return {} }
        lib.finished = { finished += 1 }
        XCTAssertTrue(lib.start())
        XCTAssertFalse(lib.busy); XCTAssertEqual(lib.message, "Wi-Fi 未就绪"); XCTAssertEqual(finished, 1)
    }
    func testManualStopDuringTransportPreparationDoesNotStartDownload() {
        let lib = configured(); var prepared: ((String?) -> Void)?
        lib.prepareDownloads = { prepared = $0 }
        lib.download = { _, _, _ in XCTFail("must not download"); return {} }
        XCTAssertTrue(lib.start()); lib.stop(); XCTAssertTrue(lib.busy)
        prepared?(nil)
        XCTAssertFalse(lib.busy); XCTAssertEqual(lib.message, "同步已停止，可点击重新同步")
    }
    func testManualStopShowsSavedCheckpointInsteadOfCancellationError() {
        let lib = configured(); var complete: ((String?, String?) -> Void)?
        lib.download = { _, _, done in complete = done; return {} }
        XCTAssertTrue(lib.start())
        lib.stop(); complete?(nil, "同步已取消")
        XCTAssertFalse(lib.busy)
        XCTAssertEqual(lib.rows[0].status, "同步已停止，断点已保留")
        XCTAssertEqual(lib.message, "同步已停止，可点击重新同步")
    }
    func testPositionFailureSkipsCurrentRunAndManualSyncRetriesFile() {
        let lib = configured()
        var downloads: [String] = []
        lib.count = { mode, done in done(mode == 1 ? 2 : 0, nil) }
        lib.page = { mode, _, done in done(mode == 1 ? [self.file, DemoAudioFile(name: "two.opus", size: 7, mode: 1)] : [], nil) }
        lib.download = { file, _, done in
            downloads.append(file.name)
            let firstFailure = file.name == "one.opus" && downloads.filter { $0 == "one.opus" }.count == 1
            done(firstFailure ? nil : "/\(file.name).ogg", firstFailure ? "downloadPositionMismatch" : nil)
            return {}
        }
        XCTAssertTrue(lib.start())
        XCTAssertEqual(downloads, ["one.opus", "two.opus"])
        XCTAssertEqual(lib.failedCount, 1)
        XCTAssertEqual(lib.completedCount, 1)
        XCTAssertTrue(lib.message.contains("失败 1"))
        XCTAssertTrue(lib.start())
        XCTAssertEqual(downloads, ["one.opus", "two.opus", "one.opus", "two.opus"])
        XCTAssertEqual(lib.failedCount, 0)
        XCTAssertEqual(lib.completedCount, 2)
    }
    func testRecordingAndUnknownNeverList() {
        for value in [active, DemoRecordingValue(state: 3, name: nil, mode: nil), DemoRecordingValue(state: 0, name: nil, mode: nil)] {
            let lib = configured(); lib.readRecording = { $0(value, nil) }; lib.count = { _, _ in XCTFail("must not list") }
            _ = lib.start(); XCTAssertFalse(lib.busy); XCTAssertTrue(lib.rows.isEmpty)
        }
    }
    func testRecordingBetweenPagesStopsNextRequest() {
        let lib = configured(); var respond: (([DemoAudioFile]?, String?) -> Void)?
        lib.count = { _, done in done(2, nil) }; lib.page = { _, _, done in respond = done }
        _ = lib.start(); lib.observe(active); respond?([file], nil)
        XCTAssertFalse(lib.busy); XCTAssertTrue(lib.rows.isEmpty)
    }
    func testRecordingCancelsDownloadAndLateProgressCannotCompleteNewRun() {
        let lib = configured(); var cancelled = 0; var done: ((String?, String?) -> Void)?; var progress: ((Int64) -> Void)?
        lib.download = { _, p, d in progress = p; done = d; return { cancelled += 1 } }
        _ = lib.start(); lib.observe(active); XCTAssertEqual(cancelled, 1)
        done?(nil, "cancelled"); XCTAssertNil(lib.rows[0].localPath)
        lib.invalidate(); progress?(7); done?("/late.ogg", nil); XCTAssertTrue(lib.rows.isEmpty)
    }
    func testLateStoppedQueryCannotOverwriteRecordingNotification() {
        let lib = configured(); var done: ((DemoRecordingValue?, String?) -> Void)?
        lib.readRecording = { done = $0 }; lib.count = { _, _ in XCTFail() }
        _ = lib.start(); lib.observe(active); done?(stopped, nil)
        XCTAssertTrue(lib.isRecording); XCTAssertFalse(lib.busy)
    }
    func testManualStopWaitsForPendingQueryWithoutIssuingNextPage() {
        let lib = configured(); var done: (([DemoAudioFile]?, String?) -> Void)?
        lib.page = { _, _, d in done = d }; lib.download = { _, _, _ in XCTFail(); return {} }
        _ = lib.start(); lib.stop(); XCTAssertTrue(lib.busy)
        done?([file], nil); XCTAssertFalse(lib.busy); XCTAssertTrue(lib.rows.isEmpty)
    }
    func testDuplicatePageAndCountChangeFailWithoutDownload() {
        for invalid in [[file, file], []] {
            let lib = configured(); lib.count = { _, done in done(2, nil) }; lib.page = { _, _, done in done(invalid, nil) }
            lib.download = { _, _, _ in XCTFail(); return {} }; _ = lib.start(); XCTAssertFalse(lib.busy)
        }
    }
    func testReadFailureAndDisconnectIgnoreOldCallbacks() {
        let lib = configured(); var done: ((DemoRecordingValue?, String?) -> Void)?
        lib.readRecording = { done = $0 }; lib.count = { _, _ in XCTFail() }
        _ = lib.start(); done?(nil, "timeout"); XCTAssertEqual(lib.message, "timeout")
        _ = lib.start(); lib.invalidate(); done?(stopped, nil); XCTAssertFalse(lib.busy)
    }
    func testEmptyModesAndZeroByteFilesDoNotDownload() {
        let lib = configured(); lib.count = { _, done in done(0, nil) }; lib.download = { _, _, _ in XCTFail(); return {} }
        _ = lib.start(); XCTAssertEqual(lib.message, "设备暂无录音文件")
        lib.count = { mode, done in done(mode == 1 ? 1 : 0, nil) }; lib.page = { _, _, done in done([DemoAudioFile(name: "empty", size: 0, mode: 1)], nil) }
        _ = lib.start(); XCTAssertNil(lib.rows.first?.localPath); XCTAssertFalse(lib.busy)
    }
    func testRecordingClockTimestampPauseResumeAndUnknownName() {
        let clock = DemoRecordingClock()
        clock.update(active, wall: 1800000010, uptime: 100); XCTAssertEqual(clock.seconds(uptime: 105), 15); XCTAssertTrue(clock.estimated)
        clock.update(DemoRecordingValue(state: 3, name: active.name, mode: 1), wall: 1800000015, uptime: 105)
        XCTAssertEqual(clock.seconds(uptime: 110), 15)
        clock.update(active, wall: 1800000020, uptime: 110); XCTAssertEqual(clock.seconds(uptime: 115), 20)
        clock.update(DemoRecordingValue(state: 2, name: "bad.opus", mode: 1), wall: 1800000025, uptime: 115)
        XCTAssertFalse(clock.estimated); XCTAssertEqual(clock.seconds(uptime: 118), 3)
        clock.update(stopped); XCTAssertEqual(clock.seconds(), 0)
    }




    func testResumePhasesNeverMarkCompleteAndIgnoreDisconnectedState() {
        let lib = configured(); lib.download = { _,_,_ in {} }; _ = lib.start()
        lib.phase(file: file, text: "检查断点"); XCTAssertEqual(lib.rows[0].status, "检查断点")
        lib.phase(file: file, text: "继续下载"); XCTAssertEqual(lib.rows[0].status, "继续下载")
        lib.phase(file: file, text: "重新封装"); lib.converting(bytes: 7, total: 7)
        XCTAssertEqual(lib.rows[0].status, "重新封装 100%"); XCTAssertEqual(lib.completedCount, 0)
        lib.invalidate(); lib.phase(file: file, text: "继续下载"); XCTAssertTrue(lib.rows.isEmpty)
    }
    func testSystemOpusDecoderProducesNativePlayableCAFAndRejectsPartialCRC() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("test.ogg"), output = dir.appendingPathComponent("out.caf")
        let bytes = ogg(); try bytes.write(to: source)
        _ = try DemoOggPlayback.prepare(source, destination: output)
        let pcm = try AVAudioFile(forReading: output)
        XCTAssertEqual(pcm.processingFormat.sampleRate, 48000); XCTAssertEqual(pcm.length, 48000)
        XCTAssertTrue(try AVAudioPlayer(contentsOf: output).prepareToPlay())
        if let path = ProcessInfo.processInfo.environment["DEMO_PLAYBACK_QA"] { try Data(contentsOf: output).write(to: URL(fileURLWithPath: path)) }
        for invalid in [Data(bytes.dropLast()), Data(bytes.dropLast(32)), Data(bytes.enumerated().map { $0.offset == 50 ? $0.element ^ 1 : $0.element })] {
            try invalid.write(to: source); XCTAssertThrowsError(try DemoOggPlayback.prepare(source, destination: dir.appendingPathComponent(UUID().uuidString + ".caf")))
        }
    }
    func testSDKBatchOggWithNativeDecoderWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["WAVENOTE_BATCH_OGG_OUTPUT"] else { throw XCTSkip("SDK batch fixture optional") }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try DemoOggPlayback.prepare(URL(fileURLWithPath: path), destination: output)
        XCTAssertEqual(try AVAudioFile(forReading: output).length, 103 * 960)
    }



    private func ogg(batched: Bool = false) -> Data {
        func le(_ n: UInt64, _ length: Int) -> Data { Data((0..<length).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
        func page(_ payload: Data, _ sequence: UInt64, _ flags: UInt8, _ granule: UInt64, laces: Data? = nil) -> Data {
            let table = laces ?? Data([UInt8(payload.count)])
            var data = Data("OggS".utf8) + Data([0, flags]) + le(granule, 8) + le(1, 4) + le(sequence, 4) + Data([0,0,0,0,UInt8(table.count)]) + table + payload
            var crc: UInt32 = 0
            for b in data { crc ^= UInt32(b) << 24; for _ in 0..<8 { crc = crc & 0x80000000 == 0 ? crc << 1 : (crc << 1) ^ 0x04c11db7 } }
            data.replaceSubrange(22..<26, with: le(UInt64(crc), 4)); return data
        }
        var data = page(Data("OpusHead".utf8) + Data([1,1,0,0,0,0,0,0,0,0,0]), 0, 2, 0)
        data += page(Data("OpusTags".utf8) + Data(repeating: 0, count: 8), 1, 0, 0)
        if batched { return data + page(Data((0..<150).map { [UInt8(0xf8),0xff,0xfe][$0 % 3] }), 2, 4, 48000, laces: Data(repeating: 3, count: 50)) }
        for i in 0..<50 { data += page(Data([0xf8,0xff,0xfe]), UInt64(i+2), i == 49 ? 4 : 0, UInt64((i+1)*960)) }
        return data
    }
}
