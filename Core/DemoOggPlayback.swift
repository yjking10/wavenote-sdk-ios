import Foundation
import AVFoundation

/// Demo 层容器适配：保留 SDK 的 Ogg，使用系统 Opus 解码器生成可播放的 PCM CAF。
/// 不引入第三方播放器/解码器；按页读取，内存上限为一个 Ogg 页及一个 Opus 包。
enum DemoOggPlayback {
    static func prepare(_ source: URL, destination: URL) throws -> URL {
        let reader = try Reader(source)
        defer { reader.close() }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: reader.channels, mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let output = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: reader.channels),
              let converter = AVAudioConverter(from: input, to: output),
              let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 5760) else { throw Failure.unsupported }
        converter.primeMethod = .none
        // Reader 已校验 SDK 输出 pre-skip=0；禁用系统默认 120 帧的预热裁剪。
        converter.primeInfo = AVAudioConverterPrimeInfo(leadingFrames: 0, trailingFrames: 0)
        let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: 65_536)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".caf")
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: temporary) } }
        do {
            let file = try AVAudioFile(forWriting: temporary, settings: output.settings)
            var readError: Error?
            while true {
                var error: NSError?
                let state = converter.convert(to: pcm, error: &error) { _, status in
                    do {
                        guard let packet = try reader.next() else { status.pointee = .endOfStream; return nil }
                        packet.withUnsafeBytes { raw in compressed.data.copyMemory(from: raw.baseAddress!, byteCount: packet.count) }
                        compressed.byteLength = UInt32(packet.count); compressed.packetCount = 1
                        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: UInt32(try Reader.samples(packet)), mDataByteSize: UInt32(packet.count))
                        status.pointee = .haveData; return compressed
                    } catch { readError = error; status.pointee = .endOfStream; return nil }
                }
                if let readError { throw readError }
                if let error { throw error }
                if pcm.frameLength > 0 { try file.write(from: pcm) }
                if state == .endOfStream { break }
                if state == .error || (state == .inputRanDry && pcm.frameLength == 0) { throw Failure.corrupt }
            }
            guard reader.ended, file.length > 0 else { throw Failure.corrupt }
        }
        try FileManager.default.moveItem(at: temporary, to: destination); complete = true
        return destination
    }
    enum Failure: Error { case corrupt, unsupported }
    private final class Reader {
        let handle: FileHandle
        var channels: UInt32 = 0
        private var sequence: UInt64 = 0
        private var serial: UInt64?
        private var pending = Data()
        private var packets: [Data] = []
        private var headers = 0
        private var frames: UInt64 = 0
        private(set) var ended = false
        init(_ url: URL) throws {
            handle = try FileHandle(forReadingFrom: url)
            do { while headers < 2 { try page() } } catch { try? handle.close(); throw error }
        }
        func close() { try? handle.close() }
        func next() throws -> Data? {
            while packets.isEmpty && !ended { try page() }
            return packets.isEmpty ? nil : packets.removeFirst()
        }
        private func read(_ count: Int) throws -> Data {
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw Failure.corrupt }; return data
        }
        private func page() throws {
            let fixed = try read(27)
            guard fixed.prefix(4) == Data("OggS".utf8), fixed[4] == 0, fixed[5] & ~7 == 0 else { throw Failure.corrupt }
            let table = try read(Int(fixed[26])), body = try read(table.reduce(0) { $0 + Int($1) })
            var full = fixed + table + body
            let checksum = Self.little(fixed, 22, 4)
            full.replaceSubrange(22..<26, with: [0,0,0,0])
            guard UInt64(Self.crc(full)) == checksum, Self.little(fixed, 18, 4) == sequence,
                  (sequence == 0 ? fixed[5] & 2 != 0 : fixed[5] & 2 == 0),
                  (fixed[5] & 1 != 0) == !pending.isEmpty else { throw Failure.corrupt }
            let id = Self.little(fixed, 14, 4)
            guard serial == nil || serial == id else { throw Failure.corrupt }; serial = id; sequence += 1
            var offset = 0
            for length in table {
                pending.append(body.subdata(in: offset..<(offset + Int(length)))); offset += Int(length)
                guard pending.count <= 65_536 else { throw Failure.corrupt }
                if length < 255 {
                    if headers == 0 {
                        guard pending.count == 19, pending.prefix(8) == Data("OpusHead".utf8), pending[8] == 1,
                              [1,2].contains(pending[9]), Self.little(pending, 10, 2) == 0, Self.little(pending, 16, 2) == 0, pending[18] == 0 else { throw Failure.unsupported }
                        channels = UInt32(pending[9]); headers += 1
                    } else if headers == 1 {
                        guard pending.prefix(8) == Data("OpusTags".utf8) else { throw Failure.corrupt }; headers += 1
                    } else { frames += UInt64(try Self.samples(pending)); packets.append(pending) }
                    pending = Data()
                }
            }
            if fixed[5] & 4 != 0 {
                guard headers == 2, pending.isEmpty, frames > 0, Self.little(fixed, 6, 8) == frames,
                      (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw Failure.corrupt }
                ended = true
            }
        }
        static func little(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 { (0..<count).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) } }
        static func crc(_ bytes: Data) -> UInt32 {
            var value: UInt32 = 0
            for byte in bytes { value ^= UInt32(byte) << 24; for _ in 0..<8 { value = value & 0x80000000 == 0 ? value << 1 : (value << 1) ^ 0x04c11db7 } }
            return value
        }
        static func samples(_ packet: Data) throws -> Int {
            guard let toc = packet.first else { throw Failure.corrupt }
            let frame: Int
            if toc & 0x80 != 0 { frame = 120 << ((toc >> 3) & 3) }
            else if toc & 0x60 == 0x60 { frame = toc & 8 != 0 ? 960 : 480 }
            else { let value = Int((toc >> 3) & 3); frame = value == 3 ? 2880 : 480 << value }
            let count: Int
            switch toc & 3 { case 0: count = 1; case 1, 2: count = 2; default: guard packet.count > 1 else { throw Failure.corrupt }; count = Int(packet[1] & 63) }
            guard count > 0, count * frame <= 5760 else { throw Failure.corrupt }; return count * frame
        }
    }
}
