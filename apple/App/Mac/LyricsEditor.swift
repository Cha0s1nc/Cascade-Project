import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CascadeKit

// The lyrics editor, ported from lyrics-editor.html: line rows with word pills, an inspector,
// Stamp mode, its own player with speed, a karaoke preview, and a save to the Cascade Server
// plugin. The document logic is LRCDocument in CascadeKit; the state is LyricsEditorModel.

struct LyricsEditorView: View {
    let itemId: String
    @Environment(AppState.self) private var state
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var model = LyricsEditorModel()
    @State private var importing = false

    var body: some View {
        Group {
            if let error = model.loadError {
                Text(error).foregroundStyle(.secondary).padding()
            } else if state.cascadePluginApi == nil && model.loaded {
                Text("The lyrics editor needs the Cascade Server plugin, which was not found on this server.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            } else if !model.loaded {
                ProgressView()
            } else {
                editor
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .macThemed()
        .task {
            // The "needs the plugin" notice, once, before the editor opens. The openers may have
            // shown it already; this makes a window opened any other way ask too.
            guard PluginNotice.ensure() else { dismissWindow(id: "lyrics-editor", value: itemId); return }
            await model.load(state: state, itemId: itemId)
        }
        .onDisappear { model.stop() }
        .background(KeyMonitor { handle($0) })
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.lrcTypes) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return alert("Could not read that file.") }
            let parsed = LRCDocument.parse(text)
            if parsed.isEmpty { return alert("No valid LRC lines found in that file.") }
            if model.lines.isEmpty || confirmOverwrite("Import \"\(url.lastPathComponent)\"?") { model.replace(with: parsed) }
        }
    }

    private static let lrcTypes: [UTType] = [.plainText, UTType(filenameExtension: "lrc"), UTType(filenameExtension: "slrc")].compactMap { $0 }

    private var editor: some View {
        VStack(spacing: 0) {
            header
            Divider()
            KaraokePreview(model: model).frame(height: 64)
            Divider()
            LineList(model: model)
            Divider()
            Inspector(model: model).frame(height: 76)
            Divider()
            transport
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ArtworkView(itemId: model.item?.albumId ?? model.item?.id, size: 44).frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.item?.name ?? "Unknown Track").font(.headline).lineLimit(1)
                Text([model.item?.albumArtist ?? model.item?.artists?.first, model.item?.album].compactMap { $0 }.joined(separator: " - "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let status = model.status {
                Text(status.text).font(.caption).foregroundStyle(status.ok ? .green : .red).lineLimit(1)
            }
            Button { model.toggleStamp() } label: { Label("Stamp Mode", systemImage: "hand.tap") }
                .disabled(model.lines.isEmpty)
                .tint(model.stamping ? MacTheme.shared.accent : nil)
                .help("Space stamps the next word at the playhead; Esc leaves")
            Button("Re-import") {
                if model.original.isEmpty { return }
                if model.lines.isEmpty || confirmOverwrite("Re-import the saved lyrics?") { model.replace(with: model.original) }
            }
            .disabled(model.original.isEmpty)
            Button("Import .lrc") { importing = true }
            Button("Save to Jellyfin") { Task { await model.save(state: state) } }
                .buttonStyle(.borderedProminent)
                .disabled(model.lines.isEmpty || model.saving)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(12)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay(mainPlayer: state.player) } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
            }
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            Slider(value: Binding(get: { model.position }, set: { model.seek(to: $0) }), in: 0...max(model.duration, 1))
                .accessibilityLabel("Position")
            Text("\(LRCDocument.display(model.position)) / \(LRCDocument.display(model.duration))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Divider().frame(height: 16)
            Slider(value: Binding(get: { model.speed }, set: { model.setSpeed($0) }), in: 0.25...2, step: 0.05)
                .frame(width: 100).accessibilityLabel("Speed")
            Text(model.speed == 1 ? "1\u{00D7}" : String(format: "%.2f", model.speed).replacing(/\.?0+$/, with: "") + "\u{00D7}")
                .font(.caption.monospacedDigit()).frame(width: 40, alignment: .leading)
                .onTapGesture(count: 2) { model.setSpeed(1) }
                .help("Double-click to reset to 1\u{00D7}")
        }
        .padding(12)
    }

    // MARK: Keys

