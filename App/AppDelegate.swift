import UIKit
import WaveNoteSDK

@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let nav = UINavigationController(rootViewController: HomeController())
        nav.view.tintColor = UIColor(red: 0.09, green: 0.42, blue: 0.51, alpha: 1)
        window.rootViewController = nav; window.makeKeyAndVisible(); self.window = window
        return true
    }
    func applicationDidEnterBackground(_ application: UIApplication) {
        ((window?.rootViewController as? UINavigationController)?.viewControllers.first as? HomeController)?.model.player.stop()
    }
}

final class HomeController: UITableViewController {
    let model = DemoController()
    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "WaveNote"
        navigationItem.backButtonTitle = "返回"
        model.changed = { [weak self] in self?.update() }
        model.player.progressChanged = { [weak self] in self?.updatePlaybackProgress() }
        update()
    }
    private func update() {
        if model.flow.ready, let sn = model.sdk.connectedDevice?.serialNumber {
            let button = UIButton(type: .system)
            button.setTitle(sn, for: .normal); button.titleLabel?.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
            button.accessibilityIdentifier = "connectedSN"
            button.addTarget(self, action: #selector(settings), for: .touchUpInside)
            navigationItem.titleView = button
        } else {
            navigationItem.titleView = nil
            if navigationController?.topViewController !== self {
                navigationController?.dismiss(animated: false)
                navigationController?.popToRootViewController(animated: false)
            }
        }
        tableView.reloadData()
        for page in navigationController?.viewControllers ?? [] {
            (page as? SettingsController)?.tableView.reloadData()
            (page as? PowerController)?.tableView.reloadData()
            (page as? GainController)?.updateStatus()
            (page as? RecordingDetailController)?.tableView.reloadData()
        }
    }
    @objc private func settings() {
        guard model.flow.ready else { return }
        navigationController?.pushViewController(SettingsController(model: model), animated: true)
    }
    override func numberOfSections(in tableView: UITableView) -> Int { model.flow.ready || model.flow.showsNearby ? 2 : 1 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "连接设备" : !model.flow.ready ? "附近设备" : model.library.isRecording ? "当前录音" : "录音文件" }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 1 && model.flow.ready { return model.player.message.isEmpty ? "音频仅保存在本机，不删除设备文件。下载中停止同步可能断开蓝牙，需要重新连接。" : model.player.message }
        return section == 0 ? "演示身份：本地模拟。绑定记录仅在本机保存，两端不共享。" : "选择设备后绑定并连接；已绑定设备直接连接。"
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 3 : !model.flow.ready ? max(1, model.devices.count) : model.library.isRecording ? 1 : 1 + model.library.rows.count }
    override func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.font = .preferredFont(forTextStyle: .body); cell.textLabel?.adjustsFontForContentSizeCategory = true
        if path.section == 1 && model.flow.ready {
            if model.library.isRecording {
                cell.textLabel?.text = model.library.recording.state == 3 ? "录音已暂停" : "正在录音"
                cell.textLabel?.textColor = .systemRed; cell.detailTextLabel?.text = "点击查看当前文件名和录音时长 · 文件同步已暂停"
                cell.accessoryType = .disclosureIndicator
            } else if path.row == 0 {
                cell.textLabel?.text = model.library.busy ? "停止同步" : "重新同步文件"
                cell.textLabel?.textColor = view.tintColor; cell.detailTextLabel?.text = model.library.message
            } else {
                let row = model.library.rows[path.row - 1]
                cell.textLabel?.text = row.file.name
                let percent = row.file.size > 0 ? Int(Double(row.received) / Double(row.file.size) * 100) : 0
                cell.detailTextLabel?.text = "\(row.file.mode == 1 ? "Note" : "Call") · \(row.status) · \(percent)%\n\(ByteCountFormatter.string(fromByteCount: row.received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: row.file.size, countStyle: .file))"
                if let path = row.localPath {
                    let button = UIButton(type: .system)
                    button.setTitle(model.player.path == path && model.player.playing ? "暂停" : "播放", for: .normal)
                    button.isEnabled = !model.player.preparing
                    button.addAction(UIAction { [weak self] _ in self?.model.player.toggle(path) }, for: .touchUpInside)
                    if model.player.path == path && !model.player.preparing {
                        let accessory = DemoPlaybackAccessory(button: button)
                        accessory.update(model.player)
                        cell.accessoryView = accessory
                    } else {
                        button.frame = CGRect(x: 0, y: 0, width: 64, height: 44); cell.accessoryView = button
                    }
                } else {
                    let progress = UIProgressView(progressViewStyle: .default); progress.progress = Float(percent) / 100
                    progress.frame = CGRect(x: 0, y: 0, width: 80, height: 4); cell.accessoryView = progress
                }
            }
        } else if path.section == 0 {
            cell.textLabel?.text = ["开始扫描", model.bluetooth, model.status][path.row]
            if path.row == 0 { cell.textLabel?.textColor = model.flow.busy || model.flow.ready ? .secondaryLabel : view.tintColor; cell.accessibilityIdentifier = "scan" }
            if path.row == 1 && model.sdk.bluetoothState == .unauthorized { cell.accessoryType = .disclosureIndicator }
        } else if model.devices.isEmpty { cell.textLabel?.text = "扫描后，附近的 Note 设备会显示在这里。"; cell.textLabel?.textColor = .secondaryLabel }
        else {
            let d = model.devices[path.row]
            cell.textLabel?.text = d.serialNumber; cell.textLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
            cell.detailTextLabel?.text = "\(d.name ?? "Note") · \(d.rssi) dBm · \(model.identity.isBound(d.serialNumber) ? "已绑定" : "未绑定")"
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }
    private func updatePlaybackProgress() {
        for cell in tableView.visibleCells {
            (cell.accessoryView as? DemoPlaybackAccessory)?.update(model.player)
        }
    }
    override func tableView(_ tableView: UITableView, heightForRowAt path: IndexPath) -> CGFloat {
        if model.flow.ready, path.section == 1, !model.library.isRecording, path.row > 0,
           let local = model.library.rows[path.row - 1].localPath, local == model.player.path { return 112 }
        return UITableView.automaticDimension
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
        tableView.deselectRow(at: path, animated: true)
        if path.section == 1 && model.flow.ready {
            if model.library.isRecording { navigationController?.pushViewController(RecordingDetailController(model: model), animated: true) }
            else if path.row == 0 { if model.library.busy { model.library.stop() } else { model.syncFiles() } }
        } else if path.section == 0 {
            if path.row == 0 { model.scan() }
            if path.row == 1 && model.sdk.bluetoothState == .unauthorized, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        } else if !model.devices.isEmpty { model.select(model.devices[path.row]) }
    }
}

