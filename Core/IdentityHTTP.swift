import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 示例 HTTP 边界。Token 只存在请求内存；不持久化、不记录请求/响应原文。
public final class IdentityHTTP: @unchecked Sendable {
    public struct Failure: Error { public let code: Int }
    public typealias Transport = (URLRequest, @escaping (Data?, Int?, Error?) -> Void) -> () -> Void
    private let base: URL
    private let transport: Transport
    private let lock = NSLock()
    private var pending: [UUID: (cancel: () -> Void, done: (Result<String, Failure>) -> Void)] = [:]
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 10
        config.urlCache = nil; config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()
    public init(baseURL: URL, transport: Transport? = nil) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else { throw Failure(code: 1201) }
        base = baseURL
        self.transport = transport ?? { request, done in
            let task = Self.session.dataTask(with: request) { data, response, error in
                done(data, (response as? HTTPURLResponse)?.statusCode, error)
            }
            task.resume(); return { task.cancel() }
        }
    }
    /// 每次调用是新的逻辑请求；默认不重试，幂等键随本次 URLRequest 固定。
    public func request(_ action: String, serial: String, user: String, token: String,
                        done: @escaping (Result<String, Failure>) -> Void) {
        guard ["check", "bind", "unbind"].contains(action), !user.isEmpty, !serial.isEmpty,
              !token.isEmpty, !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { done(.failure(Failure(code: 1201))); return }
        var request = URLRequest(url: base.appendingPathComponent("v1/device-bindings/\(action)"), timeoutInterval: 10)
        request.httpMethod = "POST"; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if action != "check" { request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["serialNumber": serial, "userIdentifier": user])
        let id = UUID()
        lock.lock(); pending[id] = ({}, done); lock.unlock()
        let cancel = transport(request) { [weak self] data, status, error in
            let result: Result<String, Failure>
            if let error {
                let ns = error as NSError
                result = .failure(Failure(code: ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut ? 1018 : ns.code == NSURLErrorCancelled ? 1017 : 1206))
            } else { result = Self.parse(action, data: data, status: status) }
            self?.finish(id, result)
        }
        lock.lock()
        if let entry = pending[id] { pending[id] = (cancel, entry.done); lock.unlock() }
        else { lock.unlock(); cancel() }
    }
    private func finish(_ id: UUID, _ result: Result<String, Failure>) {
        lock.lock(); let entry = pending.removeValue(forKey: id); lock.unlock()
        entry?.done(result)
    }
    /// 切换账号/环境时调用；迟到和重复网络结果不会再次完成旧请求。
    public func cancelAll() {
        lock.lock(); let entries = Array(pending.values); pending.removeAll(); lock.unlock()
        for entry in entries { entry.cancel(); entry.done(.failure(Failure(code: 1017))) }
    }
    public static func parse(_ action: String, data: Data?, status: Int?) -> Result<String, Failure> {
        func fail(_ code: Int = 1103) -> Result<String, Failure> { .failure(Failure(code: code)) }
        guard let data, let status, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = obj["code"] as? String, obj["message"] is String,
              let requestID = obj["requestId"] as? String, !requestID.isEmpty else { return fail() }
        if status == 200 && code == "OK" {
            guard let value = (obj["data"] as? [String: Any])?["ownership"] as? String,
                  ["UNBOUND", "CURRENT_USER", "ANOTHER_USER"].contains(value),
                  action == "check" || (action == "bind" && value == "CURRENT_USER") || (action == "unbind" && value == "UNBOUND") else { return fail() }
            return .success(value)
        }
        let errors: [String: (Int, Int)] = [
            "INVALID_ARGUMENT": (400,1201), "INVALID_CREDENTIAL": (401,1012), "USER_IDENTITY_MISMATCH": (403,1015),
            "BINDING_REJECTED": (403,1007), "DEVICE_NOT_OWNED": (403,1009), "UNBIND_REJECTED": (403,1009),
            "DEVICE_BOUND_TO_ANOTHER_USER": (409,1004), "IDEMPOTENCY_KEY_REUSED": (409,1201), "REQUEST_IN_PROGRESS": (409,1106),
            "PAYLOAD_TOO_LARGE": (413,1201), "UNSUPPORTED_MEDIA_TYPE": (415,1201), "RATE_LIMITED": (429,1106),
            "INTERNAL_ERROR": (500,1206), "SERVICE_UNAVAILABLE": (503,1206)]
        guard obj["data"] is NSNull, let mapping = errors[code], status == mapping.0 else { return fail() }
        return fail(mapping.1)
    }
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
