import UIKit
import CryptoKit
import Security
import WaveNoteSDK

private enum Secrets {
    private static let values: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist") else {
            fatalError("Secrets.plist not found")
        }

        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else {
            fatalError("Unable to read Secrets.plist")
        }

        return dictionary
    }()

    static var devicePrivateKey: String {
        value(for: "DEV_AUTH_USER_PRIVATE_KEY_PKCS8_B64")
    }

    static var devicePublicKey: String {
        value(for: "DEV_AUTH_USER_PUBLIC_KEY_SPKI_B64")
    }

    static var serverPrivateKey: String {
        value(for: "DEV_CLOUD_PRIVATE_KEY_PKCS8_B64")
    }

    private static func value(for key: String) -> String {
        guard let value = values[key] as? String, !value.isEmpty else {
            fatalError("\(key) not configured")
        }
        return value
    }
}

/// 模拟身份在 Debug / Release 均明确启用，仅用于独立演示。
final class DemoIdentityProvider: NSObject, WaveNoteIdentityProvider {
    private let store: DemoOwnershipStore
    override init() {
        let defaults = UserDefaults.standard
        store = DemoOwnershipStore(read: { defaults.dictionary(forKey: "demo.ownership") as? [String: String] ?? [:] },
                                   write: { defaults.set($0, forKey: "demo.ownership") })
        super.init()
    }
    private func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    func isBound(_ sn: String) -> Bool { store.owner(hash(sn)) == hash("demo-user") }
    func checkOwnership(serialNumber: String, userIdentifier: String, completion: @escaping (WaveNoteOwnership, WaveNoteError?) -> Void) {
        let owner = store.owner(hash(serialNumber))
        completion(owner == nil ? .unbound : owner == hash(userIdentifier) ? .currentUser : .anotherUser, nil)
    }
    func bind(serialNumber: String, userIdentifier: String, completion: @escaping (WaveNoteError?) -> Void) {
        completion(store.bind(hash(serialNumber), user: hash(userIdentifier)) ? nil : WaveNoteError(.deviceBoundToAnotherUser, operation: "bind", message: "设备已属于其他演示账户"))
    }
    func unbind(serialNumber: String, userIdentifier: String, completion: @escaping (WaveNoteError?) -> Void) {
        completion(store.unbind(hash(serialNumber), user: hash(userIdentifier)) ? nil : WaveNoteError(.cloudUnbindFailed, operation: "unbind", message: "模拟归属不匹配"))
    }
    /// Development only. Production must request the SN signature and user key pair from cloud;
    /// never ship a production cloud private key in an App bundle, log, or repository.
    func fetchDeviceSignature(serialNumber: String, userIdentifier: String,
                              completion: @escaping (WaveNoteDeviceSignature?, WaveNoteError?) -> Void) {
        guard let key = DemoRSA.privateKey(pkcs8Base64: Secrets.serverPrivateKey),
              let signature = DemoRSA.sign(serialNumber, key: key) else {
            completion(nil, WaveNoteError(.identityProviderUnavailable, operation: "deviceSignature", message: "缺少本地开发签名配置")); return
        }
        completion(WaveNoteDeviceSignature(serialSignatureBase64: signature), nil)
    }
    func fetchUserKeyPair(userIdentifier: String,
                          completion: @escaping (WaveNoteUserKeyPair?, WaveNoteError?) -> Void) {
        completion(WaveNoteUserKeyPair(userPublicKeySPKIBase64: Secrets.devicePublicKey, userPrivateKeyPKCS8Base64: Secrets.devicePrivateKey), nil)
    }
}

