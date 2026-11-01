import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreAudioKit
import SwiftUI

// MARK: - Global shortcut

/// A system-wide shortcut via Carbon's RegisterEventHotKey (needs no Accessibility permission).
/// Carbon delivers application-target events on the main thread, hence main-actor isolation.
@MainActor
final class HotKey {
    // Read only by `deinit`, which Swift runs outside the main actor.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void
    /// False when another app already owns this shortcut.
    private(set) var isRegistered = false

    init(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            MainActor.assumeIsolated {
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { hotKey.action() } // after the Carbon callback returns
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x414D5852), id: 1) // 'AMXR'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        isRegistered = status == noErr
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

enum HotKeyPreset: String, CaseIterable, Identifiable {
    case off, controlOptionM, controlOptionA, controlOptionCommandM, shiftCommandM

    var id: String { rawValue }

    var display: String {
        switch self {
        case .off: return "None"
        case .controlOptionM: return "⌃⌥M"
        case .controlOptionA: return "⌃⌥A"
        case .controlOptionCommandM: return "⌃⌥⌘M"
        case .shiftCommandM: return "⇧⌘M"
        }
    }

    var keyCode: Int { self == .controlOptionA ? kVK_ANSI_A : kVK_ANSI_M }

    var modifiers: Int {
        switch self {
        case .off: return 0
        case .controlOptionM, .controlOptionA: return controlKey | optionKey
        case .controlOptionCommandM: return controlKey | optionKey | cmdKey
        case .shiftCommandM: return shiftKey | cmdKey
        }
    }

    static var current: HotKeyPreset {
        UserDefaults.standard.string(forKey: Prefs.hotKey).flatMap(HotKeyPreset.init(rawValue:)) ?? .controlOptionM
    }
}

/// Registers the chosen shortcut, which opens the menu bar panel from anywhere.
@MainActor
final class Shortcut: ObservableObject {
    static let shared = Shortcut()
    /// Set when the chosen shortcut is taken by another app.
    @Published private(set) var conflict: HotKeyPreset?
    private var hotKey: HotKey?
    private var registered: HotKeyPreset?

    func register() {
        let preset = HotKeyPreset.current
        guard preset != registered else { return }
        registered = preset
        hotKey = nil
        conflict = nil
        guard preset != .off else { return }
        let hotKey = HotKey(keyCode: preset.keyCode, modifiers: preset.modifiers) { MenuBarPanel.toggle() }
        self.hotKey = hotKey
        if !hotKey.isRegistered {
            conflict = preset
            log.error("Shortcut \(preset.display, privacy: .public) is taken by another app")
        }
    }
}

@MainActor
enum MenuBarPanel {
    /// MenuBarExtra has no API to open it, but clicking its status item does the same thing.
    static func toggle() {
        for window in NSApp.windows where String(describing: type(of: window)).contains("StatusBarWindow") {
            if let button = findButton(in: window.contentView) {
                NSApp.activate()
                button.performClick(nil)
                return
            }
        }
        log.error("Couldn't find the menu bar item to open")
    }

    private static func findButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        return view.subviews.lazy.compactMap { findButton(in: $0) }.first
    }
}

// MARK: - Super Volume Keys

enum VolumeKey { case up, down, mute }

/// Makes the keyboard's volume keys work for outputs macOS can't change the volume of (HDMI, DisplayPort and
/// others), using AppMixer's software volume. The keys are only taken while such an output is the default;
/// otherwise macOS handles them as usual. Needs Accessibility permission to intercept them.
@MainActor
final class VolumeKeys: ObservableObject {
    static let shared = VolumeKeys()
    @Published private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: Prefs.superVolumeKeys) }

    /// Starts or stops to match the setting. Called at launch, when the setting changes and when the app
    /// becomes active (permission may have just been granted in System Settings).
    func update(prompt: Bool = false) {
        guard Self.isEnabled else { return stop() }
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            // The documented value of kAXTrustedCheckOptionPrompt (a C global Swift 6 won't read unchecked).
            if prompt { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
            return
        }
        let systemDefined = CGEventMask(1 << 14) // NX_SYSDEFINED: media and volume keys
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: systemDefined, callback: { _, type, event, _ in
            VolumeKeys.handle(type, event)
        }, userInfo: nil) else {
            log.error("Couldn't start listening for volume keys")
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        isRunning = true
    }

    private func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        isRunning = false
    }

    /// Runs on the main run loop for every media key. Must be quick: a slow tap gets disabled by macOS.
    private nonisolated static func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { if let tap = VolumeKeys.shared.tap { CGEvent.tapEnable(tap: tap, enable: true) } }
            return pass
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return pass }
        let code = (ns.data1 & 0xFFFF_0000) >> 16
        let isDown = (ns.data1 & 0xFF00) >> 8 == 0xA
        let key: VolumeKey
        switch code { // NX_KEYTYPE_SOUND_UP, _SOUND_DOWN, _MUTE
        case 0: key = .up
        case 1: key = .down
        case 7: key = .mute
        default: return pass
        }
        return MainActor.assumeIsolated {
            let model = MixerModel.shared
            guard let device = model.defaultDevice, model.hasFixedVolume(device) else { return pass }
            if isDown { model.volumeKey(key) }
            return nil // the key-up too, or macOS shows its "can't change the volume" symbol
        }
    }
}

