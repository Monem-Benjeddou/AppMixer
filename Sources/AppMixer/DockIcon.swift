import AppKit

/// Shows the Dock icon only while one of the app's windows is open. With every window closed the app
/// lives in the menu bar alone, like other menu-bar utilities. Panels (menu bar popovers, floating
/// pickers) don't count as windows.
@MainActor
final class DockIcon {
    static let shared = DockIcon()

    /// When false, the app never appears in the Dock (the "Show in Dock" setting).
    var isEnabled: () -> Bool = { true }

    private var observers: [NSObjectProtocol] = []
    /// While menu-bar-only, a cheap once-a-second check catches windows that appear without posting
    /// any notification (e.g. opened while macOS hasn't let the app become active).
    private var fallbackTimer: Timer?

    func start() {
        let center = NotificationCenter.default
        // Visibility (occlusion) catches windows that appear without taking focus, such as the
        // window SwiftUI opens at launch.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DockIcon.shared.update() }
            })
        }
        // Opening a window from the menu bar activates the app before the window takes focus.
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DockIcon.shared.update() }
        })
        // The closing window is still visible when this fires, so leave it out explicitly.
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated { DockIcon.shared.update(ignoring: closing) }
        })
        // Windows don't exist yet while the app is finishing launching; decide once they do.
        DispatchQueue.main.async { DockIcon.shared.update() }
    }

    func update(ignoring closing: NSWindow? = nil) {
        let hasWindow = NSApp.windows.contains { $0 !== closing && $0.isVisible && Self.isAppWindow($0) }
        let wanted: NSApplication.ActivationPolicy = hasWindow && isEnabled() ? .regular : .accessory
        setFallbackTimer(running: wanted == .accessory && isEnabled())
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        // Coming back to the Dock leaves the app inactive; bring the window forward.
        if wanted == .regular { NSApp.activate() }
    }

    private func setFallbackTimer(running: Bool) {
        if running, fallbackTimer == nil {
            fallbackTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { DockIcon.shared.update() }
            }
            fallbackTimer?.tolerance = 0.5
        } else if !running {
            fallbackTimer?.invalidate()
            fallbackTimer = nil
        }
    }

    private static func isAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && window.level == .normal
    }
}
