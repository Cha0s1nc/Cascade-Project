// What is downloaded, as one value: the single source of truth for offline
// playback (the Apple app's lesson, OfflineIndex.swift: one index, not several
// stores kept in step by hand). Pure, so the rules that decide what a removal
// may delete and what counts as a finished download are tested here;
// offline.js owns the files and the one copy on disk.
//
// Paths are relative to the offline folder: an absolute path breaks when
// userData moves, and a relative one is what can be checked for escaping.

import type { JfItem } from './types.ts'

export interface OfflineTrack {
  /** The single-item fields a queue row needs, so the Downloads view and
   *  playback work with no server. See slimItem(). */
  item: JfItem
  /** "media/<id>.<ext>" once the whole file is on disk; null until then. */
  file: string | null
  bytes: number
}

/** An album or playlist the user asked for. A track shared by two of them is
 *  stored once. */
export interface OfflineCollection {
  item: JfItem
  trackIds: string[]
}

/** A play the server never heard about (its start report failed), to be sent
 *  as /UserPlayedItems/{id}?datePlayed once the server is back. Jellyfin counts
 *  a play when playback STARTS, so that report is the one whose loss loses a
 *  play. `date` is ISO 8601. */
export interface OfflinePlay { itemId: string; userId: string; date: string }

export interface OfflineIndex {
  tracks: Record<string, OfflineTrack>
  /** Newest first. */
  collections: OfflineCollection[]
  plays: OfflinePlay[]
}

export const emptyIndex = (): OfflineIndex => ({ tracks: {}, collections: [], plays: [] })

/** Most plays kept while offline. A year of listening on a plane is not 5000. */
export const MAX_QUEUED_PLAYS = 5000

const ITEM_FIELDS = [
  'Id', 'Name', 'Type', 'MediaType', 'Album', 'AlbumId', 'AlbumArtist', 'Artists', 'AlbumPrimaryImageTag',
  'RunTimeTicks', 'IndexNumber', 'ParentIndexNumber', 'ProductionYear', 'ChildCount', 'SortName',
  'NormalizationGain',
] as const

/** An item cut down to the fields worth keeping offline. The list queries hand
 *  back far more (UserData, MediaStreams, paths) and the index is rewritten on
 *  every change. `ImageTags.Primary` stays, as the art check reads it. */
