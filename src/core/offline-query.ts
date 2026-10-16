// The offline stand-in for the server: a request (path plus params) answered
// from the catalog (offline-index.ts) in Jellyfin's response shape, so the
// screens run unchanged in Offline Mode (docs/offline-mode-plan.md, section 2).
//
// It answers exactly the routes and params docs/offline-request-map.md found
// the screens sending, and nothing speculative. Anything else answers an empty
// list marked `unknownRoute`, never a network call. CascadeKit's
// OfflineQuery.swift is the same engine; test/fixtures/offline-query.json holds
// cases both are tested against, so the two stay in step. Change one, change
// the other.
//
// Only what is on disk is answered: an item still downloading cannot play
// offline, and a collection, series or genre shows only while it holds
// something that can.
//
// Sorting compares lowercased text by code point, not with localeCompare, so
// the desktop and Apple order things identically whatever the system locale.
//
// Cost: offlineQuery(index) builds a view of the catalog, each part (albums,
// playlists, shows, artists, genres) only when a request first needs it. A
// caller that keeps the result while the catalog is unchanged pays that once;
// answerOffline() builds a fresh one per call. Measured on 20,000 songs in
// 2,000 albums (node 22, a cloud VM): building about 60 ms, then about 15 ms a
// request; Offline Mode keeps one engine per catalog state.

import type { JfItem, JfNameId } from './types.ts'
import {
  type OfflineIndex, libraryOf, librariesInUse, PLACEHOLDER_LIBRARIES,
} from './offline-index.ts'

export interface OfflineAnswer {
  /** 200, or 404 for an id the catalog does not hold. */
  status: number
  body: unknown
  /** The route is not one the engine knows: the body is an empty list. */
  unknownRoute?: true
}

type Params = Map<string, string>

/** A resolved catalog entry: the item as the screens see it, plus what the
 *  filters match on, every id normalized (normId). Arrays rather than sets:
 *  each holds one to three ids, and a catalog of tens of thousands of
 *  entries spent its time collecting garbage sets. */
interface Entry {
  item: JfItem
  /** Its own id, normalized. */
  key: string
  /** Library ids it belongs to (an artist or genre can span several). */
  libraries: readonly string[]
  /** Ids a ParentId may name to reach it: album, series, season, playlists. */
  parents: readonly string[]
  artistIds: readonly string[]
  albumArtistIds: readonly string[]
  genreIds: readonly string[]
  /** A genre's item types, lowercased, for /Genres?IncludeItemTypes=. */
  types?: readonly string[]
}

const NONE: readonly string[] = Object.freeze([])
const EMPTY_LIST = { Items: [], TotalRecordCount: 0, StartIndex: 0 }
const notFound = (): OfflineAnswer => ({ status: 404, body: null })
const ok = (body: unknown): OfflineAnswer => ({ status: 200, body })

/** Jellyfin ids compare without case or dashes ("N" and "D" GUID formats). */
const normId = (id: string): string => id.toLowerCase().replace(/-/g, '')

/** Without repeats. The lists here hold one to three ids, where a scan is
 *  cheaper than building a set. */
function uniq(xs: string[]): string[] {
  if (xs.length < 2) return xs
  const out: string[] = []
  for (const x of xs) if (!out.includes(x)) out.push(x)
  return out
}

/** The placeholder libraries' ids, which Offline Mode adds to the libraries a
 *  screen fans out over, so downloads whose library is not known yet still
 *  show (plan, section 1). */
export const placeholderLibraryIds = (): string[] => Object.values(PLACEHOLDER_LIBRARIES).map(l => l.Id)

// ── Requests ─────────────────────────────────────────────────────────────────

function readParams(path: string, params: Record<string, unknown> = {}): { segments: string[], params: Params } {
  const out: Params = new Map()
  const q = path.indexOf('?')
  if (q >= 0) {
    for (const [k, v] of new URLSearchParams(path.slice(q + 1))) out.set(k.toLowerCase(), v)
    path = path.slice(0, q)
  }
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined || v === null) continue
    out.set(k.toLowerCase(), Array.isArray(v) ? v.map(String).join(',') : String(v))
  }
  return { segments: path.split('/').filter(Boolean), params: out }
}

const list = (p: Params, key: string, sep: RegExp = /,/): string[] =>
  (p.get(key) ?? '').split(sep).map(s => s.trim()).filter(Boolean)

const bool = (p: Params, key: string): boolean | null => {
  const v = (p.get(key) ?? '').toLowerCase()
  return v === 'true' ? true : v === 'false' ? false : null
}

