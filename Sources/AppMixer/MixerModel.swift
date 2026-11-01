import AppKit
import CoreAudio
import Combine

struct AppSetting: Codable, Equatable {
    var volume: Float = 1
    var muted = false
    /// nil = follow the system default output.
    var deviceUID: String?
    var effects = Effects()

    var isPassthrough: Bool { volume == 1 && !muted && deviceUID == nil && !effects.isActive }

    init() {}

    // Settings saved before a field existed still decode; synthesized decoding would reject them and lose every app's setting.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID)
        effects = try c.decodeIfPresent(Effects.self, forKey: .effects) ?? Effects()
    }
}

/// UI state and per-app settings. Holds no Core Audio calls itself: all of that is done by `AudioEngine`
/// on its own queue, and results are published back here on the main thread.
@MainActor
final class MixerModel: ObservableObject {
    static let shared = MixerModel()

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var defaultDeviceID = AudioObjectID(kAudioObjectUnknown)
    @Published private(set) var deviceVolumes: [String: Float] = [:]
    @Published private(set) var mutedDevices: Set<String> = []
    @Published private(set) var balances: [String: Float] = [:]
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var defaultInputID = AudioObjectID(kAudioObjectUnknown)
    @Published private(set) var inputVolumes: [String: Float] = [:]
    @Published private(set) var alertDeviceID = AudioObjectID(kAudioObjectUnknown)
    /// Sound effects volume, 0...1, as in System Settings › Sound.
    @Published private(set) var alertVolume: Float = 1
    @Published private(set) var systemEffects: Effects
    /// Software volume for outputs without a volume control of their own (HDMI, DisplayPort), by device UID.
    @Published private(set) var softVolumes: [String: Float]
    @Published private(set) var softMuted: Set<String>
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var settings: [String: AppSetting]
    @Published private(set) var permission = AudioCapturePermission.status
    /// True while a scan has been stuck in the audio server for a while (shown as a banner; the UI stays usable).
    @Published private(set) var audioServerUnresponsive = false
    /// Safe mode after repeated crashes: saved volumes aren't applied (no taps are created) until
    /// they're turned back on. Audio a crashing tap could take down then just plays normally.
    @Published private(set) var volumesPaused = Stability.safeMode
    /// "AppMixer quit unexpectedly and was reopened", until dismissed.
    @Published var crashNotice = Stability.safeMode ? nil : Stability.previousCrash?.message

