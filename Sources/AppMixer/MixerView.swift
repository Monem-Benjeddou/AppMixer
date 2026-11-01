import SwiftUI

// MARK: - Main window

enum Page: String, CaseIterable, Hashable { case mixer, effects, devices }

struct RootView: View {
    @ObservedObject var model: MixerModel
    @AppStorage("selectedPage") private var storedPage = Page.mixer.rawValue
    @AppStorage(Prefs.floating) private var floating = false
    @AppStorage(Prefs.showIdleApps) private var showIdleApps = true
    @State private var query = ""
    @State private var confirmReset = false
    /// Toolbar items size to their content; the bar is given the window's width so actions sit at the far end.
    @State private var barWidth: CGFloat = 860

    private var page: Page { Page(rawValue: storedPage) ?? .mixer }

    var body: some View {
        VStack(spacing: 0) {
            Notices(model: model)
            switch page {
            case .mixer: MixerPage(model: model, query: query, showIdleApps: showIdleApps) { storedPage = Page.effects.rawValue }
            case .effects: EffectsPage(model: model)
            case .devices: DevicesPage(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .background(GeometryReader { geo in Color.clear.onAppear { barWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, width in barWidth = width } })
        .frame(minWidth: 860, minHeight: 540)
        .background(WindowFloating(floating: floating))
        .navigationTitle("")
        .toolbarBackground(Theme.canvas, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 6) {
                    tabs
                    Spacer(minLength: 12)
                    actions
                }
                .frame(width: max(barWidth - 140, 560)) // leaves room for the traffic lights and toolbar margins
            }
        }
        .confirmationDialog("Reset all apps?", isPresented: $confirmReset) {
            Button("Reset All", role: .destructive) { model.resetAll() }
        } message: {
            Text("Every app goes back to 100% volume, unmuted, no effects, on the system output.")
        }
    }

    @ViewBuilder private var actions: some View {
                if page == .mixer {
                    FilterField(text: $query)
                    IconKey(symbol: "moon.zzz", help: showIdleApps ? "Hide idle apps" : "Show idle apps", isOn: showIdleApps) {
                        showIdleApps.toggle()
                    }
                    IconKey(symbol: "arrow.counterclockwise", help: "Reset every app") { confirmReset = true }
                        .disabled(model.settings.isEmpty)
                }
                IconKey(symbol: floating ? "pin.fill" : "pin", help: floating ? "Stop keeping on top" : "Keep on top",
                        isOn: floating) { floating.toggle() }
    }

    private var tabs: some View {
        HStack(spacing: 20) {
            ForEach(Page.allCases, id: \.self) { tab in
                Button { storedPage = tab.rawValue } label: {
                    HStack(spacing: 6) {
                        Text(tab.rawValue.uppercased()).font(.mono(11, .semibold)).tracking(1.6)
                        if tab == .effects { LED(on: model.systemEffects.isActive, size: 5) }
                        if tab == .mixer, case let count = model.apps.filter(\.isPlaying).count, count > 0 {
                            Text(String(format: "%02d", count)).font(.mono(9, .medium)).foregroundStyle(Theme.live)
                        }
                    }
                    .foregroundStyle(page == tab ? Theme.text : Theme.text3)
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(page == tab ? Theme.signal : .clear).frame(height: 2).offset(y: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == tab ? .isSelected : [])
            }
        }
        .padding(.leading, 8)
        .fixedSize()
    }
}

private struct FilterField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.text3)
            TextField("FILTER", text: $text)
                .textFieldStyle(.plain)
                .font(.mono(11))
                .frame(width: 130)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.well))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }
}