const int = (p: Params, key: string): number | null => {
  const n = Number(p.get(key))
  return p.has(key) && Number.isInteger(n) && n >= 0 ? n : null
}

const parentOf = (p: Params): string | null => p.has('parentid') ? normId(p.get('parentid')!) : null
const typesOf = (p: Params): Set<string> => new Set(list(p, 'includeitemtypes').map(t => t.toLowerCase()))
const typeOf = (e: Entry): string => (e.item.Type ?? 'Audio').toLowerCase()

// ── The catalog as entries ───────────────────────────────────────────────────

const ids = (list: JfNameId[] | undefined): string[] => list ? list.map(x => normId(x.Id)) : []

/** What the engine sees: every ready media item, and, built on first use, the
 *  albums, playlists, shows, artists and genres they imply. */
class Catalog {
  readonly index: OfflineIndex
  readonly media: Entry[] = []
  private readonly mediaById = new Map<string, Entry>()
  private _albums?: Entry[]
  private _playlists?: { list: Entry[], tracks: Map<string, Entry[]> }
  private _containers?: Entry[]
  private _artists?: Entry[]
  private _albumArtists?: Entry[]
  private _musicGenres?: Entry[]
  private _genres?: Entry[]

  constructor(index: OfflineIndex) {
    this.index = index
    const playlistsOf = new Map<string, string[]>()
    for (const c of index.collections) {
      if (c.item.Type !== 'Playlist') continue
      const key = normId(c.item.Id)
      for (const id of c.trackIds) {
        const into = playlistsOf.get(id)
        if (into) into.push(key)
        else playlistsOf.set(id, [key])
      }
    }
    // Ids in a fixed order (normalized, then by code unit, as Swift's < on
    // the same ASCII strings), since an album made from its tracks takes the
    // first track's fields.
    const ready = Object.keys(index.tracks).filter(id => index.tracks[id].file)
      .map(id => [normId(id), id] as const).sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)
    const stored = new Set(index.libraries.map(l => l.Id))
    for (const [key, id] of ready) {
      const t = index.tracks[id]
      const item = t.item
      const library = t.library && stored.has(t.library) ? t.library : libraryOf(index, id)!
      const parents = playlistsOf.get(id)?.slice() ?? []
      if (item.AlbumId) parents.push(normId(item.AlbumId))
      if (item.SeriesId) parents.push(normId(item.SeriesId))
      if (item.SeasonId) parents.push(normId(item.SeasonId))
      const albumArtistIds = ids(item.AlbumArtists)
      const e: Entry = {
        item,
        key,
        libraries: [normId(library)],
        parents,
        artistIds: uniq([...ids(item.ArtistItems), ...albumArtistIds]),
        albumArtistIds,
        genreIds: ids(item.GenreItems),
      }
      this.media.push(e)
      this.mediaById.set(e.key, e)
    }
  }

  get albums(): Entry[] {
    if (this._albums) return this._albums
    const stored = new Map(this.index.collections.filter(c => c.item.Type === 'MusicAlbum').map(c => [normId(c.item.Id), c.item]))
    const byAlbum = new Map<string, Entry[]>()
    for (const e of this.media) {
      if ((e.item.Type !== 'Audio' && e.item.Type !== undefined) || !e.item.AlbumId) continue
      const key = normId(e.item.AlbumId)
      const into = byAlbum.get(key)
      if (into) into.push(e)
      else byAlbum.set(key, [e])
    }
    this._albums = [...byAlbum.keys()].sort(cmpText).map(key => {
      const tracks = byAlbum.get(key)!
      const first = tracks[0].item
      const item: JfItem = { ...(stored.get(key) ?? {
        Id: first.AlbumId!, Name: first.Album, Type: 'MusicAlbum', AlbumArtist: first.AlbumArtist,
        ...(first.AlbumArtists ? { AlbumArtists: first.AlbumArtists } : {}),
        ...(first.ProductionYear !== undefined ? { ProductionYear: first.ProductionYear } : {}),
        ...(first.AlbumPrimaryImageTag ? { ImageTags: { Primary: first.AlbumPrimaryImageTag } } : {}),
        ChildCount: tracks.length,
      }) }
      const genres = new Map<string, JfNameId>()
      for (const t of tracks) for (const g of t.item.GenreItems ?? []) if (!genres.has(normId(g.Id))) genres.set(normId(g.Id), g)
      if (!item.DateCreated) {
        const d = dateCreatedOf(tracks)
        if (d) item.DateCreated = d
      }
      if (!item.GenreItems && genres.size) {
        item.GenreItems = [...genres.values()]
        item.Genres = item.GenreItems.map(g => g.Name ?? '')
      }
      const artistIds = new Set([...ids(item.AlbumArtists), ...ids(item.ArtistItems)])
      const albumArtistIds = new Set(ids(item.AlbumArtists))
      const libraries = new Set<string>()
      for (const t of tracks) {
        for (const a of t.artistIds) artistIds.add(a)
        for (const a of t.albumArtistIds) albumArtistIds.add(a)
        for (const l of t.libraries) libraries.add(l)
      }
      return {
        item, key, libraries: [...libraries], parents: NONE, artistIds: [...artistIds], albumArtistIds: [...albumArtistIds],
        genreIds: uniq([...ids(item.GenreItems), ...genres.keys()]),
      }
    })
    return this._albums
  }

  private get playlistParts(): { list: Entry[], tracks: Map<string, Entry[]> } {
    if (this._playlists) return this._playlists
    const out = { list: [] as Entry[], tracks: new Map<string, Entry[]>() }
    for (const c of [...this.index.collections].sort((a, b) => cmpText(a.item.Id, b.item.Id))) {
      if (c.item.Type !== 'Playlist') continue
      const tracks = c.trackIds.map(id => this.mediaById.get(normId(id))).filter((e): e is Entry => !!e)
      if (!tracks.length) continue
      const key = normId(c.item.Id)
      out.list.push({ item: { ...c.item, ChildCount: tracks.length }, key, libraries: NONE, parents: NONE, artistIds: NONE, albumArtistIds: NONE, genreIds: NONE })
      out.tracks.set(key, tracks)
    }
    this._playlists = out
    return out
  }

  get playlists(): Entry[] { return this.playlistParts.list }
  /** A playlist's ready tracks in playlist order. */
  playlistTracks(key: string): Entry[] | undefined { return this.playlistParts.tracks.get(key) }

  /** Series and seasons with a ready episode. A season the catalog has no
   *  container for (an episode whose season was never stored) is made from
   *  the episode's own fields, so the show page still lists it. */
  get containers(): Entry[] {
    if (this._containers) return this._containers
    const episodes = this.media.filter(e => e.item.Type === 'Episode')
    const made = new Map<string, JfItem>()
    const under = new Map<string, Entry[]>()
    for (const e of episodes) {
      const ep = e.item
      if (ep.SeriesId) {
        const key = normId(ep.SeriesId)
        if (!made.has(key)) made.set(key, this.index.containers[ep.SeriesId] ?? { Id: ep.SeriesId, Name: ep.SeriesName, Type: 'Series' })
        under.set(key, [...(under.get(key) ?? []), e])
      }
      if (ep.SeasonId) {
        const key = normId(ep.SeasonId)
        if (!made.has(key)) {
          made.set(key, this.index.containers[ep.SeasonId] ?? {
            Id: ep.SeasonId, Name: ep.SeasonName, Type: 'Season', SeriesId: ep.SeriesId, SeriesName: ep.SeriesName,
            ...(ep.ParentIndexNumber !== undefined ? { IndexNumber: ep.ParentIndexNumber } : {}),
          })
        }
        under.set(key, [...(under.get(key) ?? []), e])
      }
    }
    this._containers = [...made.keys()].sort(cmpText).map(key => {
      let item = made.get(key)!
      const eps = under.get(key) ?? []
      if (item.Type === 'Series' && !item.DateCreated) {
        const d = dateCreatedOf(eps)
        if (d) item = { ...item, DateCreated: d }
      }
      return {
        item, key,
        libraries: uniq(eps.flatMap(x => x.libraries)),
        parents: item.Type === 'Season' && item.SeriesId ? [normId(item.SeriesId)] : NONE,
        artistIds: NONE, albumArtistIds: NONE,
        genreIds: ids(item.GenreItems),
      }
    })
    return this._containers
  }

  /** Artists, derived from what is downloaded: Jellyfin keeps them as items
   *  of their own, the catalog only as names and ids on the tracks. */
  private people(pick: (i: JfItem) => JfNameId[] | undefined): Entry[] {
    const found = new Map<string, { first: JfNameId, libs: Set<string> }>()
    for (const e of this.media) {
      for (const a of pick(e.item) ?? []) {
        const key = normId(a.Id)
        let f = found.get(key)
        if (!f) { f = { first: a, libs: new Set() }; found.set(key, f) }
        for (const l of e.libraries) f.libs.add(l)
      }
    }
    return [...found.keys()].sort(cmpText).map(key => {
      const f = found.get(key)!
      return {
        item: { Id: f.first.Id, Name: f.first.Name ?? '', Type: 'MusicArtist' }, key,
        libraries: [...f.libs], parents: NONE, artistIds: NONE, albumArtistIds: NONE, genreIds: NONE,
      }
    })
  }

  get artists(): Entry[] {
    return this._artists ??= this.people(i => i.ArtistItems && i.AlbumArtists ? [...i.ArtistItems, ...i.AlbumArtists] : i.ArtistItems ?? i.AlbumArtists)
  }

  get albumArtists(): Entry[] { return this._albumArtists ??= this.people(i => i.AlbumArtists) }

  private genreList(from: Entry[], type: string): Entry[] {
    const found = new Map<string, { item: JfNameId, libs: Set<string>, types: Set<string> }>()
    for (const e of from) {
      for (const g of e.item.GenreItems ?? []) {
        const key = normId(g.Id)
        let f = found.get(key)
        if (!f) { f = { item: g, libs: new Set(), types: new Set() }; found.set(key, f) }
        for (const l of e.libraries) f.libs.add(l)
        f.types.add(typeOf(e))
      }
    }
    return [...found.keys()].sort(cmpText).map(key => {
      const f = found.get(key)!
      return {
        item: { Id: f.item.Id, Name: f.item.Name ?? '', Type: type }, key,
        libraries: [...f.libs], parents: NONE, artistIds: NONE, albumArtistIds: NONE, genreIds: NONE, types: [...f.types],
      }
    })
  }

  get musicGenres(): Entry[] {
    return this._musicGenres ??= this.genreList([...this.media.filter(e => typeOf(e) === 'audio'), ...this.albums], 'MusicGenre')
  }

  get genres(): Entry[] {
    return this._genres ??= this.genreList([...this.media, ...this.albums, ...this.containers.filter(c => c.item.Type === 'Series')], 'Genre')
  }

  /** Everything /Items may list, or with `types` (lowercased) only the parts
   *  that can hold those types, so a songs query builds no albums. Artists
   *  and genres only when asked for by type or id, as Jellyfin keeps them
   *  outside the library folders. */
  all(withPeople: boolean, types: Set<string> = new Set()): Entry[] {
    const want = (...kinds: string[]) => !types.size || kinds.some(k => types.has(k))
    return [
      ...(want('audio', 'movie', 'episode') ? this.media : []),
      ...(want('musicalbum') ? this.albums : []),
      ...(want('playlist') ? this.playlists : []),
      ...(want('series', 'season') ? this.containers : []),
      ...(withPeople && want('musicartist') ? this.artists : []),
      ...(withPeople && want('musicgenre') ? this.musicGenres : []),
    ]
  }

  /** One entry by (normalized) id, in the order Jellyfin's kinds take
   *  precedence: a file, then what it implies. */
  byId(key: string): Entry | undefined {
    return this.mediaById.get(key)
      ?? [this.albums, this.playlists, this.containers, this.artists, this.albumArtists, this.musicGenres, this.genres]
        .map(list => list.find(e => e.key === key)).find(e => !!e)
  }

  libraryView(id: string): JfItem | null {
    const v = librariesInUse(this.index).find(l => normId(l.Id) === id)
    return v ? { Id: v.Id, Name: v.Name, CollectionType: v.CollectionType, Type: 'CollectionFolder' } : null
  }

  /** Whether a (normalized) id is a library: a stored one or a placeholder. */
  isLibrary(id: string): boolean {
    return this.index.libraries.some(l => normId(l.Id) === id) || placeholderLibraryIds().some(l => normId(l) === id)
  }
}

