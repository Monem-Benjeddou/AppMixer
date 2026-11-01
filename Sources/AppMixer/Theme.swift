import AppKit
import SwiftUI

/// AppMixer's look: an audio instrument panel. Graphite in dark mode, warm paper in light mode, one signal
/// colour for anything that is switched on, monospaced figures for every value. No decoration: every mark
/// on screen shows a state or a value.
enum Theme {
    static let canvas = Color.adaptive(rgb(0xE8E6E1), rgb(0x0B0C0E))
    static let panel = Color.adaptive(rgb(0xF5F4F0), rgb(0x131518))
    static let raised = Color.adaptive(rgb(0xFFFFFF), rgb(0x1D2024))
    /// Recessed areas: fader slots, the EQ plot.
    static let well = Color.adaptive(rgb(0xD9D7D1), rgb(0x08090B))
    static let line = Color.adaptive(rgb(0x000000, 0.09), rgb(0xFFFFFF, 0.07))
    static let lineStrong = Color.adaptive(rgb(0x000000, 0.18), rgb(0xFFFFFF, 0.16))
    static let text = Color.adaptive(rgb(0x17181B), rgb(0xECEDEF))
    static let text2 = Color.adaptive(rgb(0x5A5D64), rgb(0x9DA2AA))
    static let text3 = Color.adaptive(rgb(0x8C8F96), rgb(0x5D626A))
    /// On, active, boosted.
    static let signal = Color(nsColor: rgb(0xFF5B1F))
    /// Playing.
    static let live = Color(nsColor: rgb(0x34D17C))
    /// Muted, failed.
    static let alert = Color(nsColor: rgb(0xFF453A))
    static let caution = Color(nsColor: rgb(0xFFB224))
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

extension Color {
    static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
}

extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Text {
    /// Small tracked capitals, like the printing on a hardware panel.
    func panelLabel(_ color: Color = Theme.text3) -> some View {
        font(.mono(9.5, .semibold)).tracking(1.4).foregroundStyle(color)
    }
}

extension View {
    /// A module on the panel: slightly raised surface, hairline edge.
    func module(radius: CGFloat = 10) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.line))
    }
}

/// A status light. Lit lights glow slightly, like an LED behind a panel.
struct LED: View {
    var color: Color = Theme.signal
    var on: Bool
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(on ? color : Theme.lineStrong)
            .frame(width: size, height: size)
            .shadow(color: on ? color.opacity(0.7) : .clear, radius: on ? 3 : 0)
            .accessibilityHidden(true)
    }
}

/// A panel key: flat, hairline edge, lit in its tint when on.
struct KeyStyle: ButtonStyle {
    var isOn = false
    var tint: Color = Theme.signal
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        KeyBody(configuration: configuration, isOn: isOn, tint: tint, compact: compact)
    }

    private struct KeyBody: View {
        let configuration: Configuration
        let isOn: Bool
        let tint: Color
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.mono(compact ? 9.5 : 10.5, .semibold))
                .tracking(0.8)
                .foregroundStyle(isOn ? tint : Theme.text2)
                .padding(.horizontal, compact ? 7 : 10)
                .frame(minHeight: compact ? 20 : 26)
                .background(RoundedRectangle(cornerRadius: 5).fill(isOn ? tint.opacity(0.14) : Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isOn ? tint.opacity(0.55) : Theme.line))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .contentShape(Rectangle())
        }
    }
}

/// A borderless icon key for bars and footers.
struct IconKey: View {
    let symbol: String
    let help: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Theme.signal : Theme.text2)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? Theme.signal.opacity(0.14) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A fader with a hardware-style cap. Grabbing the cap moves it relative to where you grabbed; clicking the slot
/// jumps there. Drags snap to the detent (100% volume, centre balance), and a double-click returns to it.
struct Fader: View {
    enum Axis { case horizontal, vertical }

    var axis: Axis = .horizontal
    let value: Double
    var range: ClosedRange<Double> = 0...1
    var detent: Double?
    var tint: Color = Theme.signal
    /// Values marked beside a vertical fader.
    var marks: [(value: Double, label: String)] = []
    let label: String
    var valueText: String = ""
    let onChange: (Double) -> Void

    @State private var grab: Double?
    @Environment(\.isEnabled) private var isEnabled

    private var span: Double { range.upperBound - range.lowerBound }
    private var capLength: CGFloat { axis == .vertical ? 14 : 12 }

