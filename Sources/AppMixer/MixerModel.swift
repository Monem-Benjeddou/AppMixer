import AppKit
import CoreAudio
import Combine

struct AppSetting: Codable, Equatable {
    var volume: Float = 1
    var muted = false
    /// nil = follow the system default output.
    var deviceUID: String?

    var isPassthrough: Bool { volume == 1 && !muted && deviceUID == nil }
}

/// UI state and per-app settings. Holds no Core Audio calls itself: all of that is done by `AudioEngine`
/// on its own queue, and results are published back here on the main thread.
@MainActor
final class MixerModel: ObservableObject {
    static let shared = MixerModel()

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var outputDevices: [OutputDevice] = []
    @Published private(set) var defaultDeviceID = AudioObjectID(kAudioObjectUnknown)
    @Published private(set) var deviceVolumes: [String: Float] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var settings: [String: AppSetting]
    @Published private(set) var permission = AudioCapturePermission.status
    /// True while a scan has been stuck in the audio server for a while (shown as a banner; the UI stays usable).
    @Published private(set) var audioServerUnresponsive = false

    private let engine = AudioEngine()
    private var timer: Timer?
    private var refreshInFlight = false
    private var refreshPending = false
    private var refreshStarted = Date()
    private var isRequestingPermission = false
    /// Set when the system prompt said yes, in case the status check can't see it.
    private var grantedThisSession = false
    private static let settingsKey = "appSettings"

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

        // Listener blocks run on the engine's queue; hop to main to schedule a refresh.
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            CA.observeSystem(selector, queue: engine.queue) {
                DispatchQueue.main.async { MixerModel.shared.refresh() }
            }
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

    var defaultDevice: OutputDevice? { outputDevices.first { $0.objectID == defaultDeviceID } }
    var defaultDeviceName: String { defaultDevice?.name ?? "No output device" }

    func setting(for appID: String) -> AppSetting { settings[appID] ?? AppSetting() }

    // MARK: Actions

    func setVolume(_ volume: Float, for appID: String) { update(appID) { $0.volume = volume } }
    func toggleMute(_ appID: String) { update(appID) { $0.muted.toggle() } }
    func setDevice(_ uid: String?, for appID: String) { update(appID) { $0.deviceUID = uid } }

    func reset(_ appID: String) {
        settings[appID] = nil
        save()
        errors[appID] = nil
        engine.queue.async { [engine] in engine.remove(appID) }
    }

    func resetAll() {
        settings = [:]
        save()
        errors = [:]
        engine.queue.async { [engine] in engine.removeAll() }
    }

    func makeDefault(_ device: OutputDevice) {
        defaultDeviceID = device.objectID
        engine.queue.async { CA.setDefaultOutputDevice(device.objectID) }
    }

    func setDeviceVolume(_ volume: Float, for device: OutputDevice) {
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

    private func update(_ appID: String, _ change: (inout AppSetting) -> Void) {
        var setting = self.setting(for: appID)
        change(&setting)
        settings[appID] = setting.isPassthrough ? nil : setting
        save()

        guard let app = apps.first(where: { $0.id == appID }) else { return }
        let canCreate = setting.isPassthrough || ensurePermission()
        engine.queue.async { [engine] in
            let errors = engine.update(app, setting, canCreateTaps: canCreate)
            DispatchQueue.main.async { MixerModel.shared.publish(errors: errors) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    // MARK: Refresh

    private func tick() {
        // Watchdog: a scan that hasn't come back means the audio server is stuck. Say so instead of looking frozen.
        if refreshInFlight, Date().timeIntervalSince(refreshStarted) > 4, !audioServerUnresponsive {
            log.error("Audio server has not responded for 4s")
            audioServerUnresponsive = true
        }
        refresh()
    }

    /// Rescans in the background. Coalesced: at most one scan runs, plus one queued behind it.
    func refresh() {
        guard !refreshInFlight else {
            refreshPending = true
            return
        }
        refreshInFlight = true
        refreshStarted = Date()
        let settings = self.settings
        let canCreate = settings.values.contains { !$0.isPassthrough } ? ensurePermission() : false

        engine.queue.async { [engine] in
            let snapshot = engine.scan()
            let errors = engine.reconcile(apps: snapshot.apps, settings: settings, canCreateTaps: canCreate)
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
    }

    private func publish(errors newErrors: [String: String]) {
        if newErrors != errors { errors = newErrors }
    }

    // MARK: Permission

    /// True when taps may be created. Asks macOS at most once; never creates a tap while the answer is pending or "no".
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
