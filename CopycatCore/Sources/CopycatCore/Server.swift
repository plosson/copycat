import Foundation
import Network

/// Listens on 127.0.0.1 only, one request per connection.
/// Not on ::1: Network.framework refuses to bind 127.0.0.1 and ::1 to the same port, and copycat.js always calls 127.0.0.1.
public final class Server: @unchecked Sendable {
    public static let defaultPort: UInt16 = 47823

    let router: Router
    let maxConnections: Int
    let requestDeadline: TimeInterval
    private let queue = DispatchQueue(label: "copycat.server")
    private var listener: NWListener?
    private var openConnections = 0
    public private(set) var port: UInt16

    /// `port` 0 picks a free port (for tests); read `port` after `start()`.
    public init(port: UInt16 = Server.defaultPort, router: Router, maxConnections: Int = 16, requestDeadline: TimeInterval = 5) {
        self.port = port
        self.router = router
        self.maxConnections = maxConnections
        self.requestDeadline = requestDeadline
    }

    /// Blocks until the listener is ready. Throws when the port is in use.
    public func start() throws {
        let listener = try listen(port: port)
        port = listener.port?.rawValue ?? port
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func listen(port: UInt16) throws -> NWListener {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        params.acceptLocalOnly = true
        let listener = try NWListener(using: params)

        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error), .waiting(let error):
                failure = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 2) == .timedOut { failure = NWError.posix(.ETIMEDOUT) }
        if let failure {
            listener.cancel()
            throw failure
        }
        listener.stateUpdateHandler = nil
        return listener
    }

    /// Runs on `queue`.
    private func accept(_ connection: NWConnection) {
        guard openConnections < maxConnections else {
            connection.cancel()
            return
        }
        openConnections += 1
        Connection(connection, router: router, queue: queue, deadline: requestDeadline) { [weak self] in
            self?.openConnections -= 1
        }.start()
    }
}

/// One client connection. Everything runs on the server queue.
final class Connection: @unchecked Sendable {
    let connection: NWConnection
    let router: Router
    let queue: DispatchQueue
    let deadline: TimeInterval
    let onClose: () -> Void
    private var buffer = Data()
    private var gotRequest = false
    private var closed = false

    init(_ connection: NWConnection, router: Router, queue: DispatchQueue, deadline: TimeInterval, onClose: @escaping () -> Void) {
        self.connection = connection
        self.router = router
        self.queue = queue
        self.deadline = deadline
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: close()
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + deadline) { [self] in
            if !gotRequest { close() }
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
            guard !closed else { return }
            if let data { buffer.append(data) }
            switch HTTPParser.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { close() } else { receive() }
            case .invalid:
                close()
            case .bodyTooLarge(let request):
                gotRequest = true
                send(router.respondBodyTooLarge(request))
            case .complete(let request):
                gotRequest = true
                let router = self.router
                Task {
                    let response = await router.respond(to: request)
                    self.queue.async { self.send(response) }
                }
            }
        }
    }

    private func send(_ response: HTTPResponse) {
        guard !closed else { return }
        connection.send(content: response.serialized(), isComplete: true, completion: .contentProcessed { [self] _ in
            close()
        })
    }

    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose()
    }
}
