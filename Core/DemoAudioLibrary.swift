import Foundation

struct DemoAudioFile: Equatable {
    let name: String
    let size: Int64
    let mode: Int
    var key: String { "\(mode):\(size):\(name)" }
}
struct DemoRecordingValue {
    // 0 unknown, 1 stopped, 2 recording, 3 paused (SDK public state values).
    let state: Int
    let name: String?
    let mode: Int?
}
struct DemoAudioRow {
    let file: DemoAudioFile
    var received: Int64 = 0
    var status = "等待同步"
    var localPath: String?
    var kilobytesPerSecond: Double?
    var speedText: String {
        guard ["正在同步", "继续下载"].contains(status) else { return "" }
        return kilobytesPerSecond.map { String(format: " · %.1f KB/s", $0) } ?? " · — KB/s"
    }
    /// Complete row metadata only; no credentials, raw SN or audio payload.
    var logJSON: String {
        let value: [String: Any] = ["file": ["name": file.name, "size": file.size, "mode": file.mode, "key": file.key],
                                   "received": received, "status": status, "localPath": localPath.map { path in
                                       path.replacingOccurrences(of: "(/wavenote/)[^/]+", with: "$1[redacted]", options: .regularExpression)
                                   } as Any? ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// Demo 调度器只依赖注入的公共 API 适配器；同一时刻仅发一个请求。
/// 每个请求与连接都有代际，重复或旧回调不能推进后续列表/下载。
final class DemoAudioLibrary {
    var readRecording: (@escaping (DemoRecordingValue?, String?) -> Void) -> Void = { _ in }
    var count: (Int, @escaping (Int?, String?) -> Void) -> Void = { _, _ in }
    var page: (Int, Int, @escaping ([DemoAudioFile]?, String?) -> Void) -> Void = { _, _, _ in }
    var download: (DemoAudioFile, @escaping (Int64) -> Void, @escaping (String?, String?) -> Void) -> (() -> Void) = { _, _, _ in {} }
    var changed: (() -> Void)?
    var finished: (() -> Void)?
    var completedRow: ((DemoAudioRow) -> Void)?
    private(set) var rows: [DemoAudioRow] = []
    private(set) var busy = false
    private(set) var recording = DemoRecordingValue(state: 0, name: nil, mode: nil)
    private(set) var message = "连接后检查录音状态"
    private var generation = 0
    private var request = 0
    private var stopRequested = false
    private var cancelDownload: (() -> Void)?
    private var collected: [DemoAudioFile] = []
    private var failedThisConnection = Set<String>()
    var isRecording: Bool { recording.state == 2 || recording.state == 3 }
    /// 仅完整交付到本地的文件计为已完成；失败、取消和空文件不计入。
    var completedCount: Int { rows.lazy.filter { $0.localPath != nil }.count }
    var failedCount: Int { rows.lazy.filter { $0.status == "同步失败，断点已保留" }.count }
    var totalCount: Int { rows.count }
    var syncCountText: String { "已完成同步 \(completedCount)/\(totalCount) 个文件" + (failedCount > 0 ? "，失败 \(failedCount) 个" : "") }
    func invalidate() {
        generation += 1; request += 1; cancelDownload = nil; busy = false
        stopRequested = false; rows = []; collected = []; failedThisConnection.removeAll()
        recording = DemoRecordingValue(state: 0, name: nil, mode: nil); message = "连接已断开，重新连接后同步"
    }
    func observe(_ value: DemoRecordingValue) {
        recording = value
        if value.state != 1 {
            if busy { stopRequested = true; cancelDownload?() }
            message = isRecording ? "\(value.state == 3 ? "录音已暂停" : "正在录音") · 文件同步已暂停" : "录音状态未知，不同步文件"
        }
        changed?()
    }
    @discardableResult func start() -> Bool {
        guard !busy, !isRecording else { return false }
        generation += 1; busy = true; stopRequested = false; collected = []
        message = "正在确认录音状态…"; changed?()
        let ticket = next()
        readRecording { [weak self] value, error in
            guard let self, self.accept(ticket) else { return }
            if let error { self.end(error); return }
            guard let value else { self.end("录音状态应答缺失"); return }
            if self.stopRequested { self.end(self.message); return }
            self.observe(value)
            guard !self.stopRequested, value.state == 1 else { self.end(self.message); return }
            self.listMode(1)
        }
        return true
    }
    func stop() {
        guard busy else { return }
        stopRequested = true; message = "正在停止同步…"; changed?(); cancelDownload?()
    }
    private func next() -> (Int, Int) { request += 1; return (generation, request) }
    private func accept(_ ticket: (Int, Int)) -> Bool {
        guard busy, generation == ticket.0, request == ticket.1 else { return false }
        request += 1; return true
    }
    private func proceed() -> Bool {
        if stopRequested || recording.state != 1 { end(isRecording ? "录音中，文件同步已暂停" : "同步已停止，可点击重新同步"); return false }; return true
    }
    private func listMode(_ mode: Int) {
        guard proceed() else { return }
        message = "正在获取 \(mode == 1 ? "Note" : "Call") 文件列表…"; changed?()
        let ticket = next()
        count(mode) { [weak self] value, error in
            guard let self, self.accept(ticket), self.proceed() else { return }
            if let error { self.end(error); return }
            guard let value, (0...1_000_000).contains(value) else { self.end("文件数量应答非法"); return }
            self.listPage(mode, index: 0, expected: value, files: [])
        }
    }
    private func listPage(_ mode: Int, index: Int, expected: Int, files: [DemoAudioFile]) {
        guard proceed() else { return }
        if files.count == expected {
            collected += files
            if mode == 1 { listMode(2) }
            else {
                let old = Dictionary(rows.map { ($0.file.key, $0) }, uniquingKeysWith: { a, _ in a })
                rows = collected.map { old[$0.key] ?? DemoAudioRow(file: $0) }; changed?(); downloadNext(0)
            }
            return
        }
        let ticket = next()
        page(mode, index) { [weak self] values, error in
            guard let self, self.accept(ticket), self.proceed() else { return }
            if let error { self.end(error); return }
            guard let values, !values.isEmpty, values.count <= 5, files.count + values.count <= expected,
                  values.allSatisfy({ $0.mode == mode && $0.size >= 0 }),
                  Set((files + values).map(\.name)).count == files.count + values.count else { self.end("文件列表变化或出现重复页，请重新同步"); return }
            self.listPage(mode, index: index + 1, expected: expected, files: files + values)
        }
    }
    private func downloadNext(_ index: Int) {
        guard proceed() else { return }
        guard index < rows.count else { end(rows.isEmpty ? "设备暂无录音文件" : failedCount > 0 ? "同步结束：成功 \(completedCount)、失败 \(failedCount)、总计 \(totalCount) 个文件" : "同步完成，点击播放本地音频"); return }
        let file = rows[index].file
        if failedThisConnection.contains(file.key) { rows[index].status = "同步失败，断点已保留"; changed?(); downloadNext(index + 1); return }
        if file.size == 0 { rows[index].status = "空文件，无法播放"; changed?(); downloadNext(index + 1); return }
        rows[index].status = "正在同步"; rows[index].received = 0; rows[index].localPath = nil
        message = "正在同步第 \(index + 1) 个文件"; changed?()
        let ticket = next()
        let rate = DemoTransferRate()
        rows[index].kilobytesPerSecond = nil
        cancelDownload = download(file, { [weak self] bytes in
            guard let self, self.busy, self.generation == ticket.0, self.request == ticket.1 else { return }
            self.rows[index].kilobytesPerSecond = rate.sample(bytes: bytes)
            self.rows[index].received = max(0, min(file.size, bytes)); self.changed?()
        }, { [weak self] path, error in
            guard let self, self.accept(ticket) else { return }
            self.cancelDownload = nil
            self.rows[index].kilobytesPerSecond = nil
            if let error {
                if error == "downloadPositionMismatch", !self.stopRequested, !self.isRecording {
                    self.failedThisConnection.insert(file.key); self.rows[index].status = "同步失败，断点已保留"
                    self.changed?(); self.downloadNext(index + 1); return
                }
                self.rows[index].status = self.isRecording ? "录音开始，下载中断" : error
                self.end(self.stopRequested ? "同步已暂停，未完成文件不会用于播放" : error); return
            }
            guard let path else { self.rows[index].status = "缺少本地文件"; self.end("下载未交付完整文件"); return }
            self.rows[index].localPath = path; self.rows[index].received = file.size; self.rows[index].status = "同步完成"
            self.completedRow?(self.rows[index])
            self.changed?(); self.downloadNext(index + 1)
        })
    }
    func phase(file: DemoAudioFile, text: String) {
        guard busy, let index = rows.firstIndex(where: { $0.file.key == file.key && $0.localPath == nil }) else { return }
        rows[index].status = text; message = text; changed?()
    }
    func converting(bytes: Int64, total: Int64) {
        guard busy, let index = rows.firstIndex(where: { $0.localPath == nil && (["正在同步", "检查断点", "继续下载"].contains($0.status) || $0.status.hasPrefix("正在生成音频") || $0.status.hasPrefix("重新封装")) }) else { return }
        let percent = total > 0 ? min(100, max(0, bytes * 100 / total)) : 0
        let label = rows[index].status.hasPrefix("重新封装") ? "重新封装" : "正在生成音频文件"
        rows[index].kilobytesPerSecond = nil
        rows[index].status = "\(label) \(percent)%"
        message = "下载完成，\(label) \(percent)%"; changed?()
    }
    private func end(_ text: String) { busy = false; cancelDownload = nil; message = text; changed?(); finished?() }
}

/// 从 Note 文件名的 Unix 秒时间戳估算；观察到暂停时冻结，不伪造设备时长字段。
final class DemoRecordingClock {
    private var key: String?
    private var state = 0
    private var elapsed: TimeInterval = 0
    private var anchor: TimeInterval = 0
    private(set) var estimated = false
    func update(_ value: DemoRecordingValue, wall: TimeInterval = Date().timeIntervalSince1970, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard value.state == 2 || value.state == 3 else { key = nil; state = value.state; elapsed = 0; estimated = false; return }
        let newKey = "\(value.mode ?? 0):\(value.name ?? "")"
        if key != newKey {
            key = newKey; elapsed = 0
            if let name = value.name?.split(separator: ".").first, !name.isEmpty, name.allSatisfy({ $0.isASCII && $0.isNumber }), let stamp = TimeInterval(name), stamp >= 1746057600, stamp <= wall {
                elapsed = wall - stamp; estimated = true
            } else { estimated = false }
        } else if state == 2 { elapsed += max(0, uptime - anchor) }
        anchor = uptime; state = value.state
    }
    func seconds(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int { Int(elapsed + (state == 2 ? max(0, uptime - anchor) : 0)) }
    static func text(_ seconds: Int) -> String { String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
}

/// 根据进度回调中的新增原始字节计算速率，每至少 0.5 秒更新；1 KB = 1024 字节。
/// 首次回调仅建立基线，续传已有字节不计入本次速率。
final class DemoTransferRate {
    private var anchor: (bytes: Int64, time: TimeInterval)?
    private var rate: Double?
    func sample(bytes: Int64, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double? {
        guard let previous = anchor, bytes >= previous.bytes, now >= previous.time else {
            anchor = (bytes, now); rate = nil; return nil
        }
        let elapsed = now - previous.time
        if elapsed >= 0.5 {
            rate = Double(bytes - previous.bytes) / elapsed / 1024
            anchor = (bytes, now)
        }
        return rate
    }
}
