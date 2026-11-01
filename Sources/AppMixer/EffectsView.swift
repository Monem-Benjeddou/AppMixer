import AVFoundation
import SwiftUI

/// EQ, Magic Boost and Audio Unit controls for one route: an app (`routeID` = its bundle ID) or the whole system.
struct EffectsEditor: View {
    let effects: Effects
    let routeID: String
    let title: String
    @ObservedObject var model: MixerModel
    /// The popover version: modules stacked, shorter graph.
    var compact = false
    let onChange: (Effects) -> Void

    private func change(_ edit: (inout Effects) -> Void) {
        var copy = effects
        edit(&copy)
        onChange(copy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LED(on: effects.isActive)
                Text(title.uppercased()).panelLabel(Theme.text2).lineLimit(1)
                Spacer()
                Button(effects.enabled ? "ACTIVE" : "BYPASSED") { change { $0.enabled.toggle() } }
                    .buttonStyle(KeyStyle(isOn: effects.enabled, compact: true))
                    .help(effects.enabled ? "Bypass: hear the original sound, keep the settings" : "Turn the effects back on")
                Button("RESET") { onChange(Effects()) }
                    .buttonStyle(KeyStyle(compact: true))
                    .disabled(effects == Effects())
            }

            Group {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("EQUALIZER").panelLabel()
                        Spacer()
                        PresetMenu(eq: effects.eq) { eq in change { $0.eq = eq } }
                    }
                    EQGraph(gains: effects.eq) { eq in change { $0.eq = eq } }
                        .frame(height: compact ? 150 : 230)
                }
                .padding(12)
                .module()

                let modules = Group {
                    BoostModule(isOn: effects.boost) { on in change { $0.boost = on } }
                    AudioUnitModule(selected: effects.audioUnit, routeID: routeID, model: model) { ref in
                        change { $0.audioUnit = ref }
                    }
                }
                if compact {
                    VStack(spacing: 10) { modules }
                } else {
                    HStack(alignment: .top, spacing: 12) { modules }
                }
            }
            .disabled(!effects.enabled)
            .opacity(effects.enabled ? 1 : 0.45)
        }
    }
}

private struct BoostModule: View {
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Button { onChange(!isOn) } label: {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isOn ? Theme.signal : Theme.text2)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 7).fill(isOn ? Theme.signal.opacity(0.14) : Theme.raised))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isOn ? Theme.signal.opacity(0.5) : Theme.line))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("MAGIC BOOST").font(.mono(11, .semibold)).tracking(1).foregroundStyle(Theme.text)
                        LED(on: isOn)
                    }
                    Text("Quiet audio up to 4× louder. Loud audio left alone.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .module()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Magic Boost")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct PresetMenu: View {
    let eq: [Float]
    let onSelect: ([Float]) -> Void

    var body: some View {
        PanelMenu(title: (Effects.presets.first { $0.eq == eq }?.name ?? "Custom").uppercased(), font: .mono(9.5, .semibold),
                  color: Theme.text2) {
            ForEach(Effects.presets, id: \.name) { preset in
                Button { onSelect(preset.eq) } label: { menuItem(preset.name, preset.eq == eq) }
            }
        }
        .fixedSize()
        .help("Equalizer presets")
    }
}

/// The EQ as a frequency-response plot: the curve is computed from the same filters the audio runs through.
/// Drag up or down anywhere in a band's column to set it; double-click to flatten it.
struct EQGraph: View {
    let gains: [Float]
    let onChange: ([Float]) -> Void
    @State private var dragging: Int?

