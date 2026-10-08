import AppKit
import XCTest
@testable import CopycatCore

/// Writes fixed bytes into a fresh cache folder, like the real Fetcher, or fails.
final class FakeFetcher: Fetching, @unchecked Sendable {
    let cache: URL
    var bytes = Data("GIF89a".utf8) + Data(repeating: 1, count: 20)
    var contentType: String? = "image/gif"
    var error: CopyError?
    var delay: TimeInterval = 0
    private(set) var calls = 0

    init(cache: URL) { self.cache = cache }

    func fetch(_ url: URL) async throws -> FetchedFile {
        calls += 1
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let error { throw error }
        let folder = cache.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(".partial")
        try bytes.write(to: file)
        return FetchedFile(fileURL: file, contentType: contentType, head: bytes.prefix(16))
    }
}

final class RecordingFeedback: FeedbackSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    var events: [String] { lock.withLock { _events } }
    func working() { lock.withLock { _events.append("working") } }
    func succeeded() { lock.withLock { _events.append("succeeded") } }
    func failed(_ error: CopyError) { lock.withLock { _events.append("failed:\(error.rawValue)") } }
}

final class CopyPipelineTests: XCTestCase {
    var cache: URL!
    var pasteboard: NSPasteboard!
    var store: DefaultsPermissionStore!
    var fetcher: FakeFetcher!
    var feedback: RecordingFeedback!
    let origin = "https://a.com"

    override func setUpWithError() throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        pasteboard = NSPasteboard(name: .init("copycat-test-\(UUID().uuidString)"))
        let suite = "copycat-test-\(UUID().uuidString)"
        store = DefaultsPermissionStore(defaults: UserDefaults(suiteName: suite)!)
        store.set(origin, .granted)
        fetcher = FakeFetcher(cache: cache)
        feedback = RecordingFeedback()
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: cache)
    }

    func pipeline() -> CopyPipeline {
        let gate = Gatekeeper(store: store, prompter: FakePrompter(.deny))
        return CopyPipeline(gatekeeper: gate, fetcher: fetcher, writer: PasteboardWriter(pasteboard: pasteboard),
                            feedback: feedback, cacheDirectory: cache)
    }

    func assertCopy(_ p: CopyPipeline, _ request: CopyRequest, from origin: String? = nil, throws expected: CopyError, line: UInt = #line) async {
        do {
            try await p.copy(request, from: origin ?? self.origin)
            XCTFail("expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? CopyError, expected, line: line)
        }
    }

    func testCopiesGifUnderTheDetectedName() async throws {
        try await pipeline().copy(CopyRequest(url: "https://a.com/x/clip.mp4", name: "funny"), from: origin)
        let stored = try XCTUnwrap(pasteboard.pasteboardItems?.first?.string(forType: .fileURL))
        let file = try XCTUnwrap(URL(string: stored))
        XCTAssertEqual(file.lastPathComponent, "funny.gif")
        XCTAssertEqual(try Data(contentsOf: file), fetcher.bytes)
        XCTAssertEqual(feedback.events, ["succeeded"])
    }

    func testCopiedFileIsQuarantinedLikeABrowserDownload() async throws {
        fetcher.bytes = Data("PK\u{3}\u{4}not really a zip".utf8)
        fetcher.contentType = nil
        try await pipeline().copy(CopyRequest(url: "https://a.com/x", type: "application/zip"), from: origin)
        let stored = try XCTUnwrap(pasteboard.pasteboardItems?.first?.string(forType: .fileURL))
        let file = try XCTUnwrap(URL(string: stored))
        let size = getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0)
        XCTAssertGreaterThan(size, 0, "the file must carry com.apple.quarantine so Gatekeeper checks anything opened from it")
    }

    func testDeniedOriginNeverFetchesAndGivesNoFeedback() async {
        store.set(origin, .denied)
        await assertCopy(pipeline(), CopyRequest(url: "https://a.com/a.gif"), throws: .denied)
        XCTAssertEqual(fetcher.calls, 0)
        XCTAssertEqual(feedback.events, [])
    }

    func testFetchFailureIsReportedAndReleasesTheOrigin() async throws {
        let p = pipeline()
        fetcher.error = .tooLarge
        await assertCopy(p, CopyRequest(url: "https://a.com/a.gif"), throws: .tooLarge)
        XCTAssertEqual(feedback.events, ["failed:too_large"])
        fetcher.error = nil
        try await p.copy(CopyRequest(url: "https://a.com/a.gif"), from: origin)  // not busy
    }

    func testEmptyUrlIsBadUrlAfterAdmission() async {
        await assertCopy(pipeline(), CopyRequest(url: ""), throws: .badURL)
        XCTAssertEqual(fetcher.calls, 0)
    }

    func testFailedCopyLeavesTheClipboardAlone() async {
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)
        fetcher.error = .fetchFailed
        await assertCopy(pipeline(), CopyRequest(url: "https://a.com/a.gif"), throws: .fetchFailed)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testSlowDownloadShowsWorkingFirst() async throws {
        fetcher.delay = 0.5
        try await pipeline().copy(CopyRequest(url: "https://a.com/a.gif"), from: origin)
        XCTAssertEqual(feedback.events, ["working", "succeeded"])
    }

    func testFastDownloadNeverShowsWorking() async throws {
        try await pipeline().copy(CopyRequest(url: "https://a.com/a.gif"), from: origin)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(feedback.events, ["succeeded"])
    }
}
