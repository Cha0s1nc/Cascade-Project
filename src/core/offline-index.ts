// What is downloaded, as one value: the single source of truth for offline
// playback and, since version 2, for Offline Mode's library (the Apple app's
// lesson, OfflineIndex.swift: one index, not several stores kept in step by
// hand). Pure, so the rules that decide what a removal may delete and what
// counts as a finished download are tested here; offline.js owns the files and
// the one copy on disk. src/core/offline-query.ts answers the screens' requests
// from it.
//
// Paths are relative to the offline folder: an absolute path breaks when
// userData moves, and a relative one is what can be checked for escaping.
//
// Version 2 (docs/offline-mode-plan.md, section 1) keeps version 1's shape and
// adds to it, so a version 1 file reads as is: wider items, video, the library
// each item came from, the user, lyrics, subtitles, media segments and the
// history snapshot. A version 1 file has no `version` and no libraries; its
// items fall into the placeholder libraries until the app is next online.

import type { JfItem, JfNameId } from './types.ts'
import type { LyricLine, LyricWord } from './lyrics.ts'
import type { SpicyCredit, SpicyContributor } from './spicy-lyrics.ts'

export const INDEX_VERSION = 2

/** Lyrics saved with a track, already parsed: the waterfall's answer at
 *  download time. */
export interface OfflineLyrics {
  /** Where they came from: 'cascade', 'spicy', 'kugou', 'lrclib', 'jellyfin'. */
  source: string
  synced: boolean
  lines: LyricLine[]
  /** ISO 8601. */
  savedAt: string
  /** SpicyLyrics are kept no longer than the plugin's own cache may keep them
   *  (SPICY_LYRICS_DAYS); every other source never expires. ISO 8601 or null. */
  expiresAt: string | null
  /** What the lyrics UI must show beside SpicyLyrics lyrics, offline too. */
  credit?: SpicyCredit
}

/** The source a lyrics result is stored under, from the label the waterfall
 *  gives it. A result carrying a credit is SpicyLyrics, whatever its label. */
export function lyricsSourceKey(label: string, hasCredit: boolean): string {
  if (hasCredit) return 'spicy'
  const l = label.toLowerCase()
  if (l.startsWith('kugou')) return 'kugou'
  if (l.startsWith('lrclib')) return 'lrclib'
  if (l.startsWith('jellyfin')) return 'jellyfin'
  return 'cascade'
}

/** How a stored source is named in the lyrics UI. */
export function lyricsSourceLabel(lyrics: OfflineLyrics): string {
  if (lyrics.credit) return lyrics.credit.provider
  return ({ cascade: 'Cascade', kugou: 'Kugou', lrclib: 'LRCLIB', jellyfin: 'Jellyfin' } as Record<string, string>)[lyrics.source] ?? lyrics.source
}

/** An external text subtitle saved beside a video, as WebVTT. */
export interface OfflineSubtitle {
  /** The stream's index in the item's MediaStreams. */
  index: number
  /** "subs/<id>.<index>.vtt". */
  file: string
  language?: string
  title?: string
  isDefault?: boolean
  isForced?: boolean
}

/** One /MediaSegments entry (intro, credits), as the server sent it. */
export interface OfflineSegment {
  Type: string
  StartTicks: number
  EndTicks: number
}

/** A downloaded media item: a track, a movie or an episode. The map is still
 *  called `tracks`, as in version 1, because offline.js and the renderer read
 *  it by that name; it holds every file-backed item. */
export interface OfflineTrack {
  /** The fields its screens read, so playback and Offline Mode work with no
   *  server. See slimItem(). */
  item: JfItem
  /** "media/<id>.<ext>" once the whole file is on disk; null until then. */
  file: string | null
  bytes: number
  /** The library it was downloaded from. Missing for items from a version 1
   *  index, or until the library is looked up: libraryOf() then answers the
   *  placeholder library for its kind. */
  library?: string
  lyrics?: OfflineLyrics
  subs?: OfflineSubtitle[]
  segments?: OfflineSegment[]
  /** The Cascade plugin's explicit flag, so the badge shows offline. */
  explicit?: boolean
}

/** What the person asked for: an album, a playlist, a movie, a season or a
 *  whole series. A track shared by two of them is stored once. */
export interface OfflineCollection {
  item: JfItem
  /** The album's or playlist's own order; a show's episodes in show order. */
  trackIds: string[]
}

/** A library as /UserViews names it. */
export interface OfflineLibraryView {
  Id: string
  Name: string
  CollectionType: string
}

/** The Policy fields the apps read (permissions.ts, radio, downloads). */
export interface OfflinePolicy {
  IsAdministrator?: boolean
  EnableContentDeletion?: boolean
  EnableContentDeletionFromFolders?: string[]
  EnableContentDownloading?: boolean
  EnableLiveTvAccess?: boolean
}

export interface OfflineUser {
  Id: string
  Name: string
  Policy: OfflinePolicy
}

/** One row of the server's play history as it stood. */
export interface HistoryEntry {
  Id: string
  LastPlayedDate: string | null
  PlayCount: number
}

/** The server's play history when the app was last online, newest first: what
 *  reconnecting compares against before replaying offline plays (plan,
 *  section 5). */
