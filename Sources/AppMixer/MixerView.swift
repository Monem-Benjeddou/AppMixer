import ServiceManagement
import SwiftUI

enum Prefs {
    static let showIdleApps = "showIdleApps"
    static let maxBoost = "maxBoost"
    static let showInDock = "showInDock"
}

// MARK: - Main window

enum Page: String, Hashable { case mixer, devices }

struct RootView: View {
    @ObservedObject var model: MixerModel
    @AppStorage("selectedPage") private var storedPage = Page.mixer.rawValue

    private var page: Binding<Page?> {
        Binding(get: { Page(rawValue: storedPage) ?? .mixer }, set: { storedPage = ($0 ?? .mixer).rawValue })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: page) {
                Section("Audio") {
                    Label("Mixer", systemImage: "slider.vertical.3")
                        .badge(model.apps.filter(\.isPlaying).count)
                        .tag(Page.mixer)
                    Label("Devices", systemImage: "hifispeaker.2")
                        .badge(model.outputDevices.count)
                        .tag(Page.devices)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) { OutputSummary(model: model).padding(10) }
        } detail: {
            switch page.wrappedValue ?? .mixer {
            case .mixer: MixerPage(model: model)
            case .devices: DevicesPage(model: model)
            }
        }
        .frame(minWidth: 820, minHeight: 480)
    }
}

/// The current system output, pinned to the bottom of the sidebar.
private struct OutputSummary: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.defaultDevice?.symbol ?? "speaker.slash")
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text("Output").font(.caption2).foregroundStyle(.secondary)
                Text(model.defaultDeviceName).font(.caption).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}

// MARK: Mixer page

struct MixerPage: View {
    @ObservedObject var model: MixerModel
    @AppStorage(Prefs.showIdleApps) private var showIdleApps = true
    @State private var query = ""
    @State private var confirmReset = false

    private var filtered: [AudioApp] {
        guard !query.isEmpty else { return model.apps }
        return model.apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var playing: [AudioApp] { filtered.filter(\.isPlaying) }
    private var idle: [AudioApp] { filtered.filter { !$0.isPlaying } }

    var body: some View {
        Group {
            if model.apps.isEmpty {
                ContentUnavailableView("No Apps Using Audio", systemImage: "speaker.wave.2",
                                       description: Text("Apps show up here as soon as they open an audio connection."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    if model.volumesPaused {
                        Callout(symbol: "lifepreserver", tint: .orange,
                                title: "Your saved volumes are paused",
                                message: "AppMixer quit unexpectedly twice right after starting, so it started without changing any app's audio. Everything plays at normal volume until you turn them back on.",
                                action: ("Turn Volumes Back On", { model.resumeVolumes() }))
                            .listRowSeparator(.hidden)
                    } else if let notice = model.crashNotice {
                        Callout(symbol: "arrow.clockwise.circle.fill", tint: .blue,
                                title: notice,
                                message: "Your volumes and outputs were restored. If it keeps happening, please open an issue on GitHub.",
                                action: ("Dismiss", { model.crashNotice = nil }))
                            .listRowSeparator(.hidden)
                    }
                    if model.audioServerUnresponsive {
                        Callout(symbol: "hourglass", tint: .yellow,
                                title: "The macOS audio system isn't responding",
                                message: "AppMixer is waiting for it and will catch up automatically. If this persists, a device or audio driver may be stuck — try unplugging recently connected audio devices.",
                                action: nil)
                            .listRowSeparator(.hidden)
                    }
                    if model.permission == .denied {
                        PermissionBanner().listRowSeparator(.hidden)
                    } else if !model.errors.isEmpty {
                        ErrorBanner(errors: model.errors, apps: model.apps) { model.retryFailed() }
                            .listRowSeparator(.hidden)
                    }
                    Section {
                        if playing.isEmpty {
                            Text("Nothing is playing right now.").foregroundStyle(.secondary).padding(.vertical, 6)
                        }
                        ForEach(playing) { AppRow(app: $0, model: model) }
                    } header: {
                        SectionHeader(title: "Playing", count: playing.count)
                    }
                    if showIdleApps && !idle.isEmpty {
                        Section {
                            ForEach(idle) { AppRow(app: $0, model: model) }
                        } header: {
                            SectionHeader(title: "Idle", count: idle.count)
                        }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }
        }
        .navigationTitle("Mixer")
        .navigationSubtitle("\(playing.count) playing · \(model.settings.count) customized")
        .searchable(text: $query, placement: .toolbar, prompt: "Filter apps")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $showIdleApps) {
                    Label("Show Idle Apps", systemImage: "moon.zzz")
                }
                .help("Show apps that have audio open but aren't playing")

                Button {
                    confirmReset = true
                } label: {
                    Label("Reset All", systemImage: "arrow.counterclockwise")
                }
                .help("Set every app back to 100% on the system output")
                .disabled(model.settings.isEmpty)
            }
        }
        .confirmationDialog("Reset all apps?", isPresented: $confirmReset) {
            Button("Reset All", role: .destructive) { model.resetAll() }
        } message: {
            Text("Every app goes back to 100% volume, unmuted, on the system output.")
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack {
            Text(title)
            Text("\(count)").foregroundStyle(.tertiary)
        }
    }
}

private struct PermissionBanner: View {
    var body: some View {
        Callout(symbol: "lock.fill", tint: .orange,
                title: "AppMixer needs permission to control app audio",
                message: "Turn on AppMixer under System Settings › Privacy & Security › Screen & System Audio Recording (System Audio Recording Only). Your settings are saved and apply as soon as access is granted.",
                action: ("Open Privacy Settings", openPrivacySettings))
    }
}

private struct ErrorBanner: View {
    let errors: [String: String]
    let apps: [AudioApp]
    let retry: () -> Void

    var body: some View {
        Callout(symbol: "exclamationmark.triangle.fill", tint: .red,
                title: "Couldn't take control of \(names)",
                message: (errors.values.first ?? "") + " The app keeps playing normally until this is resolved.",
                action: ("Try Again", retry))
    }

    private var names: String {
        let list = errors.keys.compactMap { id in apps.first { $0.id == id }?.name }.sorted()
        return list.isEmpty ? "some apps" : ListFormatter.localizedString(byJoining: list)
    }
}

private struct Callout: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    let action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.0, action: action.1).padding(.top, 4)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12)))
        .padding(.vertical, 6)
    }
}

