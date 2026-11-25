import UIKit
import UniformTypeIdentifiers
import WaveNoteSDK

/// Owned by DemoController; opening/closing the screen does not own the SDK operation.
@MainActor final class DemoBluetoothFirmware: NSObject, WaveNoteBluetoothFirmwareUpdateDelegate {
    private let sdk: WaveNoteSDK
    private let changed: () -> Void
    private let fileQueue = DispatchQueue(label: "WaveNoteDemo.firmware")
    let flow = DemoOTAFlow()
    private(set) var fileURL: URL?
    private(set) var originalName = ""
    private(set) var fileBytes: Int64 = 0
    private(set) var importing = false
    private(set) var importMessage = ""
    private(set) var message = "请选择适用于当前设备的本地蓝牙固件。"
    private var operation: WaveNoteOperation?
    private var operationID: UUID?
    private var targetSerial: String?
    private var targetText = ""
    private var versionQuery = 0
    private var versionRequested = false
    var hasSession: Bool { fileURL != nil || importing || flow.stage != nil }
    var canChoose: Bool { !flow.active && !importing }
    var canStart: Bool { canChoose && fileURL != nil && sdk.connectionState == .ready }
    var canCancel: Bool {
        guard flow.active, !flow.cancelPending, let value = sdk.bluetoothFirmwareUpdate.snapshot else { return false }
        return value.operationID == operationID && value.canCancel && value.state.rawValue < 4
    }
    init(sdk: WaveNoteSDK, changed: @escaping () -> Void) {
        self.sdk = sdk; self.changed = changed; super.init()
        sdk.bluetoothFirmwareUpdate.delegate = self
    }
    var deviceText: String {
        if (flow.active || flow.outcome != nil), !targetText.isEmpty { return targetText }
        return currentDeviceText
    }
    var currentDeviceText: String {
        guard let device = sdk.connectedDevice else { return "目标设备尚未连接" }
        return "目标设备：\(device.name ?? "Note")\nSN：\(device.serialNumber)\n当前上报版本：\(sdk.deviceSettings.snapshot.firmwareVersion ?? "未知")"
    }
    func start(expectedGeneration: Int, expectedSerial: String) {
        guard let fileURL else { return }
        let bytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard canStart, flow.generation == expectedGeneration, sdk.connectedDevice?.serialNumber == expectedSerial,
              DemoOTAFlow.validFileSize(bytes) else {
            message = "设备、连接或固件已变化，请重新核对后开始升级。"; changed(); return
        }
        let before = currentDeviceText.replacingOccurrences(of: "当前上报版本：", with: "升级前上报版本：")
        guard let ticket = flow.begin() else { return }
        targetText = before
        targetSerial = expectedSerial; operationID = nil; versionRequested = false; versionQuery += 1
        importMessage = ""; message = "正在准备升级…"; changed()
        let token = sdk.bluetoothFirmwareUpdate.start(fileURL: fileURL) { [weak self] error in
            guard let self else { return }
            let result: DemoOTAFlow.Outcome = error == nil ? .success : error?.errorCode == .operationCancelled ? .cancelled : .failed
            guard self.flow.finish(ticket, outcome: result) else { return }
            self.operation = nil
            switch result {
            case .success: self.message = "固件升级已完成，正在恢复目标设备的业务连接。"
            case .cancelled: self.message = "设备已确认取消，等待业务连接恢复。"
            case .failed: self.message = error.map { "\(DemoValues.error($0.code))（\($0.code)）" } ?? "升级失败"
            }
            self.changed()
            DispatchQueue.main.async { [weak self] in self?.connectionChanged() }
        }
        if flow.generation == ticket, flow.active { operation = token; operationID = token.identifier }
        changed()
    }
    func cancel() {
        guard canCancel, let ticket = flow.beginCancel() else { return }
        message = "正在请求取消，请等待设备确认。"; changed()
        sdk.bluetoothFirmwareUpdate.cancel { [weak self] error in
            guard let self, self.flow.cancelResult(ticket, accepted: error == nil) else { return }
            self.message = error.map { "取消未确认：\($0.code) · \($0.operation)，以升级状态为准。" } ?? "取消请求已确认，正在等待最终升级状态。"
            self.changed()
        }
    }
    func bluetoothFirmwareUpdate(_ updater: WaveNoteBluetoothFirmwareUpdate, didUpdate progress: WaveNoteOTAProgress) {
        guard flow.active, operationID == progress.operationID else { return }
        flow.update(flow.generation, stage: progress.state.rawValue, percent: progress.progress); changed()
    }
    func connectionChanged() {
        guard !flow.active, flow.outcome != nil else { return }
        let previousReady = flow.businessReady; let previousMessage = message
        defer { if previousReady != flow.businessReady || previousMessage != message { changed() } }
        let ready = sdk.connectionState == .ready && sdk.connectedDevice?.serialNumber == targetSerial
        if !ready, flow.businessReady { versionQuery += 1; versionRequested = false }
        flow.connectionReady(ready)
        if !ready, flow.outcome == .success { message = "固件升级已完成，正在恢复目标设备的业务连接。" }
        if flow.outcome == .cancelled { message = ready ? "已取消升级，业务连接已恢复。" : "设备已确认取消，等待业务连接恢复。" }
        guard ready, flow.outcome == .success, !versionRequested else { return }
        versionRequested = true
        message = "业务连接已恢复，正在读取设备上报版本…"
        let ticket = flow.generation; versionQuery += 1; let query = versionQuery
        sdk.deviceSettings.query(.hardware) { [weak self] value, error in
            guard let self, ticket == self.flow.generation, query == self.versionQuery,
                  self.sdk.connectionState == .ready, self.sdk.connectedDevice?.serialNumber == self.targetSerial else { return }
            self.message = error == nil ? "业务连接已恢复，设备上报版本：\(value?.firmwareVersion ?? "未知")。" : "业务连接已恢复，版本读取未完成，可在设备设置中刷新。"
            self.changed()
        }
    }
    func importFile(_ source: URL) {
        guard canChoose else { return }
        importing = true; importMessage = "正在导入固件…"; changed()
        let access = source.startAccessingSecurityScopedResource()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("bluetooth-firmware-\(UUID().uuidString).ufw")
        fileQueue.async { [weak self] in
            var name = source.lastPathComponent
            var bytes: Int64 = 0
            let copied: Bool
            do {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .nameKey, .fileSizeKey])
                name = values.name ?? name
                guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                if let size = values.fileSize, !DemoOTAFlow.validFileSize(Int64(size)) { throw CocoaError(.fileReadTooLarge) }
                try FileManager.default.copyItem(at: source, to: destination)
                bytes = Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                copied = DemoOTAFlow.validFileSize(bytes)
            } catch { copied = false }
            if access { source.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                guard let self else { try? FileManager.default.removeItem(at: destination); return }
                self.importing = false
                if copied {
                    if let previous = self.fileURL { self.fileQueue.async { try? FileManager.default.removeItem(at: previous) } }
                    self.fileURL = destination; self.originalName = name; self.fileBytes = bytes
                    self.flow.selectFirmware(); self.operationID = nil; self.targetText = ""; self.targetSerial = nil
                    self.versionQuery += 1; self.versionRequested = false
                    self.message = "固件已导入，请核对设备和文件后开始升级。"; self.importMessage = ""
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    self.importMessage = "导入失败，文件为空、过大或无法读取，请重新选择。" +
                        (self.fileURL == nil ? "尚未选择固件。" : "仍保留上一份固件：\(self.originalName)。")
                }
                self.changed()
            }
        }
    }
}

