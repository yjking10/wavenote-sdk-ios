# WaveNote iOS SDK Demo

本项目展示如何在 iOS 应用中集成 WaveNote SDK，完成设备扫描、绑定、连接、录音控制、设备设置和音频文件同步。本文面向应用开发者；服务端鉴权与账户归属由接入方实现。

可运行参考代码：[Swift](App/SwiftIntegration.swift) · [Objective-C](App/ObjCIntegration.m) · [Identity Provider](App/HTTPIdentityProvider.swift)。

## 集成前提

- iOS 15 及以上；真实 BLE 连接需要真机。
- 将完整的 `WaveNoteSDK.xcframework` 添加到目标的 **Frameworks, Libraries, and Embedded Content**，并设置为 **Embed & Sign**。
- Swift 使用 `import WaveNoteSDK`；Objective-C 使用 `@import WaveNoteSDK;`。
- 所有 SDK API 调用、Completion 和 Delegate 回调均在主线程；耗时 UI 外工作请自行切换至工作线程。
- 在 `Info.plist` 中配置以下权限相关键值：

| 用途 | `Info.plist` 配置 | 是否必需 |
| --- | --- | --- |
| 扫描和连接蓝牙设备 | `NSBluetoothAlwaysUsageDescription`，填写面向用户的蓝牙用途说明。 | 必需 |
| 应用退到后台后继续作为蓝牙中心设备工作 | `UIBackgroundModes` 中加入 `bluetooth-central`。 | 仅需要后台蓝牙时 |
| 连接设备热点或进行局域网传输 | `NSLocalNetworkUsageDescription`，填写面向用户的本地网络用途说明。 | 仅使用热点/局域网传输时 |

蓝牙授权由系统在首次使用时请求。当前 Demo 不请求麦克风、相册、文件或定位权限；Demo 的 [Info.plist](App/Info.plist) 可作为配置参考。

## 运行 Demo 的开发凭据

此配置仅用于本地运行 Demo 和开发设备联调，**不得用于生产应用**。请勿提交真实私钥或把它们写入日志。

1. 复制示例文件为本地配置文件：

   ```bash
   cp App/Config/Secrets.example.plist App/Config/Secrets.plist
   ```

2. 在 `App/Config/Secrets.plist` 中填入 Base64 编码的开发凭据：

   | 键 | 填写内容 |
   | --- | --- |
   | `DEV_CLOUD_PRIVATE_KEY_PKCS8_B64` | 开发环境云服务私钥（PKCS#8）。 |
   | `DEV_AUTH_USER_PUBLIC_KEY_SPKI_B64` | 当前开发用户的公钥（SPKI）。 |
   | `DEV_AUTH_USER_PRIVATE_KEY_PKCS8_B64` | 与上述公钥配对的当前开发用户私钥（PKCS#8）。 |

`Secrets.plist` 已被 Git 忽略，并作为 Demo 的应用资源读取。生产环境应由 `WaveNoteIdentityProvider` 从可信服务或安全存储获取签名与用户密钥材料，绝不能将生产私钥打包进 App。

## 初始化与连接

SDK 使用当前登录用户的稳定标识和宿主实现的 `WaveNoteIdentityProvider` 配置。应用必须强持有 Provider；SDK 对 Delegate 使用弱引用。`configure(with:)` 不会自动开始扫描或连接。

