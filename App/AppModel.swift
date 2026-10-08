import AppKit
import CopycatCore
import ServiceManagement
import SwiftUI

enum IconState {
    case idle, working, succeeded, failed
}

struct Site: Identifiable {
    let origin: String
    let permission: Permission
    var id: String { origin }
}

@MainActor
final class AppModel: ObservableObject {
    nonisolated static let soundKey = "soundOn"
    nonisolated static let localHTTPKey = "allowLocalHTTP"

    @Published private(set) var icon: IconState = .idle
    @Published private(set) var sites: [Site] = []
    @Published private(set) var serverError: String?
    @Published var soundOn: Bool {
        didSet { UserDefaults.standard.set(soundOn, forKey: Self.soundKey) }
    }
    @Published var allowLocalHTTP: Bool {
        didSet { UserDefaults.standard.set(allowLocalHTTP, forKey: Self.localHTTPKey) }
    }
    @Published var openAtLogin: Bool {
        didSet { setOpenAtLogin(openAtLogin) }
    }

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private let store = DefaultsPermissionStore()
    private var server: Server?
    private var iconReset: Task<Void, Never>?

    init() {
        UserDefaults.standard.register(defaults: [Self.soundKey: true])
        soundOn = UserDefaults.standard.bool(forKey: Self.soundKey)
        allowLocalHTTP = UserDefaults.standard.bool(forKey: Self.localHTTPKey)
        openAtLogin = SMAppService.mainApp.status == .enabled

        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Copycat", isDirectory: true)
        CacheJanitor.prune(cache)

        let fetcher = Fetcher(cacheDirectory: cache, policy: {
            URLPolicy(allowLocalHTTP: UserDefaults.standard.bool(forKey: AppModel.localHTTPKey))
        })
        let gatekeeper = Gatekeeper(store: store, prompter: WindowPrompter(controller: PromptController()))
        let pipeline = CopyPipeline(gatekeeper: gatekeeper, fetcher: fetcher, writer: PasteboardWriter(),
                                    feedback: AppFeedback(model: self), cacheDirectory: cache)
        let server = Server(router: Router(service: pipeline, version: version))
        do {
            try server.start()
            self.server = server
        } catch {
            serverError = "Port \(Server.defaultPort) is in use"
        }

        reloadSites()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSites() }
        }
    }

    func reloadSites() {
        let current = store.all().map { Site(origin: $0.key, permission: $0.value) }.sorted { $0.origin < $1.origin }
        if current.map(\.origin) != sites.map(\.origin) || current.map(\.permission) != sites.map(\.permission) {
            sites = current
        }
    }

    func remove(_ site: Site) {
        store.set(site.origin, .prompt)
        reloadSites()
    }

    func show(_ state: IconState) {
        icon = state
        iconReset?.cancel()
        let seconds: Double
        switch state {
        case .succeeded: seconds = 1
        case .failed: seconds = 2
        case .idle, .working: return
        }
        iconReset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { self?.icon = .idle }
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Copycat: open at login: \(error)")
        }
    }
}