/** The newest DateCreated among some entries, for an album or show the
 *  catalog did not store one for. */
function dateCreatedOf(entries: Entry[]): string | null {
  let best: string | null = null, bestTime = -Infinity
  for (const e of entries) {
    const t = time(e.item.DateCreated)
    if (t !== null && t > bestTime) { best = e.item.DateCreated!; bestTime = t }
  }
  return best
}

// ── Sorting ──────────────────────────────────────────────────────────────────

/** Lowercased text by code point: the same order on every system. */
function cmpText(a: string, b: string): number {
  if (a === b) return 0
  const x = a.toLowerCase(), y = b.toLowerCase()
  let i = 0, j = 0
  while (i < x.length && j < y.length) {
    const cx = x.codePointAt(i)!, cy = y.codePointAt(j)!
    if (cx !== cy) return cx < cy ? -1 : 1
    i += cx > 0xffff ? 2 : 1
    j += cy > 0xffff ? 2 : 1
  }
  const restX = i < x.length, restY = j < y.length
  return restX === restY ? 0 : restX ? 1 : -1
}

const time = (s: string | undefined): number | null => {
  const t = s ? Date.parse(s) : NaN
  return Number.isFinite(t) ? t : null
}

type SortValue = string | number | null

/** One SortBy key's value. Null sorts first ascending, as Jellyfin's do. */
function sortValue(i: JfItem, key: string): SortValue {
  switch (key) {
    case 'sortname': return i.SortName ?? i.Name ?? ''
    case 'name': return i.Name ?? ''
    case 'album': return i.Album ?? ''
    case 'albumartist': return i.AlbumArtist ?? i.Artists?.[0] ?? ''
    case 'datecreated': return time(i.DateCreated)
    case 'dateplayed': return time(i.UserData?.LastPlayedDate)
    case 'playcount': return i.UserData?.PlayCount ?? 0
    case 'productionyear': return i.ProductionYear ?? null
    case 'parentindexnumber': return i.ParentIndexNumber ?? null
    case 'indexnumber': return i.IndexNumber ?? null
    case 'communityrating': return i.CommunityRating ?? null
    case 'runtime': return i.RunTimeTicks ?? null
    default: return null
  }
}

