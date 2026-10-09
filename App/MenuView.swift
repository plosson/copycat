import AppKit
import CopycatCore
import HoulahopUpdater
import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel
    let updater: Updater

    var body: some View {
        Text(model.serverError ?? "Copycat is running")

        Divider()

        siteSection("Allowed sites", .granted)
        siteSection("Denied sites", .denied)

        Divider()

        Toggle("Play sound", isOn: $model.soundOn)
        Toggle("Open at login", isOn: $model.openAtLogin)
        // Hidden development setting: shown while Option is held when the menu opens, or while it is on.
        if model.allowLocalHTTP || NSEvent.modifierFlags.contains(.option) {
            Toggle("Allow http://localhost (development)", isOn: $model.allowLocalHTTP)
        }

        Divider()

        Text("Version \(model.version)")
        CheckForUpdatesButton(updater: updater)
        Button("Quit Copycat") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private func siteSection(_ title: String, _ permission: Permission) -> some View {
        let sites = model.sites.filter { $0.permission == permission }
        Menu("\(title) (\(sites.count))") {
            if sites.isEmpty {
                Text("None")
            }
            ForEach(sites) { site in
                Button("Remove \(site.origin)") { model.remove(site) }
            }
        }
    }
}
