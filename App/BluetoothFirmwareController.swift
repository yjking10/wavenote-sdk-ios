import UIKit
import UniformTypeIdentifiers
import WaveNoteSDK

/// Demo consumes only WaveNote's public API and copies imported firmware off the main thread.
final class BluetoothFirmwareController: UIViewController, UIDocumentPickerDelegate, WaveNoteBluetoothFirmwareUpdateDelegate {
    private let model: DemoController
    private let fileQueue = DispatchQueue(label: "WaveNoteDemo.firmware")
    private var firmware: URL?
    private var operation: WaveNoteOperation?
    private var copying = false
    private var fileBytes = 0
    private var message = "请选择适用于当前设备的本地蓝牙固件。"
    private let fileLabel = UILabel()
    private let statusLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let choose = UIButton(type: .system)
    private let start = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    init(model: DemoController) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var running: Bool {
        guard let value = model.sdk.bluetoothFirmwareUpdate.snapshot else { return false }
        return ![.completed, .cancelled, .failed].contains(value.state)
    }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "蓝牙固件升级"; view.backgroundColor = .systemGroupedBackground
        fileLabel.numberOfLines = 0; statusLabel.numberOfLines = 0
        choose.setTitle("选择固件文件", for: .normal); choose.addTarget(self, action: #selector(pick), for: .touchUpInside)
        start.setTitle("开始升级", for: .normal); start.addTarget(self, action: #selector(confirmStart), for: .touchUpInside)
        cancel.setTitle("请求取消升级", for: .normal); cancel.addTarget(self, action: #selector(cancelUpdate), for: .touchUpInside)
        let note = UILabel(); note.numberOfLines = 0; note.textColor = .secondaryLabel
        note.text = "升级期间请保持设备供电并将应用留在前台。设备可能重启、重新连接；进度达到 99% 时仍须等待升级结果。"
        let stack = UIStackView(arrangedSubviews: [fileLabel, choose, start, progress, statusLabel, cancel, note])
        stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)
        ])
        model.sdk.bluetoothFirmwareUpdate.delegate = self
        updateStatus()
    }
    func updateStatus() {
        guard isViewLoaded else { return }
        fileLabel.text = copying ? "正在导入固件…" : firmware.map { _ in "已导入固件（\(fileBytes) 字节）" } ?? "尚未选择固件"
        if let value = model.sdk.bluetoothFirmwareUpdate.snapshot {
            let states = ["准备中", "升级中", "重新连接", "设备重启中", "升级成功", "已取消", "升级失败"]
            let connection = running ? "升级期间暂停业务操作" : model.sdk.connectionState == .ready ? "业务连接已就绪" : "业务连接尚未就绪"
            statusLabel.text = "\(states[value.state.rawValue]) · \(value.progress)%\n\(message)\n\(connection)"
            progress.progress = Float(value.progress) / 100
        } else { statusLabel.text = message }
        choose.isEnabled = !running && !copying
        start.isEnabled = !running && !copying && firmware != nil && model.sdk.connectionState == .ready
        cancel.isEnabled = running && model.sdk.bluetoothFirmwareUpdate.snapshot?.canCancel == true
    }
    @objc private func pick() {
        guard !running, !copying else { return }
        // File providers may identify an unregistered .ufw extension only as a generic item.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.shouldShowFileExtensions = true
        picker.delegate = self; present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let source = urls.first, !running else { return }
        copying = true; updateStatus()
        let access = source.startAccessingSecurityScopedResource()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("bluetooth-firmware-\(UUID().uuidString).ufw")
        fileQueue.async { [weak self] in
            let copied: Bool
            do {
                if try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    try FileManager.default.copyItem(at: source, to: destination); copied = true
                } else { copied = false }
            } catch { copied = false }
            let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if access { source.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                guard let self else { return }
                if copied {
                    if let previous = self.firmware { self.fileQueue.async { try? FileManager.default.removeItem(at: previous) } }
                    self.firmware = destination; self.fileBytes = bytes; self.message = "固件已导入，请核对设备和固件后开始升级。"
                } else { self.message = "无法读取固件文件，请重新选择。" }
                self.copying = false; self.updateStatus()
            }
        }
    }
    @objc private func confirmStart() {
        guard let firmware, !running else { return }
        let alert = UIAlertController(title: "升级蓝牙固件", message: "确认此固件适用于当前设备，并在升级期间保持设备供电。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "返回", style: .cancel))
        alert.addAction(UIAlertAction(title: "开始升级", style: .default) { [weak self] _ in
            guard let self else { return }
            self.message = "正在准备升级…"
            self.operation = self.model.sdk.bluetoothFirmwareUpdate.start(fileURL: firmware) { [weak self] error in
                guard let self else { return }
                self.message = error.map { "\(DemoValues.error($0.code))（\($0.code)）" } ?? "固件升级成功，业务连接将自动恢复。"
                self.operation = nil; self.updateStatus()
            }
            self.updateStatus()
        })
        present(alert, animated: true)
    }
    @objc private func cancelUpdate() {
        model.sdk.bluetoothFirmwareUpdate.cancel { [weak self] error in
            self?.message = error.map { "取消未确认：\($0.code) · \($0.operation)，以升级状态为准。" } ?? "原生流程已确认取消。"
            self?.updateStatus()
        }
    }
    func bluetoothFirmwareUpdate(_ updater: WaveNoteBluetoothFirmwareUpdate, didUpdate progress: WaveNoteOTAProgress) { updateStatus() }
}