export interface HistorySnapshot {
  /** ISO 8601. */
  takenAt: string
  entries: HistoryEntry[]
}

/** A play the server never heard about (its start report failed), to be sent
 *  as /UserPlayedItems/{id}?datePlayed once the server is back. Jellyfin counts
 *  a play when playback STARTS, so that report is the one whose loss loses a
 *  play. `date` is ISO 8601. */
export interface OfflinePlay { itemId: string; userId: string; date: string }

export interface OfflineIndex {
  version: typeof INDEX_VERSION
  tracks: Record<string, OfflineTrack>
  /** Newest first. */
  collections: OfflineCollection[]
  /** Series and seasons the downloaded episodes belong to, by id: the Shows
   *  grid and a show's page list them, and they have no file of their own. */
  containers: Record<string, JfItem>
  /** The libraries downloaded items came from. */
  libraries: OfflineLibraryView[]
  user: OfflineUser | null
  history: HistorySnapshot | null
  plays: OfflinePlay[]
}

export const emptyIndex = (): OfflineIndex => ({
  version: INDEX_VERSION, tracks: {}, collections: [], containers: {}, libraries: [], user: null, history: null, plays: [],
})

/** Most plays kept while offline. A year of listening on a plane is not 5000. */
export const MAX_QUEUED_PLAYS = 5000

/** Rows of play history kept in the snapshot: History and Recently Played
 *  together never show more from the top of the list than this. */
export const MAX_HISTORY_ENTRIES = 200

/** How long SpicyLyrics may be kept: the plugin's own cache rule. */
export const SPICY_LYRICS_DAYS = 25

/** The item types that are files of their own. */
const MEDIA_TYPES = new Set(['Audio', 'Movie', 'Episode'])

/** The item types a collection may be. */
const COLLECTION_TYPES = new Set(['MusicAlbum', 'Playlist', 'Movie', 'Season', 'Series'])

// ── Libraries ────────────────────────────────────────────────────────────────

/** Where items with no known library go: everything from a version 1 index,
 *  and anything downloaded before its library was looked up. One per kind, so
 *  Music and Video still split the way the mode switcher expects. */
export const PLACEHOLDER_LIBRARIES: Readonly<Record<'Audio' | 'Movie' | 'Episode', OfflineLibraryView>> = {
  Audio: { Id: 'cascade-offline-music', Name: 'Downloads', CollectionType: 'music' },
  Movie: { Id: 'cascade-offline-movies', Name: 'Downloaded Movies', CollectionType: 'movies' },
  Episode: { Id: 'cascade-offline-shows', Name: 'Downloaded Shows', CollectionType: 'tvshows' },
}

export const isPlaceholderLibrary = (id: string): boolean =>
  Object.values(PLACEHOLDER_LIBRARIES).some(l => l.Id === id)

/** A library id: a GUID with or without dashes, or a placeholder's. */
export const isSafeLibraryId = (id: unknown): id is string =>
  typeof id === 'string' && /^[A-Za-z0-9-]{1,64}$/.test(id) && !/^-+$/.test(id)

const placeholderFor = (item: JfItem): OfflineLibraryView =>
  item.Type === 'Movie' ? PLACEHOLDER_LIBRARIES.Movie
    : item.Type === 'Episode' ? PLACEHOLDER_LIBRARIES.Episode
      : PLACEHOLDER_LIBRARIES.Audio

/** The library a downloaded item belongs to: the one it was downloaded from
 *  when that is known and still listed, otherwise its kind's placeholder. */
export function libraryOf(index: OfflineIndex, trackId: string): string | null {
  const t = index.tracks[trackId]
  if (!t) return null
  if (t.library && index.libraries.some(l => l.Id === t.library)) return t.library
  return placeholderFor(t.item).Id
}

/** Items still in a placeholder library, for the online lookup to place. */
export const unplacedTrackIds = (index: OfflineIndex): string[] =>
  Object.keys(index.tracks).filter(id => isPlaceholderLibrary(libraryOf(index, id) ?? '')).sort()

/** The libraries Offline Mode lists (/UserViews): every stored library that
 *  holds a downloaded item, then each placeholder that holds one. */
export function librariesInUse(index: OfflineIndex): OfflineLibraryView[] {
  const used = new Set(Object.keys(index.tracks).map(id => libraryOf(index, id)))
  return [
    ...index.libraries.filter(l => used.has(l.Id)),
    ...Object.values(PLACEHOLDER_LIBRARIES).filter(l => used.has(l.Id)),
  ]
}

/** Stores the server's library list (/UserViews), keeping the kinds that can
 *  hold downloads. An item whose library is no longer listed falls back to
 *  its placeholder. */
export function setLibraries(index: OfflineIndex, views: JfItem[]): void {
  const kinds = new Set(['music', 'musicvideos', 'movies', 'tvshows'])
  const seen = new Set<string>()
  index.libraries = []
  for (const v of views) {
    if (!v || !isSafeLibraryId(v.Id) || isPlaceholderLibrary(v.Id) || seen.has(v.Id)) continue
    if (!kinds.has(v.CollectionType ?? '')) continue
    seen.add(v.Id)
    index.libraries.push({ Id: v.Id, Name: typeof v.Name === 'string' ? v.Name : '', CollectionType: v.CollectionType as string })
  }
}

