import Foundation

/// 只管理 Demo 的交互任务；SDK 仍负责身份和设备应答校验。
final class DemoFlow {
    enum Route { case bind, connect }
    private(set) var generation = 0
    private(set) var busy = false
    private(set) var ready = false
    private var awaitingBind = false
    private(set) var selecting = false
    var showsNearby: Bool { !selecting && !ready }

    func select(bound: Bool, fresh: Bool) -> (Int, Route)? {
        guard !busy, !ready, fresh else { return nil }
        generation += 1; busy = true; selecting = true; awaitingBind = !bound
        return (generation, bound ? .connect : .bind)
    }
    func bound(_ token: Int, success: Bool) -> Bool {
        guard accepts(token), awaitingBind else { return false }
        awaitingBind = false
        if !success { busy = false; selecting = false }
        return success
    }
    func connected() { selecting = false; ready = true; busy = false; awaitingBind = false }
    func invalidate() { selecting = false; generation += 1; ready = false; busy = false; awaitingBind = false }
    /// SDK 停止扫描也会报告 disconnected，不能取消正在进行的绑定选择。
    func disconnected() {
        guard !selecting else { return }
        if ready || busy { invalidate() }
    }
    func accepts(_ token: Int) -> Bool { generation == token }
    func beginSetting() -> Int? {
        guard ready, !busy else { return nil }; generation += 1; busy = true; return generation
    }
    func finish(_ token: Int) -> Bool {
        guard accepts(token), ready else { return false }; busy = false; return true
    }
    static func gain(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text), (0...255).contains(value) else { return nil }
        return value
    }
    static func minutes(_ value: Int?) -> String {
        guard let value else { return "未知" }; return value == 0 ? "永不" : "\(value) 分钟"
    }
}

/// 注入持久化函数，测试不接触真实用户数据；实际存储只使用摘要。
final class DemoOwnershipStore {
    private let read: () -> [String: String]
    private let write: ([String: String]) -> Void
    init(read: @escaping () -> [String: String], write: @escaping ([String: String]) -> Void) { self.read = read; self.write = write }
    func owner(_ key: String) -> String? { read()[key] }
    func bind(_ key: String, user: String) -> Bool {
        var values = read(); guard values[key] == nil || values[key] == user else { return false }
        values[key] = user; write(values); return true
    }
    func unbind(_ key: String, user: String) -> Bool {
        var values = read(); guard values[key] == nil || values[key] == user else { return false }
        values.removeValue(forKey: key); write(values); return true
    }
}

/// 顺序读取器：失败即停止，取消会话后忽略回调，重复回调不能多推进一项。
enum DemoReadSequence {
    static func run<Item, Failure>(_ items: [Item], active: @escaping () -> Bool,
        query: @escaping (Item, @escaping (Failure?) -> Void) -> Void,
        finished: @escaping (Failure?) -> Void) {
        var index = 0; var waiting = false; var ended = false
        func next() {
            guard active(), !ended else { return }
            if index == items.count { ended = true; finished(nil); return }
            let current = index; waiting = true
            query(items[current]) { error in
                guard active(), !ended, waiting, current == index else { return }
                waiting = false
                if let error { ended = true; finished(error) }
                else { index += 1; next() }
            }
        }
        next()
    }
}

enum DemoValues {
    static func usb(_ raw: Int?) -> String { raw == 1 ? "已开启" : raw == 0 ? "已关闭" : "未知" }
    static func canSetUSB(_ raw: Int?) -> Bool { raw == 0 || raw == 1 }
    static func error(_ code: Int) -> String {
        switch code {
        case 1016: return "扫描结果已过期，请重新扫描后选择设备。"
        case 1001: return "蓝牙不可用，请检查权限和蓝牙开关。"
        case 1004: return "设备已绑定其他账户，无法连接。"
        case 1203: return "结果未确认，请检查设备状态；不会自动重试。"
        case 1102: return "设备应答超时，连接已关闭；请重新扫描连接。"
        case 1005, 1011, 1106: return "设备忙碌，请停止录音或等待当前操作完成后重试。"
        case 1202: return "设备拒绝设置或回读不一致，未确认保存成功。"
        default: return "操作未完成（\(code)），请检查设备状态后重试。"
        }
    }
}