/// Parses local development-only PKCS#8 material without writing it to logs or UserDefaults.
private enum DemoRSA {
    static func privateKey(pkcs8Base64: String) -> SecKey? {
        guard let der = Data(base64Encoded: pkcs8Base64) else { return nil }
        return SecKeyCreateWithData(pkcs8InnerKey(der) as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)
    }
    static func sign(_ serial: String, key: SecKey) -> String? {
        var error: Unmanaged<CFError>?
        guard let value = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(serial.utf8) as CFData, &error) as Data? else { return nil }
        return value.base64EncodedString()
    }
    private static func pkcs8InnerKey(_ der: Data) -> Data {
        func fields(_ data: Data) -> [(UInt8, Data)] {
            var index = 0; var values: [(UInt8, Data)] = []
            while index + 2 <= data.count {
                let tag = data[index]; index += 1; var length = Int(data[index]); index += 1
                if length & 0x80 != 0 { let bytes = length & 0x7f; guard bytes > 0, bytes <= 4, index + bytes <= data.count else { return [] }; length = 0; for _ in 0..<bytes { length = length << 8 | Int(data[index]); index += 1 } }
                guard index + length <= data.count else { return [] }; values.append((tag, data.subdata(in: index..<(index + length)))); index += length
            }; return values
        }
        guard let outer = fields(der).first(where: { $0.0 == 0x30 })?.1 else { return Data() }
        return fields(outer).first(where: { $0.0 == 0x04 })?.1 ?? Data()
    }
}

