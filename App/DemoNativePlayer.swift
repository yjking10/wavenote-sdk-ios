import Foundation
import WaveNoteAudioEngine

/// Demo 对 WaveNoteAudioEngine 的主线程适配层；不记录本地路径或音频载荷。
@MainActor final class DemoNativePlayer {
    var changed: (() -> Void)?
    /// 高频进度仅供当前播放器页面刷新，避免重建文件列表。
    var progressChanged: (() -> Void)?

    private let player = WaveNoteAudioPlayer()
    private var eventTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var observers: [UUID: () -> Void] = [:]
    private var generation = 0

    private(set) var path: String?
    private(set) var message = ""
    private(set) var preparing = false
    private(set) var positionMilliseconds: Int64 = 0
    private(set) var durationMilliseconds: Int64 = 0
    private(set) var waveformSamples: [Float] = []
    private(set) var waveformLoading = false
    private(set) var noiseLevel: NoiseSuppressionLevel = .balanced

    var playing: Bool { player.state == .playing }
    var fraction: Float {
        guard durationMilliseconds > 0 else { return 0 }
        return Float(min(1, Double(positionMilliseconds) / Double(durationMilliseconds)))
    }
    var timeText: String {
        "\(Self.timeText(milliseconds: positionMilliseconds)) / \(Self.timeText(milliseconds: durationMilliseconds))"
    }
    var noiseTitle: String {
        switch noiseLevel {
        case .off: return "关闭"
        case .light: return "轻度"
        case .balanced: return "均衡"
        case .strong: return "强力"
        }
    }

    init() {
        player.setNoiseSuppressionLevel(.balanced)
        let events = player.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    deinit {
        eventTask?.cancel()
        waveformTask?.cancel()
    }

    @discardableResult
    func observe(_ callback: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = callback
        return token
    }

    func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    /// 打开已完成传输的本地文件。准备完成后由页面上的播放键开始播放。
    func load(_ source: String, waveformSampleCount: Int) {
        guard FileManager.default.fileExists(atPath: source) else {
            message = "本地音频文件已不存在，请重新同步。"
            notify()
            return
        }

        generation += 1
        let token = generation
        waveformTask?.cancel()
        player.stop()
        path = source
        preparing = true
        positionMilliseconds = 0
        durationMilliseconds = 0
        waveformSamples = []
        waveformLoading = true
        message = "正在准备播放…"
        notify()

        let url = URL(fileURLWithPath: source)
        Task { [weak self] in
            do {
                try await self?.player.prepare(localFile: url)
                guard let self, self.generation == token else { return }
                self.preparing = false
                self.message = "准备就绪"
                self.notify()
            } catch {
                guard let self, self.generation == token else { return }
                self.preparing = false
                self.message = "无法准备此音频，请检查文件完整性或剩余空间。"
                self.notify()
            }
        }

        extractWaveform(from: url, sampleCount: waveformSampleCount, generation: token)
    }

    /// 适配横竖屏宽度时只更新可视波形，不影响已准备好的播放会话。
    func reloadWaveform(sampleCount: Int) {
        guard let path else { return }
        waveformTask?.cancel()
        waveformLoading = true
        notify()
        extractWaveform(from: URL(fileURLWithPath: path), sampleCount: sampleCount, generation: generation)
    }

    func setNoiseSuppressionLevel(_ level: NoiseSuppressionLevel) {
        guard noiseLevel != level else { return }
        noiseLevel = level
        player.setNoiseSuppressionLevel(level)
        message = "降噪已设为\(noiseTitle)"
        notify()
    }

    private func extractWaveform(from url: URL, sampleCount: Int, generation token: Int) {
        waveformTask = Task { [weak self] in
            do {
                let samples = try await WaveNoteWaveformExtractor().extract(localFile: url, sampleCount: max(1, sampleCount))
                guard let self, self.generation == token else { return }
                self.waveformSamples = samples
                self.waveformLoading = false
                self.notify()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == token else { return }
                self.waveformLoading = false
                self.message = "波形生成失败，仍可尝试播放音频。"
                self.notify()
            }
        }
    }

    func toggle() {
        guard path != nil, !preparing else { return }
        if playing {
            player.pause()
            message = "播放已暂停"
        } else {
            do {
                try player.play()
                message = "正在播放"
            } catch {
                message = "无法开始播放，请重新打开该音频。"
            }
        }
        notify()
    }

    func seek(to milliseconds: Int64) {
        guard durationMilliseconds > 0, !preparing else { return }
        let target = min(max(milliseconds, 0), durationMilliseconds)
        do {
            try player.seek(milliseconds: target)
            positionMilliseconds = target
        } catch {
            message = "无法跳转播放位置。"
        }
        notify()
    }

    func skip(seconds: Int64) {
        seek(to: positionMilliseconds + seconds * 1_000)
    }

    func stop() {
        generation += 1
        waveformTask?.cancel()
        waveformTask = nil
        player.stop()
        path = nil
        preparing = false
        positionMilliseconds = 0
        durationMilliseconds = 0
        waveformSamples = []
        waveformLoading = false
        message = ""
        notify()
    }

    private func apply(_ event: PlayerEvent) {
        switch event {
        case .stateChanged(let state):
            if state == .preparing { preparing = true }
            if state == .ready || state == .playing || state == .paused || state == .completed { preparing = false }
            if state == .completed { message = "播放完成" }
            if state == .failed { message = "音频播放失败。" }
            notify()
        case .position(let milliseconds, let duration):
            positionMilliseconds = max(0, milliseconds)
            durationMilliseconds = max(0, duration)
            notify(progressOnly: true)
        case .completed:
            message = "播放完成"
            notify()
        case .systemInterrupted:
            message = "播放已被系统中断"
            notify()
        case .preemptedByAnotherPlayer:
            message = "播放已被其他音频占用"
            notify()
        case .noiseSuppressionPreparing:
            message = "正在应用\(noiseTitle)降噪…"
            notify()
        case .noiseSuppressionReady:
            message = "降噪已启用：\(noiseTitle)"
            notify()
        case .noiseSuppressionBypassed:
            message = "当前音频暂不支持降噪，将按原音播放。"
            notify()
        case .noiseSuppressionRecovered:
            message = "降噪已恢复：\(noiseTitle)"
            notify()
        case .fatalError:
            preparing = false
            message = "播放器发生错误，请重新打开该音频。"
            notify()
        }
    }

    private func notify(progressOnly: Bool = false) {
        if progressOnly { progressChanged?() } else { changed?() }
        observers.values.forEach { $0() }
    }

    static func timeText(milliseconds: Int64) -> String {
        let seconds = max(milliseconds, 0) / 1_000
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }
}
