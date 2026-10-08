import Darwin
import XCTest
@testable import CopycatCore

final class ServerTests: XCTestCase {
    var service: FakeCopyService!
    var server: Server!

    override func setUpWithError() throws {
        service = FakeCopyService()
        server = try startServer()
    }

    override func tearDown() {
        server?.stop()
    }

    func startServer(deadline: TimeInterval = 0.5) throws -> Server {
        let s = Server(port: 0, router: Router(service: service, version: "1.0.0"), requestDeadline: deadline)
        try s.start()
        return s
    }

    func ping(origin: String = "https://a.com") -> String {
        "GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: \(origin)\r\n\r\n"
    }

    func post(_ body: String) -> String {
        "POST /copy HTTP/1.1\r\nOrigin: https://a.com\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    func testPing() throws {
        let (status, json, text) = try XCTUnwrap(RawClient.exchange(port: server.port, ping()))
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["app"], "copycat")
        XCTAssertTrue(text.contains("Access-Control-Allow-Origin: https://a.com\r\n"))
    }

    func testNoOriginIsForbidden() throws {
        let (status, _, _) = try XCTUnwrap(RawClient.exchange(port: server.port, "GET /ping HTTP/1.1\r\n\r\n"))
        XCTAssertEqual(status, 403)
    }

    func testGetAndPutOnCopyAreRefused() throws {
        for method in ["GET", "PUT"] {
            let request = "\(method) /copy HTTP/1.1\r\nOrigin: https://a.com\r\nContent-Length: 0\r\n\r\n"
            let (status, _, _) = try XCTUnwrap(RawClient.exchange(port: server.port, request))
            XCTAssertEqual(status, 405, method)
        }
        XCTAssertTrue(service.copies.isEmpty)
    }

    func testPreflightHeaders() throws {
        let request = "OPTIONS /copy HTTP/1.1\r\nOrigin: https://a.com\r\nAccess-Control-Request-Method: POST\r\nAccess-Control-Request-Private-Network: true\r\n\r\n"
        let (status, _, text) = try XCTUnwrap(RawClient.exchange(port: server.port, request))
        XCTAssertEqual(status, 204)
        XCTAssertTrue(text.contains("Access-Control-Allow-Private-Network: true\r\n"))
        XCTAssertTrue(text.contains("Access-Control-Allow-Methods: GET, POST\r\n"))
    }

    func testBodyOverEightKilobytesIsBadRequest() throws {
        let body = #"{"url":"https://a.com/a.gif","name":""# + String(repeating: "a", count: 9_000) + #""}"#
        let (status, json, _) = try XCTUnwrap(RawClient.exchange(port: server.port, post(body)))
        XCTAssertEqual(status, 400)
        XCTAssertEqual(json["error"], "bad_request")
        XCTAssertTrue(service.copies.isEmpty)
    }

    func testInvalidJsonIsBadRequest() throws {
        let (status, json, _) = try XCTUnwrap(RawClient.exchange(port: server.port, post("{not json")))
        XCTAssertEqual(status, 400)
        XCTAssertEqual(json["error"], "bad_request")
    }

    func testCopyErrorReachesTheClient() throws {
        service.error = .tooLarge
        let (status, json, _) = try XCTUnwrap(RawClient.exchange(port: server.port, post(#"{"url":"https://a.com/a.gif"}"#)))
        XCTAssertEqual(status, 413)
        XCTAssertEqual(json, ["ok": false, "error": "too_large"])
    }

    func testHeadersOverSixteenKilobytesCloseTheConnection() throws {
        let request = "GET /ping HTTP/1.1\r\nOrigin: https://a.com\r\nX-Pad: " + String(repeating: "a", count: 17_000) + "\r\n\r\n"
        XCTAssertNil(try RawClient.exchange(port: server.port, request))
    }

    func testStalledHalfRequestIsClosedAtTheDeadline() throws {
        let client = try RawClient(port: server.port)
        client.send("GET /ping HTTP/1.1\r\nOrigin: https://a")
        let start = Date()
        XCTAssertEqual(client.readToEnd(), .data(Data()))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testSlowCopyIsNotCutByTheRequestDeadline() throws {
        service.delay = 1  // longer than the 0.5 s request deadline
        let (status, _, _) = try XCTUnwrap(RawClient.exchange(port: server.port, post(#"{"url":"https://a.com/a.gif"}"#)))
        XCTAssertEqual(status, 200)
    }

    func testFiftyParallelConnectionsAreCappedAndServerRecovers() throws {
        server.stop()
        server = try startServer(deadline: 2)
        let clients = try (0..<50).map { _ in try RawClient(port: server.port, readTimeout: 0.5) }
        let closedAtOnce = clients.filter { $0.readToEnd() == .data(Data()) }.count
        XCTAssertGreaterThanOrEqual(closedAtOnce, 34, "at most 16 connections may stay open")
        Thread.sleep(forTimeInterval: 2)  // held connections hit their deadline
        let (status, _, _) = try XCTUnwrap(RawClient.exchange(port: server.port, ping()))
        XCTAssertEqual(status, 200)
    }

    func testSecondServerOnTheSamePortFailsToStart() {
        let other = Server(port: server.port, router: Router(service: service, version: "1.0.0"))
        XCTAssertThrowsError(try other.start())
    }

    func testNotReachableFromANonLoopbackInterface() throws {
        guard let address = Self.nonLoopbackIPv4() else { throw XCTSkip("no non-loopback IPv4 interface") }
        XCTAssertThrowsError(try RawClient(host: address, port: server.port, readTimeout: 1))
    }

    static func nonLoopbackIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0, entry.pointee.ifa_flags & UInt32(IFF_UP) != 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return String(cString: host)
        }
        return nil
    }
}