/// Safe mode, crash, permission and error messages, shown above whichever page is open.
private struct Notices: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        let notices = items
        if !notices.isEmpty {
            VStack(spacing: 8) { ForEach(notices.indices, id: \.self) { notices[$0] } }
                .padding(.horizontal, 16)
                .padding(.top, 12)
        }
    }

    private var items: [Notice] {
        var list: [Notice] = []
        if model.volumesPaused {
            list.append(Notice(tint: Theme.caution, symbol: "lifepreserver", title: "Your saved volumes are paused",
                               message: "AppMixer quit unexpectedly twice right after starting, so it started without changing any app's audio. Everything plays normally until you turn them back on.",
                               actions: [("Turn volumes back on", { model.resumeVolumes() })]))
        } else if let notice = model.crashNotice {
            list.append(Notice(tint: Theme.text2, symbol: "arrow.clockwise", title: notice,
                               message: "Your volumes and outputs were restored. If it keeps happening, please open an issue on GitHub.",
                               actions: [("Dismiss", { model.crashNotice = nil })]))
        }
        if model.audioServerUnresponsive {
            list.append(Notice(tint: Theme.caution, symbol: "hourglass", title: "The macOS audio system isn't responding",
                               message: "AppMixer is waiting for it and will catch up automatically. If this persists, try unplugging recently connected audio devices."))
        }
        if model.isRequestingPermission {
            list.append(Notice(tint: Theme.signal, symbol: "hand.raised", title: "Click Allow in the macOS prompt",
                               message: "Changes take effect once you allow AppMixer to control app audio. The prompt may be in a corner of your screen."))
        } else if model.permission == .denied {
            list.append(Notice(tint: Theme.caution, symbol: "lock", title: "AppMixer needs permission to control app audio",
                               message: "Turn on AppMixer in System Settings › Privacy & Security › Screen & System Audio Recording (System Audio Recording Only). Already on? It's from an older version, which macOS no longer accepts: reset it, then click Allow.",
                               actions: [("Open privacy settings", openPrivacySettings),
                                         ("Reset permission", { model.resetPermission() })]))
        } else if !model.errors.isEmpty {
            let names = model.errors.keys.compactMap { id in
                id == AudioEngine.systemID ? "system effects" : model.apps.first { $0.id == id }?.name
            }.sorted()
            list.append(Notice(tint: Theme.alert, symbol: "exclamationmark.triangle",
                               title: "Couldn't take control of \(names.isEmpty ? "some apps" : ListFormatter.localizedString(byJoining: names))",
                               message: (model.errors.values.first ?? "") + " Audio keeps playing normally until this is resolved.",
                               actions: [("Try again", { model.retryFailed() })]))
        }
        return list
    }
}

// MARK: Mixer page: a console, one channel strip per app

struct MixerPage: View {
    @ObservedObject var model: MixerModel
    let query: String
    let showIdleApps: Bool
    let openEffects: () -> Void

    private var filtered: [AudioApp] {
        query.isEmpty ? model.apps : model.apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let playing = filtered.filter(\.isPlaying)
        let idle = showIdleApps ? filtered.filter { !$0.isPlaying } : []
        HStack(spacing: 0) {
            Group {
                if model.apps.isEmpty {
                    EmptyPanel(title: "NO AUDIO SOURCES", message: "Apps appear here as soon as they open an audio connection.")
                } else if playing.isEmpty && idle.isEmpty {
                    EmptyPanel(title: query.isEmpty ? "NOTHING PLAYING" : "NO MATCH",
                               message: query.isEmpty ? "Idle apps are hidden. Show them with the moon key." : "No app called “\(query)”.")
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(playing) { ChannelStrip(app: $0, model: model) }
                            if !idle.isEmpty {
                                VStack(spacing: 8) {
                                    Text("IDLE").panelLabel().fixedSize().rotationEffect(.degrees(-90)).frame(width: 14, height: 40)
                                    Rectangle().fill(Theme.line).frame(width: 1)
                                }
                                .padding(.horizontal, 4)
                                ForEach(idle) { ChannelStrip(app: $0, model: model) }
                            }
                        }
                        .padding(16)
                    }
                    .scrollIndicators(.automatic)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(Theme.line).frame(width: 1)
            MasterStrip(model: model, openEffects: openEffects)
                .padding(16)
        }
    }
}