const SORT_KEYS = new Set(['sortname', 'name', 'album', 'albumartist', 'datecreated', 'dateplayed', 'playcount',
  'productionyear', 'parentindexnumber', 'indexnumber', 'communityrating', 'runtime'])

function compareValues(a: SortValue, b: SortValue): number {
  if (a === b) return 0
  if (a === null) return -1
  if (b === null) return 1
  if (typeof a === 'string' && typeof b === 'string') return cmpText(a, b)
  return (a as number) < (b as number) ? -1 : (a as number) > (b as number) ? 1 : 0
}

/** Sorts by Jellyfin SortBy keys (unknown ones ignored) and SortOrder (one
 *  for all, or one per key), the id breaking any tie. Random shuffles with
 *  `random`, so tests can pin it. Each key's value is worked out once per
 *  entry, not once per comparison. */
function sortEntries(entries: Entry[], p: Params, random: () => number, fallback: string[]): Entry[] {
  const keys = list(p, 'sortby').map(k => k.toLowerCase())
  if (keys.includes('random')) {
    const out = [...entries]
    for (let i = out.length - 1; i > 0; i--) {
      const j = Math.min(Math.floor(random() * (i + 1)), i)
      ;[out[i], out[j]] = [out[j], out[i]]
    }
    return out
  }
  const orders = list(p, 'sortorder').map(o => o.toLowerCase() === 'descending' ? -1 : 1)
  const chosen = (keys.length ? keys : fallback).filter(k => SORT_KEYS.has(k))
  const values = entries.map(e => chosen.map(k => sortValue(e.item, k)))
  const order = entries.map((_, i) => i).sort((x, y) => {
    for (let k = 0; k < chosen.length; k++) {
      const c = compareValues(values[x][k], values[y][k])
      if (c) return c * (orders[k] ?? orders[0] ?? 1)
    }
    return cmpText(entries[x].item.Id, entries[y].item.Id)
  })
  return order.map(i => entries[i])
}

