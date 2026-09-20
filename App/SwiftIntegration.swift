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
    /// 仅删除 SDK 托管的本地音频和续传数据，不删除设备文件。
    static func deleteLocalAudio(_ sdk: WaveNoteSDK, sn: String, mode: WaveNoteRecordMode, name: String, completion: @escaping (WaveNoteError?) -> Void) {
        sdk.files.deleteLocalAudio(serialNumber: sn, mode: mode, fileName: name, completion: completion)
    }
    /// READY 后显式下载或恢复；默认保留设备文件。删除失败时本地已完成音频仍保留。
    static func download(_ sdk: WaveNoteSDK, file: WaveNoteFile, resume: Bool, deleteSource: Bool = false, completion: @escaping (WaveNoteLocalAudio?, WaveNoteError?) -> Void) -> WaveNoteOperation {
        sdk.files.downloadToStorage(file, resume: resume, deleteSource: deleteSource, completion: completion)
    }
}