    private static let minHz: Float = 20, maxHz: Float = 20000
    private static let inset = EdgeInsets(top: 10, leading: 30, bottom: 20, trailing: 10)

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: Self.inset.leading, y: Self.inset.top,
                              width: max(geo.size.width - Self.inset.leading - Self.inset.trailing, 1),
                              height: max(geo.size.height - Self.inset.top - Self.inset.bottom, 1))
            let x: (Float) -> CGFloat = { hz in
                plot.minX + CGFloat(log10(hz / Self.minHz) / log10(Self.maxHz / Self.minHz)) * plot.width
            }
            let y: (Float) -> CGFloat = { db in
                plot.midY - CGFloat(min(max(db, -Effects.maxGain - 3), Effects.maxGain + 3) / Effects.maxGain) * plot.height / 2
            }

            ZStack {
                Canvas { context, _ in
                    context.fill(Path(roundedRect: plot, cornerRadius: 4), with: .color(Theme.well))
                    for db: Float in [-12, -6, 0, 6, 12] {
                        var line = Path()
                        line.move(to: CGPoint(x: plot.minX, y: y(db)))
                        line.addLine(to: CGPoint(x: plot.maxX, y: y(db)))
                        context.stroke(line, with: .color(db == 0 ? Theme.lineStrong : Theme.line), lineWidth: 1)
                        context.draw(Text(db > 0 ? "+\(Int(db))" : "\(Int(db))").font(.mono(8)).foregroundColor(Theme.text3),
                                     at: CGPoint(x: plot.minX - 6, y: y(db)), anchor: .trailing)
                    }
                    for hz in Effects.bands {
                        var line = Path()
                        line.move(to: CGPoint(x: x(hz), y: plot.minY))
                        line.addLine(to: CGPoint(x: x(hz), y: plot.maxY))
                        context.stroke(line, with: .color(Theme.line), lineWidth: 1)
                        context.draw(Text(EQGraph.label(hz)).font(.mono(8)).foregroundColor(Theme.text3),
                                     at: CGPoint(x: x(hz), y: plot.maxY + 10))
                    }
                    var curve = Path()
                    for i in 0...180 {
                        let hz = Self.minHz * pow(Self.maxHz / Self.minHz, Float(i) / 180)
                        let point = CGPoint(x: x(hz), y: y(EffectChain.response(gains, at: hz)))
                        if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                    }
                    var area = curve
                    area.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
                    area.addLine(to: CGPoint(x: plot.minX, y: plot.midY))
                    area.closeSubpath()
                    context.fill(area, with: .color(Theme.signal.opacity(0.12)))
                    context.stroke(curve, with: .color(Theme.signal), lineWidth: 1.5)
                }

                ForEach(Effects.bands.indices, id: \.self) { band in
                    let gain = band < gains.count ? gains[band] : 0
                    let active = dragging == band
                    Circle()
                        .fill(gain == 0 ? Theme.raised : Theme.signal)
                        .overlay(Circle().strokeBorder(gain == 0 ? Theme.lineStrong : Theme.signal, lineWidth: 1.5))
                        .frame(width: active ? 13 : 9, height: active ? 13 : 9)
                        .position(x: x(Effects.bands[band]), y: y(gain))
                        .overlay {
                            if active {
                                Text(String(format: "%+.0f dB", gain))
                                    .font(.mono(9, .semibold))
                                    .foregroundStyle(Theme.text)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.raised))
                                    .position(x: x(Effects.bands[band]), y: y(gain) - 16)
                            }
                        }
                        .accessibilityElement()
                        .accessibilityLabel("\(EQGraph.label(Effects.bands[band])) hertz")
                        .accessibilityValue("\(Int(gain)) decibels")
                        .accessibilityAdjustableAction { direction in
                            set(band, direction == .increment ? gain + 1 : gain - 1)
                        }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let band = dragging ?? nearest(drag.startLocation.x, x)
                    dragging = band
                    let db = Float((plot.midY - drag.location.y) / (plot.height / 2)) * Effects.maxGain
                    set(band, abs(db) < 0.75 ? 0 : db.rounded())
                }
                .onEnded { _ in dragging = nil })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in set(nearest(tap.location.x, x), 0) })
        }
        .help("Drag a band up or down. Double-click to flatten it.")
    }

    private func nearest(_ px: CGFloat, _ x: (Float) -> CGFloat) -> Int {
        Effects.bands.indices.min { abs(x(Effects.bands[$0]) - px) < abs(x(Effects.bands[$1]) - px) } ?? 0
    }

    private func set(_ band: Int, _ db: Float) {
        var copy = gains
        guard band < copy.count else { return }
        copy[band] = min(max(db, -Effects.maxGain), Effects.maxGain)
        if copy != gains { onChange(copy) }
    }

    static func label(_ hz: Float) -> String { hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))" }
}

private struct AudioUnitModule: View {
    let selected: AudioUnitRef?
    let routeID: String
    @ObservedObject var model: MixerModel
    let onSelect: (AudioUnitRef?) -> Void

    /// Listing components asks every installed plug-in bundle; done once, the first time a picker is shown.
    private static let installed: [(maker: String, units: [AVAudioUnitComponent])] =
        Dictionary(grouping: AudioUnitRef.installed(), by: \.manufacturerName)
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.maker < $1.maker }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("AUDIO UNIT").panelLabel()
                LED(on: selected != nil)
                Spacer()
            }
            HStack(spacing: 8) {
                PanelMenu(title: selected?.name ?? "Empty slot", font: .system(size: 12.5, weight: .medium),
                          color: selected == nil ? Theme.text3 : Theme.text) {
                    Button { onSelect(nil) } label: { menuItem("None", selected == nil) }
                    Divider()
                    if Self.installed.isEmpty { Text("No Audio Unit effects installed") }
                    ForEach(Self.installed, id: \.maker) { group in
                        Section(group.maker) {
                            ForEach(group.units, id: \.self) { unit in
                                let ref = AudioUnitRef(unit)
                                Button { onSelect(ref) } label: { menuItem(unit.name, ref == selected) }
                            }
                        }
                    }
                }
                Spacer(minLength: 4)
                Button("EDIT") { model.openAudioUnitEditor(for: routeID, title: selected?.name ?? "Audio Unit") }
                    .buttonStyle(KeyStyle(compact: true))
                    .disabled(selected == nil)
                    .help("Open the effect's own controls")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .module()
    }
}

/// The FX key on a channel: lit while the app has effects on, opens its editor.
struct EffectsButton: View {
    let app: AudioApp
    @ObservedObject var model: MixerModel
    var compact = false
    @State private var showing = false

    private var effects: Effects { model.setting(for: app.id).effects }

    var body: some View {
        Button { showing.toggle() } label: {
            Text("FX").frame(maxWidth: compact ? nil : .infinity)
        }
        .buttonStyle(KeyStyle(isOn: effects.isActive, compact: true))
        .help("Effects for \(app.name)")
        .accessibilityLabel("Effects for \(app.name)")
        .accessibilityValue(effects.isActive ? "On" : "Off")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            EffectsEditor(effects: effects, routeID: app.id, title: app.name, model: model, compact: true) {
                model.setEffects($0, for: app.id)
            }
            .padding(14)
            .frame(width: 420)
            .background(Theme.canvas)
        }
    }
}