/** Places items in a library the lookup found them in. A library not in the
 *  stored list is refused, so a stray id cannot hide an item. */
export function assignLibrary(index: OfflineIndex, trackIds: string[], libraryId: string): void {
  if (!index.libraries.some(l => l.Id === libraryId)) return
  for (const id of trackIds) if (index.tracks[id]) index.tracks[id].library = libraryId
}

// ── Items ────────────────────────────────────────────────────────────────────

const STRING_FIELDS = [
  'Id', 'Name', 'SortName', 'Type', 'MediaType', 'Album', 'AlbumId', 'AlbumArtist', 'AlbumPrimaryImageTag',
  'DateCreated', 'Overview', 'PlaylistItemId', 'SeriesId', 'SeriesName', 'SeriesPrimaryImageTag', 'SeasonId',
  'SeasonName', 'OfficialRating',
] as const
const NUMBER_FIELDS = [
  'RunTimeTicks', 'IndexNumber', 'ParentIndexNumber', 'ProductionYear', 'ChildCount', 'NormalizationGain',
  'CommunityRating',
] as const
const BOOLEAN_FIELDS = ['CanDelete', 'IsPublic'] as const
const STRING_ARRAY_FIELDS = ['Artists', 'Genres', 'BackdropImageTags'] as const
const NAME_ID_FIELDS = ['ArtistItems', 'AlbumArtists', 'GenreItems'] as const
const STREAM_STRINGS = ['Type', 'Codec', 'Language', 'DisplayTitle'] as const
const STREAM_NUMBERS = ['Index', 'Channels', 'Width', 'Height'] as const
const STREAM_BOOLEANS = ['IsDefault', 'IsForced', 'IsExternal', 'IsTextSubtitleStream'] as const

const isFiniteNumber = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

function slimNameIds(v: unknown): JfNameId[] | undefined {
  if (!Array.isArray(v)) return undefined
  const out: JfNameId[] = []
  for (const x of v) {
    if (!isPlainObject(x) || typeof x.Id !== 'string' || !x.Id) continue
    out.push(typeof x.Name === 'string' ? { Id: x.Id, Name: x.Name } : { Id: x.Id })
  }
  return out
}

/**
 * An item cut down to the fields its screens read offline
 * (docs/offline-request-map.md), each checked for its type: this also reads
 * what came off the disk. The list queries hand back far more (paths, people,
 * every stream of an audio file) and the index is rewritten on every change.
 * Video keeps its streams and chapters; audio does not need them.
 */
export function slimItem(item: JfItem): JfItem {
  const src = item as unknown as Record<string, unknown>
  const out: Record<string, unknown> = {}
  for (const k of STRING_FIELDS) if (typeof src[k] === 'string') out[k] = src[k]
  for (const k of NUMBER_FIELDS) if (isFiniteNumber(src[k])) out[k] = src[k]
  for (const k of BOOLEAN_FIELDS) if (typeof src[k] === 'boolean') out[k] = src[k]
  for (const k of STRING_ARRAY_FIELDS) {
    if (Array.isArray(src[k])) out[k] = (src[k] as unknown[]).filter(x => typeof x === 'string')
  }
  for (const k of NAME_ID_FIELDS) {
    const list = slimNameIds(src[k])
    if (list) out[k] = list
  }
  const tags = src.ImageTags
  if (isPlainObject(tags) && typeof tags.Primary === 'string') out.ImageTags = { Primary: tags.Primary }

  const ud = src.UserData
  if (isPlainObject(ud)) {
    const u: Record<string, unknown> = {}
    if (typeof ud.Played === 'boolean') u.Played = ud.Played
    if (typeof ud.IsFavorite === 'boolean') u.IsFavorite = ud.IsFavorite
    if (isFiniteNumber(ud.PlayCount)) u.PlayCount = ud.PlayCount
    if (isFiniteNumber(ud.PlaybackPositionTicks)) u.PlaybackPositionTicks = ud.PlaybackPositionTicks
    if (typeof ud.LastPlayedDate === 'string') u.LastPlayedDate = ud.LastPlayedDate
    out.UserData = u
  }

  // The first source only: the merge compares its bitrate, video needs its id.
  const source = Array.isArray(src.MediaSources) ? src.MediaSources[0] : undefined
  if (isPlainObject(source)) {
    const s: Record<string, unknown> = {}
    if (typeof source.Id === 'string') s.Id = source.Id
    if (typeof source.Container === 'string') s.Container = source.Container
    if (isFiniteNumber(source.Bitrate)) s.Bitrate = source.Bitrate
    if (isFiniteNumber(source.Size)) s.Size = source.Size
    out.MediaSources = [s]
  }

  const video = out.Type === 'Movie' || out.Type === 'Episode'
  if (video && Array.isArray(src.MediaStreams)) {
    out.MediaStreams = (src.MediaStreams as unknown[]).filter(isPlainObject).map(m => {
      const s: Record<string, unknown> = {}
      for (const k of STREAM_STRINGS) if (typeof m[k] === 'string') s[k] = m[k]
      for (const k of STREAM_NUMBERS) if (isFiniteNumber(m[k])) s[k] = m[k]
      for (const k of STREAM_BOOLEANS) if (typeof m[k] === 'boolean') s[k] = m[k]
      return s
    })
  }
  if (video && Array.isArray(src.Chapters)) {
    out.Chapters = (src.Chapters as unknown[]).filter(isPlainObject).flatMap(c =>
      isFiniteNumber(c.StartPositionTicks)
        ? [typeof c.Name === 'string' ? { StartPositionTicks: c.StartPositionTicks, Name: c.Name } : { StartPositionTicks: c.StartPositionTicks }]
        : [])
  }
  return out as unknown as JfItem
}

