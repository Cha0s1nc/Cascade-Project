// The offline stand-in for the server: a request (path plus params) answered
// from the catalog (offline-index.ts) in Jellyfin's response shape, so the
// screens run unchanged in Offline Mode (docs/offline-mode-plan.md, section 2).
//
// It answers exactly the routes and params docs/offline-request-map.md found
// the screens sending, and nothing speculative. Anything else answers an empty
// list marked `unknownRoute`, never a network call. CascadeKit's
// OfflineQuery.swift is the same engine; test/fixtures/offline-query.json holds
// cases both are tested against, so the two stay in step.
//
// Only what is on disk is answered: an item still downloading cannot play
// offline, and a collection, series or genre shows only while it holds
// something that can.
//
// Sorting compares lowercased text by code point, not with localeCompare, so
// the desktop and Apple order things identically whatever the system locale.

import type { JfItem, JfNameId } from './types.ts'
import {
  type OfflineIndex, type OfflineTrack, libraryOf, librariesInUse, PLACEHOLDER_LIBRARIES,
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
 *  filters match on. */
interface Entry {
  item: JfItem
  /** Library ids it belongs to, normalized (an artist or genre can span
   *  several). */
  libraries: Set<string>
  /** Ids a ParentId may name to reach it: album, series, season, playlists. */
  parents: Set<string>
  artistIds: Set<string>
  albumArtistIds: Set<string>
  genreIds: Set<string>
  /** A genre's item types, for /Genres?IncludeItemTypes=. */
  types?: Set<string>
}

const EMPTY_LIST = { Items: [], TotalRecordCount: 0, StartIndex: 0 }
const notFound = (): OfflineAnswer => ({ status: 404, body: null })
const ok = (body: unknown): OfflineAnswer => ({ status: 200, body })

/** Jellyfin ids compare without case or dashes ("N" and "D" GUID formats). */
const normId = (id: string): string => id.toLowerCase().replace(/-/g, '')

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

// ── The catalog as entries ───────────────────────────────────────────────────

const ids = (list: JfNameId[] | undefined): string[] => (list ?? []).map(x => normId(x.Id))

/** What the engine sees: every ready media item, the collections, containers,
 *  albums, artists and genres they imply. Built per request; the catalog is
 *  small and requests are a person's clicks. */
class Catalog {
  readonly byId = new Map<string, Entry>()
  readonly media: Entry[] = []
  private readonly mediaSet = new Set<Entry>()
  readonly albums: Entry[] = []
  readonly playlists: Entry[] = []
  readonly containers: Entry[] = []
  readonly artists: Entry[] = []
  readonly albumArtists: Entry[] = []
  readonly musicGenres: Entry[] = []
  readonly genres: Entry[] = []
  /** Playlist id to its ready tracks in playlist order. */
  readonly playlistTracks = new Map<string, Entry[]>()
  readonly index: OfflineIndex

  constructor(index: OfflineIndex) {
    this.index = index
    const ready = Object.keys(index.tracks).sort(cmpText).filter(id => index.tracks[id].file)
    const playlistsOf = new Map<string, Set<string>>()
    for (const c of index.collections) {
      if (c.item.Type !== 'Playlist') continue
      for (const id of c.trackIds) {
        if (!playlistsOf.has(id)) playlistsOf.set(id, new Set())
        playlistsOf.get(id)!.add(normId(c.item.Id))
      }
    }

    for (const id of ready) {
      const t: OfflineTrack = index.tracks[id]
      const item = t.item
      const lib = libraryOf(index, id)!
      const parents = new Set<string>(playlistsOf.get(id) ?? [])
      for (const p of [item.AlbumId, item.SeriesId, item.SeasonId]) if (p) parents.add(normId(p))
      const e: Entry = {
        item,
        libraries: new Set([normId(lib)]),
        parents,
        artistIds: new Set([...ids(item.ArtistItems), ...ids(item.AlbumArtists)]),
        albumArtistIds: new Set(ids(item.AlbumArtists)),
        genreIds: new Set(ids(item.GenreItems)),
      }
      this.media.push(e)
      this.mediaSet.add(e)
      this.byId.set(normId(id), e)
    }

    this.buildAlbums()
    this.buildPlaylists()
    this.buildContainers()
    this.buildPeopleAndGenres()
  }

  private buildAlbums(): void {
    const stored = new Map(this.index.collections.filter(c => c.item.Type === 'MusicAlbum').map(c => [normId(c.item.Id), c.item]))
    const byAlbum = new Map<string, Entry[]>()
    for (const e of this.media) {
      if (e.item.Type !== 'Audio' && e.item.Type !== undefined) continue
      if (!e.item.AlbumId) continue
      const key = normId(e.item.AlbumId)
      if (!byAlbum.has(key)) byAlbum.set(key, [])
      byAlbum.get(key)!.push(e)
    }
    for (const key of [...byAlbum.keys()].sort(cmpText)) {
      const tracks = byAlbum.get(key)!
      const first = tracks[0].item
      const item: JfItem = stored.get(key) ?? {
        Id: first.AlbumId!, Name: first.Album, Type: 'MusicAlbum', AlbumArtist: first.AlbumArtist,
        ...(first.AlbumArtists ? { AlbumArtists: first.AlbumArtists } : {}),
        ...(first.ProductionYear !== undefined ? { ProductionYear: first.ProductionYear } : {}),
        ...(first.AlbumPrimaryImageTag ? { ImageTags: { Primary: first.AlbumPrimaryImageTag } } : {}),
        ChildCount: tracks.length,
      }
      const genres = new Map<string, JfNameId>()
      for (const t of tracks) for (const g of t.item.GenreItems ?? []) genres.set(normId(g.Id), g)
      const e: Entry = {
        item: { ...item, ...(!item.DateCreated ? dateCreatedOf(tracks) : {}), ...(!item.GenreItems && genres.size ? { GenreItems: [...genres.values()], Genres: [...genres.values()].map(g => g.Name ?? '') } : {}) },
        libraries: new Set(tracks.flatMap(t => [...t.libraries])),
        parents: new Set(),
        artistIds: new Set([...ids(item.AlbumArtists), ...ids(item.ArtistItems), ...tracks.flatMap(t => [...t.artistIds])]),
        albumArtistIds: new Set([...ids(item.AlbumArtists), ...tracks.flatMap(t => [...t.albumArtistIds])]),
        genreIds: new Set([...ids(item.GenreItems), ...genres.keys()]),
      }
      this.albums.push(e)
      this.byId.set(key, e)
    }
  }

  private buildPlaylists(): void {
    for (const c of [...this.index.collections].sort((a, b) => cmpText(a.item.Id, b.item.Id))) {
      if (c.item.Type !== 'Playlist') continue
      const tracks = c.trackIds.map(id => this.byId.get(normId(id))).filter((e): e is Entry => !!e && this.mediaSet.has(e))
      if (!tracks.length) continue
      const e: Entry = {
        item: { ...c.item, ChildCount: tracks.length },
        libraries: new Set(), parents: new Set(), artistIds: new Set(), albumArtistIds: new Set(), genreIds: new Set(),
      }
      this.playlists.push(e)
      this.playlistTracks.set(normId(c.item.Id), tracks)
      this.byId.set(normId(c.item.Id), e)
    }
  }

  /** Series and seasons with a ready episode. A season the catalog has no
   *  container for (an episode whose season was never stored) is made from
   *  the episode's own fields, so the show page still lists it. */
  private buildContainers(): void {
    const episodes = this.media.filter(e => e.item.Type === 'Episode')
    const made = new Map<string, JfItem>()
    for (const e of episodes) {
      const ep = e.item
      if (ep.SeriesId && !made.has(normId(ep.SeriesId))) {
        made.set(normId(ep.SeriesId), this.index.containers[ep.SeriesId] ?? { Id: ep.SeriesId, Name: ep.SeriesName, Type: 'Series' })
      }
      if (ep.SeasonId && !made.has(normId(ep.SeasonId))) {
        made.set(normId(ep.SeasonId), this.index.containers[ep.SeasonId] ?? {
          Id: ep.SeasonId, Name: ep.SeasonName, Type: 'Season', SeriesId: ep.SeriesId, SeriesName: ep.SeriesName,
          ...(ep.ParentIndexNumber !== undefined ? { IndexNumber: ep.ParentIndexNumber } : {}),
        })
      }
    }
    for (const key of [...made.keys()].sort(cmpText)) {
      const item = made.get(key)!
      const under = episodes.filter(e => e.parents.has(key))
      const e: Entry = {
        item: item.Type === 'Series' ? { ...item, ...(!item.DateCreated ? dateCreatedOf(under) : {}) } : item,
        libraries: new Set(under.flatMap(x => [...x.libraries])),
        parents: item.Type === 'Season' && item.SeriesId ? new Set([normId(item.SeriesId)]) : new Set(),
        artistIds: new Set(), albumArtistIds: new Set(),
        genreIds: new Set(ids(item.GenreItems)),
      }
      this.containers.push(e)
      this.byId.set(key, e)
    }
  }

  /** Artists and genres, derived from what is downloaded: Jellyfin keeps them
   *  as items of their own, the catalog only as names and ids on the tracks. */
  private buildPeopleAndGenres(): void {
    const people = (pick: (i: JfItem) => JfNameId[] | undefined, into: Entry[]) => {
      const found = new Map<string, { first: JfNameId, libs: Set<string> }>()
      for (const e of this.media) {
        for (const a of pick(e.item) ?? []) {
          const key = normId(a.Id)
          const f = found.get(key) ?? { first: a, libs: new Set<string>() }
          for (const l of e.libraries) f.libs.add(l)
          found.set(key, f)
        }
      }
      for (const key of [...found.keys()].sort(cmpText)) {
        const f = found.get(key)!
        const e: Entry = {
          item: { Id: f.first.Id, Name: f.first.Name ?? '', Type: 'MusicArtist' },
          libraries: f.libs, parents: new Set(), artistIds: new Set(), albumArtistIds: new Set(), genreIds: new Set(),
        }
        into.push(e)
        if (!this.byId.has(key)) this.byId.set(key, e)
      }
    }
    people(i => [...(i.ArtistItems ?? []), ...(i.AlbumArtists ?? [])], this.artists)
    people(i => i.AlbumArtists, this.albumArtists)

    const genres = (from: Entry[], type: string, into: Entry[]) => {
      const found = new Map<string, { item: JfNameId, libs: Set<string>, types: Set<string> }>()
      for (const e of from) {
        for (const g of e.item.GenreItems ?? []) {
          const key = normId(g.Id)
          const f = found.get(key) ?? { item: g, libs: new Set<string>(), types: new Set<string>() }
          for (const l of e.libraries) f.libs.add(l)
          f.types.add((e.item.Type ?? 'Audio').toLowerCase())
          found.set(key, f)
        }
      }
      for (const key of [...found.keys()].sort(cmpText)) {
        const f = found.get(key)!
        const e: Entry = {
          item: { Id: f.item.Id, Name: f.item.Name ?? '', Type: type },
          libraries: f.libs, parents: new Set(), artistIds: new Set(), albumArtistIds: new Set(), genreIds: new Set(),
          types: f.types,
        }
        into.push(e)
        if (!this.byId.has(key)) this.byId.set(key, e)
      }
    }
    genres([...this.media.filter(e => (e.item.Type ?? 'Audio') === 'Audio'), ...this.albums], 'MusicGenre', this.musicGenres)
    genres([...this.media, ...this.albums, ...this.containers.filter(c => c.item.Type === 'Series')], 'Genre', this.genres)
  }

  /** Everything /Items may list. Artists and genres only when asked for by
   *  type or id, as Jellyfin keeps them outside the library folders. */
  all(withPeople: boolean): Entry[] {
    return [
      ...this.media, ...this.albums, ...this.playlists, ...this.containers,
      ...(withPeople ? [...this.artists, ...this.musicGenres] : []),
    ]
  }

  libraryView(id: string): JfItem | null {
    const v = librariesInUse(this.index).find(l => normId(l.Id) === id)
    return v ? { Id: v.Id, Name: v.Name, CollectionType: v.CollectionType, Type: 'CollectionFolder' } : null
  }
}

/** The newest DateCreated among some entries, for an album or show the
 *  catalog did not store one for. */
function dateCreatedOf(entries: Entry[]): { DateCreated?: string } {
  const dates = entries.map(e => e.item.DateCreated).filter((d): d is string => !!d && Number.isFinite(Date.parse(d)))
  if (!dates.length) return {}
  return { DateCreated: dates.reduce((a, b) => (Date.parse(b) > Date.parse(a) ? b : a)) }
}

// ── Sorting ──────────────────────────────────────────────────────────────────

/** Lowercased text by code point: the same order on every system. */
function cmpText(a: string, b: string): number {
  const x = [...a.toLowerCase()], y = [...b.toLowerCase()]
  for (let i = 0; i < Math.min(x.length, y.length); i++) {
    const d = x[i].codePointAt(0)! - y[i].codePointAt(0)!
    if (d) return d < 0 ? -1 : 1
  }
  return x.length === y.length ? 0 : x.length < y.length ? -1 : 1
}

const time = (s: string | undefined): number | null => {
  const t = s ? Date.parse(s) : NaN
  return Number.isFinite(t) ? t : null
}

/** One SortBy key's value. Null sorts first ascending, as Jellyfin's do. */
function sortValue(i: JfItem, key: string): string | number | null {
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
    default: return undefined as never
  }
}

