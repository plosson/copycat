import Foundation
import Network

/// A tiny HTTP server for tests. Each path answers with raw bytes, optionally keeping the connection open.
final class TestHTTPServer: @unchecked Sendable {
    enum Reply {
        case close(Data)  // send, then close
        case stall(Data)  // send, then keep the connection open
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-http-server")
    private let routes: [String: Reply]
    private var open: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init(routes: [String: Reply]) throws {
        self.routes = routes
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] in self?.serve($0) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, let port = listener.port?.rawValue else {
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func stop() {
        queue.sync { open.forEach { $0.cancel() } }
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        open.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return }
            let firstLine = String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\r\n").first ?? ""
            let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            switch self.routes[path] ?? .close(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)) {
            case .close(let bytes):
                connection.send(content: bytes, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            case .stall(let bytes):
                connection.send(content: bytes, completion: .idempotent)
            }
        }
    }

    static func response(_ status: String = "200 OK", headers: [String] = [], body: Data = Data()) -> Data {
        let head = (["HTTP/1.1 \(status)", "Connection: close"] + headers).joined(separator: "\r\n") + "\r\n\r\n"
        return Data(head.utf8) + body
    }
}
