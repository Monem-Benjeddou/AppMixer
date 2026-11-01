import AVFoundation
import AudioToolbox
import Foundation

/// An installed Audio Unit effect, saved by its component identity.
struct AudioUnitRef: Codable, Hashable {
    let type: UInt32
    let subType: UInt32
    let manufacturer: UInt32
    let name: String

    init(_ component: AVAudioUnitComponent) {
        let d = component.audioComponentDescription
        type = d.componentType
        subType = d.componentSubType
        manufacturer = d.componentManufacturer
        name = component.name
    }

    var componentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subType, componentManufacturer: manufacturer,
                                  componentFlags: 0, componentFlagsMask: 0)
    }

    /// Installed effects, grouped by maker in the menus.
    static func installed() -> [AVAudioUnitComponent] {
        [kAudioUnitType_Effect, kAudioUnitType_MusicEffect].flatMap { type in
            AVAudioUnitComponentManager.shared().components(matching: AudioComponentDescription(
                componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0))
        }
    }
}

/// One app's (or the whole system's) effect settings.
struct Effects: Codable, Equatable {
    static let bands: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let maxGain: Float = 12

    /// Off keeps the settings but bypasses them.
    var enabled = true
    /// Gain in dB for each of `bands`.
    var eq = [Float](repeating: 0, count: bands.count)
    var boost = false
    var audioUnit: AudioUnitRef?

    var isEQFlat: Bool { eq.allSatisfy { $0 == 0 } }
    var isActive: Bool { enabled && (boost || audioUnit != nil || !isEQFlat) }
    /// The Audio Unit in use; part of a route's identity, since loading one means rebuilding the route.
    var activeAudioUnit: AudioUnitRef? { enabled ? audioUnit : nil }

    init() {}

    // Older saves (and future ones with extra keys) still decode instead of discarding every setting.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        let saved = try c.decodeIfPresent([Float].self, forKey: .eq) ?? []
        eq = Self.bands.indices.map { $0 < saved.count && saved[$0].isFinite ? min(max(saved[$0], -Self.maxGain), Self.maxGain) : 0 }
        boost = try c.decodeIfPresent(Bool.self, forKey: .boost) ?? false
        audioUnit = try c.decodeIfPresent(AudioUnitRef.self, forKey: .audioUnit)
    }

    static let presets: [(name: String, eq: [Float])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Bass Cut", [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        ("Treble Boost", [0, 0, 0, 0, 0, 0, 2, 4, 5, 6]),
        ("Vocals", [-2, -2, -1, 0, 2, 4, 4, 2, 0, -1]),
        ("Podcast", [-6, -4, -1, 0, 2, 3, 3, 1, -1, -3]),
        ("Loudness", [5, 4, 2, 0, -1, 0, 0, 1, 3, 4]),
        ("Laptop Speakers", [-6, -3, 2, 4, 3, 0, 0, 1, 2, 2]),
    ]
}

/// Effect settings shared with the audio thread: written on the engine queue, read once per buffer.
/// Plain float stores, so a buffer rendered mid-update sees a mix of old and new band gains at worst.
final class EffectParams {
    static let count = Effects.bands.count + 1 // band gains, then boost (0 or 1)
    let values = UnsafeMutablePointer<Float>.allocate(capacity: count)

    init() { values.initialize(repeating: 0, count: Self.count) }
    deinit { values.deallocate() }

    func set(_ effects: Effects) {
        for band in Effects.bands.indices { values[band] = effects.enabled ? effects.eq[band] : 0 }
        values[Effects.bands.count] = effects.enabled && effects.boost ? 1 : 0
    }
}

/// EQ, Magic Boost and an optional Audio Unit, applied to interleaved stereo in place on the IO thread.
/// Everything the IO thread touches is allocated up front: no allocation or locks while rendering.
final class EffectChain {
    /// Frames processed per call; callers split longer buffers.
    static let maxFrames = 512
    private static let bandCount = Effects.bands.count
    // Layout of `state`: last-used band gains, then 5 coefficients per band, then 2 channels × 2 filter memories per band,
    // then the boost envelope and gain.
    private static let coefOffset = bandCount
    private static let memOffset = coefOffset + bandCount * 5
    private static let envOffset = memOffset + bandCount * 4
    private static let stateCount = envOffset + 2

