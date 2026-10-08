import Foundation

public struct FetchedFile: Sendable {
    /// The downloaded bytes, inside a fresh `<cache>/<uuid>/` folder.
    public let fileURL: URL
    public let contentType: String?
    /// The first 16 bytes, for the type detector.
    public let head: Data
}

public protocol Fetching: Sendable {
    func fetch(_ url: URL) async throws -> FetchedFile
}

/// Downloads one file with the address checks and limits from the spec.
public final class Fetcher: Fetching, @unchecked Sendable {
    let cacheDirectory: URL
    let policy: @Sendable () -> URLPolicy
    let maxBytes: Int
    let idleTimeout: TimeInterval
    let totalTimeout: TimeInterval

    public init(
        cacheDirectory: URL,
        policy: @escaping @Sendable () -> URLPolicy,
        maxBytes: Int = 100 * 1024 * 1024,
        idleTimeout: TimeInterval = 10,
        totalTimeout: TimeInterval = 60
    ) {
        self.cacheDirectory = cacheDirectory
        self.policy = policy
        self.maxBytes = maxBytes
        self.idleTimeout = idleTimeout
        self.totalTimeout = totalTimeout
    }

    /// Throws `CopyError` only.
    public func fetch(_ url: URL) async throws -> FetchedFile {
        let policy = self.policy()
        try policy.check(url)

        let folder = cacheDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw CopyError.fetchFailed
        }

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = idleTimeout
        config.timeoutIntervalForResource = totalTimeout

        let download = Download(destination: folder.appendingPathComponent(".partial"), maxBytes: maxBytes, policy: policy)
        let session = URLSession(configuration: config, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            return try await download.run(session.dataTask(with: url))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

/// One download. URLSession calls the delegate methods one at a time on its own serial queue.
final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let destination: URL
    let maxBytes: Int
    let policy: URLPolicy

    private var continuation: CheckedContinuation<FetchedFile, Error>?
    private var handle: FileHandle?
    private var received = 0
    private var head = Data()
    private var contentType: String?
    private var failure: CopyError?

    init(destination: URL, maxBytes: Int, policy: URLPolicy) {
        self.destination = destination
        self.maxBytes = maxBytes
        self.policy = policy
    }

    func run(_ task: URLSessionDataTask) async throws -> FetchedFile {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            task.resume()
        }
    }

    private func fail(_ error: CopyError, _ task: URLSessionTask) {
        if failure == nil { failure = error }
        task.cancel()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, url.scheme?.lowercased() == "https" else {
            fail(.badURL, task)
            return completionHandler(nil)
        }
        do {
            try policy.check(url)
            completionHandler(request)
        } catch {
            fail(error as? CopyError ?? .fetchFailed, task)
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard failure == nil,
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else {
            fail(.fetchFailed, dataTask)
            return completionHandler(.cancel)
        }
        if http.expectedContentLength > maxBytes {
            fail(.tooLarge, dataTask)
            return completionHandler(.cancel)
        }
        contentType = http.value(forHTTPHeaderField: "Content-Type")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination)
        else {
            fail(.fetchFailed, dataTask)
            return completionHandler(.cancel)
        }
        self.handle = handle
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += data.count
        guard received <= maxBytes else { return fail(.tooLarge, dataTask) }
        if head.count < 16 { head.append(data.prefix(16 - head.count)) }
        do {
            try handle?.write(contentsOf: data)
        } catch {
            fail(.fetchFailed, dataTask)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        guard let continuation else { return }
        self.continuation = nil
        if let failure {
            continuation.resume(throwing: failure)
        } else if let error = error as? URLError {
            continuation.resume(throwing: error.code == .timedOut ? CopyError.timeout : CopyError.fetchFailed)
        } else if error != nil {
            continuation.resume(throwing: CopyError.fetchFailed)
        } else {
            continuation.resume(returning: FetchedFile(fileURL: destination, contentType: contentType, head: head))
        }
    }
}
