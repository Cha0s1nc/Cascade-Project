// Jellyfin shapes, hand-written to cover only the fields Cascade actually reads.
//
// Deliberately not generated from Jellyfin's OpenAPI schema: that produces
// thousands of lines describing a surface this app never touches. If you start
// using a new field, add it here.

export interface JfUserData {
  PlayCount?: number
  LastPlayedDate?: string
  IsFavorite?: boolean
  /** Where the user stopped, in ticks. Non-zero means "offer to resume".
   *  Jellyfin fills this from the PositionTicks we already report. */
  PlaybackPositionTicks?: number
  Played?: boolean
}

/** One track inside a media source - video, audio or subtitle. */
export interface JfMediaStream {
  Type?: string
  /** Index within the media source; the id used in subtitle stream URLs. */
  Index?: number
  Codec?: string
  Language?: string
  DisplayTitle?: string
  IsDefault?: boolean
  IsForced?: boolean
  /** False for bitmap subtitles (PGS, VOBSUB), which a <track> cannot render. */
  IsTextSubtitleStream?: boolean
}

/** A track, album, artist, or playlist. Jellyfin returns one shape for all of
 *  them, with different fields populated - hence almost everything optional. */
export interface JfItem {
  Id: string
  Name?: string

  /** 'Audio' | 'MusicAlbum' | 'MusicArtist' | 'Playlist' | 'Movie' | 'Series'
   *  | 'Season' | 'Episode'. The only thing separating a song from a movie. */
  Type?: string
  /** 'Audio' | 'Video'. Present on playable items; Type is more reliable. */
  MediaType?: string

  Album?: string
  AlbumId?: string
  AlbumArtist?: string
  Artists?: string[]

  /** Art tags. Presence means art exists; the value is not used in image URLs. */
  AlbumPrimaryImageTag?: string
  ImageTags?: { Primary?: string }

  /** Duration in ticks (100-nanosecond units). */
  RunTimeTicks?: number
  DateCreated?: string
  IndexNumber?: number
  ProductionYear?: number

  /** Number of tracks, on album/playlist items. */
  ChildCount?: number

  // ── Video ──
  /** Plot synopsis, on movies and episodes. Needs Fields=Overview. */
  Overview?: string
  /** Episodes only: the series and season they belong to. */
  SeriesName?: string
  SeriesId?: string
  /** The series' own poster tag, present on an episode with Fields=SeriesPrimaryImageTag.
   *  Used to show the series' art instead of the episode's own thumbnail. */
  SeriesPrimaryImageTag?: string
  SeasonName?: string
  SeasonId?: string
  /** Season number on an episode; IndexNumber is the episode number. */
  ParentIndexNumber?: number
  /** Populated with Fields=MediaStreams. Drives subtitle track selection. */
  MediaStreams?: JfMediaStream[]
  MediaSources?: { Id?: string, Container?: string }[]

  /** Only on library views (/Users/{id}/Views) - 'music', 'musicvideos', etc.
   *  Used to filter the library picker down to music libraries. */
  CollectionType?: string

  /** Only present on items fetched as part of a playlist; needed to remove the
   *  right entry when the same track appears twice. */
  PlaylistItemId?: string

  /** Playlists only. Whether the playlist is visible to other users. */
  IsPublic?: boolean

  /** Whether the requesting user is allowed to delete this item - the closest
   *  thing Jellyfin exposes to "do you own this". Used to gate Edit Playlist:
   *  explicit `false` hides the controls, `true` or absent (older servers)
   *  offers them and lets the write fail loudly if the server disagrees. */
  CanDelete?: boolean

  UserData?: JfUserData
}

/** Standard envelope for Jellyfin list endpoints. */
export interface JfItemsResponse {
  Items?: JfItem[]
  TotalRecordCount?: number
}

export interface JfAuthResult {
  AccessToken: string
  User: { Id: string, Name?: string }
}

/** Connection state. `libraryIds` narrows every query to the user's chosen
 *  music libraries; empty or absent means "the whole server". */
export interface ServerConfig {
  url: string
  token: string
  userId: string
  libraryIds?: string[]
  /** Movie and TV libraries, kept separate from each other (so a movie query
   *  never fans out across TV libraries or vice versa) and from `libraryIds`
   *  (so a music query never touches either). Passed explicitly to getMerged
   *  by the video views. */
  movieLibraryIds?: string[]
  showLibraryIds?: string[]
  /** Unique per install. Jellyfin uses it to tell clients apart, which remote
   *  control depends on. See authHeader() in jellyfin.ts. */
  deviceId?: string
  /** Reported to Jellyfin on every request so the dashboard's device list keeps
   *  up. See JellyfinClient.headers(). */
  appVersion?: string
}

/** Query parameters for a Jellyfin request. Values are stringified by the client. */
export type JfParams = Record<string, string | number | boolean | undefined>
