import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import CopycatCore

final class PasteboardWriterTests: XCTestCase {
    var pasteboard: NSPasteboard!
    var dir: URL!

    override func setUpWithError() throws {
        pasteboard = NSPasteboard(name: .init("copycat-test-\(UUID().uuidString)"))
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: dir)
    }

    func file(_ name: String, _ bytes: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func testGifGetsFileUrlAndGifData() throws {
        let bytes = Data("GIF89a-animated".utf8)
        let url = try file("a.gif", bytes)
        try PasteboardWriter(pasteboard: pasteboard).write(fileURL: url, type: .gif)
        let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(item.string(forType: .fileURL), url.absoluteString)
        XCTAssertEqual(item.data(forType: .init("com.compuserve.gif")), bytes)
    }

    func testVideoGetsFileUrlOnly() throws {
        let url = try file("a.mp4", Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8))
        try PasteboardWriter(pasteboard: pasteboard).write(fileURL: url, type: .mpeg4Movie)
        let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertEqual(item.types, [.fileURL])
    }

    func testPreviousClipboardIsReplaced() throws {
        pasteboard.clearContents()
        pasteboard.setString("old text", forType: .string)
        let url = try file("a.png", Data([0x89, 0x50, 0x4E, 0x47]))
        try PasteboardWriter(pasteboard: pasteboard).write(fileURL: url, type: .png)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testMissingFileLeavesClipboardUntouched() {
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)
        let missing = dir.appendingPathComponent("gone.gif")
        XCTAssertThrowsError(try PasteboardWriter(pasteboard: pasteboard).write(fileURL: missing, type: .gif))
        XCTAssertThrowsError(try PasteboardWriter(pasteboard: pasteboard).write(fileURL: missing, type: .mpeg4Movie))
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testFileNameWithSpacesAndEmojiRoundTrips() throws {
        let url = try file("my cat 🐱.gif", Data("GIF89a".utf8))
        try PasteboardWriter(pasteboard: pasteboard).write(fileURL: url, type: .gif)
        let stored = try XCTUnwrap(pasteboard.pasteboardItems?.first?.string(forType: .fileURL))
        XCTAssertEqual(URL(string: stored)?.path, url.path)
    }
}