private struct EmptyPanel: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) { ForEach(0..<5) { _ in LED(on: false, size: 5) } }
            Text(title).font(.mono(12, .semibold)).tracking(2).foregroundStyle(Theme.text2)
            Text(message).font(.system(size: 12)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

private struct ChannelStrip: View {
    let app: AudioApp
    @ObservedObject var model: MixerModel
    @AppStorage(Prefs.maxBoost) private var maxBoost = 2.0

    private var setting: AppSetting { model.setting(for: app.id) }
    private var isCustomized: Bool { model.settings[app.id] != nil }

    var body: some View {
        let setting = self.setting
        let percent = safeInt((setting.volume * 100).rounded())
        VStack(spacing: 10) {
            AppIcon(app: app, size: 30)
                .padding(.top, 4)
            VStack(spacing: 3) {
                Text(app.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = model.errors[app.id] {
                    Text("NO CONTROL").panelLabel(Theme.alert).help(error)
                } else {
                    Text(app.isPlaying ? "LIVE" : "IDLE").panelLabel(app.isPlaying ? Theme.live : Theme.text3)
                }
            }

            RouteMenu(app: app, model: model)
            EffectsButton(app: app, model: model)

            Fader(axis: .vertical, value: Double(setting.volume), range: 0...max(maxBoost, 1), detent: 1,
                  tint: setting.muted ? Theme.text3 : setting.volume > 1 ? Theme.signal : Theme.text,
                  marks: maxBoost > 1 ? [(0, "0"), (1, "100"), (maxBoost, "\(safeInt(maxBoost * 100))")] : [(0, "0"), (1, "100")],
                  label: "\(app.name) volume", valueText: setting.muted ? "Muted" : "\(percent) percent") {
                model.setVolume(Float($0), for: app.id)
            }
            .disabled(setting.muted)
            .frame(maxHeight: .infinity)

            Readout(value: setting.muted ? "MUTE" : "\(percent)", unit: setting.muted ? "" : "%",
                    color: setting.muted ? Theme.alert : setting.volume > 1 ? Theme.signal : Theme.text, size: 14)

            Button { model.toggleMute(app.id) } label: { Text("M").frame(maxWidth: .infinity) }
                .buttonStyle(KeyStyle(isOn: setting.muted, tint: Theme.alert))
                .help(setting.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
                .accessibilityLabel(setting.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: 108)
        .frame(maxHeight: .infinity)
        .module()
        // A customized channel carries a signal line along its top edge.
        .overlay(alignment: .top) {
            if isCustomized { Rectangle().fill(Theme.signal).frame(height: 2).padding(.horizontal, 10) }
        }
        .opacity(app.isPlaying ? 1 : 0.62)
        .contextMenu {
            Button(setting.muted ? "Unmute" : "Mute") { model.toggleMute(app.id) }
            Button("Reset to 100%") { model.reset(app.id) }.disabled(!isCustomized)
        }
    }
}

/// The output for one app: SYSTEM (follow the default) or a device.
private struct RouteMenu: View {
    let app: AudioApp
    @ObservedObject var model: MixerModel
    var compact = false

    var body: some View {
        let uid = model.setting(for: app.id).deviceUID
        let device = uid.flatMap { uid in model.outputDevices.first { $0.uid == uid } }
        let title = uid == nil ? "SYSTEM" : (device?.name ?? "OFFLINE")
        PanelMenu(title: compact ? "→" : title, font: .mono(9.5, .medium), color: uid == nil ? Theme.text2 : Theme.signal) {
            Button { model.setDevice(nil, for: app.id) } label: {
                menuItem("System Default (\(model.defaultDeviceName))", uid == nil)
            }
            Divider()
            ForEach(model.outputDevices) { device in
                Button { model.setDevice(device.uid, for: app.id) } label: { menuItem(device.name, uid == device.uid) }
            }
        }
        .frame(maxWidth: compact ? nil : .infinity)
        .padding(.vertical, 4)
        .padding(.horizontal, compact ? 0 : 4)
        .background(compact ? nil : RoundedRectangle(cornerRadius: 4).fill(Theme.well))
        .help("Output for \(app.name)\(uid != nil && device == nil ? ": that device is disconnected, so it plays on the system output" : "")")
    }
}

/// The system output: device, volume and the system-wide effects.
private struct MasterStrip: View {
    @ObservedObject var model: MixerModel
    let openEffects: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("MASTER").panelLabel(Theme.text2).padding(.top, 4)
            if let device = model.defaultDevice {
                let volume = model.outputVolume(device)
                let muted = model.isOutputMuted(device)
                Image(systemName: device.symbol).font(.system(size: 18)).foregroundStyle(Theme.text2).frame(height: 30)
                PanelMenu(title: device.name, font: .system(size: 11, weight: .medium), lines: 2) {
                    ForEach(model.outputDevices) { other in
                        Button { model.makeDefault(other) } label: { menuItem(other.name, other.uid == device.uid) }
                    }
                }
                .frame(maxWidth: .infinity)
                Text(model.hasFixedVolume(device) ? "SOFTWARE VOL" : device.kind.uppercased()).panelLabel()

                Fader(axis: .vertical, value: Double(volume), tint: muted ? Theme.text3 : Theme.signal,
                      marks: [(0, "0"), (0.5, "50"), (1, "100")], label: "Output volume",
                      valueText: muted ? "Muted" : "\(safeInt((volume * 100).rounded())) percent") { value in
                    model.hasFixedVolume(device) ? model.setSoftVolume(Float(value), for: device)
                                                 : model.setDeviceVolume(Float(value), for: device)
                }
                .frame(maxHeight: .infinity)

                Readout(value: muted ? "MUTE" : "\(safeInt((volume * 100).rounded()))", unit: muted ? "" : "%",
                        color: muted ? Theme.alert : Theme.text, size: 14)
                Button { model.toggleOutputMute(device) } label: { Text("M").frame(maxWidth: .infinity) }
                    .buttonStyle(KeyStyle(isOn: muted, tint: Theme.alert))
                    .accessibilityLabel(muted ? "Unmute output" : "Mute output")
            } else {
                Spacer()
                Text("NO OUTPUT").panelLabel(Theme.alert)
                Spacer()
            }

            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 2)
            Text("SYSTEM FX").panelLabel()
            let effects = model.systemEffects
            Button {
                var copy = effects
                copy.boost = !(effects.enabled && effects.boost)
                if copy.boost { copy.enabled = true }
                model.setSystemEffects(copy)
            } label: { Text("BOOST").frame(maxWidth: .infinity) }
                .buttonStyle(KeyStyle(isOn: effects.enabled && effects.boost, compact: true))
                .help("Magic Boost for all audio")
            Button(action: openEffects) { Text("EQ ›").frame(maxWidth: .infinity) }
                .buttonStyle(KeyStyle(isOn: effects.enabled && (!effects.isEQFlat || effects.audioUnit != nil), compact: true))
                .help("System equalizer and Audio Unit")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: 124)
        .frame(maxHeight: .infinity)
        .module()
    }
}

// MARK: Effects page

struct EffectsPage: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                EffectsEditor(effects: model.systemEffects, routeID: AudioEngine.systemID, title: "System effects · all audio",
                              model: model) { model.setSystemEffects($0) }
                Text("System effects apply to every app, on top of an app's own effects (the FX key on its channel). Alerts and interface sounds are left out, so they stay on the Sound Effects device.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Devices page

struct DevicesPage: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("OUTPUT", count: model.outputDevices.count) {
                    ForEach(model.outputDevices) { DeviceModule(device: $0, isInput: false, model: model) }
                }
                section("INPUT", count: model.inputDevices.count) {
                    ForEach(model.inputDevices) { DeviceModule(device: $0, isInput: true, model: model) }
                }
                if !model.outputDevices.isEmpty {
                    section("SOUND EFFECTS", count: nil) { SoundEffectsModule(model: model) }
                }
            }
            .padding(20)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    private func section<Content: View>(_ title: String, count: Int?, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).panelLabel(Theme.text2)
                if let count { Text(String(format: "%02d", count)).font(.mono(9.5)).foregroundStyle(Theme.text3) }
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            if count == 0 {
                Text("None connected").font(.system(size: 12)).foregroundStyle(Theme.text3).padding(.vertical, 6)
            }
            content()
        }
    }
}

