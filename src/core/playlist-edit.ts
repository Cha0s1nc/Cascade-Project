// Bulk playlist editing: remove and move-to-top/bottom over a selection of
// rows. Pure, no DOM - renderer.js owns the checkbox selection (a Set of
// entry ids) and the actual POST /Playlists/{id} write; this only computes
// the new row order it should send.

import type { JfItem } from './types.ts'

/** The id that identifies one row in a real playlist - the entry id when
 *  present (a track can appear more than once), the track id otherwise. Same
 *  fallback renderer.js already uses for drag-reorder and remove-from-playlist. */
export function entryIdOf(item: JfItem): string {
  return item.PlaylistItemId || item.Id
}

/** Drop every selected row, keeping the rest in their existing order. */
export function removeSelected(items: JfItem[], selected: ReadonlySet<string>): JfItem[] {
  return items.filter(item => !selected.has(entryIdOf(item)))
}

/** Pull every selected row to the front, in their existing relative order. */
export function moveSelectedToTop(items: JfItem[], selected: ReadonlySet<string>): JfItem[] {
  const sel: JfItem[] = []
  const rest: JfItem[] = []
  for (const item of items) (selected.has(entryIdOf(item)) ? sel : rest).push(item)
  return [...sel, ...rest]
}

/** Push every selected row to the back, in their existing relative order. */
export function moveSelectedToBottom(items: JfItem[], selected: ReadonlySet<string>): JfItem[] {
  const sel: JfItem[] = []
  const rest: JfItem[] = []
  for (const item of items) (selected.has(entryIdOf(item)) ? sel : rest).push(item)
  return [...rest, ...sel]
}

/** Spaces writes to one playlist at least `spacingMs` apart. Jellyfin 10.11.11
 *  rewrites playlist.xml from a background metadata saver shortly after each
 *  playlist change; a second write landing inside that window collides with
 *  it on the file ("being used by another process" in the server log) and the
 *  playlist is left in an older state, though every request answered 204.
 *  Measured: writes 100 ms apart lost the final state 7 runs in 10, 300 ms
 *  apart none in 10. The slot is taken before sleeping, so concurrent writes
 *  queue in turn. The native app does the same (PlaylistWriteGate). */
export function createPlaylistWriteGate(
  spacingMs = 400,
  now: () => number = () => Date.now(),
  sleep: (ms: number) => Promise<void> = ms => new Promise(resolve => setTimeout(resolve, ms)),
): (playlistId: string) => Promise<void> {
  const nextSlot = new Map<string, number>()
  return async playlistId => {
    const t = now()
    const slot = Math.max(t, nextSlot.get(playlistId) ?? t)
    nextSlot.set(playlistId, slot + spacingMs)
    if (slot > t) await sleep(slot - t)
  }
}