/// 播放按钮、时间及进度放在同一文件行；计时刷新不触发 reloadData。
private final class DemoPlaybackAccessory: UIView {
    private let time = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    init(button: UIButton) {
        super.init(frame: CGRect(x: 0, y: 0, width: 142, height: 84))
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textAlignment = .center
        progress.accessibilityLabel = "播放进度"
        let stack = UIStackView(arrangedSubviews: [button, time, progress])
        stack.axis = .vertical; stack.spacing = 6
        stack.frame = bounds; stack.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        addSubview(stack)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ player: DemoNativePlayer) {
        time.text = player.timeText; progress.progress = player.fraction
        progress.accessibilityValue = player.timeText
    }
}

final class SettingsController: UITableViewController {
    struct Row { let title: String; let value: String; var action: (() -> Void)? = nil }
    let model: DemoController
    init(model: DemoController) { self.model = model; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "设备设置"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "刷新", style: .plain, target: self, action: #selector(refresh))
        model.refresh()
    }
    @objc private func refresh() { model.refresh() }
    private func value(_ number: NSNumber?) -> String { number?.stringValue ?? "未知" }
    private func info(_ title: String, _ text: String) { navigationController?.pushViewController(TextPage(title: title, text: text), animated: true) }
    private var groups: [(String, [Row])] {
        let s = model.snapshot
        let mode = model.mode == 1 ? "Note 模式" : model.mode == 2 ? "Call 模式" : "未知"
        let disk: String
        if let used = s?.storageUsed?.doubleValue, let total = s?.storageTotal?.doubleValue, total > 0 {
            disk = "\(value(s?.storageUsed)) / \(value(s?.storageTotal))（\(Int(used / total * 100))%）"
        } else { disk = "未知" }
        return [
            ("通用", [Row(title: "设备名称", value: s?.deviceName ?? model.sdk.connectedDevice?.name ?? "未知"),
                      Row(title: "SN", value: model.sdk.connectedDevice?.serialNumber ?? "未知"),
                      Row(title: "模式", value: mode, action: { self.info("录音模式", "当前：\(mode)\n\nNote 模式用于现场录音；Call 模式用于通话录音。请使用设备物理开关切换，页面随设备状态更新。") }),
                      Row(title: "电量", value: s?.batteryLevel.map { "\($0)%" } ?? "未知", action: { self.info("电量", "电量：\(self.value(s?.batteryLevel))\n充电状态：\(s?.charging == 1 ? "充电中" : s?.charging == 0 ? "未充电" : "未知")\n\n电量较低时请及时充电。") }),
                      Row(title: "存储", value: disk, action: { self.info("设备存储", "已用 / 总量：\(disk)\n\n容量保留设备原始单位。此页面仅查看使用情况，不清空设备内容。") }),
                      Row(title: "固件版本", value: s?.firmwareVersion ?? "未知"),
                      Row(title: "自动关机", value: DemoFlow.minutes(s?.autoPowerOffMinutes?.intValue), action: { self.autoPower() })]),
            ("隐私与安全", [Row(title: "USB 访问", value: DemoValues.usb(s?.usbEnabled?.intValue), action: { self.usb() })]),
            ("高级录音设置", [Row(title: "麦克风增益", value: value(s?.microphoneGain), action: { self.gain(microphone: true) }),
                           Row(title: "振动传感器增益", value: value(s?.vibrationGain), action: { self.gain(microphone: false) })]),
            ("连接管理", [Row(title: "断开连接", value: "", action: { self.model.disconnect() }),
                        Row(title: "解绑设备", value: "", action: { self.confirm("解绑设备", "仅解除本机演示账户归属，不清空设备内容。") { self.model.unbind() } })])
        ]
    }
    override func numberOfSections(in tableView: UITableView) -> Int { groups.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { groups[section].0 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return model.status }
        if section == 1 { return "开启后允许通过 USB 访问设备内容。此状态不表示线缆是否连接。" }
        if section == 2 { return "原始整数 0–255，数值不代表分贝或百分比。" }
        return "演示身份：本地模拟"
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { groups[section].1.count }
    override func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        let row = groups[path.section].1[path.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = row.title; cell.detailTextLabel?.text = row.value; cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.font = .preferredFont(forTextStyle: .body); cell.detailTextLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.textLabel?.adjustsFontForContentSizeCategory = true; cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.accessoryType = row.action == nil ? .none : .disclosureIndicator
        cell.textLabel?.textColor = path.section == 3 ? .systemRed : .label
        if path.section == 1 {
            let toggle = UISwitch(); toggle.isOn = model.snapshot?.usbEnabled == 1
            toggle.isEnabled = DemoValues.canSetUSB(model.snapshot?.usbEnabled?.intValue) && !model.flow.busy
            toggle.addTarget(self, action: #selector(toggleUSB(_:)), for: .valueChanged); cell.accessoryView = toggle
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
        tableView.deselectRow(at: path, animated: true)
        guard model.flow.ready else { return }
        if model.flow.busy { return }
        groups[path.section].1[path.row].action?()
    }
    @objc private func toggleUSB(_ sender: UISwitch) {
        let enabled = sender.isOn; sender.isOn = model.snapshot?.usbEnabled == 1
        model.control { self.model.sdk.deviceSettings.setUSBEnabled(enabled, completion: $0) }
    }
    private func usb() { info("USB 访问", "开启后允许通过 USB 访问设备内容。请使用右侧开关设置；未知状态请先刷新。") }
    private func gain(microphone: Bool) {
        navigationController?.pushViewController(GainController(model: model, microphone: microphone), animated: true)
    }
    private func autoPower() {
        let page = PowerController(model: model); navigationController?.pushViewController(page, animated: true)
    }
    private func confirm(_ title: String, _ message: String, action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认", style: .destructive) { _ in action() }); present(alert, animated: true)
    }
}

final class TextPage: UIViewController {
    let text: String
    init(title: String, text: String) { self.text = text; super.init(nibName: nil, bundle: nil); self.title = title }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemGroupedBackground
        let label = UITextView(); label.text = text; label.isEditable = false; label.backgroundColor = .clear
        label.font = .preferredFont(forTextStyle: .body); label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(label)
        NSLayoutConstraint.activate([label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20), label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20), label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)])
    }
}

