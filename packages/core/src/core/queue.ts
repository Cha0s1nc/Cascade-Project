// Queue ordering: sorting, shuffling, and what plays next. Pure, no DOM.
//
// The repeat/shuffle rules used to live in renderer.js on the grounds that they
// were "mostly button classList updates". Only the button painting was - the
// decisions underneath (where shuffle puts the currently playing track, what a
// queue does when it runs out) are real behaviour the React Native app has to
// reproduce exactly, so they live here now. Each host keeps its own buttons.

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

// ---------------------------------------------------------------------------
// Repeat and shuffle
// ---------------------------------------------------------------------------

/** none -> play through and stop. all -> wrap. one -> replay this track. */
export type RepeatMode = 'none' | 'all' | 'one'

/** The order the repeat button cycles through, matching the desktop. */
const REPEAT_CYCLE: RepeatMode[] = ['none', 'all', 'one']

/** Next mode for a press of the repeat button. */
export function nextRepeatMode(mode: RepeatMode): RepeatMode {
  const i = REPEAT_CYCLE.indexOf(mode)
  return REPEAT_CYCLE[(i + 1) % REPEAT_CYCLE.length] as RepeatMode
}

/** A queue and where we are in it. */
export interface QueueOrder<T = JfItem> {
  items: T[]
  index: number
  /** The pre-shuffle order, kept only while shuffle is on. */
  unshuffled: T[] | null
}

/**
 * Turn shuffle on or off, keeping the current track playing.
 *
 * Two details that look like fussiness and are not, both carried over from the
 * desktop:
 *
 * Turning shuffle *on* moves the current track to the front and sets the index
 * to 0, rather than shuffling around it. Without that the track you are
 * listening to would jump to a random position, and everything before it would
 * be skipped the moment it ended.
 *
 * Turning shuffle *off* restores the saved order and finds the current track in
 * it by id, rather than reusing the index. The index means nothing across a
 * reorder, and reusing it would jump to an unrelated track.
 *
 * Returns new state; never mutates its input.
 */
export function setShuffle<T extends { Id: string }>(state: QueueOrder<T>, on: boolean): QueueOrder<T> {
  const currentId = state.items[state.index]?.Id

  if (on) {
    // Already on: leave it be, or we would reshuffle and lose the saved order.
    if (state.unshuffled) return state

    const items = shuffled(state.items)
    const at = items.findIndex(t => t.Id === currentId)
    if (at > 0) {
      const [track] = items.splice(at, 1)
      if (track) items.unshift(track)
    }
    return { items, index: items.length ? 0 : -1, unshuffled: [...state.items] }
  }

  if (!state.unshuffled) return state
  const items = state.unshuffled
  const at = items.findIndex(t => t.Id === currentId)
  return { items, index: at >= 0 ? at : 0, unshuffled: null }
}

/** What should happen when the current track finishes on its own. */
export type QueueAdvance =
  | { action: 'restart' }
  | { action: 'play'; index: number }
  | { action: 'stop' }

/**
 * What plays when a track ends by itself.
 *
 * Separate from `manualNextIndex` because the two genuinely differ: repeat-one
 * replays the track when it ends, but pressing next with repeat-one on should
 * move to the next track. A player that refused to skip would read as broken.
 */
export function advanceOnEnd(length: number, index: number, repeat: RepeatMode): QueueAdvance {
  if (length <= 0) return { action: 'stop' }
  if (repeat === 'one') return { action: 'restart' }

  const next = index + 1
  if (next < length) return { action: 'play', index: next }
  return repeat === 'all' ? { action: 'play', index: 0 } : { action: 'stop' }
}

/** Index for the next button, or -1 if there is nothing to move to. */
export function manualNextIndex(length: number, index: number, repeat: RepeatMode): number {
  if (length <= 0) return -1
  const next = index + 1
  if (next < length) return next
  return repeat === 'all' ? 0 : -1
}

/** Index for the previous button, or -1 if there is nothing to move to. */
export function manualPreviousIndex(length: number, index: number, repeat: RepeatMode): number {
  if (length <= 0) return -1
  const prev = index - 1
  if (prev >= 0) return prev
  return repeat === 'all' ? length - 1 : -1
}