```swift
import WaveNoteSDK

@MainActor
final class NoteManager: NSObject, WaveNoteSDKDelegate {
    private let identityProvider: WaveNoteIdentityProvider
    private let sdk = WaveNoteSDK.shared

    init(identityProvider: WaveNoteIdentityProvider) {
        self.identityProvider = identityProvider
    }

    func start(userIdentifier: String) {
        sdk.delegate = self
        sdk.configure(with: WaveNoteSDKConfiguration(
            userIdentifier: userIdentifier,
            enableAutoReconnect: false,
            identityProvider: identityProvider
        ))
    }

    func scan() {
        sdk.startScanning()
    }

    func waveNoteSDK(_ sdk: WaveNoteSDK, didUpdateDiscoveredDevices devices: [WaveNoteDiscoveredDevice]) {
        // 在界面中展示 devices；用户选择后调用 selectDevice(_:)。
    }

    func selectDevice(_ device: WaveNoteDiscoveredDevice) {
        sdk.bind(device) { [weak self] result in
            switch result {
            case .success:
                self?.sdk.connect(to: device)
            case .failure(let error):
                self?.showError(error)
            }
        }
    }

    func waveNoteSDK(_ sdk: WaveNoteSDK,
                     didChangeConnectionState state: WaveNoteConnectionState,
                     device: WaveNoteDevice?) {
        switch state {
        case .ready:
            refreshDevice()
        case .failed, .disconnected:
            updateDisconnectedUI()
        default:
            break
        }
    }

    func waveNoteSDK(_ sdk: WaveNoteSDK, didReceive error: WaveNoteError) {
        showError(error)
    }

    private func refreshDevice() {}
    private func showError(_ error: WaveNoteError) {}
    private func updateDisconnectedUI() {}
}
```

使用最近一次扫描回调中的 `WaveNoteDiscoveredDevice` 调用 `bind` 或 `connect(to:)`。`bind` 会先确认账户归属：设备未绑定时绑定到当前用户，已属于当前用户时成功，属于其他用户时返回错误。绑定成功后仍需显式调用 `connect(to:)`。

只有连接状态变为 `.ready` 后，才调用设备设置、录音和文件接口。请按 `WaveNoteError.errorCode` 或 `code` 处理错误，不要解析错误文本。需要停止扫描时调用 `stopScanning()`；主动断开时调用 `disconnectDevice()`。

## 设备设置与录音

设备设置查询和控制都要求连接已就绪。查询成功返回最新 `WaveNoteSettingsSnapshot`；设置接口的 Completion 为 `nil` 时，表示设备已确认该操作。

```swift
func refreshDevice(_ sdk: WaveNoteSDK) {
    sdk.deviceSettings.query(.battery) { snapshot, error in
        if error == nil {
            renderBattery(snapshot?.batteryLevel)
        }
    }
}

func startRecording(_ sdk: WaveNoteSDK) {
    sdk.recording.start { error in
        if let error { showError(error) }
    }
}

func stopRecording(_ sdk: WaveNoteSDK) {
    sdk.recording.stop { error in
        if let error { showError(error) }
    }
}
```

调用录音控制前先检查 `sdk.recording.snapshot.state`：仅 `.stopped` 状态可开始，`.recording` 或 `.paused` 状态可停止。可设置 `sdk.recording.delegate` 接收状态更新；Delegate 同样需要由宿主强持有。

Demo 还演示了 `setMicrophoneGain`、`setVibrationGain`、`setAutoPowerOff` 和 `setUSBEnabled`。这些设置均应在设备空闲时调用，并在 Completion 返回成功后更新界面。

## 文件同步与本地音频

设备空闲且连接已就绪后，可按录音模式查询文件。`count` 返回数量，`page` 按页返回文件；使用列表结果创建或直接使用 `WaveNoteFile` 下载。托管下载 `downloadToStorage` 由 SDK 管理当前用户的本地音频，Completion 成功时返回 `WaveNoteLocalAudio`。

```swift
@MainActor
final class AudioSync: NSObject, WaveNoteFilesDelegate {
    private let sdk: WaveNoteSDK

    init(sdk: WaveNoteSDK) {
        self.sdk = sdk
        super.init()
        sdk.files.delegate = self
    }

    func loadFirstPage() {
        sdk.files.page(mode: .note, index: 0) { files, error in
            if error == nil {
                self.renderFiles(files ?? [])
            }
        }
    }

    func download(_ file: WaveNoteFile) {
        sdk.files.downloadToStorage(file, resume: true) { audio, error in
            if let audio, error == nil {
                self.play(audio.url)
            } else if let error {
                self.showError(error)
            }
        }
    }

    func files(_ files: WaveNoteFiles, didUpdate progress: WaveNoteTransferProgress) {
        renderProgress(progress.receivedBytes, progress.totalBytes, progress.state)
    }

    func findLocal(serialNumber: String, mode: WaveNoteRecordMode, fileName: String) {
        sdk.files.findLocalAudio(serialNumber: serialNumber, mode: mode, fileName: fileName) { audio, error in
            if let audio, error == nil { self.play(audio.url) }
        }
    }

    func removeLocal(serialNumber: String, mode: WaveNoteRecordMode, fileName: String) {
        sdk.files.deleteLocalAudio(serialNumber: serialNumber, mode: mode, fileName: fileName) { error in
            if let error { self.showError(error) }
        }
    }

    private func renderFiles(_ files: [WaveNoteFile]) {}
    private func renderProgress(_ received: Int64, _ total: Int64, _ state: WaveNoteOperationState) {}
    private func play(_ url: URL) {}
    private func showError(_ error: WaveNoteError) {}
}
```