function page(entries: Entry[], p: Params): { Items: JfItem[], TotalRecordCount: number, StartIndex: number } {
  const start = int(p, 'startindex') ?? 0
  const limit = int(p, 'limit')
  const slice = entries.slice(start, limit === null ? undefined : start + limit)
  return { Items: slice.map(e => e.item), TotalRecordCount: entries.length, StartIndex: start }
}

// ── Filters ──────────────────────────────────────────────────────────────────

const fold = (s: string): string => s.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase()

const meets = (have: readonly string[], want: Set<string>): boolean => have.some(id => want.has(id))

/** The filters /Items and the artist and genre lists share. */
function filterEntries(entries: Entry[], p: Params): Entry[] {
  const wanted = (key: string) => new Set(list(p, key).map(normId))
  const artistIds = wanted('artistids'), albumArtistIds = wanted('albumartistids'), genreIds = wanted('genreids')
  const genreNames = new Set(list(p, 'genres', /\|/).map(fold))
  const artistNames = new Set(list(p, 'artists', /\|/).map(fold))
  const years = new Set(list(p, 'years').map(Number).filter(Number.isInteger))
  const term = fold(p.get('searchterm') ?? '').trim()
  const filters = new Set(list(p, 'filters').map(f => f.toLowerCase()))
  const favorite = bool(p, 'isfavorite') ?? (filters.has('isfavorite') ? true : null)
  const played = bool(p, 'isplayed') ?? (filters.has('isplayed') ? true : filters.has('isunplayed') ? false : null)
  const resumable = filters.has('isresumable')
  const any = artistIds.size || albumArtistIds.size || genreIds.size || genreNames.size || artistNames.size
    || years.size || term || favorite !== null || played !== null || resumable
  if (!any) return entries

  return entries.filter(e => {
    const item = e.item
    if (artistIds.size && !meets(e.artistIds, artistIds)) return false
    if (albumArtistIds.size && !meets(e.albumArtistIds, albumArtistIds)) return false
    if (genreIds.size && !meets(e.genreIds, genreIds)) return false
    if (genreNames.size && !(item.Genres ?? []).some(n => genreNames.has(fold(n)))) return false
    if (artistNames.size && ![...(item.Artists ?? []), item.AlbumArtist ?? ''].some(n => artistNames.has(fold(n)))) return false
    if (years.size && !years.has(item.ProductionYear ?? NaN)) return false
    if (term && !fold(item.Name ?? '').includes(term)) return false
    if (favorite !== null && (item.UserData?.IsFavorite === true) !== favorite) return false
    if (played !== null && (item.UserData?.Played === true) !== played) return false
    if (resumable && !((item.UserData?.PlaybackPositionTicks ?? 0) > 0)) return false
    return true
  })
}

