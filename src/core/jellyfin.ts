// Jellyfin HTTP client. No DOM, no Electron - uses only fetch and URL, both of
// which exist on webOS/Tizen and in React Native.

import type { JfItem, JfItemsResponse, JfAuthResult, JfParams, ServerConfig } from './types.ts'

const EMPTY_RESPONSE: JfItemsResponse = { Items: [], TotalRecordCount: 0 }

/** Longest a server error body is allowed to become once turned into
 *  `error.message`. Past this it is truncated rather than shown whole. */
const MAX_ERROR_MESSAGE_LEN = 300

/**
 * Turn a failed response into a short, readable error message.
 *
 * Jellyfin's own error bodies are short plain text and worth showing as-is.
 * A reverse proxy sitting in front of a dead server (Cloudflare, nginx, etc)
 * answers instead with a whole HTML error page - kilobytes of markup that,
 * dumped into `error.message` and rendered by a caller, becomes a wall of red
 * text filling the screen. Detect that case by content-type or a leading `<`
 * and fall back to the status line instead. Whatever text does get kept is
 * collapsed to one line and capped, since even a "short" text body can in
 * practice be huge.
 */
export async function readErrorMessage(res: Response): Promise<string> {
  const status = `${res.status} ${res.statusText}`.trim()
  let body = ''
  try {
    body = await res.text()
  } catch {
    return status
  }
  const trimmed = body.trim()
  if (!trimmed) return status

  const contentType = res.headers.get('content-type') || ''
  if (contentType.includes('html') || trimmed.startsWith('<')) return status

  const collapsed = trimmed.replace(/\s+/g, ' ')
  return collapsed.length > MAX_ERROR_MESSAGE_LEN
    ? `${collapsed.slice(0, MAX_ERROR_MESSAGE_LEN)}…`
    : collapsed
}

/**
 * Identifies this client to Jellyfin.
 *
 * `deviceId` must be unique per install. It used to be the constant
 * "cascade-app", which made every Cascade look like the same device: the server
 * could not tell two clients apart, so remote control could not target one of
 * them and two instances collided in the session list.
 */
/**
 * The standard `Authorization: MediaBrowser ...` value. With a token, it also
 * carries the token: the one way to authenticate that Jellyfin 12 accepts by
 * default. 12.0 turned off the legacy ways (the X-Emby-Token and
 * X-Emby-Authorization headers, the api_key query parameter) on new and
 * upgraded servers alike, so a client still using them simply stops working
 * there. Jellyfin 10.11 already accepts this form, so it is safe on both.
 */
export function authHeader(appVersion: string, deviceId: string, token?: string): string {
  const base = `MediaBrowser Client="Cascade", Device="Cascade", DeviceId="${deviceId}", Version="${appVersion}"`
  return token ? `${base}, Token="${token}"` : base
}

/** Headers for an authenticated request, from the session config (`jf`). The
 *  one place the token goes into a header; see authHeader. */
export function authHeaders(
  config: { token: string, appVersion?: string, deviceId?: string },
  extra: Record<string, string> = {},
): Record<string, string> {
  return { Authorization: authHeader(config.appVersion ?? '0.0.0', config.deviceId ?? 'cascade-app', config.token), ...extra }
}

/**
 * One-time migration: earlier Cascade builds saved movie and TV library
 * selections together under one flat `videoLibraryIds` key. Split that list
 * into the two per-category lists it should have always been, by looking up
 * each id's CollectionType in the library list fetched from /Views. An id
 * that no longer matches anything (renamed, deleted, wrong category) is
 * dropped rather than guessed at.
 */
export function splitVideoLibraryIds(
  libs: JfItem[],
  oldIds: string[],
): { movieIds: string[], showIds: string[] } {
  const movieIds = oldIds.filter(id => libs.some(l => l.Id === id && l.CollectionType === 'movies'))
  const showIds  = oldIds.filter(id => libs.some(l => l.Id === id && l.CollectionType === 'tvshows'))
  return { movieIds, showIds }
}

/**
 * The ids actually in effect for one video category (movies, or TV shows).
 *
 * With exactly one library in the category there is nothing to choose, so
 * that library is always used, regardless of what (if anything) is saved -
 * this is derived fresh every time rather than persisted, so it keeps working
 * if the library is later renamed or replaced. Otherwise it is whatever was
 * saved, minus any id that no longer matches a library on the server (one
 * that was deleted or moved to a different category since the last launch).
 */