下载完成以 Completion 成功且返回 `WaveNoteLocalAudio` 为准；进度回调中的文件仅在状态为 `.completed` 时可视为完整文件。`findLocalAudio` 不要求蓝牙连接；无匹配时回调为 `audio == nil` 且 `error == nil`。`deleteLocalAudio` 只删除 SDK 托管的本地音频，不删除设备文件。

下载、录音和设置操作可能互斥。发起操作后保留返回的 `WaveNoteOperation`；需要由用户取消时调用其 `cancel()`，不要依据不确定结果自动重发可能产生副作用的操作。

## 解绑与退出登录

解绑要求当前设备处于 `.ready` 且空闲状态。它会请求 Provider 完成账户归属解除；在 UI 中应先取得用户确认。

```swift
func unbind(_ sdk: WaveNoteSDK) {
    sdk.unbindCurrentDevice { error in
        if let error { showError(error) }
    }
}

func logout(_ sdk: WaveNoteSDK) {
    sdk.clearConfiguration()
    // 再取消 Provider 的旧请求，清除当前用户的安全缓存和登录态。
}
```

切换用户、Provider 或登录会话时，先调用 `clearConfiguration()`，再配置新用户。该方法会停止当前 SDK 操作并忽略旧会话的迟到回调。

## 服务端与 `WaveNoteIdentityProvider`

`WaveNoteIdentityProvider` 是应用连接 SDK 与接入方账户服务的适配层。接口由 iOS 宿主实现，Provider 从当前登录会话取得凭据并请求服务端；SDK 不接收或持久化登录凭据。

每个方法可在任意队列完成，但**每次调用必须恰好回调一次**。成功时 `error` 为 `nil`；失败时返回适当的 `WaveNoteError`。在 Provider 中不要记录登录凭据、设备序列号、用户标识、签名或密钥材料。

| 方法 | 服务端职责 | 成功结果 |
| --- | --- | --- |
| `checkOwnership(serialNumber:userIdentifier:completion:)` | 校验当前用户与设备的账户归属，不改变绑定状态。 | `.unbound`、`.currentUser` 或 `.anotherUser`。 |
| `bind(serialNumber:userIdentifier:completion:)` | 在完成用户授权后，将未绑定设备绑定给当前用户。 | `error == nil`。 |
| `unbind(serialNumber:userIdentifier:completion:)` | 在完成用户授权后，解除当前用户与设备的账户归属。 | `error == nil`。 |
| `fetchDeviceSignature(serialNumber:userIdentifier:completion:)` | 在设备身份校验需要时，向可信服务获取本次连接所需的设备签名。 | `WaveNoteDeviceSignature`。 |
| `fetchUserKeyPair(userIdentifier:completion:)` | 在设备身份校验需要时，从可信服务或用户安全存储取得当前用户的密钥对。 | `WaveNoteUserKeyPair`。 |

实现要求：

- 每次请求基于当前登录用户授权，服务端不得信任客户端传入的用户标识来替代鉴权。
- `bind` 和 `unbind` 应提供幂等保护，避免网络重试或重复请求产生错误的账户归属。
- 设备签名应针对本次连接获取；用户密钥材料必须来自可信服务或用户安全存储。
- 不要把签名、私钥、登录凭据或其他敏感材料写入 App、日志、代码仓库或 README。

Provider 可参考 [HTTPIdentityProvider.swift](App/HTTPIdentityProvider.swift) 的适配方式。该示例仅用于演示接口调用，接入方应按自己的认证体系实现网络请求、会话失效和安全存储策略。
