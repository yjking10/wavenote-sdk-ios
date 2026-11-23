# WaveNote iOS SDK Demo

本项目展示如何在 iOS 应用中集成 WaveNote SDK，完成设备扫描、绑定、连接、录音控制、设备设置和音频文件同步。本文面向应用开发者；服务端鉴权与账户归属由接入方实现。

可运行参考代码：[Swift](App/SwiftIntegration.swift) · [Objective-C](App/ObjCIntegration.m) · [Identity Provider](App/HTTPIdentityProvider.swift)。

## 集成前提

- iOS 15.1 及以上；真实 BLE 连接需要真机。
- 将 `WaveNoteSDK.xcframework` 和 `WaveNoteAudioEngine.xcframework` 添加到目标的 **Frameworks, Libraries, and Embedded Content**，并均设置为 **Embed & Sign**。
- Swift 使用 `import WaveNoteSDK`；使用本地音频播放、波形或降噪时另加 `import WaveNoteAudioEngine`。Objective-C 分别使用 `@import WaveNoteSDK;` 和 `@import WaveNoteAudioEngine;`。
- 所有 SDK API 调用、Completion 和 Delegate 回调均在主线程；耗时 UI 外工作请自行切换至工作线程。
- 在 `Info.plist` 中配置以下权限相关键值：

| 用途                                   | `Info.plist` 配置                                                  | 是否必需                |
| -------------------------------------- | ------------------------------------------------------------------ | ----------------------- |
| 扫描和连接蓝牙设备                     | `NSBluetoothAlwaysUsageDescription`，填写面向用户的蓝牙用途说明。  | 必需                    |
| 应用退到后台后继续作为蓝牙中心设备工作 | `UIBackgroundModes` 中加入 `bluetooth-central`。                   | 仅需要后台蓝牙时        |
| 连接设备热点或进行局域网传输           | `NSLocalNetworkUsageDescription`，填写面向用户的本地网络用途说明。 | 仅使用热点/局域网传输时 |

Wi-Fi 快传还需要在 Signing & Capabilities 中启用 **Hotspot Configuration** 和 **Access WiFi Information**。SDK 会读取当前 SSID 以确认已加入目标热点；由于该网络由 App 通过 `NEHotspotConfiguration` 加入，Demo 无需额外请求定位权限。蓝牙授权由系统在首次使用时请求。当前 Demo 不请求麦克风、相册、文件或定位权限；Demo 的 [Info.plist](App/Info.plist) 可作为配置参考。

## 导出 SDK 生产日志

首页右上角“导出日志”在未连接、连接失败或蓝牙关闭时均可使用。点击后后台生成 SDK 生产诊断快照，显示“正在导出…”，完成后打开系统分享面板，可选择系统或已安装 App 提供的保存、发送方式；iPad 使用按钮定位弹出面板。取消分享正常返回，不提示发送成功。

日志为 JSONL，不包含音频或设备端日志。Demo 显式开启后记录关键状态、错误码、阶段和耗时，默认最多 2 MiB／7 天，可通过 `configureProductionDiagnostics` 调整；详细 `openLog` 控制台日志不进入附件。系统临时目录中的导出文件最多保留 24 小时，在启动或后续导出时清理；退出、换用户或清除诊断时提前删除。请在分享完成前保持文件存在。

宿主使用 `sdk.exportDiagnostics { url, error in ... }`，成功后将 URL 交给 `UIActivityViewController`，完整接入见 `App/AppDelegate.swift`。Demo 内已包含本次构建的 SDK XCFramework；旧版本二进制不包含这些接口。SDK 不自行上传诊断；上传和长期保存由宿主管理。

## Audio Engine：本地音频处理

Demo 已引入 `WaveNoteAudioEngine.xcframework`，用于处理 `downloadToStorage` 返回的已完成本地音频。它与设备传输解耦，不能播放正在下载、已取消或不完整的文件。

核心能力包括：

