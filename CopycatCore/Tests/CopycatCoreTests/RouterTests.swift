import XCTest
@testable import CopycatCore

final class FakeCopyService: CopyService, @unchecked Sendable {
    var permission: Permission = .prompt
    var error: CopyError?
    var delay: TimeInterval = 0
    private(set) var copies: [(CopyRequest, String)] = []

    func permission(for origin: String) async -> Permission { permission }

    func copy(_ request: CopyRequest, from origin: String) async throws {
        copies.append((request, origin))
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let error { throw error }
    }
}

final class RouterTests: XCTestCase {
    let service = FakeCopyService()
    lazy var router = Router(service: service, version: "1.2.3")

    func request(_ method: String, _ path: String, origin: String? = "https://A.com", body: String = "") -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: origin.map { ["origin": $0] } ?? [:], body: Data(body.utf8))
    }

    func json(_ r: HTTPResponse) -> [String: AnyHashable] {
        (try? JSONSerialization.jsonObject(with: r.body)) as? [String: AnyHashable] ?? [:]
    }

    func testPingEchoesOriginAndReportsPermission() async {
        service.permission = .granted
        let r = await router.respond(to: request("GET", "/ping"))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.header("Access-Control-Allow-Origin"), "https://A.com")
        XCTAssertEqual(r.header("Vary"), "Origin")
        XCTAssertEqual(r.header("Content-Type"), "application/json")
        XCTAssertEqual(json(r), ["app": "copycat", "version": "1.2.3", "permission": "granted"])
    }

    func testMissingOriginIsForbiddenWithoutCorsHeaders() async {
        let r = await router.respond(to: request("GET", "/ping", origin: nil))
        XCTAssertEqual(r.status, 403)
        XCTAssertNil(r.header("Access-Control-Allow-Origin"))
    }

    func testNullOriginIsForbiddenAndNeverReachesTheService() async {
        let r = await router.respond(to: request("POST", "/copy", origin: "null", body: #"{"url":"https://a.com/a.gif"}"#))
        XCTAssertEqual(r.status, 403)
        XCTAssertTrue(service.copies.isEmpty)
    }

    func testPreflightAnswersWithAllCorsHeaders() async {
        let r = await router.respond(to: request("OPTIONS", "/copy"))
        XCTAssertEqual(r.status, 204)
        XCTAssertEqual(r.header("Access-Control-Allow-Methods"), "GET, POST")
        XCTAssertEqual(r.header("Access-Control-Allow-Headers"), "Content-Type")
        XCTAssertEqual(r.header("Access-Control-Allow-Private-Network"), "true")
        XCTAssertEqual(r.header("Access-Control-Allow-Origin"), "https://A.com")
    }

    func testWrongMethodsAreRefused() async {
        for method in ["GET", "PUT", "DELETE"] {
            let r = await router.respond(to: request(method, "/copy"))
            XCTAssertEqual(r.status, 405, method)
        }
        let r = await router.respond(to: request("POST", "/ping"))
        XCTAssertEqual(r.status, 405)
        XCTAssertTrue(service.copies.isEmpty)
    }

    func testUnknownPathIsNotFound() async {
        let r = await router.respond(to: request("GET", "/admin"))
        XCTAssertEqual(r.status, 404)
    }

    func testCopyPassesNormalizedOriginAndHints() async throws {
        let r = await router.respond(to: request("POST", "/copy", body: #"{"url":"https://a.com/a.gif","type":"image/gif","name":"a.gif"}"#))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(json(r), ["ok": true])
        let (copy, origin) = try XCTUnwrap(service.copies.first)
        XCTAssertEqual(origin, "https://a.com")
        XCTAssertEqual(copy.url, "https://a.com/a.gif")
        XCTAssertEqual(copy.type, "image/gif")
        XCTAssertEqual(copy.name, "a.gif")
    }

    func testBadBodiesAreBadRequests() async {
        for body in ["", "not json", "{}", #"{"url":5}"#, #"{"url":""}"#, #"["https://a.com"]"#, #"{"url":"https://a.com","name":7}"#] {
            let r = await router.respond(to: request("POST", "/copy", body: body))
            XCTAssertEqual(r.status, 400, body)
            XCTAssertEqual(json(r), ["ok": false, "error": "bad_request"], body)
        }
        XCTAssertTrue(service.copies.isEmpty)
    }

    func testCopyErrorsMapToTheirStatus() async {
        let cases: [(CopyError, Int)] = [(.badURL, 400), (.blockedAddress, 400), (.denied, 403), (.busy, 429),
                                         (.tooLarge, 413), (.fetchFailed, 502), (.timeout, 504)]
        for (error, status) in cases {
            service.error = error
            let r = await router.respond(to: request("POST", "/copy", body: #"{"url":"https://a.com/a.gif"}"#))
            XCTAssertEqual(r.status, status, error.rawValue)
            XCTAssertEqual(json(r), ["ok": false, "error": error.rawValue])
            XCTAssertEqual(r.header("Access-Control-Allow-Origin"), "https://A.com")
        }
    }

    func testBodyTooLargeIsBadRequest() {
        let r = router.respondBodyTooLarge(request("POST", "/copy"))
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(json(r), ["ok": false, "error": "bad_request"])
    }

    func testSerializedResponseHasLengthAndClose() {
        let text = String(decoding: Router.json(200, ["ok": true], origin: "https://a.com").serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }
}