@MainActor final class DemoController: NSObject, WaveNoteSDKDelegate, WaveNoteDeviceSettingsDelegate, WaveNoteRecordingDelegate, WaveNoteFilesDelegate, WaveNoteWiFiDelegate {
    let sdk = WaveNoteSDK.shared
    let identity = DemoIdentityProvider()
    let flow = DemoFlow()
    let library = DemoAudioLibrary()
    let recordingClock = DemoRecordingClock()
    let player = DemoNativePlayer()
    private var libraryToken: Int?
    private var audioSession = 0
    private var scheduledSync = 0
    private var progressFile: DemoAudioFile?
    // 单调时钟：仅统计 finishing 到 completion，包含收尾和索引提交，不含传输。
    private var oggStartedAt: TimeInterval?
    private var progressID: UUID?
    private var progressCallback: ((Int64) -> Void)?
    private var syncTransport: WaveNoteTransferTransport = .bluetooth
    private var syncSerialNumber: String?
    private var wifiWorkflow = false
    private var wifiOpenOperation: WaveNoteOperation?
    private var wifiResult = ""
    var changed: (() -> Void)?
    var devices: [WaveNoteDiscoveredDevice] = []
    var snapshot: WaveNoteSettingsSnapshot?
    var mode: Int?
    var status = "点击开始扫描，选择身边的 Note 设备。"
    var bluetooth = "正在检查蓝牙状态"
    var wifiTransferActive: Bool { wifiWorkflow }
    var wifiButtonTitle: String { wifiWorkflow ? "关闭 Wi-Fi 快传" : "使用 Wi-Fi 快传" }
    var wifiButtonDetail: String {
        switch sdk.wifi.snapshot.state {
        case .enabling: return "正在请求设备开启热点…"
        case .joining: return "正在加入设备热点…"
        case .connecting: return "正在连接设备 TCP…"
        case .ready: return library.busy ? "正在通过 Wi-Fi 同步；点击可停止并恢复蓝牙" : "Wi-Fi 已就绪；点击关闭并恢复蓝牙"
        case .closing: return "正在关闭 Wi-Fi 快传…"
        case .restoringBluetooth: return "Wi-Fi 已关闭，正在恢复蓝牙…"
        case .failed: return "Wi-Fi 快传失败，正在恢复蓝牙"
        case .off: return "先通过蓝牙读取列表，再以 Wi-Fi 下载；完成后自动恢复蓝牙"
        @unknown default: return "Wi-Fi 快传状态未知"
        }
    }
    private var scanning = false
    private var scanGeneration = 0
    private var unbinding = false
    private var unbindCompleted = false
    private var erasedDeviceFiles = false
    override init() {
        super.init()
        sdk.delegate = self; sdk.deviceSettings.delegate = self; sdk.recording.delegate = self; sdk.files.delegate = self; sdk.wifi.delegate = self
        configureLibrary()
        print("[WaveNoteDemo] SDK version=\(WaveNoteSDK.sdkVersion)")
        // Demo 在 Debug / Release 均默认输出 SDK 脱敏日志到控制台。
        sdk.openLog(true)
        sdk.configure(with: WaveNoteSDKConfiguration(userIdentifier: "demo-user", enableAutoReconnect: true, identityProvider: identity, enableLiveAudio: true))
    }
    func scan() {
        guard !flow.busy, !flow.ready else { return }
        if sdk.bluetoothState == .unauthorized {
            status = "蓝牙权限未授予，请在系统设置中允许访问后重试。"; changed?(); return
        }
        guard sdk.bluetoothState == .poweredOn else { status = "请开启蓝牙，待蓝牙可用后重新扫描。"; changed?(); return }
        flow.invalidate(); scanGeneration += 1; let token = scanGeneration
        devices = []; scanning = true; status = "正在扫描…"; changed?(); sdk.startScanning()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.2) { [weak self] in
            guard let self, self.scanGeneration == token, self.scanning else { return }
            self.scanning = false
            self.status = self.devices.isEmpty ? "未发现设备，请靠近设备后重新扫描。" : "扫描完成，请选择设备。"
            self.changed?()
        }
    }
    func select(_ device: WaveNoteDiscoveredDevice) {
        guard Date().timeIntervalSince(device.lastSeen) <= 30 else { status = "扫描结果已过期，请重新扫描后选择设备。"; changed?(); return }
        guard let (token, route) = flow.select(bound: identity.isBound(device.serialNumber), fresh: true) else { return }
        // SDK 检查扫描批次及 30 秒有效期，Demo 不伪造发现对象。
        scanning = false; scanGeneration += 1
        status = route == .bind ? "正在绑定…" : "正在连接…"; changed?()
        if route == .connect { sdk.connect(to: device); return }
        sdk.bind(device) { [weak self] (result: Result<WaveNoteDevice, WaveNoteError>) in
            guard let self, self.flow.accepts(token) else { return }
            switch result {
            case .success:
                if self.flow.bound(token, success: true) { self.status = "绑定完成，正在连接…"; self.changed?(); self.sdk.connect(to: device) }
            case .failure(let error):
                _ = self.flow.bound(token, success: false); self.status = Self.errorText(error); self.changed?()
            }
        }
    }
    func refresh() {
        guard let token = flow.beginSetting() else { return }
        status = "正在读取设备设置…"; changed?()
        let items: [WaveNoteSetting] = [.hardware, .battery, .charging, .storage, .recording, .microphoneGain, .vibrationGain, .autoPowerOff]
        DemoReadSequence.run(items, active: { self.flow.accepts(token) && self.flow.ready }, query: { item, done in
            self.sdk.deviceSettings.query(item) { [weak self] value, error in
                guard let self, self.flow.accepts(token), self.flow.ready else { return }
                if let error { done(error); return }
                guard let value else { done(WaveNoteError(.invalidDeviceResponse, operation: "query", message: "缺少查询快照")); return }
                self.snapshot = value; self.mode = self.sdk.recording.snapshot.mode?.intValue; self.changed?(); done(nil)
            }
        }, finished: { (error: WaveNoteError?) in
            guard self.flow.finish(token) else { return }
            self.status = error.map(Self.errorText) ?? "设备设置已更新"; self.changed?()
        })
    }

    func control(shutdown: Bool = false, _ action: (@escaping (WaveNoteError?) -> Void) -> Void) {
        guard let token = flow.beginSetting() else { status = "设备忙碌，请等待当前操作完成。"; changed?(); return }
        status = shutdown ? "正在请求关机，等待设备确认…" : "正在保存，等待设备回读…"; changed?()
        action { [weak self] error in
            guard let self else { return }
            // 关机可能先断连，再返回结果未确认；保留该操作结果，但不得覆盖新会话。
            guard self.flow.accepts(token) || (shutdown && !self.flow.ready && self.flow.generation == token + 1) else { return }
            _ = self.flow.finish(token)
            self.status = error.map(Self.errorText) ?? (shutdown ? "设备已确认关机请求" : "已保存并确认设备状态")
            self.changed?()
        }
    }
    /// 仅在已连接且没有文件同步或设置事务时控制录音；最终状态以 recording Delegate 为准。
    func toggleRecording() {
        guard flow.ready else { return }
        guard !library.busy else { status = "文件同步中，请等待同步完成后再操作录音。"; changed?(); return }
        guard let token = flow.beginSetting() else { status = "设备忙碌，请等待当前操作完成。"; changed?(); return }
        let state = sdk.recording.snapshot.state
        let starting = state == .stopped
        guard starting || state == .recording || state == .paused else {
            _ = flow.finish(token); status = "录音状态未知，请稍后重试。"; changed?(); return
        }
        status = starting ? "正在开启录音…" : "正在停止录音…"; changed?()
        let action: (@escaping (WaveNoteError?) -> Void) -> Void = starting ? sdk.recording.start : sdk.recording.stop
        action { [weak self] error in
            guard let self, self.flow.accepts(token), self.flow.ready else { return }
            _ = self.flow.finish(token)
            self.status = error.map(Self.errorText) ?? (starting ? "录音已开启，文件同步已暂停。" : "录音已停止，准备同步文件。")
            self.changed?()
        }
    }
    func startRecording() {
        guard sdk.recording.snapshot.state == .stopped else { status = "录音状态未知，请稍后重试。"; changed?(); return }
        toggleRecording()
    }
    func stopRecording() {
        let state = sdk.recording.snapshot.state
        guard state == .recording || state == .paused else { status = "录音状态未知，请稍后重试。"; changed?(); return }
        toggleRecording()
    }
    func toggleWiFiTransfer() {
        if wifiWorkflow {
            status = "正在停止 Wi-Fi 传输，随后恢复蓝牙…"
            if library.busy { library.stop() }
            if [.enabling, .joining, .connecting].contains(sdk.wifi.snapshot.state) { wifiOpenOperation?.cancel() }
            else if !library.busy { closeWiFiAfterSync() }
            changed?(); return
        }
        guard flow.ready, sdk.recording.snapshot.state == .stopped, !library.busy else {
            status = "请等待设备空闲且当前同步完成后再开启 Wi-Fi 快传。"; changed?(); return
        }
        startSync(transport: .wifi)
    }
    func disconnect() { guard !flow.busy else { return }; sdk.disconnectDevice() }
    func unbind(eraseDeviceFiles: Bool = false) {
        guard flow.beginSetting() != nil else { return }
        erasedDeviceFiles = eraseDeviceFiles && sdk.connectedDevice?.serialNumber.hasPrefix("R202") == true
        unbinding = true; status = erasedDeviceFiles ? "正在解绑并清空内容…" : "正在解绑…"; changed?()
        sdk.unbindCurrentDevice(eraseDeviceFiles: eraseDeviceFiles) { _ in }
    }
    static func errorText(_ error: WaveNoteError) -> String {
        DemoValues.error(error.code)
    }

    func waveNoteSDK(_ sdk: WaveNoteSDK, didUpdateBluetoothState state: WaveNoteBluetoothState) {
        bluetooth = ["蓝牙状态未知", "蓝牙未授权 · 可前往系统设置", "此设备不支持蓝牙", "蓝牙已关闭", "蓝牙已开启", "蓝牙正在重置"][state.rawValue]; changed?()
    }
    func waveNoteSDK(_ sdk: WaveNoteSDK, didUpdateDiscoveredDevices values: [WaveNoteDiscoveredDevice]) { devices = values; changed?() }
    func waveNoteSDK(_ sdk: WaveNoteSDK, didChangeConnectionState state: WaveNoteConnectionState, device: WaveNoteDevice?) {
        if state == .disconnected && flow.selecting { return }
        if wifiWorkflow, state != .ready {
            if state == .failed, !library.busy, sdk.wifi.snapshot.state != .ready, sdk.wifi.snapshot.state != .closing {
                let result = wifiResult.isEmpty ? library.message : wifiResult
                wifiWorkflow = false; wifiOpenOperation = nil; wifiResult = ""
                finishLibraryFlow(); resetAudio(); flow.invalidate()
                status = "\(result)；Wi-Fi 已关闭，但蓝牙恢复失败，请重新扫描连接。"
            } else if state == .connecting || state == .discoveringServices || state == .reconnecting {
                status = "Wi-Fi 已关闭，正在恢复蓝牙连接…"
            } else {
                status = state == .failed ? "Wi-Fi 切换期间蓝牙连接失败，等待恢复…" : wifiButtonDetail
            }
            changed?(); return
        }
        if state == .ready {
            if wifiWorkflow, !library.busy, ![.ready, .closing].contains(sdk.wifi.snapshot.state) {
                finishWiFiWorkflow(); return
            }
            if !flow.ready { flow.connected(); snapshot = nil; mode = nil; audioSession += 1; library.invalidate(); observeRecording(sdk.recording.snapshot); scheduleSync() }
            status = "已连接，点击顶部 SN 查看设备设置。"
        } else if state == .disconnected || state == .failed {
            resetAudio()
            if state == .failed { flow.invalidate() } else { flow.disconnected() }; snapshot = nil; mode = nil; status = unbindCompleted ? (erasedDeviceFiles ? "已解绑，设备内容已清空。" : "已解绑，设备内容保留。") : state == .failed ? "连接失败，请重新扫描。" : "已断开，请重新扫描连接。"
            unbindCompleted = false
        } else if flow.ready { resetAudio(); flow.invalidate(); snapshot = nil; mode = nil }
        if state == .connecting || state == .discoveringServices { status = "正在连接并同步设备状态…" }
        changed?()
    }
    func waveNoteSDK(_ sdk: WaveNoteSDK, didChangeUnbindingState state: WaveNoteUnbindingState, device: WaveNoteDevice?) {
        guard unbinding else { return }
        if state == .completed { unbinding = false; unbindCompleted = true; status = erasedDeviceFiles ? "已解绑，设备内容已清空。" : "已解绑，设备内容保留。" }
        if state == .failed { unbinding = false; _ = flow.finish(flow.generation); status = "解绑失败，保留当前归属与连接。" }
        changed?()
    }
    func waveNoteSDK(_ sdk: WaveNoteSDK, didReceive error: WaveNoteError) {
        if !flow.ready && flow.busy { flow.invalidate() }
        scanning = false; scanGeneration += 1
        if unbinding { unbinding = false; _ = flow.finish(flow.generation) }
        status = Self.errorText(error); changed?()
    }
    func deviceSettings(_ settings: WaveNoteDeviceSettings, didUpdate value: WaveNoteSettingsSnapshot) { guard flow.ready else { return }; snapshot = value; changed?() }
    func recording(_ recording: WaveNoteRecording, didUpdate value: WaveNoteRecordingSnapshot) { guard flow.ready else { return }; mode = value.mode?.intValue; observeRecording(value); changed?() }
    func wifi(_ wifi: WaveNoteWiFi, didUpdate value: WaveNoteWiFiSnapshot) {
        guard wifiWorkflow else { return }
        switch value.state {
        case .ready: status = "Wi-Fi 已连接，开始传输文件。"
        case .closing: status = "正在关闭 Wi-Fi 快传…"
        case .restoringBluetooth: status = "Wi-Fi 已关闭，正在恢复蓝牙连接…"
        case .failed: status = value.error.map(Self.errorText) ?? "Wi-Fi 快传失败，正在恢复蓝牙。"
        case .off:
            if sdk.connectionState == .ready, !library.busy { finishWiFiWorkflow(); return }
        default: status = wifiButtonDetail
        }
        changed?()
    }
}