func openPrivacySettings() {
    let urls = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
                "x-apple.systempreferences:com.apple.preference.security?Privacy"]
    for string in urls {
        if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
    }
}

/// One app in the main window: icon and name, mute, volume, output.
private struct AppRow: View {
    let app: AudioApp
    @ObservedObject var model: MixerModel
    @AppStorage(Prefs.maxBoost) private var maxBoost = 2.0

    private var setting: AppSetting { model.setting(for: app.id) }
    private var isCustomized: Bool { model.settings[app.id] != nil }

    var body: some View {
        HStack(spacing: 14) {
            AppIcon(app: app, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                if let error = model.errors[app.id] {
                    Label("Not controlled", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .help(error)
                } else {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 180, alignment: .leading)

            MuteButton(muted: setting.muted, volume: setting.volume) { model.toggleMute(app.id) }

            VolumeSlider(value: setting.volume, maxValue: Float(maxBoost)) { model.setVolume($0, for: app.id) }
                .disabled(setting.muted)
                .frame(minWidth: 140)

            VolumeLabel(setting: setting).frame(width: 52, alignment: .trailing)

            DeviceMenu(app: app, model: model).frame(width: 190)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button(setting.muted ? "Unmute" : "Mute") { model.toggleMute(app.id) }
            Button("Reset to 100%") { model.reset(app.id) }.disabled(!isCustomized)
        }
    }

    private var subtitle: String {
        var parts = [app.isPlaying ? "Playing" : "Idle"]
        if let uid = setting.deviceUID {
            parts.append("→ " + (model.outputDevices.first { $0.uid == uid }?.name ?? "Disconnected device"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: Devices page

struct DevicesPage: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        List {
            Section {
                ForEach(model.outputDevices) { DeviceRow(device: $0, model: model) }
            } header: {
                SectionHeader(title: "Output Devices", count: model.outputDevices.count)
            } footer: {
                Text("Apps set to System Default follow the device marked Default. Per-app routing is set on the Mixer page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.outputDevices.isEmpty {
                ContentUnavailableView("No Output Devices", systemImage: "speaker.slash")
            }
        }
        .navigationTitle("Devices")
        .navigationSubtitle(model.defaultDeviceName)
    }
}

private struct DeviceRow: View {
    let device: OutputDevice
    @ObservedObject var model: MixerModel

    private var isDefault: Bool { device.objectID == model.defaultDeviceID }
    private var routedApps: [AudioApp] {
        model.apps.filter { model.setting(for: $0.id).deviceUID == device.uid }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: device.symbol)
                .font(.title3)
                .foregroundStyle(isDefault ? Color.white : Color.accentColor)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(isDefault ? Color.accentColor : Color.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.body.weight(.medium)).lineLimit(1)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let volume = model.deviceVolumes[device.uid] {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary).font(.caption)
                Slider(value: Binding(get: { Double(volume) },
                                      set: { model.setDeviceVolume(Float($0), for: device) }), in: 0...1)
                    .frame(width: 160)
                Text("\(safeInt((volume * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            } else {
                Text("Fixed volume").font(.caption).foregroundStyle(.tertiary).frame(width: 222, alignment: .trailing)
            }

            Group {
                if isDefault {
                    Text("Default")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(.tint)
                } else {
                    Button("Make Default") { model.makeDefault(device) }.controlSize(.small)
                }
            }
            .frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    private var details: String {
        let count = routedApps.count
        return count == 0 ? device.kind : "\(device.kind) · \(count) app\(count == 1 ? "" : "s") routed here"
    }
}

// MARK: - Menu bar panel

struct MenuBarMixer: View {
    @ObservedObject var model: MixerModel
    @Environment(\.openWindow) private var openWindow

    private var apps: [AudioApp] { model.apps.filter { $0.isPlaying || model.settings[$0.id] != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.defaultDevice?.symbol ?? "speaker.slash").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("AppMixer").font(.headline)
                    Text(model.defaultDeviceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(12)

            Divider()

            if apps.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2").font(.title2).foregroundStyle(.tertiary)
                    Text("Nothing is playing").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                // A ScrollView in a menu-bar window collapses to zero height unless given one explicitly.
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(apps) { CompactAppRow(app: $0, model: model) }
                    }
                    .padding(12)
                }
                .frame(height: min(CGFloat(apps.count) * 66 + 24, 400))
            }

            Divider()

            HStack(spacing: 12) {
                Button("Open AppMixer") {
                    openWindow(id: "mixer")
                    NSApp.activate()
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit AppMixer")
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .frame(width: 340)
    }
}

private struct CompactAppRow: View {
    let app: AudioApp
    @ObservedObject var model: MixerModel
    @AppStorage(Prefs.maxBoost) private var maxBoost = 2.0

    private var setting: AppSetting { model.setting(for: app.id) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                AppIcon(app: app, size: 20)
                Text(app.name).lineLimit(1)
                Spacer()
                VolumeLabel(setting: setting)
                DeviceMenu(app: app, model: model, iconOnly: true)
            }
            HStack(spacing: 8) {
                MuteButton(muted: setting.muted, volume: setting.volume) { model.toggleMute(app.id) }
                VolumeSlider(value: setting.volume, maxValue: Float(maxBoost)) { model.setVolume($0, for: app.id) }
                    .disabled(setting.muted)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Shared controls

private struct AppIcon: View {
    let app: AudioApp
    let size: CGFloat

    var body: some View {
        Group {
            if let image = app.icon {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if app.isPlaying && size >= 28 {
                Circle().fill(.green)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            }
        }
    }
}

private struct MuteButton: View {
    let muted: Bool
    let volume: Float
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: muted ? "speaker.slash.fill" : symbol)
                .foregroundStyle(muted ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(muted ? "Unmute" : "Mute")
    }

    private var symbol: String {
        switch volume {
        case 0: return "speaker.fill"
        case ..<0.4: return "speaker.wave.1.fill"
        case ..<1.01: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

/// A volume slider that snaps to 100%, where the app is left completely untouched.
private struct VolumeSlider: View {
    let value: Float
    let maxValue: Float
    let onChange: (Float) -> Void

    private var upperBound: Double { Double(max(maxValue, 1)) }

    private var binding: Binding<Double> {
        Binding(
            get: { Double(min(value, maxValue)) },
            set: { newValue in
                let snapped: Double = abs(newValue - 1) < 0.03 * upperBound ? 1 : newValue
                onChange(Float(snapped))
            })
    }

    var body: some View {
        Slider(value: binding, in: 0...upperBound)
    }
}

private struct VolumeLabel: View {
    let setting: AppSetting

    var body: some View {
        Text(setting.muted ? "Muted" : "\(safeInt((setting.volume * 100).rounded()))%")
            .font(.callout.monospacedDigit())
            .foregroundStyle(setting.muted ? AnyShapeStyle(.red)
                             : setting.volume > 1 ? AnyShapeStyle(.orange)
                             : setting.volume < 1 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
}

private struct DeviceMenu: View {
    let app: AudioApp
    @ObservedObject var model: MixerModel
    var iconOnly = false

    private var selectedUID: String? { model.setting(for: app.id).deviceUID }
    private var selected: OutputDevice? { selectedUID.flatMap { uid in model.outputDevices.first { $0.uid == uid } } }

    var body: some View {
        Menu {
            Button { model.setDevice(nil, for: app.id) } label: {
                checkmarked("System Default (\(model.defaultDeviceName))", selectedUID == nil)
            }
            Divider()
            ForEach(model.outputDevices) { device in
                Button { model.setDevice(device.uid, for: app.id) } label: {
                    checkmarked(device.name, selectedUID == device.uid)
                }
            }
        } label: {
            if iconOnly {
                Image(systemName: selected?.symbol ?? "hifispeaker")
            } else {
                Label(selected?.name ?? "System Default", systemImage: selected?.symbol ?? "hifispeaker")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: iconOnly, vertical: false)
        .help("Output for \(app.name)")
    }

    @ViewBuilder private func checkmarked(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Prefs.showIdleApps) private var showIdleApps = true
    @AppStorage(Prefs.maxBoost) private var maxBoost = 2.0
    @AppStorage(Prefs.showInDock) private var showInDock = true
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
