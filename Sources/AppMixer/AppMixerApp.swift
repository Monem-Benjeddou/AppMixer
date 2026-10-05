import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Always open the main window at launch instead of restoring a "closed" state from the last quit.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let showInDock = UserDefaults.standard.object(forKey: Prefs.showInDock) as? Bool ?? true
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    // Keep running in the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct AppMixerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    // Created eagerly so saved per-app settings apply at launch, not when a window first opens.
    @ObservedObject private var model = MixerModel.shared

    var body: some Scene {
        Window("AppMixer", id: "mixer") {
            RootView(model: model)
        }
        .defaultSize(width: 940, height: 600)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            MenuBarMixer(model: model)
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)
    }
}
