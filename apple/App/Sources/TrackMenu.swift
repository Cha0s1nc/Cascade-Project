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

/// Grouped in sections so a new entry is one more Button in the right group.
/// "Add to Playlist..." belongs in the second one, next to Favorite.
private struct TrackContextMenu: ViewModifier {
    let track: JfItem
    @Environment(AppState.self) private var state
    @Environment(\.openItem) private var openItem
    /// Local, because the row's item is a snapshot the server's answer does
    /// not update. Nil until toggled here.
    @State private var favorite: Bool?

    private var isFavorite: Bool { favorite ?? track.userData?.isFavorite ?? false }
    private var artist: JfNameId? { track.albumArtists?.first ?? track.artistItems?.first }

    func body(content: Content) -> some View {
        content.contextMenu {
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
            }
            Section {
                Button(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.slash" : "heart") {
                    toggleFavorite()
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

    /// Fetched rather than built from the track's album name and id: the
    /// album and artist pages read fields a track does not carry.
    private func go(to id: String) {
        guard let client = state.client, let openItem else { return }
        Task {
            if let item = try? await client.item(id: id) { openItem(item) }
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
