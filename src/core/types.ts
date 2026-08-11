// Jellyfin shapes, hand-written to cover only the fields Cascade actually reads.
//
// Deliberately not generated from Jellyfin's OpenAPI schema: that produces
// thousands of lines describing a surface this app never touches. If you start
// using a new field, add it here.

export interface JfUserData {
  PlayCount?: number
  LastPlayedDate?: string
  IsFavorite?: boolean
}

/** A track, album, artist, or playlist. Jellyfin returns one shape for all of
 *  them, with different fields populated - hence almost everything optional. */
export interface JfItem {
  Id: string
  Name?: string

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

  /** Only on library views (/Users/{id}/Views) - 'music', 'musicvideos', etc.
   *  Used to filter the library picker down to music libraries. */
  CollectionType?: string

  /** Only present on items fetched as part of a playlist; needed to remove the
   *  right entry when the same track appears twice. */
  PlaylistItemId?: string

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
  /** Unique per install. Jellyfin uses it to tell clients apart, which remote
   *  control depends on. See authHeader() in jellyfin.ts. */
  deviceId?: string
}

/** Query parameters for a Jellyfin request. Values are stringified by the client. */
export type JfParams = Record<string, string | number | boolean | undefined>
