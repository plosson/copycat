import XCTest
@testable import CopycatCore

final class HTTPParserTests: XCTestCase {
    func parse(_ text: String) -> HTTPParser.Result { HTTPParser.parse(Data(text.utf8)) }

    func testCompleteRequestWithBody() {
        guard case .complete(let r) = parse("POST /copy?x=1 HTTP/1.1\r\nOrigin: https://a.com\r\nContent-Length: 2\r\n\r\n{}") else {
            return XCTFail()
        }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/copy")
        XCTAssertEqual(r.headers["origin"], "https://a.com")
        XCTAssertEqual(r.body, Data("{}".utf8))
    }

    func testHalfRequestIsIncomplete() {
        XCTAssertEqual(parse("GET /ping HTTP/1.1\r\nOrigin: https://a"), .incomplete)
        XCTAssertEqual(parse("POST /copy HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}"), .incomplete)
    }

    func testHeadersOverSixteenKilobytesAreInvalid() {
        let huge = "GET /ping HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: 17_000)
        XCTAssertEqual(parse(huge), .invalid, "no terminator yet but already too big")
        XCTAssertEqual(parse(huge + "\r\n\r\n"), .invalid)
    }

    func testBodyOverEightKilobytesIsReportedWithoutReadingIt() {
        guard case .bodyTooLarge(let r) = parse("POST /copy HTTP/1.1\r\nOrigin: https://a.com\r\nContent-Length: 9000\r\n\r\n") else {
            return XCTFail()
        }
        XCTAssertEqual(r.headers["origin"], "https://a.com")
    }

    func testChunkedBodiesAreInvalid() {
        XCTAssertEqual(parse("POST /copy HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n"), .invalid)
    }

    func testDuplicateContentLengthOrOriginIsInvalid() {
        XCTAssertEqual(parse("POST /copy HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 0\r\n\r\n{}"), .invalid)
        XCTAssertEqual(parse("GET /ping HTTP/1.1\r\nOrigin: https://a.com\r\norigin: https://b.com\r\n\r\n"), .invalid)
    }

    func testMalformedContentLengthIsInvalid() {
        for value in ["-1", "abc", "1e3", "", "99999999999999999999", "+5"] {
            XCTAssertEqual(parse("POST /copy HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n"), .invalid, value)
        }
    }

    func testMalformedRequestLinesAreInvalid() {
        for line in ["GET /ping", "GET /ping HTTP/2", "GET  /ping HTTP/1.1", "GET ping HTTP/1.1", "\u{0}\u{1} / HTTP/1.1"] {
            XCTAssertEqual(parse(line + "\r\n\r\n"), .invalid, line)
        }
    }

    func testHeaderLineWithoutColonIsInvalid() {
        XCTAssertEqual(parse("GET /ping HTTP/1.1\r\nOrigin https://a.com\r\n\r\n"), .invalid)
    }

    func testInvalidUtf8IsInvalid() {
        var bytes = Data("GET /ping HTTP/1.1\r\nX: ".utf8)
        bytes += Data([0xFF, 0xFE])
        bytes += Data("\r\n\r\n".utf8)
        XCTAssertEqual(HTTPParser.parse(bytes), .invalid)
    }
}
