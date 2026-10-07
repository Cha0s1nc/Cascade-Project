import SwiftUI
import CascadeKit

/// Toolbar button (and the overlay header's) opening the Theme panel: the desktop's theme
/// popover, a Theme page with Colors and Lyrics a push away.
struct ThemePanelButton: View {
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Image(systemName: "paintpalette") }
            .help("Theme and lyrics")
            .accessibilityLabel("Theme and lyrics")
            .popover(isPresented: $open, arrowEdge: .bottom) { ThemePanel() }
    }
}

/// The panel itself: Mode and Font on the main page, Colors and Lyrics one push away.
struct ThemePanel: View {
    var body: some View {
        NavigationStack {
            ThemeMainPage()
        }
        .frame(width: 340, height: 480)
    }
}

// MARK: - Main page

private struct ThemeMainPage: View {
    @Bindable private var theme = MacTheme.shared
    @State private var custom = MacTheme.shared.fontCustom

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Mode", selection: $theme.settings.mode) {
                    Text("Dark").tag(ThemeSettings.Mode.dark)
                    Text("Light").tag(ThemeSettings.Mode.light)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section {
                NavigationLink {
                    ThemeColorsPage()
                } label: {
                    HStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color(hex: theme.settings.gradStart), theme.accent],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 14, height: 14)
                        Text("Colors")
                    }
                }
                NavigationLink("Lyrics") { ThemeLyricsPage() }
            }
            Section("Font") {
                Picker("Font", selection: Binding(
                    get: { theme.fontPreset },
                    set: { theme.setFont(preset: $0, custom: custom) })) {
                    ForEach(AppFont.presets, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                if theme.fontPreset == "custom" {
                    TextField("Font family name", text: $custom)
                        .noAutocaps()
                        .autocorrectionDisabled()
                        .onChange(of: custom) { _, new in theme.setFont(preset: "custom", custom: new) }
                    if !custom.isEmpty, AppFont.sanitize(custom).isEmpty {
                        Text("Letters, numbers, spaces and hyphens only.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            SharePresetSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Theme")
    }
}

// MARK: - Colors

private struct ThemeColorsPage: View {
    @Bindable private var theme = MacTheme.shared

    var body: some View {
        let locked = theme.settings.albumArt
        Form {
            Section("Gradient") {
                HStack {
                    colorWell("Start", hex: $theme.settings.gradStart)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    colorWell("End", hex: $theme.settings.gradEnd)
                }
                presets
            }
            .disabled(locked)
            .opacity(locked ? 0.4 : 1)
            .help(locked ? "Album art accent overrides this" : "")

            Section {
                Toggle(isOn: $theme.settings.albumArt) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Album art accent")
                        Text("Match the colors to the current album's art").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Now Playing background") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Background dim")
                        Spacer()
                        Text(theme.tuning.bgDim, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { theme.tuning.bgDim }, set: { theme.tuning.bgDim = NPTuning.clampBgDim($0) }),
                           in: NPTuning.bgDimRange)
                    Text("Light mode with album art accent").font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: $theme.tuning.bgBlend) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Blend background with art")
                        Text("Light mode with album art accent").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Colors")
    }

    private func colorWell(_ name: String, hex: Binding<String>) -> some View {
        VStack(spacing: 4) {
            ColorPicker(name, selection: Binding(get: { Color(hex: hex.wrappedValue) },
                                                 set: { hex.wrappedValue = $0.hexString }),
                        supportsOpacity: false)
                .labelsHidden()
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var presets: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            ForEach(ThemePreset.all) { preset in
                let active = theme.settings.activePreset == preset
                Button {
                    theme.settings.gradStart = preset.start
                    theme.settings.gradEnd = preset.end
                } label: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [Color(hex: preset.start), Color(hex: preset.end)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 34)
                        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.primary, lineWidth: active ? 2 : 0) }
                }
                .buttonStyle(.plain)
                .help(preset.label)
                .accessibilityLabel(preset.label)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
    }
}

// MARK: - Lyrics

/// Every lyric knob (StyleTuning, which keeps the desktop's lyric-style.ts keys), by section,
/// with a reset for each and one for all. The first page of presets is the iOS sheet's.
private struct ThemeLyricsPage: View {
    @Bindable private var tuning = StyleTuning.shared

    private var sections: [String] {
        StyleTuning.knobs.map(\.section).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    var body: some View {
        Form {
            Section {
                Text("Full-screen lyrics in Now Playing. Changes show right away.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(StyleTuning.presetGroups) { group in
                Section {
                    presetPicker(group)
                } header: {
                    Text(group.title)
                } footer: {
                    Text(group.footer)
                }
            }
            ForEach(sections, id: \.self) { section in
                Section(section) {
                    ForEach(StyleTuning.knobs.filter { $0.section == section }, id: \.key) { KnobRow(knob: $0) }
                }
            }
            Section {
                Button("Reset all lyric settings", role: .destructive) { tuning.values = .init() }
                    .disabled(tuning.changes.isEmpty)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Lyrics")
    }

    /// The group's choices, plus Custom while its knobs match none.
    private func presetPicker(_ group: StyleTuning.PresetGroup) -> some View {
        let current = tuning.preset(in: group)?.name ?? "Custom"
        return Picker(group.title, selection: Binding(
            get: { current },
            set: { name in
                if let preset = group.presets.first(where: { $0.name == name }) { tuning.apply(preset) }
            })) {
            ForEach(group.presets) { Text($0.name).tag($0.name) }
            if current == "Custom" { Text("Custom").tag("Custom") }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// One knob: its value (accented once changed) over a slider, and a button that puts it back.
private struct KnobRow: View {
    let knob: StyleTuning.Knob
    @Bindable private var tuning = StyleTuning.shared

    var body: some View {
        let value = tuning.values[keyPath: knob.path]
        let standard = StyleTuning.Values()[keyPath: knob.path]
        let changed = value != standard
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(knob.label)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(knob.step < 0.01 ? 3 : knob.step < 1 ? 2 : 0)))
                    .monospacedDigit()
                    .foregroundStyle(changed ? MacTheme.shared.accent : .secondary)
                Button {
                    tuning.values[keyPath: knob.path] = standard
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .opacity(changed ? 1 : 0)
                .disabled(!changed)
                .help("Reset to \(standard.formatted(.number.precision(.fractionLength(knob.step < 0.01 ? 3 : knob.step < 1 ? 2 : 0))))")
                .accessibilityLabel("Reset \(knob.label)")
            }
            .font(.subheadline)
            Slider(value: $tuning.values[dynamicMember: knob.path], in: knob.range, step: knob.step)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { tuning.values[keyPath: knob.path] = standard }
    }
}
