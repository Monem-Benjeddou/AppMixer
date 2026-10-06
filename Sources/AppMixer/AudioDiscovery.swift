import AppKit
import CoreAudio

struct OutputDevice: Identifiable, Hashable {
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    /// Format details that change when, say, Bluetooth earbuds switch to call mode (16 kHz mono)
    /// for a voice call. Routing is rebuilt when they change.
    var sampleRate: Double = 0
    var outputChannels: Int = 0
    var id: String { uid }

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return name.localizedCaseInsensitiveContains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return name.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform.path"
        default: return "hifispeaker"
        }
    }

    var kind: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        default: return "Audio device"
        }
    }
}

/// A user-facing app plus every Core Audio process (helpers, WebKit GPU process, …) that plays on its behalf.
struct AudioApp: Identifiable, Equatable, @unchecked Sendable { // NSImage is immutable once loaded
    let id: String          // bundle identifier of the responsible app
    let name: String
    let icon: NSImage?
    var processObjectIDs: [AudioObjectID]
    var isPlaying: Bool

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
            && lhs.processObjectIDs == rhs.processObjectIDs && lhs.isPlaying == rhs.isPlaying
    }
}

enum AudioDiscovery {
    static func outputDevices() -> [OutputDevice] {
        CA.objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { id in
            guard CA.streamCount(id, scope: kAudioObjectPropertyScopeOutput) > 0,
                  let uid = CA.string(id, kAudioDevicePropertyDeviceUID),
                  let name = CA.string(id, kAudioObjectPropertyName) else { return nil }
            let transport = CA.value(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
            return OutputDevice(objectID: id, uid: uid, name: name, transport: transport,
                                sampleRate: CA.value(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0,
                                outputChannels: CA.channelCount(id, scope: kAudioObjectPropertyScopeOutput))
        }
    }

    static func apps() -> [AudioApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var byBundle: [String: AudioApp] = [:]

        for process in CA.objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            guard let pid = CA.value(process, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0, pid != ownPID,
                  let app = owningApp(of: pid), let bundleID = app.bundleIdentifier,
                  app.processIdentifier != ownPID else { continue }

            let playing = (CA.value(process, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            if var existing = byBundle[bundleID] {
                existing.processObjectIDs.append(process)
                existing.isPlaying = existing.isPlaying || playing
                byBundle[bundleID] = existing
            } else {
                byBundle[bundleID] = AudioApp(id: bundleID, name: app.localizedName ?? bundleID, icon: app.icon,
                                              processObjectIDs: [process], isPlaying: playing)
            }
        }

        return byBundle.values
            .map { var a = $0; a.processObjectIDs.sort(); return a }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
    }

    /// Maps a helper process (e.g. "Google Chrome Helper", WebKit GPU process) to the regular app responsible for it.
    private static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
        if let responsible = responsiblePID(pid), responsible != pid,
           let app = NSRunningApplication(processIdentifier: responsible), app.activationPolicy == .regular {
            return app
        }
        // Fall back to bundle-ID prefix matching: com.foo.App.helper -> com.foo.App
        guard let helperID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && ($0.bundleIdentifier.map { helperID.hasPrefix($0 + ".") } ?? false)
        }
    }

    private typealias ResponsibilityFn = @convention(c) (pid_t) -> pid_t
    private static let responsibilityFn: ResponsibilityFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibilityFn.self)
    }()

    private static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let fn = responsibilityFn else { return nil }
        let result = fn(pid)
        return result > 0 ? result : nil
    }
}
