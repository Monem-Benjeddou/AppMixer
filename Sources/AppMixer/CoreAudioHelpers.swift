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

    static var defaultOutputDevice: AudioObjectID? {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
              initial: AudioObjectID(kAudioObjectUnknown))
    }

    static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        objectIDs(device, kAudioDevicePropertyStreams, scope: scope).count
    }

    static func setDefaultOutputDevice(_ device: AudioObjectID) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = device
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }

    /// The device's main volume as shown in Control Center, or nil if the device has no software volume.
    static func deviceVolume(_ device: AudioObjectID) -> Float? {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }

    static func setDeviceVolume(_ device: AudioObjectID, _ volume: Float) {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        var value = Float32(min(max(volume, 0), 1))
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}