// ── Reading ──────────────────────────────────────────────────────────────────

export const collectionOf = (index: OfflineIndex, id: string): OfflineCollection | undefined =>
  index.collections.find(c => c.item.Id === id)

/** The file a ready track plays from, or null while it is not all on disk. */
export const readyFile = (index: OfflineIndex, trackId: string): string | null =>
  index.tracks[trackId]?.file ?? null

/** Tracks still to fetch, oldest request first, a shared track once. */
export function pendingTrackIds(index: OfflineIndex): string[] {
  const seen = new Set<string>()
  const out: string[] = []
  for (const c of [...index.collections].reverse()) {
    for (const id of c.trackIds) {
      if (index.tracks[id] && index.tracks[id].file === null && !seen.has(id)) { seen.add(id); out.push(id) }
    }
  }
  return out
}

export function collectionProgress(index: OfflineIndex, collectionId: string): { done: number; total: number } {
  const ids = collectionOf(index, collectionId)?.trackIds ?? []
  return { done: ids.filter(id => index.tracks[id]?.file != null).length, total: ids.length }
}

export function totalBytes(index: OfflineIndex): number {
  return Object.values(index.tracks).reduce((sum, t) => sum + t.bytes, 0)
}

/** Bytes a collection's ready tracks take, counting a track shared with
 *  another collection in full (it is what removing this one would not free,
 *  but it is also what the person sees as "this album's size"). */
export function collectionBytes(index: OfflineIndex, collectionId: string): number {
  const ids = collectionOf(index, collectionId)?.trackIds ?? []
  return ids.reduce((sum, id) => sum + (index.tracks[id]?.bytes ?? 0), 0)
}

/** Every file the index points at: ready media and saved subtitles. */
export const indexedFiles = (index: OfflineIndex): Set<string> =>
  new Set(Object.values(index.tracks).flatMap(t => [
    ...(t.file ? [t.file] : []),
    ...(t.subs ?? []).map(s => s.file),
  ]))

/** Lyrics saved with a track, or null when there are none or they have
 *  expired (SpicyLyrics past SPICY_LYRICS_DAYS: shown no longer, whatever the
 *  network does). */
export function lyricsOf(index: OfflineIndex, trackId: string, now: Date): OfflineLyrics | null {
  const l = index.tracks[trackId]?.lyrics
  if (!l) return null
  return l.expiresAt && Date.parse(l.expiresAt) <= now.getTime() ? null : l
}

/** Tracks whose saved lyrics have expired: to be refetched while online, or
 *  dropped (dropLyrics) when that fails. */
export const expiredLyricsTrackIds = (index: OfflineIndex, now: Date): string[] =>
  Object.keys(index.tracks).filter(id => index.tracks[id].lyrics && !lyricsOf(index, id, now)).sort()

// ── Changing (in place) ──────────────────────────────────────────────────────

/** Asks for a collection: an album or playlist with its tracks, a movie with
 *  itself, a season or series with its episodes. Asking again refreshes its
 *  list; items already on disk are kept, not fetched twice. `containers` are
 *  the series and seasons the episodes belong to. Items that are not audio,
 *  a movie or an episode are dropped, and so is an id that cannot be a file
 *  name. */
export function addCollection(index: OfflineIndex, collection: JfItem, items: JfItem[], containers: JfItem[] = []): void {
  const media = items.filter(t => t?.Id && isSafeId(t.Id) && (t.Type === undefined || MEDIA_TYPES.has(t.Type)))
  index.collections = index.collections.filter(c => c.item.Id !== collection.Id)
  index.collections.unshift({ item: slimItem(collection), trackIds: media.map(t => t.Id) })
  for (const t of media) {
    const existing = index.tracks[t.Id]
    if (existing) existing.item = slimItem(t)
    else index.tracks[t.Id] = { item: slimItem(t), file: null, bytes: 0 }
  }
  for (const c of containers) {
    if (c?.Id && isSafeId(c.Id) && (c.Type === 'Series' || c.Type === 'Season')) index.containers[c.Id] = slimItem(c)
  }
}

/** Refreshes stored items from a fresher copy the server sent: fields the
 *  copy has replace the stored ones, fields it lacks are kept (a list query
 *  carries no NormalizationGain, the stored single-item fetch did). How items
 *  from version 1 gain the ids and user data it never kept. */
export function refreshItems(index: OfflineIndex, items: JfItem[]): void {
  for (const fresh of items) {
    const t = fresh?.Id ? index.tracks[fresh.Id] : undefined
    if (t) t.item = slimItem({ ...t.item, ...fresh } as JfItem)
  }
}

export function markReady(index: OfflineIndex, trackId: string, file: string, bytes: number): void {
  const t = index.tracks[trackId]
  if (!t) return
  t.file = file
  t.bytes = bytes
}

