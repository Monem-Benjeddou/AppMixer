import AVFoundation
import CoreAudio
import Foundation

/// Everything that talks to the audio server. Calls into Core Audio are synchronous IPC to coreaudiod and can
/// stall for seconds (a waking Bluetooth device, a slow virtual driver), so all of it runs on one serial queue —
/// never the main thread.
final class AudioEngine: @unchecked Sendable { // confined to `queue`
    struct Snapshot {
        var devices: [AudioDevice]
        var defaultDeviceID: AudioObjectID
        var deviceVolumes: [String: Float]
        var mutedDevices: Set<String>
        var balances: [String: Float]
        var inputDevices: [AudioDevice]
        var defaultInputID: AudioObjectID
        var inputVolumes: [String: Float]
        /// The device alerts and other sound effects play on.
        var alertDeviceID: AudioObjectID
        var apps: [AudioApp]
    }

    /// The system-wide effects route's key in `taps` and `errors`. Not a bundle ID, so no app can collide with it.
    static let systemID = "AppMixer.system"

    struct TapKey: Equatable {
        let processObjectIDs: [AudioObjectID]
        let outputUID: String
        // The device's identity and format: a reconnect (new object ID) or a switch to call mode
        // (new rate or channel count) needs a new route.
        var deviceID: AudioObjectID = 0
        var sampleRate: Double = 0
        var outputChannels: Int = 0
        var audioUnit: AudioUnitRef?
        /// The system Audio Unit, which app routes run a copy of.
        var systemAudioUnit: AudioUnitRef?
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
    private var devices: [AudioDevice] = []
    private var defaultDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var appParams: [String: EffectParams] = [:]
    /// Outputs with no volume control of their own; only these get the software volume.
    private var fixedVolume: Set<String> = []
    /// The alert sound server: kept out of the system route so alerts stay on the Sound Effects device.
    private var soundEffectProcesses: [AudioObjectID] = []
    /// Forwards parameter changes made on the system plug-in (in its editor) to the copies on app routes.
    private var systemUnitObserver: (tree: AUParameterTree, token: AUParameterObserverToken)?
    private let systemParams = EffectParams()

    // MARK: Scanning (on queue)

    func scan() -> Snapshot {
        dispatchPrecondition(condition: .onQueue(queue))
        devices = AudioDiscovery.devices(kAudioObjectPropertyScopeOutput)
        for device in devices where !observedDevices.contains(device.objectID) {
            observedDevices.insert(device.objectID)
            for (selector, scope) in [(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
                                      (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
                                      (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
                                      // so the menu bar volume indicator follows the volume keys
                                      (kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput),
                                      (kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)] {
                CA.observe(device.objectID, selector, scope: scope, queue: queue) { [weak self] in self?.onDeviceChange?() }
            }
        }
        let unknown = AudioObjectID(kAudioObjectUnknown)
        defaultDeviceID = CA.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) ?? unknown
        var volumes: [String: Float] = [:]
        var muted: Set<String> = []
        var balances: [String: Float] = [:]
        fixedVolume = []
        for device in devices {
            volumes[device.uid] = CA.deviceVolume(device.objectID)
            if volumes[device.uid] == nil { fixedVolume.insert(device.uid) }
            balances[device.uid] = CA.balance(device.objectID)
            if CA.isMuted(device.objectID) { muted.insert(device.uid) }
        }
        soundEffectProcesses = AudioDiscovery.soundEffectProcesses()
        let inputs = AudioDiscovery.devices(kAudioObjectPropertyScopeInput)
        var inputVolumes: [String: Float] = [:]
        for device in inputs { inputVolumes[device.uid] = CA.deviceVolume(device.objectID, scope: kAudioObjectPropertyScopeInput) }
        return Snapshot(devices: devices, defaultDeviceID: defaultDeviceID, deviceVolumes: volumes, mutedDevices: muted,
                        balances: balances, inputDevices: inputs,
                        defaultInputID: CA.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) ?? unknown,
                        inputVolumes: inputVolumes,
                        alertDeviceID: CA.defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice) ?? unknown,
                        apps: AudioDiscovery.apps())
    }

    // MARK: Taps (on queue)

    /// What applies to every route, not just one app's.
    struct Global {
        var effects = Effects()
        /// Software volume for outputs that have no volume control of their own (HDMI, DisplayPort), by device UID.
        var softVolumes: [String: Float] = [:]
        var softMuted: Set<String> = []

        func gain(for uid: String) -> Float { softMuted.contains(uid) ? 0 : softVolumes[uid] ?? 1 }
    }

    /// Brings taps in line with the settings. Returns the current per-app errors.
    func reconcile(apps: [AudioApp], settings: [String: AppSetting], global: Global, canCreateTaps: Bool) -> [String: String] {
        dispatchPrecondition(condition: .onQueue(queue))
        for app in apps { apply(app, settings[app.id] ?? AppSetting(), global, canCreateTaps: canCreateTaps) }

        let live = Set(apps.map(\.id) + [Self.systemID])
        for id in Array(taps.keys) where !live.contains(id) { taps[id] = nil; tapKeys[id] = nil }
        for id in Array(failed.keys) where !live.contains(id) { failed[id] = nil }
        for id in Array(errors.keys) where !live.contains(id) { errors[id] = nil }
        for id in Array(appParams.keys) where !live.contains(id) { appParams[id] = nil }
        applySystem(global, canCreateTaps: canCreateTaps)
        return errors
    }

    /// Fast path for slider drags: when the tap already exists this is just a gain write.
    func update(_ app: AudioApp, _ setting: AppSetting, global: Global, canCreateTaps: Bool) -> [String: String] {
        dispatchPrecondition(condition: .onQueue(queue))
        failed[app.id] = nil
        apply(app, setting, global, canCreateTaps: canCreateTaps)
        applySystem(global, canCreateTaps: canCreateTaps) // the system route leaves out apps with their own
        return errors
    }

