import Foundation

/// Decides whether Copycat may download from a URL.
public struct URLPolicy: Sendable {
    /// Development setting: also allow `http://localhost` and `http://127.0.0.1`.
    public var allowLocalHTTP: Bool
    var resolve: @Sendable (String) throws -> [IPAddress]

    public init(
        allowLocalHTTP: Bool = false,
        resolve: @escaping @Sendable (String) throws -> [IPAddress] = { try IPAddress.resolve($0) }
    ) {
        self.allowLocalHTTP = allowLocalHTTP
        self.resolve = resolve
    }

    /// Throws `CopyError.badURL` or `CopyError.blockedAddress`.
    public func check(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(),
              let rawHost = url.host, !rawHost.isEmpty,
              url.user == nil, url.password == nil
        else { throw CopyError.badURL }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        // Parsers disagree on forms like `0177.0.0.1` (octal or decimal?), so only plain dotted quads pass.
        if Self.looksNumeric(host) && !Self.isDottedQuad(host) { throw CopyError.badURL }

        if allowLocalHTTP, scheme == "http", host == "localhost" || host == "127.0.0.1" { return }
        guard scheme == "https" else { throw CopyError.badURL }

        let addresses = try resolve(host)
        if addresses.isEmpty || addresses.contains(where: \.isBlocked) {
            throw CopyError.blockedAddress
        }
    }

    static func looksNumeric(_ host: String) -> Bool {
        host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            part.allSatisfy(\.isASCIIDigit)
                || (part.hasPrefix("0x") && part.dropFirst(2).allSatisfy(\.isHexDigit))
        }
    }

    static func isDottedQuad(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCIIDigit)
                && (part == "0" || !part.hasPrefix("0")) && Int(part)! <= 255
        }
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
