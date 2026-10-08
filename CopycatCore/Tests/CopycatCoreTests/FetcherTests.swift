import XCTest
@testable import CopycatCore

final class FetcherTests: XCTestCase {
    var cache: URL!
    var server: TestHTTPServer!
    let gif = Data("GIF89a".utf8) + Data(repeating: 0x2A, count: 100)

    override func setUpWithError() throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let big = Data(repeating: 0x41, count: 5_000)
        server = try TestHTTPServer(routes: [
            "/ok.gif": .close(TestHTTPServer.response(headers: ["Content-Type: image/gif", "Content-Length: \(gif.count)"], body: gif)),
            "/big-no-length": .close(TestHTTPServer.response(body: big)),
            "/big-declared": .close(TestHTTPServer.response(headers: ["Content-Length: 5000"], body: big)),
            "/lying-length": .close(TestHTTPServer.response(headers: ["Content-Length: 10"], body: big)),
            "/stall": .stall(TestHTTPServer.response(headers: ["Content-Length: 1000"], body: Data("GIF89a".utf8))),
            "/missing": .close(TestHTTPServer.response("404 Not Found", headers: ["Content-Length: 0"])),
            "/to-http": .close(TestHTTPServer.response("302 Found", headers: ["Location: http://example.com/a.gif", "Content-Length: 0"])),
            "/to-private": .close(TestHTTPServer.response("302 Found", headers: ["Location: https://10.0.0.1/a.gif", "Content-Length: 0"])),
            "/to-localhost-http": .close(TestHTTPServer.response("302 Found", headers: ["Location: http://127.0.0.1:1/a.gif", "Content-Length: 0"])),
        ])
        try server.start()
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: cache)
    }

    func fetcher(maxBytes: Int = 1_000, idle: TimeInterval = 10) -> Fetcher {
        Fetcher(cacheDirectory: cache, policy: { URLPolicy(allowLocalHTTP: true) }, maxBytes: maxBytes, idleTimeout: idle)
    }

    func assertFails(_ path: String, _ expected: CopyError, _ f: Fetcher? = nil, line: UInt = #line) async {
        do {
            _ = try await (f ?? fetcher()).fetch(server.url(path))
            XCTFail("expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? CopyError, expected, line: line)
        }
    }

    func cacheFolders() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
    }

    func testDownloadsIntoAFreshCacheFolder() async throws {
        let file = try await fetcher().fetch(server.url("/ok.gif"))
        XCTAssertEqual(try Data(contentsOf: file.fileURL), gif)
        XCTAssertEqual(file.head, gif.prefix(16))
        XCTAssertEqual(file.contentType, "image/gif")
        XCTAssertEqual(file.fileURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL, cache.standardizedFileURL)
    }

    func testOverLimitWithoutContentLengthIsCutOff() async {
        await assertFails("/big-no-length", .tooLarge)
        XCTAssertEqual(cacheFolders(), [], "partial download must be deleted")
    }

    func testDeclaredContentLengthOverLimitIsRefused() async {
        await assertFails("/big-declared", .tooLarge)
    }

    func testContentLengthLowerThanBodyNeverExceedsLimit() async throws {
        do {
            let file = try await fetcher().fetch(server.url("/lying-length"))
            let size = try FileManager.default.attributesOfItem(atPath: file.fileURL.path)[.size] as! Int
            XCTAssertLessThanOrEqual(size, 1_000)
        } catch {
            XCTAssertEqual(error as? CopyError, .fetchFailed)
        }
    }

    func testStalledDownloadTimesOut() async {
        let start = Date()
        await assertFails("/stall", .timeout, fetcher(idle: 1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testNotFoundIsFetchFailed() async {
        await assertFails("/missing", .fetchFailed)
    }

    func testRedirectToHttpIsRefused() async {
        await assertFails("/to-http", .badURL)
    }

    func testRedirectToLocalHttpIsRefusedEvenWithDevelopmentSetting() async {
        await assertFails("/to-localhost-http", .badURL)
    }

    func testRedirectToPrivateAddressIsRefused() async {
        await assertFails("/to-private", .blockedAddress)
    }

    func testPolicyIsCheckedBeforeAnyConnection() async {
        let strict = Fetcher(cacheDirectory: cache, policy: { URLPolicy() })
        await assertFails("/ok.gif", .badURL, strict)
        XCTAssertEqual(cacheFolders(), [])
    }
}
