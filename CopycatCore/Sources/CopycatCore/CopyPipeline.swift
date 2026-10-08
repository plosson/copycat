import CoreServices
import Foundation
import UniformTypeIdentifiers

/// The JSON body of `POST /copy`.
public struct CopyRequest: Decodable, Sendable {
    public let url: String
    public let type: String?
    public let name: String?

    public init(url: String, type: String? = nil, name: String? = nil) {
        self.url = url
        self.type = type
        self.name = name
    }
}

/// All the HTTP server knows about Copycat.
public protocol CopyService: Sendable {
    func permission(for origin: String) async -> Permission
    /// Throws `CopyError` only.
    func copy(_ request: CopyRequest, from origin: String) async throws
}

/// Menu bar icon, sound and notification. Called from any thread.
public protocol FeedbackSink: Sendable {
    func working()
    func succeeded()
    func failed(_ error: CopyError)
}

/// Permissions → Fetcher → Type detector → Pasteboard writer → Feedback.
public final class CopyPipeline: CopyService, @unchecked Sendable {
    let gatekeeper: Gatekeeper
    let fetcher: Fetching
    let writer: PasteboardWriter
    let feedback: FeedbackSink
    let cacheDirectory: URL
    let workingDelay: TimeInterval

    public init(
        gatekeeper: Gatekeeper, fetcher: Fetching, writer: PasteboardWriter, feedback: FeedbackSink,
        cacheDirectory: URL, workingDelay: TimeInterval = 0.3
    ) {
        self.gatekeeper = gatekeeper
        self.fetcher = fetcher
        self.writer = writer
        self.feedback = feedback
        self.cacheDirectory = cacheDirectory
        self.workingDelay = workingDelay
    }

    public func permission(for origin: String) async -> Permission {
        await gatekeeper.permission(for: origin)
    }

    public func copy(_ request: CopyRequest, from origin: String) async throws {
        // Refusals before admission (denied, busy, prompt timeout) give no feedback,
        // so a page cannot flood the user with notifications.
        try await gatekeeper.admit(origin)

        let feedback = self.feedback
        let delay = UInt64(workingDelay * 1_000_000_000)
        let pulse = Task {
            try await Task.sleep(nanoseconds: delay)
            feedback.working()
        }
        do {
            guard let url = URL(string: request.url) else { throw CopyError.badURL }
            let fetched = try await fetcher.fetch(url)
            let type = TypeDetector.detectType(head: fetched.head, hint: request.type, contentType: fetched.contentType, url: url)
            let name = TypeDetector.fileName(hint: request.name, url: url, type: type)
            let file = fetched.fileURL.deletingLastPathComponent().appendingPathComponent(name)
            try FileManager.default.moveItem(at: fetched.fileURL, to: file)
            try Self.quarantine(file, from: url)
            try writer.write(fileURL: file, type: type)
            pulse.cancel()
            await gatekeeper.finish(origin)
            feedback.succeeded()
            CacheJanitor.prune(cacheDirectory)
        } catch {
            pulse.cancel()
            await gatekeeper.finish(origin)
            let copyError = error as? CopyError ?? .fetchFailed
            feedback.failed(copyError)
            throw copyError
        }
    }

    /// Marks the file as downloaded from the web, so Gatekeeper checks anything opened from it.
    static func quarantine(_ file: URL, from source: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "Copycat",
            kLSQuarantineDataURLKey as String: source,
        ]
        var file = file
        try file.setResourceValues(values)
    }
}