    func remove(_ appID: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        taps[appID] = nil
        tapKeys[appID] = nil
        failed[appID] = nil
        errors[appID] = nil
        appParams[appID] = nil
    }

    func removeAll() {
        dispatchPrecondition(condition: .onQueue(queue))
        taps = [:]
        tapKeys = [:]
        lastRenderCounts = [:]
        failed = [:]
        errors = [:]
    }

    /// The Audio Unit loaded on a route (an app's, or `systemID`), for its editor window.
    func audioUnit(for id: String) -> AUAudioUnit? {
        dispatchPrecondition(condition: .onQueue(queue))
        return taps[id]?.chains.lazy.compactMap(\.audioUnit).first
    }

    func saveAudioUnitState(for id: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        taps[id]?.chains.forEach { $0.saveState() }
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

    private func apply(_ app: AudioApp, _ setting: AppSetting, _ global: Global, canCreateTaps: Bool) {
        guard let device = target(for: setting) else { return }
        let gain = (setting.muted ? 0 : setting.volume) * deviceGain(device, global)
        let params = appParams[app.id] ?? EffectParams()
        appParams[app.id] = params
        params.set(setting.effects)
        let key = TapKey(processObjectIDs: app.processObjectIDs, outputUID: device.uid, deviceID: device.objectID,
                         sampleRate: device.sampleRate, outputChannels: device.outputChannels,
                         audioUnit: setting.effects.activeAudioUnit, systemAudioUnit: global.effects.activeAudioUnit)

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
            // The app's own effects, then the system effects. One plug-in instance can't render for several routes at
            // once, so the route runs its own copy of the system Audio Unit, kept in step with the original.
            let systemState = taps[Self.systemID]?.chains.first?.audioUnit?.fullState
            let chains = [try EffectChain(params: params, sampleRate: device.sampleRate, audioUnit: key.audioUnit, stateKey: app.id),
                          try EffectChain(params: systemParams, sampleRate: device.sampleRate, audioUnit: key.systemAudioUnit,
                                          stateKey: Self.systemID, initialState: systemState, savesState: false)]
            taps[app.id] = try AppTap(source: .processes(key.processObjectIDs), outputDevice: device, gain: gain, chains: chains)
            tapKeys[app.id] = key
            lastRenderCounts[app.id] = nil
            errors[app.id] = nil
        } catch {
            failed[app.id] = key
            errors[app.id] = error.localizedDescription
        }
    }

    /// The system-wide route: every process without its own route, tapped together and played on the default output
    /// through the system effects. Only exists while system effects are on or a fixed-volume output is turned down.
    private func applySystem(_ global: Global, canCreateTaps: Bool) {
        let id = Self.systemID
        systemParams.set(global.effects)
        guard let device = devices.first(where: { $0.objectID == defaultDeviceID }) else { return }
        let gain = deviceGain(device, global)
        guard global.effects.isActive || gain != 1 else {
            taps[id] = nil
            tapKeys[id] = nil
            errors[id] = nil
            return
        }
        // Without AppMixer's own process in the exclusions the tap would capture its own output: a feedback loop.
        guard let own = CA.processObject(pid: getpid()) else {
            log.error("AppMixer's own audio process isn't known yet; not starting system-wide effects")
            return
        }
        let routed = tapKeys.filter { $0.key != id && taps[$0.key] != nil }.flatMap(\.value.processObjectIDs)
        let key = TapKey(processObjectIDs: Set([own] + routed + soundEffectProcesses).sorted(), outputUID: device.uid, deviceID: device.objectID,
                         sampleRate: device.sampleRate, outputChannels: device.outputChannels,
                         audioUnit: global.effects.activeAudioUnit)
        if let tap = taps[id], tapKeys[id] == key {
            tap.gain = gain
            return
        }
        guard canCreateTaps, failed[id] != key else { return }
        taps[id] = nil
        tapKeys[id] = nil
        do {
            let chain = try EffectChain(params: systemParams, sampleRate: device.sampleRate, audioUnit: key.audioUnit, stateKey: id)
            taps[id] = try AppTap(source: .allExcept(key.processObjectIDs), outputDevice: device, gain: gain, chains: [chain])
            tapKeys[id] = key
            observeSystemUnit(chain.audioUnit)
            lastRenderCounts[id] = nil
            errors[id] = nil
        } catch {
            failed[id] = key
            errors[id] = error.localizedDescription
        }
    }

    /// Keeps the copies of the system plug-in on app routes in step with the original while its editor is used.
    private func observeSystemUnit(_ unit: AUAudioUnit?) {
        if let old = systemUnitObserver { old.tree.removeParameterObserver(old.token) }
        systemUnitObserver = nil
        guard let tree = unit?.parameterTree else { return }
        let token = tree.token(byAddingParameterObserver: { [weak self] address, value in
            guard let self else { return }
            self.queue.async {
                for (id, tap) in self.taps where id != Self.systemID {
                    tap.chains.dropFirst().first?.audioUnit?.parameterTree?.parameter(withAddress: address)?.value = value
                }
            }
        })
        systemUnitObserver = (tree, token)
    }

    private func deviceGain(_ device: AudioDevice, _ global: Global) -> Float {
        fixedVolume.contains(device.uid) ? global.gain(for: device.uid) : 1
    }

    /// The chosen device if it's connected, otherwise the system default (the choice is kept for when it reconnects).
    private func target(for setting: AppSetting) -> AudioDevice? {
        if let uid = setting.deviceUID, let chosen = devices.first(where: { $0.uid == uid }) { return chosen }
        return devices.first { $0.objectID == defaultDeviceID }
    }
}
