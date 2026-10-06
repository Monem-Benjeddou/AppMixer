import AppKit
import os

/// Keeps the app running through the failures code can't catch: crashes (Swift runtime traps,
/// memory errors, uncaught Objective-C exceptions) and hangs.
///
/// - A crash is recorded, and the app reopens itself once the crashed process is gone.
/// - A main thread stuck for 45 seconds counts as a crash: recorded, then the app restarts.
/// - Crashing again within two minutes of launch, twice in a row, starts the app in safe mode,
///   where it leaves its riskiest work off until you turn it back on. A third quick crash stops
///   the reopening, so a crash loop can't run forever.
///
/// Identical in AppMixer, ClipStash and SnapStash; each app decides what safe mode turns off.
enum Stability {
    struct Crash {
        /// In plain words, e.g. "a memory error" or "a hang".
        let reason: String
        /// Seconds the crashed session had been running.
        let uptime: Int
        let wasHang: Bool

        /// One sentence for the person using the app.
        var message: String {
            wasHang ? "\(Stability.appName) stopped responding, so it was restarted"
                    : "\(Stability.appName) quit unexpectedly and was reopened"
        }
    }

    /// What ended the previous session, if it didn't end normally.
    private(set) static var previousCrash: Crash?
    /// Set after two quick crashes in a row.
    private(set) static var safeMode = false

    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app", category: "stability")
    private static let streakKey = "stability.quickCrashStreak"
    /// A crash this soon after launch counts toward safe mode.
    private static let quickCrashSeconds = 120
    private static var started = false

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? appName, isDirectory: true)
    }
    private static var crashFile: URL { directory.appendingPathComponent("last-crash") }
    private static var exceptionFile: URL { directory.appendingPathComponent("last-exception") }

    /// Call first thing at launch, before any app state is created.
    static func start() {
        guard !started, Bundle.main.bundleIdentifier != nil else { return }
        started = true
        handOverToRunningCopy()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        readPreviousSession()

        if isDebuggerAttached {
            log.notice("Debugger attached: crash and hang interception off")
            return
        }
        installCrashHandlers()
        Watchdog.shared.start()
        runSelfTestIfRequested()

        // Two quiet minutes: this launch is stable, so a later crash starts the count again.
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(quickCrashSeconds)) {
            UserDefaults.standard.set(0, forKey: streakKey)
            crashRelaunchEnabled = 1
        }
    }

    /// Two copies (say, one in Applications and one in Downloads) would fight over shortcuts, audio
    /// taps or the history file. If one is already running, bring it forward and quit before this
    /// copy creates any state. Runs before AppKit is up, hence `open` rather than NSWorkspace.
    private static func handOverToRunningCopy() {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }),
              let url = other.bundleURL else { return }
        log.notice("Already running (pid \(other.processIdentifier)); handing over")
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [url.path] // the running copy gets a "reopen" and shows its window
        try? open.run()
        open.waitUntilExit()
        exit(EXIT_SUCCESS)
    }

    /// Leaves safe mode for this session (the app turns its features back on).
    static func leaveSafeMode() {
        safeMode = false
        UserDefaults.standard.set(0, forKey: streakKey)
    }

    /// Test aid: `open App.app --args -stabilityTest crash` (or `exception`, `hang`) fails on purpose
    /// three seconds after launch, to check that the app records it and comes back.
    private static func runSelfTestIfRequested() {
        guard let test = UserDefaults.standard.string(forKey: "stabilityTest") else { return }
        log.notice("Stability self-test: \(test, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            switch test {
            case "crash":
                let empty: [Int] = []
                _ = empty[Int(getpid() % 2) + 1] // out of range: a Swift runtime trap
            case "exception":
                NSException(name: .genericException, reason: "Stability self-test", userInfo: nil).raise()
            case "hang":
                while true { sleep(1) }
            default:
                break
            }
        }
    }

    // MARK: Previous session

    private static func readPreviousSession() {
        let defaults = UserDefaults.standard
        var streak = defaults.integer(forKey: streakKey)
        defer {
            try? FileManager.default.removeItem(at: crashFile)
            try? FileManager.default.removeItem(at: exceptionFile)
        }
        guard let record = try? String(contentsOf: crashFile, encoding: .utf8) else {
            defaults.set(0, forKey: streakKey) // ended normally (or was force-quit, which isn't a crash)
            return
        }
        // "signal <number> <uptime>" from the crash handler, or "hang 0 <uptime>" from the watchdog.
        let parts = record.split(separator: " ").map(String.init)
        let kind = parts.first ?? "signal"
        let code = parts.count > 1 ? Int32(parts[1]) ?? 0 : 0
        let uptime = parts.count > 2 ? Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
        var reason = kind == "hang" ? "a hang" : describe(signal: code)
        if let exception = try? String(contentsOf: exceptionFile, encoding: .utf8), !exception.isEmpty {
            reason = "an internal error (\(exception.prefix(200)))"
        }
        previousCrash = Crash(reason: reason, uptime: uptime, wasHang: kind == "hang")
        streak = uptime < quickCrashSeconds ? streak + 1 : 0
        defaults.set(streak, forKey: streakKey)
        safeMode = streak >= 2
        // A crash in safe mode, soon after launch, isn't reopened again.
        crashRelaunchEnabled = streak >= 2 ? 0 : 1
        log.error("Previous session ended with \(reason, privacy: .public) after \(uptime)s; quick-crash streak \(streak)")
    }

    private static func describe(signal: Int32) -> String {
        switch signal {
        case SIGSEGV, SIGBUS: return "a memory error"
        case SIGTRAP, SIGILL: return "an internal error"
        case SIGABRT: return "an internal error"
        case SIGFPE: return "a calculation error"
        default: return "an unexpected error"
        }
    }

    // MARK: Crash handling

    private static func installCrashHandlers() {
        crashFilePath = strdup(crashFile.path)
        exceptionFilePath = exceptionFile.path
        numberBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 24)
        launchTime = time(nil)
        relaunchArgv = makeRelaunchArgv()
        // Its own session, so the helper isn't cleaned up along with the crashed app's process group.
        relaunchAttributes = UnsafeMutablePointer<posix_spawnattr_t?>.allocate(capacity: 1)
        relaunchAttributes?.initialize(to: nil)
        posix_spawnattr_init(relaunchAttributes)
        posix_spawnattr_setflags(relaunchAttributes, Int16(POSIX_SPAWN_SETSID))
        relaunchEnvironment = makeCStringArray(ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" })

        installExceptionHandler()

        // An alternate stack, so even a stack overflow on the main thread can be handled.
        let stackSize = 64 * 1024
        var stack = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: stackSize, alignment: 16),
                            ss_size: stackSize, ss_flags: 0)
        sigaltstack(&stack, nil)

        for signal in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = crashSignalHandler
            action.sa_flags = SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
    }

    /// Uncaught Objective-C exceptions: keeps the reason (the abort that follows is handled by the
    /// signal handler), then passes the exception on to whichever handler was there before.
    private static func installExceptionHandler() {
        let current = NSGetUncaughtExceptionHandler()
        let address = { (handler: (@convention(c) (NSException) -> Void)?) in unsafeBitCast(handler, to: UnsafeRawPointer?.self) }
        if current != nil, address(current) == address(exceptionHandlerPointer) { return }
        previousExceptionHandler = current
        NSSetUncaughtExceptionHandler { exception in
            let text = "\(exception.name.rawValue): \(exception.reason ?? "no reason")"
            try? text.write(toFile: exceptionFilePath, atomically: false, encoding: .utf8)
            previousExceptionHandler?(exception)
        }
        exceptionHandlerPointer = NSGetUncaughtExceptionHandler()
    }

    /// Call from applicationDidFinishLaunching: AppKit installs its own exception handler while
    /// launching, so ours goes back on top (and still calls AppKit's).
    static func didFinishLaunching() {
        guard started, crashFilePath != nil else { return }
        installExceptionHandler()
    }

    /// `/bin/sh -c '<wait for this process to exit>; open <app>'`, prepared up front because a
    /// signal handler may not allocate.
    private static func makeRelaunchArgv() -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        makeCStringArray(["/bin/sh", "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                          Bundle.main.bundlePath, String(getpid())])
    }

    /// A NULL-terminated C string array that lives for the rest of the process.
    private static func makeCStringArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { array[index] = strdup(string) }
        array[strings.count] = nil
        return array
    }

    /// The main thread has been stuck for a long time: record it as a crash and restart.
    fileprivate static func recoverFromHang(seconds: TimeInterval) {
        let uptime = Int(time(nil) - launchTime)
        log.fault("Main thread stuck for \(Int(seconds))s; restarting")
        try? "hang 0 \(uptime)".write(to: crashFile, atomically: true, encoding: .utf8)
        if crashRelaunchEnabled != 0, let argv = relaunchArgv {
            var pid: pid_t = 0
            posix_spawn(&pid, "/bin/sh", nil, relaunchAttributes, argv, relaunchEnvironment)
        }
        _exit(EXIT_FAILURE)
    }

    private static var isDebuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return info.kp_proc.p_flag & P_TRACED != 0
    }
}

