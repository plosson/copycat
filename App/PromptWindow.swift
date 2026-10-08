import AppKit
import CopycatCore
import SwiftUI

/// The "Allow example.com to copy files to your clipboard?" window.
@MainActor
final class PromptController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<PromptAnswer, Never>?

    func ask(origin: String) async -> PromptAnswer {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            show(origin)
        }
    }

    func finish(_ answer: PromptAnswer) {
        guard let continuation else { return }
        self.continuation = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        continuation.resume(returning: answer)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { finish(.dismissed) }
    }

    private func show(_ origin: String) {
        let view = PromptView(host: Origin.host(of: origin), origin: origin,
                              deny: { [weak self] in self?.finish(.deny) },
                              allow: { [weak self] in self?.finish(.allow) })
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 140),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Copycat"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: view)
        panel.delegate = self
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }
}

struct PromptView: View {
    let host: String
    let origin: String
    let deny: () -> Void
    let allow: () -> Void
    /// The buttons ignore clicks for a moment, so a page cannot open the prompt just under a click it provoked.
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow \(host) to copy files to your clipboard?").font(.headline)
            Text(origin).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Spacer()
                // Neither button is the default, so a stray Return key does not allow a site.
                Button("Deny", action: deny)
                Button("Allow", action: allow)
            }
            .disabled(!armed)
        }
        .padding(20)
        .frame(width: 400)
        .task {
            try? await Task.sleep(nanoseconds: 750_000_000)
            armed = true
        }
    }
}

struct WindowPrompter: Prompter {
    let controller: PromptController

    func ask(origin: String) async -> PromptAnswer {
        await withTaskCancellationHandler {
            await controller.ask(origin: origin)
        } onCancel: {
            Task { @MainActor in controller.finish(.dismissed) }
        }
    }
}
