import SwiftUI
import CascadeKit

// Movies and shows: the desktop's video browsing. Tapping a movie or show
// opens its page; tapping an episode or Play starts Apple's player.

#if os(tvOS)
let posterWidth: CGFloat = 200
let stillWidth: CGFloat = 360
#else
let posterWidth: CGFloat = 120
let stillWidth: CGFloat = 240
#endif

/// A movie or show: its poster and name, opening its page.
struct PosterTile: View {
    let item: JfItem

    var body: some View {
        NavigationLink(value: item) {
            #if os(macOS)
            MacPosterTile(item: item)
            #else
            VStack(alignment: .leading, spacing: 4) {
                ArtworkView(itemId: item.id, size: posterWidth, aspect: 2.0 / 3.0)
                    .overlay(alignment: .bottom) { WatchedBar(item: item) }
                Text(item.name ?? "Untitled").scaledFont(.caption).lineLimit(1)
                if let year = item.productionYear {
                    Text(String(year)).scaledFont(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: posterWidth)
            #endif
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .modifier(PosterMenu(item: item))
        #endif
    }
}

#if os(macOS)
/// The desktop's poster card menu: play (or resume) a movie, open its page,
/// mark it played or not.
private struct PosterMenu: ViewModifier {
    let item: JfItem
    @Environment(AppState.self) private var state
    @Environment(\.showLibraryItem) private var showLibraryItem
    @Environment(\.openItem) private var openItem
    /// The played state as toggled here, until the grid reloads.
    @State private var played: Bool?

    private var isPlayed: Bool { played ?? item.userData?.played ?? false }

    func body(content: Content) -> some View {
        content.contextMenu {
            if item.type == "Movie" {
                Button((item.userData?.playbackPositionTicks ?? 0) > 0 ? "Resume" : "Play", systemImage: "play") {
                    Task { await state.playVideoItem(item) }
                }
            }
            Button("Go to Details", systemImage: "info.circle") {
                if let openItem { openItem(item) } else { showLibraryItem?(item) }
            }
            Button(isPlayed ? "Mark Unplayed" : "Mark Played", systemImage: isPlayed ? "eye.slash" : "eye") {
                guard let client = state.client else { return }
                let target = !isPlayed
                Task {
                    if (try? await client.setPlayed(target, itemId: item.id)) != nil { played = target }
                    else { announceWriteFailed(target ? "mark as watched" : "mark as unwatched") }
                }
            }
        }
    }
}
#endif

/// An episode or a movie to resume, as a 16:9 still that plays at once.
struct VideoStillTile: View {
    let item: JfItem
    @Environment(AppState.self) private var state

    var body: some View {
        Button {
            Task { await state.playVideoItem(item) }
        } label: {
            #if os(macOS)
            // The whole still plays, so under the pointer it dims with a play mark (CardHover).
            CardHover { hovering in stillBody(hovering) }
            #else
            stillBody(false)
            #endif
        }
        .buttonStyle(.plain)
    }

    private func stillBody(_ hovering: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // A movie's own 16:9 picture is its backdrop; its Primary is
            // the poster, which a wide frame crops.
            ArtworkView(itemId: item.id, size: stillWidth, aspect: 16.0 / 9.0,
                        imageType: item.type == "Movie" && item.backdropImageTags?.isEmpty == false ? "Backdrop" : "Primary")
                .overlay(alignment: .bottom) { WatchedBar(item: item) }
                .overlay { if hovering { PlayMarkOverlay() } }
            Text(item.seriesName ?? item.name ?? "Untitled").scaledFont(.caption).lineLimit(1)
            if item.type == "Episode" {
                Text([VideoPlayback.episodeCode(item), item.name].compactMap { $0 }.joined(separator: " \u{00b7} "))
                    .scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: stillWidth)
    }
}

/// A still or Continue watching card under the pointer: the picture dims and a play mark
/// shows, since a click plays it.
struct PlayMarkOverlay: View {
    var body: some View {
        ZStack {
            ProportionalRoundedRectangle().fill(.black.opacity(0.45))
            Image(systemName: "play.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 4)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// How far in a started movie or episode is, along its bottom edge.
///
/// Takes the numbers rather than the item: JfItem is equal to any other copy
/// with the same id, so SwiftUI took a refetched item with new progress for
/// the old one and never redrew.
struct WatchedBar: View {
    let position: Int
    let total: Int

    init(item: JfItem) {
        position = item.userData?.playbackPositionTicks ?? 0
        total = item.runTimeTicks ?? 0
    }

    var body: some View {
        if position > 0, total > 0 {
            GeometryReader { geo in
                Capsule().fill(.tint)
                    .frame(width: geo.size.width * min(1, Double(position) / Double(total)), height: 4)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .padding(6)
        }
    }
}

/// Backdrop, poster and details, and how to play it.
struct MovieDetailView: View {
    let movie: JfItem
    @Environment(AppState.self) private var state
    @State private var full: JfItem?
    @State private var audioIndex: Int?

    private var item: JfItem { full ?? movie }

    var body: some View {
        content
            .navigationTitle(item.name ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            // The list fetch lacks the streams, which the audio picker needs; and
            // closing the player changes the resume point, so fetch again then.
            .task(id: state.videoRevision) {
                guard let client = state.client else { return }
                if let fresh = try? await client.item(id: movie.id) { full = fresh }
            }
    }

    private func play(resume: Bool) {
        Task { await state.playVideo([item], audioStreamIndex: audioIndex, resume: resume) }
    }

    #if os(macOS)
    /// Personality v1, as Flutter's VideoPage: the detail header with the poster, then the overview.
    private var content: some View {
        let started = resumeTicks(for: item) > 0
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CxDetailHeader(label: "Movie", title: item.name ?? "", artId: item.id, aspect: 2.0 / 3.0,
                               meta: videoFacts(item), voice: item.taglines?.first) {
                    PillButton(started ? "Resume" : "Play", symbol: "play.fill", primary: true) { play(resume: true) }
                    if started { PillButton("From the Start", symbol: "backward.end.fill") { play(resume: false) } }
                    CxLikeButton(item: item)
                    VideoDownloadButton(item: item, kind: .movie)
                }
                VStack(alignment: .leading, spacing: 18) {
                    AudioTrackPicker(item: item, audioIndex: $audioIndex)
                    if let overview = item.overview { CxOverview(text: overview) }
                }
                .cxPage(top: 0)
            }
        }
    }
    #else
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VideoHeader(item: item)
                PlayButtons(item: item, started: resumeTicks(for: item) > 0, audioIndex: $audioIndex) { play(resume: $0) }
                VideoDownloadButton(item: item, kind: .movie).padding(.horizontal)
                if let overview = item.overview { Text(overview).padding(.horizontal) }
            }
            .padding(.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    #endif
}

/// A show: its seasons, and each season's episodes.
struct SeriesDetailView: View {
    let series: JfItem
    @Environment(AppState.self) private var state
    @State private var seasons: [JfItem] = []
    @State private var season: String?
    @State private var episodes: [JfItem] = []
    /// Where you left off (continueEpisode): the episode, and where in it to start.
    @State private var resumeAt: (episode: JfItem, startTicks: Int)?
    /// The show as one item: a list's copy has no overview or taglines.
    @State private var full: JfItem?
    private var show: JfItem { full ?? series }

    var body: some View {
        content
            .navigationTitle(series.name ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task {
                guard let client = state.client, seasons.isEmpty else { return }
                async let one = try? await client.item(id: series.id)
                seasons = (try? await client.seasons(of: series.id)) ?? []
                full = await one
                await findWhereLeftOff(client)
                // Open on that episode's season rather than the first.
                season = resumeAt?.episode.seasonId ?? seasons.first?.id
            }
            // What was watched moves Continue and the progress bars on.
            .task(id: state.videoRevision) {
                guard state.videoRevision > 0, let client = state.client, !seasons.isEmpty else { return }
                await findWhereLeftOff(client)
                episodes = (try? await client.episodes(of: series.id, season: season)) ?? episodes
            }
            .task(id: season) {
                guard let client = state.client else { return }
                episodes = (try? await client.episodes(of: series.id, season: season)) ?? []
            }
    }

    #if os(macOS)
    /// Personality v1, as Flutter's VideoPage: the detail header with the poster and where you
    /// left off, the overview, then the seasons as chips over the chosen season's episodes.
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CxDetailHeader(label: "TV Show", title: show.name ?? "", artId: series.id, aspect: 2.0 / 3.0,
                               meta: videoFacts(show), voice: show.taglines?.first) {
                    if let resumeAt {
                        PillButton(continueTitle(resumeAt.episode, resumeAt.startTicks), symbol: "play.fill", primary: true) {
                            Task { await playFromHere(resumeAt.episode, startTicks: resumeAt.startTicks) }
                        }
                    }
                    CxLikeButton(item: show)
                    VideoDownloadButton(item: series, kind: .series)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if let overview = show.overview { CxOverview(text: overview).padding(.bottom, 12) }
                    FollowSeriesToggle(seriesId: series.id)
                    HStack(spacing: 8) {
                        if seasons.count > 1 {
                            ForEach(seasons) { s in
                                CxChip(title: s.name ?? "Season", on: s.id == season) { season = s.id }
                            }
                        } else if let only = seasons.first {
                            Text(only.name ?? "Season").cx(.section).foregroundStyle(Cx.text)
                        }
                        Spacer(minLength: 0)
                        if let current = seasons.first(where: { $0.id == season }) {
                            VideoDownloadButton(item: seasonItem(current), kind: .season)
                        }
                    }
                    .padding(.top, 24).padding(.bottom, 12)
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                            MacEpisodeRow(episode: episode, played: episode.userData?.played == true) {
                                Task { await state.playVideo(episodes, startIndex: index) }
                            }
                        }
                    }
                }
                .cxPage(top: 0)
            }
        }
    }
    #else
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VideoHeader(item: series)
                if let resumeAt {
                    Button {
                        Task { await playFromHere(resumeAt.episode, startTicks: resumeAt.startTicks) }
                    } label: {
                        Label(continueTitle(resumeAt.episode, resumeAt.startTicks), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }
                if let overview = series.overview { Text(overview).padding(.horizontal) }
                VStack(alignment: .leading, spacing: 8) {
                    VideoDownloadButton(item: series, kind: .series)
                    FollowSeriesToggle(seriesId: series.id)
                }
                .padding(.horizontal)
                HStack {
                    if seasons.count > 1 {
                        Picker("Season", selection: $season) {
                            ForEach(seasons) { Text($0.name ?? "Season").tag(Optional($0.id)) }
                        }
                        .pickerStyle(.menu)
                    }
                    if let current = seasons.first(where: { $0.id == season }) {
                        VideoDownloadButton(item: seasonItem(current), kind: .season)
                    }
                }
                .padding(.horizontal)
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                        HStack(alignment: .top) {
                            Button {
                                Task { await state.playVideo(episodes, startIndex: index) }
                            } label: {
                                EpisodeRow(episode: episode, played: episode.userData?.played == true)
                            }
                            .buttonStyle(.plain)
                            VideoDownloadButton(item: episode, kind: .episode, compact: true)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    #endif

    /// A season knows its show, for the season's download.
    private func seasonItem(_ season: JfItem) -> JfItem {
        var s = season
        s.seriesId = series.id
        s.seriesName = series.name
        return s
    }

    /// The episode watched last, resumed, or the one after it. Jellyfin's Next Up only finds
    /// the next unwatched episode, so on a rewatch it showed nothing or the wrong one.
    private func findWhereLeftOff(_ client: JellyfinClient) async {
        guard let all = try? await client.episodes(of: series.id) else { return }
        resumeAt = continueEpisode(all).map { (all[$0.index], $0.startTicks) }
    }

    private func continueTitle(_ episode: JfItem, _ startTicks: Int) -> String {
        let code = VideoPlayback.episodeCode(episode) ?? episode.name ?? "Episode"
        return startTicks > 0 ? "Resume \(code) at \(clock(seconds(fromTicks: startTicks)))" : "Continue with \(code)"
    }

    /// Its whole season becomes the queue, as a tap on the episode does, so it rolls on.
    private func playFromHere(_ episode: JfItem, startTicks: Int) async {
        guard let client = state.client,
              let season = try? await client.episodes(of: series.id, season: episode.seasonId),
              let index = season.firstIndex(where: { $0.id == episode.id }) else { return }
        await state.playVideo(season, startIndex: index, startTicks: startTicks)
    }
}

private struct EpisodeRow: View {
    let episode: JfItem
    /// Apart from `episode` for the reason WatchedBar gives.
    let played: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtworkView(itemId: episode.id, size: stillWidth * 0.6, aspect: 16.0 / 9.0)
                .overlay(alignment: .bottom) { WatchedBar(item: episode) }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text([VideoPlayback.episodeCode(episode), episode.name].compactMap { $0 }.joined(separator: "  "))
                        .scaledFont(.headline).lineLimit(2)
                    if played {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                            .accessibilityLabel("Watched")
                    }
                }
                if let overview = episode.overview {
                    Text(overview).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if let ticks = episode.runTimeTicks, seconds(fromTicks: ticks) >= 60 {
                    Text("\(Int(seconds(fromTicks: ticks) / 60)) min").scaledFont(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// The backdrop with the title and facts under it.
private struct VideoHeader: View {
    let item: JfItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.backdropImageTags?.isEmpty == false {
                ArtworkView(itemId: item.id, size: 800, fillsFrame: true, aspect: 16.0 / 9.0, imageType: "Backdrop")
                    .frame(maxWidth: .infinity)
            }
            Text(item.name ?? "").font(.title.bold()).padding(.horizontal)
            Text(videoFacts(item)).scaledFont(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
        }
    }
}

/// Year, rating, length and score: "2002 · PG · 161 min · 7.2".
func videoFacts(_ item: JfItem) -> String {
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        if let rating = item.officialRating { parts.append(rating) }
        if let ticks = item.runTimeTicks, seconds(fromTicks: ticks) >= 60 {
            parts.append("\(Int(seconds(fromTicks: ticks) / 60)) min")
        }
        if let score = item.communityRating { parts.append(String(format: "%.1f", score)) }
        return parts.joined(separator: " \u{00b7} ")
}

/// Play or resume, from the start, and which audio track.
private struct PlayButtons: View {
    let item: JfItem
    /// Passed in rather than read off `item`, for the reason WatchedBar gives.
    let started: Bool
    @Binding var audioIndex: Int?
    let play: (_ resume: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { play(true) } label: {
                    Label(started ? "Resume" : "Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                if started {
                    Button { play(false) } label: {
                        Label("From the Start", systemImage: "backward.end.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }
            let tracks = VideoPlayback.audioTracks(item)
            if tracks.count > 1 {
                HStack {
                    Text("Audio").foregroundStyle(.secondary)
                    Picker("Audio", selection: $audioIndex) {
                        Text("Default").tag(Int?.none)
                        ForEach(tracks, id: \.index) { Text($0.displayTitle ?? $0.language ?? "Track").tag($0.index) }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .padding(.horizontal)
    }
}

#if os(macOS)
/// A movie's or show's overview, in the page's secondary text at a reading width.
private struct CxOverview: View {
    let text: String
    var body: some View {
        Text(text).cx(.regular).foregroundStyle(Cx.text2).lineSpacing(4)
            .frame(maxWidth: 760, alignment: .leading)
            .textSelection(.enabled)
    }
}

/// Which audio track a movie plays with, when it has more than one.
private struct AudioTrackPicker: View {
    let item: JfItem
    @Binding var audioIndex: Int?

    var body: some View {
        let tracks = VideoPlayback.audioTracks(item)
        if tracks.count > 1 {
            HStack(spacing: 10) {
                Text("Audio").cx(.small).foregroundStyle(Cx.text2)
                Picker("Audio", selection: $audioIndex) {
                    Text("Default").tag(Int?.none)
                    ForEach(tracks, id: \.index) { Text($0.displayTitle ?? $0.language ?? "Track").tag($0.index) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
        }
    }
}

/// An episode (Flutter's episode row, with the Mac's still kept): the still with what was
/// watched, the code and name, two lines of its overview, the length, and a mark once watched.
private struct MacEpisodeRow: View {
    let episode: JfItem
    /// Apart from `episode` for the reason WatchedBar gives.
    let played: Bool
    let play: () -> Void
    @Environment(\.uiScale) private var zoom
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 14 * zoom) {
            Button(action: play) {
                HStack(alignment: .center, spacing: 14 * zoom) {
                    ArtworkView(itemId: episode.id, size: 160, aspect: 16.0 / 9.0)
                        .overlay(alignment: .bottom) { WatchedBar(item: episode) }
                        .overlay { if hovering { PlayMarkOverlay() } }
                    VStack(alignment: .leading, spacing: 3) {
                        Text([VideoPlayback.episodeCode(episode), episode.name].compactMap { $0 }.joined(separator: "  "))
                            .cx(.row).foregroundStyle(hovering ? Cx.accent : Cx.text).lineLimit(1)
                        if let overview = episode.overview {
                            Text(overview).cx(.small).foregroundStyle(Cx.text3).lineLimit(2)
                        }
                        if let ticks = episode.runTimeTicks, seconds(fromTicks: ticks) >= 60 {
                            Text("\(Int(seconds(fromTicks: ticks) / 60)) min").cx(.small).foregroundStyle(Cx.text3)
                        }
                    }
                    Spacer(minLength: 8)
                    if played {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Cx.accent)
                            .accessibilityLabel("Watched")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VideoDownloadButton(item: episode, kind: .episode, compact: true)
        }
        .padding(10 * zoom)
        .background(hovering ? Cx.line : .clear, in: RoundedRectangle(cornerRadius: 10))
        .onHover { on in withAnimation(.easeOut(duration: on ? 0.12 : 0.2)) { hovering = on } }
    }
}
#endif
