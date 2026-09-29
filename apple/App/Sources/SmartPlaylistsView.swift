import SwiftUI
import CascadeKit

/// The built-in smart playlists, the desktop's two.
private let builtIns: [(kind: String, name: String, symbol: String, colors: [Color])] = [
    ("favorites", "Favorites", "heart.fill", [.pink, .red]),
    ("most-played", "Most Played", "chart.line.uptrend.xyaxis", [.blue, .green]),
]

/// Playlists that fill themselves: Favorites, Most Played and the user's own
/// rule-based ones, then a tile to make another. Above the real playlists.
struct SmartPlaylistShelf: View {
    @Environment(AppState.self) private var state
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Smart Playlists").font(.headline).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(builtIns, id: \.kind) { entry in
                        NavigationLink(value: AppRoute.smartPlaylist(entry.kind)) {
                            tile(entry.name, "Auto-updating", entry.symbol, entry.colors)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(state.smartPlaylists) { playlist in
                        NavigationLink(value: AppRoute.smartPlaylist(playlist.id)) {
                            tile(playlist.name, "Smart playlist", "line.3.horizontal.decrease", [.purple, .indigo])
                        }
                        .buttonStyle(.plain)
                    }
                    Button { creating = true } label: {
                        tile("New", "Build from rules", "plus", [.gray.opacity(0.5), .gray.opacity(0.8)])
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 8)
        .sheet(isPresented: $creating) {
            SmartPlaylistEditor(playlist: SmartPlaylist(name: "")).environment(state)
        }
    }

    private func tile(_ name: String, _ subtitle: String, _ symbol: String, _ colors: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 120, height: 120)
                .overlay { Image(systemName: symbol).font(.largeTitle).foregroundStyle(.white) }
            Text(name).font(.caption).lineLimit(1)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 120, alignment: .leading)
    }
}

/// One smart playlist's songs, worked out fresh each time it opens.
struct SmartPlaylistView: View {
    let kind: String
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var tracks: [JfItem] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var editing = false
    @State private var confirmingDelete = false

    private var userPlaylist: SmartPlaylist? { state.smartPlaylists.first { $0.id == kind } }
    private var name: String { builtIns.first { $0.kind == kind }?.name ?? userPlaylist?.name ?? "Smart Playlist" }

    var body: some View {
        List {
            HStack(spacing: 12) {
                Button { Task { await state.player?.play(tracks) } } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                Button { Task { await playShuffled(tracks, on: state.player) } } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(tracks.isEmpty)
            #if os(iOS)
            .listRowSeparator(.hidden)
            #endif
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button { Task { await state.player?.play(tracks, startIndex: index) } } label: {
                    TrackRow(track: track)
                }
                .buttonStyle(.plain)
                .trackContextMenu(track)
            }
            if tracks.isEmpty {
                LoadingOverlay(isLoading: isLoading, error: error, isEmpty: true)
            }
        }
        .navigationTitle(name)
        .toolbar {
            if userPlaylist != nil {
                ToolbarItem {
                    Menu {
                        Button("Edit Rules", systemImage: "slider.horizontal.3") { editing = true }
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let userPlaylist { SmartPlaylistEditor(playlist: userPlaylist).environment(state) }
        }
        .confirmationDialog("Delete \(name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                state.deleteSmartPlaylist(id: kind)
                dismiss()
            }
        }
        .refreshable { await load() }
        // Again after editing: the rules are part of the key.
        .task(id: userPlaylist) { await load() }
    }

    private func load() async {
        guard let client = state.client else { return }
        do {
            switch kind {
            case "favorites": tracks = try await client.favoriteSongs()
            case "most-played": tracks = try await client.mostPlayedSongs()
            default:
                guard let userPlaylist else { return }
                tracks = try await client.songs(matching: userPlaylist)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

/// The rule builder: a name, all or any, the rules, then order and length.
struct SmartPlaylistEditor: View {
    @State var playlist: SmartPlaylist
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var genres: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $playlist.name)
                    Picker("Songs that match", selection: $playlist.matchAny) {
                        Text("All Rules").tag(false)
                        Text("Any Rule").tag(true)
                    }
                }
                Section {
                    ForEach(playlist.rules.indices, id: \.self) { i in
                        RuleRow(rule: $playlist.rules[i], genres: genres)
                    }
                    .onDelete { playlist.rules.remove(atOffsets: $0) }
                    Menu {
                        Button("Genre") { playlist.rules.append(.genre(genres.first ?? "", isNot: false)) }
                        Button("Artist") { playlist.rules.append(.artist("")) }
                        Button("Year") { playlist.rules.append(.year(min: 1990, max: 1999)) }
                        Button("Added Recently") { playlist.rules.append(.addedWithinDays(30)) }
                        Button("Played") { playlist.rules.append(.played(true)) }
                        Button("Play Count") { playlist.rules.append(.playCountAtLeast(5)) }
                        Button("Favorite") { playlist.rules.append(.favorite(true)) }
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                } header: {
                    Text("Rules")
                } footer: {
                    Text(playlist.rules.isEmpty ? "No rules: every song, in the order below." : "")
                }
                Section("Order") {
                    Picker("Sort By", selection: $playlist.sortBy) {
                        Text("Name").tag(SmartPlaylist.SortField.name)
                        Text("Artist").tag(SmartPlaylist.SortField.artist)
                        Text("Album").tag(SmartPlaylist.SortField.album)
                        Text("Date Added").tag(SmartPlaylist.SortField.dateAdded)
                        Text("Play Count").tag(SmartPlaylist.SortField.playCount)
                    }
                    Toggle("Descending", isOn: $playlist.descending)
                    NumberStepper("Up to \(playlist.limit) songs", value: $playlist.limit, in: 10...SmartPlaylist.maxLimit, step: 10)
                }
            }
            .navigationTitle(state.smartPlaylists.contains { $0.id == playlist.id } ? "Edit Smart Playlist" : "New Smart Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        state.saveSmartPlaylist(playlist)
                        dismiss()
                    }
                    .disabled(playlist.validated() == nil)
                }
            }
            .task {
                genres = ((try? await state.client?.genres()) ?? []).compactMap(\.name)
            }
        }
    }
}