- 单文件播放：准备、播放/暂停/停止、跳转、音量（`0...1`）、倍速（`0.5...2`）和单曲循环；播放器同时只管理一个本地文件。
- 事件流：播放状态、毫秒级位置和时长、播放完成、系统中断/被其他播放器抢占，以及不可恢复错误。
- 实时降噪：提供关闭、轻度、均衡、强力四档；切换是异步的，应根据事件中的“准备完成”或“已绕过”更新 UI。
- 波形提取：从本地文件异步生成归一化 RMS 浮点数组，适用于波形预览；可按采样数或每秒采样密度提取。
- 离线降噪：将本地音频导出为新的 48 kHz、单声道、16-bit PCM WAV 文件。输出 URL 必须是尚不存在的本地 `.wav` 文件。

以下示例使用 Swift 并展示 Demo 采用的高层 API。调用和事件消费均在主线程进行；页面销毁时取消事件任务，并在播放器不再使用时调用 `close()`（关闭后的实例不可复用）。

```swift
import WaveNoteAudioEngine

@MainActor
final class LocalAudioController {
    private let player = WaveNoteAudioPlayer()
    private var eventTask: Task<Void, Never>?

    init() {
        player.setNoiseSuppressionLevel(.balanced)
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.player.events {
                switch event {
                case .position(let position, let duration):
                    self.renderProgress(position, duration)
                case .completed:
                    self.showCompleted()
                case .noiseSuppressionBypassed:
                    self.showNoiseSuppressionUnavailable()
                case .fatalError(let error):
                    self.showError(error)
                default:
                    break
                }
            }
        }
    }

    func open(_ audio: WaveNoteLocalAudio) {
        Task {
            do {
                try await player.prepare(localFile: audio.url)
                try player.setRate(1.25)
                try player.play()
            } catch {
                showError(error)
            }
        }
    }

    func seek(to milliseconds: Int64) {
        try? player.seek(milliseconds: milliseconds)
    }

    func pause() { player.pause() }

    func makeWaveform(for audio: WaveNoteLocalAudio) {
        Task {
            do {
                let samples = try await WaveNoteWaveformExtractor().extract(
                    localFile: audio.url,
                    sampleCount: 240
                )
                renderWaveform(samples)
            } catch {
                showError(error)
            }
        }
    }

    deinit {
        eventTask?.cancel()
        player.close()
    }

    private func renderProgress(_ position: Int64, _ duration: Int64) {}
    private func showCompleted() {}
    private func showNoiseSuppressionUnavailable() {}
    private func renderWaveform(_ samples: [Float]) {}
    private func showError(_ error: Error) {}
}
```

完整的页面适配可参考 [DemoNativePlayer.swift](App/DemoNativePlayer.swift)。若使用 Objective-C，可使用 `WaveNoteAudioEnginePlayer`、`WaveNoteAudioEngineWaveformExtractor` 和 `WaveNoteAudioEngineDenoiser` 这三个同等功能的封装；它们的 Completion 和 Delegate 回调也在主线程。

## 运行 Demo 的开发凭据

此配置仅用于本地运行 Demo 和开发设备联调，**不得用于生产应用**。请勿提交真实私钥或把它们写入日志。

1. 复制示例文件为本地配置文件：

   ```bash
   cp App/Config/Secrets.example.plist App/Config/Secrets.plist
   ```

