import AudioToolbox
import CoreAudio
import Foundation

import os

let log = Logger(subsystem: "dev.appmixer.AppMixer", category: "audio")

struct CoreAudioError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        switch status {
        case OSStatus(kAudioHardwareIllegalOperationError), OSStatus(kAudioDevicePermissionsError):
            return "macOS denied access to this app's audio. Check AppMixer's audio recording permission."
        case OSStatus(kAudioHardwareBadObjectError), OSStatus(kAudioHardwareBadDeviceError):
            return "The app or output device went away while AppMixer was connecting to it."
        case OSStatus(kAudioHardwareNotRunningError):
            return "The macOS audio system isn't running."
        case OSStatus(kAudioDeviceUnsupportedFormatError):
            return "The output device uses an audio format AppMixer can't handle."
        case OSStatus(kAudioHardwareUnsupportedOperationError):
            return "This Mac doesn't support capturing this app's audio."
        default:
            return "\(operation) failed (\(Self.fourCC(status)))."
        }
    }

    /// Core Audio errors are usually four-character codes like 'nope' or '!obj'.
    static func fourCC(_ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "error \(status)" }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}

func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr {
        let error = CoreAudioError(operation: operation, status: status)
        log.error("\(operation, privacy: .public) failed: \(CoreAudioError.fourCC(status), privacy: .public)")
        throw error
    }
}

/// Thin wrappers over AudioObjectGetPropertyData.
enum CA {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         initial: T) -> T? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = initial
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? result : nil
    }

    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Calls `handler` on `queue` whenever a system-object property changes.
    static func observeSystem(_ selector: AudioObjectPropertySelector, queue: DispatchQueue,
                              _ handler: @escaping () -> Void) {
        var addr = address(selector)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue) { _, _ in handler() }
    }

    /// Calls `handler` on `queue` when a property of one object changes.
    static func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        queue: DispatchQueue, _ handler: @escaping () -> Void) {
        var addr = address(selector, scope: scope)
        AudioObjectAddPropertyListenerBlock(object, &addr, queue) { _, _ in handler() }
    }

    /// Total channels across a device's streams in one direction.
    static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        objectIDs(device, kAudioDevicePropertyStreams, scope: scope).count
    }

    /// The system's default device for a role: `kAudioHardwarePropertyDefaultOutputDevice`, `…DefaultInputDevice`
    /// or `…DefaultSystemOutputDevice` (sound effects).
    static func defaultDevice(_ role: AudioObjectPropertySelector) -> AudioObjectID? {
        value(AudioObjectID(kAudioObjectSystemObject), role, initial: AudioObjectID(kAudioObjectUnknown))
    }

    static func setDefaultDevice(_ role: AudioObjectPropertySelector, _ device: AudioObjectID) {
        var addr = address(role)
        var id = device
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }

    /// A Float32 property (volume, balance), or nil if the device doesn't have it.
    static func float(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope) -> Float? {
        var addr = address(selector, scope: scope)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        return value(device, selector, scope: scope, initial: Float32(0))
    }

    static func setFloat(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope, _ newValue: Float) {
        var addr = address(selector, scope: scope)
        var value = Float32(min(max(newValue.isFinite ? newValue : 0, 0), 1))
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    /// The device's main volume as shown in Control Center, or nil if the device has no software volume.
    static func deviceVolume(_ device: AudioObjectID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> Float? {
        float(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
    }

    static func setDeviceVolume(_ device: AudioObjectID, _ volume: Float,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) {
        setFloat(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, volume)
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        (value(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0)) ?? 0) != 0
    }

    /// Left/right balance from 0 (left) to 1 (right), or nil when the device can't change it.
    static func balance(_ device: AudioObjectID) -> Float? {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainBalance, scope: kAudioObjectPropertyScopeOutput)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &addr), AudioObjectIsPropertySettable(device, &addr, &settable) == noErr,
              settable.boolValue else { return nil }
        return float(device, kAudioHardwareServiceDeviceProperty_VirtualMainBalance, scope: kAudioObjectPropertyScopeOutput)
    }

    static func setBalance(_ device: AudioObjectID, _ balance: Float) {
        setFloat(device, kAudioHardwareServiceDeviceProperty_VirtualMainBalance, scope: kAudioObjectPropertyScopeOutput, balance)
    }

    /// The rates a device offers (ranges collapsed to their ends), lowest first.
    static func sampleRates(_ device: AudioObjectID) -> [Double] {
        var addr = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        return Set(ranges.flatMap { [$0.mMinimum, $0.mMaximum] }.filter { $0 > 0 }).sorted()
    }

    static func setSampleRate(_ device: AudioObjectID, _ rate: Double) {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(rate)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
    }

    /// The audio server's object for a process, used to keep AppMixer's own output out of the system-wide tap.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}