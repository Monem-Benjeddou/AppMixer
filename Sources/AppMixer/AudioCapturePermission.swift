import Foundation

/// The "System Audio Recording" permission that process taps need.
///
/// There's no public API to query it, so this uses the TCC SPI (as other audio-tap apps do), which lets us check
/// without prompting. Without that check, every tap attempt while undetermined or denied shows a system prompt.
enum AudioCapturePermission {
    enum Status { case unknown, granted, denied }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let preflightFn: PreflightFn? = tcc.flatMap { dlsym($0, "TCCAccessPreflight") }
        .map { unsafeBitCast($0, to: PreflightFn.self) }
    private static let requestFn: RequestFn? = tcc.flatMap { dlsym($0, "TCCAccessRequest") }
        .map { unsafeBitCast($0, to: RequestFn.self) }

    /// Never shows a prompt.
    static var status: Status {
        guard let preflightFn else { return .unknown }
        switch preflightFn(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt (only if the user hasn't decided yet) and reports the answer on the main queue.
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let requestFn else {
            completion(true) // SPI unavailable: let tap creation trigger the prompt itself
            return
        }
        requestFn(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