export function effectiveLibraryIds(
  categoryLibs: JfItem[],
  savedIds: string[] | null | undefined,
): string[] {
  if (!categoryLibs.length) return []
  // Null means no choice has ever been made, which is different from an empty
  // array meaning "explicitly none". A sole library used to be forced on
  // whatever was saved, so turning video off was impossible for anyone with
  // exactly one movie or TV library: the toggle either did not render or did
  // nothing. It still defaults on, so nobody loses a library they never chose,
  // but off is now a state that sticks.
  if (savedIds == null) return categoryLibs.length === 1 ? [categoryLibs[0].Id] : []
  return savedIds.filter(id => categoryLibs.some(l => l.Id === id))
}

/**
 * One card per series for Home's Continue watching, so a binged show appears
 * once instead of once per episode.
 *
 * Keeps the first episode seen for each SeriesId and drops the rest, so the
 * caller's order decides which one wins. Continue watching passes what is
 * partway through (re-sorted most recent first, since getMerged concatenates
 * each library's results and the server's DatePlayed sort only holds within
 * one) followed by Next Up, which means a show's half-watched episode beats
 * the Next Up entry for the same show.
 *
 * An episode with no SeriesId is never dropped and never merged with another
 * SeriesId-less episode - each one is its own entry, same as a Movie. Movies
 * pass through unchanged.
 */
export function onePerSeries(items: JfItem[]): JfItem[] {
  const seenSeries = new Set<string>()
  const result: JfItem[] = []
  for (const item of items) {
    if (item.Type === 'Episode' && item.SeriesId) {
      if (seenSeries.has(item.SeriesId)) continue
      seenSeries.add(item.SeriesId)
    }
    result.push(item)
  }
  return result
}

/** Default page size when a caller does not set params.Limit. */
const DEFAULT_PAGE_SIZE = 500

/**
 * Authenticate against a server. Standalone rather than a client method because
 * it runs before there is any config to construct a client with.
 */
export async function authenticate(
  serverUrl: string,
  username: string,
  password: string,
  appVersion: string,
  deviceId: string,
): Promise<JfAuthResult> {
  const res = await fetch(`${serverUrl}/Users/AuthenticateByName`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: authHeader(appVersion, deviceId),
    },
    body: JSON.stringify({ Username: username, Pw: password }),
  })
  if (!res.ok) throw new Error(await readErrorMessage(res))
  return res.json() as Promise<JfAuthResult>
}

/** What the server hands back when a QuickConnect request is started. */
export interface QuickConnectStart {
  /** Shown to the user; they type it into Jellyfin on an already-signed-in device. */
  Code: string
  /** Opaque handle used to poll and then exchange for a token. Never shown. */
  Secret: string
}

interface QuickConnectState {
  Authenticated?: boolean
}

/** How often to ask the server whether the code has been approved. */
export const QUICK_CONNECT_POLL_MS = 2000

/** Give up after this long so a forgotten sign-in does not poll forever. */
export const QUICK_CONNECT_TIMEOUT_MS = 5 * 60 * 1000

/** Whether the server has QuickConnect switched on. Never throws - a server that
 *  404s this simply does not offer it. */
export async function quickConnectEnabled(serverUrl: string): Promise<boolean> {
  try {
    const res = await fetch(`${serverUrl}/QuickConnect/Enabled`)
    if (!res.ok) return false
    return await res.json() === true
  } catch {
    return false
  }
}

/**
 * Start a QuickConnect request and get the code to show the user.
 *
 * The device id matters here: Jellyfin ties the pending request to it, and it is
 * what the resulting token is bound to.
 */
export async function quickConnectInitiate(
  serverUrl: string,
  appVersion: string,
  deviceId: string,
): Promise<QuickConnectStart> {
  const res = await fetch(`${serverUrl}/QuickConnect/Initiate`, {
    method: 'POST',
    headers: { Authorization: authHeader(appVersion, deviceId) },
  })
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
  return res.json() as Promise<QuickConnectStart>
}

/** True once the user has approved the code on another device. */
export async function quickConnectApproved(serverUrl: string, secret: string): Promise<boolean> {
  const res = await fetch(`${serverUrl}/QuickConnect/Connect?secret=${encodeURIComponent(secret)}`)
  // 404 means the request expired or was cancelled server-side - treat as
  // still-pending rather than throwing, and let the timeout end it.
  if (!res.ok) return false
  const state = await res.json() as QuickConnectState
  return state?.Authenticated === true
}