export function slimItem(item: JfItem): JfItem {
  const src = item as unknown as Record<string, unknown>
  const out: Record<string, unknown> = {}
  for (const k of ITEM_FIELDS) if (src[k] !== undefined) out[k] = src[k]
  if (item.ImageTags?.Primary) out.ImageTags = { Primary: item.ImageTags.Primary }
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

/** Every file a ready track points at. */
export const indexedFiles = (index: OfflineIndex): Set<string> =>
  new Set(Object.values(index.tracks).flatMap(t => t.file ? [t.file] : []))

// ── Changing (in place) ──────────────────────────────────────────────────────

/** Asks for a collection. Asking again refreshes its track list; tracks already
 *  on disk are kept, not fetched twice. A track list is the album's or
 *  playlist's own order. Tracks that are not music are dropped. */
export function addCollection(index: OfflineIndex, collection: JfItem, tracks: JfItem[]): void {
  const audio = tracks.filter(t => t?.Id && isSafeId(t.Id) && (t.Type === undefined || t.Type === 'Audio'))
  index.collections = index.collections.filter(c => c.item.Id !== collection.Id)
  index.collections.unshift({ item: slimItem(collection), trackIds: audio.map(t => t.Id) })
  for (const t of audio) {
    const existing = index.tracks[t.Id]
    if (existing) existing.item = slimItem(t)
    else index.tracks[t.Id] = { item: slimItem(t), file: null, bytes: 0 }
  }
}

export function markReady(index: OfflineIndex, trackId: string, file: string, bytes: number): void {
  const t = index.tracks[trackId]
  if (!t) return
  t.file = file
  t.bytes = bytes
}

/** Drops a collection, and with it every track no other collection still
 *  holds. Returns the files that are now nobody's, to delete. */
export function removeCollection(index: OfflineIndex, collectionId: string): string[] {
  index.collections = index.collections.filter(c => c.item.Id !== collectionId)
  const kept = new Set(index.collections.flatMap(c => c.trackIds))
  const orphaned: string[] = []
  for (const [id, t] of Object.entries(index.tracks)) {
    if (kept.has(id)) continue
    if (t.file) orphaned.push(t.file)
    delete index.tracks[id]
  }
  return orphaned.sort()
}

/** Brings the index in line with the disk after a crash, a relaunch or a person
 *  poking at the folder: a ready track whose file is gone goes back to pending.
 *  Returns files on disk the index does not know, to delete (a download that
 *  finished after its collection was removed). */
export function reconcile(index: OfflineIndex, filesOnDisk: Iterable<string>): string[] {
  const onDisk = new Set(filesOnDisk)
  for (const t of Object.values(index.tracks)) {
    if (t.file && !onDisk.has(t.file)) { t.file = null; t.bytes = 0 }
  }
  const known = indexedFiles(index)
  return [...onDisk].filter(f => !known.has(f)).sort()
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

const isPlainObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v)

const isoDate = (v: unknown): string | null => {
  if (typeof v !== 'string') return null
  const t = Date.parse(v)
  return Number.isFinite(t) ? new Date(t).toISOString() : null
}

/**
 * A stored index, validated: it is read from disk, where anything can be. A
 * path that could leave the offline folder is dropped (the track goes back to
 * pending), an id that is not a plain id is dropped, an unreadable value is an
 * empty index rather than a crash.
 */
export function parseIndex(raw: unknown): OfflineIndex {
  const index = emptyIndex()
  if (!isPlainObject(raw)) return index

  if (isPlainObject(raw.tracks)) {
    for (const [id, v] of Object.entries(raw.tracks)) {
      if (!isSafeId(id) || !isPlainObject(v) || !isPlainObject(v.item) || v.item.Id !== id) continue
      const file = isSafeMediaPath(v.file) ? v.file : null
      const bytes = file && typeof v.bytes === 'number' && Number.isFinite(v.bytes) && v.bytes > 0 ? Math.floor(v.bytes) : 0
      index.tracks[id] = { item: slimItem(v.item as unknown as JfItem), file, bytes }
    }
  }

  if (Array.isArray(raw.collections)) {
    const seen = new Set<string>()
    for (const c of raw.collections) {
      if (!isPlainObject(c) || !isPlainObject(c.item) || !isSafeId(c.item.Id) || seen.has(c.item.Id)) continue
      seen.add(c.item.Id)
      const ids = Array.isArray(c.trackIds) ? c.trackIds.filter((id): id is string => typeof id === 'string' && !!index.tracks[id]) : []
      index.collections.push({ item: slimItem(c.item as unknown as JfItem), trackIds: ids })
    }
  }

  if (Array.isArray(raw.plays)) {
    for (const p of raw.plays) {
      if (!isPlainObject(p) || !isSafeId(p.itemId) || typeof p.userId !== 'string' || !/^[A-Za-z0-9-]{1,64}$/.test(p.userId)) continue
      const date = isoDate(p.date)
      if (date) index.plays.push({ itemId: p.itemId, userId: p.userId, date })
    }
    if (index.plays.length > MAX_QUEUED_PLAYS) index.plays.splice(0, index.plays.length - MAX_QUEUED_PLAYS)
  }

  // A track no collection holds is nobody's: it would never be listed, played
  // from a Downloads row, or removed.
  const held = new Set(index.collections.flatMap(c => c.trackIds))
  for (const id of Object.keys(index.tracks)) if (!held.has(id)) delete index.tracks[id]
  return index
}

// ── Judging a download ───────────────────────────────────────────────────────

const AUDIO_EXTENSIONS: Record<string, string> = {
  'audio/flac': 'flac', 'audio/x-flac': 'flac', 'audio/mpeg': 'mp3', 'audio/mp3': 'mp3',
  'audio/mp4': 'm4a', 'audio/x-m4a': 'm4a', 'audio/aac': 'aac', 'audio/ogg': 'ogg',
  'audio/opus': 'opus', 'audio/wav': 'wav', 'audio/x-wav': 'wav', 'audio/webm': 'webm',
  'audio/x-ms-wma': 'wma', 'audio/x-matroska': 'mka',
}

/** The extension a downloaded file is saved under. A media element picks its
 *  parser by what the response says, but a wrong or missing extension is a
 *  file nothing else can identify. The server's file name first (/Download
 *  sends the original's), then the MIME type; null when neither says audio. */
export function fileExtensionFor(contentDisposition: string | null | undefined, contentType: string | null | undefined): string | null {
  const name = /filename\*?=(?:UTF-8'')?"?([^";]+)"?/i.exec(contentDisposition ?? '')?.[1]
  if (name) {
    const dot = name.lastIndexOf('.')
    const ext = dot >= 0 ? name.slice(dot + 1).toLowerCase() : ''
    if (/^[a-z0-9]{1,5}$/.test(ext)) return ext
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
