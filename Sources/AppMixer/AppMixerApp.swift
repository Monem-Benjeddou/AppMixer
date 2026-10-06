import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Always open the main window at launch instead of restoring a "closed" state from the last quit.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Stability.didFinishLaunching()
        DockIcon.shared.isEnabled = { UserDefaults.standard.object(forKey: Prefs.showInDock) as? Bool ?? true }
        DockIcon.shared.start()
    }

    // Keep running in the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct AppMixerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    // Created eagerly so saved per-app settings apply at launch, not when a window first opens.
    @ObservedObject private var model: MixerModel

    init() {
        Stability.start() // before anything else, so crashes and hangs from here on are caught
        _model = ObservedObject(wrappedValue: MixerModel.shared)
    }

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