/** Exchange an approved secret for a real access token. */
export async function quickConnectAuthenticate(
  serverUrl: string,
  secret: string,
  appVersion: string,
  deviceId: string,
): Promise<JfAuthResult> {
  const res = await fetch(`${serverUrl}/Users/AuthenticateWithQuickConnect`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: authHeader(appVersion, deviceId),
    },
    body: JSON.stringify({ Secret: secret }),
  })
  if (!res.ok) throw new Error(await readErrorMessage(res))
  return res.json() as Promise<JfAuthResult>
}

export class JellyfinClient {
  // Written out longhand rather than as a constructor parameter property:
  // Node's strip-only TypeScript mode (what `npm test` uses) rejects those,
  // since they emit code instead of only removing types.
  private readonly getConfig: () => ServerConfig

  /**
   * Takes a *getter* rather than a config object because the renderer replaces
   * its `jf` object wholesale on connect (`jf = { ... }`). Holding a reference
   * to the old object would silently keep using stale credentials.
   */
  constructor(getConfig: () => ServerConfig) {
    this.getConfig = getConfig
  }

  private get config(): ServerConfig {
    return this.getConfig()
  }

  /**
   * Headers for an ordinary, already-authenticated request: the token inside
   * the standard Authorization header (see authHeader).
   *
   * The client fields ride along on every request, not just the login calls,
   * because Jellyfin records a client's version from them. Since a saved token
   * is reused indefinitely, the dashboard's device list kept showing whatever
   * version last actually signed in until a sign-out and back in.
   */
  private headers(extra: Record<string, string> = {}): Record<string, string> {
    return authHeaders(this.config, extra)
  }

  async get<T = JfItemsResponse>(path: string, params: JfParams = {}): Promise<T> {
    const { url } = this.config
    const target = new URL(`${url}${path}`)

    for (const [k, v] of Object.entries(params)) {
      // Skipping undefined rather than letting URLSearchParams stringify it to
      // the literal "undefined", which is never what a caller means.
      if (v === undefined) continue
      target.searchParams.set(k, String(v))
    }

    const res = await fetch(target, { headers: this.headers() })
    if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
    return res.json() as Promise<T>
  }

  async post<T>(path: string, body: unknown, params: JfParams = {}): Promise<T> {
    const { url } = this.config
    const target = new URL(`${url}${path}`)
    for (const [k, v] of Object.entries(params)) {
      if (v === undefined) continue
      target.searchParams.set(k, String(v))
    }

    const res = await fetch(target, {
      method: 'POST',
      headers: this.headers({ 'Content-Type': 'application/json' }),
      body: JSON.stringify(body),
    })
    if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
    // Some POSTs answer 204 with no body (/Sessions/Capabilities/Full does).
    // Parsing that as JSON threw "Unexpected end of JSON input", which made
    // remote-control registration fail on every start.
    if (res.status === 204) return undefined as T
    return res.json() as Promise<T>
  }

  /**
   * DELETE, for the endpoints that answer with no body.
   *
   * Returns nothing on purpose - `post` parses JSON, and the endpoints reached
   * this way reply 204. Resolves rather than throwing on a failed call, because
   * every caller so far is cleaning something up and has no better plan than
   * carrying on.
   */
  async del(path: string, params: JfParams = {}): Promise<boolean> {
    const { url } = this.config
    const target = new URL(`${url}${path}`)
    for (const [k, v] of Object.entries(params)) {
      if (v === undefined) continue
      target.searchParams.set(k, String(v))
    }
    try {
      const res = await fetch(target, { method: 'DELETE', headers: this.headers() })
      return res.ok
    } catch {
      return false
    }
  }

  /**
   * Run the query against each selected library and merge, de-duplicating by Id.
   * With no libraries selected this is a plain `get`.
   *
   * Respects params.Limit per library - use `getAllPaged` when you need
   * everything.
   *
   * `libraryIds` overrides the configured music libraries. Video browsing
   * passes its own set that way, so a movie query never fans out across the
   * music libraries and a music query never touches the movie ones.
   */
  async getMerged(path: string, params: JfParams = {}, libraryIds?: string[]): Promise<JfItemsResponse> {
    const ids = libraryIds ?? this.config.libraryIds ?? []
    if (!ids.length) return this.get<JfItemsResponse>(path, params)

    const { query, strip } = withDedupeFields(params, ids)
    const groups = await this.getGrouped(path, query, ids)
    return strip(dedupeById(groups.map(g => g.items)))
  }