const inLibrary = (entries: Entry[], parent: string | null): Entry[] =>
  parent === null ? entries : entries.filter(e => e.libraries.includes(parent))

// ── Routes ───────────────────────────────────────────────────────────────────

function items(c: Catalog, p: Params, random: () => number): OfflineAnswer {
  const types = typesOf(p)
  const idList = list(p, 'ids').map(normId)
  const parent = parentOf(p)
  const wantsPeople = idList.length > 0 || types.has('musicartist') || types.has('musicgenre')
  // Jellyfin 12's playlists-holding-a-parent query asks for playlists only;
  // everything else narrows by type later anyway.
  let entries = c.all(wantsPeople, types)
  let fallback = ['sortname']

  if (idList.length) {
    const set = new Set(idList)
    entries = entries.filter(e => set.has(e.key))
  }
  if (parent !== null) {
    const playlist = c.playlistTracks(parent)
    if (types.size === 1 && types.has('playlist') && !playlist) {
      // Jellyfin 12: playlists holding the parent's items.
      const under = new Set(c.media.filter(e => e.parents.includes(parent) || e.libraries.includes(parent)).map(e => e.key))
      entries = entries.filter(e => e.item.Type === 'Playlist' && (c.playlistTracks(e.key) ?? []).some(t => under.has(t.key)))
    } else if (playlist) {
      const present = new Set(entries.map(e => e.key))
      entries = playlist.filter(t => present.has(t.key))
      fallback = []
    } else if (c.isLibrary(parent)) {
      entries = inLibrary(entries.filter(e => e.item.Type !== 'Playlist'), parent)
    } else {
      // An album, series or season: in disc and track (or season and
      // episode) order unless a sort is asked for.
      entries = entries.filter(e => e.parents.includes(parent))
      fallback = ['parentindexnumber', 'indexnumber', 'sortname']
    }
  }
  if (types.size) entries = entries.filter(e => types.has(typeOf(e)))
  entries = filterEntries(entries, p)
  // A playlist keeps its own order unless a sort is asked for.
  const sorted = fallback.length || p.has('sortby') ? sortEntries(entries, p, random, fallback) : entries
  return ok(page(sorted, p))
}

function oneItem(c: Catalog, id: string): OfflineAnswer {
  const e = c.byId(id)
  if (e) return ok(e.item)
  const view = c.libraryView(id)
  return view ? ok(view) : notFound()
}

function latest(c: Catalog, p: Params): OfflineAnswer {
  const types = typesOf(p)
  let entries = inLibrary(c.media, parentOf(p))
  if (types.size) entries = entries.filter(e => types.has(typeOf(e)))
  const sorted = sortEntries(entries, new Map([['sortby', 'DateCreated'], ['sortorder', 'Descending']]), () => 0, [])
  return ok(sorted.slice(0, int(p, 'limit') ?? 20).map(e => e.item))
}

