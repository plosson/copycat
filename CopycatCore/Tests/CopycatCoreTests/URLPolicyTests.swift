import XCTest
@testable import CopycatCore

final class URLPolicyTests: XCTestCase {
    let policy = URLPolicy()

    func assertRefused(_ string: String, _ expected: CopyError, policy: URLPolicy? = nil, line: UInt = #line) {
        let url = URL(string: string)
        XCTAssertNotNil(url, "URL(string:) refused \(string)", line: line)
        guard let url else { return }
        XCTAssertThrowsError(try (policy ?? self.policy).check(url), line: line) {
            XCTAssertEqual($0 as? CopyError, expected, string, line: line)
        }
    }

    func testNonHttpsSchemesAreBadUrls() {
        assertRefused("http://example.com/a.gif", .badURL)
        assertRefused("file:///etc/passwd", .badURL)
        assertRefused("javascript:alert(1)", .badURL)
        assertRefused("data:image/gif;base64,R0lGODlh", .badURL)
        assertRefused("ftp://example.com/a.gif", .badURL)
    }

    func testCredentialsInUrlAreBadUrls() {
        assertRefused("https://user:pw@example.com/a.gif", .badURL)
        assertRefused("https://user@example.com/a.gif", .badURL)
    }

    func testPrivateIPv4LiteralsAreBlocked() {
        for host in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1",
                     "169.254.169.254", "100.64.0.1", "0.0.0.0"] {
            assertRefused("https://\(host)/a.gif", .blockedAddress)
        }
    }

    func testPrivateIPv6LiteralsAreBlocked() {
        for host in ["[::1]", "[::]", "[fc00::1]", "[fd12:3456::1]", "[fe80::1]", "[::ffff:127.0.0.1]",
                     "[::ffff:192.168.0.1]", "[::ffff:7f00:1]"] {
            assertRefused("https://\(host)/a.gif", .blockedAddress)
        }
    }

    func testDecimalOctalAndHexIPv4FormsAreBadUrls() {
        // Non-canonical numeric hosts are refused outright: getaddrinfo reads 0177 as decimal, browsers as octal.
        for host in ["2130706433", "0177.0.0.1", "0x7f.1", "0x7f000001", "167772161", "127.1", "1.2.3.256", "1..2.3"] {
            assertRefused("https://\(host)/a.gif", .badURL)
        }
    }

    func testOrdinaryNamesWithDigitsAreNotTreatedAsNumeric() {
        let p = URLPolicy(resolve: { _ in [.v4(0x5DB8_D822)] })
        XCTAssertNoThrow(try p.check(URL(string: "https://123.com/a.gif")!))
        XCTAssertNoThrow(try p.check(URL(string: "https://cdn1.0x7f.net/a.gif")!))
    }

    func testRangeEdgesNextToPrivateRangesAreAllowed() throws {
        for host in ["172.15.255.255", "172.32.0.0", "100.63.255.255", "100.128.0.0", "11.0.0.0"] {
            let p = URLPolicy()
            XCTAssertNoThrow(try p.check(URL(string: "https://\(host)/a.gif")!), host)
        }
    }

    func testPublicNameResolvingToPrivateAddressIsBlocked() {
        let p = URLPolicy(resolve: { _ in [.v4(0x5DB8_D822), .v4(0x0A00_0001)] })  // public + 10.0.0.1
        assertRefused("https://innocent.example/a.gif", .blockedAddress, policy: p)
    }

    func testNameResolvingToNothingIsBlocked() {
        let p = URLPolicy(resolve: { _ in [] })
        assertRefused("https://empty.example/a.gif", .blockedAddress, policy: p)
    }

    func testUnresolvableNameIsFetchFailed() {
        let p = URLPolicy(resolve: { _ in throw CopyError.fetchFailed })
        assertRefused("https://nx.example/a.gif", .fetchFailed, policy: p)
    }

    func testPublicAddressIsAllowed() {
        let p = URLPolicy(resolve: { _ in [.v4(0x5DB8_D822)] })
        XCTAssertNoThrow(try p.check(URL(string: "https://example.com/a.gif")!))
    }

    func testLocalHttpNeedsTheDevelopmentSetting() {
        assertRefused("http://localhost:8080/a.gif", .badURL)
        let dev = URLPolicy(allowLocalHTTP: true)
        XCTAssertNoThrow(try dev.check(URL(string: "http://localhost:8080/a.gif")!))
        XCTAssertNoThrow(try dev.check(URL(string: "http://127.0.0.1:8080/a.gif")!))
        assertRefused("http://192.168.1.1/a.gif", .badURL, policy: dev)
        assertRefused("http://example.com/a.gif", .badURL, policy: dev)
        assertRefused("https://localhost/a.gif", .blockedAddress, policy: dev)
    }
}