  /**
   * Like `getMerged`, but keeps each library's results separate instead of
   * flattening them, so a caller can render one section per library. Groups
   * come back in the same order as `libraryIds`. A library that fails yields
   * an empty group rather than sinking the whole call, same as `getMerged`.
   *
   * With no libraries selected, falls back to a plain `get` wrapped as a
   * single unlabelled group, mirroring `getMerged`'s no-library behaviour.
   */
  async getGrouped(path: string, params: JfParams = {}, libraryIds?: string[]): Promise<{ libraryId: string, items: JfItem[] }[]> {
    const ids = libraryIds ?? this.config.libraryIds ?? []
    if (!ids.length) {
      const res = await this.get<JfItemsResponse>(path, params)
      return [{ libraryId: '', items: res.Items || [] }]
    }

    const results = await Promise.all(ids.map(libId =>
      this.get<JfItemsResponse>(path, { ...params, ParentId: libId })
        .catch(() => EMPTY_RESPONSE)
    ))

    return ids.map((libId, i) => ({ libraryId: libId, items: results[i].Items || [] }))
  }

  /**
   * Like `getMerged`, but paginates each library until every matching item is
   * fetched instead of stopping at params.Limit. Pages within a library are
   * fetched in parallel once the first page reveals TotalRecordCount.
   */
  async getAllPaged(path: string, params: JfParams = {}, libraryIds?: string[]): Promise<JfItemsResponse> {
    const configured = libraryIds ?? this.config.libraryIds
    const ids: (string | null)[] = configured?.length ? configured : [null]
    const pageSize = Number(params.Limit) || DEFAULT_PAGE_SIZE
    const { query, strip } = withDedupeFields(params, configured ?? [])
    params = query

    const perLibrary = await Promise.all(ids.map(async libId => {
      const baseParams = libId ? { ...params, ParentId: libId } : params

      const first = await this.get<JfItemsResponse>(path, { ...baseParams, StartIndex: 0 })
        .catch(() => EMPTY_RESPONSE)

      const items = [...(first.Items || [])]
      const total = first.TotalRecordCount ?? items.length

      if (total > items.length) {
        const starts: number[] = []
        for (let start = items.length; start < total; start += pageSize) starts.push(start)

        const pages = await Promise.all(starts.map(start =>
          this.get<JfItemsResponse>(path, { ...baseParams, StartIndex: start })
            .catch(() => EMPTY_RESPONSE)
        ))
        for (const p of pages) items.push(...(p.Items || []))
      }

      return items
    }))

    return strip(dedupeById(perLibrary))
  }

  /** Primary image URL for an item. No tag means no art, so no URL.
   *
   *  The tag rides along in the URL rather than only gating it: edit a cover in
   *  Cascade's own metadata editor and the item's tag changes, so without it
   *  every grid keeps rendering the pre-edit image from cache.
   */
  artUrl(itemId: string, tag: string | undefined | null): string | null {
    if (!tag) return null
    return `${this.imageUrl(itemId)}&tag=${encodeURIComponent(tag)}`
  }

  /** Artists always render a placeholder, so this has no tag guard. */
  artistArtUrl(itemId: string): string {
    return this.imageUrl(itemId)
  }

  private imageUrl(itemId: string): string {
    const { url, token } = this.config
    return `${url}/Items/${itemId}/Images/Primary?fillHeight=600&fillWidth=600&quality=90&ApiKey=${token}`
  }

  /** The stored image with no transformation requested.
   *
   *  `imageUrl` asks for fillHeight/fillWidth/quality, and any of those sends
   *  the file through Jellyfin's image processor, which re-encodes it - so an
   *  animated cover in the library arrives as a single flattened frame. Asking
   *  for no transformation returns the original bytes untouched, which is the
   *  only way an animated cover stays animated.
   *
   *  Unbounded in size, so this is for the one now-playing image and nothing
   *  else. Grid tiles must keep using the resized still. */
  originalArtUrl(itemId: string): string {
    const { url, token } = this.config
    return `${url}/Items/${itemId}/Images/Primary?ApiKey=${token}`
  }
}

/** Flatten item lists, keeping the first occurrence of each Id. */
/**
 * Merges per-library results (in library order) into one list: the same item
 * once by Id, and the same song or album found in two different libraries
 * once too. Shuffling three libraries that each hold the same album otherwise
 * played every song three times.
 *
 * Songs match on title and artist, ignoring case and punctuation, with
 * durations within DUPLICATE_DURATION_SEC (so a "(Live)" or extended cut,
 * titled or timed differently, stays), and the copy with the highest bitrate
 * is kept, in the place the first copy held (bitrate from MediaSources, see
 * withDedupeFields; without it the first library's copy stays). Albums match
 * on name and album artist, and the copy with the most tracks is kept
 * (ChildCount): the same album can be whole in one library and one song in
 * another, and keeping the one-song copy hid the rest of the album. Artists
 * match on name: Jellyfin 12 gives the same artist a different id in every
 * library, so the id alone listed each one once per library. Copies inside
 * one library are never merged: that is the library's own business, like a
 * single kept next to its album.
 */