/** Containers nothing downloaded still belongs to. */
function pruneContainers(index: OfflineIndex): void {
  const held = new Set<string>()
  for (const t of Object.values(index.tracks)) {
    if (t.item.SeriesId) held.add(t.item.SeriesId)
    if (t.item.SeasonId) held.add(t.item.SeasonId)
  }
  for (const id of Object.keys(index.containers)) if (!held.has(id)) delete index.containers[id]
}

/** Drops a collection, and with it every item no other collection still
 *  holds, and the series and seasons nothing left belongs to. Returns the
 *  files that are now nobody's, to delete (media and subtitles). */
export function removeCollection(index: OfflineIndex, collectionId: string): string[] {
  index.collections = index.collections.filter(c => c.item.Id !== collectionId)
  const kept = new Set(index.collections.flatMap(c => c.trackIds))
  const orphaned: string[] = []
  for (const [id, t] of Object.entries(index.tracks)) {
    if (kept.has(id)) continue
    if (t.file) orphaned.push(t.file)
    for (const s of t.subs ?? []) orphaned.push(s.file)
    delete index.tracks[id]
  }
  pruneContainers(index)
  return orphaned.sort()
}

/** Brings the index in line with the disk after a crash, a relaunch or a person
 *  poking at the folder: a ready track whose file is gone goes back to pending,
 *  a subtitle whose file is gone is forgotten. Returns files on disk the index
 *  does not know, to delete (a download that finished after its collection was
 *  removed). */
export function reconcile(index: OfflineIndex, filesOnDisk: Iterable<string>): string[] {
  const onDisk = new Set(filesOnDisk)
  for (const t of Object.values(index.tracks)) {
    if (t.file && !onDisk.has(t.file)) { t.file = null; t.bytes = 0 }
    if (t.subs) {
      t.subs = t.subs.filter(s => onDisk.has(s.file))
      if (!t.subs.length) delete t.subs
    }
  }
  const known = indexedFiles(index)
  return [...onDisk].filter(f => !known.has(f)).sort()
}

/** Saves a track's lyrics. SpicyLyrics get an expiry SPICY_LYRICS_DAYS out. */
export function setLyrics(index: OfflineIndex, trackId: string,
  lyrics: { source: string; synced: boolean; lines: LyricLine[]; credit?: SpicyCredit | null }, now: Date): void {
  const t = index.tracks[trackId]
  if (!t) return
  const lines = parseLyricLines(lyrics.lines)
  if (!lines.length || typeof lyrics.source !== 'string' || !lyrics.source) return
  const expires = lyrics.source === 'spicy' ? new Date(now.getTime() + SPICY_LYRICS_DAYS * 86_400_000).toISOString() : null
  t.lyrics = { source: lyrics.source, synced: !!lyrics.synced, lines, savedAt: now.toISOString(), expiresAt: expires }
  const credit = parseCredit(lyrics.credit)
  if (credit) t.lyrics.credit = credit
}

export function dropLyrics(index: OfflineIndex, trackId: string): void {
  if (index.tracks[trackId]) delete index.tracks[trackId].lyrics
}

export function setSubtitles(index: OfflineIndex, trackId: string, subs: OfflineSubtitle[]): void {
  const t = index.tracks[trackId]
  if (!t) return
  const valid = parseSubtitles(subs)
  if (valid.length) t.subs = valid
  else delete t.subs
}

export function setSegments(index: OfflineIndex, trackId: string, segments: OfflineSegment[]): void {
  const t = index.tracks[trackId]
  if (!t) return
  const valid = parseSegments(segments)
  if (valid.length) t.segments = valid
  else delete t.segments
}

export function setExplicit(index: OfflineIndex, trackId: string, explicit: boolean): void {
  const t = index.tracks[trackId]
  if (!t) return
  if (explicit) t.explicit = true
  else delete t.explicit
}

/** Stores the signed-in user from /Users/{id}, keeping the Policy fields the
 *  apps read. */
export function setUser(index: OfflineIndex, user: unknown): void {
  index.user = parseUser(user)
}

/** The rows a snapshot keeps, from the server's played items, newest first. */
export function historyEntriesOf(items: JfItem[]): HistoryEntry[] {
  return items.filter(i => i && isSafeId(i.Id)).slice(0, MAX_HISTORY_ENTRIES).map(i => ({
    Id: i.Id,
    LastPlayedDate: typeof i.UserData?.LastPlayedDate === 'string' ? i.UserData.LastPlayedDate : null,
    PlayCount: isFiniteNumber(i.UserData?.PlayCount) ? i.UserData.PlayCount : 0,
  }))
}

export function setHistory(index: OfflineIndex, items: JfItem[], takenAt: Date): void {
  index.history = { takenAt: takenAt.toISOString(), entries: historyEntriesOf(items) }
}

/** Queues a play for replay. Newest are kept past the cap. */
export function addPlay(index: OfflineIndex, play: OfflinePlay): void {
  index.plays.push(play)
  if (index.plays.length > MAX_QUEUED_PLAYS) index.plays.splice(0, index.plays.length - MAX_QUEUED_PLAYS)
}

/** Whether a queued play the server refused should be dropped rather than
 *  retried. The item is gone (deleted or re-scanned since) or the request can
 *  never succeed, so retrying would jam every play queued behind it. Anything
 *  else (no response, 401, 5xx) may clear up, so the play is kept. */