/// Converts to Int without the runtime trap Int() hits on NaN, infinity or huge values.
func safeInt<F: BinaryFloatingPoint>(_ value: F, fallback: Int = 0) -> Int {
    guard value.isFinite, abs(value) < F(Int32.max) else { return fallback }
    return Int(value)
}

// State for the signal handler, set up in `installCrashHandlers`. A signal handler may only touch
// preallocated memory and async-signal-safe calls, so everything it needs is ready beforehand.
private var crashFilePath: UnsafeMutablePointer<CChar>?
private var exceptionFilePath = ""
private var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
private var exceptionHandlerPointer: (@convention(c) (NSException) -> Void)?
private var numberBuffer: UnsafeMutablePointer<UInt8>?
private var launchTime: time_t = 0
private var relaunchArgv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
private var relaunchEnvironment: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
private var relaunchAttributes: UnsafeMutablePointer<posix_spawnattr_t?>?
private var crashRelaunchEnabled: Int32 = 1
private var handlingCrash: Int32 = 0

private func crashSignalHandler(_ signal: Int32) {
    // A second fault while handling the first: give up and let the system take over.
    if handlingCrash != 0 {
        Darwin.signal(signal, SIG_DFL)
        raise(signal)
        return
    }
    handlingCrash = 1

    if let path = crashFilePath {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            writeLiteral(fd, "signal ")
            writeNumber(fd, Int(signal))
            writeLiteral(fd, " ")
            writeNumber(fd, Int(time(nil) - launchTime))
            close(fd)
        }
    }
    if crashRelaunchEnabled != 0, let argv = relaunchArgv {
        var pid: pid_t = 0
        posix_spawn(&pid, "/bin/sh", nil, relaunchAttributes, argv, relaunchEnvironment)
    }
    // Let the system finish the crash as usual (crash report included).
    Darwin.signal(signal, SIG_DFL)
    raise(signal)
}