export function dedupeById(lists: JfItem[][]): JfItemsResponse {
  const seen = new Set<string>()
  const byContent = new Map<string, { lib: number, sec: number | null, pos: number }[]>()
  const items: JfItem[] = []
  lists.forEach((list, lib) => {
    for (const item of list) {
      if (seen.has(item.Id)) continue
      seen.add(item.Id)
      const key = contentKey(item)
      if (key) {
        const sec = item.RunTimeTicks ? item.RunTimeTicks / 10_000_000 : null
        const copies = byContent.get(key) ?? []
        const copy = copies.find(c => c.lib !== lib &&
          (item.Type !== 'Audio' || c.sec == null || sec == null || Math.abs(c.sec - sec) <= DUPLICATE_DURATION_SEC))
        if (copy) {
          if (better(item, items[copy.pos])) { items[copy.pos] = item; copy.lib = lib; copy.sec = sec }
          continue
        }
        copies.push({ lib, sec, pos: items.length })
        byContent.set(key, copies)
      }
      items.push(item)
    }
  })
  return { Items: items, TotalRecordCount: items.length }
}

const bitrate = (item: JfItem) => item.MediaSources?.[0]?.Bitrate ?? 0
/** Which of two copies of the same song or album to keep. */
const better = (a: JfItem, b: JfItem) => a.Type === 'MusicAlbum'
  ? (a.ChildCount ?? 0) > (b.ChildCount ?? 0)
  : bitrate(a) > bitrate(b)

/**
 * The fields the cross-library merge compares copies by, asked for only when
 * the query spans two or more libraries: MediaSources for a song's bitrate
 * (which more than doubles each item, 1.4 KB to 3.7 KB measured) and
 * ChildCount for an album's track count. `strip` takes them back off
 * afterwards unless the caller asked for them itself.
 */
function withDedupeFields(params: JfParams, ids: readonly string[]): { query: JfParams, strip: (r: JfItemsResponse) => JfItemsResponse } {
  const fields = String(params.Fields ?? '')
  const types = String(params.IncludeItemTypes ?? '')
  const has = (list: string, name: string) => new RegExp(`(^|,)${name}(,|$)`).test(list)
  const add = ids.length > 1
    ? [has(types, 'Audio') && 'MediaSources', has(types, 'MusicAlbum') && 'ChildCount'].filter((f): f is string => !!f && !has(fields, f))
    : []
  if (!add.length) return { query: params, strip: r => r }
  return {
    query: { ...params, Fields: [fields, ...add].filter(Boolean).join(',') },
    strip: r => {
      for (const i of r.Items ?? []) for (const f of add) delete (i as unknown as Record<string, unknown>)[f]
      return r
    },
  }
}

export const DUPLICATE_DURATION_SEC = 3

const normalise = (s: string | undefined | null) =>
  (s || '').normalize('NFKC').toLowerCase().replace(/[\p{P}\p{S}\s]+/gu, '')

/** What makes two songs or albums the same, or null for anything else. */
function contentKey(item: JfItem): string | null {
  if (item.Type === 'Audio') {
    const title = normalise(item.Name)
    return title ? `a|${title}|${normalise(item.Artists?.[0] || item.AlbumArtist)}` : null
  }
  if (item.Type === 'MusicAlbum') {
    const name = normalise(item.Name)
    return name ? `m|${name}|${normalise(item.AlbumArtist || item.Artists?.[0])}` : null
  }
  if (item.Type === 'MusicArtist') {
    const name = normalise(item.Name)
    return name ? `r|${name}` : null
  }
  return null
}

/** Whether a Content-Type is a format that *can* carry animation.
 *
 *  Deliberately not "is animated": a static GIF or WebP also matches, and the
 *  only cost of a false positive is serving the original file instead of a
 *  600px re-encode for one image. Telling the two apart means parsing frame
 *  counts out of the bytes, which is a lot of work to save a few KB. */
export function isAnimatedImageType(contentType: string | null | undefined): boolean {
  const t = (contentType || '').split(';')[0].trim().toLowerCase()
  return t === 'image/gif' || t === 'image/apng' || t === 'image/webp' || t === 'image/avif'
}