export const dropsPlay = (status: number): boolean => status === 400 || status === 404

// ── Storage ──────────────────────────────────────────────────────────────────

/** An id fit to become a file name: Jellyfin's are hex, and one from anywhere
 *  else must not become a path. */
export const isSafeId = (id: unknown): id is string =>
  typeof id === 'string' && /^[A-Za-z0-9]{1,64}$/.test(id)

/** "media/" plus a plain file name: no separators, no "..", no dot-file. */
export const isSafeMediaPath = (p: unknown): p is string =>
  typeof p === 'string' && /^media\/[A-Za-z0-9_-][A-Za-z0-9._-]*$/.test(p) && !p.includes('..')

/** "art/<id>.jpg". */
export const isSafeArtPath = (p: unknown): p is string =>
  typeof p === 'string' && /^art\/[A-Za-z0-9]{1,64}\.jpg$/.test(p)

/** "subs/<id>.<index>.vtt". */
export const isSafeSubtitlePath = (p: unknown): p is string =>
  typeof p === 'string' && /^subs\/[A-Za-z0-9]{1,64}\.\d{1,4}\.vtt$/.test(p)

/** A Jellyfin user id (a GUID, with or without dashes). It names the account's
 *  offline folder, so it must never be a path. */
export const isSafeUserId = (id: unknown): id is string =>
  typeof id === 'string' && /^[A-Za-z0-9-]{1,64}$/.test(id) && !/^-+$/.test(id)

const isPlainObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v)

const isoDate = (v: unknown): string | null => {
  if (typeof v !== 'string') return null
  const t = Date.parse(v)
  return Number.isFinite(t) ? new Date(t).toISOString() : null
}

/** Most lines one track's lyrics may hold, and words one line may hold. */
const MAX_LYRIC_LINES = 5000
const MAX_LYRIC_WORDS = 500

function parseWords(v: unknown): LyricWord[] | null {
  if (!Array.isArray(v)) return null
  return v.slice(0, MAX_LYRIC_WORDS).filter(isPlainObject).flatMap(w =>
    isFiniteNumber(w.Start) && typeof w.Text === 'string'
      ? [{ Start: w.Start, End: isFiniteNumber(w.End) ? w.End : null, Text: w.Text }]
      : [])
}

function parseLyricLines(v: unknown): LyricLine[] {
  if (!Array.isArray(v)) return []
  const out: LyricLine[] = []
  for (const l of v.slice(0, MAX_LYRIC_LINES)) {
    if (!isPlainObject(l) || !isFiniteNumber(l.Start) || typeof l.Text !== 'string') continue
    const line: LyricLine = { Start: l.Start, End: isFiniteNumber(l.End) ? l.End : null, Text: l.Text, Words: parseWords(l.Words) }
    const bg = parseWords(l.Background)
    if (bg) line.Background = bg
    if (l.Opposite === true) line.Opposite = true
    out.push(line)
  }
  return out
}

function parseContributor(v: unknown): SpicyContributor | null {
  if (!isPlainObject(v) || typeof v.name !== 'string') return null
  return { name: v.name, url: typeof v.url === 'string' ? v.url : null }
}

function parseCredit(v: unknown): SpicyCredit | undefined {
  if (!isPlainObject(v) || typeof v.provider !== 'string' || !v.provider) return undefined
  return { provider: v.provider, uploader: parseContributor(v.uploader), maker: parseContributor(v.maker) }
}

function parseLyrics(v: unknown): OfflineLyrics | undefined {
  if (!isPlainObject(v) || typeof v.source !== 'string' || !v.source) return undefined
  const lines = parseLyricLines(v.lines)
  const savedAt = isoDate(v.savedAt)
  if (!lines.length || !savedAt) return undefined
  // SpicyLyrics with no readable expiry are treated as already expired rather
  // than kept for good.
  const expiresAt = isoDate(v.expiresAt) ?? (v.source === 'spicy' ? savedAt : null)
  const out: OfflineLyrics = { source: v.source, synced: v.synced === true, lines, savedAt, expiresAt }
  const credit = parseCredit(v.credit)
  if (credit) out.credit = credit
  return out
}

function parseSubtitles(v: unknown): OfflineSubtitle[] {
  if (!Array.isArray(v)) return []
  const seen = new Set<number>()
  const out: OfflineSubtitle[] = []
  for (const s of v) {
    if (!isPlainObject(s) || !Number.isInteger(s.index) || (s.index as number) < 0 || !isSafeSubtitlePath(s.file)) continue
    if (seen.has(s.index as number)) continue
    seen.add(s.index as number)
    const sub: OfflineSubtitle = { index: s.index as number, file: s.file }
    if (typeof s.language === 'string') sub.language = s.language
    if (typeof s.title === 'string') sub.title = s.title
    if (typeof s.isDefault === 'boolean') sub.isDefault = s.isDefault
    if (typeof s.isForced === 'boolean') sub.isForced = s.isForced
    out.push(sub)
  }
  return out
}

