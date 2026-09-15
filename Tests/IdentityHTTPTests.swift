import XCTest
#if canImport(DemoLogic)
@testable import DemoLogic
#else
@testable import WaveNoteDemo
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
final class IdentityHTTPTests: XCTestCase {
    func body(_ owner: String = "CURRENT_USER") -> Data { Data("{\"code\":\"OK\",\"message\":\"成功\",\"requestId\":\"synthetic\",\"data\":{\"ownership\":\"\(owner)\"}}".utf8) }
    func failure(_ result: Result<String, IdentityHTTP.Failure>) -> Int? { if case .failure(let error) = result { return error.code }; return nil }
    func testEncodingAllActionsAndOnceCompletion() throws {
        var requests: [URLRequest] = []; var replies: [(Data?, Int?, Error?) -> Void] = []
        let client = try IdentityHTTP(baseURL: URL(string: "https://sandbox.invalid")!, transport: { request, done in requests.append(request); replies.append(done); return {} })
        var values: [String] = []
        for action in ["check", "bind", "unbind"] { client.request(action, serial: "synthetic-sn", user: "synthetic-user", token: "synthetic-token") { values.append((try? $0.get()) ?? "error") } }
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertNotEqual(requests[1].value(forHTTPHeaderField: "Idempotency-Key"), requests[2].value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(requests[1].timeoutInterval, 10)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: requests[1].httpBody!)) as? [String:String], ["serialNumber":"synthetic-sn", "userIdentifier":"synthetic-user"])
        replies[0](body("ANOTHER_USER"),200,nil); replies[1](body(),200,nil); replies[2](body("UNBOUND"),200,nil); replies[2](body("UNBOUND"),200,nil)
        XCTAssertEqual(values, ["ANOTHER_USER", "CURRENT_USER", "UNBOUND"])
    }
    func testCancellationAccountSwitchAndOldCallback() throws {
        var reply: ((Data?,Int?,Error?) -> Void)?; var codes: [Int?] = []; var cancelled = 0
        let client = try IdentityHTTP(baseURL: URL(string: "https://sandbox.invalid")!, transport: { _, done in reply = done; return { cancelled += 1 } })
        client.request("bind", serial: "synthetic", user: "a", token: "a") { codes.append(self.failure($0)) }
        client.cancelAll(); let old = reply
        client.request("bind", serial: "synthetic", user: "b", token: "b") { codes.append(self.failure($0)) }
        old?(body(),200,nil); XCTAssertEqual(codes, [1017]); reply?(body(),200,nil)
        XCTAssertEqual(codes, [1017,nil]); XCTAssertEqual(cancelled,1)
    }
    func testBusinessErrorsAndInvalidResponses() {
        let cases: [(Int,String,Int)] = [(400,"INVALID_ARGUMENT",1201),(401,"INVALID_CREDENTIAL",1012),(403,"USER_IDENTITY_MISMATCH",1015),(403,"BINDING_REJECTED",1007),(403,"DEVICE_NOT_OWNED",1009),(403,"UNBIND_REJECTED",1009),(409,"DEVICE_BOUND_TO_ANOTHER_USER",1004),(409,"IDEMPOTENCY_KEY_REUSED",1201),(409,"REQUEST_IN_PROGRESS",1106),(413,"PAYLOAD_TOO_LARGE",1201),(415,"UNSUPPORTED_MEDIA_TYPE",1201),(429,"RATE_LIMITED",1106),(500,"INTERNAL_ERROR",1206),(503,"SERVICE_UNAVAILABLE",1206)]
        for (status,code,expected) in cases {
            let data = Data("{\"code\":\"\(code)\",\"message\":\"x\",\"requestId\":\"trace\",\"data\":null}".utf8)
            XCTAssertEqual(failure(IdentityHTTP.parse("bind",data:data,status:status)),expected)
            XCTAssertEqual(failure(IdentityHTTP.parse("bind",data:data,status:200)),1103)
        }
        for data in [Data(),Data("<html>error</html>".utf8),Data("{}".utf8),body("FUTURE"),body("UNBOUND")] {
            XCTAssertEqual(failure(IdentityHTTP.parse("bind",data:data,status:200)),1103)
        }
        XCTAssertEqual(failure(IdentityHTTP.parse("check",data:body(),status:503)),1103)
    }
    func testTimeoutAndTransportFailure() throws {
        for (underlying, expected) in [(NSURLErrorTimedOut,1018),(NSURLErrorCannotConnectToHost,1206)] {
            let client = try IdentityHTTP(baseURL: URL(string:"https://sandbox.invalid")!, transport: { _,done in done(nil,nil,NSError(domain:NSURLErrorDomain,code:underlying));return {} })
            var codes: [Int?] = []
            client.request("check", serial:"synthetic",user:"synthetic",token:"synthetic") { codes.append(self.failure($0)) }
            XCTAssertEqual(codes,[expected])
        }
    }
    func testRejectUnsafeAddressAndToken() throws {
        for address in ["http://host", "https://token@host", "https://host?token=x", "https://host#fragment"] {
            XCTAssertThrowsError(try IdentityHTTP(baseURL:URL(string:address)!))
        }
        let client = try IdentityHTTP(baseURL:URL(string:"https://sandbox.invalid")!,transport:{ _,_ in XCTFail("must not send");return {} })
        client.request("check",serial:"s",user:"u",token:"t\r\nheader") { XCTAssertEqual(self.failure($0),1201) }
    }
}
