import UniformTypeIdentifiers
import XCTest
@testable import CopycatCore

final class TypeDetectorTests: XCTestCase {
    let gifBytes = Data("GIF89a".utf8) + Data([0x01, 0x00, 0x01, 0x00])
    let page = URL(string: "https://example.com/files/clip.mp4")!

    func testGifBytesNamedMp4AreAGif() {
        let type = TypeDetector.detectType(head: gifBytes, hint: "video/mp4", contentType: "video/mp4", url: page)
        XCTAssertEqual(type, .gif)
        XCTAssertEqual(TypeDetector.fileName(hint: nil, url: page, type: type), "clip.gif")
    }

    func testEmptyFileFallsBackWithoutCrashing() {
        let url = URL(string: "https://example.com/download")!
        XCTAssertEqual(TypeDetector.detectType(head: Data(), hint: nil, contentType: nil, url: url), .data)
    }

    func testThreeByteFileIsNotSniffed() {
        XCTAssertNil(TypeDetector.sniff(Data("GIF".utf8)))
        XCTAssertNil(TypeDetector.sniff(Data([0x89, 0x50, 0x4E])))
    }

    func testHtmlErrorPageServedAsGifIsNotAGif() {
        let html = Data("<!DOCTYPE html><html>404</html>".utf8)
        let url = URL(string: "https://example.com/a.gif")!
        let type = TypeDetector.detectType(head: html, hint: "image/gif", contentType: "image/gif", url: url)
        XCTAssertNotEqual(type, .gif)
        XCTAssertFalse(TypeDetector.fileName(hint: nil, url: url, type: type).hasSuffix(".gif"))
    }

    func testWebPWithWrongRiffSizeIsStillWebP() {
        var bytes = Data("RIFF".utf8)
        bytes += Data([0xFF, 0xFF, 0xFF, 0xFF])
        bytes += Data("WEBPVP8 ".utf8)
        XCTAssertEqual(TypeDetector.sniff(bytes), .webP)
    }

    func testRiffWithoutWebPMarkerIsNotWebP() {
        XCTAssertNil(TypeDetector.sniff(Data("RIFF\0\0\0\0WAVEfmt ".utf8)))
    }

    func testQuickTimeBrandIsMov() {
        let mov = Data([0, 0, 0, 0x14]) + Data("ftypqt  ".utf8)
        XCTAssertEqual(TypeDetector.sniff(mov), .quickTimeMovie)
        let mp4 = Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8)
        XCTAssertEqual(TypeDetector.sniff(mp4), .mpeg4Movie)
    }

    func testContentTypeParametersAreIgnored() {
        let url = URL(string: "https://example.com/x")!
        let type = TypeDetector.detectType(head: Data("%PDF-1.7".utf8), hint: nil, contentType: "Application/PDF; charset=binary", url: url)
        XCTAssertEqual(type, .pdf)
    }

    func testUnknownMimeHintIsIgnored() {
        let url = URL(string: "https://example.com/x")!
        XCTAssertEqual(TypeDetector.detectType(head: Data("hello".utf8), hint: "made/up", contentType: nil, url: url), .data)
    }

    func testPathTraversalNameIsFlattened() {
        let name = TypeDetector.fileName(hint: "../../etc/passwd", url: page, type: .gif)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.hasPrefix("."))
        XCTAssertTrue(name.hasSuffix(".gif"))
    }

    func testHiddenNameLosesLeadingDot() {
        XCTAssertEqual(TypeDetector.fileName(hint: ".hidden", url: page, type: .gif), "hidden.gif")
    }

    func testFiveHundredCharacterNameIsCapped() {
        let name = TypeDetector.fileName(hint: String(repeating: "a", count: 500), url: page, type: .gif)
        XCTAssertLessThanOrEqual(name.count, 120)
        XCTAssertTrue(name.hasSuffix(".gif"))
    }

    func testNullBytesAndControlCharactersAreRemoved() {
        let name = TypeDetector.fileName(hint: "a\u{0}b\u{7}c\u{202E}d.gif", url: page, type: .gif)
        XCTAssertEqual(name, "abcd.gif")
    }

    func testEmojiNameStaysWithinFileSystemByteLimit() {
        let name = TypeDetector.fileName(hint: String(repeating: "🐱", count: 200), url: page, type: .gif)
        XCTAssertLessThanOrEqual(name.utf8.count, 240)
        XCTAssertTrue(name.hasPrefix("🐱"))
        XCTAssertTrue(name.hasSuffix(".gif"))
    }

    func testNameWithoutExtensionGetsTheDetectedOne() {
        XCTAssertEqual(TypeDetector.fileName(hint: "funny", url: page, type: .mpeg4Movie), "funny.mp4")
    }

    func testNameMadeOnlyOfDotsAndSlashesFallsBackToUrlThenDefault() {
        let bare = URL(string: "https://example.com/")!
        let name = TypeDetector.fileName(hint: "/../.", url: bare, type: .gif, now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasPrefix("copycat-19700101-"), name)
        XCTAssertTrue(name.hasSuffix(".gif"))
    }

    func testUnknownTypeGetsBinExtension() {
        XCTAssertEqual(TypeDetector.fileName(hint: "a.gif", url: page, type: .data), "a.bin")
    }
}
