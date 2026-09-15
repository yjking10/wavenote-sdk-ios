import Foundation
import WaveNoteSDK

/// 宿主示例；真实登录由应用提供。模拟归属只存本次进程内存。
final class HTTPIdentityProvider: NSObject, WaveNoteIdentityProvider {
    let http: IdentityHTTP?
    private var owners: [String: String] = [:]
    init(http: IdentityHTTP?) { self.http = http }
    func checkOwnership(serialNumber: String, apiKey: String, userIdentifier: String, completion: @escaping (WaveNoteOwnership, WaveNoteError?) -> Void) {
        guard let http else {
            completion(owners[serialNumber] == nil ? .unbound : owners[serialNumber] == userIdentifier ? .currentUser : .anotherUser, nil); return
        }
        http.request("check", serial: serialNumber, user: userIdentifier, token: apiKey) { result in
            switch result {
            case .success(let value): completion(value == "UNBOUND" ? .unbound : value == "CURRENT_USER" ? .currentUser : .anotherUser, nil)
            case .failure(let error): completion(.unbound, Self.error(error, "check"))
            }
        }
    }
    func bind(serialNumber: String, apiKey: String, userIdentifier: String, completion: @escaping (WaveNoteError?) -> Void) {
        change("bind", serial: serialNumber, token: apiKey, user: userIdentifier, done: completion)
    }
    func unbind(serialNumber: String, apiKey: String, userIdentifier: String, completion: @escaping (WaveNoteError?) -> Void) {
        change("unbind", serial: serialNumber, token: apiKey, user: userIdentifier, done: completion)
    }
    private func change(_ action: String, serial: String, token: String, user: String, done: @escaping (WaveNoteError?) -> Void) {
        if let http {
            http.request(action, serial: serial, user: user, token: token) { result in
                switch result { case .success: done(nil); case .failure(let error): done(Self.error(error, action)) }
            }
        } else {
            guard owners[serial] == nil || owners[serial] == user else {
                done(WaveNoteError(action == "bind" ? .deviceBoundToAnotherUser : .cloudUnbindFailed, operation: "simulation", message: "归属不匹配")); return
            }
            owners[serial] = action == "bind" ? user : nil; done(nil)
        }
    }
    private static func error(_ error: IdentityHTTP.Failure, _ action: String) -> WaveNoteError {
        WaveNoteError(WaveNoteErrorCode(rawValue: error.code) ?? .invalidDeviceResponse, operation: "server.\(action)", message: "身份请求未完成，请按错误码处理")
    }
}
