import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CascadeKit

/// The look as a CascadePreset, and a preset applied back, in the desktop's
/// format so looks move between the two apps. The lyric size travels as the
/// desktop's lyricScale (1 is 30 pt here); every other knob by its own key.
@MainActor
enum LookPresets {
    static let baseLyricSize = 30.0

    static func current(name: String) -> CascadePreset {
        let theme = MacTheme.shared
        let s = theme.settings
        var style = StyleTuning.shared.changes
        style["lyricSize"] = nil
        return CascadePreset(
            name: name,
            theme: .init(mode: s.mode, gradStart: s.gradStart, gradEnd: s.gradEnd, albumArt: s.albumArt,
                         bgDim: theme.tuning.bgDim, bgBlend: theme.tuning.bgBlend,
                         fontPreset: theme.fontPreset, fontCustom: theme.fontCustom),
            lyrics: .init(style: style,
                          lyricScale: NPTuning.clampLyricScale(StyleTuning.shared.values.lyricSize / baseLyricSize)))
    }

    /// Each part the preset carries replaces that part whole: knobs it does not
    /// name go back to the defaults, so it lands on one known look.
    static func apply(_ preset: CascadePreset) {
        let theme = MacTheme.shared
        if let t = preset.theme {
            var s = theme.settings
            (s.mode, s.gradStart, s.gradEnd, s.albumArt) = (t.mode, t.gradStart, t.gradEnd, t.albumArt)
            theme.settings = s
            var tuning = theme.tuning
            (tuning.bgDim, tuning.bgBlend) = (t.bgDim, t.bgBlend)
            theme.tuning = tuning
            theme.setFont(preset: t.fontPreset, custom: t.fontCustom)
        }
        if let l = preset.lyrics {
            var v = StyleTuning.Values()
            for knob in StyleTuning.knobs {
                let value = knob.key == "lyricSize" ? l.lyricScale * baseLyricSize : l.style[knob.key]
                // Clamped here: the preset is someone else's file.
                if let value { v[keyPath: knob.path] = min(max(value, knob.range.lowerBound), knob.range.upperBound) }
            }
            StyleTuning.shared.values = v
            var tuning = theme.tuning
            tuning.lyricScale = l.lyricScale
            theme.tuning = tuning
        }
    }
}

/// Theme panel > Share a Look: export or copy the look, import or paste one.
struct SharePresetSection: View {
    @AppStorage("cascade.presetName") private var name = "My Cascade look"
    @State private var status: (ok: Bool, text: String)?

    private static let type = UTType(filenameExtension: CascadePreset.fileExtension, conformingTo: .json) ?? .json

    var body: some View {
        Section {
            TextField("Name", text: $name)
            HStack {
                Button("Export\u{2026}", action: export)
                Button("Copy as Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(LookPresets.current(name: name).serialized(), forType: .string)
                    status = (true, "Copied. Paste it into Cascade on another computer.")
                }
            }
            HStack {
                Button("Import\u{2026}", action: importFile)
                Button("Paste") { use(NSPasteboard.general.string(forType: .string) ?? "") }
            }
            if let status {
                Text(status.text).font(.caption).foregroundStyle(status.ok ? Color.secondary : Color.red)
            }
        } header: {
            Text("Share a Look")
        } footer: {
            Text("The theme and the lyrics look, as a file or text that Cascade on the desktop or another Mac can open.")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CascadePreset.fileName(name)
        panel.allowedContentTypes = [Self.type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LookPresets.current(name: name).serialized().write(to: url, atomically: true, encoding: .utf8)
            status = (true, "Saved \(url.lastPathComponent).")
        } catch {
            status = (false, "Could not save: \(error.localizedDescription)")
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.type, .json, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Size first: a preset is a few hundred bytes, and a wrong file can be anything.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= CascadePreset.maxBytes else { return status = (false, CascadePreset.ParseError.tooLarge.description) }
        use((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    private func use(_ text: String) {
        switch CascadePreset.parse(text) {
        case .success(let preset):
            LookPresets.apply(preset)
            let parts = [preset.theme != nil ? "theme" : nil, preset.lyrics != nil ? "lyrics" : nil].compactMap { $0 }
            status = (true, "Applied \u{201C}\(preset.name)\u{201D} (\(parts.joined(separator: " and "))).")
        case .failure(let error):
            status = (false, error.description)
        }
    }
}
