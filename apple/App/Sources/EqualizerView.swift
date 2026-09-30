import SwiftUI
import CascadeKit

/// Settings > Equalizer: the desktop's five bands, presets and preamp.
struct EqualizerView: View {
    @Environment(AppState.self) private var state

    private var profile: EQProfile { state.player?.equalizer ?? EQProfile() }

    private func set(_ change: (inout EQProfile) -> Void) {
        var p = profile
        change(&p)
        state.setEqualizer(p)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Equalizer", isOn: Binding(get: { profile.enabled }, set: { on in set { $0.enabled = on } }))
                Picker("Preset", selection: Binding(
                    get: { profile.presetName ?? "Custom" },
                    set: { name in
                        guard let preset = EQProfile.presets.first(where: { $0.name == name }) else { return }
                        set { $0.gains = preset.bands }
                    })) {
                    ForEach(EQProfile.presets, id: \.name) { Text($0.name).tag($0.name) }
                    if profile.presetName == nil { Text("Custom").tag("Custom") }
                }
            } footer: {
                Text("Works on songs streamed at Original quality and on downloads; a lower streaming quality plays flat. While it is on, quiet tracks are also turned up by volume normalization.\n\nIt costs gapless playback: expect a short pause, about a quarter second, between tracks, even on albums meant to run together.")
            }

            Section("Bands") {
                ForEach(EQProfile.bands.indices, id: \.self) { i in
                    DecibelRow(label: bandLabel(EQProfile.bands[i]), value: Binding(
                        get: { i < profile.gains.count ? profile.gains[i] : 0 },
                        set: { v in set { $0.gains[i] = EQProfile.clamp(v) } }))
                }
            }
            .disabled(!profile.enabled)

            Section {
                Toggle("Automatic Preamp", isOn: Binding(
                    get: { profile.preamp == nil },
                    set: { auto in set { $0.preamp = auto ? nil : $0.effectivePreamp } }))
                if profile.preamp != nil {
                    DecibelRow(label: "Preamp", value: Binding(
                        get: { profile.effectivePreamp },
                        set: { v in set { $0.preamp = EQProfile.clamp(v) } }))
                }
                Button("Reset", role: .destructive) { set { $0 = EQProfile(enabled: $0.enabled) } }
            } footer: {
                Text("Automatic turns the whole signal down by the biggest boost, so boosted bands cannot distort.")
            }
            .disabled(!profile.enabled)
        }
        .navigationTitle("Equalizer")
    }

    private func bandLabel(_ hz: Double) -> String {
        hz >= 1000 ? "\(Int(hz / 1000)) kHz" : "\(Int(hz)) Hz"
    }
}

/// A gain from -12 to +12 dB: a slider on iOS, steps on tvOS, which has no
/// Slider.
private struct DecibelRow: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        let text = String(format: "%+.1f dB", value)
        #if os(tvOS)
        HStack {
            Text(label)
            Spacer()
            Button { value = EQProfile.clamp(value - 1) } label: { Image(systemName: "minus") }
            Text(text).monospacedDigit().frame(minWidth: 120)
            Button { value = EQProfile.clamp(value + 1) } label: { Image(systemName: "plus") }
        }
        #else
        VStack(alignment: .leading) {
            HStack {
                Text(label)
                Spacer()
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: -EQProfile.gainLimit...EQProfile.gainLimit, step: 0.5)
                .accessibilityLabel(label)
                .accessibilityValue(text)
        }
        #endif
    }
}