/// The on-screen level shown when the volume keys change a software volume.
@MainActor
enum VolumeHUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(volume: Float, muted: Bool, device: String) {
        let view = HUDView(volume: volume, muted: muted, device: device)
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 64),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = NSHostingView(rootView: view)
            self.panel = panel
            return panel
        }()
        (panel.contentView as? NSHostingView<HUDView>)?.rootView = view
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 260 - 12, y: frame.maxY - 64 - 12))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    struct HUDView: View {
        let volume: Float
        let muted: Bool
        let device: String

        var body: some View {
            let lit = muted ? 0 : Int((volume * 16).rounded())
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: VolumeSymbol.name(volume: volume, muted: muted))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(muted ? Theme.alert : Theme.text)
                    Text(device.uppercased()).panelLabel(Theme.text2).lineLimit(1)
                    Spacer()
                    Readout(value: muted ? "MUTE" : "\(safeInt((volume * 100).rounded()))", unit: muted ? "" : "%",
                            color: muted ? Theme.alert : Theme.text, size: 12)
                }
                HStack(spacing: 3) {
                    ForEach(0..<16, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1).fill(i < lit ? Theme.signal : Theme.well).frame(height: 6)
                    }
                }
            }
            .padding(14)
            .frame(width: 260, height: 64)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.lineStrong))
        }
    }
}

enum VolumeSymbol {
    static func name(volume: Float, muted: Bool) -> String {
        if muted || volume <= 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

// MARK: - Audio Unit editor

@MainActor
enum AudioUnitWindow {
    private static var open: [ObjectIdentifier: NSWindow] = [:]
    private static var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Shows the plug-in's own editor. `onClose` saves what was changed in it.
    static func show(_ unit: AUAudioUnit, title: String, onClose: @escaping () -> Void) {
        let id = ObjectIdentifier(unit)
        if let window = open[id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        unit.requestViewController { controller in
            DispatchQueue.main.async {
                // Plug-ins without their own editor get one slider per parameter.
                let controller = controller ?? NSHostingController(rootView: GenericAudioUnitView(unit: unit))
                let window = NSWindow(contentViewController: controller)
                window.title = title
                window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
                window.isReleasedWhenClosed = false
                let preferred = controller.preferredContentSize
                let size = preferred.width > 0 && preferred.height > 0 ? preferred : controller.view.frame.size
                window.setContentSize(size.width > 0 && size.height > 0 ? size : NSSize(width: 480, height: 320))
                window.center()
                open[id] = window
                closeObservers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                            object: window, queue: .main) { _ in
                    onClose()
                    MainActor.assumeIsolated {
                        open[id] = nil
                        if let token = closeObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(token) }
                    }
                }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        }
    }
}

/// Controls for a plug-in that has no editor of its own: its parameters as faders.
private struct GenericAudioUnitView: View {
    let unit: AUAudioUnit
    @State private var values: [AUParameterAddress: AUValue] = [:]

    private var parameters: [AUParameter] { unit.parameterTree?.allParameters.filter { $0.flags.contains(.flag_IsWritable) } ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if parameters.isEmpty {
                    Text("This effect has no adjustable settings.").font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                ForEach(parameters, id: \.address) { parameter in
                    let value = values[parameter.address] ?? parameter.value
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(parameter.displayName.uppercased()).panelLabel(Theme.text2)
                            Spacer()
                            Readout(value: parameter.string(fromValue: [value]), unit: parameter.unitName ?? "", size: 11)
                        }
                        Fader(value: Double(value), range: Double(parameter.minValue)...Double(max(parameter.maxValue, parameter.minValue + 0.0001)),
                              label: parameter.displayName, valueText: parameter.string(fromValue: [value])) { newValue in
                            parameter.value = AUValue(newValue)
                            values[parameter.address] = AUValue(newValue)
                        }
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 420, height: min(CGFloat(max(parameters.count, 1)) * 52 + 36, 520))
        .background(Theme.canvas)
    }
}

// MARK: - Floating window

/// Gives a SwiftUI view access to its window, to pin it above other windows.
struct WindowFloating: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { // the view has no window until it's in one
            guard let window = view.window else { return }
            window.level = floating ? .floating : .normal
            window.collectionBehavior = floating ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        }
    }
}
