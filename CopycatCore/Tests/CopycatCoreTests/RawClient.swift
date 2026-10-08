import Darwin
import Foundation

/// Plain BSD sockets, so tests can send exactly the bytes they want.
final class RawClient {
    let fd: Int32

    init(host: String = "127.0.0.1", port: UInt16, readTimeout: TimeInterval = 3) throws {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let ai = list else { throw POSIXError(.EINVAL) }
        defer { freeaddrinfo(ai) }
        let fd = socket(ai.pointee.ai_family, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(readTimeout), tv_usec: Int32((readTimeout - floor(readTimeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        self.fd = fd
    }

    deinit { Darwin.close(fd) }

    func send(_ text: String) { send(Data(text.utf8)) }

    func send(_ data: Data) {
        _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, data.count, 0) }
    }

    enum ReadResult: Equatable {
        case data(Data)  // the server closed after sending this (possibly empty)
        case timedOut    // still open when the read timeout expired
    }

    /// Reads until the server closes the connection.
    func readToEnd() -> ReadResult {
        var all = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n > 0 { all.append(contentsOf: chunk[0..<n]); continue }
            if n == 0 || errno == ECONNRESET { return .data(all) }
            return .timedOut
        }
    }

    /// Sends a request and returns the status code and JSON body, or nil when the server closed without answering.
    static func exchange(port: UInt16, _ request: String, host: String = "127.0.0.1") throws -> (Int, [String: AnyHashable], String)? {
        let client = try RawClient(host: host, port: port)
        client.send(request)
        guard case .data(let bytes) = client.readToEnd(), !bytes.isEmpty else { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        let status = Int(text.split(separator: " ")[1]) ?? 0
        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: AnyHashable] ?? [:]
        return (status, json, text)
    }
}
