import Foundation
import WaveNoteSDK

/// 宿主持有传入的 provider 和 delegate；在主线程调用。
@MainActor enum SwiftIntegration {
    static func configure(token: String, user: String, provider: WaveNoteIdentityProvider, delegate: WaveNoteSDKDelegate) -> WaveNoteSDK {
        let sdk = WaveNoteSDK.shared
        sdk.delegate = delegate
        sdk.configure(with: WaveNoteSDKConfiguration(apiKey: token, userIdentifier: user, enableAutoReconnect: false, identityProvider: provider))
        return sdk
    }
    /// READY 后调用；error 非 nil 时不得使用快照。
    static func battery(_ sdk: WaveNoteSDK, completion: @escaping (WaveNoteSettingsSnapshot?, WaveNoteError?) -> Void) {
        sdk.deviceSettings.query(.battery, completion: completion)
    }
    /// 指定设备查询当前用户本地音频，无需连接；nil/nil 表示尚未下载。
    static func localAudio(_ sdk: WaveNoteSDK, sn: String, mode: WaveNoteRecordMode, name: String, completion: @escaping (WaveNoteLocalAudio?, WaveNoteError?) -> Void) {
        sdk.files.findLocalAudio(serialNumber: sn, mode: mode, fileName: name, completion: completion)
    }
    /// READY 后显式下载或恢复；SDK 自动选择用户目录并持久化索引。
    static func download(_ sdk: WaveNoteSDK, file: WaveNoteFile, resume: Bool, completion: @escaping (WaveNoteLocalAudio?, WaveNoteError?) -> Void) -> WaveNoteOperation {
        sdk.files.downloadToStorage(file, resume: resume, completion: completion)
    }
}
