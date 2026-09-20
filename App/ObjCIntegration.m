#import <Foundation/Foundation.h>
#import <WaveNoteSDK/WaveNoteSDK-Swift.h>
/// 可复制的 Objective-C 接入；宿主持有 provider、delegate 和登录凭据。
void ConfigureWaveNote(NSString *user, id<WaveNoteIdentityProvider> provider, id<WaveNoteSDKDelegate> delegate) {
    WaveNoteSDK *sdk = WaveNoteSDK.sharedSDK;
    sdk.delegate = delegate;
    [sdk configureWithConfiguration:[[WaveNoteSDKConfiguration alloc] initWithUserIdentifier:user enableAutoReconnect:NO reconnectPolicy:WaveNoteReconnectPolicyNone identityProvider:provider]];
}
void ClearWaveNoteForLogout(void) { [WaveNoteSDK.sharedSDK clearConfiguration]; }
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
