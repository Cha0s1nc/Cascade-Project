import SwiftUI
import CascadeKit

/// Push a library item onto the current tab's stack. Set by TabStack; nil
/// where there is no stack to push onto (the Now Playing sheet, the tvOS
/// Now Playing tab), and the Go to entries hide there.
extension EnvironmentValues {
    @Entry var openItem: ((JfItem) -> Void)? = nil
}

extension View {
    /// The long-press menu for a track, the same everywhere a track is listed.
    func trackContextMenu(_ track: JfItem) -> some View {
        modifier(TrackContextMenu(track: track))
    }
}

/// The long-press menu on a track row: TrackMenuItems, plus the state and the
/// Add to Playlist sheet those items need.
private struct TrackContextMenu: ViewModifier {
    let track: JfItem
    @Environment(AppState.self) private var state
    /// Local, because the row's item is a snapshot the server's answer does
    /// not update. Nil until toggled here.
    @State private var favorite: Bool?
    @State private var played: Bool?
    @State private var addingToPlaylist = false

    func body(content: Content) -> some View {
        content.contextMenu {
            TrackMenuItems(track: track, favorite: $favorite, played: $played,
                           addingToPlaylist: $addingToPlaylist)
        }
        // Passed explicitly: a sheet is its own presentation, and the picker
        // reads the client from AppState.
        .sheet(isPresented: $addingToPlaylist) {
            AddToPlaylistSheet(track: track).environment(state)
        }
    }
}

/// A track's actions, shared by the row long-press menu and Now Playing's ···
/// menu so the two cannot drift apart. Grouped in sections so a new entry is
/// one more Button in the right group. The caller owns the state (so Now
/// Playing's heart and this menu's Favorite agree) and presents the Add to
/// Playlist sheet, which cannot live inside a menu.
struct TrackMenuItems: View {
    let track: JfItem
    /// Overrides of the track's snapshot, nil until toggled.
    @Binding var favorite: Bool?
    @Binding var played: Bool?
    @Binding var addingToPlaylist: Bool
    @Environment(AppState.self) private var state
    @Environment(\.openItem) private var openItem

    private var isFavorite: Bool { favorite ?? track.userData?.isFavorite ?? false }
    private var isPlayed: Bool { played ?? track.userData?.played ?? false }
    private var artist: JfNameId? { track.albumArtists?.first ?? track.artistItems?.first }

    var body: some View {
        Section {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                Task { await state.player?.playNext([track]) }
            }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                Task { await state.player?.addToQueue([track]) }
            }
            Button("Instant Mix", systemImage: "wand.and.stars") {
                Task { await state.player?.playInstantMix(from: track.id) }
            }
            // Picked in Control Devices; the desktop's "Play on <device>".
            if let device = state.controlledDevice {
                Button("Play on \(device.name)", systemImage: "hifispeaker") {
                    Task { try? await state.client?.play([track.id], on: device.id) }
                }
            }
        }
        Section {
            Button(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.slash" : "heart") {
                toggleFavorite()
            }
            Button(isPlayed ? "Mark as Unplayed" : "Mark as Played",
                   systemImage: isPlayed ? "circle" : "checkmark.circle") {
                togglePlayed()
            }
            Button("Add to Playlist…", systemImage: "text.badge.plus") {
                addingToPlaylist = true
            }
        }
        if openItem != nil {
            Section {
                if let albumId = track.albumId {
                    Button("Go to Album", systemImage: "square.stack") { go(to: albumId) }
                }
                if let artist {
                    Button("Go to Artist", systemImage: "music.mic") { go(to: artist.id) }
                }
            }
        }
    }

    /// Flips only once the server has accepted it (CODEMAP rule 1).
    private func toggleFavorite() {
        guard let client = state.client else { return }
        let target = !isFavorite
        Task {
            do {
                try await client.setFavorite(target, itemId: track.id)
                favorite = target
            } catch {}
        }
    }

    /// Same rule as the favorite: only once the server has said yes.
    private func togglePlayed() {
        guard let client = state.client else { return }
        let target = !isPlayed
        Task {
            do {
                try await client.setPlayed(target, itemId: track.id)
                played = target
            } catch {}
        }
    }

    /// Fetched rather than built from the track's album name and id: the
    /// album and artist pages read fields a track does not carry.
    private func go(to id: String) {
        guard let client = state.client, let openItem else { return }
        Task {
            if let item = try? await client.item(id: id) { openItem(item) }
        }
    }
}

