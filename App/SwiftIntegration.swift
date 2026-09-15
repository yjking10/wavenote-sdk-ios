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
}
