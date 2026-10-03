import Foundation

// Which sections belong to Music and which to Video, ported from the
// desktop's src/core/browse-mode.ts.
//
// The mode is a browsing filter only: it decides which sidebar sections and
// which Home shelves show. It never touches playback, the queue, or which
// libraries exist on the server.

public enum BrowseModeLogic {
    public enum Mode: String, Sendable { case music, video }

    /// Section names (the desktop's view names) in each mode. Home and
    /// Settings are in neither: they show in both.
    public static let musicSections = ["albums", "artists", "songs", "playlists", "genres", "history", "radio"]
    public static let videoSections = ["movies", "shows"]

    /// The mode a section belongs to, or nil for one shown in both. Used to
    /// switch the mode when something (a search result, View Album, a remote
    /// command) navigates into a section the current mode is hiding, so a
    /// deep link never lands on a section with no sidebar row.
    public static func sectionMode(_ section: String) -> Mode? {
        if musicSections.contains(section) { return .music }
        if videoSections.contains(section) { return .video }
        return nil
    }

    /// The section a library item opens in, for deep links.
    public static func section(forItemType type: String?) -> String? {
        switch type {
        case "MusicAlbum", "Audio": "albums"
        case "MusicArtist": "artists"
        case "Playlist": "playlists"
        case "MusicGenre": "genres"
        case "Movie": "movies"
        case "Series", "Season", "Episode": "shows"
        default: nil
        }
    }

    /// The saved mode against whether a video library is in play right now.
    /// Fresh installs and anything unrecognized are music, and so is any
    /// account with no video library: a library removed after "video" was
    /// saved must not strand a now music-only user on a mode with nothing in
    /// it. The saved value itself is left alone by the caller, so the choice
    /// comes back if a video library is added again.
    public static func resolve(saved: String?, hasVideoLibrary: Bool) -> Mode {
        guard hasVideoLibrary else { return .music }
        return saved == "video" ? .video : .music
    }
}