final class GainController: UIViewController {
    let model: DemoController; let microphone: Bool
    let input = UITextField(); let stepper = UIStepper(); let message = UILabel()
    private let saveButton = UIButton(type: .system)
    init(model: DemoController, microphone: Bool) { self.model = model; self.microphone = microphone; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); title = microphone ? "麦克风增益" : "振动传感器增益"; view.backgroundColor = .systemGroupedBackground
        let current = microphone ? model.snapshot?.microphoneGain : model.snapshot?.vibrationGain
        input.text = current?.stringValue; input.placeholder = "请输入 0–255"; input.keyboardType = .numberPad; input.borderStyle = .roundedRect
        input.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium); input.accessibilityIdentifier = "gainInput"
        stepper.minimumValue = 0; stepper.maximumValue = 255; stepper.stepValue = 1; stepper.value = current?.doubleValue ?? 0
        stepper.addTarget(self, action: #selector(step), for: .valueChanged)
        input.addTarget(self, action: #selector(edited), for: .editingChanged)
        message.text = "原始整数 0–255。点击保存后等待设备回读确认。"; message.numberOfLines = 0
        saveButton.setTitle("保存", for: .normal); saveButton.addTarget(self, action: #selector(self.save), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [message, input, stepper, saveButton]); stack.axis = .vertical; stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)])
    }
    func updateStatus() {
        guard isViewLoaded else { return }
        message.text = model.status
        input.isEnabled = model.flow.ready && !model.flow.busy
        stepper.isEnabled = input.isEnabled; saveButton.isEnabled = input.isEnabled
    }
    @objc private func step() { input.text = String(Int(stepper.value)) }
    @objc private func edited() { if let value = DemoFlow.gain(input.text ?? "") { stepper.value = Double(value) } }
    @objc private func save() {
        guard let value = DemoFlow.gain(input.text ?? "") else { message.text = "请输入 0–255 范围内的整数。"; return }
        guard model.flow.ready, !model.flow.busy else { message.text = "设备忙碌，请稍后重试。"; return }
        view.endEditing(true)
        model.control { completion in
            let callback: (WaveNoteError?) -> Void = { [weak self] error in completion(error); self?.message.text = self?.model.status }
            if microphone { model.sdk.deviceSettings.setMicrophoneGain(value, completion: callback) }
            else { model.sdk.deviceSettings.setVibrationGain(value, completion: callback) }
        }
        message.text = model.status
    }
}

final class PowerController: UITableViewController {
    let model: DemoController; let values = [1, 15, 30, 60, 300, 0]
    init(model: DemoController) { self.model = model; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); title = "自动关机" }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 7 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { "当前：\(DemoFlow.minutes(model.snapshot?.autoPowerOffMinutes?.intValue))\n\(model.status)" }
    override func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = path.row == 6 ? "立即关机" : DemoFlow.minutes(values[path.row])
        if path.row == 6 { cell.textLabel?.textColor = .systemRed }
        else { cell.accessoryType = model.snapshot?.autoPowerOffMinutes?.intValue == values[path.row] ? .checkmark : .none }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
        tableView.deselectRow(at: path, animated: true); guard model.flow.ready, !model.flow.busy else { return }
        if path.row == 6 {
            let alert = UIAlertController(title: "立即关机？", message: "将中断设备连接。若只有断连通知，结果仍可能未确认。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel))
            alert.addAction(UIAlertAction(title: "关机", style: .destructive) { _ in self.model.control(shutdown: true) { self.model.sdk.maintenance.shutdown(completion: $0) } }); present(alert, animated: true)
        } else {
            model.control { done in self.model.sdk.deviceSettings.setAutoPowerOff(minutes: self.values[path.row]) { error in done(error); self.tableView.reloadData() } }
            tableView.reloadData()
        }
    }
}

final class RecordingDetailController: UITableViewController {
    let model: DemoController
    private var timer: Timer?
    init(model: DemoController) { self.model = model; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() { super.viewDidLoad(); title = "当前录音" }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tableView.reloadData() }
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); timer?.invalidate(); timer = nil }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 3 }
    override func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = ["状态", "文件名称", model.recordingClock.estimated ? "录音时长（估算）" : "本次连接已观察时长"][path.row]
        let value = model.library.recording
        cell.detailTextLabel?.text = [value.state == 2 ? "正在录音" : value.state == 3 ? "录音已暂停" : value.state == 1 ? "录音已停止" : "未知", value.name ?? "未知", model.library.isRecording ? DemoRecordingClock.text(model.recordingClock.seconds()) : "—"][path.row]
        cell.detailTextLabel?.numberOfLines = 0
        return cell
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "设备没有提供总时长字段。文件名含有效 Unix 秒时间戳时据此估算，并扣除本次连接观察到的暂停；连接前的暂停无法还原。无法解析时仅累计本次观察时长。停止录音后自动同步文件。"
    }
}