    private let engine = AudioEngine()
    private var timer: Timer?
    private var refreshInFlight = false
    private var refreshPending = false
    private var refreshStarted = Date()
    /// True while the macOS permission prompt is waiting for an answer (shown as a hint: the prompt
    /// often appears in a screen corner where it's easy to miss).
    @Published private(set) var isRequestingPermission = false
    /// Set when the system prompt said yes, in case the status check can't see it.
    private var grantedThisSession = false
    private static let settingsKey = "appSettings"
    private static let systemEffectsKey = "systemEffects"
    private static let softVolumesKey = "softVolumes"
    private static let softMutedKey = "softMuted"
    private var alertVolumeWork: DispatchWorkItem?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey) {
            do {
                settings = try JSONDecoder().decode([String: AppSetting].self, from: data)
            } catch {
                // Keep the unreadable copy for diagnosis rather than silently overwriting it.
                log.error("Saved settings are unreadable, starting fresh: \(error.localizedDescription, privacy: .public)")
                UserDefaults.standard.set(data, forKey: Self.settingsKey + ".unreadable")
                settings = [:]
            }
        } else {
            settings = [:]
        }
        let defaults = UserDefaults.standard
        systemEffects = defaults.data(forKey: Self.systemEffectsKey).flatMap { try? JSONDecoder().decode(Effects.self, from: $0) } ?? Effects()
        softVolumes = defaults.dictionary(forKey: Self.softVolumesKey) as? [String: Float] ?? [:]
        softMuted = Set(defaults.stringArray(forKey: Self.softMutedKey) ?? [])

        // Listener blocks run on the engine's queue; hop to main to schedule a refresh.
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            CA.observeSystem(selector, queue: engine.queue) {
                DispatchQueue.main.async { MixerModel.shared.refresh() }
            }
        }
        // A device switching format (Bluetooth earbuds entering call mode) or going away: reroute.
        engine.onDeviceChange = {
            DispatchQueue.main.async { MixerModel.shared.refresh() }
        }
        // If coreaudiod restarts, every tap and object ID we hold is dead: drop them and rebuild from scratch.
        CA.observeSystem(kAudioHardwarePropertyServiceRestarted, queue: engine.queue) { [engine] in
            log.notice("Audio server restarted; rebuilding taps")
            engine.removeAll()
            DispatchQueue.main.async { MixerModel.shared.refresh() }
        }
        // Devices come and go across sleep; rescan on wake.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { MixerModel.shared.refresh() }
        }
        // "Is playing" and device volume have no system-wide notification, so poll them (off the main thread).
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckPermission() }
        }
        refresh()
    }

    var defaultDevice: AudioDevice? { outputDevices.first { $0.objectID == defaultDeviceID } }
    var defaultDeviceName: String { defaultDevice?.name ?? "No output device" }
    var defaultInput: AudioDevice? { inputDevices.first { $0.objectID == defaultInputID } }
    var alertDevice: AudioDevice? { outputDevices.first { $0.objectID == alertDeviceID } }

    /// True for outputs macOS can't change the volume of; AppMixer gives those a software volume.
    func hasFixedVolume(_ device: AudioDevice) -> Bool { deviceVolumes[device.uid] == nil }

    /// The volume shown for a device: its own, or AppMixer's software volume for a fixed-volume output.
    func outputVolume(_ device: AudioDevice) -> Float { deviceVolumes[device.uid] ?? softVolumes[device.uid] ?? 1 }
    func isOutputMuted(_ device: AudioDevice) -> Bool {
        hasFixedVolume(device) ? softMuted.contains(device.uid) : mutedDevices.contains(device.uid)
    }

    private var global: AudioEngine.Global {
        AudioEngine.Global(effects: volumesPaused ? Effects() : systemEffects, softVolumes: softVolumes, softMuted: softMuted)
    }

    func setting(for appID: String) -> AppSetting { settings[appID] ?? AppSetting() }

    // MARK: Actions

    func setVolume(_ volume: Float, for appID: String) { update(appID) { $0.volume = volume } }
    func toggleMute(_ appID: String) { update(appID) { $0.muted.toggle() } }
    func setDevice(_ uid: String?, for appID: String) { update(appID) { $0.deviceUID = uid } }
    func setEffects(_ effects: Effects, for appID: String) { update(appID) { $0.effects = effects } }

    func reset(_ appID: String) {
        settings[appID] = nil
        save()
        errors[appID] = nil
        engine.queue.async { [engine] in engine.remove(appID) }
        refresh() // the system route takes the app back
    }

    func setSystemEffects(_ effects: Effects) {
        systemEffects = effects
        if let data = try? JSONEncoder().encode(effects) { UserDefaults.standard.set(data, forKey: Self.systemEffectsKey) }
        if volumesPaused { return resumeVolumes() }
        push()
    }

    func setSoftVolume(_ volume: Float, for device: AudioDevice) {
        softVolumes[device.uid] = min(max(volume, 0), 1)
        softMuted.remove(device.uid)
        saveSoftVolumes()
        push()
    }

    func toggleOutputMute(_ device: AudioDevice) {
        if hasFixedVolume(device) {
            if softMuted.remove(device.uid) == nil { softMuted.insert(device.uid) }
            saveSoftVolumes()
            push()
        } else {
            let mute = !mutedDevices.contains(device.uid)
            if mute { mutedDevices.insert(device.uid) } else { mutedDevices.remove(device.uid) }
            engine.queue.async {
                var addr = CA.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
                var value = UInt32(mute ? 1 : 0)
                AudioObjectSetPropertyData(device.objectID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            }
        }
    }

    /// A volume key press for an output with no volume control. Steps of 1/16, like macOS.
    func volumeKey(_ key: VolumeKey) {
        guard let device = defaultDevice else { return }
        let current = softVolumes[device.uid] ?? 1
        switch key {
        case .up: setSoftVolume(current + 1 / 16, for: device)
        case .down: setSoftVolume(current - 1 / 16, for: device)
        case .mute: toggleOutputMute(device)
        }
        VolumeHUD.show(volume: softVolumes[device.uid] ?? 1, muted: softMuted.contains(device.uid), device: device.name)
    }

    private func saveSoftVolumes() {
        UserDefaults.standard.set(softVolumes, forKey: Self.softVolumesKey)
        UserDefaults.standard.set(Array(softMuted), forKey: Self.softMutedKey)
    }

    func makeDefaultInput(_ device: AudioDevice) {
        defaultInputID = device.objectID
        engine.queue.async { CA.setDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, device.objectID) }
    }

    func makeAlertDevice(_ device: AudioDevice) {
        alertDeviceID = device.objectID
        engine.queue.async { CA.setDefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice, device.objectID) }
    }

    func setInputVolume(_ volume: Float, for device: AudioDevice) {
        inputVolumes[device.uid] = volume
        engine.queue.async { CA.setDeviceVolume(device.objectID, volume, scope: kAudioObjectPropertyScopeInput) }
    }

    func setBalance(_ balance: Float, for device: AudioDevice) {
        balances[device.uid] = balance
        engine.queue.async { CA.setBalance(device.objectID, balance) }
    }

    func setSampleRate(_ rate: Double, for device: AudioDevice) {
        engine.queue.async { CA.setSampleRate(device.objectID, rate) }
        // The device's format listener refreshes and rebuilds its routes once the change lands.
    }

    /// Sound effects volume has no Core Audio property; System Settings' own value is set through AppleScript.
    /// Debounced: a slider drag runs the script once it settles, not on every step.
    func setAlertVolume(_ volume: Float) {
        alertVolume = volume
        alertVolumeWork?.cancel()
        let work = DispatchWorkItem {
            var error: NSDictionary?
            NSAppleScript(source: "set volume alert volume \(safeInt((volume * 100).rounded()))")?.executeAndReturnError(&error)
            if let error { log.error("Setting the alert volume failed: \(error, privacy: .public)") }
            MainActor.assumeIsolated { MixerModel.shared.alertVolumeWork = nil }
        }
        alertVolumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Opens the plug-in's own editor for the Audio Unit on a route (an app's ID, or `AudioEngine.systemID`).
    func openAudioUnitEditor(for id: String, title: String) {
        engine.queue.async { [engine] in
            guard let unit = engine.audioUnit(for: id) else { return }
            DispatchQueue.main.async {
                AudioUnitWindow.show(unit, title: title) {
                    engine.queue.async { engine.saveAudioUnitState(for: id) }
                }
            }
        }
    }

    func resetAll() {
        settings = [:]
        save()
        errors = [:]
        engine.queue.async { [engine] in engine.removeAll() }
    }

    func makeDefault(_ device: AudioDevice) {
        defaultDeviceID = device.objectID
        engine.queue.async { CA.setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, device.objectID) }
    }

    func setDeviceVolume(_ volume: Float, for device: AudioDevice) {
        deviceVolumes[device.uid] = volume
        engine.queue.async { CA.setDeviceVolume(device.objectID, volume) }
    }

    /// Clears remembered failures and tries again.
    func retryFailed() {
        errors = [:]
        engine.queue.async { [engine] in engine.clearFailures() }
        refresh()
    }

    /// Called when the app becomes active (e.g. back from System Settings) so a new permission takes effect.
    func recheckPermission() {
        let status = AudioCapturePermission.status
        guard status != permission, !(status == .unknown && grantedThisSession) else { return }
        permission = status
        engine.queue.async { [engine] in engine.clearFailures() }
        refresh()
    }

    func resumeVolumes() {
        Stability.leaveSafeMode()
        volumesPaused = false
        refresh()
    }

    private func update(_ appID: String, _ change: (inout AppSetting) -> Void) {
        var setting = self.setting(for: appID)
        change(&setting)
        settings[appID] = setting.isPassthrough ? nil : setting
        save()
        // Changing a volume in safe mode means you want them back.
        if volumesPaused { return resumeVolumes() }

        guard let app = apps.first(where: { $0.id == appID }) else { return }
        let canCreate = setting.isPassthrough || ensurePermission()
        let global = self.global
        engine.queue.async { [engine] in
            let errors = engine.update(app, setting, global: global, canCreateTaps: canCreate)
            DispatchQueue.main.async { MixerModel.shared.publish(errors: errors) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    /// Applies system-wide changes (system effects, software volume) without rescanning.
    private func push() {
        let settings = volumesPaused ? [:] : self.settings
        let global = self.global
        let apps = self.apps
        let canCreate = needsTaps(settings, global) ? ensurePermission() : false
        engine.queue.async { [engine] in
            let errors = engine.reconcile(apps: apps, settings: settings, global: global, canCreateTaps: canCreate)
            DispatchQueue.main.async { MixerModel.shared.publish(errors: errors) }
        }
    }

    private func needsTaps(_ settings: [String: AppSetting], _ global: AudioEngine.Global) -> Bool {
        settings.values.contains { !$0.isPassthrough } || global.effects.isActive
            || outputDevices.contains { hasFixedVolume($0) && global.gain(for: $0.uid) != 1 }
    }

    // MARK: Refresh

    private func tick() {
        // Watchdog: a scan that hasn't come back means the audio server is stuck. Say so instead of looking frozen.
        if refreshInFlight, Date().timeIntervalSince(refreshStarted) > 4, !audioServerUnresponsive {
            log.error("Audio server has not responded for 4s")
            audioServerUnresponsive = true
        }
        // Routes whose audio stopped flowing are rebuilt, whether or not anything is on screen.
        engine.queue.async { [engine] in
            if engine.removeStalledTaps() { DispatchQueue.main.async { MixerModel.shared.refresh() } }
        }
        // "Is playing" and device volumes are only ever shown, so with no window or menu open there's
        // nothing to poll for: apps and devices coming and going arrive as system notifications.
        // A slow rescan stays as a safety net.
        if !Self.isUIVisible, Date().timeIntervalSince(refreshStarted) < 30 { return }
        refresh()
    }

    /// Whether any AppMixer window or the menu bar panel is on screen.
    private static var isUIVisible: Bool {
        NSApp.windows.contains { window in
            window.isVisible && window.occlusionState.contains(.visible)
                && !String(describing: type(of: window)).contains("StatusBar")
        }
    }

    /// Rescans in the background. Coalesced: at most one scan runs, plus one queued behind it.
    func refresh() {
        guard !refreshInFlight else {
            refreshPending = true
            return
        }
        refreshInFlight = true
        refreshStarted = Date()
        let settings = volumesPaused ? [:] : self.settings
        let global = self.global
        let canCreate = needsTaps(settings, global) ? ensurePermission() : false

        engine.queue.async { [engine] in
            let snapshot = engine.scan()
            let errors = engine.reconcile(apps: snapshot.apps, settings: settings, global: global, canCreateTaps: canCreate)
            DispatchQueue.main.async {
                let model = MixerModel.shared
                model.publish(snapshot)
                model.publish(errors: errors)
                model.refreshInFlight = false
                if model.audioServerUnresponsive { model.audioServerUnresponsive = false }
                if model.refreshPending {
                    model.refreshPending = false
                    model.refresh()
                }
            }
        }
    }

    private func publish(_ snapshot: AudioEngine.Snapshot) {
        if snapshot.devices != outputDevices { outputDevices = snapshot.devices }
        if snapshot.defaultDeviceID != defaultDeviceID { defaultDeviceID = snapshot.defaultDeviceID }
        if snapshot.deviceVolumes != deviceVolumes { deviceVolumes = snapshot.deviceVolumes }
        if snapshot.apps != apps { apps = snapshot.apps }
        if snapshot.mutedDevices != mutedDevices { mutedDevices = snapshot.mutedDevices }
        if snapshot.balances != balances { balances = snapshot.balances }
        if snapshot.inputDevices != inputDevices { inputDevices = snapshot.inputDevices }
        if snapshot.defaultInputID != defaultInputID { defaultInputID = snapshot.defaultInputID }
        if snapshot.inputVolumes != inputVolumes { inputVolumes = snapshot.inputVolumes }
        if snapshot.alertDeviceID != alertDeviceID { alertDeviceID = snapshot.alertDeviceID }
        // Read here rather than on the audio queue: it's a preferences read, not an audio-server call.
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let alert = (CFPreferencesCopyAppValue("com.apple.sound.beep.volume" as CFString, kCFPreferencesAnyApplication) as? NSNumber)?.floatValue ?? 1
        if alertVolumeWork == nil, alert != alertVolume { alertVolume = alert } // not mid-drag
    }

    private func publish(errors newErrors: [String: String]) {
        if newErrors != errors { errors = newErrors }
    }

    // MARK: Permission

    /// True when taps may be created. Asks macOS at most once; never creates a tap while the answer is pending or "no".
    /// Clears a stale permission entry and asks again (one system prompt).
    func resetPermission() {
        guard AudioCapturePermission.reset() else {
            log.error("Couldn't reset the audio capture permission")
            openPrivacySettings()
            return
        }
        log.notice("Audio capture permission reset; asking again")
        grantedThisSession = false
        permission = .unknown
        engine.queue.async { [engine] in engine.clearFailures() }
        _ = ensurePermission()
    }

    private func ensurePermission() -> Bool {
        let status = AudioCapturePermission.status
        let effective: AudioCapturePermission.Status = status == .unknown && grantedThisSession ? .granted : status
        if effective != permission { permission = effective }

        switch effective {
        case .granted:
            return true
        case .denied:
            return false
        case .unknown:
            guard !isRequestingPermission else { return false }
            isRequestingPermission = true
            AudioCapturePermission.request { granted in
                let model = MixerModel.shared
                model.isRequestingPermission = false
                model.grantedThisSession = granted
                model.permission = granted ? .granted : AudioCapturePermission.status
                if granted { model.refresh() }
            }
            return false
        }
    }
}
