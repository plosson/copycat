import Foundation

/// Turns one parsed request into one response. Knows HTTP and CORS, nothing about downloads.
public struct Router: Sendable {
    let service: CopyService
    let version: String

    public init(service: CopyService, version: String) {
        self.service = service
        self.version = version
    }

    public func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard let rawOrigin = request.headers["origin"], let origin = Origin.normalize(rawOrigin) else {
            return Self.json(403, ["ok": false, "error": CopyError.denied.rawValue], origin: nil)
        }
        switch (request.method, request.path) {
        case ("OPTIONS", _):
            return HTTPResponse(status: 204, headers: Self.cors(rawOrigin) + [
                ("Access-Control-Allow-Methods", "GET, POST"),
                ("Access-Control-Allow-Headers", "Content-Type"),
                ("Access-Control-Allow-Private-Network", "true"),
            ], body: Data())
        case ("GET", "/ping"):
            let permission = await service.permission(for: origin)
            return Self.json(200, ["app": "copycat", "version": version, "permission": permission.rawValue], origin: rawOrigin)
        case ("POST", "/copy"):
            guard let copy = try? JSONDecoder().decode(CopyRequest.self, from: request.body), !copy.url.isEmpty else {
                return Self.failure(.badRequest, origin: rawOrigin)
            }
            do {
                try await service.copy(copy, from: origin)
                return Self.json(200, ["ok": true], origin: rawOrigin)
            } catch {
                return Self.failure(error as? CopyError ?? .fetchFailed, origin: rawOrigin)
            }
        case (_, "/ping"), (_, "/copy"):
            return Self.json(405, ["ok": false, "error": CopyError.badRequest.rawValue], origin: rawOrigin)
        default:
            return Self.json(404, ["ok": false, "error": CopyError.badRequest.rawValue], origin: rawOrigin)
        }
    }

    /// The answer when the declared body is over 8 KB.
    public func respondBodyTooLarge(_ request: HTTPRequest) -> HTTPResponse {
        let origin = request.headers["origin"].flatMap { Origin.normalize($0) == nil ? nil : $0 }
        return Self.failure(.badRequest, origin: origin)
    }

    static func failure(_ error: CopyError, origin: String?) -> HTTPResponse {
        json(error.httpStatus, ["ok": false, "error": error.rawValue], origin: origin)
    }

    static func cors(_ origin: String) -> [(String, String)] {
        [("Access-Control-Allow-Origin", origin), ("Vary", "Origin")]
    }

    static func json(_ status: Int, _ object: [String: Any], origin: String?) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: (origin.map(cors) ?? []) + [("Content-Type", "application/json")], body: body)
    }
}
