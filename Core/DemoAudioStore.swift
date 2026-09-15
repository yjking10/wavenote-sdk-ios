import Foundation
import CryptoKit

/// 只把 SDK 成功交付的 Ogg 写入索引；partial 永不作为可播放项。
/// 使用 SN 摘要目录 + 模式/名称/原始大小摘要，避免设备与同名文件互相覆盖。
final class DemoAudioStore: Sendable {
    private let root: URL
    init(root: URL) { self.root = root }
    private struct Marker: Codable { let name: String; let bytes: Int64 }
    private func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func directory(_ sn: String, _ file: DemoAudioFile) -> URL { root.appendingPathComponent(digest(sn)).appendingPathComponent(digest(file.key)) }
    func prepare(sn: String, file: DemoAudioFile) throws -> (destination: URL, cached: Bool) {
        let dir = directory(sn, file), fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = dir.appendingPathComponent("complete.json")
        if let data = try? Data(contentsOf: marker), let saved = try? JSONDecoder().decode(Marker.self, from: data),
           saved.name == URL(fileURLWithPath: saved.name).lastPathComponent, saved.name.hasSuffix(".ogg"), saved.bytes > 0 {
            let url = dir.appendingPathComponent(saved.name)
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber, size.int64Value == saved.bytes { return (url, true) }
        }
        // 重试使用新目标；不把旧 partial 大小当续传偏移，也不覆盖上次文件。
        return (dir.appendingPathComponent(UUID().uuidString + ".ogg"), false)
    }
    func commit(_ url: URL, sn: String, file: DemoAudioFile) throws {
        guard url.deletingLastPathComponent() == directory(sn, file), url.pathExtension == "ogg",
              let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber, size.int64Value > 0 else { throw CocoaError(.fileReadCorruptFile) }
        try JSONEncoder().encode(Marker(name: url.lastPathComponent, bytes: size.int64Value)).write(to: directory(sn, file).appendingPathComponent("complete.json"), options: .atomic)
    }
}
