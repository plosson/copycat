import HoulahopUpdater
import SwiftUI

@main
struct CopycatApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model, updater: updater)
        } label: {
            MenuBarIcon(state: model.icon)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarIcon: View {
    let state: IconState

    var body: some View {
        switch state {
        // Template image (22 pt canvas): macOS tints it for light/dark menu bars.
        case .idle: Image("CopycatMenu").renderingMode(.template).accessibilityLabel("Copycat")
        case .working: Image(systemName: "arrow.down.doc").symbolEffect(.pulse)
        case .succeeded: Image(systemName: "checkmark.circle")
        case .failed: Image(systemName: "exclamationmark.triangle")
        }
    }
}
