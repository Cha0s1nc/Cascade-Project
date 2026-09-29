import Foundation

// Jellyfin shapes, hand-written to cover only the fields Cascade actually
// reads. Deliberately not generated from the server's OpenAPI schema: that
// produces thousands of lines describing a surface this app never touches.
// If you start using a new field, add it here.
//
// The wire is PascalCase; these are Swift-cased. See JSON.swift for the one
// rule that bridges them, and use JSON.decoder/JSON.encoder for anything on
// this file's types.

public struct JfUserData: Codable, Sendable {
    public var playCount: Int?
    public var lastPlayedDate: String?
    public var isFavorite: Bool?
    /// Where the user stopped, in ticks. Jellyfin fills this from the
    /// PositionTicks we report.
    public var playbackPositionTicks: Int?
    public var played: Bool?

    public init(playbackPositionTicks: Int? = nil, played: Bool? = nil, isFavorite: Bool? = nil,
                playCount: Int? = nil) {
        self.playCount = playCount
        self.playbackPositionTicks = playbackPositionTicks
        self.played = played
        self.isFavorite = isFavorite
    }
}

/// One track inside a media source.
public struct JfMediaStream: Codable, Sendable {
    /// "Audio", "Video", "Subtitle".
    public var type: String?
    public var index: Int?
    public var codec: String?
    public var language: String?
    public var displayTitle: String?
    public var isDefault: Bool?
}

public struct JfImageTags: Codable, Sendable {
    public var primary: String?
}

public struct JfMediaSourceRef: Codable, Sendable {
    public var id: String?
    public var container: String?
    /// Bits per second. How mergeLibraryCopies picks between two copies of a
    /// song, so it is only asked for when more than one library is browsed.
    public var bitrate: Int?
}

/// A track, album, artist or playlist. Jellyfin returns one shape for all of
/// them with different fields populated, hence almost everything optional.
public struct JfItem: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String?

    /// "Audio", "MusicAlbum", "MusicArtist", "Playlist". The only thing
    /// separating a song from a movie.
    public var type: String?
    public var mediaType: String?

    public var album: String?
    public var albumId: String?
    public var albumArtist: String?
    public var artists: [String]?

    /// Art tags. Presence means art exists; the value is not used in image URLs.
    public var albumPrimaryImageTag: String?
    public var imageTags: JfImageTags?

    /// Duration in ticks (100-nanosecond units).
    public var runTimeTicks: Int?
    public var dateCreated: String?
    public var indexNumber: Int?
    /// Disc number on a track. An album with no discs reported leaves this nil,
    /// which sorts ahead of anything explicitly numbered.
    public var parentIndexNumber: Int?
    public var productionYear: Int?
    /// Only sent when asked for (Fields=Genres).
    public var genres: [String]?
    /// Jellyfin's loudness scan, in dB: on a single item (not in lists), and
    /// on far fewer albums than tracks.
    public var normalizationGain: Double?
    public var childCount: Int?
    /// An artist's biography or an album's notes. Only sent for a single item
    /// (or a list asked for Fields=Overview).
    public var overview: String?

    /// Only on library views (/UserViews) - "music", "movies", etc.
    public var collectionType: String?

    /// Populated with Fields=MediaStreams.
    public var mediaStreams: [JfMediaStream]?
    public var mediaSources: [JfMediaSourceRef]?

    public var userData: JfUserData?

    /// Which selected library this came from, by position. Set by
    /// itemsAcrossLibraries, never sent by the server; mergeLibraryCopies only
    /// merges copies from different libraries.
    public var sourceLibrary: Int?

    /// The name Jellyfin sorts by ("Killers, The"), with Fields=SortName.
    public var sortName: String?

    /// Which entry of a playlist this is, on /Playlists/{id}/Items. The id to
    /// remove or move by. Jellyfin 10.11 sets it to the track's own id and
    /// refuses to add a track twice; use `entryId`, which falls back to `id`.
    public var playlistItemId: String?
    /// Artists with their ids, which Go to Artist needs; `artists` is names
    /// only. Both come back on track lists without asking.
    public var artistItems: [JfNameId]?
    public var albumArtists: [JfNameId]?

    public init(id: String, name: String? = nil, type: String? = nil,
                runTimeTicks: Int? = nil, userData: JfUserData? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.runTimeTicks = runTimeTicks
        self.userData = userData
    }

    // Identity is the id alone, not every field. Two fetches of the same track
    // differ in whatever fields each query asked for, and SwiftUI navigation
    // needs them to be the same item. Hashable rather than only Equatable so
    // navigationDestination(for:) and NavigationPath can carry one.
    public static func == (a: JfItem, b: JfItem) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A name with the id it refers to, as Jellyfin nests artists in an item.
public struct JfNameId: Codable, Sendable, Hashable {
    public var id: String
    public var name: String?
}

/// Standard envelope for Jellyfin list endpoints.
public struct JfItemsResponse: Codable, Sendable {
    public var items: [JfItem]?
    public var totalRecordCount: Int?
}

public struct JfAuthUser: Codable, Sendable {
    public var id: String
    public var name: String?
}

public struct JfAuthResult: Codable, Sendable {
    public var accessToken: String
    public var user: JfAuthUser
}

/// Connection state. `libraryIds` narrows every query to the user's chosen
/// music libraries; empty means "the whole server".
public struct ServerConfig: Sendable, Equatable {
    public var url: String
    public var token: String
    public var userId: String
    public var libraryIds: [String]
    /// Must be unique per install. A constant here makes every Cascade look
    /// like the same device to the server, so remote control cannot target one
    /// of them and two instances collide in the session list.
    public var deviceId: String

    public init(url: String, token: String, userId: String,
                libraryIds: [String] = [], deviceId: String) {
        // A trailing slash turns every path into a double slash, which some
        // reverse proxies answer with a redirect that drops the auth header.
        self.url = url.hasSuffix("/") ? String(url.dropLast()) : url
        self.token = token
        self.userId = userId
        self.libraryIds = libraryIds
        self.deviceId = deviceId
    }
}
