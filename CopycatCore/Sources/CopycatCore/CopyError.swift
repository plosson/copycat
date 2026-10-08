import Foundation

/// Every failure Copycat reports to a web page. The raw value is the `error` code in the JSON answer.
public enum CopyError: String, Error, Equatable, Sendable {
    case badRequest = "bad_request"
    case badURL = "bad_url"
    case blockedAddress = "blocked_address"
    case denied
    case busy
    case tooLarge = "too_large"
    case fetchFailed = "fetch_failed"
    case timeout

    public var httpStatus: Int {
        switch self {
        case .badRequest, .badURL, .blockedAddress: return 400
        case .denied: return 403
        case .busy: return 429
        case .tooLarge: return 413
        case .fetchFailed: return 502
        case .timeout: return 504
        }
    }

    /// Text for the failure notification.
    public var message: String {
        switch self {
        case .badRequest: return "The page sent an invalid request."
        case .badURL: return "The link is not a valid https address."
        case .blockedAddress: return "The link points to a private network address."
        case .denied: return "This site is not allowed to copy files."
        case .busy: return "Copycat is busy. Try again in a moment."
        case .tooLarge: return "The file is larger than 100 MB."
        case .fetchFailed: return "The download failed."
        case .timeout: return "The download took too long."
        }
    }
}
