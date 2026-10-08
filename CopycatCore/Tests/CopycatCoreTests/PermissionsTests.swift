import XCTest
@testable import CopycatCore

/// Answers after an optional delay, or waits until cancelled when `answer` is nil.
actor FakePrompter: Prompter {
    let answer: PromptAnswer?
    private(set) var asked: [String] = []
    private(set) var cancelled = 0

    init(_ answer: PromptAnswer?) { self.answer = answer }

    func ask(origin: String) async -> PromptAnswer {
        asked.append(origin)
        if let answer { return answer }
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
        cancelled += 1
        return .dismissed
    }

    func waitUntilAsked() async {
        while asked.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}

final class Clock: @unchecked Sendable {
    var current = Date(timeIntervalSince1970: 1_000_000)
}

final class OriginTests: XCTestCase {
    func testNormalizesCaseAndKeepsPort() {
        XCTAssertEqual(Origin.normalize("HTTPS://Example.COM"), "https://example.com")
        XCTAssertEqual(Origin.normalize("https://example.com:8443"), "https://example.com:8443")
        XCTAssertEqual(Origin.normalize("http://localhost:3000"), "http://localhost:3000")
    }

    func testRefusesOriginsThatAreNotPlainHttpOrigins() {
        for raw in ["null", "", "file://", "chrome-extension://abcdef", "https://", "https://a.com/path",
                    "https://user@a.com", "https://a.com?x=1", "javascript:alert(1)", "example.com"] {
            XCTAssertNil(Origin.normalize(raw), raw)
        }
    }

    func testHostForPrompt() {
        XCTAssertEqual(Origin.host(of: "https://example.com:8443"), "example.com")
    }
}

final class PermissionStoreTests: XCTestCase {
    var defaults: UserDefaults!
    var store: DefaultsPermissionStore!

    override func setUp() {
        let suite = "copycat-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = DefaultsPermissionStore(defaults: defaults)
    }

    func testUnknownOriginIsPrompt() {
        XCTAssertEqual(store.get("https://a.com"), .prompt)
    }

    func testOriginsDifferingOnlyByPortOrSchemeAreDistinct() {
        store.set("https://a.com", .granted)
        XCTAssertEqual(store.get("https://a.com:8443"), .prompt)
        XCTAssertEqual(store.get("http://a.com"), .prompt)
    }

    func testSettingPromptForgetsTheOrigin() {
        store.set("https://a.com", .denied)
        store.set("https://a.com", .prompt)
        XCTAssertEqual(store.all(), [:])
    }

    func testCorruptStoredValuesCountAsUnknownNotGranted() {
        defaults.set(["https://a.com": "yes", "https://b.com": 1, "https://c.com": "prompt", "https://d.com": "granted"],
                     forKey: DefaultsPermissionStore.key)
        XCTAssertEqual(store.get("https://a.com"), .prompt)
        XCTAssertEqual(store.get("https://b.com"), .prompt)
        XCTAssertEqual(store.all(), ["https://d.com": .granted])
    }

    func testStoredValueOfWrongShapeIsIgnored() {
        defaults.set("granted", forKey: DefaultsPermissionStore.key)
        XCTAssertEqual(store.get("https://a.com"), .prompt)
        store.set("https://a.com", .granted)
        XCTAssertEqual(store.get("https://a.com"), .granted)
    }
}

final class GatekeeperTests: XCTestCase {
    var store: DefaultsPermissionStore!
    let a = "https://a.com"
    let b = "https://b.com"

    override func setUp() {
        let suite = "copycat-test-\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        store = DefaultsPermissionStore(defaults: UserDefaults(suiteName: suite)!)
    }

    func gate(_ prompter: FakePrompter, timeout: TimeInterval = 60, clock: Clock = Clock()) -> Gatekeeper {
        Gatekeeper(store: store, prompter: prompter, promptTimeout: timeout, now: { clock.current })
    }

    func assertAdmit(_ gate: Gatekeeper, _ origin: String, throws expected: CopyError, line: UInt = #line) async {
        do {
            try await gate.admit(origin)
            XCTFail("expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? CopyError, expected, line: line)
        }
    }

    func testDeniedOriginNeverPrompts() async {
        store.set(a, .denied)
        let prompter = FakePrompter(.allow)
        await assertAdmit(gate(prompter), a, throws: .denied)
        let asked = await prompter.asked
        XCTAssertEqual(asked, [])
    }

    func testAllowIsRemembered() async throws {
        let prompter = FakePrompter(.allow)
        let g = gate(prompter)
        try await g.admit(a)
        await g.finish(a)
        try await g.admit(a)
        let asked = await prompter.asked
        XCTAssertEqual(asked, [a])
        XCTAssertEqual(store.get(a), .granted)
    }

    func testDenyIsRememberedAndReleasesTheOrigin() async {
        let g = gate(FakePrompter(.deny))
        await assertAdmit(g, a, throws: .denied)
        XCTAssertEqual(store.get(a), .denied)
        await assertAdmit(g, a, throws: .denied)
    }

    func testSecondPromptWhileOneIsOpenIsBusy() async {
        let prompter = FakePrompter(nil)
        let g = gate(prompter)
        let first = Task { try await g.admit(a) }
        await prompter.waitUntilAsked()
        await assertAdmit(g, b, throws: .busy)
        first.cancel()
        _ = await first.result
    }

    func testGrantedOriginIsNotBlockedByAnotherOriginsPrompt() async throws {
        store.set(b, .granted)
        let prompter = FakePrompter(nil)
        let g = gate(prompter)
        let first = Task { try await g.admit(a) }
        await prompter.waitUntilAsked()
        try await g.admit(b)
        first.cancel()
        _ = await first.result
    }

    func testSameOriginTwiceInParallelIsBusy() async throws {
        store.set(a, .granted)
        let g = gate(FakePrompter(nil))
        try await g.admit(a)
        await assertAdmit(g, a, throws: .busy)
        await g.finish(a)
        try await g.admit(a)
    }

    func testSameUnknownOriginTwiceWhilePromptingIsBusy() async {
        let prompter = FakePrompter(nil)
        let g = gate(prompter, timeout: 0.2)
        async let first: Void = g.admit(a)
        await prompter.waitUntilAsked()
        await assertAdmit(g, a, throws: .busy)
        _ = try? await first
    }

    func testThirtyFirstCopyInAMinuteIsBusyThenAllowedLater() async throws {
        store.set(a, .granted)
        let clock = Clock()
        let g = gate(FakePrompter(nil), clock: clock)
        for _ in 0..<30 {
            try await g.admit(a)
            await g.finish(a)
            clock.current += 1
        }
        await assertAdmit(g, a, throws: .busy)
        clock.current += 31  // the first copies are now over a minute old
        try await g.admit(a)
    }

    func testRateLimitIsPerOrigin() async throws {
        store.set(a, .granted)
        store.set(b, .granted)
        let g = gate(FakePrompter(nil))
        for _ in 0..<30 {
            try await g.admit(a)
            await g.finish(a)
        }
        try await g.admit(b)
    }

    func testClosingThePromptIsTimeoutAndOriginStaysUnknown() async {
        let prompter = FakePrompter(.dismissed)
        let clock = Clock()
        let g = gate(prompter, clock: clock)
        await assertAdmit(g, a, throws: .timeout)
        XCTAssertEqual(store.get(a), .prompt)
        clock.current += 61
        await assertAdmit(g, a, throws: .timeout)
        let asked = await prompter.asked
        XCTAssertEqual(asked.count, 2, "a closed prompt can be asked again later")
    }

    func testDismissedOriginCannotPromptAgainForAMinute() async {
        let prompter = FakePrompter(.dismissed)
        let clock = Clock()
        let g = gate(prompter, clock: clock)
        await assertAdmit(g, a, throws: .timeout)
        clock.current += 59
        await assertAdmit(g, a, throws: .busy)
        let asked = await prompter.asked
        XCTAssertEqual(asked, [a], "a site must not pop the prompt again right after it was closed")
    }

    func testUnansweredPromptAlsoStartsTheCooldown() async {
        let prompter = FakePrompter(nil)
        let g = gate(prompter, timeout: 0.2)
        await assertAdmit(g, a, throws: .timeout)
        await assertAdmit(g, a, throws: .busy)
    }

    func testUnansweredPromptTimesOutAndClosesTheWindow() async {
        let prompter = FakePrompter(nil)
        let g = gate(prompter, timeout: 0.2)
        await assertAdmit(g, a, throws: .timeout)
        let cancelled = await prompter.cancelled
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(store.get(a), .prompt)
        await assertAdmit(g, b, throws: .timeout)  // the prompt slot is free again
    }
}