const SORT_KEYS = new Set(['sortname', 'name', 'album', 'albumartist', 'datecreated', 'dateplayed', 'playcount',
  'productionyear', 'parentindexnumber', 'indexnumber', 'communityrating', 'runtime'])

function compareValues(a: string | number | null, b: string | number | null): number {
  if (a === b) return 0
  if (a === null) return -1
  if (b === null) return 1
  if (typeof a === 'string' && typeof b === 'string') return cmpText(a, b)
  return (a as number) < (b as number) ? -1 : (a as number) > (b as number) ? 1 : 0
}

/** Sorts by Jellyfin SortBy keys (unknown ones ignored) and SortOrder (one
 *  for all, or one per key), the id breaking any tie. Random shuffles with
 *  `random`, so tests can pin it. */
function sortEntries(entries: Entry[], p: Params, random: () => number, fallback: string[]): Entry[] {
  const keys = list(p, 'sortby').map(k => k.toLowerCase())
  if (keys.includes('random')) {
    const out = [...entries]
    for (let i = out.length - 1; i > 0; i--) {
      const j = Math.floor(random() * (i + 1))
      ;[out[i], out[j]] = [out[j], out[i]]
    }
    return out
  }
  const orders = list(p, 'sortorder').map(o => o.toLowerCase() === 'descending' ? -1 : 1)
  const chosen = (keys.length ? keys : fallback).filter(k => SORT_KEYS.has(k))
  return [...entries].sort((x, y) => {
    for (let k = 0; k < chosen.length; k++) {
      const dir = orders[k] ?? orders[0] ?? 1
      const c = compareValues(sortValue(x.item, chosen[k]), sortValue(y.item, chosen[k]))
      if (c) return c * dir
    }
    return cmpText(x.item.Id, y.item.Id)
  })
}

