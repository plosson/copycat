import Foundation

public enum Origin {
    /// `scheme://host[:port]`, lower-cased, for http and https origins only. `nil` for anything else, including `null`.
    public static func normalize(_ raw: String) -> String? {
        guard let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/"
        else { return nil }
        return parts.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// The host part, for the prompt's headline.
    public static func host(of origin: String) -> String {
        URLComponents(string: origin)?.host ?? origin
    }
}
