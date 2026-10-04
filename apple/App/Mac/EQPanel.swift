import SwiftUI
import CascadeKit

/// One equalizer profile's editor, for Settings > Playback: its own switch,
/// presets, a draggable response graph, and the preamp. The desktop's
/// per-profile panel (`data-eq` in index.html); Music and Video each get one,
/// so editing one cannot touch the other's curve.
struct EQPanel: View {
    let title: String
    @Binding var profile: EQProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Toggle(title, isOn: Binding(get: { profile.enabled }, set: { on in change { $0.enabled = on } }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Picker("Preset", selection: Binding(
                get: { profile.presetName ?? "Custom" },
                set: { name in
                    guard let preset = EQProfile.presets.first(where: { $0.name == name }) else { return }
                    change { $0.gains = preset.bands }
                })) {
                ForEach(EQProfile.presets, id: \.name) { Text($0.name).tag($0.name) }
                if profile.presetName == nil { Text("Custom").tag("Custom") }
            }
            EQGraphView(label: title, gains: Binding(get: { profile.gains }, set: { g in change { $0.gains = g } }))
                .opacity(profile.enabled ? 1 : 0.55)
            Toggle("Automatic preamp", isOn: Binding(
                get: { profile.preamp == nil },
                // Seeds manual mode with the current auto value instead of jumping to 0.
                set: { auto in change { $0.preamp = auto ? nil : $0.effectivePreamp } }))
            if profile.preamp != nil {
                HStack {
                    Text("Preamp")
                    Slider(value: Binding(get: { profile.effectivePreamp }, set: { v in change { $0.preamp = EQProfile.clamp((v * 2).rounded() / 2) } }),
                           in: -EQProfile.gainLimit...EQProfile.gainLimit)
                        .accessibilityLabel("\(title) preamp")
                    Text(String(format: "%+.1f dB", profile.effectivePreamp)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                }
            } else {
                Text(String(format: "Preamp %+.1f dB: turned down by the biggest boost so boosted bands cannot distort.", profile.effectivePreamp))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Reset", role: .destructive) { change { $0 = EQProfile(enabled: $0.enabled) } }
            }
        }
    }

    private func change(_ edit: (inout EQProfile) -> Void) {
        var p = profile
        edit(&p)
        profile = p
    }
}

/// The five points on a curve: drag a point up or down, or focus the graph and
/// use the keys the desktop's points take (left and right choose a band, up and
/// down 0.5 dB, Page keys 3 dB, Home and End the limits).
struct EQGraphView: View {
    let label: String
    @Binding var gains: [Double]

    @State private var dragging: Int?
    @State private var selected = 0
    @FocusState private var focused: Bool
    private let height: CGFloat = 140

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    Canvas { context, size in
                        for db in [-6.0, 0, 6] {
                            var line = Path()
                            let y = EQGraph.y(db, height: size.height)
                            line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                            context.stroke(line, with: .color(.secondary.opacity(db == 0 ? 0.45 : 0.18)), lineWidth: 1)
                        }
                        let points = EQGraph.points(gains, width: size.width, height: size.height)
                        guard let first = points.first else { return }
                        var curve = Path()
                        curve.move(to: CGPoint(x: first.x, y: first.y))
                        for s in EQGraph.curve(gains, width: size.width, height: size.height) {
                            curve.addCurve(to: CGPoint(x: s.to.x, y: s.to.y), control1: CGPoint(x: s.control1.x, y: s.control1.y),
                                           control2: CGPoint(x: s.control2.x, y: s.control2.y))
                        }
                        context.stroke(curve, with: .color(.accentColor), lineWidth: 2.5)
                    }
                    ForEach(gains.indices, id: \.self) { i in
                        let active = dragging == i || (focused && selected == i)
                        Circle()
                            .fill(active ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                            .frame(width: active ? 16 : 13, height: active ? 16 : 13)
                            .position(x: EQGraph.x(i, of: gains.count, width: w), y: EQGraph.y(gains[i], height: h))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // The point nearest where the drag began is the one it moves.
                        if dragging == nil {
                            dragging = gains.indices.min { abs(EQGraph.x($0, of: gains.count, width: w) - value.startLocation.x)
                                                           < abs(EQGraph.x($1, of: gains.count, width: w) - value.startLocation.x) }
                            if let d = dragging { selected = d }
                            focused = true
                        }
                        if let i = dragging, gains.indices.contains(i) { gains[i] = EQGraph.db(y: value.location.y, height: h) }
                    }
                    .onEnded { _ in dragging = nil })
            }
            .frame(height: height)
            .padding(.horizontal, 6)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { selected = max(0, selected - 1); return .handled }
            .onKeyPress(.rightArrow) { selected = min(gains.count - 1, selected + 1); return .handled }
            .onKeyPress(.upArrow) { nudge(.up) }
            .onKeyPress(.downArrow) { nudge(.down) }
            .onKeyPress(.pageUp) { nudge(.pageUp) }
            .onKeyPress(.pageDown) { nudge(.pageDown) }
            .onKeyPress(.home) { nudge(.home) }
            .onKeyPress(.end) { nudge(.end) }
            .accessibilityElement()
            .accessibilityLabel("\(label) equalizer, \(EQGraph.label(EQProfile.bands[min(selected, EQProfile.bands.count - 1)]))")
            .accessibilityValue(String(format: "%+.1f dB", gains.indices.contains(selected) ? gains[selected] : 0))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: _ = nudge(.up)
                case .decrement: _ = nudge(.down)
                @unknown default: break
                }
            }
            HStack(spacing: 0) {
                ForEach(gains.indices, id: \.self) { i in
                    VStack(spacing: 0) {
                        Text(EQGraph.label(EQProfile.bands[i])).font(.caption2)
                        Text(String(format: "%.1f dB", gains[i])).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func nudge(_ key: EQGraph.Key) -> KeyPress.Result {
        guard gains.indices.contains(selected) else { return .ignored }
        gains[selected] = EQGraph.db(after: key, from: gains[selected])
        return .handled
    }
}

/// The Video profile lives in `cascade.eqVideo`, the Electron key's name, in the
/// same shape as the Music one (`cascade.eq`).
///
/// HOOK for the playback agent (P): until PlaybackService holds a Video profile
/// and AppState a setter for it, editing the panel only persists the value
/// here. When P lands that, replace the body of `applyVideoEqualizer` with the
/// call that puts the profile on the live video player, and make
/// `loadVideoEqualizer` read it from there.
@MainActor
enum VideoEqualizer {
    static let key = "cascade.eqVideo"

    static func load() -> EQProfile { EQProfile.decode(UserDefaults.standard.data(forKey: key)) }

    static func save(_ profile: EQProfile, state: AppState) {
        UserDefaults.standard.set(profile.encoded(), forKey: key)
        applyVideoEqualizer(profile, state: state)
    }

    /// P: wire this to the video player's equalizer.
    static func applyVideoEqualizer(_ profile: EQProfile, state: AppState) {}
}
