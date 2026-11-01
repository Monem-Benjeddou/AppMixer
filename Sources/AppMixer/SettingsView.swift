import ServiceManagement
import SwiftUI

enum Prefs {
    static let showIdleApps = "showIdleApps"
    static let maxBoost = "maxBoost"
    static let showInDock = "showInDock"
    static let hotKey = "hotKey"
    static let superVolumeKeys = "superVolumeKeys"
    static let menuBarIcon = "menuBarIcon"
    static let floating = "floating"
}

func openPrivacySettings() {
    let urls = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
                "x-apple.systempreferences:com.apple.preference.security?Privacy"]
    for string in urls {
        if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Prefs.showIdleApps) private var showIdleApps = true
    @AppStorage(Prefs.maxBoost) private var maxBoost = 2.0
    @AppStorage(Prefs.showInDock) private var showInDock = true
    @AppStorage(Prefs.menuBarIcon) private var menuBarIcon = MenuBarIcon.mixer.rawValue
    @AppStorage(Prefs.hotKey) private var hotKey = HotKeyPreset.controlOptionM.rawValue
    @AppStorage(Prefs.superVolumeKeys) private var superVolumeKeys = false
    @ObservedObject private var shortcut = Shortcut.shared
    @ObservedObject private var volumeKeys = VolumeKeys.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show in Dock while a window is open", isOn: $showInDock)
                    .onChange(of: showInDock) { _, _ in DockIcon.shared.update() }
                Toggle("Show idle apps in the mixer", isOn: $showIdleApps)
            }

            Section("Menu Bar") {
                Picker("Menu bar icon", selection: $menuBarIcon) {
                    Label("Mixer", systemImage: "slider.vertical.3").tag(MenuBarIcon.mixer.rawValue)
                    Label("Output volume", systemImage: "speaker.wave.2.fill").tag(MenuBarIcon.volume.rawValue)
                }
                Picker("Open with shortcut", selection: $hotKey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.display).tag($0.rawValue) }
                }
                .onChange(of: hotKey) { _, _ in shortcut.register() }
                if let conflict = shortcut.conflict {
                    Text("\(conflict.display) is used by another app. Pick another shortcut.")
                        .font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Use volume keys for outputs without volume control", isOn: $superVolumeKeys)
                    .onChange(of: superVolumeKeys) { _, _ in volumeKeys.update(prompt: true) }
                if superVolumeKeys && !volumeKeys.isRunning {
                    LabeledContent("Needs Accessibility permission") {
                        Button("Open Accessibility Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .foregroundStyle(.orange)
                }
            } header: {
                Text("Volume Keys")
            } footer: {
                Text("HDMI, DisplayPort and some other outputs ignore the keyboard's volume keys. With this on, the keys change AppMixer's software volume for those outputs. Other outputs work as usual.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Maximum volume", selection: $maxBoost) {
                    Text("100% (no boost)").tag(1.0)
                    Text("150%").tag(1.5)
                    Text("200%").tag(2.0)
                }
            } header: {
                Text("Volume")
            } footer: {
                Text("Boosting above 100% can clip loud sources.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Audio capture") {
                    Button("Open Privacy Settings") { openPrivacySettings() }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("macOS asks for permission the first time you change an app. If an app goes silent, check that AppMixer is allowed under Screen & System Audio Recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
