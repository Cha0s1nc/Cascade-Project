import Foundation

/// Which rows a right-click menu shows for each kind of card
/// (src/core/context-menu.ts menuItemsForKind), a flat table because six
/// kinds with mostly disjoint action sets is a lookup, not an abstraction.
public enum MenuItemKind: Sendable {
    /// A standalone movie or an episode: playable, with its own played state.
    case video
    case album, artist, series, playlist, smartPlaylist, userSmartPlaylist
}

public struct MenuItemVisibility: Sendable, Equatable {
    public var play = false, playNext = false, playLast = false, shuffle = false, instantMix = false
    public var addPlaylist = false, download = false, favorite = false
    public var markPlayed = false, markUnplayed = false
    public var goArtist = false, viewDetail = false
    public var rename = false, deleteItem = false, refreshMeta = false, editMeta = false

    public init() {}
}

public func menuItems(for kind: MenuItemKind, isPlayed: Bool? = nil) -> MenuItemVisibility {
    var v = MenuItemVisibility()
    switch kind {
    case .album:
        (v.play, v.playNext, v.playLast, v.shuffle, v.instantMix) = (true, true, true, true, true)
        (v.addPlaylist, v.download, v.favorite, v.goArtist, v.refreshMeta, v.editMeta) = (true, true, true, true, true, true)
    case .artist:
        (v.play, v.playNext, v.playLast, v.shuffle, v.instantMix) = (true, true, true, true, true)
        (v.addPlaylist, v.favorite, v.viewDetail) = (true, true, true)
    case .video:
        // No known played state hides both rows rather than guessing.
        (v.play, v.viewDetail) = (true, true)
        v.markPlayed = isPlayed == false
        v.markUnplayed = isPlayed == true
    case .series:
        // A container: nothing of its own to play.
        v.viewDetail = true
        v.markPlayed = isPlayed == false
        v.markUnplayed = isPlayed == true
    case .playlist:
        (v.play, v.playNext, v.playLast, v.shuffle, v.addPlaylist) = (true, true, true, true, true)
        (v.rename, v.deleteItem) = (true, true)
    case .smartPlaylist:
        (v.play, v.playNext, v.playLast, v.shuffle, v.addPlaylist) = (true, true, true, true, true)
    case .userSmartPlaylist:
        // Rename and delete become Edit Rules and Delete: a local definition,
        // never gated on the server's delete right the way a real playlist is.
        (v.play, v.playNext, v.playLast, v.shuffle, v.addPlaylist) = (true, true, true, true, true)
        (v.rename, v.deleteItem) = (true, true)
    }
    return v
}