2. 在 `App/Config/Secrets.plist` 中填入 Base64 编码的开发凭据：

   | 键                                    | 填写内容                                     |
   | ------------------------------------- | -------------------------------------------- |
   | `DEV_CLOUD_PRIVATE_KEY_PKCS8_B64`     | 开发环境云服务私钥（PKCS#8）。               |
   | `DEV_AUTH_USER_PUBLIC_KEY_SPKI_B64`   | 当前开发用户的公钥（SPKI）。                 |
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
            enableAutoReconnect: true,
            reconnectPolicy: .default,
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
        case .reconnecting:
            updateReconnectingUI()
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
    private func updateReconnectingUI() {}
    private func showError(_ error: WaveNoteError) {}
    private func updateDisconnectedUI() {}
}
```

使用最近一次扫描回调中的 `WaveNoteDiscoveredDevice` 调用 `bind` 或 `connect(to:)`。`bind` 会先确认账户归属：设备未绑定时绑定到当前用户，已属于当前用户时成功，属于其他用户时返回错误。绑定成功后仍需显式调用 `connect(to:)`。

只有连接状态变为 `.ready` 后，才调用设备设置、录音和文件接口。请按 `WaveNoteError.errorCode` 或 `code` 处理错误，不要解析错误文本。需要停止扫描时调用 `stopScanning()`；主动断开时调用 `disconnectDevice()`。

## 自动重连

将 `enableAutoReconnect` 设为 `true` 后，SDK 会在设备曾成功进入 `.ready` 且发生可恢复的异常断连时，按当前用户保存的设备 SN 重新扫描、重新执行身份校验并连接。业务层只需根据连接状态更新 UI，**不要**在 `.disconnected`、`.failed` 或错误回调中自行循环调用 `connect(to:)`。

`reconnectPolicy` 决定每轮重连前的等待时间：`.none` 不重连；`.conservative` 为 30/30 秒（2 次）；`.default` 为 0/3/10 秒（3 次）；`.aggressive` 为每 3 秒一次（最多 5 次）。`.aggressive` 仅在前台执行，应用进入后台会暂停当前等待或重扫，回到前台后再评估是否恢复。每次尝试都会进行最长 8 秒的目标设备扫描。

```swift
func waveNoteSDK(_ sdk: WaveNoteSDK,
                 didChangeConnectionState state: WaveNoteConnectionState,
                 device: WaveNoteDevice?) {
    switch state {
    case .reconnecting:
        // 告知用户正在恢复连接；无需再次调用 connect(to:)。
        updateReconnectingUI()
    case .ready:
        // 连接或重连已完成；仅此时恢复依赖 BLE 的操作入口。
        refreshDevice()
    case .disconnected, .failed:
        updateDisconnectedUI()
    default:
        break
    }
}