    /// Space plays (or stamps), the arrows seek 5 s, j and l 1 s, Esc leaves Stamp mode. Not
    /// while a text field is being edited (KeyMonitor leaves those alone).
    private func handle(_ event: NSEvent) -> Bool {
        let seek: (Double) -> Void = { model.skip($0) }
        switch event.keyCode {
        case 49:
            if model.stamping { model.stampNext() } else { model.togglePlay(mainPlayer: state.player) }
        case 123: seek(-5)
        case 124: seek(5)
        case 53:
            guard model.stamping else { return false }
            model.exitStamp()
        default:
            // j and l are plain seeks, but not in Stamp mode, where the hands are busy with Space.
            switch event.charactersIgnoringModifiers {
            case "j" where !model.stamping: seek(-1)
            case "l" where !model.stamping: seek(1)
            default: return false
            }
        }
        return true
    }

    private func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.runModal()
    }

    private func confirmOverwrite(_ question: String) -> Bool {
        let a = NSAlert()
        a.messageText = question
        a.informativeText = "This will overwrite your current edits."
        a.addButton(withTitle: "Overwrite")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - The line list

private struct LineList: View {
    let model: LyricsEditorModel
    @State private var editingWord: LyricsEditorModel.Selection?

    var body: some View {
        let playing = LRCDocument.active(model.lines, at: model.position)?.line
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.lines.indices, id: \.self) { li in
                        row(li, playing: playing == li).id(li)
                    }
                    Button("+ Add line") { model.appendLine() }.padding(.top, 6)
                }
                .padding(12)
            }
            .onChange(of: model.stampIdx) {
                switch model.stampTarget {
                case .word(let l, _)?, .line(let l)?: withAnimation { proxy.scrollTo(l, anchor: .center) }
                case nil: break
                }
            }
        }
    }

    private func row(_ li: Int, playing: Bool) -> some View {
        let line = model.lines[li]
        let selected = model.selection == .line(li)
        let lineStampNext = model.stampTarget == .line(li)
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 2) {
                Text("\(li + 1)").font(.caption2).foregroundStyle(.secondary)
                Text(LRCDocument.display(line.start))
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(MacTheme.shared.accent, lineWidth: lineStampNext ? 2 : 0))
                    .help("Click to edit this line's timestamp")
            }
            .frame(width: 70)
            Group {
                if let words = line.words {
                    PillFlow(spacing: 6) {
                        ForEach(words.indices, id: \.self) { wi in pill(li, wi, words[wi]) }
                        Button { model.addWord(li) } label: { Text("+").padding(.horizontal, 6) }
                            .buttonStyle(.bordered).controlSize(.small).help("Add word")
                    }
                } else {
                    TextField("Lyric line", text: Binding(get: { model.lines[li].text }, set: { model.setText(li, $0) }))
                        .textFieldStyle(.plain)
                        .onTapGesture { model.selection = .line(li) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                if li > 0 { iconButton("arrow.up", "Move up") { model.moveLine(li, -1) } }
                if li < model.lines.count - 1 { iconButton("arrow.down", "Move down") { model.moveLine(li, 1) } }
                if line.words == nil { iconButton("textformat.abc", "Split into word pills") { model.splitLine(li) } }
                iconButton("xmark", "Remove line") { model.removeLine(li) }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(playing ? MacTheme.shared.accent.opacity(0.18) : Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(MacTheme.shared.accent, lineWidth: selected ? 1.5 : 0))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = .line(li) }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.caption) }
            .buttonStyle(.borderless).help(help).accessibilityLabel(help)
    }

    @ViewBuilder private func pill(_ li: Int, _ wi: Int, _ word: LRCWord) -> some View {
        let sel = LyricsEditorModel.Selection.word(li, wi)
        let isNext = model.stampTarget == .word(line: li, word: wi)
        Group {
            if editingWord == sel {
                TextField("word", text: Binding(get: { model.lines[li].words?[wi].text.trimmingCharacters(in: .whitespaces) ?? "" },
                                                set: { model.setWord(li, wi, text: $0) }))
                    .textFieldStyle(.plain).frame(minWidth: 40).fixedSize()
                    .onSubmit { editingWord = nil }
            } else {
                Text(word.text.trimmingCharacters(in: .whitespaces))
                    .onTapGesture(count: 2) { model.selection = sel; editingWord = sel }
                    .onTapGesture { model.selection = sel }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(model.selection == sel ? MacTheme.shared.accent.opacity(0.35) : Color.primary.opacity(0.12)))
        .overlay(Capsule().stroke(MacTheme.shared.accent, lineWidth: isNext ? 2 : 0))
        .help("Click to select, double-click to edit, drag to reorder")
        // Dragging a word onto another puts it in front of that one, on any line.
        .draggable("\(li):\(wi)")
        .dropDestination(for: String.self) { items, _ in
            let from = items.first?.split(separator: ":").compactMap { Int($0) }
            guard let from, from.count == 2 else { return false }
            model.moveWord(from: (from[0], from[1]), before: (li, wi))
            return true
        }
    }
}

