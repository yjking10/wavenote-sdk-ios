import XCTest
import AVFoundation
#if canImport(DemoLogic)
@testable import DemoLogic
#else
@testable import WaveNoteDemo
#endif

final class DemoAudioTests: XCTestCase {
    let stopped = DemoRecordingValue(state: 1, name: nil, mode: nil)
    let active = DemoRecordingValue(state: 2, name: "1800000000.opus", mode: 1)
    let file = DemoAudioFile(name: "one.opus", size: 7, mode: 1)
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
        XCTAssertTrue(lib.start()); XCTAssertFalse(lib.start())
        XCTAssertEqual(calls, ["count1", "page1", "count2", "page2", "download1"])
        progress?(3); XCTAssertEqual(lib.rows[0].received, 3); XCTAssertNil(lib.rows[0].localPath)
        let first = complete; first?("/one.ogg", nil); first?("/wrong.ogg", nil)
        XCTAssertEqual(calls.last, "download2"); XCTAssertEqual(lib.rows[0].localPath, "/one.ogg")
        complete?("/two.ogg", nil); XCTAssertFalse(lib.busy); XCTAssertEqual(lib.rows[1].localPath, "/two.ogg")
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
    func testStoreRequiresCommitAndSeparatesDeviceModeAndSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: dir) }
        let store = DemoAudioStore(root: dir)
        let first = try store.prepare(sn: "fake-device-a", file: file); try Data([1,2,3]).write(to: first.destination)
        XCTAssertFalse(try store.prepare(sn: "fake-device-a", file: file).cached)
        try store.commit(first.destination, sn: "fake-device-a", file: file)
        XCTAssertTrue(try store.prepare(sn: "fake-device-a", file: file).cached)
        XCTAssertFalse(try store.prepare(sn: "fake-device-b", file: file).cached)
        XCTAssertFalse(try store.prepare(sn: "fake-device-a", file: DemoAudioFile(name: file.name, size: 8, mode: 1)).cached)
        XCTAssertFalse(try store.prepare(sn: "fake-device-a", file: DemoAudioFile(name: file.name, size: 7, mode: 2)).cached)
        try FileManager.default.removeItem(at: first.destination); XCTAssertFalse(try store.prepare(sn: "fake-device-a", file: file).cached)
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
    private func ogg() -> Data {
        func le(_ n: UInt64, _ length: Int) -> Data { Data((0..<length).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) }) }
        func page(_ payload: Data, _ sequence: UInt64, _ flags: UInt8, _ granule: UInt64) -> Data {
            var data = Data("OggS".utf8) + Data([0, flags]) + le(granule, 8) + le(1, 4) + le(sequence, 4) + Data([0,0,0,0,1,UInt8(payload.count)]) + payload
            var crc: UInt32 = 0
            for b in data { crc ^= UInt32(b) << 24; for _ in 0..<8 { crc = crc & 0x80000000 == 0 ? crc << 1 : (crc << 1) ^ 0x04c11db7 } }
            data.replaceSubrange(22..<26, with: le(UInt64(crc), 4)); return data
        }
        var data = page(Data("OpusHead".utf8) + Data([1,1,0,0,0,0,0,0,0,0,0]), 0, 2, 0)
        data += page(Data("OpusTags".utf8) + Data(repeating: 0, count: 8), 1, 0, 0)
        for i in 0..<50 { data += page(Data([0xf8,0xff,0xfe]), UInt64(i+2), i == 49 ? 4 : 0, UInt64((i+1)*960)) }
        return data
    }
}