function page(entries: Entry[], p: Params): { Items: JfItem[], TotalRecordCount: number, StartIndex: number } {
  const start = int(p, 'startindex') ?? 0
  const limit = int(p, 'limit')
  const slice = entries.slice(start, limit === null ? undefined : start + limit)
  return { Items: slice.map(e => e.item), TotalRecordCount: entries.length, StartIndex: start }
}

// ── Filters ──────────────────────────────────────────────────────────────────

const fold = (s: string): string => s.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase()

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

  return entries.filter(({ item, artistIds: a, albumArtistIds: aa, genreIds: g }) => {
    if (artistIds.size && ![...artistIds].some(id => a.has(id))) return false
    if (albumArtistIds.size && ![...albumArtistIds].some(id => aa.has(id))) return false
    if (genreIds.size && ![...genreIds].some(id => g.has(id))) return false
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

function inLibrary(entries: Entry[], parent: string | null): Entry[] {
  return parent === null ? entries : entries.filter(e => e.libraries.has(parent))
}

/** Whether a (normalized) id is a library: a stored one or a placeholder. */
const isLibrary = (c: Catalog, id: string): boolean =>
  c.index.libraries.some(l => normId(l.Id) === id) || placeholderLibraryIds().some(l => normId(l) === id)

// ── Routes ───────────────────────────────────────────────────────────────────

function items(c: Catalog, p: Params, random: () => number): OfflineAnswer {
  const types = new Set(list(p, 'includeitemtypes').map(t => t.toLowerCase()))
  const idList = list(p, 'ids').map(normId)
  const parent = p.has('parentid') ? normId(p.get('parentid')!) : null
  const wantsPeople = idList.length > 0 || types.has('musicartist') || types.has('musicgenre')
  let entries = c.all(wantsPeople)
  let fallback = ['sortname']

  if (idList.length) {
    const set = new Set(idList)
    entries = entries.filter(e => set.has(normId(e.item.Id)))
  }
  if (parent !== null) {
    const playlist = c.playlistTracks.get(parent)
    if (types.size === 1 && types.has('playlist') && !playlist) {
      // Jellyfin 12: playlists holding the parent's items.
      const under = new Set(c.media.filter(e => e.parents.has(parent) || e.libraries.has(parent)).map(e => e.item.Id))
      entries = entries.filter(e => e.item.Type === 'Playlist' && (c.playlistTracks.get(normId(e.item.Id)) ?? []).some(t => under.has(t.item.Id)))
    } else if (playlist) {
      entries = playlist.filter(t => entries.includes(t))
      fallback = []
    } else if (isLibrary(c, parent)) {
      entries = inLibrary(entries.filter(e => e.item.Type !== 'Playlist'), parent)
    } else {
      // An album, series or season: in disc and track (or season and
      // episode) order unless a sort is asked for.
      entries = entries.filter(e => e.parents.has(parent))
      fallback = ['parentindexnumber', 'indexnumber', 'sortname']
    }
  }
  if (types.size) entries = entries.filter(e => types.has((e.item.Type ?? 'Audio').toLowerCase()))
  entries = filterEntries(entries, p)
  // A playlist keeps its own order unless a sort is asked for.
  const sorted = fallback.length || p.has('sortby') ? sortEntries(entries, p, random, fallback) : entries
  return ok(page(sorted, p))
}

function oneItem(c: Catalog, id: string): OfflineAnswer {
  const e = c.byId.get(id)
  if (e) return ok(e.item)
  const view = c.libraryView(id)
  return view ? ok(view) : notFound()
}

function latest(c: Catalog, p: Params): OfflineAnswer {
  const types = new Set(list(p, 'includeitemtypes').map(t => t.toLowerCase()))
  const parent = p.has('parentid') ? normId(p.get('parentid')!) : null
  let entries = inLibrary(c.media, parent)
  if (types.size) entries = entries.filter(e => types.has((e.item.Type ?? 'Audio').toLowerCase()))
  const sorted = sortEntries(entries, new Map([['sortby', 'DateCreated'], ['sortorder', 'Descending']]), Math.random, [])
  return ok(sorted.slice(0, int(p, 'limit') ?? 20).map(e => e.item))
}

function queryFilters(c: Catalog, p: Params): OfflineAnswer {
  const types = new Set(list(p, 'includeitemtypes').map(t => t.toLowerCase()))
  const parent = p.has('parentid') ? normId(p.get('parentid')!) : null
  let entries = inLibrary(c.all(false), parent)
  if (types.size) entries = entries.filter(e => types.has((e.item.Type ?? 'Audio').toLowerCase()))
  const uniq = (xs: string[]) => [...new Set(xs)].sort(cmpText)
  return ok({
    Genres: uniq(entries.flatMap(e => e.item.Genres ?? [])),
    Tags: [],
    OfficialRatings: uniq(entries.flatMap(e => e.item.OfficialRating ? [e.item.OfficialRating] : [])),
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
  const tracks = c.playlistTracks.get(id)
  if (!tracks) return notFound()
  return ok(page(tracks.map(t => ({ ...t, item: { ...t.item, PlaylistItemId: t.item.PlaylistItemId ?? t.item.Id } })), p))
}

function playlist(c: Catalog, id: string): OfflineAnswer {
  const tracks = c.playlistTracks.get(id)
  const e = c.byId.get(id)
  if (!tracks || !e) return notFound()
  return ok({ OpenAccess: e.item.IsPublic === true, Shares: [], ItemIds: tracks.map(t => t.item.Id) })
}

function seasons(c: Catalog, seriesId: string, p: Params, random: () => number): OfflineAnswer {
  if (!c.containers.some(e => normId(e.item.Id) === seriesId)) return notFound()
  const found = c.containers.filter(e => e.item.Type === 'Season' && e.parents.has(seriesId))
  return ok(page(sortEntries(found, new Map(), random, ['indexnumber', 'sortname']), p))
}

function episodes(c: Catalog, seriesId: string, p: Params, random: () => number): OfflineAnswer {
  if (!c.containers.some(e => normId(e.item.Id) === seriesId)) return notFound()
  const season = p.has('seasonid') ? normId(p.get('seasonid')!) : null
  const found = c.media.filter(e => e.item.Type === 'Episode' && e.parents.has(seriesId) && (season === null || e.parents.has(season)))
  return ok(page(sortEntries(found, new Map(), random, ['parentindexnumber', 'indexnumber', 'sortname']), p))
}

/** Per show, the first unplayed episode after the last played one; shows not
 *  started are left out, as the server's Next Up leaves them. Most recently
 *  watched show first. */
function nextUp(c: Catalog, p: Params, random: () => number): OfflineAnswer {
  const parent = p.has('parentid') ? normId(p.get('parentid')!) : null
  const onlySeries = p.has('seriesid') ? normId(p.get('seriesid')!) : null
  const resumable = bool(p, 'enableresumable') !== false
  const found: { entry: Entry, last: number }[] = []
  for (const series of inLibrary(c.containers.filter(e => e.item.Type === 'Series'), parent)) {
    const sid = normId(series.item.Id)
    if (onlySeries !== null && sid !== onlySeries) continue
    const eps = sortEntries(c.media.filter(e => e.item.Type === 'Episode' && e.parents.has(sid)), new Map(), random,
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
function derivedList(c: Catalog, from: Entry[], p: Params, random: () => number): OfflineAnswer {
  const parent = p.has('parentid') ? normId(p.get('parentid')!) : null
  let entries = filterEntries(inLibrary(from, parent), p)
  const types = new Set(list(p, 'includeitemtypes').map(t => t.toLowerCase()))
  if (types.size) {
    entries = entries.filter(e => [...(e.types ?? [])].some(t => types.has(t)))
  }
  return ok(page(sortEntries(entries, p, random, ['sortname']), p))
}

function persons(c: Catalog, p: Params, random: () => number): OfflineAnswer {
  const kinds = new Set(list(p, 'persontypes').map(t => t.toLowerCase()))
  const from = kinds.size === 1 && kinds.has('albumartist') ? c.albumArtists : c.artists
  if (kinds.size && !kinds.has('artist') && !kinds.has('albumartist')) return ok(EMPTY_LIST)
  return derivedList(c, from, p, random)
}

/** /Items/<word> routes that are not an item id. */
const RESERVED = new Set(['latest', 'filters', 'filters2', 'root', 'counts', 'resume'])

/**
 * Answers one GET from the catalog. `path` is the route as the apps send it
 * (a query string on it is read too); `params` the query, names in any case.
 * `random` drives SortBy=Random.
 */
export function answerOffline(index: OfflineIndex, path: string, params: Record<string, unknown> = {},
  random: () => number = Math.random): OfflineAnswer {
  const { segments: seg, params: p } = readParams(path, params)
  const s = seg.map(x => x.toLowerCase())
  const c = new Catalog(index)
  const id = (i: number) => normId(seg[i])

  if (s.length === 1 && s[0] === 'items') return items(c, p, random)
  if (s.length === 2 && s[0] === 'items' && s[1] === 'latest') return latest(c, p)
  if (s.length === 2 && s[0] === 'items' && s[1] === 'filters') return queryFilters(c, p)
  if (s.length === 2 && s[0] === 'items' && /^[a-z0-9-]+$/.test(s[1]) && !RESERVED.has(s[1])) return oneItem(c, id(1))
  if (s.length === 1 && s[0] === 'userviews') return views(c)
  if (s.length === 2 && s[0] === 'users' && /^[a-z0-9-]+$/.test(s[1])) return user(c, s[1] === 'me' ? 'me' : id(1))
  if (s.length === 3 && s[0] === 'playlists' && s[2] === 'items') return playlistItems(c, id(1), p)
  if (s.length === 2 && s[0] === 'playlists') return playlist(c, id(1))
  if (s.length === 2 && s[0] === 'shows' && s[1] === 'nextup') return nextUp(c, p, random)
  if (s.length === 3 && s[0] === 'shows' && s[2] === 'seasons') return seasons(c, id(1), p, random)
  if (s.length === 3 && s[0] === 'shows' && s[2] === 'episodes') return episodes(c, id(1), p, random)
  if (s.length === 2 && s[0] === 'mediasegments') return segments(c, id(1))
  if (s.length === 1 && s[0] === 'artists') return derivedList(c, c.artists, p, random)
  if (s.length === 2 && s[0] === 'artists' && s[1] === 'albumartists') return derivedList(c, c.albumArtists, p, random)
  if (s.length === 1 && s[0] === 'persons') return persons(c, p, random)
  if (s.length === 1 && s[0] === 'musicgenres') return derivedList(c, c.musicGenres, p, random)
  if (s.length === 1 && s[0] === 'genres') return derivedList(c, c.genres, p, random)
  return { status: 200, body: EMPTY_LIST, unknownRoute: true }
}

/** The placeholder libraries' ids, which Offline Mode adds to the libraries a
 *  screen fans out over, so downloads whose library is not known yet still
 *  show (plan, section 1). */
export const placeholderLibraryIds = (): string[] => Object.values(PLACEHOLDER_LIBRARIES).map(l => l.Id)