private struct DeviceModule: View {
    let device: AudioDevice
    let isInput: Bool
    @ObservedObject var model: MixerModel
    @State private var expanded = false

    private var isDefault: Bool { device.objectID == (isInput ? model.defaultInputID : model.defaultDeviceID) }
    private var hasDetails: Bool { device.sampleRates.count > 1 || (!isInput && model.balances[device.uid] != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                LED(on: isDefault)
                Image(systemName: isInput && device.symbol == "laptopcomputer" ? "mic" : device.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(isDefault ? Theme.text : Theme.text2)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(spec).font(.mono(9.5)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                level

                Button(isDefault ? "DEFAULT" : "SET DEFAULT") {
                    guard !isDefault else { return }
                    isInput ? model.makeDefaultInput(device) : model.makeDefault(device)
                }
                .buttonStyle(KeyStyle(isOn: isDefault, compact: true))
                .help(isDefault ? "This is the system \(isInput ? "input" : "output")" : "Make this the system \(isInput ? "input" : "output")")
                .frame(width: 96, alignment: .trailing)

                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hasDetails ? 1 : 0)
                .disabled(!hasDetails)
                .accessibilityLabel(expanded ? "Hide details" : "Show balance and sample rate")
            }
            if expanded && hasDetails {
                details.padding(.leading, 56)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .module()
    }

    @ViewBuilder private var level: some View {
        let volume: Float? = isInput ? model.inputVolumes[device.uid] : model.outputVolume(device)
        if let volume {
            let software = !isInput && model.hasFixedVolume(device)
            let muted = !isInput && model.isOutputMuted(device)
            HStack(spacing: 10) {
                if software { Text("SOFT").panelLabel(Theme.signal).help("Software volume: this output has no volume control of its own") }
                if !isInput {
                    Button { model.toggleOutputMute(device) } label: {
                        Image(systemName: VolumeSymbol.name(volume: volume, muted: muted))
                            .font(.system(size: 11))
                            .foregroundStyle(muted ? Theme.alert : Theme.text3)
                            .frame(width: 18)
                    }
                    .buttonStyle(.plain)
                    .help(muted ? "Unmute" : "Mute")
                }
                Fader(value: Double(volume), tint: muted ? Theme.text3 : Theme.signal,
                      label: "\(device.name) \(isInput ? "input level" : "volume")",
                      valueText: "\(safeInt((volume * 100).rounded())) percent") { value in
                    if isInput { model.setInputVolume(Float(value), for: device) }
                    else if software { model.setSoftVolume(Float(value), for: device) }
                    else { model.setDeviceVolume(Float(value), for: device) }
                }
                .frame(width: 170)
                Readout(value: muted ? "MUTE" : "\(safeInt((volume * 100).rounded()))", unit: muted ? "" : "%",
                        color: muted ? Theme.alert : Theme.text, size: 12)
                    .frame(width: 42, alignment: .trailing)
            }
        } else {
            Text("FIXED LEVEL").panelLabel().frame(width: 260, alignment: .trailing)
        }
    }

    private var details: some View {
        HStack(spacing: 28) {
            if !isInput, let balance = model.balances[device.uid] {
                HStack(spacing: 8) {
                    Text("BALANCE").panelLabel()
                    Text("L").font(.mono(9)).foregroundStyle(Theme.text3)
                    Fader(value: Double(balance), detent: 0.5, tint: Theme.text2, label: "Balance",
                          valueText: balance == 0.5 ? "Centre" : balance < 0.5 ? "Left" : "Right") {
                        model.setBalance(Float($0), for: device)
                    }
                    .frame(width: 150)
                    Text("R").font(.mono(9)).foregroundStyle(Theme.text3)
                }
            }
            if device.sampleRates.count > 1 {
                HStack(spacing: 8) {
                    Text("SAMPLE RATE").panelLabel()
                    PanelMenu(title: Self.rate(device.sampleRate)) {
                        ForEach(device.sampleRates, id: \.self) { rate in
                            Button { model.setSampleRate(rate, for: device) } label: { menuItem(Self.rate(rate), rate == device.sampleRate) }
                        }
                    }
                    .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var spec: String {
        var parts = [device.kind.uppercased()]
        if device.sampleRate > 0 { parts.append(Self.rate(device.sampleRate)) }
        if !isInput, device.outputChannels > 0 { parts.append("\(device.outputChannels) CH") }
        let routed = isInput ? 0 : model.apps.filter { model.setting(for: $0.id).deviceUID == device.uid }.count
        if routed > 0 { parts.append("\(routed) APP\(routed == 1 ? "" : "S") ROUTED") }
        return parts.joined(separator: " · ")
    }

    static func rate(_ hz: Double) -> String { String(format: "%.1f kHz", hz / 1000) }
}

private struct SoundEffectsModule: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        HStack(spacing: 14) {
            LED(on: false).hidden()
            Image(systemName: "bell").font(.system(size: 15)).foregroundStyle(Theme.text2).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                PanelMenu(title: model.alertDevice?.name ?? "Choose a device", font: .system(size: 13, weight: .medium)) {
                    ForEach(model.outputDevices) { device in
                        Button { model.makeAlertDevice(device) } label: { menuItem(device.name, device.objectID == model.alertDeviceID) }
                    }
                }
                .fixedSize()
                Text("ALERTS AND INTERFACE SOUNDS").font(.mono(9.5)).foregroundStyle(Theme.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Fader(value: Double(model.alertVolume), label: "Sound effects volume",
                  valueText: "\(safeInt((model.alertVolume * 100).rounded())) percent") { model.setAlertVolume(Float($0)) }
                .frame(width: 170)
            Readout(value: "\(safeInt((model.alertVolume * 100).rounded()))", size: 12).frame(width: 42, alignment: .trailing)
            Spacer().frame(width: 134) // lines up with the device rows' level column
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .module()
    }
}

// MARK: - Menu bar panel

struct MenuBarMixer: View {
    @ObservedObject var model: MixerModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuShowAllDevices") private var showAll = false
    @State private var showingEQ = false

    private var apps: [AudioApp] { model.apps.filter { $0.isPlaying || model.settings[$0.id] != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                LED(color: Theme.live, on: model.apps.contains(where: \.isPlaying))
                Text("APPMIXER").font(.mono(10.5, .bold)).tracking(2).foregroundStyle(Theme.text)
                Spacer()
                IconKey(symbol: showAll ? "chevron.up" : "chevron.down",
                        help: showAll ? "Hide input and sound effects" : "Show input and sound effects") {
                    withAnimation(.easeOut(duration: 0.15)) { showAll.toggle() }
                }
                IconKey(symbol: "macwindow", help: "Open AppMixer") { openMain() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            rule

            VStack(spacing: 12) {
                if let output = model.defaultDevice {
                    IOLine(label: "OUT", devices: model.outputDevices, selected: output, onSelect: model.makeDefault,
                           volume: model.outputVolume(output), muted: model.isOutputMuted(output),
                           onVolume: { model.hasFixedVolume(output) ? model.setSoftVolume($0, for: output) : model.setDeviceVolume($0, for: output) },
                           onMute: { model.toggleOutputMute(output) })
                } else {
                    Text("NO OUTPUT DEVICE").panelLabel(Theme.alert).frame(maxWidth: .infinity, alignment: .leading)
                }
                if showAll {
                    if let input = model.defaultInput {
                        IOLine(label: "IN", devices: model.inputDevices, selected: input, onSelect: model.makeDefaultInput,
                               volume: model.inputVolumes[input.uid], muted: false,
                               onVolume: { model.setInputVolume($0, for: input) }, onMute: nil)
                    }
                    if let alert = model.alertDevice {
                        IOLine(label: "SFX", devices: model.outputDevices, selected: alert, onSelect: model.makeAlertDevice,
                               volume: model.alertVolume, muted: false, onVolume: model.setAlertVolume, onMute: nil)
                    }
                }
            }
            .padding(12)

            rule

            HStack(spacing: 6) {
                Text("SYSTEM FX").panelLabel()
                LED(on: model.systemEffects.isActive, size: 5)
                Spacer()
                let effects = model.systemEffects
                Button("BOOST") {
                    var copy = effects
                    copy.boost = !(effects.enabled && effects.boost)
                    if copy.boost { copy.enabled = true }
                    model.setSystemEffects(copy)
                }
                .buttonStyle(KeyStyle(isOn: effects.enabled && effects.boost, compact: true))
                .help("Magic Boost: quiet audio louder, everywhere")
                Button("EQ") { showingEQ.toggle() }
                    .buttonStyle(KeyStyle(isOn: effects.enabled && (!effects.isEQFlat || effects.audioUnit != nil), compact: true))
                    .help("System equalizer and Audio Unit")
                    .popover(isPresented: $showingEQ, arrowEdge: .bottom) {
                        EffectsEditor(effects: effects, routeID: AudioEngine.systemID, title: "System effects", model: model,
                                      compact: true) { model.setSystemEffects($0) }
                            .padding(14)
                            .frame(width: 420)
                            .background(Theme.canvas)
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            rule

            if model.isRequestingPermission || model.permission == .denied {
                Notice(tint: model.isRequestingPermission ? Theme.signal : Theme.caution,
                       symbol: model.isRequestingPermission ? "hand.raised" : "lock",
                       title: model.isRequestingPermission ? "Click Allow in the macOS prompt" : "Audio control is off",
                       message: model.isRequestingPermission ? "Changes start working once you allow AppMixer. The prompt may be in a corner of your screen."
                                                            : "AppMixer doesn't have permission to control app audio.",
                       actions: model.isRequestingPermission ? [] : [("Fix", openMain)])
                    .padding(10)
                rule
            }

            if apps.isEmpty {
                VStack(spacing: 6) {
                    Text("NOTHING PLAYING").font(.mono(10.5, .semibold)).tracking(1.6).foregroundStyle(Theme.text3)
                    Text("Apps appear here when they play sound.").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                // A ScrollView in a menu-bar window collapses to zero height unless given one explicitly.
                ScrollView {
                    VStack(spacing: 14) { ForEach(apps) { SourceRow(app: $0, model: model) } }
                        .padding(12)
                }
                .frame(height: min(CGFloat(apps.count) * 58 + 24, 340))
            }

            rule

            HStack(spacing: 8) {
                SettingsLink { Text("SETTINGS") }.buttonStyle(KeyStyle(compact: true))
                Spacer()
                Button("QUIT") { NSApp.terminate(nil) }.buttonStyle(KeyStyle(compact: true))
            }
            .padding(10)
        }
        .frame(width: 340)
        .background(Theme.canvas)
    }

    private var rule: some View { Rectangle().fill(Theme.line).frame(height: 1) }

    private func openMain() {
        openWindow(id: "mixer")
        NSApp.activate()
    }
}

/// One device line in the menu bar: role, device, level.
private struct IOLine: View {
    let label: String
    let devices: [AudioDevice]
    let selected: AudioDevice
    let onSelect: (AudioDevice) -> Void
    /// nil: the device has no adjustable level.
    let volume: Float?
    let muted: Bool
    let onVolume: (Float) -> Void
    let onMute: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).panelLabel(Theme.text2).frame(width: 28, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                PanelMenu(title: selected.name, font: .system(size: 12, weight: .medium)) {
                    ForEach(devices) { device in
                        Button { onSelect(device) } label: { menuItem(device.name, device.uid == selected.uid) }
                    }
                }
                .fixedSize()
                .help("Choose the device")
                HStack(spacing: 8) {
                    if let volume {
                        Fader(value: Double(volume), tint: muted ? Theme.text3 : Theme.signal, label: "\(label) level",
                              valueText: "\(safeInt((volume * 100).rounded())) percent") { onVolume(Float($0)) }
                        Readout(value: muted ? "MUTE" : "\(safeInt((volume * 100).rounded()))", unit: muted ? "" : "%",
                                color: muted ? Theme.alert : Theme.text, size: 11)
                            .frame(width: 40, alignment: .trailing)
                    } else {
                        Text("FIXED LEVEL").panelLabel()
                        Spacer()
                    }
                    Button("M") { onMute?() }
                        .buttonStyle(KeyStyle(isOn: muted, tint: Theme.alert, compact: true))
                        .accessibilityLabel(muted ? "Unmute" : "Mute")
                        .opacity(onMute == nil ? 0 : 1) // keeps every line's fader the same length
                        .disabled(onMute == nil)
                }
            }
        }
    }
}

private struct SourceRow: View {
    let app: AudioApp
    @ObservedObject var model: MixerModel
    @AppStorage(Prefs.maxBoost) private var maxBoost = 2.0

    var body: some View {
        let setting = model.setting(for: app.id)
        let percent = safeInt((setting.volume * 100).rounded())
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                AppIcon(app: app, size: 18)
                Text(app.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                if model.errors[app.id] != nil {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(Theme.alert)
                        .help(model.errors[app.id] ?? "")
                }
                Spacer()
                RouteMenu(app: app, model: model, compact: setting.deviceUID == nil)
                    .fixedSize()
                EffectsButton(app: app, model: model, compact: true)
            }
            HStack(spacing: 8) {
                Fader(value: Double(setting.volume), range: 0...max(maxBoost, 1), detent: 1,
                      tint: setting.muted ? Theme.text3 : setting.volume > 1 ? Theme.signal : Theme.text,
                      label: "\(app.name) volume", valueText: "\(percent) percent") { model.setVolume(Float($0), for: app.id) }
                    .disabled(setting.muted)
                Readout(value: setting.muted ? "MUTE" : "\(percent)", unit: setting.muted ? "" : "%",
                        color: setting.muted ? Theme.alert : setting.volume > 1 ? Theme.signal : Theme.text, size: 11)
                    .frame(width: 40, alignment: .trailing)
                Button("M") { model.toggleMute(app.id) }
                    .buttonStyle(KeyStyle(isOn: setting.muted, tint: Theme.alert, compact: true))
                    .accessibilityLabel(setting.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            }
            .padding(.leading, 26)
        }
    }
}

// MARK: - Shared

struct AppIcon: View {
    let app: AudioApp
    let size: CGFloat

    var body: some View {
        Group {
            if let image = app.icon {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(Theme.text3)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if app.isPlaying { LED(color: Theme.live, on: true, size: size >= 28 ? 7 : 5).offset(x: 2, y: 2) }
        }
    }
}