function parseSegments(v: unknown): OfflineSegment[] {
  if (!Array.isArray(v)) return []
  return v.filter(isPlainObject).flatMap(s =>
    typeof s.Type === 'string' && isFiniteNumber(s.StartTicks) && isFiniteNumber(s.EndTicks) && s.EndTicks > s.StartTicks
      ? [{ Type: s.Type, StartTicks: s.StartTicks, EndTicks: s.EndTicks }]
      : [])
}

function parseUser(v: unknown): OfflineUser | null {
  if (!isPlainObject(v) || !isSafeUserId(v.Id) || typeof v.Name !== 'string') return null
  const p = isPlainObject(v.Policy) ? v.Policy : {}
  const policy: OfflinePolicy = {}
  for (const k of ['IsAdministrator', 'EnableContentDeletion', 'EnableContentDownloading', 'EnableLiveTvAccess'] as const) {
    if (typeof p[k] === 'boolean') policy[k] = p[k] as boolean
  }
  if (Array.isArray(p.EnableContentDeletionFromFolders)) {
    policy.EnableContentDeletionFromFolders = p.EnableContentDeletionFromFolders.filter((x): x is string => typeof x === 'string')
  }
  return { Id: v.Id, Name: v.Name, Policy: policy }
}

function parseHistory(v: unknown): HistorySnapshot | null {
  if (!isPlainObject(v) || !Array.isArray(v.entries)) return null
  const takenAt = isoDate(v.takenAt)
  if (!takenAt) return null
  const entries: HistoryEntry[] = []
  for (const e of v.entries.slice(0, MAX_HISTORY_ENTRIES)) {
    if (!isPlainObject(e) || !isSafeId(e.Id)) continue
    entries.push({
      Id: e.Id,
      LastPlayedDate: typeof e.LastPlayedDate === 'string' ? e.LastPlayedDate : null,
      PlayCount: isFiniteNumber(e.PlayCount) && e.PlayCount >= 0 ? Math.floor(e.PlayCount) : 0,
    })
  }
  return { takenAt, entries }
}

/**
 * A stored index, validated: it is read from disk, where anything can be. A
 * path that could leave the offline folder is dropped (the track goes back to
 * pending), an id that is not a plain id is dropped, an unreadable value is an
 * empty index rather than a crash. A version 1 index (no `version`) reads into
 * version 2 as is: it simply has no libraries, user, lyrics or snapshot yet.
 */
export function parseIndex(raw: unknown): OfflineIndex {
  const index = emptyIndex()
  if (!isPlainObject(raw)) return index

  if (isPlainObject(raw.tracks)) {
    for (const [id, v] of Object.entries(raw.tracks)) {
      if (!isSafeId(id) || !isPlainObject(v) || !isPlainObject(v.item) || v.item.Id !== id) continue
      const file = isSafeMediaPath(v.file) ? v.file : null
      const bytes = file && typeof v.bytes === 'number' && Number.isFinite(v.bytes) && v.bytes > 0 ? Math.floor(v.bytes) : 0
      const track: OfflineTrack = { item: slimItem(v.item as unknown as JfItem), file, bytes }
      if (isSafeLibraryId(v.library) && !isPlaceholderLibrary(v.library)) track.library = v.library
      const lyrics = parseLyrics(v.lyrics)
      if (lyrics) track.lyrics = lyrics
      const subs = parseSubtitles(v.subs)
      if (subs.length) track.subs = subs
      const segments = parseSegments(v.segments)
      if (segments.length) track.segments = segments
      if (v.explicit === true) track.explicit = true
      index.tracks[id] = track
    }
  }

  if (Array.isArray(raw.collections)) {
    const seen = new Set<string>()
    for (const c of raw.collections) {
      if (!isPlainObject(c) || !isPlainObject(c.item) || !isSafeId(c.item.Id) || seen.has(c.item.Id)) continue
      if (typeof c.item.Type === 'string' && !COLLECTION_TYPES.has(c.item.Type)) continue
      seen.add(c.item.Id)
      const ids = Array.isArray(c.trackIds) ? c.trackIds.filter((id): id is string => typeof id === 'string' && !!index.tracks[id]) : []
      index.collections.push({ item: slimItem(c.item as unknown as JfItem), trackIds: ids })
    }
  }

  if (isPlainObject(raw.containers)) {
    for (const [id, v] of Object.entries(raw.containers)) {
      if (!isSafeId(id) || !isPlainObject(v) || v.Id !== id || (v.Type !== 'Series' && v.Type !== 'Season')) continue
      index.containers[id] = slimItem(v as unknown as JfItem)
    }
  }

  if (Array.isArray(raw.libraries)) setLibraries(index, raw.libraries.filter(isPlainObject) as unknown as JfItem[])
  index.user = parseUser(raw.user)
  index.history = parseHistory(raw.history)

  if (Array.isArray(raw.plays)) {
    for (const p of raw.plays) {
      if (!isPlainObject(p) || !isSafeId(p.itemId) || !isSafeUserId(p.userId)) continue
      const date = isoDate(p.date)
      if (date) index.plays.push({ itemId: p.itemId, userId: p.userId, date })
    }
    if (index.plays.length > MAX_QUEUED_PLAYS) index.plays.splice(0, index.plays.length - MAX_QUEUED_PLAYS)
  }

  // A track no collection holds is nobody's: it would never be listed, played
  // from a Downloads row, or removed.
  const held = new Set(index.collections.flatMap(c => c.trackIds))
  for (const id of Object.keys(index.tracks)) if (!held.has(id)) delete index.tracks[id]
  pruneContainers(index)
  return index
}