@MainActor extension DemoController {
    private func configureLibrary() {
        library.completedRow = { row in print("[WaveNoteDemo][FileCompleted] \(row.logJSON)") }
        library.changed = { [weak self] in self?.changed?() }
        player.changed = { [weak self] in self?.changed?() }
        library.finished = { [weak self] in
            guard let self else { return }
            if self.wifiWorkflow {
                self.wifiResult = self.library.message
                self.closeWiFiAfterSync()
            } else {
                self.finishLibraryFlow()
            }
        }
        library.readRecording = { [weak self] done in
            self?.sdk.recording.refresh { value, error in
                done(value.map { DemoRecordingValue(state: $0.state.rawValue, name: $0.fileName, mode: $0.mode?.intValue) }, error.map(Self.errorText))
            }
        }
        library.count = { [weak self] mode, done in self?.sdk.files.count(mode: mode == 1 ? .note : .call) { value, error in done(value?.intValue, error.map(Self.errorText)) } }
        library.page = { [weak self] mode, index, done in
            self?.sdk.files.page(mode: mode == 1 ? .note : .call, index: index) { values, error in
                done(values?.map { DemoAudioFile(name: $0.name, size: $0.size, mode: $0.mode.rawValue) }, error.map(Self.errorText))
            }
        }
        library.prepareDownloads = { [weak self] done in
            guard let self else { done("连接已失效"); return }
            guard self.syncTransport == .wifi else { done(nil); return }
            self.status = "文件列表已读取，正在开启 Wi-Fi 快传…"; self.changed?()
            self.wifiOpenOperation = self.sdk.wifi.open { [weak self] error in
                guard let self else { return }
                self.wifiOpenOperation = nil
                done(error.map(Self.errorText))
            }
        }
        library.download = { [weak self] file, progress, done in
            guard let self, let sn = self.syncSerialNumber else { done(nil, "连接已失效"); return {} }
            let session = self.audioSession
            self.library.phase(file: file, text: "检查断点")
            var cancelled = false
            var operation: WaveNoteOperation?
            self.sdk.files.findLocalAudio(serialNumber: sn, mode: file.mode == 1 ? .note : .call, fileName: file.name) { [weak self] cached, error in
                guard let self, self.audioSession == session else { return }
                guard !cancelled else { done(nil, "同步已取消"); return }
                // 查询接口必须如实报告损坏的索引/Ogg；同步入口则让
                // SDK 删除该缓存并重新从设备获取，不能因此卡住整轮队列。
                if let error, error.errorCode != .fileIOFailed { done(nil, Self.errorText(error)); return }
                if let error { print("[WaveNoteDemo][AudioCache] cache unavailable; redownload operation=\(error.operation) code=\(error.code)") }
                if let cached, cached.rawBytes == file.size { done(cached.url.path, nil); return }
                operation = self.sdk.files.downloadToStorage(WaveNoteFile(name: file.name, size: file.size, mode: file.mode == 1 ? .note : .call), transport: self.syncTransport, resume: true, deleteSource: true) { [weak self] audio, error in
                    guard let self, self.audioSession == session else { return }
                    self.logOggDuration(result: error == nil && audio != nil ? "completed" : error?.code == WaveNoteErrorCode.operationCancelled.rawValue ? "cancelled" : "failed")
                    self.progressID = nil; self.progressCallback = nil; self.progressFile = nil
                    if let error {
                        done(nil, error.operation == "downloadPositionMismatch" ? "downloadPositionMismatch" : Self.errorText(error))
                    }
                    else if let audio { done(audio.url.path, nil) }
                    else { done(nil, "下载未交付文件") }
                }
                self.progressID = operation?.identifier; self.progressCallback = progress; self.progressFile = file
            }
            return { cancelled = true; operation?.cancel() }
        }
        library.deleteLocal = { [weak self] file, done in
            guard let self, let sn = self.sdk.connectedDevice?.serialNumber else { done("连接已失效"); return }
            self.sdk.files.deleteLocalAudio(serialNumber: sn, mode: file.mode == 1 ? .note : .call, fileName: file.name) { error in
                done(error.map(Self.errorText))
            }
        }
    }