    let params: EffectParams
    private let sampleRate: Float
    private let state = UnsafeMutablePointer<Float>.allocate(capacity: stateCount)
    private let boostAttack: Float
    private let boostRelease: Float
    private let envelopeRelease: Float

    /// The loaded Audio Unit, for its editor window.
    let audioUnit: AUAudioUnit?
    private let stateKey: String?
    private let savesState: Bool
    private var renderBlock: AURenderBlock?
    private var pullInput: AURenderPullInputBlock?
    private let auIn = UnsafeMutablePointer<Float>.allocate(capacity: 2 * maxFrames)
    private let auOut = UnsafeMutablePointer<Float>.allocate(capacity: 2 * maxFrames)
    private let outList = AudioBufferList.allocate(maximumBuffers: 2)
    private let timestamp = UnsafeMutablePointer<AudioTimeStamp>.allocate(capacity: 1)
    private let pullFrames = UnsafeMutablePointer<Int>.allocate(capacity: 1)

    /// `stateKey` names where the Audio Unit's own settings are kept between routes and launches. A copy of another
    /// route's plug-in starts from `initialState` (that plug-in's current settings) and doesn't save its own (`savesState`).
    init(params: EffectParams, sampleRate: Double, audioUnit ref: AudioUnitRef? = nil, stateKey: String? = nil,
         initialState: [String: Any]? = nil, savesState: Bool = true) throws {
        self.params = params
        self.sampleRate = Float(sampleRate > 0 ? sampleRate : 48000)
        self.stateKey = stateKey
        self.savesState = savesState
        let fs = self.sampleRate
        boostAttack = 1 - exp(-1 / (0.005 * fs))  // gain comes down within ~5 ms of a loud passage
        boostRelease = 1 - exp(-1 / (0.6 * fs))   // and rises back over ~0.6 s, slow enough not to pump
        envelopeRelease = exp(-1 / (0.25 * fs))
        state.initialize(repeating: 0, count: Self.stateCount)
        for band in 0..<Self.bandCount { state[band] = .nan } // forces coefficients on the first buffer
        state[Self.envOffset + 1] = 1
        auIn.initialize(repeating: 0, count: 2 * Self.maxFrames)
        auOut.initialize(repeating: 0, count: 2 * Self.maxFrames)
        timestamp.initialize(to: AudioTimeStamp())
        timestamp.pointee.mFlags = .sampleTimeValid
        pullFrames.initialize(to: 0)

        guard let ref else {
            audioUnit = nil
            return
        }
        do {
            let unit = try Self.instantiate(ref)
            unit.maximumFramesToRender = AUAudioFrameCount(Self.maxFrames)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(fs), channels: 2) else {
                throw CoreAudioError(operation: "Loading \(ref.name)", status: OSStatus(kAudioUnitErr_FormatNotSupported))
            }
            if unit.inputBusses.count > 0 {
                try unit.inputBusses[0].setFormat(format)
                unit.inputBusses[0].isEnabled = true // a disabled input renders as "no connection"
            }
            try unit.outputBusses[0].setFormat(format)
            unit.outputBusses[0].isEnabled = true
            if let saved = initialState ?? stateKey.flatMap({ Self.loadState($0, ref) }) { unit.fullState = saved }
            try unit.allocateRenderResources()
            audioUnit = unit
        } catch {
            log.error("Loading Audio Unit \(ref.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw CoreAudioError(operation: "Loading \(ref.name)", status: OSStatus((error as NSError).code))
        }
        renderBlock = audioUnit?.renderBlock
        let input = auIn, frames = pullFrames, maxFrames = Self.maxFrames
        pullInput = { _, _, _, _, list in
            for (channel, buffer) in UnsafeMutableAudioBufferListPointer(list).prefix(2).enumerated() {
                let source = input + channel * maxFrames
                if let data = buffer.mData {
                    memcpy(data, source, frames.pointee * 4)
                } else {
                    UnsafeMutableAudioBufferListPointer(list)[channel].mData = UnsafeMutableRawPointer(source)
                }
                UnsafeMutableAudioBufferListPointer(list)[channel].mDataByteSize = UInt32(frames.pointee * 4)
            }
            return noErr
        }
    }

