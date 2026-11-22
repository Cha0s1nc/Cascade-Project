import SwiftUI
import CascadeKit

/// The Mac's Home in Personality v1, as the Penpot "Mac / Home" board and Flutter's
/// desktop Home (flutter/lib/ui/pages/home.dart): the greeting and its voice line,
/// Recently played as the Home card beside eight song tiles, Continue watching, and
/// Recently added. One Home for Music and Video, like Flutter's desktop.
///
/// ponytail: no Rediscover shelf yet; it lands with the Rediscover page.
struct MacHomeView: View {
    @Environment(AppState.self) private var state
    @Environment(\.uiScale) private var zoom
    @State private var played: [JfItem] = []
    @State private var added: [JfItem] = []
    @State private var watching: [JfItem] = []
    @State private var voice: String?
    @State private var loading = true
    @State private var error: String?
    /// The page's content width, for the Recently played layout.
    @State private var width: CGFloat = 0

    private var libraries: VideoLibrarySelection { state.videoLibraries }
    private static var voiceCache: (key: String, line: String)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(greeting).cx(.hero).foregroundStyle(Cx.text)
                    Text(voice ?? today).cx(.voice).foregroundStyle(Cx.text2)
                }
                if let error {
                    HStack {
                        Text(error).cx(.regular).foregroundStyle(.red)
                        Button("Try Again") { Task { await load() } }
                    }
                    .padding(.top, 12)
                } else if loading && played.isEmpty && added.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(40)
                }
                if let first = played.first {
                    header("Recently played", link: "See all", to: .history)
                    recentlyPlayed(first)
                }
                if !watching.isEmpty {
                    header("Continue watching")
                    continueWatching
                }
                if !added.isEmpty {
                    header("Recently added")
                    shelf(added)
                }
            }
            .padding(.horizontal, 36 * zoom).padding(.top, 30 * zoom).padding(.bottom, 40 * zoom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { ($0.size.width - 72 * zoom).rounded() } action: { width = $0 }
        }
        .background(alignment: .top) { Cx.wash.frame(height: 360 * zoom).allowsHitTesting(false) }
        .navigationTitle("Home")
        .task(id: state.config?.libraryIds) { await load() }
        .task(id: "\(libraries.movieIds)|\(libraries.showIds)|\(state.videoRevision)") { await loadVideo() }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return "\(part), \(state.username ?? "there")"
    }

    private var today: String { Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()) }

    private func load() async {
        guard let client = state.client else { return }
        state.snapshotHistory()
        if played.isEmpty && added.isEmpty { loading = true }
        do {
            async let p = client.recentlyPlayed(limit: 9)
            async let a = client.recentlyAdded(limit: 12)
            (played, added) = try await (p, a)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
        // The voice line is a nicety: on any failure the date stays.
        // ponytail: worked out once per launch and account (it reads up to 500 plays), as
        // Flutter's stats(); refresh it on a timer if a long-running session drifts.
        let key = "\(state.config?.url ?? "")|\(state.config?.userId ?? "")|\(state.config?.libraryIds ?? [])"
        if let cached = Self.voiceCache, cached.key == key { voice = cached.line; return }
        if let stats = try? await client.homeStats() {
            voice = HomeVoice.line(songs: stats.songs, week: stats.week)
            Self.voiceCache = (key, voice!)
        }
    }

    private func loadVideo() async {
        guard let client = state.client else { return }
        await libraries.load(client: client, userId: state.config?.userId)
        let (movies, shows) = (libraries.movieIds, libraries.showIds)
        guard !movies.isEmpty || !shows.isEmpty else { watching = []; return }
        watching = (try? await client.continueWatchingMerged(movieIds: movies, showIds: shows, limit: 3)) ?? []
    }

    private func header(_ title: String, link: String? = nil, to route: AppRoute? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).cx(.section).foregroundStyle(Cx.text)
            Spacer()
            if let link, let route {
                NavigationLink(value: route) { Text(link).cx(.small).foregroundStyle(Cx.text2) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.top, 30 * zoom).padding(.bottom, 16 * zoom)
    }

    /// The Home card, then the next eight played songs in two columns beside it;
    /// in a narrow window the tiles go under the card.
    private func recentlyPlayed(_ first: JfItem) -> some View {
        let tiles = Array(played.dropFirst().prefix(8))
        let grid = HStack(alignment: .top, spacing: 12) {
            ForEach([Array(tiles.prefix(4)), Array(tiles.dropFirst(4))].indices, id: \.self) { column in
                let half = column == 0 ? Array(tiles.prefix(4)) : Array(tiles.dropFirst(4))
                VStack(spacing: 8) {
                    ForEach(half) { song in
                        SongTile(song: song) { Task { await state.player?.play(played, startIndex: played.firstIndex(of: song) ?? 0) } }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        // Flutter's widths: a 440 pt card in a wide window, 380 in a middling one, and the
        // tiles under the card once two 260 pt columns no longer fit beside it.
        let card = width >= 1100 * zoom ? 440 * zoom : 380 * zoom
        return Group {
            if width >= card + 16 + 520 * zoom {
                HStack(alignment: .top, spacing: 16) {
                    HomeCard(lastPlayed: first, played: played).frame(width: card)
                    grid
                }
            } else {
                VStack(spacing: 16) {
                    HomeCard(lastPlayed: first, played: played)
                    grid
                }
            }
        }
    }

    private var continueWatching: some View {
        // As many as fit (a card needs about 330 pt), up to three.
        HStack(alignment: .top, spacing: 20 * zoom) {
            ForEach(watching.prefix(max(1, min(3, Int((width + 20 * zoom) / (330 * zoom)))))) { item in
                Button { Task { await state.playVideoItem(item) } } label: {
                    CardHover { hovering in
                        HStack(spacing: 14) {
                            ArtworkView(itemId: item.id, size: 176, aspect: 16.0 / 9.0,
                                        imageType: item.type == "Movie" && item.backdropImageTags?.isEmpty == false ? "Backdrop" : "Primary")
                                .overlay(alignment: .bottom) { WatchedBar(item: item) }
                                // A click plays it, so under the pointer it shows a play mark.
                                .overlay { if hovering { PlayMarkOverlay() } }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.seriesName ?? item.name ?? "Untitled").cx(.strong)
                                    .foregroundStyle(hovering ? Cx.accent : Cx.text).lineLimit(1)
                                Text(item.type == "Episode"
                                     ? [VideoPlayback.episodeCode(item), item.name].compactMap { $0 }.joined(separator: " \u{00B7} ")
                                     : ["Movie", item.productionYear.map(String.init)].compactMap { $0 }.joined(separator: " \u{00B7} "))
                                    .cx(.small).foregroundStyle(Cx.text2).lineLimit(1)
                                if let left = timeLeft(item) { Text(left).cx(.small).foregroundStyle(Cx.text3) }
                            }
                            .frame(maxWidth: 160 * zoom, alignment: .leading)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func timeLeft(_ item: JfItem) -> String? {
        guard let total = item.runTimeTicks, total > 0 else { return nil }
        let minutes = Int(Double(total - (item.userData?.playbackPositionTicks ?? 0)) / 600_000_000)
        guard minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
    }

    /// One row of album cards, as many as fit at 168 pt.
    private func shelf(_ albums: [JfItem]) -> some View {
        GeometryReader { geo in
            let gap = 22 * zoom
            let count = max(3, Int((geo.size.width + gap) / (168 * zoom + gap)))
            let width = (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            HStack(alignment: .top, spacing: gap) {
                ForEach(albums.prefix(count)) { album in
                    // The library's card, so the shelf answers the pointer as the grids do.
                    NavigationLink(value: album) { MacTile(item: album, subtitle: album.albumArtist).frame(width: width) }
                    .buttonStyle(.plain)
                    .itemContextMenu(album)
                }
            }
        }
        .frame(height: 230 * zoom)
    }
}

/// A played song as a small card: art, title, artist and album, length.
private struct SongTile: View {
    let song: JfItem
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                ArtworkView(itemId: song.albumId ?? song.id, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name ?? "Unknown").cx(.row).foregroundStyle(Cx.text).lineLimit(1)
                    Text([song.albumArtist ?? song.artists?.first, song.album].compactMap { $0 }.joined(separator: " \u{00B7} "))
                        .cx(.small).foregroundStyle(Cx.text2).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let ticks = song.runTimeTicks {
                    Text(clock(Double(ticks) / 10_000_000)).cx(.small).monospacedDigit().foregroundStyle(Cx.text3)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background((hovering ? Cx.hover : Cx.surface.opacity(0.55)), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .trackContextMenu(song)
    }
}

/// Home's card (Flutter's HeroCard). With a queue playing or offered back it is
/// "Now playing" or "Previously queued": that song, how many are left, the next songs
/// falling in behind its art, and Resume. Without one it is "Last played": the last
/// song alone, with Play.
private struct HomeCard: View {
    let lastPlayed: JfItem
    let played: [JfItem]
    @Environment(AppState.self) private var state
    @Environment(\.uiScale) private var zoom

    private enum Mode { case playing, paused, offered, last }
    /// Flutter's compact card below 460 pt, or Play and Shuffle wrap.
    @State private var compact = false

    var body: some View {
        let player = state.player
        let live = player?.item != nil && (player?.queue.items.count ?? 0) > 1
        let offer = live ? nil : state.restoreOffer
        let mode: Mode = live ? (player!.isPaused ? .paused : .playing) : offer != nil ? .offered : .last
        let (song, next): (JfItem, [JfItem]) = switch mode {
        case .playing, .paused:
            (player!.item!, Array(player!.queue.items.dropFirst(player!.queue.index + 1)))
        case .offered:
            (offer!.queue.queue[min(offer!.queue.index, offer!.queue.queue.count - 1)],
             Array(offer!.queue.queue.dropFirst(offer!.queue.index + 1)))
        case .last:
            (lastPlayed, [])
        }
        HStack(spacing: (compact ? 16 : 22) * zoom) {
            ArtStack(song: song, next: next, size: (compact ? 96 : 140) * zoom)
            VStack(alignment: .leading, spacing: 0) {
                Text(mode == .playing ? "Now playing" : mode == .last ? "Last played" : "Previously queued")
                    .cx(.caps).foregroundStyle(Cx.foam)
                Group {
                    if compact { Text(song.name ?? "Unknown").font(.display(22 * zoom)) } else { Text(song.name ?? "Unknown").cx(.title) }
                }
                .foregroundStyle(Cx.text).lineLimit(1)
                    .padding(.top, 6)
                Text([song.albumArtist ?? song.artists?.first, song.album].compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .cx(.row).foregroundStyle(Cx.text2).lineLimit(1)
                    .padding(.top, 6)
                if !next.isEmpty {
                    Text("\(next.count) left").cx(.small).foregroundStyle(Cx.text3).padding(.top, 4)
                }
                HStack(spacing: 8) {
                    switch mode {
                    case .playing: PillButton("Pause", symbol: "pause.fill", primary: true) { player?.togglePlayPause() }
                    case .paused: PillButton("Resume", symbol: "play.fill", primary: true) { player?.togglePlayPause() }
                    case .offered:
                        PillButton("Resume", symbol: "play.fill", primary: true) {
                            // The offer restores the queue paused; Resume here means play it.
                            offer?.accept()
                            state.restoreOffer = nil
                            if state.player?.isPaused == true { state.player?.togglePlayPause() }
                        }
                    case .last:
                        PillButton("Play", symbol: "play.fill", primary: true) {
                            Task { await state.player?.play(played, startIndex: 0) }
                        }
                    }
                    PillButton("Shuffle", symbol: "shuffle") {
                        guard let player else { return }
                        if !player.shuffle { player.toggleShuffle() }
                        if mode == .last { Task { await player.play(played, startIndex: 0) } }
                    }
                }
                .padding(.top, compact ? 12 : 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding((compact ? 18 : 22) * zoom)
        .frame(minHeight: (compact ? 168 : 230) * zoom)
        .onGeometryChange(for: Bool.self) { $0.size.width < 460 * zoom } action: { compact = $0 }
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(Cx.surface)
                .overlay(RoundedRectangle(cornerRadius: 18).fill(LinearGradient(
                    colors: [Color(dark: 0x5A2A5E, light: 0x5A2A5E, darkOpacity: 0.5, lightOpacity: 0.2), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing)))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Cx.line))
        }
        .trackContextMenu(song)
    }
}

/// The cover with the next songs stepped in behind it (Flutter's ArtStack, still):
/// up to three, each smaller, fainter and a peek further right. Off with the
/// showArtStack setting (Flutter's key), and with an empty queue it is one cover.
struct ArtStack: View {
    let song: JfItem
    let next: [JfItem]
    let size: CGFloat
    /// False when the caller draws the front cover itself (Now Playing's, with its overlays).
    var showsFront = true
    @AppStorage("cascade.showArtStack") private var showStack = true
    @Environment(\.uiScale) private var zoom

    var body: some View {
        let behind = showStack ? Array(next.prefix(3)) : []
        let peek = size * 0.07
        ZStack(alignment: .leading) {
            ForEach(Array(behind.enumerated()).reversed(), id: \.offset) { i, item in
                let scale = 0.9 - Double(i) * 0.07
                ArtworkView(itemId: item.albumId ?? item.id, size: size * scale / zoom)
                    .opacity(0.6 - Double(i) * 0.15)
                    .offset(x: size * (1 - scale) + peek * CGFloat(i + 1))
            }
            if showsFront {
                ArtworkView(itemId: song.albumId ?? song.id, size: size / zoom)
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
            }
        }
        .frame(width: size + peek * CGFloat(behind.count), height: size, alignment: .leading)
        .animation(.easeInOut(duration: 0.3), value: song.id)
    }
}
