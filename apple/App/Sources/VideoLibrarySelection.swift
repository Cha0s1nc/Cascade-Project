import SwiftUI
import CascadeKit

/// Which movie and TV libraries the app browses, apart from the music ones
/// (see VideoLibraries in CascadeKit for why they are separate).
///
/// Saved as `cascade.movieLibraryIds` and `cascade.showLibraryIds`, the
/// desktop's keys. A missing key means "never chosen", which is different from
/// an empty list ("chose none"), so the value is read as an optional.
@MainActor @Observable
final class VideoLibrarySelection {
    private static let movieKey = "cascade.movieLibraryIds"
    private static let showKey = "cascade.showLibraryIds"

    private(set) var movieLibraries: [JfItem] = []
    private(set) var showLibraries: [JfItem] = []
    /// False until the first answer from the server, so a screen can tell
    /// "no video libraries" from "not asked yet".
    private(set) var isLoaded = false
    private var savedMovies = UserDefaults.standard.stringArray(forKey: movieKey)
    private var savedShows = UserDefaults.standard.stringArray(forKey: showKey)
    private var loadedFor: String?

    var movieIds: [String] { VideoLibraries.selection(categoryLibs: movieLibraries, saved: savedMovies) }
    var showIds: [String] { VideoLibraries.selection(categoryLibs: showLibraries, saved: savedShows) }
    /// Any movie or TV library at all, chosen or not: the Music / Video switch
    /// has nothing to switch to without one.
    var hasVideoLibrary: Bool { !movieLibraries.isEmpty || !showLibraries.isEmpty }

    /// Asks the server once per sign-in (and again when forced, after a
    /// library was added). A failed ask leaves the last answer in place.
    func load(client: JellyfinClient?, userId: String?, force: Bool = false) async {
        guard let client, let userId else { return }
        if loadedFor == userId, !force { return }
        guard let found = try? await client.videoLibraries() else { return }
        (movieLibraries, showLibraries) = found
        loadedFor = userId
        isLoaded = true
    }

    func setMovieIds(_ ids: [String]) {
        savedMovies = ids
        UserDefaults.standard.set(ids, forKey: Self.movieKey)
    }

    func setShowIds(_ ids: [String]) {
        savedShows = ids
        UserDefaults.standard.set(ids, forKey: Self.showKey)
    }
}