    func syncFiles() {
        startSync(transport: .bluetooth)
    }
    private func startSync(transport: WaveNoteTransferTransport) {
        guard flow.ready, !library.isRecording, !library.busy, let serial = sdk.connectedDevice?.serialNumber,
              let token = flow.beginSetting() else { return }
        syncTransport = transport; syncSerialNumber = serial; wifiWorkflow = transport == .wifi
        scheduledSync += 1; libraryToken = token
        if !library.start() {
            _ = flow.finish(token); libraryToken = nil; syncSerialNumber = nil; syncTransport = .bluetooth; wifiWorkflow = false
        }
    }
    private func finishLibraryFlow() {
        if let token = libraryToken { _ = flow.finish(token) }
        libraryToken = nil; syncSerialNumber = nil; syncTransport = .bluetooth; changed?()
    }
    private func closeWiFiAfterSync() {
        switch sdk.wifi.snapshot.state {
        case .ready:
            wifiOpenOperation = nil
            status = "正在关闭 Wi-Fi 快传并恢复蓝牙…"; changed?()
            sdk.wifi.close { [weak self] error in
                guard let self else { return }
                if let error { self.status = Self.errorText(error); self.changed?() }
            }
        case .enabling, .joining, .connecting:
            wifiOpenOperation?.cancel()
            wifiOpenOperation = nil
        case .closing, .restoringBluetooth:
            break
        case .off:
            if sdk.connectionState == .ready { finishWiFiWorkflow() }
            else { status = "正在恢复蓝牙连接…"; changed?() }
        case .failed:
            status = "Wi-Fi 快传失败，正在恢复蓝牙连接…"; changed?()
        @unknown default:
            status = "Wi-Fi 状态未知，请检查设备连接。"; changed?()
        }
    }
    private func finishWiFiWorkflow() {
        let result = wifiResult.isEmpty ? library.message : wifiResult
        wifiWorkflow = false; wifiOpenOperation = nil; wifiResult = ""
        finishLibraryFlow()
        status = "\(result)；Wi-Fi 已关闭，蓝牙已恢复。"; changed?()
    }
    private func scheduleSync() {
        scheduledSync += 1; let ticket = scheduledSync; let session = audioSession
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.flow.ready, self.audioSession == session, self.scheduledSync == ticket, !self.library.isRecording else { return }
            if self.flow.busy { self.scheduleSync() } else { self.syncFiles() }
        }
    }
    private func observeRecording(_ value: WaveNoteRecordingSnapshot) {
        let wasRecording = library.isRecording
        let state = DemoRecordingValue(state: value.state.rawValue, name: value.fileName, mode: value.mode?.intValue)
        recordingClock.update(state); library.observe(state)
        if library.isRecording { scheduledSync += 1; player.stop() }
        if wasRecording && value.state == .stopped { scheduleSync() }
    }
    private func logOggDuration(result: String) {
        guard let started = oggStartedAt else { return }
        oggStartedAt = nil
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        print("[WaveNoteDemo][OpusToOgg] operationID=\(progressID?.uuidString ?? "unknown") result=\(result) elapsedMs=\(String(format: "%.1f", elapsedMs)) rawBytes=\(progressFile?.size ?? 0) scope=finishingToCompletion")
    }
    private func resetAudio() {
        logOggDuration(result: "interrupted")
        audioSession += 1; scheduledSync += 1; libraryToken = nil; progressID = nil; progressCallback = nil
        library.invalidate(); recordingClock.update(DemoRecordingValue(state: 0, name: nil, mode: nil)); player.stop()
    }
    func files(_ files: WaveNoteFiles, didUpdate progress: WaveNoteTransferProgress) {
        guard flow.ready, progress.operationID == progressID else { return }
        if progress.state == .finishing, oggStartedAt == nil { oggStartedAt = ProcessInfo.processInfo.systemUptime }
        if let file = progressFile {
            if progress.state == .running, library.rows.first(where: { $0.file.key == file.key })?.status == "检查断点" { library.phase(file: file, text: "正在同步") }
            if progress.state == .checkingStorage { library.phase(file: file, text: "检查断点") }
            if progress.state == .resuming { library.phase(file: file, text: "继续下载") }
            if progress.state == .repackaging { library.phase(file: file, text: "重新封装") }
        }
        if [.running, .finishing, .completed].contains(progress.state) { progressCallback?(progress.receivedBytes) }
        if progress.state == .finishing { library.converting(bytes: progress.convertedBytes, total: progress.totalBytes) }
    }
}
