import XCTest
@testable import CopycatCore

final class CacheJanitorTests: XCTestCase {
    var dir: URL!
    let now = Date()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    func folder(_ name: String = UUID().uuidString, age: TimeInterval) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url.appendingPathComponent("a.gif"))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    func remaining() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
    }

    func testKeepsOnlyTheTwentyNewest() throws {
        let folders = try (0..<25).map { try folder(age: TimeInterval($0 * 60)) }
        CacheJanitor.prune(dir, now: now)
        XCTAssertEqual(try remaining(), Set(folders.prefix(20).map(\.lastPathComponent)))
    }

    func testDeletesFoldersOlderThanADayEvenWhenFew() throws {
        let fresh = try folder(age: 60)
        try folder(age: 86_401)
        CacheJanitor.prune(dir, now: now)
        XCTAssertEqual(try remaining(), [fresh.lastPathComponent])
    }

    func testNeverTouchesFoldersOrFilesNotNamedWithAUuid() throws {
        try folder("Important", age: 999_999)
        try Data("x".utf8).write(to: dir.appendingPathComponent(UUID().uuidString))
        CacheJanitor.prune(dir, keep: 0, now: now)
        XCTAssertEqual(try remaining().count, 2)
    }

    func testMissingDirectoryDoesNotCrash() {
        CacheJanitor.prune(dir.appendingPathComponent("nope"), now: now)
    }
}