// ── Judging a download ───────────────────────────────────────────────────────

const AUDIO_EXTENSIONS: Record<string, string> = {
  'audio/flac': 'flac', 'audio/x-flac': 'flac', 'audio/mpeg': 'mp3', 'audio/mp3': 'mp3',
  'audio/mp4': 'm4a', 'audio/x-m4a': 'm4a', 'audio/aac': 'aac', 'audio/ogg': 'ogg',
  'audio/opus': 'opus', 'audio/wav': 'wav', 'audio/x-wav': 'wav', 'audio/webm': 'webm',
  'audio/x-ms-wma': 'wma', 'audio/x-matroska': 'mka',
}

/** Extensions a downloaded track may be saved under: what the MIME table
 *  above produces, plus lossless and container formats a library also holds. */
const AUDIO_FILE_EXTENSIONS = new Set([
  ...Object.values(AUDIO_EXTENSIONS), 'alac', 'aif', 'aiff', 'ape', 'wv', 'dsf', 'dff', 'oga', 'mp4', 'm4b', 'mpc',
])

/** The extension a downloaded file is saved under. A media element picks its
 *  parser by what the response says, but a wrong or missing extension is a
 *  file nothing else can identify. The server's file name first (/Download
 *  sends the original's), then the MIME type; null when neither says audio.
 *  A file name only counts when it names audio: an error page a proxy
 *  answered 200 with is not a track, whatever it is called. */
export function fileExtensionFor(contentDisposition: string | null | undefined, contentType: string | null | undefined): string | null {
  const name = /filename\*?=(?:UTF-8'')?"?([^";]+)"?/i.exec(contentDisposition ?? '')?.[1]
  if (name) {
    const dot = name.lastIndexOf('.')
    const ext = dot >= 0 ? name.slice(dot + 1).toLowerCase() : ''
    if (AUDIO_FILE_EXTENSIONS.has(ext)) return ext
  }
  const mime = (contentType ?? '').split(';')[0].trim().toLowerCase()
  return AUDIO_EXTENSIONS[mime] ?? null
}

export type DownloadVerdict =
  | { ok: true; ext: string }
  | { ok: false; message: string }

/**
 * Whether what arrived is a finished track. A 2xx with the full length and
 * something that says audio, nothing else: a truncated stream must not become a
 * finished download, and an error page that came back 200 from a proxy is not
 * music. `expected` is the Content-Length the server announced (null when it
 * did not, as with a chunked response).
 */
export function judgeDownload(r: {
  status: number
  expected: number | null
  received: number
  contentDisposition?: string | null
  contentType?: string | null
}): DownloadVerdict {
  if (r.status < 200 || r.status >= 300) {
    return { ok: false, message: r.status === 403
      ? 'The server does not allow this account to download. An admin can turn on media downloading for it.'
      : `The server answered HTTP ${r.status}.` }
  }
  if (r.received <= 0 || (r.expected !== null && r.received !== r.expected)) {
    return { ok: false, message: 'A download was cut short.' }
  }
  const ext = fileExtensionFor(r.contentDisposition, r.contentType)
  if (!ext) return { ok: false, message: 'The server sent something that is not a music file.' }
  return { ok: true, ext }
}

// ── Serving a file ───────────────────────────────────────────────────────────

/** The part of a file a request asked for: inclusive byte offsets. */
export type ByteRange = { start: number; end: number }

/**
 * A Range header against a file of `size` bytes. Null means "no usable range,
 * send the whole file" (absent, malformed, or a multi-range request, which a
 * media element does not make); 'unsatisfiable' means answer 416. A media
 * element seeks with these, so getting the arithmetic wrong is a track that
 * will not scrub.
 */
export function parseByteRange(header: string | null | undefined, size: number): ByteRange | 'unsatisfiable' | null {
  const m = /^bytes=(\d*)-(\d*)$/.exec((header ?? '').trim())
  if (!m || (m[1] === '' && m[2] === '')) return null
  if (!Number.isInteger(size) || size <= 0) return 'unsatisfiable'
  if (m[1] === '') {
    // "-N": the last N bytes.
    const n = Number(m[2])
    return n === 0 ? 'unsatisfiable' : { start: Math.max(0, size - n), end: size - 1 }
  }
  const start = Number(m[1])
  const end = m[2] === '' ? size - 1 : Math.min(Number(m[2]), size - 1)
  if (start >= size || end < start) return 'unsatisfiable'
  return { start, end }
}

const CONTENT_TYPES: Record<string, string> = {
  flac: 'audio/flac', mp3: 'audio/mpeg', m4a: 'audio/mp4', mp4: 'audio/mp4', aac: 'audio/aac', ogg: 'audio/ogg',
  opus: 'audio/ogg', wav: 'audio/wav', webm: 'audio/webm', wma: 'audio/x-ms-wma', mka: 'audio/x-matroska',
  jpg: 'image/jpeg',
}

/** What to tell the media element a stored file is, from its extension. */
export function contentTypeForFile(file: string): string {
  return CONTENT_TYPES[file.slice(file.lastIndexOf('.') + 1).toLowerCase()] ?? 'application/octet-stream'
}
