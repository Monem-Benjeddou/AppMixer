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
        Shortcut.shared.register()
        VolumeKeys.shared.update()
        // Accessibility may have just been granted in System Settings.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { VolumeKeys.shared.update() }
        }
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
        if CommandLine.arguments.contains("--dsp-self-test") { exit(EffectChain.selfTest() ? 0 : 1) }
        Stability.start() // before anything else, so crashes and hangs from here on are caught
        _model = ObservedObject(wrappedValue: MixerModel.shared)
    }

    var body: some Scene {
        Window("AppMixer", id: "mixer") {
            RootView(model: model)
        }
        .defaultSize(width: 940, height: 600)
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            MenuBarMixer(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

enum MenuBarIcon: String { case mixer, volume }

/// The menu bar icon: the mixer symbol, or the output volume at a glance.
private struct MenuBarLabel: View {
    @ObservedObject var model: MixerModel
    @AppStorage(Prefs.menuBarIcon) private var style = MenuBarIcon.mixer.rawValue

    var body: some View {
        if style == MenuBarIcon.volume.rawValue, let device = model.defaultDevice {
            Image(systemName: VolumeSymbol.name(volume: model.outputVolume(device), muted: model.isOutputMuted(device)))
        } else {
            Image(systemName: "slider.vertical.3")
        }
    }
}
