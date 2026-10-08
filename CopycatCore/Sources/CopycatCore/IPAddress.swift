import Darwin
import Foundation

/// A resolved IP address, and whether Copycat refuses to connect to it.
public enum IPAddress: Equatable, Sendable {
    case v4(UInt32)
    case v6([UInt8])

    /// IPv4 ranges Copycat never downloads from: (network, prefix length).
    static let blockedV4: [(UInt32, UInt32)] = [
        (0x7F00_0000, 8),   // 127.0.0.0/8
        (0x0A00_0000, 8),   // 10.0.0.0/8
        (0xAC10_0000, 12),  // 172.16.0.0/12
        (0xC0A8_0000, 16),  // 192.168.0.0/16
        (0xA9FE_0000, 16),  // 169.254.0.0/16
        (0x6440_0000, 10),  // 100.64.0.0/10
        (0x0000_0000, 8),   // 0.0.0.0/8
    ]

    public var isBlocked: Bool {
        switch self {
        case .v4(let address):
            return Self.blockedV4.contains { network, prefix in
                let mask: UInt32 = prefix == 0 ? 0 : ~0 << (32 - prefix)
                return address & mask == network
            }
        case .v6(let b):
            guard b.count == 16 else { return true }
            let zeroPrefix = b[0..<10].allSatisfy { $0 == 0 }
            if zeroPrefix && b[10] == 0xFF && b[11] == 0xFF {  // ::ffff:a.b.c.d
                let v4 = b[12...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                return IPAddress.v4(v4).isBlocked
            }
            if b[0..<15].allSatisfy({ $0 == 0 }) && (b[15] == 0 || b[15] == 1) { return true }  // :: and ::1
            if b[0] & 0xFE == 0xFC { return true }  // fc00::/7
            if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return true }  // fe80::/10
            return false
        }
    }

    /// Resolves a host name or IP literal (including forms like `2130706433` or `0177.0.0.1`).
    public static func resolve(_ host: String) throws -> [IPAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else {
            throw CopyError.fetchFailed
        }
        defer { freeaddrinfo(first) }

        var addresses: [IPAddress] = []
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let sockaddr = entry.pointee.ai_addr else { continue }
            switch entry.pointee.ai_family {
            case AF_INET:
                sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    addresses.append(.v4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr)))
                }
            case AF_INET6:
                sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    addresses.append(.v6(withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }))
                }
            default:
                continue
            }
        }
        return addresses
    }
}
