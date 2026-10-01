// Queue ordering: sorting and shuffling. Pure, no DOM.
//
// The repeat/shuffle *toggle* logic stays in renderer.js - it is mostly button
// classList updates and is not portable. Only the ordering maths lives here.

import type { JfItem } from './types.ts'

export type SongSortField = 'name' | 'artist' | 'album' | 'added' | 'played'
export type SortDirection = 'asc' | 'desc'

/** Sort key for a track. Strings are lowercased; dates become epoch millis. */
export function songSortValue(item: JfItem, field: SongSortField | string): string | number {
  switch (field) {
    case 'artist': return (item.AlbumArtist || item.Artists?.[0] || '').toLowerCase()
    case 'album':  return (item.Album || '').toLowerCase()
    case 'added':  return item.DateCreated ? Date.parse(item.DateCreated) || 0 : 0
    case 'played': return item.UserData?.LastPlayedDate ? Date.parse(item.UserData.LastPlayedDate) || 0 : 0
    default:       return (item.Name || '').toLowerCase()
  }
}

/**
 * Sort tracks **in place** and return the same array.
 *
 * In place on purpose: renderer.js keeps a long-lived `allSongs` array that
 * other code holds references to, so replacing it would strand those.
 */
export function sortSongs(
  items: JfItem[],
  field: SongSortField | string,
  direction: SortDirection | string,
): JfItem[] {
  const dir = direction === 'desc' ? -1 : 1
  return items.sort((a, b) => {
    const va = songSortValue(a, field)
    const vb = songSortValue(b, field)
    if (va < vb) return -1 * dir
    if (va > vb) return 1 * dir
    return 0
  })
}

/**
 * Fisher-Yates, in place. Returns the same array.
 *
 * ponytail: Math.random() is fine here - this shuffles a play queue, not
 * anything that needs to resist prediction.
 */
export function shuffleInPlace<T>(arr: T[]): T[] {
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[arr[i], arr[j]] = [arr[j], arr[i]]
  }
  return arr
}

/** Fisher-Yates on a copy, leaving the input untouched. */
export function shuffled<T>(items: readonly T[]): T[] {
  return shuffleInPlace([...items])
}

/**
 * Insert `items` right after the currently playing track, for "Play next".
 *
 * queueIndex points at what's playing right now - inserting before it, or at
 * it, would change what's playing. queueIndex + 1 is always the right spot,
 * clamped so an empty/negative queueIndex (nothing playing yet) inserts at
 * the front instead of going negative.
 *
 * Returns a new array rather than mutating `queue` in place: renderer.js's
 * `queue` is a plain `let`, already reassigned wholesale elsewhere (sign out,
 * stop playback, un-shuffling), so handing back a fresh array fits the
 * existing pattern instead of adding a second, mutating convention next to it.
 */
export function insertAfterCurrent<T>(queue: readonly T[], queueIndex: number, items: readonly T[]): T[] {
  const at = Math.max(0, queueIndex + 1)
  return [...queue.slice(0, at), ...items, ...queue.slice(at)]
}

/**
 * Index of the track that follows `queueIndex`, honouring repeat mode, or
 * null when nothing should follow (queue exhausted, repeat off).
 *
 * Shared by crossfade scheduling and stream prefetch in renderer.js - both
 * need "what plays next" without actually playing it. 'one' repeats the
 * current track forever, so nothing ever follows it.
 */
export function nextQueueIndex(queueLength: number, queueIndex: number, repeatMode: string): number | null {
  if (repeatMode === 'one') return null
  const next = queueIndex + 1
  if (next >= queueLength) return repeatMode === 'all' ? 0 : null
  return next
}

/**
 * Seconds left in the queue: what remains of the current track plus every
 * track after it. A track with no RunTimeTicks counts as 0.
 */
export function queueRemainingSec(queue: readonly JfItem[], queueIndex: number, positionSec: number): number {
  if (queueIndex < 0 || queueIndex >= queue.length) return 0
  const len = (i: number) => (queue[i].RunTimeTicks || 0) / 10_000_000
  let total = Math.max(0, len(queueIndex) - Math.max(0, positionSec || 0))
  for (let i = queueIndex + 1; i < queue.length; i++) total += len(i)
  return total
}