func retryTapped() {
    // 仅供用户主动点击“重试”时调用；即使自动重连关闭也可使用。
    sdk.reconnectLastDevice()
}
```

`disconnectDevice()` 会取消自动重连并移除当前用户的上次成功连接记录；用户登出或切换账号时调用 `clearConfiguration()`，同样会取消重连。`reconnectLastDevice()` 仅重建连接，不会重放录音、删除、OTA 等有副作用的业务操作；这些操作应由业务在再次收到 `.ready` 后决定是否发起。Wi-Fi 切换、OTA、关机/重启及清空设备等流程期间，SDK 会暂停自动重连以避免冲突。

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

Demo 还演示了 `setMicrophoneGain`、`setVibrationGain`、`setAutoPowerOff`、`setUSBEnabled` 和设备文件 Log 开关。设置页查询 110 后显示状态，调用 `sdk.maintenance.setDeviceLogEnabled` 发送 222 并回读确认；未知状态时禁用开关。设备文件 Log 与 SDK 的 `openLog` 独立。这些设置均应在设备空闲时调用，并在 Completion 返回成功后更新界面。

## 文件同步与本地音频

文件区的 Wi-Fi 快传入口允许在 BLE 同步过程中点击。Demo 会先停止当前下载并保留断点，再通过 `startFastTransfer` 建立热点/TCP，并以 Wi-Fi 从断点继续；结束后调用 `stopFastTransfer` 并等待蓝牙恢复。热点选择最多等待120秒；用户接受系统弹框但热点尚未就绪时，SDK 保留已批准配置并每1秒串行重试，不使用固定预热。用户未确认或主动拒绝时，Demo 不显示错误，等待设备自动关闭热点并恢复蓝牙后继续断点同步。BLE 恢复最多等待60秒，连接失败、蓝牙关闭或超时会结束本轮同步并提示重新扫描；完整建连期限、权限、前台限制或TCP连接等真实故障仍正常提示。

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

| 方法                                                            | 服务端职责                                                                                                                       | 成功结果                                       |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| `checkOwnership(serialNumber:userIdentifier:completion:)`       | 校验当前用户与设备的账户归属，不改变绑定状态。                                                                                   | `.unbound`、`.currentUser` 或 `.anotherUser`。 |
| `bind(serialNumber:userIdentifier:completion:)`                 | 在完成用户授权后，将未绑定设备绑定给当前用户。                                                                                   | `error == nil`。                               |
| `unbind(serialNumber:userIdentifier:completion:)`               | 在完成用户授权后，解除当前用户与设备的账户归属。                                                                                 | `error == nil`。                               |
| `fetchDeviceSignature(serialNumber:userIdentifier:completion:)` | 在设备身份校验需要时，向可信服务获取本次连接所需的设备签名。设备公钥已内置在设备中，云端服务持有对应私钥；App 不在本地生成签名。 | `WaveNoteDeviceSignature`。                    |
| `fetchUserKeyPair(userIdentifier:completion:)`                  | 获取当前用户业务维护的唯一且稳定的 RSA-2048 用户密钥对，供 SDK 在当前连接中完成用户身份校验。                                    | `WaveNoteUserKeyPair`。                        |

实现要求：

- 每次请求基于当前登录用户授权，服务端不得信任客户端传入的用户标识来替代鉴权。
- `bind` 和 `unbind` 应提供幂等保护，避免网络重试或重复请求产生错误的账户归属。
- `fetchDeviceSignature` 应由 App 通过 Provider 请求业务服务端获取签名；设备签名应针对每次连接和自动重连重新获取。云端私钥不得打包进 App、写入本地配置或由 App 本地生成签名。
- `fetchUserKeyPair` 返回的是接入方业务维护的用户密钥对：每个用户应有唯一且稳定的密钥对，公钥和私钥必须严格匹配。App 将密钥对交给 SDK，SDK 仅在设备端内存中用于当前连接认证；断连或认证失败后清除当前会话中的私钥，长期保存由宿主的 Keychain、可信服务或其他安全存储负责。
- 用户公钥用于发送用户身份材料，用户私钥用于解密设备返回的会话材料。密钥格式为：RSA-2048；公钥使用 X.509 SubjectPublicKeyInfo（SPKI）DER 后 Base64 编码，私钥使用 PKCS#8 DER 后 Base64 编码。
- 不需要 X.509 证书，因此没有证书有效期要求，密钥轮换由接入方业务自行管理。
- 不要把签名、私钥、登录凭据或其他敏感材料写入 App、日志、代码仓库或 README。

Provider 可参考 [HTTPIdentityProvider.swift](App/HTTPIdentityProvider.swift) 的适配方式。该示例仅用于演示接口调用，接入方应按自己的认证体系实现网络请求、会话失效和安全存储策略。


## 蓝牙固件升级

设备设置 → 蓝牙固件升级 → 选择固件文件 → 开始升级。完整页面代码见 [BluetoothFirmwareController.swift](App/BluetoothFirmwareController.swift)。

公开 OTA 入口为 `sdk.bluetoothFirmwareUpdate`，用于杰理蓝牙固件。原生依赖已内置，无需 Flutter 或单独接管杰理连接；开始时复用当前已就绪的 BLE 连接，SDK 处理升级期间的必要断开和回连。乐鑫 OTA 仅内部保留实现，暂不提供公共入口。

### 调用前提与接口

- 所有调用、进度代理和 completion 均在主线程。先完成 SDK 配置及连接，等待 `connectionState == .ready`，再由用户确认设备和固件后启动。
- 传入可读、非空、大小不超过 `Int32.max` 字节的本地文件 URL；宿主确认固件适用于当前设备，并在升级期间保持文件内容和访问权限稳定。SDK 不下载固件，也不按文件名判断适配型号。
- 使用系统文件选择器导入 `.ufw` 等固件；从外部文件提供方取得 URL 后，应在有效访问权限内将文件复制到 App 本地目录，耗时复制放到后台。Demo 已实现此流程。
- iOS 蓝牙 OTA 仅支持真机；模拟器调用返回 `operationBlocked`（1106），不会执行刷写。升级期间保持设备供电及 App 前台运行。

以下接口均属于 `sdk.bluetoothFirmwareUpdate`：

| Swift 接口 | Objective-C 对应接口 | 用途 |
| --- | --- | --- |
| `start(fileURL:completion:) -> WaveNoteOperation` | `startWithFileURL:completion:` | 启动升级；completion 在本次升级结束或请求被拒绝时回调一次，`nil` 表示原生确认升级成功 |
| `delegate` | `delegate` | 接收 `WaveNoteBluetoothFirmwareUpdateDelegate` 进度；弱引用，宿主必须保持代理存活 |
| `snapshot` | `snapshot` | 读取最近的 `WaveNoteOTAProgress?`；初始为 `nil`，终态保留到后续已接受的操作更新 |
| `cancel(completion:)` | `cancelWithCompletion:` | 请求原生取消；以 completion 和后续终态确认结果 |

### 完整 Swift 示例

将下面的客户端作为页面或业务控制器的属性持有，覆盖整次升级生命周期；不要只在点击事件中创建临时代理。调用 `start(fileURL:)` 时传入已导入 App 本地目录的固件 URL。

```swift
import Foundation
import WaveNoteSDK