extension View {
    /// The long-press menu for an album, artist or playlist tile, the desktop's
    /// card menu (src/core/context-menu.ts): play it, queue it, mix from it,
    /// favorite it, add it to a playlist, go to its artist.
    func itemContextMenu(_ item: JfItem) -> some View {
        modifier(ItemContextMenu(item: item))
    }
}

private struct ItemContextMenu: ViewModifier {
    let item: JfItem
    @Environment(AppState.self) private var state
    @Environment(\.openItem) private var openItem
    /// Local override of the tile's snapshot, nil until toggled here.
    @State private var favorite: Bool?
    /// The tracks to add, fetched when Add to Playlist is picked; set, the
    /// sheet shows.
    @State private var playlistTracks: [JfItem] = []
    @State private var addingToPlaylist = false

    private var isFavorite: Bool { favorite ?? item.userData?.isFavorite ?? false }
    private var artist: JfNameId? { item.type == "MusicAlbum" ? item.albumArtists?.first : nil }

    func body(content: Content) -> some View {
        content.contextMenu {
            Section {
                Button("Play", systemImage: "play") {
                    withTracks { await state.player?.play($0) }
                }
                Button("Shuffle", systemImage: "shuffle") {
                    withTracks { await playShuffled($0, on: state.player) }
                }
            }
            Section {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    withTracks { await state.player?.playNext($0) }
                }
                Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    withTracks { await state.player?.addToQueue($0) }
                }
                Button("Instant Mix", systemImage: "wand.and.stars") {
                    Task { await state.player?.playInstantMix(from: item.id) }
                }
            }
            Section {
                Button(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.slash" : "heart") {
                    toggleFavorite()
                }
                Button("Add to Playlist\u{2026}", systemImage: "text.badge.plus") {
                    withTracks { tracks in
                        playlistTracks = tracks
                        addingToPlaylist = true
                    }
                }
            }
            if let artist, openItem != nil {
                Button("Go to Artist", systemImage: "music.mic") {
                    guard let client = state.client, let openItem else { return }
                    Task { if let found = try? await client.item(id: artist.id) { openItem(found) } }
                }
            }
        }
        .sheet(isPresented: $addingToPlaylist) {
            AddToPlaylistSheet(tracks: playlistTracks).environment(state)
        }
    }

    /// The tile's songs, fetched when an action needs them: a grid of albums
    /// does not carry its tracks, and fetching them all up front would cost a
    /// request per tile for menus nobody opens.
    private func withTracks(_ action: @escaping @MainActor ([JfItem]) async -> Void) {
        guard let client = state.client else { return }
        Task {
            let tracks: [JfItem]
            switch item.type {
            case "MusicAlbum": tracks = (try? await client.tracks(inAlbum: item.id)) ?? []
            case "MusicArtist": tracks = (try? await client.tracks(byArtist: item.id)) ?? []
            case "Playlist": tracks = (try? await client.tracks(inPlaylist: item.id)) ?? []
            default: tracks = []
            }
            guard !tracks.isEmpty else { return }
            await action(tracks)
        }
    }

    /// Flips only once the server has accepted it (CODEMAP rule 1).
    private func toggleFavorite() {
        guard let client = state.client else { return }
        let target = !isFavorite
        Task {
            do {
                try await client.setFavorite(target, itemId: item.id)
                favorite = target
            } catch {}
        }
    }
}

/// A tab's navigation stack with a path, so the track menu's Go to entries
/// can push onto it.
struct TabStack<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            content
                .libraryToolbar()
                .appNavigation()
        }
        .environment(\.openItem) { path.append($0) }
    }
}
