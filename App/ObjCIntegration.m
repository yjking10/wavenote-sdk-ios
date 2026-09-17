#import <Foundation/Foundation.h>
#import <WaveNoteSDK/WaveNoteSDK-Swift.h>
/// 可复制的 Objective-C 接入；宿主持有 provider 和 delegate，凭据只由运行时传入。
void ConfigureWaveNote(NSString *token, NSString *user, id<WaveNoteIdentityProvider> provider, id<WaveNoteSDKDelegate> delegate) {
    WaveNoteSDK *sdk = WaveNoteSDK.sharedSDK;
    sdk.delegate = delegate;
    [sdk configureWithConfiguration:[[WaveNoteSDKConfiguration alloc] initWithAPIKey:token userIdentifier:user enableAutoReconnect:NO reconnectPolicy:WaveNoteReconnectPolicyNone identityProvider:provider]];
}
void QueryWaveNoteBattery(void (^completion)(WaveNoteSettingsSnapshot *, WaveNoteError *)) {
    [WaveNoteSDK.sharedSDK.deviceSettings query:WaveNoteSettingBattery completion:completion];
}
void UnbindWaveNote(void (^completion)(WaveNoteError *)) {
    [WaveNoteSDK.sharedSDK unbindCurrentDeviceWithCompletion:completion];
}

void FindWaveNoteAudio(NSString *sn, WaveNoteRecordMode mode, NSString *name, void (^completion)(WaveNoteLocalAudio *, WaveNoteError *)) {
    [WaveNoteSDK.sharedSDK.files findLocalAudioWithSerialNumber:sn mode:mode fileName:name completion:completion];
}
WaveNoteOperation *DownloadWaveNoteAudio(WaveNoteFile *file, BOOL resume, void (^completion)(WaveNoteLocalAudio *, WaveNoteError *)) {
    return [WaveNoteSDK.sharedSDK.files downloadToStorage:file transport:WaveNoteTransferTransportBluetooth resume:resume completion:completion];
}