/** A long span as the queue panel shows it: "1d 1h", "2h 5m", "34m", "<1m". */
export function formatQueueSpan(sec: number): string {
  const m = Math.floor(Math.max(0, sec) / 60)
  if (m < 1) return '<1m'
  const d = Math.floor(m / 1440), h = Math.floor(m / 60) % 24, min = m % 60
  if (d) return h ? `${d}d ${h}h` : `${d}d`
  if (h) return min ? `${h}h ${min}m` : `${h}h`
  return `${min}m`
}

/**
 * What to call a queue in "Up Next, from ..." when the caller did not say:
 * the album's name when every track is from one album, otherwise nothing.
 */
export function queueSourceFallback(items: readonly JfItem[]): string | null {
  const first = items[0]
  if (!first?.AlbumId || !first.Album) return null
  return items.every(t => t.AlbumId === first.AlbumId) ? first.Album : null
}

/**
 * The queue as kept across a restart: item ids (refetched on restore, so a
 * track deleted meanwhile just drops out), where playback was, and the
 * original order when shuffled. Music only: a video or a radio station is
 * not kept, and an empty queue keeps nothing.
 */
export interface SavedQueue {
  ids: string[]
  index: number
  positionSec: number
  unshuffledIds?: string[]
}

export const SAVED_QUEUE_MAX = 2000

export function savedQueueOf(queue: readonly JfItem[], index: number, positionSec: number, unshuffled: readonly JfItem[]): SavedQueue | null {
  const current = queue[index]
  if (!current || current.Type !== 'Audio') return null
  // Past the cap, keep a window that holds the current track.
  const start = queue.length > SAVED_QUEUE_MAX ? Math.max(0, Math.min(index - 100, queue.length - SAVED_QUEUE_MAX)) : 0
  const ids = queue.slice(start, start + SAVED_QUEUE_MAX).map(i => i.Id)
  const saved: SavedQueue = { ids, index: index - start, positionSec: Math.max(0, Math.round(positionSec * 10) / 10) }
  if (unshuffled.length) saved.unshuffledIds = unshuffled.slice(0, SAVED_QUEUE_MAX).map(i => i.Id)
  return saved
}

const idList = (v: unknown): string[] =>
  Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string' && /^[0-9a-f-]{32,36}$/i.test(x)).slice(0, SAVED_QUEUE_MAX) : []

/** Every id a stored queue needs fetched, or none if it is not a queue. Stored data is untrusted. */
export function savedQueueIds(saved: unknown): string[] {
  if (!saved || typeof saved !== 'object') return []
  const s = saved as Record<string, unknown>
  return [...new Set([...idList(s.ids), ...idList(s.unshuffledIds)])]
}

/**
 * Rebuilds a stored queue from freshly fetched items (any order). If the
 * current track is gone, the next one that is still there becomes current,
 * from its start.
 */
export function restoreQueue(saved: unknown, items: readonly JfItem[]): { queue: JfItem[], index: number, positionSec: number, unshuffled: JfItem[] } | null {
  if (!saved || typeof saved !== 'object') return null
  const s = saved as Record<string, unknown>
  const ids = idList(s.ids)
  const byId = new Map(items.map(i => [i.Id, i]))
  const queue = ids.map(id => byId.get(id)).filter((i): i is JfItem => !!i)
  if (!queue.length) return null
  const savedIndex = Number.isInteger(s.index) ? Math.min(Math.max(s.index as number, 0), ids.length - 1) : 0
  const pos = typeof s.positionSec === 'number' && Number.isFinite(s.positionSec) ? Math.max(0, s.positionSec) : 0
  const stillThere = byId.has(ids[savedIndex])
  // Items kept before the saved current one: where it, or its successor, now sits.
  const before = ids.slice(0, savedIndex).filter(id => byId.has(id)).length
  const index = Math.min(before, queue.length - 1)
  const unshuffled = idList(s.unshuffledIds).map(id => byId.get(id)).filter((i): i is JfItem => !!i)
  return { queue, index, positionSec: stillThere ? pos : 0, unshuffled }
}