@MainActor
final class BluetoothOTAClient: NSObject, WaveNoteBluetoothFirmwareUpdateDelegate {
    private let updater: WaveNoteBluetoothFirmwareUpdate

    init(sdk: WaveNoteSDK) {
        updater = sdk.bluetoothFirmwareUpdate
        super.init()
        updater.delegate = self
    }

    var snapshot: WaveNoteOTAProgress? { updater.snapshot }

    @discardableResult
    func start(fileURL: URL) -> WaveNoteOperation {
        updater.start(fileURL: fileURL) { error in
            if let error {
                if error.errorCode == .operationCancelled {
                    print("蓝牙固件升级已取消")
                } else {
                    print("OTA 未完成 code=\(error.code) operation=\(error.operation)")
                }
            } else {
                print("固件升级成功，业务连接就绪另看 SDK 连接代理")
            }
        }
    }

    func cancel() {
        guard updater.snapshot?.canCancel == true else {
            print("当前阶段不可取消")
            return
        }
        updater.cancel { error in
            if let error {
                print("取消未确认 code=\(error.code) operation=\(error.operation)")
            } else {
                print("原生已确认取消，等待升级终态回调")
            }
        }
    }

    func bluetoothFirmwareUpdate(_ updater: WaveNoteBluetoothFirmwareUpdate,
                                 didUpdate progress: WaveNoteOTAProgress) {
        // 在此更新阶段、进度条和取消按钮；按钮可用性使用 canCancel。
        print("OTA state=\(progress.state.rawValue) progress=\(progress.progress)% canCancel=\(progress.canCancel)")
    }
}
```

宿主持有客户端后调用 `client.start(fileURL: localFirmwareURL)`；页面重绘可读取 `client.snapshot`，用户点击取消时调用 `client.cancel()`。返回令牌的 `identifier` 与进度的 `operationID` 对应；释放令牌不会取消升级。需要处理取消结果时使用管理器的 `cancel(completion:)`，令牌 `cancel()` 也只发起请求，不保证设备退出刷写。

### 进度字段与状态枚举

| `WaveNoteOTAProgress` 字段 | 含义 |
| --- | --- |
| `operationID: UUID` | 本地操作标识，用于区分任务及其回调 |
| `state: WaveNoteOTAState` | 当前统一阶段，见下表 |
| `progress: Int` | 0…100；初始准备为 0，升级阶段最多 99，只有明确成功才为 100 |
| `canCancel: Bool` | 当前原生阶段是否允许请求取消 |
| `error: WaveNoteError?` | 当前进度携带的失败或取消原因；也须处理 start 的 completion |
| `nativeErrorCode: NSNumber?` | 原生数值诊断代码；业务判断使用 `error.code` 或 `error.errorCode` |

两端状态数值一致，但不保证每次升级都会经过全部阶段：

| 数值 | `WaveNoteOTAState` | 含义与 UI 处理 |
| --- | --- | --- |
| 0 | `.preparing` | 准备、认证或 Loader 准备，显示准备状态 |
| 1 | `.upgrading` | 正在传输或执行固件升级，显示进度及 `canCancel` |
| 2 | `.reconnecting` | SDK 正在处理升级所需回连，等待状态推进 |
| 3 | `.rebooting` | 原生明确进入重启阶段时报告，等待结果 |
| 4 | `.completed` | 原生明确确认升级成功，进度为 100 |
| 5 | `.cancelled` | 本次升级已取消；不表示设备已回滚 |
| 6 | `.failed` | 本次升级失败，按错误码提示并结束本次操作 |

升级进度非递减；回连后的准备、重启、取消或失败保留已有百分比。写入成功、上传完毕、99%、断连或重启都不能单独作为升级成功依据。成功或原生确认取消后，SDK 尝试恢复业务连接；业务可用以 SDK 连接代理报告 `.ready` 为准，恢复失败不会改写已确认的 OTA 成功结果。

取消按钮使用 `snapshot?.canCancel == true`；阶段可能在点击时变化，因此仍须处理取消 completion。拒绝取消返回 `operationBlocked`（1106），5 秒未确认返回 `operationOutcomeUnknown`（1203），随后以原任务的真实终态为准。已确认取消时，原始 start completion 会返回 `operationCancelled`（1017）。

### OTA 错误码 1301–1309

业务使用 `WaveNoteError.code` 或 `errorCode` 判断；`operation` 用于诊断定位，不解析错误正文或原生数值来替代稳定错误码。拒绝升级不会自动停止录音、取消传输或关闭设备 Wi-Fi。

| 错误码 | `WaveNoteErrorCode` | 原因 | 处理方式 |
| --- | --- | --- | --- |
| 1301 | `.otaRecordingActive` | 正在录音或暂停录音 | 先结束录音；暂停仍不可升级 |
| 1302 | `.otaFileTransferActive` | BLE/Wi-Fi 文件传输、续传、转换或收尾未完成 | 等待整个任务完成 |
| 1303 | `.otaLiveAudioActive` | 实时音频运行中或停止中 | 先结束实时流并等待停止确认 |
| 1304 | `.otaWiFiActive` | 设备 Wi-Fi 快传开启、使用、关闭或恢复 BLE 中 | 结束快传，等待业务连接恢复 `.ready` |
| 1305 | `.otaAlreadyInProgress` | 已有 OTA、前置检查或原生 OTA 事务 | 等待当前任务结束，避免重复提交 |
| 1306 | `.otaUSBActive` | 已确认 USB 连接或挂载 | 断开 USB，等待设备上报断开状态 |
| 1307 | `.otaDeviceBusy` | 设置、删除、维护、身份或其他控制事务未完成 | 等待控制事务结束 |
| 1308 | `.otaDeviceStateUnavailable` | 状态查询失败、录音状态未知或 USB 明确上报无效值 | 重新连接并确认设备状态后再由用户重试 |
| 1309 | `.otaPowerInsufficient` | 设备或原生 SDK 明确报告电量/电压不足 | 先充电，再由用户重新发起 |

新 BLE 会话就绪且没有收到 USB 上报时，默认 USB 未连接；有效 `116` 通知或 `102.usb_connect` 更新本会话状态，`usb_state` 只表示功能开关。仅未收到 USB 上报不会触发 1308，录音状态仍须确认停止；状态查询超时会关闭不确定会话。SDK 不盲目重发超时指令，也不自行设定低电量百分比阈值。单纯充电、开启边录边传选项但没有活动流，不单独禁止 OTA。

连接、权限、本地文件、取消及升级阶段失败仍沿用 SDK 的其他错误码。固件正确性、真实刷写、回连、取消及成功后的业务连接恢复须在指定真机单独验收；文档示例和编译通过不代表真机 OTA 已通过。