function queryFilters(c: Catalog, p: Params): OfflineAnswer {
  const types = typesOf(p)
  let entries = inLibrary(c.all(false, types), parentOf(p))
  if (types.size) entries = entries.filter(e => types.has(typeOf(e)))
  const sortedUniq = (xs: string[]) => [...new Set(xs)].sort(cmpText)
  return ok({
    Genres: sortedUniq(entries.flatMap(e => e.item.Genres ?? [])),
    Tags: [],
    OfficialRatings: sortedUniq(entries.flatMap(e => e.item.OfficialRating ? [e.item.OfficialRating] : [])),
    Years: [...new Set(entries.flatMap(e => e.item.ProductionYear !== undefined ? [e.item.ProductionYear] : []))].sort((a, b) => a - b),
  })
}

function views(c: Catalog): OfflineAnswer {
  const out = librariesInUse(c.index).map(v => ({ Id: v.Id, Name: v.Name, CollectionType: v.CollectionType, Type: 'CollectionFolder' }))
  return ok({ Items: out, TotalRecordCount: out.length, StartIndex: 0 })
}

function user(c: Catalog, id: string): OfflineAnswer {
  const u = c.index.user
  if (!u || (id !== 'me' && normId(u.Id) !== id)) return notFound()
  return ok({ Id: u.Id, Name: u.Name, Policy: u.Policy })
}

function playlistItems(c: Catalog, id: string, p: Params): OfflineAnswer {
  const tracks = c.playlistTracks(id)
  if (!tracks) return notFound()
  return ok(page(tracks.map(t => ({ ...t, item: { ...t.item, PlaylistItemId: t.item.PlaylistItemId ?? t.item.Id } })), p))
}

function playlist(c: Catalog, id: string): OfflineAnswer {
  const tracks = c.playlistTracks(id)
  const e = c.playlists.find(x => x.key === id)
  if (!tracks || !e) return notFound()
  return ok({ OpenAccess: e.item.IsPublic === true, Shares: [], ItemIds: tracks.map(t => t.item.Id) })
}

function seasons(c: Catalog, seriesId: string, p: Params, random: () => number): OfflineAnswer {
  if (!c.containers.some(e => e.key === seriesId)) return notFound()
  const found = c.containers.filter(e => e.item.Type === 'Season' && e.parents.includes(seriesId))
  return ok(page(sortEntries(found, new Map(), random, ['indexnumber', 'sortname']), p))
}

function episodes(c: Catalog, seriesId: string, p: Params, random: () => number): OfflineAnswer {
  if (!c.containers.some(e => e.key === seriesId)) return notFound()
  const season = p.has('seasonid') ? normId(p.get('seasonid')!) : null
  const found = c.media.filter(e => e.item.Type === 'Episode' && e.parents.includes(seriesId) && (season === null || e.parents.includes(season)))
  return ok(page(sortEntries(found, new Map(), random, ['parentindexnumber', 'indexnumber', 'sortname']), p))
}

/** Per show, the first unplayed episode after the last played one; shows not
 *  started are left out, as the server's Next Up leaves them. Most recently
 *  watched show first. */
function nextUp(c: Catalog, p: Params, random: () => number): OfflineAnswer {
  const onlySeries = p.has('seriesid') ? normId(p.get('seriesid')!) : null
  const resumable = bool(p, 'enableresumable') !== false
  const found: { entry: Entry, last: number }[] = []
  for (const series of inLibrary(c.containers.filter(e => e.item.Type === 'Series'), parentOf(p))) {
    if (onlySeries !== null && series.key !== onlySeries) continue
    const eps = sortEntries(c.media.filter(e => e.item.Type === 'Episode' && e.parents.includes(series.key)), new Map(), random,
      ['parentindexnumber', 'indexnumber', 'sortname'])
    let lastPlayed = -1
    eps.forEach((e, i) => { if (e.item.UserData?.Played) lastPlayed = i })
    if (lastPlayed < 0) continue
    const next = eps.slice(lastPlayed + 1).find(e => !e.item.UserData?.Played &&
      (resumable || !((e.item.UserData?.PlaybackPositionTicks ?? 0) > 0)))
    if (!next) continue
    const last = Math.max(...eps.map(e => time(e.item.UserData?.LastPlayedDate) ?? 0))
    found.push({ entry: next, last })
  }
  found.sort((a, b) => b.last - a.last || cmpText(a.entry.item.Id, b.entry.item.Id))
  return ok(page(found.map(f => f.entry), p))
}

