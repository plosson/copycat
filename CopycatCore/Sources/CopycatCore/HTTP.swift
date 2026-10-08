import Foundation

public struct HTTPRequest: Sendable, Equatable {
    public let method: String
    /// Path without the query string.
    public let path: String
    /// Header names are lower-cased.
    public let headers: [String: String]
    public let body: Data
}

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [(String, String)]
    public let body: Data

    public static func == (l: HTTPResponse, r: HTTPResponse) -> Bool {
        l.status == r.status && l.body == r.body && l.headers.map { "\($0.0): \($0.1)" } == r.headers.map { "\($0.0): \($0.1)" }
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    static let reasons = [
        200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 413: "Payload Too Large", 429: "Too Many Requests",
        502: "Bad Gateway", 504: "Gateway Timeout",
    ]

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Unknown")\r\n"
        for (name, value) in headers + [("Content-Length", "\(body.count)"), ("Connection", "close")] {
            head += "\(name): \(value)\r\n"
        }
        return Data((head + "\r\n").utf8) + body
    }
}

/// Parses one HTTP/1.1 request from the bytes received so far.
public enum HTTPParser {
    public static let maxHead = 16 * 1024
    public static let maxBody = 8 * 1024

    public enum Result: Equatable {
        case incomplete
        case complete(HTTPRequest)
        /// Headers are fine but the declared body is over `maxBody`; the body is not read.
        case bodyTooLarge(HTTPRequest)
        /// Anything else: the connection is closed without an answer.
        case invalid
    }

    public static func parse(_ buffer: Data) -> Result {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else {
            return buffer.count > maxHead ? .invalid : .incomplete
        }
        let headEnd = end.upperBound - buffer.startIndex
        guard headEnd <= maxHead,
              let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8)
        else { return .invalid }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0",
              !requestLine[0].isEmpty, requestLine[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
              requestLine[1].hasPrefix("/")
        else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { return .invalid }
            // Two Content-Length or Origin headers are ambiguous: refuse rather than guess.
            if headers[name] != nil, name == "content-length" || name == "origin" { return .invalid }
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        if headers["transfer-encoding"] != nil { return .invalid }

        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.allSatisfy(\.isASCIIDigit), raw.count <= 9, let value = Int(raw) else { return .invalid }
            length = value
        } else {
            length = 0
        }

        let path = String(requestLine[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let method = String(requestLine[0])
        if length > maxBody {
            return .bodyTooLarge(HTTPRequest(method: method, path: path, headers: headers, body: Data()))
        }
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let body = Data(buffer[bodyStart..<bodyStart + length])
        return .complete(HTTPRequest(method: method, path: path, headers: headers, body: body))
    }
}