private func writeLiteral(_ fd: Int32, _ text: StaticString) {
    _ = write(fd, text.utf8Start, text.utf8CodeUnitCount)
}

/// Writes a non-negative number without allocating.
private func writeNumber(_ fd: Int32, _ value: Int) {
    guard let buffer = numberBuffer else { return }
    var number = max(value, 0)
    var length = 0
    repeat {
        buffer[23 - length] = UInt8(48 + number % 10)
        number /= 10
        length += 1
    } while number > 0 && length < 24
    _ = write(fd, buffer + (24 - length), length)
}

/// Pings the main thread every two seconds. Stuck for 8 seconds: logged. Stuck for 45: restarted,
/// since a menu bar app that never responds again is worse than one that comes back.
private final class Watchdog: @unchecked Sendable {
    static let shared = Watchdog()
    private let queue = DispatchQueue(label: "stability.watchdog", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var pingSentAt: TimeInterval?
    private var warned = false

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 2, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    private func check() {
        // System uptime stops while the Mac sleeps, so sleep never looks like a hang.
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let sent = pingSentAt
        if sent == nil { pingSentAt = now }
        lock.unlock()

        guard let sent else {
            DispatchQueue.main.async { [self] in
                lock.lock()
                let wasWarned = warned
                pingSentAt = nil
                warned = false
                lock.unlock()
                if wasWarned { Stability.log.notice("Main thread responsive again") }
            }
            return
        }
        let stalled = now - sent
        if stalled >= 45 {
            Stability.recoverFromHang(seconds: stalled)
        } else if stalled >= 8 {
            lock.lock()
            let first = !warned
            warned = true
            lock.unlock()
            if first { Stability.log.fault("Main thread unresponsive for \(Int(stalled))s") }
        }
    }
}