function segments(c: Catalog, id: string): OfflineAnswer {
  const key = Object.keys(c.index.tracks).find(k => normId(k) === id)
  const segs = key && c.index.tracks[key].file ? c.index.tracks[key].segments ?? [] : []
  const out = segs.map(s => ({ ItemId: key, Type: s.Type, StartTicks: s.StartTicks, EndTicks: s.EndTicks }))
  return ok({ Items: out, TotalRecordCount: out.length, StartIndex: 0 })
}

/** /Artists, /Artists/AlbumArtists, /Persons, /MusicGenres and /Genres: a
 *  derived list with the filters those routes take. */
function derivedList(from: Entry[], p: Params, random: () => number): OfflineAnswer {
  let entries = filterEntries(inLibrary(from, parentOf(p)), p)
  const types = typesOf(p)
  if (types.size) entries = entries.filter(e => (e.types ?? NONE).some(t => types.has(t)))
  return ok(page(sortEntries(entries, p, random, ['sortname']), p))
}

function persons(c: Catalog, p: Params, random: () => number): OfflineAnswer {
  const kinds = new Set(list(p, 'persontypes').map(t => t.toLowerCase()))
  if (kinds.size && !kinds.has('artist') && !kinds.has('albumartist')) return ok(EMPTY_LIST)
  return derivedList(kinds.size === 1 && kinds.has('albumartist') ? c.albumArtists : c.artists, p, random)
}

/** /Items/<word> routes that are not an item id. */
const RESERVED = new Set(['latest', 'filters', 'filters2', 'root', 'counts', 'resume'])
const ID_LIKE = /^[a-z0-9-]+$/

function route(c: Catalog, path: string, params: Record<string, unknown>, random: () => number): OfflineAnswer {
  const { segments: seg, params: p } = readParams(path, params)
  const s = seg.map(x => x.toLowerCase())
  const id = (i: number) => normId(seg[i])

  if (s.length === 1 && s[0] === 'items') return items(c, p, random)
  if (s.length === 2 && s[0] === 'items' && s[1] === 'latest') return latest(c, p)
  if (s.length === 2 && s[0] === 'items' && s[1] === 'filters') return queryFilters(c, p)
  if (s.length === 2 && s[0] === 'items' && ID_LIKE.test(s[1]) && !RESERVED.has(s[1])) return oneItem(c, id(1))
  if (s.length === 1 && s[0] === 'userviews') return views(c)
  if (s.length === 2 && s[0] === 'users' && ID_LIKE.test(s[1])) return user(c, s[1] === 'me' ? 'me' : id(1))
  if (s.length === 3 && s[0] === 'playlists' && s[2] === 'items') return playlistItems(c, id(1), p)
  if (s.length === 2 && s[0] === 'playlists') return playlist(c, id(1))
  if (s.length === 2 && s[0] === 'shows' && s[1] === 'nextup') return nextUp(c, p, random)
  if (s.length === 3 && s[0] === 'shows' && s[2] === 'seasons') return seasons(c, id(1), p, random)
  if (s.length === 3 && s[0] === 'shows' && s[2] === 'episodes') return episodes(c, id(1), p, random)
  if (s.length === 2 && s[0] === 'mediasegments') return segments(c, id(1))
  if (s.length === 1 && s[0] === 'artists') return derivedList(c.artists, p, random)
  if (s.length === 2 && s[0] === 'artists' && s[1] === 'albumartists') return derivedList(c.albumArtists, p, random)
  if (s.length === 1 && s[0] === 'persons') return persons(c, p, random)
  if (s.length === 1 && s[0] === 'musicgenres') return derivedList(c.musicGenres, p, random)
  if (s.length === 1 && s[0] === 'genres') return derivedList(c.genres, p, random)
  return { status: 200, body: EMPTY_LIST, unknownRoute: true }
}

export interface OfflineQuery {
  /** Answers one GET. `path` is the route as the apps send it (a query string
   *  on it is read too); `params` the query, names in any case. `random`
   *  drives SortBy=Random. */
  answer(path: string, params?: Record<string, unknown>, random?: () => number): OfflineAnswer
}

/** An engine over one state of the catalog. Keep it while the catalog is
 *  unchanged and make a new one when it changes: what it has built is not
 *  rebuilt. */
export function offlineQuery(index: OfflineIndex): OfflineQuery {
  const c = new Catalog(index)
  return { answer: (path, params = {}, random = Math.random) => route(c, path, params, random) }
}

/** Answers one GET from the catalog as it is now. */
export function answerOffline(index: OfflineIndex, path: string, params: Record<string, unknown> = {},
  random: () => number = Math.random): OfflineAnswer {
  return offlineQuery(index).answer(path, params, random)
}
