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
void DeleteWaveNoteLocalAudio(NSString *sn, WaveNoteRecordMode mode, NSString *name, void (^completion)(WaveNoteError *)) {
    [WaveNoteSDK.sharedSDK.files deleteLocalAudioWithSerialNumber:sn mode:mode fileName:name completion:completion];
}
/// deleteSource=NO 保留设备文件；YES 在本地校验完成后请求删除，删除失败会返回错误且保留本地音频。
WaveNoteOperation *DownloadWaveNoteAudio(WaveNoteFile *file, BOOL resume, BOOL deleteSource, void (^completion)(WaveNoteLocalAudio *, WaveNoteError *)) {
    return [WaveNoteSDK.sharedSDK.files downloadToStorage:file transport:WaveNoteTransferTransportBluetooth resume:resume deleteSource:deleteSource completion:completion];
}