/// Words side by side, wrapping onto new rows.
private struct PillFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, origin) in arrange(width: bounds.width, subviews).origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            maxX = max(maxX, x - spacing)
        }
        return (origins, CGSize(width: maxX, height: y + rowHeight))
    }
}

// MARK: - Inspector

private struct Inspector: View {
    let model: LyricsEditorModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.selection {
            case .line(let li)? where model.lines.indices.contains(li):
                Text("LINE").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Text("Start").foregroundStyle(.secondary)
                TimeField(value: Binding(get: { model.lines[li].start }, set: { model.setStart(li, $0) }))
                Button("Stamp") { model.stampSelection() }
                Spacer()
            case .word(let li, let wi)? where model.lines.indices.contains(li) && model.lines[li].words?.indices.contains(wi) == true:
                Text("WORD").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                TextField("word text", text: Binding(get: { model.lines[li].words?[wi].text.trimmingCharacters(in: .whitespaces) ?? "" },
                                                     set: { model.setWord(li, wi, text: $0) }))
                    .frame(width: 140)
                Text("Start").foregroundStyle(.secondary)
                TimeField(value: Binding(get: { model.lines[li].words?[wi].start }, set: { model.setWord(li, wi, start: .some($0)) }))
                Button("Stamp") { model.stampSelection() }
                Text("End").foregroundStyle(.secondary)
                TimeField(value: Binding(get: { model.lines[li].words?[wi].end }, set: { model.setWord(li, wi, end: .some($0)) }))
                Button("Stamp") { model.stampSelection(end: true) }
                Spacer()
                Button { model.moveWord(li, wi, -1) } label: { Image(systemName: "arrow.left") }.help("Move word left")
                Button { model.moveWord(li, wi, 1) } label: { Image(systemName: "arrow.right") }.help("Move word right")
                Button(role: .destructive) { model.removeWord(li, wi) } label: { Image(systemName: "trash") }.help("Remove word")
            default:
                Text("Select a line or word to edit timestamps").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        // A fresh set of fields for each selection, so one never shows another's text.
        .id(model.selection)
    }
}

/// A time as `m:ss.xxx`, committed on Return.
private struct TimeField: View {
    @Binding var value: Double?
    @State private var text = ""

    var body: some View {
        TextField("m:ss.xxx", text: $text)
            .font(.body.monospacedDigit())
            .frame(width: 90)
            .onSubmit {
                if let s = LRCDocument.seconds(fromDisplay: text) { value = s }
                text = shown
            }
            .onAppear { text = shown }
            .onChange(of: value) { text = shown }
    }

    private var shown: String { value == nil ? "" : LRCDocument.display(value) }
}

// MARK: - Karaoke preview

/// The line at the playhead, its words lighting as they are reached.
private struct KaraokePreview: View {
    let model: LyricsEditorModel

    var body: some View {
        let hit = LRCDocument.active(model.lines, at: model.position)
        Group {
            if model.lines.isEmpty {
                hint("No lyrics loaded")
            } else if let hit {
                let line = model.lines[hit.line]
                if let words = line.words, !words.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(words.indices, id: \.self) { wi in
                            Text(words[wi].text.trimmingCharacters(in: .whitespaces))
                                .foregroundStyle(wi == hit.word ? MacTheme.shared.accent : (hit.word.map { wi < $0 } == true ? Color.primary : Color.primary.opacity(0.35)))
                        }
                    }
                } else {
                    Text(line.text)
                }
            } else {
                hint(model.lines.contains { $0.start != nil }
                     ? "Waiting for first line\u{2026}"
                     : "No timestamps set. Use Stamp Mode or click a line time to add them")
            }
        }
        .font(.title3.weight(.semibold))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }

    private func hint(_ text: String) -> some View { Text(text).font(.callout).foregroundStyle(.secondary) }
}

// MARK: - Keys

/// Hands key-downs in its window to `handler` (true means taken), except while a text field is
/// being edited: its field editor is an NSText, which gets the key as typing.
private struct KeyMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let v = KeyView()
        v.handler = handler
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { (v as? KeyView)?.handler = handler }

    final class KeyView: NSView {
        var handler: (NSEvent) -> Bool = { _ in false }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window,
                      event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
                      !(self.window?.firstResponder is NSText) else { return event }
                return self.handler(event) ? nil : event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
