import SwiftUI

@main
struct CopycatApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
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
        case .idle: Image(systemName: "doc.on.clipboard")
        case .working: Image(systemName: "arrow.down.doc").symbolEffect(.pulse)
        case .succeeded: Image(systemName: "checkmark.circle")
        case .failed: Image(systemName: "exclamationmark.triangle")
        }
    }
}
