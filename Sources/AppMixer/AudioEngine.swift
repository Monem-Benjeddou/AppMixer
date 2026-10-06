import CoreAudio
import Foundation

/// Everything that talks to the audio server. Calls into Core Audio are synchronous IPC to coreaudiod and can
/// stall for seconds (a waking Bluetooth device, a slow virtual driver), so all of it runs on one serial queue —
/// never the main thread.
final class AudioEngine: @unchecked Sendable { // confined to `queue`
    struct Snapshot {
        var devices: [OutputDevice]
        var defaultDeviceID: AudioObjectID
        var deviceVolumes: [String: Float]
        var apps: [AudioApp]
    }

    struct TapKey: Equatable {
        let processObjectIDs: [AudioObjectID]
        let outputUID: String
        // The device's identity and format: a reconnect (new object ID) or a switch to call mode
        // (new rate or channel count) needs a new route.
        var deviceID: AudioObjectID = 0
        var sampleRate: Double = 0
        var outputChannels: Int = 0
    }

    let queue = DispatchQueue(label: "dev.appmixer.audio", qos: .userInitiated)

    // Only touched on `queue`.
    private var taps: [String: AppTap] = [:]
    private var tapKeys: [String: TapKey] = [:]
    private var lastRenderCounts: [String: UInt64] = [:]
    /// Devices whose format changes we already listen to.
    private var observedDevices: Set<AudioObjectID> = []
    /// Called (on `queue`) when an output device changes format or goes away.
    var onDeviceChange: (() -> Void)?
    /// Configurations that failed, so periodic refreshes don't retry (and re-prompt) until something changes.
    private var failed: [String: TapKey] = [:]
    private var errors: [String: String] = [:]
    private var devices: [OutputDevice] = []
    private var defaultDeviceID = AudioObjectID(kAudioObjectUnknown)

    // MARK: Scanning (on queue)

    func scan() -> Snapshot {
        dispatchPrecondition(condition: .onQueue(queue))
        devices = AudioDiscovery.outputDevices()
        for device in devices where !observedDevices.contains(device.objectID) {
            observedDevices.insert(device.objectID)
            for (selector, scope) in [(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
                                      (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
                                      (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal)] {
                CA.observe(device.objectID, selector, scope: scope, queue: queue) { [weak self] in self?.onDeviceChange?() }
            }
        }
        defaultDeviceID = CA.defaultOutputDevice ?? AudioObjectID(kAudioObjectUnknown)
        var volumes: [String: Float] = [:]
        for device in devices { volumes[device.uid] = CA.deviceVolume(device.objectID) }
        return Snapshot(devices: devices, defaultDeviceID: defaultDeviceID, deviceVolumes: volumes,
                        apps: AudioDiscovery.apps())
    }

    // MARK: Taps (on queue)

    /// Brings taps in line with the settings. Returns the current per-app errors.
    func reconcile(apps: [AudioApp], settings: [String: AppSetting], canCreateTaps: Bool) -> [String: String] {
        dispatchPrecondition(condition: .onQueue(queue))
        for app in apps { apply(app, settings[app.id] ?? AppSetting(), canCreateTaps: canCreateTaps) }

        let live = Set(apps.map(\.id))
        for id in Array(taps.keys) where !live.contains(id) { taps[id] = nil; tapKeys[id] = nil }
        for id in Array(failed.keys) where !live.contains(id) { failed[id] = nil }
        for id in Array(errors.keys) where !live.contains(id) { errors[id] = nil }
        return errors
    }

    /// Fast path for slider drags: when the tap already exists this is just a gain write.
    func update(_ app: AudioApp, _ setting: AppSetting, canCreateTaps: Bool) -> [String: String] {
        dispatchPrecondition(condition: .onQueue(queue))
        failed[app.id] = nil
        apply(app, setting, canCreateTaps: canCreateTaps)
        return errors
    }

    func remove(_ appID: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        taps[appID] = nil
        tapKeys[appID] = nil
        failed[appID] = nil
        errors[appID] = nil
    }

    func removeAll() {
        dispatchPrecondition(condition: .onQueue(queue))
        taps = [:]
        tapKeys = [:]
        lastRenderCounts = [:]
        failed = [:]
        errors = [:]
    }

    func clearFailures() {
        dispatchPrecondition(condition: .onQueue(queue))
        failed = [:]
    }

    /// Finds routes whose audio has stopped flowing (the output went away under them) and removes
    /// them. Returns true if any were removed, so the caller rebuilds them with a refresh.
    func removeStalledTaps() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        var removed = false
        for (id, tap) in taps {
            let count = tap.renderCount
            defer { lastRenderCounts[id] = count }
            guard Date().timeIntervalSince(tap.createdAt) > 3, let last = lastRenderCounts[id], last == count else { continue }
            log.error("Audio route for \(id, privacy: .public) stopped; rebuilding it")
            taps[id] = nil
            tapKeys[id] = nil
            lastRenderCounts[id] = nil
            failed[id] = nil
            removed = true
        }
        return removed
    }

    private func apply(_ app: AudioApp, _ setting: AppSetting, canCreateTaps: Bool) {
        guard let device = target(for: setting) else { return }
        let gain = setting.muted ? 0 : setting.volume
        let key = TapKey(processObjectIDs: app.processObjectIDs, outputUID: device.uid, deviceID: device.objectID,
                         sampleRate: device.sampleRate, outputChannels: device.outputChannels)

        // An existing tap is kept even back at 100% so dragging through 100% doesn't tear it down and rebuild it.
        if let tap = taps[app.id], tapKeys[app.id] == key {
            tap.gain = gain
            return
        }
        if tapKeys[app.id] != nil, tapKeys[app.id] != key {
            log.notice("Output for \(app.name, privacy: .public) changed (\(device.name, privacy: .public), \(Int(device.sampleRate)) Hz, \(device.outputChannels) ch); rebuilding its route")
        }
        guard !setting.isPassthrough else {
            taps[app.id] = nil
            errors[app.id] = nil
            return
        }
        guard canCreateTaps, failed[app.id] != key else { return }

        taps[app.id] = nil // tear down the old tap before creating its replacement
        tapKeys[app.id] = nil
        do {
            taps[app.id] = try AppTap(processObjectIDs: key.processObjectIDs, outputDevice: device, gain: gain)
            tapKeys[app.id] = key
            lastRenderCounts[app.id] = nil
            errors[app.id] = nil
        } catch {
            failed[app.id] = key
            errors[app.id] = error.localizedDescription
        }
    }

    /// The chosen device if it's connected, otherwise the system default (the choice is kept for when it reconnects).
    private func target(for setting: AppSetting) -> OutputDevice? {
        if let uid = setting.deviceUID, let chosen = devices.first(where: { $0.uid == uid }) { return chosen }
        return devices.first { $0.objectID == defaultDeviceID }
    }
}
