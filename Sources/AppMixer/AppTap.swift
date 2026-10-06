import CoreAudio
import Foundation

/// Captures one app's audio with a Core Audio process tap (which silences the app's normal output),
/// applies gain, and plays it on the chosen output device through a private aggregate device.
/// Private taps and aggregates belong to this process, so if AppMixer quits or crashes the app's audio returns to normal.
final class AppTap {
    let processObjectIDs: [AudioObjectID]
    let outputUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// [0] = target gain (written by the UI), [1] = gain at the end of the last render (written by the IO thread).
    private let gainState = UnsafeMutablePointer<Float>.allocate(capacity: 2)
    /// Render callbacks so far, counted on the IO thread. If it stops moving, the route is dead
    /// (e.g. the output device went away mid-stream) and the tap is rebuilt.
    private let renderCounter = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    var renderCount: UInt64 { renderCounter.pointee }
    let createdAt = Date()

    var gain: Float {
        get { gainState[0] }
        set { gainState[0] = newValue.isFinite ? max(0, newValue) : 1 } // never NaN into the audio thread
    }

    init(processObjectIDs: [AudioObjectID], outputDevice: OutputDevice, gain: Float) throws {
        self.processObjectIDs = processObjectIDs
        self.outputUID = outputDevice.uid
        let gain = gain.isFinite ? max(0, gain) : 1
        gainState[0] = gain
        gainState[1] = gain
        renderCounter.pointee = 0
        do {
            try start(outputDevice: outputDevice)
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
        gainState.deallocate()
        renderCounter.deallocate()
    }

    private func start(outputDevice: OutputDevice) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "AppMixer tap"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating process tap")

        // The render callback assumes 32-bit float samples; refuse anything else rather than play noise.
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = CA.address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &format), "Reading tap format")
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            throw CoreAudioError(operation: "Reading tap format", status: OSStatus(kAudioDeviceUnsupportedFormatError))
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppMixer output",
            kAudioAggregateDeviceUIDKey: "AppMixer-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDevice.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDevice.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating aggregate device")

        // The aggregate's input buffers list the output device's own input streams (e.g. a headset mic) first, then the tap.
        let tapBufferIndex = CA.streamCount(outputDevice.objectID, scope: kAudioObjectPropertyScopeInput)
        let state = gainState
        let counter = renderCounter
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            counter.pointee &+= 1
            AppTap.render(input: input, output: output, tapBufferIndex: tapBufferIndex, gain: state)
        }, "Creating IO proc")
        try check(AudioDeviceStart(aggregateID, ioProcID), "Starting audio device")
    }

    private func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Runs on the real-time IO thread: no allocation, no locks.
    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                               tapBufferIndex: Int, gain: UnsafeMutablePointer<Float>) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }

        let target = gain[0]
        let startGain = gain[1]
        gain[1] = target

        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard ins.count > 0, outs.count > 0 else { return }
        let src = ins[min(tapBufferIndex, ins.count - 1)]
        let dst = outs[0]
        guard let srcSamples = src.mData?.assumingMemoryBound(to: Float.self),
              let dstSamples = dst.mData?.assumingMemoryBound(to: Float.self) else { return }

        let inChannels = max(Int(src.mNumberChannels), 1)
        let outChannels = max(Int(dst.mNumberChannels), 1)
        let frames = min(Int(src.mDataByteSize) / (4 * inChannels), Int(dst.mDataByteSize) / (4 * outChannels))
        guard frames > 0 else { return }

        // Ramp across the buffer so slider moves and mute toggles don't click.
        let step = (target - startGain) / Float(frames)
        var g = startGain
        for frame in 0..<frames {
            g += step
            let inBase = frame * inChannels
            let outBase = frame * outChannels
            for channel in 0..<min(outChannels, max(inChannels, 2)) {
                let sample = srcSamples[inBase + min(channel, inChannels - 1)] * g
                dstSamples[outBase + channel] = min(1, max(-1, sample))
            }
        }
    }
}
