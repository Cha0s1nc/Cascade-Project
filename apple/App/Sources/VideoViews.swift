import SwiftUI
import CascadeKit

// Movies and shows: the desktop's video browsing. Tapping a movie or show
// opens its page; tapping an episode or Play starts Apple's player.

#if os(tvOS)
private let posterWidth: CGFloat = 200
private let stillWidth: CGFloat = 360
#else
private let posterWidth: CGFloat = 120
private let stillWidth: CGFloat = 240
#endif

/// Video's Home: pick up where you left off, the next episode of each show,
/// and what is new.
struct VideoHomeView: View {
    @Environment(AppState.self) private var state
    @State private var resume: [JfItem] = []
    @State private var nextUp: [JfItem] = []
    @State private var movies: [JfItem] = []
    @State private var episodes: [JfItem] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !resume.isEmpty { stills("Continue Watching", resume) }
                if !nextUp.isEmpty { stills("Next Up", nextUp) }
                if !movies.isEmpty { posters("Recently Added Movies", movies) }
                if !episodes.isEmpty { stills("Recently Added Episodes", episodes) }
                if loaded, resume.isEmpty, nextUp.isEmpty, movies.isEmpty, episodes.isEmpty {
                    ContentUnavailableView("No Videos", systemImage: "film",
                                           description: Text(error ?? "This server has no movies or shows you can see."))
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Home")
        .refreshable { await load() }
        .task { if !loaded { await load() } }
        .onChange(of: state.videoRevision) { Task { await load() } }
    }

    private func load() async {
        guard let client = state.client else { return }
        async let r = client.continueWatching()
        async let n = client.nextUp()
        async let m = client.latestVideo("Movie")
        async let e = client.latestVideo("Episode")
        do {
            (resume, nextUp, movies, episodes) = try await (r, n, m, e)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func stills(_ title: String, _ items: [JfItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { VideoStillTile(item: $0) }
                }
                .padding(.horizontal)
            }
        }
    }

    private func posters(_ title: String, _ items: [JfItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { PosterTile(item: $0) }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// All movies or all shows, as a poster grid.
struct VideoGridView: View {
    enum Kind { case movies, shows }
    let kind: Kind
    @Environment(AppState.self) private var state
    @State private var items: [JfItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: posterWidth), spacing: 16)], spacing: 20) {
                ForEach(items) { PosterTile(item: $0) }
            }
            .padding()
            if items.isEmpty {
                LoadingOverlay(isLoading: loading, error: error, isEmpty: true)
            }
        }
        .navigationTitle(kind == .movies ? "Movies" : "Shows")
        .refreshable { await load() }
        .task { if items.isEmpty { await load() } }
    }

    private func load() async {
        guard let client = state.client else { return }
        do {
            items = kind == .movies ? try await client.movies() : try await client.shows()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// A movie or show: its poster and name, opening its page.
struct PosterTile: View {
    let item: JfItem

    var body: some View {
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 4) {
                ArtworkView(itemId: item.id, size: posterWidth, aspect: 2.0 / 3.0)
                    .overlay(alignment: .bottom) { WatchedBar(item: item) }
                Text(item.name ?? "Untitled").font(.caption).lineLimit(1)
                if let year = item.productionYear {
                    Text(String(year)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: posterWidth)
        }
        .buttonStyle(.plain)
    }
}

/// An episode or a movie to resume, as a 16:9 still that plays at once.
struct VideoStillTile: View {
    let item: JfItem
    @Environment(AppState.self) private var state

    var body: some View {
        Button {
            Task { await state.playVideoItem(item) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ArtworkView(itemId: item.id, size: stillWidth, aspect: 16.0 / 9.0)
                    .overlay(alignment: .bottom) { WatchedBar(item: item) }
                Text(item.seriesName ?? item.name ?? "Untitled").font(.caption).lineLimit(1)
                if item.type == "Episode" {
                    Text([VideoPlayback.episodeCode(item), item.name].compactMap { $0 }.joined(separator: " \u{00b7} "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: stillWidth)
        }
        .buttonStyle(.plain)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VideoHeader(item: item)
                PlayButtons(item: item, started: resumeTicks(for: item) > 0, audioIndex: $audioIndex) { resume in
                    Task { await state.playVideo([item], audioStreamIndex: audioIndex, resume: resume) }
                }
                if let overview = item.overview { Text(overview).padding(.horizontal) }
            }
            .padding(.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
}

/// A show: its seasons, and each season's episodes.
struct SeriesDetailView: View {
    let series: JfItem
    @Environment(AppState.self) private var state
    @State private var seasons: [JfItem] = []
    @State private var season: String?
    @State private var episodes: [JfItem] = []
    @State private var next: JfItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VideoHeader(item: series)
                if let next {
                    Button {
                        Task { await state.playVideoItem(next) }
                    } label: {
                        Label("\(nextStarted ? "Resume" : "Play") \(VideoPlayback.episodeCode(next) ?? "")", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }
                if let overview = series.overview { Text(overview).padding(.horizontal) }
                if seasons.count > 1 {
                    Picker("Season", selection: $season) {
                        ForEach(seasons) { Text($0.name ?? "Season").tag(Optional($0.id)) }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal)
                }
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                        Button {
                            Task { await state.playVideo(episodes, startIndex: index) }
                        } label: {
                            EpisodeRow(episode: episode, played: episode.userData?.played == true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(series.name ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            guard let client = state.client, seasons.isEmpty else { return }
            seasons = (try? await client.seasons(of: series.id)) ?? []
            next = try? await client.nextUp(seriesId: series.id, limit: 1).first
            season = next?.seasonId ?? seasons.first?.id
        }
        // What was watched moves Next Up and the progress bars on.
        .task(id: state.videoRevision) {
            guard state.videoRevision > 0, let client = state.client, !seasons.isEmpty else { return }
            next = try? await client.nextUp(seriesId: series.id, limit: 1).first
            episodes = (try? await client.episodes(of: series.id, season: season)) ?? episodes
        }
        .task(id: season) {
            guard let client = state.client else { return }
            episodes = (try? await client.episodes(of: series.id, season: season)) ?? []
        }
    }

    private var nextStarted: Bool { (next?.userData?.playbackPositionTicks ?? 0) > 0 }
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
                        .font(.headline).lineLimit(2)
                    if played {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                            .accessibilityLabel("Watched")
                    }
                }
                if let overview = episode.overview {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                if let ticks = episode.runTimeTicks, seconds(fromTicks: ticks) >= 60 {
                    Text("\(Int(seconds(fromTicks: ticks) / 60)) min").font(.caption2).foregroundStyle(.secondary)
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
            Text(facts).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
        }
    }

    private var facts: String {
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        if let rating = item.officialRating { parts.append(rating) }
        if let ticks = item.runTimeTicks, seconds(fromTicks: ticks) >= 60 {
            parts.append("\(Int(seconds(fromTicks: ticks) / 60)) min")
        }
        if let score = item.communityRating { parts.append(String(format: "%.1f", score)) }
        return parts.joined(separator: " \u{00b7} ")
    }
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
