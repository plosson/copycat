import Foundation

public enum Permission: String, Sendable {
    case granted, denied, prompt
}

public protocol PermissionStore: AnyObject, Sendable {
    func get(_ origin: String) -> Permission
    /// `.prompt` forgets the origin.
    func set(_ origin: String, _ permission: Permission)
    func all() -> [String: Permission]
}

/// Stores `{ origin: "granted" | "denied" }` under one UserDefaults key.
public final class DefaultsPermissionStore: PermissionStore, @unchecked Sendable {
    public static let key = "permissions"
    let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func get(_ origin: String) -> Permission {
        all()[origin] ?? .prompt
    }

    public func set(_ origin: String, _ permission: Permission) {
        lock.lock()
        defer { lock.unlock() }
        var raw = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        raw[origin] = permission == .prompt ? nil : permission.rawValue
        defaults.set(raw, forKey: Self.key)
    }

    public func all() -> [String: Permission] {
        let raw = defaults.dictionary(forKey: Self.key) ?? [:]
        return raw.compactMapValues { value in
            // Anything that is not exactly "granted" or "denied" counts as unknown.
            (value as? String).flatMap(Permission.init(rawValue:)).flatMap { $0 == .prompt ? nil : $0 }
        }
    }
}

public enum PromptAnswer: Sendable {
    case allow, deny, dismissed
}

public protocol Prompter: Sendable {
    /// Shows the prompt and waits for the user. When the calling task is cancelled
    /// the prompt must close itself and return `.dismissed`.
    func ask(origin: String) async -> PromptAnswer
}

/// Decides whether a copy from an origin may go ahead: stored answers, the prompt, one copy at a time per origin, rate limit.
public actor Gatekeeper {
    let store: PermissionStore
    let prompter: Prompter
    let promptTimeout: TimeInterval
    let maxCopies: Int
    let window: TimeInterval
    let promptCooldown: TimeInterval
    let now: @Sendable () -> Date

    private var promptOpen = false
    private var inFlight: Set<String> = []
    private var history: [String: [Date]] = [:]
    /// When each origin's prompt was last closed without an answer, so a page cannot pop it again at once.
    private var dismissed: [String: Date] = [:]

    public init(
        store: PermissionStore, prompter: Prompter, promptTimeout: TimeInterval = 60,
        maxCopies: Int = 30, window: TimeInterval = 60, promptCooldown: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.prompter = prompter
        self.promptTimeout = promptTimeout
        self.maxCopies = maxCopies
        self.window = window
        self.promptCooldown = promptCooldown
        self.now = now
    }

    public func permission(for origin: String) -> Permission {
        store.get(origin)
    }

    /// Returns when the copy may start; the caller must then call `finish(_:)`.
    /// Throws `CopyError.denied`, `.busy` or `.timeout`.
    public func admit(_ origin: String) async throws {
        switch store.get(origin) {
        case .denied:
            throw CopyError.denied
        case .granted:
            try reserve(origin)
        case .prompt:
            if promptOpen { throw CopyError.busy }
            if let last = dismissed[origin], now().timeIntervalSince(last) < promptCooldown { throw CopyError.busy }
            try reserve(origin)
            promptOpen = true
            let answer = await askWithTimeout(origin)
            promptOpen = false
            switch answer {
            case .allow:
                store.set(origin, .granted)
            case .deny:
                store.set(origin, .denied)
                finish(origin)
                throw CopyError.denied
            case .dismissed:
                dismissed[origin] = now()
                finish(origin)
                throw CopyError.timeout
            }
        }
    }

    public func finish(_ origin: String) {
        inFlight.remove(origin)
    }

    private func reserve(_ origin: String) throws {
        if inFlight.contains(origin) { throw CopyError.busy }
        let cutoff = now().addingTimeInterval(-window)
        var recent = history[origin, default: []].filter { $0 > cutoff }
        defer { history[origin] = recent }
        if recent.count >= maxCopies { throw CopyError.busy }
        recent.append(now())
        inFlight.insert(origin)
    }

    private func askWithTimeout(_ origin: String) async -> PromptAnswer {
        let prompter = self.prompter
        let timeout = UInt64(promptTimeout * 1_000_000_000)
        return await withTaskGroup(of: PromptAnswer.self) { group in
            group.addTask { await prompter.ask(origin: origin) }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout)
                return .dismissed
            }
            let first = await group.next() ?? .dismissed
            group.cancelAll()
            return first
        }
    }
}
