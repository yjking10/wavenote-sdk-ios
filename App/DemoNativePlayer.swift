import AVFoundation

@MainActor final class DemoNativePlayer: NSObject, @preconcurrency AVAudioPlayerDelegate {
    var changed: (() -> Void)?
    /// 高频进度仅刷新播放控件，不重建页面或干扰滚动。
    var progressChanged: (() -> Void)?
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private var progressTimer: Timer?
    private var completed = false
    var fraction: Float { duration > 0 ? Float(min(1, position / duration)) : 0 }
    var timeText: String { "\(DemoRecordingClock.text(Int(position))) / \(DemoRecordingClock.text(Int(duration)))" }
    private func refreshProgress() {
        if let player { duration = max(0, player.duration); position = completed ? duration : min(duration, max(0, player.currentTime)) }
        progressChanged?()
    }
    private func trackProgress() {
        progressTimer?.invalidate(); progressTimer = nil
        refreshProgress()
        guard playing else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshProgress() }
        }
        progressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private(set) var path: String?
    private(set) var message = ""
    private(set) var preparing = false
    private var player: AVAudioPlayer?
    private var generation = 0
    private let queue = DispatchQueue(label: "demo.playback", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []
    var playing: Bool { player?.isPlaying == true }
    override init() {
        super.init()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if name == AVAudioSession.routeChangeNotification {
                    guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                          raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                } else {
                    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                          raw == AVAudioSession.InterruptionType.began.rawValue else { return }
                }
                Task { @MainActor in self?.stop() }
            })
        }
    }
    deinit { progressTimer?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }
    func toggle(_ source: String) {
        if path == source, let player {
            if player.isPlaying { player.pause(); message = "播放已暂停" }
            else { if completed || player.currentTime >= player.duration { player.currentTime = 0 }; completed = false; message = player.play() ? "正在播放" : "无法恢复播放，请重试" }
            trackProgress(); changed?(); return
        }
        stop(); path = source; preparing = true; message = "正在准备播放…"; changed?()
        let token = generation, url = URL(fileURLWithPath: source)
        let cached = url.deletingPathExtension().appendingPathExtension("playback.caf")
        queue.async {
            let result = Result { () -> URL in
                if FileManager.default.fileExists(atPath: cached.path) { return cached }
                return try DemoOggPlayback.prepare(url, destination: cached)
            }
            DispatchQueue.main.async {
                guard self.generation == token else { return }; self.preparing = false
                do {
                    let playable = try result.get()
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                    try AVAudioSession.sharedInstance().setActive(true)
                    let player = try AVAudioPlayer(contentsOf: playable); player.delegate = self
                    guard player.prepareToPlay(), player.play() else { throw DemoOggPlayback.Failure.unsupported }
                    self.player = player; self.message = "正在播放"; self.trackProgress()
                } catch { self.message = "无法播放此文件，请检查文件完整性、系统音频支持或剩余空间"; self.player = nil }
                self.changed?()
            }
        }
    }
    func stop() {
        progressTimer?.invalidate(); progressTimer = nil; position = 0; duration = 0; completed = false
        generation += 1; player?.stop(); player = nil; preparing = false; path = nil; message = ""
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); changed?()
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        completed = flag; progressTimer?.invalidate(); progressTimer = nil; refreshProgress()
        message = flag ? "播放完成" : "播放未完成"; changed?()
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { guard self.player === player else { return }; stop(); message = "音频解码失败"; changed?() }
}