/// Demo consumes only WaveNote's public API and copies imported firmware off the main thread.
final class BluetoothFirmwareController: UIViewController, UIDocumentPickerDelegate {
    private let model: DemoController
    private var session: DemoBluetoothFirmware { model.firmware }
    private var previousGestureEnabled: Bool?
    private let fileLabel = UILabel()
    private let deviceLabel = UILabel()
    private let statusLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let choose = UIButton(type: .system)
    private let start = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    init(model: DemoController) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); previousGestureEnabled = navigationController?.interactivePopGestureRecognizer?.isEnabled
        updateStatus()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); updateStatus() }
    override func viewWillDisappear(_ animated: Bool) {
        if let previousGestureEnabled { navigationController?.interactivePopGestureRecognizer?.isEnabled = previousGestureEnabled }
        super.viewWillDisappear(animated)
    }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "蓝牙固件升级"; view.backgroundColor = .systemGroupedBackground
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "返回", style: .plain, target: self, action: #selector(leavePage))
        fileLabel.numberOfLines = 0; statusLabel.numberOfLines = 0; deviceLabel.numberOfLines = 0
        choose.setTitle("选择固件文件", for: .normal); choose.addTarget(self, action: #selector(pick), for: .touchUpInside)
        start.setTitle("开始升级", for: .normal); start.addTarget(self, action: #selector(confirmStart), for: .touchUpInside)
        cancel.setTitle("请求取消升级", for: .normal); cancel.addTarget(self, action: #selector(cancelUpdate), for: .touchUpInside)
        let note = UILabel(); note.numberOfLines = 0; note.textColor = .secondaryLabel
        note.text = "升级期间请保持设备供电并将应用留在前台。设备可能重启、重新连接；进度达到 99% 时仍须等待升级结果。"
        let stack = UIStackView(arrangedSubviews: [choose, fileLabel, deviceLabel, start, progress, statusLabel, cancel, note])
        stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll); scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        ])
        updateStatus()
    }
    func updateStatus() {
        guard isViewLoaded else { return }
        let size = ByteCountFormatter.string(fromByteCount: session.fileBytes, countStyle: .file)
        fileLabel.text = (session.fileURL == nil ? "尚未选择固件" : "固件：\(session.originalName)\n大小：\(size)（\(session.fileBytes) 字节）") +
            (session.importMessage.isEmpty ? "" : "\n\(session.importMessage)")
        deviceLabel.text = session.deviceText
        statusLabel.text = "\(session.flow.title) · \(session.flow.percent)%\n\(session.message)"
        progress.progress = Float(session.flow.percent) / 100
        choose.isEnabled = session.canChoose; start.isEnabled = session.canStart; cancel.isEnabled = session.canCancel
        cancel.setTitle(session.flow.cancelPending ? "等待取消结果…" : "请求取消升级", for: .normal)
        if navigationController?.topViewController === self {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = session.flow.protectsExit ? false : (previousGestureEnabled ?? true)
        }
    }
    @objc private func pick() {
        guard session.canChoose else { return }
        // File providers may identify an unregistered .ufw extension only as a generic item.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.shouldShowFileExtensions = true
        picker.delegate = self; present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let source = urls.first { session.importFile(source) }
    }
    @objc private func confirmStart() {
        guard session.canStart, let serial = model.sdk.connectedDevice?.serialNumber else { return }
        let ticket = session.flow.generation
        let size = ByteCountFormatter.string(fromByteCount: session.fileBytes, countStyle: .file)
        let alert = UIAlertController(title: "升级蓝牙固件", message: "\(session.currentDeviceText)\n\n固件：\(session.originalName)\n大小：\(size)\n\n确认固件适用于此设备，并在升级期间保持设备供电。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "返回", style: .cancel))
        alert.addAction(UIAlertAction(title: "开始升级", style: .default) { [weak self] _ in
            self?.session.start(expectedGeneration: ticket, expectedSerial: serial)
        })
        present(alert, animated: true)
    }
    @objc private func cancelUpdate() { session.cancel() }
    @objc private func leavePage() {
        guard session.flow.protectsExit else { navigationController?.popViewController(animated: true); return }
        let alert = UIAlertController(title: "固件升级正在进行", message: "返回上一页不会取消升级。请保持应用在前台，可从首页重新查看升级状态。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "继续查看", style: .cancel))
        alert.addAction(UIAlertAction(title: "返回上一页", style: .default) { [weak self] _ in self?.navigationController?.popViewController(animated: true) })
        present(alert, animated: true)
    }
}
