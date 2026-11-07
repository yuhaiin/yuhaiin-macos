import AppKit
import SwiftUI

@main
struct YuhaiinMacOSApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updater = AppUpdater()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model, updater: updater)
        } label: {
            StatusLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Yuhaiin", id: "main") {
            DashboardView(model: model, updater: updater)
        }
        .defaultSize(width: 640, height: 460)

        Window(L("menu.settings"), id: "settings") {
            SettingsView(model: model, updater: updater)
        }
        // The sidebar runs up behind the traffic lights; the detail header
        // already shows the section title.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 650)
    }
}
