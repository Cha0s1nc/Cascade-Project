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