    deinit {
        if savesState, let audioUnit, let stateKey { Self.saveState(audioUnit, stateKey) }
        audioUnit?.deallocateRenderResources()
        state.deallocate()
        auIn.deallocate()
        auOut.deallocate()
        free(outList.unsafeMutablePointer)
        timestamp.deallocate()
        pullFrames.deallocate()
    }

    /// Runs on the IO thread. `samples` is interleaved stereo, at most `maxFrames` frames.
    func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        let p = params.values
        let nyquistGuard = sampleRate * 0.45
        for band in 0..<Self.bandCount {
            let gain = p[band]
            if gain != state[band] { design(band, gain: gain) }
            guard gain != 0, Effects.bands[band] < nyquistGuard else { continue }
            filter(band, samples, frames)
        }
        if p[Self.bandCount] > 0.5 { boost(samples, frames) }
        if let renderBlock, let pullInput { runAudioUnit(renderBlock, pullInput, samples, frames) }
    }

    private func design(_ band: Int, gain: Float) {
        let wasOff = state[band] == 0 || state[band].isNaN
        state[band] = gain
        let k = Self.coefficients(gain: gain, frequency: Effects.bands[band], sampleRate: sampleRate)
        let c = state + Self.coefOffset + band * 5
        (c[0], c[1], c[2], c[3], c[4]) = (k.b0, k.b1, k.b2, k.a1, k.a2)
        if wasOff { (state + Self.memOffset + band * 4).update(repeating: 0, count: 4) }
    }

    /// RBJ peaking filter for one band, normalized. Gains are clamped, so a stray value can't make an unstable filter.
    static func coefficients(gain: Float, frequency: Float, sampleRate: Float)
        -> (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        let g = gain.isFinite ? min(max(gain, -Effects.maxGain), Effects.maxGain) : 0
        let a = pow(10, g / 40)
        let w0 = 2 * Float.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * 1.4) // Q 1.4: about one octave, so neighbouring bands blend smoothly
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        return ((1 + alpha * a) / a0, -2 * cosw / a0, (1 - alpha * a) / a0, -2 * cosw / a0, (1 - alpha / a) / a0)
    }

    /// The EQ's combined gain in dB at a frequency, from the same filters the audio runs through (for the EQ graph).
    static func response(_ gains: [Float], at frequency: Float, sampleRate: Float = 48000) -> Float {
        let w = 2 * Float.pi * frequency / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        var total: Float = 0
        for (band, gain) in zip(Effects.bands, gains) where gain != 0 && band < sampleRate * 0.45 {
            let k = coefficients(gain: gain, frequency: band, sampleRate: sampleRate)
            let numRe = k.b0 + k.b1 * c1 + k.b2 * c2, numIm = -(k.b1 * s1 + k.b2 * s2)
            let denRe = 1 + k.a1 * c1 + k.a2 * c2, denIm = -(k.a1 * s1 + k.a2 * s2)
            total += 10 * log10((numRe * numRe + numIm * numIm) / max(denRe * denRe + denIm * denIm, 1e-12))
        }
        return total
    }

    private func filter(_ band: Int, _ x: UnsafeMutablePointer<Float>, _ frames: Int) {
        let c = state + Self.coefOffset + band * 5
        let (b0, b1, b2, a1, a2) = (c[0], c[1], c[2], c[3], c[4])
        for channel in 0..<2 {
            let m = state + Self.memOffset + band * 4 + channel * 2
            var z1 = m[0], z2 = m[1]
            var i = channel
            for _ in 0..<frames {
                let input = x[i]
                let output = b0 * input + z1
                z1 = b1 * input - a1 * output + z2
                z2 = b2 * input - a2 * output
                x[i] = output
                i += 2
            }
            // A blown-up filter (bad input) would stay silent or screaming forever; start it fresh instead.
            if z1.isFinite && z2.isFinite { m[0] = z1; m[1] = z2 } else { m[0] = 0; m[1] = 0 }
        }
    }

    /// Magic Boost: raises quiet passages by up to 12 dB and leaves anything already loud alone.
    private func boost(_ x: UnsafeMutablePointer<Float>, _ frames: Int) {
        let threshold: Float = 0.3 // about -10 dBFS: peaks above this get no boost
        let maxBoost: Float = 4
        var envelope = state[Self.envOffset]
        var gain = state[Self.envOffset + 1]
        for frame in 0..<frames {
            let peak = max(abs(x[2 * frame]), abs(x[2 * frame + 1]))
            envelope = peak > envelope ? peak : envelope * envelopeRelease
            // Below -80 dB is silence or noise floor: hold the gain rather than boosting hiss.
            if envelope > 0.0001 {
                let target = min(maxBoost, max(1, threshold / envelope))
                gain += (target - gain) * (target < gain ? boostAttack : boostRelease)
            }
            x[2 * frame] *= gain
            x[2 * frame + 1] *= gain
        }
        state[Self.envOffset] = envelope.isFinite ? envelope : 0
        state[Self.envOffset + 1] = gain.isFinite ? gain : 1
    }

    private func runAudioUnit(_ render: AURenderBlock, _ pull: @escaping AURenderPullInputBlock,
                              _ x: UnsafeMutablePointer<Float>, _ frames: Int) {
        for frame in 0..<frames {
            auIn[frame] = x[2 * frame]
            auIn[Self.maxFrames + frame] = x[2 * frame + 1]
        }
        pullFrames.pointee = frames
        let out = outList
        for channel in 0..<2 {
            out[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                                       mData: UnsafeMutableRawPointer(auOut + channel * Self.maxFrames))
        }
        var flags = AudioUnitRenderActionFlags()
        let status = render(&flags, timestamp, AUAudioFrameCount(frames), 0, outList.unsafeMutablePointer, pull)
        timestamp.pointee.mSampleTime += Double(frames)
        guard status == noErr else { return } // a failing effect is skipped, not allowed to silence the audio
        for channel in 0..<min(out.count, 2) {
            guard let data = out[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<frames { x[2 * frame + channel] = data[frame] }
        }
    }

    // MARK: Audio Unit loading and saved state (engine queue)

    private static func instantiate(_ ref: AudioUnitRef) throws -> AUAudioUnit {
        var result: AUAudioUnit?
        var failure: Error?
        let done = DispatchSemaphore(value: 0)
        AUAudioUnit.instantiate(with: ref.componentDescription, options: [.loadOutOfProcess]) { unit, error in
            result = unit
            failure = error
            done.signal()
        }
        // A plug-in that never answers mustn't stall the audio queue.
        guard done.wait(timeout: .now() + 5) == .success else {
            throw CoreAudioError(operation: "Loading \(ref.name)", status: OSStatus(kAudioUnitErr_FailedInitialization))
        }
        if let result { return result }
        throw failure ?? CoreAudioError(operation: "Loading \(ref.name)", status: OSStatus(kAudioUnitErr_FailedInitialization))
    }

    private static func defaultsKey(_ stateKey: String, _ ref: AudioUnitRef) -> String {
        "audioUnitState.\(stateKey).\(ref.type).\(ref.subType).\(ref.manufacturer)"
    }

    private static func loadState(_ stateKey: String, _ ref: AudioUnitRef) -> [String: Any]? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(stateKey, ref)) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Keeps whatever was set in the plug-in's own editor. Serialized first: a non-plist value
    /// would make UserDefaults throw.
    func saveState() {
        if savesState, let audioUnit, let stateKey { Self.saveState(audioUnit, stateKey) }
    }

    private static func saveState(_ unit: AUAudioUnit, _ stateKey: String) {
        let d = unit.componentDescription
        let ref = AudioUnitRef(type: d.componentType, subType: d.componentSubType, manufacturer: d.componentManufacturer, name: "")
        guard let state = unit.fullState,
              let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey(stateKey, ref))
    }

    // MARK: Self-test

    /// `AppMixer --dsp-self-test`: checks the DSP on synthetic audio and exits. Run in CI.
    static func selfTest() -> Bool {
        func run(_ effects: Effects, amplitude: Float, frequency: Float = 1000) -> (peak: Float, finite: Bool) {
            let params = EffectParams()
            params.set(effects)
            guard let chain = try? EffectChain(params: params, sampleRate: 48000) else { return (0, false) }
            var peak: Float = 0
            var finite = true
            var buffer = [Float](repeating: 0, count: 2 * maxFrames)
            var t = 0
            for round in 0..<200 { // ~2 s, long enough for the boost to settle
                for frame in 0..<maxFrames {
                    let s = amplitude * sin(2 * .pi * frequency * Float(t) / 48000)
                    buffer[2 * frame] = s
                    buffer[2 * frame + 1] = s
                    t += 1
                }
                buffer.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, frames: maxFrames) }
                finite = finite && buffer.allSatisfy(\.isFinite)
                if round > 150 { peak = max(peak, buffer.map(abs).max() ?? 0) }
            }
            return (peak, finite)
        }
        var checks: [(String, Bool)] = []
        let flat = run(Effects(), amplitude: 0.5)
        checks.append(("flat EQ leaves audio unchanged", flat.finite && abs(flat.peak - 0.5) < 0.001))
        var bass = Effects()
        bass.eq[0] = 12
        let lowTone = run(bass, amplitude: 0.1, frequency: 32)
        checks.append(("+12 dB at 32 Hz boosts a 32 Hz tone about 4x", lowTone.finite && lowTone.peak > 0.35 && lowTone.peak < 0.45))
        let highTone = run(bass, amplitude: 0.1, frequency: 8000)
        let highFlat = run(Effects(), amplitude: 0.1, frequency: 8000) // compared with itself: samples miss the true peak
        checks.append(("+12 dB at 32 Hz leaves 8 kHz alone", abs(highTone.peak - highFlat.peak) < 0.005))
        var boost = Effects()
        boost.boost = true
        let quiet = run(boost, amplitude: 0.05)
        checks.append(("Magic Boost raises quiet audio", quiet.finite && quiet.peak > 0.15))
        let loud = run(boost, amplitude: 0.8)
        checks.append(("Magic Boost leaves loud audio alone", loud.finite && abs(loud.peak - 0.8) < 0.01))
        var extreme = Effects()
        extreme.eq = Effects.bands.map { _ in Effects.maxGain }
        extreme.boost = true
        checks.append(("everything at maximum stays finite", run(extreme, amplitude: 1).finite))

        // A real plug-in (AUDelay ships with macOS) through the same render path the routes use.
        let delayRef = AudioUnitRef(type: kAudioUnitType_Effect, subType: 0x64656C79, manufacturer: kAudioUnitManufacturer_Apple, name: "AUDelay")
        if let chain = try? EffectChain(params: EffectParams(), sampleRate: 48000, audioUnit: delayRef) {
            var buffer = [Float](repeating: 0, count: 2 * maxFrames)
            var dry: Float = 0, echo: Float = 0
            for round in 0..<120 { // AUDelay's default echo comes back after 1 s, ~94 buffers
                for i in buffer.indices { buffer[i] = round == 0 && i < 64 ? 0.5 : 0 } // a click, then silence
                buffer.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, frames: maxFrames) }
                let energy = buffer.reduce(0) { $0 + $1 * $1 }
                if round == 0 { dry = energy } else { echo += energy }
            }
            checks.append(("an Audio Unit (AUDelay) processes audio", dry.isFinite && echo.isFinite && dry > 0 && echo > 0))
        } else {
            checks.append(("an Audio Unit (AUDelay) loads", false))
        }
        let graph = response(bass.eq, at: 32)
        checks.append(("EQ graph shows the filter's real gain", abs(graph - 12) < 0.1 && abs(response(bass.eq, at: 8000)) < 0.1))
        for (name, passed) in checks { print(passed ? "PASS" : "FAIL", name) }
        return checks.allSatisfy(\.1)
    }
}

private extension AudioUnitRef {
    init(type: UInt32, subType: UInt32, manufacturer: UInt32, name: String) {
        self.type = type
        self.subType = subType
        self.manufacturer = manufacturer
        self.name = name
    }
}