    var body: some View {
        GeometryReader { geo in
            let vertical = axis == .vertical
            let length = vertical ? geo.size.height : geo.size.width
            let travel = max(length - capLength, 1)
            let fraction = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span
            let center = CGPoint(x: vertical ? geo.size.width / 2 : 0, y: vertical ? 0 : geo.size.height / 2)
            let at: (Double) -> CGPoint = { f in
                vertical ? CGPoint(x: center.x, y: length - capLength / 2 - f * travel)
                         : CGPoint(x: capLength / 2 + f * travel, y: center.y)
            }
            let cap = at(fraction)
            let start = at(0)

            ZStack {
                // slot
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.well)
                    .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Theme.line))
                    .frame(width: vertical ? 5 : length, height: vertical ? length : 5)
                    .position(x: vertical ? center.x : length / 2, y: vertical ? length / 2 : center.y)
                // level
                Rectangle()
                    .fill(isEnabled ? tint : Theme.text3)
                    .frame(width: vertical ? 3 : abs(cap.x - start.x), height: vertical ? abs(start.y - cap.y) : 3)
                    .position(x: vertical ? center.x : (start.x + cap.x) / 2, y: vertical ? (start.y + cap.y) / 2 : center.y)
                // scale
                if vertical {
                    ForEach(0...10, id: \.self) { i in
                        let p = at(Double(i) / 10)
                        Rectangle().fill(Theme.lineStrong).frame(width: i % 5 == 0 ? 7 : 4, height: 1)
                            .position(x: center.x - 10 - (i % 5 == 0 ? 0 : 1.5), y: p.y)
                    }
                    ForEach(marks.indices, id: \.self) { i in
                        let p = at((marks[i].value - range.lowerBound) / span)
                        Text(marks[i].label).font(.mono(8)).foregroundStyle(Theme.text3)
                            .fixedSize()
                            .position(x: center.x + 25, y: p.y)
                    }
                }
                if let detent {
                    let p = at((detent - range.lowerBound) / span)
                    Rectangle().fill(Theme.text3)
                        .frame(width: vertical ? 14 : 1, height: vertical ? 1 : 9)
                        .position(p)
                }
                // cap
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.raised)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.lineStrong))
                    .overlay(Rectangle().fill(isEnabled ? tint : Theme.text3)
                        .frame(width: vertical ? 14 : 1.5, height: vertical ? 1.5 : 8))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    .frame(width: vertical ? 30 : capLength, height: vertical ? capLength : 18)
                    .position(cap)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let along: (CGPoint) -> Double = { p in
                        Double(vertical ? (length - capLength / 2 - p.y) : (p.x - capLength / 2)) / Double(travel)
                    }
                    if grab == nil {
                        let hit = abs(along(drag.startLocation) - fraction) * Double(travel) < Double(capLength)
                        grab = hit ? fraction : min(max(along(drag.startLocation), 0), 1)
                    }
                    let moved = Double(vertical ? -drag.translation.height : drag.translation.width) / Double(travel)
                    var newValue = range.lowerBound + min(max((grab ?? 0) + moved, 0), 1) * span
                    if let detent, abs(newValue - detent) < span * 0.025 { newValue = detent }
                    onChange(newValue)
                }
                .onEnded { _ in grab = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { if let detent { onChange(detent) } })
        }
        .frame(width: axis == .vertical ? 64 : nil, height: axis == .horizontal ? 18 : nil)
        .help(detent == nil ? label : "\(label): double-click to reset")
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            let step = span / 20
            switch direction {
            case .increment: onChange(min(value + step, range.upperBound))
            case .decrement: onChange(max(value - step, range.lowerBound))
            @unknown default: break
            }
        }
    }
}

/// A numeric display: monospaced figure, small unit.
struct Readout: View {
    let value: String
    var unit = "%"
    var color: Color = Theme.text
    var size: CGFloat = 13

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(value).font(.mono(size, .medium))
            if !unit.isEmpty { Text(unit).font(.mono(size * 0.62)).foregroundStyle(Theme.text3) }
        }
        .foregroundStyle(color)
        .monospacedDigit()
    }
}

/// A status message across the top of the panel.
struct Notice: View {
    let tint: Color
    let symbol: String
    let title: String
    let message: String
    var actions: [(title: String, run: () -> Void)] = []

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                if !actions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(actions.indices, id: \.self) { i in
                            Button(actions[i].title.uppercased(), action: actions[i].run).buttonStyle(KeyStyle(compact: true))
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.08)))
        .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 2).padding(.vertical, 8) }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.25)))
    }
}

/// A menu drawn as panel text with a small chevron, instead of a system pop-up button.
struct PanelMenu<Content: View>: View {
    let title: String
    var font: Font = .mono(10.5, .medium)
    var color: Color = Theme.text
    var lines = 1
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            HStack(spacing: 4) {
                Text(title).lineLimit(lines).truncationMode(.middle).multilineTextAlignment(.center)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Theme.text3)
            }
            .font(font)
            .foregroundStyle(color)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// Checkmarked menu item.
@ViewBuilder func menuItem(_ title: String, _ checked: Bool) -> some View {
    if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
}