/// One rule's controls, by kind.
private struct RuleRow: View {
    @Binding var rule: SmartPlaylist.Rule
    let genres: [String]

    var body: some View {
        switch rule {
        case .genre(let g, let isNot):
            VStack(alignment: .leading) {
                Picker("Rule", selection: Binding(get: { isNot }, set: { rule = .genre(g, isNot: $0) })) {
                    Text("Is").tag(false)
                    Text("Is not").tag(true)
                }
                Picker("Genre", selection: Binding(get: { g }, set: { rule = .genre($0, isNot: isNot) })) {
                    ForEach(genres.contains(g) || g.isEmpty ? genres : [g] + genres, id: \.self) { Text($0).tag($0) }
                }
            }
        case .artist(let a):
            TextField("Artist is", text: Binding(get: { a }, set: { rule = .artist($0) }))
        case .year(let lo, let hi):
            VStack(alignment: .leading) {
                NumberStepper("From \(String(lo))", value: Binding(get: { lo }, set: { rule = .year(min: $0, max: max($0, hi)) }), in: 1900...2100)
                NumberStepper("To \(String(hi))", value: Binding(get: { hi }, set: { rule = .year(min: min(lo, $0), max: $0) }), in: 1900...2100)
            }
        case .addedWithinDays(let d):
            NumberStepper("Added in the last \(d) days", value: Binding(get: { d }, set: { rule = .addedWithinDays($0) }), in: 1...3650)
        case .played(let p):
            Toggle("Played", isOn: Binding(get: { p }, set: { rule = .played($0) }))
        case .playCountAtLeast(let n):
            NumberStepper("Played at least \(n) times", value: Binding(get: { n }, set: { rule = .playCountAtLeast($0) }), in: 0...1000)
        case .favorite(let f):
            Toggle("Favorite", isOn: Binding(get: { f }, set: { rule = .favorite($0) }))
        }
    }
}

/// Stepper on iOS; tvOS has none, so there it is minus and plus buttons.
private struct NumberStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1

    init(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        #if os(tvOS)
        HStack {
            Text(label)
            Spacer()
            Button { value = max(range.lowerBound, value - step) } label: { Image(systemName: "minus") }
            Button { value = min(range.upperBound, value + step) } label: { Image(systemName: "plus") }
        }
        #else
        Stepper(label, value: $value, in: range, step: step)
        #endif
    }
}
